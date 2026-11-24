//
//  LocalInstallTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

/// "Install from file…": version naming, SHA256SUMS checks, and matching a later
/// published release by SHA-256.
@Suite struct LocalInstallTests {
    static let name = "schnitzel-engine-26.3.0-1.tar.xz"

    /// An engine like Schnitzel's own, with its own libraries.
    static var ownEngine: [String: String] {
        var files: [String: String] = [
            "schnitzel-engine-26.3.0-1/bin/wine": "loader",
            "schnitzel-engine-26.3.0-1/bin/wineserver": "server",
            "schnitzel-engine-26.3.0-1/lib/wine/x86_64-unix/ntdll.so": "ntdll",
            "schnitzel-engine-26.3.0-1/version": "26.3.0-1\n"
        ]
        for library in RuntimeLibraries.bundledInEngine {
            files["schnitzel-engine-26.3.0-1/lib/\(library)"] = "library"
        }
        return files
    }

    /// Writes the engine archive into its own folder (like a Downloads folder) and returns it.
    static func archive(in scratch: Scratch, folder: String = "downloads", name: String = name,
                        files: [String: String] = ownEngine) async throws -> URL {
        let built = try await scratch.archive(try scratch.tree("src-\(folder)", files), name: "built-\(folder).tar.gz")
        let downloads = scratch.url.appending(path: folder)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let destination = downloads.appending(path: name)
        try FileManager.default.moveItem(at: built, to: destination)
        return destination
    }

    static func writeSums(_ text: String, next archive: URL) throws {
        try Data(text.utf8).write(to: archive.deletingLastPathComponent().appending(path: "SHA256SUMS"))
    }

    @Test func namesTheVersionFromTheFileNameLikeADownload() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await Self.archive(in: scratch)
        let local = try LocalArchive.inspect(archive, kind: .engine)
        #expect(local.version == "schnitzel-engine-26.3.0-1")
        #expect(local.version == ComponentSource.schnitzelEngines.version(fromAssetName: Self.name))
        #expect(local.source == .schnitzelEngines)
        #expect(local.sha256 == (try Command.sha256(of: archive)))

        let renamed = try await Self.archive(in: scratch, folder: "renamed", name: "engine (1).tar.xz")
        #expect(throws: LocalInstallError.self) { try LocalArchive.inspect(renamed, kind: .engine) }
        // The same file isn't a DXVK archive either.
        #expect(throws: LocalInstallError.self) { try LocalArchive.inspect(archive, kind: .dxvk) }
    }

    @Test func checksAgainstSHA256SUMSAndInstallsThroughTheNormalPath() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await Self.archive(in: scratch)
        let hash = try Command.sha256(of: archive)
        try Self.writeSums("\(hash)  \(Self.name)\n\(String(repeating: "1", count: 64))  crossover-sources-26.3.0.tar.gz\n", next: archive)

        let local = try LocalArchive.inspect(archive, kind: .engine)
        #expect(local.checksum == .verified(against: archive.deletingLastPathComponent().appending(path: "SHA256SUMS")))

        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let installed = try await store.installLocal(local)
        #expect(installed.version == "schnitzel-engine-26.3.0-1")
        #expect(installed.manifest.sourceID == ComponentSource.schnitzelEngines.id)
        #expect(installed.manifest.sha256 == hash)
        #expect(installed.manifest.installedFromFile == Self.name)
        #expect(installed.manifest.notes.contains { $0.contains(Self.name) && $0.contains(hash) && $0.contains("SHA256SUMS") })
        #expect(installed.manifest.rootPath == "schnitzel-engine-26.3.0-1")
        #expect(installed.includesRuntimeLibraries)
        // What's on disk says the same.
        let onDisk = try #require(store.component(.engine, "schnitzel-engine-26.3.0-1"))
        #expect(onDisk.manifest.installedFromFile == Self.name && onDisk.manifest.notes == installed.manifest.notes)
    }

    @Test func refusesAMismatchAndInstallsNothing() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await Self.archive(in: scratch)
        try Self.writeSums("\(String(repeating: "0", count: 64)) *\(Self.name)\n", next: archive)
        #expect(throws: ComponentError.self) { try LocalArchive.inspect(archive, kind: .engine) }

        // A checksum file that doesn't list the archive is refused too.
        try Self.writeSums("\(String(repeating: "0", count: 64))  other.tar.xz\n", next: archive)
        #expect(throws: LocalInstallError.notInChecksumFile(Self.name)) { try LocalArchive.inspect(archive, kind: .engine) }

        try Self.writeSums("not a checksum file\n", next: archive)
        #expect(throws: LocalInstallError.unreadableChecksumFile) { try LocalArchive.inspect(archive, kind: .engine) }
    }

    @Test func withoutSHA256SUMSTheUserMustConfirm() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await Self.archive(in: scratch)
        let local = try LocalArchive.inspect(archive, kind: .engine)
        #expect(local.checksum == .unverified)

        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        await #expect(throws: LocalInstallError.needsConfirmation(local.sha256)) {
            try await store.installLocal(local)
        }
        #expect(store.installed(.engine).isEmpty)

        let installed = try await store.installLocal(local, confirmedUnverified: true)
        #expect(installed.manifest.notes.contains { $0.contains("confirmed by you") && $0.contains(local.sha256) })
    }

    @Test func parsesShasumOutput() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let parsed = try LocalArchive.parseChecksums("\(a)  release/one.tar.xz\n\n\(b) *two.tar.gz\n")
        #expect(parsed == ["one.tar.xz": a, "two.tar.gz": b.lowercased()])
    }

    @Test func recognizesThePublishedReleaseBySHA256() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await Self.archive(in: scratch)
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let local = try LocalArchive.inspect(archive, kind: .engine)
        let installed = try await store.installLocal(local, confirmedUnverified: true)

        func published(sha256: String?) -> AvailableComponent {
            AvailableComponent(
                source: ComponentSourceID(id: ComponentSource.schnitzelEngines.id), kind: .engine,
                version: "schnitzel-engine-26.3.0-1", assetName: Self.name,
                downloadURL: URL(string: "https://github.com/Tennessene/Schnitzel/releases/download/engine-26.3.0-1/\(Self.name)")!,
                size: 1, sha256: sha256, published: .now, releaseTag: "engine-26.3.0-1")
        }

        // A different file under the same name is flagged and left alone.
        let other = published(sha256: String(repeating: "f", count: 64))
        #expect(ComponentMatch.match(other, installed: installed) == .differentFile)
        #expect(try store.recordPublished(other) == nil)
        #expect(store.component(.engine, installed.version)?.manifest.source == installed.manifest.source)

        // The same file is the installed component: no duplicate, same version name.
        let same = published(sha256: local.sha256)
        #expect(ComponentMatch.match(same, installed: installed) == .sameFile)
        #expect(ComponentMatch.match(same, installed: nil) == .notInstalled)
        let recorded = try #require(try store.recordPublished(same))
        #expect(recorded.version == installed.version)
        #expect(recorded.manifest.source == same.downloadURL.absoluteString)
        #expect(recorded.manifest.installedFromFile == Self.name)
        #expect(recorded.manifest.notes.contains { $0.contains("engine-26.3.0-1") })
        #expect(store.installed(.engine).count == 1)
        // Only once.
        #expect(try store.recordPublished(same) == nil)

        // Downloading or installing it again is refused instead of creating a second copy.
        await #expect(throws: ComponentError.alreadyInstalled(.engine, installed.version)) {
            try await store.installLocal(local, confirmedUnverified: true)
        }
        let changed = try await Self.archive(in: scratch, folder: "changed",
                                             files: Self.ownEngine.merging(["schnitzel-engine-26.3.0-1/extra": "x"]) { $1 })
        await #expect(throws: LocalInstallError.differentFileInstalled(installed.version)) {
            try await store.installLocal(try LocalArchive.inspect(changed, kind: .engine), confirmedUnverified: true)
        }
    }

    @Test func pfannenPinnedToItKeepWorking() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await Self.archive(in: scratch)
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let installed = try await store.installLocal(try LocalArchive.inspect(archive, kind: .engine), confirmedUnverified: true)
        let pin = installed.version
        _ = try store.recordPublished(AvailableComponent(
            source: ComponentSourceID(id: ComponentSource.schnitzelEngines.id), kind: .engine, version: pin,
            assetName: Self.name, downloadURL: URL(string: "https://example.com/\(Self.name)")!, size: 1,
            sha256: installed.manifest.sha256, published: .now, releaseTag: "engine-26.3.0-1"))
        // A Pfanne's pin is the version name, which still resolves to the same folder.
        let resolved = try store.require(.engine, pin)
        #expect(resolved.folder == installed.folder)
        #expect(resolved.includesRuntimeLibraries)
    }
}
