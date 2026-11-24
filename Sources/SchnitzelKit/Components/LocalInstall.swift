//
//  LocalInstall.swift
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

/// A component archive on disk that the user picked with "Install from file…", for example
/// `schnitzel-engine-26.3.0-1.tar.xz` downloaded from a draft release.
///
/// It is installed exactly like a download: the version name comes from the file name
/// through the matching `ComponentSource`, and the archive goes through
/// `ComponentStore.install`. Only where the file comes from and how its SHA-256 is checked
/// differ.
public struct LocalArchive: Sendable, Equatable {
    /// The name of the checksum file looked for next to the archive.
    public static let checksumFileName = "SHA256SUMS"

    public enum Checksum: Sendable, Equatable {
        /// Matches the entry in the `SHA256SUMS` file next to the archive.
        case verified(against: URL)
        /// No `SHA256SUMS` next to the archive: the user has to confirm the SHA-256.
        case unverified
    }

    public let url: URL
    public let kind: ComponentKind
    /// The source whose asset names this file matches; it decides the version name.
    public let source: ComponentSource
    /// The installed version name, as a download of the same file would get it.
    public let version: String
    public let sha256: String
    public let checksum: Checksum

    public var fileName: String { url.lastPathComponent }

    /// Reads the archive: finds its version from the file name, computes its SHA-256 and
    /// checks it against a `SHA256SUMS` file in the same folder, if there is one.
    /// Throws if the name matches no source of `kind`, or if the checksum file disagrees
    /// or doesn't list the archive.
    public static func inspect(_ url: URL, kind: ComponentKind) throws -> LocalArchive {
        let name = url.lastPathComponent
        guard let source = ComponentSource.sources(for: kind).first(where: { $0.matches(assetName: name) }),
              let version = source.version(fromAssetName: name) else {
            throw LocalInstallError.unrecognizedFileName(kind, name)
        }
        try ComponentStore.validate(versionName: version)
        let sha256 = try Command.sha256(of: url)

        let sums = url.deletingLastPathComponent().appending(path: checksumFileName)
        guard FileManager.default.fileExists(atPath: sums.path) else {
            return LocalArchive(url: url, kind: kind, source: source, version: version, sha256: sha256, checksum: .unverified)
        }
        let listed = try parseChecksums(String(contentsOf: sums, encoding: .utf8))
        guard let expected = listed[name] else {
            throw LocalInstallError.notInChecksumFile(name)
        }
        guard expected == sha256 else {
            throw ComponentError.checksumMismatch(expected: expected, actual: sha256)
        }
        return LocalArchive(url: url, kind: kind, source: source, version: version, sha256: sha256,
                            checksum: .verified(against: sums))
    }

    /// Parses `shasum -a 256` output: `<64 hex>  <name>` (or `<hex> *<name>` in binary mode).
    /// Returns file name → lowercase SHA-256. Paths are reduced to their file name.
    static func parseChecksums(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { throw LocalInstallError.unreadableChecksumFile }
            let hash = parts[0].lowercased()
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit), !file.isEmpty else {
                throw LocalInstallError.unreadableChecksumFile
            }
            result[(file as NSString).lastPathComponent] = hash
        }
        return result
    }
}

extension ComponentStore {
    /// Installs a picked archive through the same path as a download. `confirmedUnverified`
    /// must be true for an archive without a `SHA256SUMS` file: the user has seen its
    /// SHA-256 and confirmed it.
    public func installLocal(_ archive: LocalArchive, confirmedUnverified: Bool = false) async throws -> InstalledComponent {
        if archive.checksum == .unverified && !confirmedUnverified {
            throw LocalInstallError.needsConfirmation(archive.sha256)
        }
        if let existing = component(archive.kind, archive.version) {
            throw existing.manifest.sha256 == archive.sha256
                ? ComponentError.alreadyInstalled(archive.kind, archive.version)
                : LocalInstallError.differentFileInstalled(archive.version)
        }
        var installed = try await install(
            archive.kind, version: archive.version, archive: archive.url,
            source: "Installed from the local file \(archive.fileName)",
            sourceID: archive.source.id, sha256: archive.sha256)
        installed.manifest.installedFromFile = archive.fileName
        switch archive.checksum {
        case .verified:
            installed.manifest.notes.append("Installed from the local file \(archive.fileName), SHA-256 \(archive.sha256), checked against \(LocalArchive.checksumFileName)")
        case .unverified:
            installed.manifest.notes.append("Installed from the local file \(archive.fileName), SHA-256 \(archive.sha256), confirmed by you (no \(LocalArchive.checksumFileName) file next to it)")
        }
        try saveManifest(of: installed)
        return installed
    }

    /// Records that a component installed from a file is the same file as a published
    /// download (same version name and SHA-256), so it counts as that download from now
    /// on. The version name, and so every Pfanne's pin, stays the same.
    @discardableResult
    public func recordPublished(_ available: AvailableComponent) throws -> InstalledComponent? {
        guard var installed = component(available.kind, available.version),
              installed.manifest.installedFromFile != nil,
              ComponentMatch.match(available, installed: installed) == .sameFile,
              installed.manifest.source != available.downloadURL.absoluteString else { return nil }
        installed.manifest.source = available.downloadURL.absoluteString
        installed.manifest.notes.append("Matches the published release \(available.releaseTag) (same SHA-256)")
        try saveManifest(of: installed)
        return installed
    }

    /// Writes a changed manifest back next to the component's files.
    func saveManifest(of component: InstalledComponent) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(component.manifest).write(to: component.folder.appending(path: Self.manifestName))
    }
}

/// How a downloadable version relates to what is installed under the same version name.
public enum ComponentMatch: Sendable, Equatable {
    case notInstalled
    /// Installed, and the file is the same (same SHA-256), or either SHA-256 is unknown.
    case sameFile
    /// Installed under the same name, but from a different file. Never replaced silently.
    case differentFile

    public static func match(_ available: AvailableComponent, installed: InstalledComponent?) -> ComponentMatch {
        guard let installed, installed.version == available.version, installed.kind == available.kind else {
            return .notInstalled
        }
        guard let published = available.sha256, let local = installed.manifest.sha256 else { return .sameFile }
        return published == local ? .sameFile : .differentFile
    }
}

public enum LocalInstallError: Error, LocalizedError, Equatable {
    case unrecognizedFileName(ComponentKind, String)
    case notInChecksumFile(String)
    case unreadableChecksumFile
    case needsConfirmation(String)
    case differentFileInstalled(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFileName(let kind, let name):
            let examples = ComponentSource.sources(for: kind).map(\.displayName).joined(separator: ", ")
            return "“\(name)” isn't named like a \(kind.displayName) download (\(examples)). Keep the file name it had on GitHub, for example schnitzel-engine-26.3.0-1.tar.xz."
        case .notInChecksumFile(let name):
            return "The \(LocalArchive.checksumFileName) file next to “\(name)” doesn't list it, so it can't be checked. Nothing was installed."
        case .unreadableChecksumFile:
            return "The \(LocalArchive.checksumFileName) file next to the archive can't be read. Nothing was installed."
        case .needsConfirmation(let sha256):
            return "There's no \(LocalArchive.checksumFileName) file next to the archive. Confirm its SHA-256 (\(sha256)) first."
        case .differentFileInstalled(let version):
            return "\(version) is already installed from a different file (the SHA-256 differs). Nothing was installed. Remove the installed one first if you really want to replace it."
        }
    }
}
