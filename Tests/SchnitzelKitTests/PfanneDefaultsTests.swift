//
//  PfanneDefaultsTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct PfanneDefaultsTests {
    func component(_ kind: ComponentKind, _ version: String, source: ComponentSource?) -> InstalledComponent {
        InstalledComponent(
            manifest: ComponentManifest(kind: kind, version: version, source: "test", sourceID: source?.id),
            folder: URL(filePath: "/nonexistent/\(kind.rawValue)/\(version)"))
    }

    @Test func prefersTheDefaultSourceAndSkipsKnownProblems() {
        let broken = component(.engine, "sikarugir-engine-WS12WineSikarugir11.0_1", source: .sikarugirEngines)
        let working = component(.engine, "sikarugir-engine-WS12WineSikarugir10.0_8", source: .sikarugirEngines)
        let other = component(.engine, "wine-11.0", source: .wineHQEngines)
        // Newest first, as the store lists them.
        #expect(PfanneDefaults.preferred(.engine, among: [other, broken, working])?.version == working.version)
        #expect(PfanneDefaults.preferred(.engine, among: [other, broken])?.version == other.version)
        #expect(PfanneDefaults.preferred(.engine, among: [broken]) == nil)
    }

    @Test func pinsTheGraphicsComponentsAndLibrariesOnlyWhenNeeded() {
        let engine = component(.engine, "schnitzel-engine-26.3.0-3", source: .schnitzelEngines)
        let installed: [ComponentKind: [InstalledComponent]] = [
            .engine: [engine],
            .dxvk: [component(.dxvk, "dxvk-1", source: .dxvk)],
            .dxmt: [component(.dxmt, "dxmt-1", source: .dxmt)],
            .libraries: [component(.libraries, "libs-1", source: .sikarugirTemplateLibraries)]
        ]
        let pins = PfanneDefaults.pins(engine: engine.version) { installed[$0] ?? [] }
        #expect(pins == ComponentPins(engine: engine.version, dxvk: "dxvk-1", dxmt: "dxmt-1", d3dMetal: nil,
                                      libraries: "libs-1"))
        // An engine that isn't installed can't bring libraries, so it gets them.
        #expect(PfanneDefaults.needsLibraries(engine: "missing", engines: [engine]))
    }
}
