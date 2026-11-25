//
//  PfanneSetupTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

/// Engines whose `wine` and `wineserver` are shell scripts, to test setup without Wine.
struct FakeEngine {
    /// A `wine` that does nothing, like the Sikarugir 11.0_1 engine outside Sikarugir.
    static let doesNothing = "exit 1"

    /// A `wine` that creates a prefix the way `wineboot --init` does.
    static let createsPrefix = """
    if [ "$1" = "wineboot" ]; then
      mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64"
      i=0; while [ $i -lt 60 ]; do touch "$WINEPREFIX/drive_c/windows/system32/file$i.dll"; i=$((i+1)); done
      echo "WINE REGISTRY Version 2" > "$WINEPREFIX/system.reg"
      echo "WINE REGISTRY Version 2" > "$WINEPREFIX/user.reg"
    fi
    echo "fake wine ran: $*"
    exit 0
    """

    static let hangs = "sleep 30"

    static func install(_ script: String, scratch: Scratch, store: ComponentStore, version: String = "Fake") async throws {
        let source = scratch.url.appending(path: "engine-\(version)")
        let bin = source.appending(path: "wswine.bundle/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appending(path: "wswine.bundle/lib/wine/x86_64-windows"),
                                                withIntermediateDirectories: true)
        for (name, body) in [("wine", script), ("wineserver", "exit 0")] {
            let file = bin.appending(path: name)
            try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        _ = try await store.install(.engine, version: version,
                                    archive: try await scratch.archive(source, name: "\(version).tar.gz"), source: "test")
    }
}

@Suite(.enabled(if: Rosetta.canRunWine, "PfanneSetup checks for Rosetta first on Apple Silicon"))
struct PfanneSetupTests {
    @Test func reportsAFailedSetupWithTheReasonAndLog() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        try await FakeEngine.install(FakeEngine.doesNothing, scratch: scratch, store: store)
        let pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Broken-\(UUID().uuidString.prefix(6))", engine: "Fake")
        defer { try? FileManager.default.removeItem(at: pfanne.logsFolder) }

        do {
            try await PfanneSetup(store: store).createPrefix(for: pfanne)
            Issue.record("createPrefix should have thrown")
        } catch PfanneError.prefixNotCreated(let reason, let wine, _, let log) {
            #expect(reason.contains("didn't create"))
            #expect(wine?.contains("exit status 1") == true)
            #expect(log != nil)
        }
        #expect(pfanne.prefixState == .missing)
        // Running a program refuses and asks for a repair instead of half-working.
        await #expect(throws: PfanneError.self) { try await PfanneSetup(store: store).applyIfNeeded(to: pfanne) }
    }

    @Test func createsAPrefixAndAppliesTheSettings() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        try await FakeEngine.install(FakeEngine.createsPrefix, scratch: scratch, store: store)
        let pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Good-\(UUID().uuidString.prefix(6))", engine: "Fake")
        defer { try? FileManager.default.removeItem(at: pfanne.logsFolder) }

        try await PfanneSetup(store: store).createPrefix(for: pfanne)
        #expect(pfanne.prefixState == .ready)
        #expect(PfanneSetup.appliedState(of: pfanne) != nil)
        // Nothing left to apply until a setting changes.
        _ = try await PfanneSetup(store: store).applyIfNeeded(to: pfanne)
    }

    @Test func repairsAPrefixWhoseDriveCIsMissing() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        try await FakeEngine.install(FakeEngine.createsPrefix, scratch: scratch, store: store)
        let pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Repair-\(UUID().uuidString.prefix(6))", engine: "Fake")
        defer { try? FileManager.default.removeItem(at: pfanne.logsFolder) }
        try await PfanneSetup(store: store).createPrefix(for: pfanne)

        try FileManager.default.removeItem(at: pfanne.driveC)
        #expect(pfanne.prefixState == .incomplete("the C: drive (drive_c) is missing"))
        try await PfanneSetup(store: store).repairPrefix(for: pfanne)
        #expect(pfanne.prefixState == .ready)
    }

    @Test func stopsWineThatHangs() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        try await FakeEngine.install(FakeEngine.hangs, scratch: scratch, store: store)
        let pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Hang-\(UUID().uuidString.prefix(6))", engine: "Fake")
        defer { try? FileManager.default.removeItem(at: pfanne.logsFolder) }
        let runtime = try WineRuntime.prepare(for: pfanne, store: store)

        let start = Date()
        await #expect(throws: WineError.self) {
            try await Wine.runWine(["wineboot", "--init"], runtime: runtime, timeout: .seconds(1))
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

@Suite struct PrefixStateTests {
    @Test func tellsMissingIncompleteAndReadyApart() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "State", engine: nil)
        #expect(pfanne.prefixState == .missing)

        try FileManager.default.createDirectory(at: pfanne.prefixURL, withIntermediateDirectories: true)
        try "x".write(to: pfanne.prefixURL.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        try "x".write(to: pfanne.prefixURL.appending(path: "user.reg"), atomically: true, encoding: .utf8)
        #expect(pfanne.prefixState == .incomplete("the C: drive (drive_c) is missing"))

        let system32 = pfanne.driveC.appending(path: "windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        #expect(pfanne.prefixState == .incomplete("the Windows system folder is empty or nearly empty"))

        for index in 0..<60 { FileManager.default.createFile(atPath: system32.appending(path: "f\(index).dll").path, contents: nil) }
        #expect(pfanne.prefixState == .ready)
        #expect(pfanne.isPrefixCreated)
    }

    @Test func picksTheMostUsefulErrorLines() {
        let output = ["wine: created the configuration directory", "noise", "0024:err:environ:run_wineboot failed to start wineboot 1", "more noise"]
        #expect(WineError.keyLines(in: output) == ["wine: created the configuration directory", "0024:err:environ:run_wineboot failed to start wineboot 1"])
        #expect(WineError.keyLines(in: ["a", "b"]) == ["a", "b"])
    }

    @Test func neverRecommendsAKnownBrokenVersion() {
        func available(_ version: String) -> AvailableComponent {
            AvailableComponent(source: ComponentSourceID(id: "sikarugir-engines"), kind: .engine, version: version,
                               assetName: version + ".tar.xz", downloadURL: URL(string: "https://example.com")!,
                               size: 0, sha256: nil, published: .now, releaseTag: "v1.0",
                               knownProblem: ComponentSource.sikarugirEngines.knownProblems[version])
        }
        let ordered = ReleaseCatalog.order(
            [available("sikarugir-engine-WS12WineSikarugir11.0_1"), available("sikarugir-engine-WS12WineSikarugir10.0_8")],
            supported: nil, isDefaultSource: true)
        #expect(ordered.first { $0.isRecommended }?.version == "sikarugir-engine-WS12WineSikarugir10.0_8")
        #expect(ordered[0].knownProblem != nil)
    }
}

/// End-to-end with a real engine. Runs only with SCHNITZEL_REAL_ENGINE_ARCHIVE and
/// SCHNITZEL_TEMPLATE_ARCHIVE set; set SCHNITZEL_REAL_ENGINE_EXPECT=fail for an engine
/// that is expected not to work.
@Suite struct RealEngineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCHNITZEL_REAL_ENGINE_ARCHIVE"] != nil))
    func createsAPfanneWithARealEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        _ = try await store.install(.engine, version: "real-engine",
                                    archive: URL(fileURLWithPath: env["SCHNITZEL_REAL_ENGINE_ARCHIVE"]!), source: "test")
        if let template = env["SCHNITZEL_TEMPLATE_ARCHIVE"] {
            _ = try await store.install(.libraries, version: "real-libraries",
                                        archive: URL(fileURLWithPath: template), source: "test")
        }
        var pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen"))
            .create(name: "Real-\(UUID().uuidString.prefix(6))", engine: "real-engine")
        pfanne.settings.pins.libraries = env["SCHNITZEL_TEMPLATE_ARCHIVE"] == nil ? nil : "real-libraries"
        try pfanne.save()
        defer { print("Logs: \(pfanne.logsFolder.path)") }

        let start = Date()
        if env["SCHNITZEL_REAL_ENGINE_EXPECT"] == "fail" {
            do {
                try await PfanneSetup(store: store).createPrefix(for: pfanne)
                Issue.record("expected the engine to fail")
            } catch {
                print("Failed as expected after \(Int(Date().timeIntervalSince(start))) s:\n\(error.localizedDescription)")
            }
        } else {
            try await PfanneSetup(store: store).createPrefix(for: pfanne)
            print("Created in \(Int(Date().timeIntervalSince(start))) s, state \(pfanne.prefixState)")
            #expect(pfanne.prefixState == .ready)
            let runtime = try WineRuntime.prepare(for: pfanne, store: store)
            let version = try await Wine.winVersion(runtime: runtime)
            print("Windows version reported by winecfg: \(String(describing: version))")
            #expect(version == .win10)
            try? await Wine.kill(runtime: runtime)
        }
    }
}

@Suite struct RosettaTests {
    // The CI program check found this on its first run (November 25, 2026): Schnitzel refused
    // to create a Pfanne on an Intel Mac because Rosetta wasn't installed, which Intel Macs
    // neither need nor can install.
    @Test func onlyAppleSiliconNeedsRosetta() {
        #expect(Rosetta.canRunWine(appleSilicon: false, rosettaInstalled: false))
        #expect(Rosetta.canRunWine(appleSilicon: true, rosettaInstalled: true))
        #expect(!Rosetta.canRunWine(appleSilicon: true, rosettaInstalled: false))
    }
}
