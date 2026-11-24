//
//  PfanneTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct PfanneStoreTests {
    @Test func createsListsAndRejectsDuplicates() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = PfanneStore(root: scratch.url.appending(path: "Pfannen"))

        let gta = try store.create(name: "  GTA V  ", engine: "E1")
        #expect(gta.name == "GTA V")
        #expect(gta.settings.pins.engine == "E1")
        #expect(!gta.isPrefixCreated)
        _ = try store.create(name: "Halo", engine: nil)
        #expect(store.list().map(\.name) == ["GTA V", "Halo"])

        #expect(throws: PfanneError.nameInUse("gta v")) { try store.create(name: "gta v", engine: nil) }
        for bad in ["", "   ", "a/b", "a:b", ".hidden"] {
            #expect(throws: PfanneError.invalidName) { try store.create(name: bad, engine: nil) }
        }
    }

    @Test func findsPfannenThatUseAComponent() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = PfanneStore(root: scratch.url.appending(path: "Pfannen"))
        var first = try store.create(name: "One", engine: "Old")
        first.settings.changePins { $0.engine = "New" }
        try first.save()
        _ = try store.create(name: "Two", engine: "New")

        #expect(store.pfannen(using: .engine, "New") == ["One", "Two"])
        #expect(store.pfannen(using: .engine, "Old") == ["One"]) // kept for rollback
        #expect(store.pfannen(using: .engine, "Other").isEmpty)
    }
}

@Suite struct WineRuntimeTests {
    func makeEngine(_ scratch: Scratch, store: ComponentStore) async throws -> InstalledComponent {
        try await store.install(
            .engine, version: "E1",
            archive: try await scratch.archive(try scratch.tree("e", ComponentStoreTests.sikarugirStyleEngine), name: "e.tar.gz"),
            source: "test")
    }

    @Test func preparesAnEnvironmentWithoutDLLOverrides() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let components = ComponentStore(root: scratch.url.appending(path: "Components"))
        let engine = try await makeEngine(scratch, store: components)
        let pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Test", engine: "E1")

        let runtime = try WineRuntime.prepare(for: pfanne, store: components)
        #expect(runtime.wineBinary == engine.root.appending(path: "bin/wine"))
        #expect(runtime.graphics.provider == .wineD3D)

        let env = runtime.environment()
        #expect(env["WINEPREFIX"] == pfanne.prefixURL.path)
        #expect(env["PATH"]?.hasPrefix(engine.root.appending(path: "bin").path) == true)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEDLLOVERRIDES"] == nil)
    }

    @Test func refusesMissingComponents() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let components = ComponentStore(root: scratch.url.appending(path: "Components"))
        let pfannen = PfanneStore(root: scratch.url.appending(path: "Pfannen"))

        let noEngine = try pfannen.create(name: "No engine", engine: nil)
        #expect(throws: PfanneError.engineNotPinned) { try WineRuntime.prepare(for: noEngine, store: components) }

        let missing = try pfannen.create(name: "Missing", engine: "Gone")
        #expect(throws: PfanneError.componentMissing(.engine, "Gone")) {
            try WineRuntime.prepare(for: missing, store: components)
        }

        _ = try await makeEngine(scratch, store: components)
        var wantsD3DMetal = try pfannen.create(name: "D3DMetal", engine: "E1")
        wantsD3DMetal.settings.graphics.layer = .d3dMetal
        #expect(throws: GraphicsError.notPinned(.d3dMetal)) {
            try WineRuntime.prepare(for: wantsD3DMetal, store: components)
        }
    }

    @Test func fingerprintChangesWithTheSettingsThatAreWrittenToThePrefix() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let components = ComponentStore(root: scratch.url.appending(path: "Components"))
        _ = try await makeEngine(scratch, store: components)
        var pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Test", engine: "E1")
        let before = try WineRuntime.prepare(for: pfanne, store: components).appliedFingerprint

        pfanne.settings.metal.metalHud = true // An env var: no prefix change needed.
        #expect(try WineRuntime.prepare(for: pfanne, store: components).appliedFingerprint == before)

        pfanne.settings.wine.windowsVersion = .win11
        #expect(try WineRuntime.prepare(for: pfanne, store: components).appliedFingerprint != before)
    }

    @Test func launchArgumentsMatchTheFileType() {
        #expect(Wine.launchArguments(for: URL(fileURLWithPath: "/g/Game.exe")) == ["/g/Game.exe"])
        #expect(Wine.launchArguments(for: URL(fileURLWithPath: "/g/Setup.MSI")) == ["msiexec", "/i", "/g/Setup.MSI"])
        #expect(Wine.launchArguments(for: URL(fileURLWithPath: "/g/run.bat")) == ["cmd", "/c", "/g/run.bat"])
        #expect(Wine.launchArguments(for: URL(fileURLWithPath: "/g/Game.lnk")) == ["start", "/unix", "/g/Game.lnk"])
    }
}

@Suite struct DXVKInstallerTests {
    @Test func installsReplacesAndRemovesDXVKRestoringWinesFiles() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let prefix = try scratch.tree("prefix", [
            "drive_c/windows/system32/d3d11.dll": "wine 64",
            "drive_c/windows/system32/kernel32.dll": "kernel",
            "drive_c/windows/syswow64/d3d11.dll": "wine 32"
        ])
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        func dxvk(_ version: String, _ tag: String) async throws -> InstalledComponent {
            let source = try scratch.tree("dxvk-\(version)", [
                "dxvk/x64/d3d11.dll": "\(tag) 64", "dxvk/x64/dxgi.dll": "\(tag) dxgi",
                "dxvk/x32/d3d11.dll": "\(tag) 32"
            ])
            return try await store.install(.dxvk, version: version,
                                           archive: try await scratch.archive(source, name: "\(version).tar.gz"),
                                           source: "test")
        }
        let first = try await dxvk("1", "dxvk1")
        let second = try await dxvk("2", "dxvk2")
        let system32 = prefix.appending(path: "drive_c/windows/system32")
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")

        try DXVKInstaller.sync(dxvk: first, prefix: prefix)
        #expect(scratch.contents(system32.appending(path: "d3d11.dll")) == "dxvk1 64")
        #expect(scratch.contents(system32.appending(path: "dxgi.dll")) == "dxvk1 dxgi")
        #expect(scratch.contents(syswow64.appending(path: "d3d11.dll")) == "dxvk1 32")
        #expect(DXVKInstaller.installedVersion(prefix: prefix) == "1")

        try DXVKInstaller.sync(dxvk: second, prefix: prefix)
        #expect(scratch.contents(system32.appending(path: "d3d11.dll")) == "dxvk2 64")
        #expect(DXVKInstaller.installedVersion(prefix: prefix) == "2")

        try DXVKInstaller.sync(dxvk: nil, prefix: prefix)
        #expect(scratch.contents(system32.appending(path: "d3d11.dll")) == "wine 64")
        #expect(scratch.contents(syswow64.appending(path: "d3d11.dll")) == "wine 32")
        #expect(!FileManager.default.fileExists(atPath: system32.appending(path: "dxgi.dll").path))
        #expect(scratch.contents(system32.appending(path: "kernel32.dll")) == "kernel")
        #expect(DXVKInstaller.installedVersion(prefix: prefix) == nil)
    }
}
