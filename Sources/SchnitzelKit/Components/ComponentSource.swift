//
//  ComponentSource.swift
//  SchnitzelKit
//
//  This file is part of Schnitzel.
//
//  Schnitzel is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Schnitzel is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Schnitzel.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

/// A GitHub repository whose release assets are versions of a component.
public struct ComponentSource: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ComponentKind
    public let displayName: String
    public let summary: String
    /// `owner/name` on GitHub.
    public let repository: String
    /// Asset names that count as versions of this component.
    public let assetPattern: String
    /// Asset names to skip even if they match `assetPattern`.
    public let excludePattern: String?
    /// Suffix removed from an asset name to get the version (the folder name).
    public let archiveSuffix: String
    /// A text file listing the versions the source's maintainers support, best first.
    /// Without it, the newest version is recommended.
    public var supportedListURL: URL? = nil

    public static let sikarugirEngines = ComponentSource(
        id: "sikarugir-engines", kind: .engine, displayName: "Sikarugir engines",
        summary: "CrossOver-based Wine built by Gcenx for Sikarugir. Supports MSync and D3DMetal. Recommended.",
        repository: "Sikarugir-App/Engines",
        assetPattern: #"^WS12Wine.+\.tar\.xz$"#, excludePattern: nil, archiveSuffix: ".tar.xz",
        supportedListURL: URL(string: "https://raw.githubusercontent.com/Sikarugir-App/Engines/main/EngineList.txt"))

    public static let wineHQEngines = ComponentSource(
        id: "winehq-engines", kind: .engine, displayName: "WineHQ builds",
        summary: "Official Wine devel and staging builds by Gcenx. No MSync, and D3DMetal may not work.",
        repository: "Gcenx/macOS_Wine_builds",
        assetPattern: #"^wine-(devel|staging)-.+-osx64\.tar\.xz$"#, excludePattern: nil, archiveSuffix: ".tar.xz")

    public static let dxvk = ComponentSource(
        id: "dxvk-macos", kind: .dxvk, displayName: "DXVK-macOS",
        summary: "DirectX 9, 10 and 11 through Vulkan and MoltenVK, by Gcenx.",
        repository: "Gcenx/DXVK-macOS",
        // The plain build: Schnitzel installs DXVK as native DLLs in system32.
        assetPattern: #"^dxvk-macOS-async-.+\.tar\.gz$"#, excludePattern: #"(builtin|CrossOver)"#,
        archiveSuffix: ".tar.gz")

    public static let dxmt = ComponentSource(
        id: "dxmt", kind: .dxmt, displayName: "DXMT",
        summary: "DirectX 10 and 11 through Metal, by 3Shain for CodeWeavers.",
        repository: "3Shain/dxmt",
        // DXMT only works as builtin DLLs inside the engine.
        assetPattern: #"^dxmt-.+-builtin\.tar\.gz$"#, excludePattern: nil, archiveSuffix: ".tar.gz")

    public static let all: [ComponentSource] = [.sikarugirEngines, .wineHQEngines, .dxvk, .dxmt]

    public static func sources(for kind: ComponentKind) -> [ComponentSource] {
        all.filter { $0.kind == kind }
    }

    func matches(assetName name: String) -> Bool {
        guard name.range(of: assetPattern, options: .regularExpression) != nil else { return false }
        if let excludePattern, name.range(of: excludePattern, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    func version(fromAssetName name: String) -> String {
        name.hasSuffix(archiveSuffix) ? String(name.dropLast(archiveSuffix.count)) : name
    }
}

/// A version that can be downloaded.
public struct AvailableComponent: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { "\(source.id)/\(version)" }
    public let source: ComponentSourceID
    public let kind: ComponentKind
    public let version: String
    public let assetName: String
    public let downloadURL: URL
    public let size: Int64
    /// From GitHub's asset digest. Nil for assets uploaded before GitHub published digests.
    public let sha256: String?
    public let published: Date
    public let releaseTag: String
    /// The version Schnitzel suggests from this source.
    public var isRecommended: Bool = false
    /// Listed as supported by the source's maintainers (only for sources with a supported list).
    public var isSupported: Bool = true
}

/// Identifies a source in `AvailableComponent` without carrying the whole definition.
public struct ComponentSourceID: Sendable, Hashable, Equatable {
    public let id: String
}

// MARK: - GitHub releases

/// Reads release lists from GitHub's public API (no account needed, 60 requests per hour).
public struct ReleaseCatalog: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let assets: [Asset]
    }

    struct Asset: Decodable {
        let name: String
        let size: Int64
        let browserDownloadUrl: URL
        let digest: String?
        let updatedAt: Date?
    }

    /// Available versions from `source`, newest first.
    public func available(from source: ComponentSource) async throws -> [AvailableComponent] {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(source.repository)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Schnitzel", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw CatalogError.rateLimited
            }
            throw CatalogError.httpStatus(http.statusCode)
        }
        let available = try Self.parse(data, source: source)

        var supported: [String]? = nil
        if let listURL = source.supportedListURL {
            var listRequest = URLRequest(url: listURL)
            listRequest.timeoutInterval = 30
            // The list only changes the order; without it everything still works.
            if let (listData, listResponse) = try? await session.data(for: listRequest),
               (listResponse as? HTTPURLResponse)?.statusCode == 200 {
                supported = String(decoding: listData, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
        return Self.order(available, supported: supported)
    }

    /// Puts supported versions first, in the maintainers' order, then the rest newest first.
    /// Marks the first one as recommended.
    static func order(_ available: [AvailableComponent], supported: [String]?) -> [AvailableComponent] {
        var result: [AvailableComponent]
        if let supported {
            let listed = supported.compactMap { name in available.first { $0.version == name } }
            let rest = available.filter { !supported.contains($0.version) }.map { component -> AvailableComponent in
                var component = component
                component.isSupported = false
                return component
            }
            result = listed + rest
        } else {
            result = available
        }
        if !result.isEmpty { result[0].isRecommended = true }
        return result
    }

    static func parse(_ data: Data, source: ComponentSource) throws -> [AvailableComponent] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([Release].self, from: data)

        var seen = Set<String>()
        var result: [AvailableComponent] = []
        for release in releases where !release.draft && !release.prerelease {
            for asset in release.assets where source.matches(assetName: asset.name) {
                let version = source.version(fromAssetName: asset.name)
                guard seen.insert(version).inserted else { continue }
                result.append(AvailableComponent(
                    source: ComponentSourceID(id: source.id), kind: source.kind, version: version,
                    assetName: asset.name, downloadURL: asset.browserDownloadUrl, size: asset.size,
                    sha256: asset.digest.flatMap(Self.sha256(fromDigest:)),
                    published: asset.updatedAt ?? release.publishedAt ?? .distantPast,
                    releaseTag: release.tagName))
            }
        }
        return result.sorted { $0.published > $1.published }
    }

    /// GitHub digests look like `sha256:<hex>`.
    static func sha256(fromDigest digest: String) -> String? {
        let prefix = "sha256:"
        guard digest.hasPrefix(prefix) else { return nil }
        let hex = digest.dropFirst(prefix.count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return String(hex)
    }
}

public enum CatalogError: Error, LocalizedError, Equatable {
    case rateLimited
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "GitHub is limiting requests right now. Wait a few minutes and try again."
        case .httpStatus(let status):
            return "GitHub answered with status \(status). Try again later."
        }
    }
}
