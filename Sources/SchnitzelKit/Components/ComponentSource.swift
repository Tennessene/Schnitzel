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
///
/// Adding a source (for example Schnitzel's own engine releases) only takes a new
/// definition here; downloading, checking, installing and pinning work the same for all.
public struct ComponentSource: Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ComponentKind
    public let displayName: String
    public let summary: String
    /// `owner/name` on GitHub.
    public let repository: String
    /// Asset names that count as versions. The first capture group is the version's core,
    /// for example `11.0_1` or `v0.80`.
    public let assetPattern: String
    /// Asset names to skip even if they match `assetPattern`.
    public var excludePattern: String? = nil
    /// Prefix for installed version names, unique per source, so two sources can never
    /// produce the same version name: `<versionPrefix>-<core>`.
    public let versionPrefix: String
    /// Only releases whose tag starts with this count. Lets one repository publish engine
    /// releases next to app releases.
    public var tagPrefix: String? = nil
    /// A text file listing the asset names (without extension) the maintainers support,
    /// best first. Without it, the newest version comes first.
    public var supportedListURL: URL? = nil
    /// A stand-in that Schnitzel's own builds will replace (see SCHNITZEL_PLAN.md).
    public var isTemporaryReference: Bool = false

    // MARK: Sources

    public static let sikarugirEngines = ComponentSource(
        id: "sikarugir-engines", kind: .engine, displayName: "Sikarugir engines",
        summary: "Temporary testing reference until Schnitzel's own engine is ready. Wine 11 with CrossOver patches, built by Gcenx for Sikarugir; supports MSync and D3DMetal.",
        repository: "Sikarugir-App/Engines",
        assetPattern: #"^(WS12Wine.+)\.tar\.xz$"#, versionPrefix: "sikarugir-engine",
        supportedListURL: URL(string: "https://raw.githubusercontent.com/Sikarugir-App/Engines/main/EngineList.txt"),
        isTemporaryReference: true)

    public static let wineHQEngines = ComponentSource(
        id: "winehq-engines", kind: .engine, displayName: "WineHQ builds",
        summary: "For comparison only. Official Wine devel and staging builds by Gcenx, without MSync or the Mac driver hooks D3DMetal needs.",
        repository: "Gcenx/macOS_Wine_builds",
        assetPattern: #"^wine-((?:devel|staging)-.+)-osx64\.tar\.xz$"#, versionPrefix: "winehq")

    public static let dxvk = ComponentSource(
        id: "dxvk-macos", kind: .dxvk, displayName: "DXVK-macOS",
        summary: "DirectX 9, 10 and 11 through Vulkan and MoltenVK, by Gcenx.",
        repository: "Gcenx/DXVK-macOS",
        // The plain build: Schnitzel installs DXVK as native DLLs in system32.
        assetPattern: #"^dxvk-macOS-async-(.+)\.tar\.gz$"#, excludePattern: #"(builtin|CrossOver)"#,
        versionPrefix: "dxvk-macos")

    public static let dxmt = ComponentSource(
        id: "dxmt", kind: .dxmt, displayName: "DXMT",
        summary: "DirectX 10 and 11 through Metal, by 3Shain for CodeWeavers.",
        repository: "3Shain/dxmt",
        // DXMT only works as builtin DLLs inside the engine.
        assetPattern: #"^dxmt-(.+)-builtin\.tar\.gz$"#, versionPrefix: "dxmt")

    public static let sikarugirTemplateLibraries = ComponentSource(
        id: "sikarugir-template-libraries", kind: .libraries, displayName: "Libraries from Sikarugir's Template",
        summary: "Temporary reference until Schnitzel builds its own. Only the open-source libraries Wine loads (FreeType, GnuTLS, MoltenVK, Vulkan loader, SDL2 and what they need) are kept; everything else in the download is discarded.",
        repository: "Sikarugir-App/Template",
        assetPattern: #"^Template-(1\.0\.\d+)\.tar\.xz$"#, versionPrefix: "sikarugir-template",
        supportedListURL: URL(string: "https://raw.githubusercontent.com/Sikarugir-App/Template/main/NewestVersion.txt"),
        isTemporaryReference: true)

    public static let all: [ComponentSource] = [
        .sikarugirEngines, .wineHQEngines, .dxvk, .dxmt, .sikarugirTemplateLibraries
    ]

    /// The one setting that decides which source is the default for each kind: its
    /// recommended version gets the "Recommended" label and is what new Pfannen use.
    /// Change `.engine` to Schnitzel's own source once a build passes testing.
    public static let defaultSourceIDs: [ComponentKind: String] = [
        .engine: sikarugirEngines.id,
        .dxvk: dxvk.id,
        .dxmt: dxmt.id,
        .libraries: sikarugirTemplateLibraries.id
    ]

    public static func defaultSource(for kind: ComponentKind) -> ComponentSource? {
        defaultSourceIDs[kind].flatMap(source(id:))
    }

    public static func source(id: String) -> ComponentSource? {
        all.first { $0.id == id }
    }

    public static func sources(for kind: ComponentKind) -> [ComponentSource] {
        all.filter { $0.kind == kind }
    }

    public var isDefault: Bool {
        Self.defaultSourceIDs[kind] == id
    }

    // MARK: Asset names

    func matches(assetName name: String) -> Bool {
        guard core(fromAssetName: name) != nil else { return false }
        if let excludePattern, name.range(of: excludePattern, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    func core(fromAssetName name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: assetPattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[range])
    }

    /// The installed version name for an asset: `<versionPrefix>-<core>`.
    func version(fromAssetName name: String) -> String? {
        core(fromAssetName: name).map { "\(versionPrefix)-\($0)" }
    }

    func matches(tag: String) -> Bool {
        tagPrefix.map(tag.hasPrefix) ?? true
    }
}

/// A version that can be downloaded.
public struct AvailableComponent: Sendable, Identifiable, Equatable, Hashable {
    public var id: String { "\(source.id)/\(version)" }
    public let source: ComponentSourceID
    public let kind: ComponentKind
    /// The installed version name, unique across sources.
    public let version: String
    public let assetName: String
    public let downloadURL: URL
    public let size: Int64
    /// From GitHub's asset digest. Nil for assets uploaded before GitHub published digests.
    public let sha256: String?
    public let published: Date
    public let releaseTag: String
    /// The version Schnitzel suggests: the first one from the default source.
    public var isRecommended: Bool = false
    /// Listed as supported by the source's maintainers (only for sources with a supported list).
    public var isSupported: Bool = true

    /// The asset name without its archive extension, as supported lists name it.
    var assetStem: String {
        for suffix in [".tar.xz", ".tar.gz", ".tar.bz2", ".tar", ".zip"] where assetName.hasSuffix(suffix) {
            return String(assetName.dropLast(suffix.count))
        }
        return assetName
    }
}

/// Identifies a source in `AvailableComponent` without carrying the whole definition.
public struct ComponentSourceID: Sendable, Hashable, Equatable {
    public let id: String
}

// MARK: - GitHub releases

/// Reads release lists from GitHub's public API (no account needed, 60 requests per hour).
public struct ReleaseCatalog: Sendable {
    /// Releases are read 100 at a time, at most this many pages per source.
    static let maxPages = 5

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

    /// Available versions from `source`, best first.
    public func available(from source: ComponentSource) async throws -> [AvailableComponent] {
        var available: [AvailableComponent] = []
        var next: URL? = URL(string: "https://api.github.com/repos/\(source.repository)/releases?per_page=100")
        var pages = 0
        while let url = next, pages < Self.maxPages {
            var request = URLRequest(url: url)
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
            available += try Self.parse(data, source: source)
            next = (response as? HTTPURLResponse)
                .flatMap { $0.value(forHTTPHeaderField: "Link") }
                .flatMap(Self.nextPage(fromLinkHeader:))
            pages += 1
        }
        available = Self.removingDuplicates(available).sorted { $0.published > $1.published }

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
        return Self.order(available, supported: supported, isDefaultSource: source.isDefault)
    }

    /// Puts supported versions first, in the maintainers' order, then the rest newest first.
    /// Marks the first one as recommended if the source is the default for its kind.
    static func order(_ available: [AvailableComponent], supported: [String]?,
                      isDefaultSource: Bool) -> [AvailableComponent] {
        var result: [AvailableComponent]
        if let supported {
            let listed = supported.compactMap { name in available.first { $0.assetStem == name } }
            let rest = available.filter { !supported.contains($0.assetStem) }.map { component -> AvailableComponent in
                var component = component
                component.isSupported = false
                return component
            }
            result = listed + rest
        } else {
            result = available
        }
        if isDefaultSource, !result.isEmpty { result[0].isRecommended = true }
        return result
    }

    static func parse(_ data: Data, source: ComponentSource) throws -> [AvailableComponent] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let releases = try decoder.decode([Release].self, from: data)

        var result: [AvailableComponent] = []
        for release in releases where !release.draft && !release.prerelease && source.matches(tag: release.tagName) {
            for asset in release.assets where source.matches(assetName: asset.name) {
                guard let version = source.version(fromAssetName: asset.name) else { continue }
                result.append(AvailableComponent(
                    source: ComponentSourceID(id: source.id), kind: source.kind, version: version,
                    assetName: asset.name, downloadURL: asset.browserDownloadUrl, size: asset.size,
                    sha256: asset.digest.flatMap(Self.sha256(fromDigest:)),
                    published: asset.updatedAt ?? release.publishedAt ?? .distantPast,
                    releaseTag: release.tagName))
            }
        }
        return removingDuplicates(result).sorted { $0.published > $1.published }
    }

    /// Keeps the first entry for each version.
    static func removingDuplicates(_ components: [AvailableComponent]) -> [AvailableComponent] {
        var seen = Set<String>()
        return components.filter { seen.insert($0.version).inserted }
    }

    /// The `rel="next"` URL from a GitHub `Link` header.
    static func nextPage(fromLinkHeader header: String) -> URL? {
        for part in header.split(separator: ",") where part.contains(#"rel="next""#) {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
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
