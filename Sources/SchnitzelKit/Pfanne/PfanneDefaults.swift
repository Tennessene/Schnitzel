//
//  PfanneDefaults.swift
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

/// Which installed components a new Pfanne gets. Shared by the app and `schnitzel-cli`,
/// so the CI checks create Pfannen exactly as the app does.
public enum PfanneDefaults {
    /// Why an installed component doesn't work in Schnitzel, if that is known.
    public static func knownProblem(of component: InstalledComponent) -> String? {
        component.componentSource?.knownProblems[component.version]
    }

    /// The version new Pfannen use: the newest one installed from the kind's default
    /// source, otherwise the newest one installed from anywhere. `installed` is the store's
    /// list for `kind`, newest first.
    public static func preferred(_ kind: ComponentKind, among installed: [InstalledComponent]) -> InstalledComponent? {
        let usable = installed.filter { knownProblem(of: $0) == nil }
        let defaultID = ComponentSource.defaultSource(for: kind)?.id
        return usable.first { $0.manifest.sourceID == defaultID } ?? usable.first
    }

    /// Whether a Pfanne with this engine needs the runtime-libraries component: only
    /// engines that don't bring their own libraries do.
    public static func needsLibraries(engine version: String?, engines: [InstalledComponent]) -> Bool {
        guard let version, let engine = engines.first(where: { $0.version == version }) else { return true }
        return !engine.includesRuntimeLibraries
    }

    /// The pins of a new Pfanne with `engine`: the preferred graphics components, and the
    /// runtime libraries only if the engine doesn't bring its own.
    public static func pins(engine: String, installed: (ComponentKind) -> [InstalledComponent]) -> ComponentPins {
        ComponentPins(
            engine: engine,
            dxvk: preferred(.dxvk, among: installed(.dxvk))?.version,
            dxmt: preferred(.dxmt, among: installed(.dxmt))?.version,
            d3dMetal: preferred(.d3dMetal, among: installed(.d3dMetal))?.version,
            libraries: needsLibraries(engine: engine, engines: installed(.engine))
                ? preferred(.libraries, among: installed(.libraries))?.version : nil)
    }
}

extension ComponentStore {
    /// The pins of a new Pfanne with `engine`, from what this store has installed.
    public func defaultPins(engine: String) -> ComponentPins {
        PfanneDefaults.pins(engine: engine) { installed($0) }
    }
}
