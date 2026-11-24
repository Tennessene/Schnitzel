//
//  PfanneSettingsTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct PfanneSettingsTests {
    @Test func defaultsMatchThePlan() {
        let settings = PfanneSettings(name: "Test")
        #expect(settings.wine.windowsVersion == .win10)
        #expect(settings.wine.enhancedSync == .msync)
        #expect(settings.graphics.layer == .auto)
        #expect(settings.metal.dlssEnabled == false)
        #expect(settings.wine.highResolutionMode == false)
    }

    @Test func roundTripsThroughAPropertyList() throws {
        var settings = PfanneSettings(name: "GTA V Pfanne")
        settings.wine.windowsVersion = .win11
        settings.graphics.layer = .dxvk
        settings.changePins { $0.engine = "WS12WineSikarugir11.0_1"; $0.dxvk = "v1.10.3" }

        let url = FileManager.default.temporaryDirectory.appending(path: "pfanne-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try settings.encode(to: url)
        #expect(try PfanneSettings.decode(from: url) == settings)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["name": "Old"], format: .xml, options: 0)
        let settings = try PropertyListDecoder().decode(PfanneSettings.self, from: data)
        #expect(settings.name == "Old")
        #expect(settings.wine.windowsVersion == .win10)
        #expect(settings.pins == ComponentPins())
    }

    @Test func refusesFilesFromANewerSchnitzel() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["name": "Future", "fileVersion": 99], format: .xml, options: 0)
        #expect(throws: PfanneError.newerFileVersion(99)) {
            try PropertyListDecoder().decode(PfanneSettings.self, from: data)
        }
    }

    @Test func changingPinsKeepsThePreviousOnesForRollback() {
        var settings = PfanneSettings(name: "Test")
        settings.changePins { $0.engine = "A" }
        settings.changePins { $0.engine = "B" }
        #expect(settings.pins.engine == "B")
        #expect(settings.previousPins?.engine == "A")

        let rolledBack = settings.rollBack()
        #expect(rolledBack)
        #expect(settings.pins.engine == "A")
        #expect(settings.previousPins?.engine == "B")
    }

    @Test func unchangedPinsDoNotOverwriteRollback() {
        var settings = PfanneSettings(name: "Test")
        settings.changePins { $0.engine = "A" }
        settings.changePins { $0.engine = "B" }
        settings.changePins { $0.engine = "B" }
        #expect(settings.previousPins?.engine == "A")
    }

    @Test func environmentNeverOverridesDLLs() {
        for sync in EnhancedSync.allCases {
            for layer in GraphicsLayer.allCases {
                var settings = PfanneSettings(name: "Test")
                settings.wine.enhancedSync = sync
                settings.graphics.layer = layer
                settings.metal.metalHud = true
                var env: [String: String] = [:]
                settings.environmentVariables(wineEnv: &env)
                #expect(env["WINEDLLOVERRIDES"] == nil)
            }
        }
    }

    @Test func msyncAlsoSetsESyncForD3DMetal() {
        var env: [String: String] = [:]
        PfanneSettings(name: "Test").environmentVariables(wineEnv: &env)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == "1")
    }
}

@Suite struct GraphicsTests {
    @Test func autoPrefersD3DMetalThenDXMT() throws {
        let all = ComponentPins(engine: "E", dxvk: "V", dxmt: "M", d3dMetal: "D")
        #expect(try ResolvedGraphics.resolve(layer: .auto, pins: all).provider == .d3dMetal)

        let noD3DMetal = ComponentPins(engine: "E", dxvk: "V", dxmt: "M")
        #expect(try ResolvedGraphics.resolve(layer: .auto, pins: noD3DMetal).provider == .dxmt)

        let nothing = ComponentPins(engine: "E")
        let resolved = try ResolvedGraphics.resolve(layer: .auto, pins: nothing)
        #expect(resolved == ResolvedGraphics(provider: .wineD3D, defaultSlot: .builtin, installsDXVK: false))
    }

    @Test func layersThatNeedAMissingComponentThrow() {
        let pins = ComponentPins(engine: "E")
        #expect(throws: GraphicsError.notPinned(.dxvk)) { try ResolvedGraphics.resolve(layer: .dxvk, pins: pins) }
        #expect(throws: GraphicsError.notPinned(.d3dMetal)) { try ResolvedGraphics.resolve(layer: .d3dMetal, pins: pins) }
        #expect(throws: GraphicsError.notPinned(.dxmt)) { try ResolvedGraphics.resolve(layer: .dxmt, pins: pins) }
    }

    @Test func dxvkLayerKeepsTheBuiltinProviderForLaterPerGameUse() throws {
        let pins = ComponentPins(engine: "E", dxvk: "V", d3dMetal: "D")
        let resolved = try ResolvedGraphics.resolve(layer: .dxvk, pins: pins)
        #expect(resolved == ResolvedGraphics(provider: .d3dMetal, defaultSlot: .native, installsDXVK: true))
    }
}

@Suite struct RegistryPlanTests {
    let dxvkDLLs = ["d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "dxgi"]

    @Test func builtinSlotSetsEveryGraphicsDLLToBuiltin() {
        let graphics = ResolvedGraphics(provider: .d3dMetal, defaultSlot: .builtin, installsDXVK: true)
        let plan = PfanneRegistry.plan(graphics: graphics, dxvkDLLs: dxvkDLLs, highResolutionMode: false)
        for dll in PfanneRegistry.managedGraphicsDLLs {
            #expect(plan.value(PfanneRegistry.dllOverridesKey, dll) == .string("builtin"))
        }
    }

    @Test func nativeSlotUsesDXVKOnlyForItsOwnDLLs() {
        let graphics = ResolvedGraphics(provider: .wineD3D, defaultSlot: .native, installsDXVK: true)
        let plan = PfanneRegistry.plan(graphics: graphics, dxvkDLLs: dxvkDLLs, highResolutionMode: false)
        #expect(plan.value(PfanneRegistry.dllOverridesKey, "d3d11") == .string("native,builtin"))
        #expect(plan.value(PfanneRegistry.dllOverridesKey, "dxgi") == .string("native,builtin"))
        #expect(plan.value(PfanneRegistry.dllOverridesKey, "d3d12") == .string("builtin"))
    }

    @Test func highResolutionModeSetsRetinaAndDPI() {
        let graphics = ResolvedGraphics(provider: .wineD3D, defaultSlot: .builtin, installsDXVK: false)
        let on = PfanneRegistry.plan(graphics: graphics, dxvkDLLs: [], highResolutionMode: true)
        #expect(on.value(PfanneRegistry.macDriverKey, "RetinaMode") == .string("y"))
        #expect(on.value(PfanneRegistry.desktopKey, "LogPixels") == .dword(192))
        let off = PfanneRegistry.plan(graphics: graphics, dxvkDLLs: [], highResolutionMode: false)
        #expect(off.value(PfanneRegistry.macDriverKey, "RetinaMode") == .string("n"))
        #expect(off.value(PfanneRegistry.desktopKey, "LogPixels") == .dword(96))
    }

    @Test func writesAValidRegFile() {
        var plan = RegistryPlan()
        plan.set(#"HKEY_CURRENT_USER\Software\Test"#, "Path", .string(#"C:\Games\"Quoted""#))
        plan.set(#"HKEY_CURRENT_USER\Software\Test"#, "Count", .dword(0xC0))
        plan.set(#"HKEY_CURRENT_USER\Software\Test"#, "Old", .delete)
        #expect(plan.regFileText == #"""
        REGEDIT4

        [HKEY_CURRENT_USER\Software\Test]
        "Path"="C:\\Games\\\"Quoted\""
        "Count"=dword:000000c0
        "Old"=-

        """#)
    }
}
