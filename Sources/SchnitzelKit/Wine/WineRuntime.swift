//
//  WineRuntime.swift
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

/// Everything needed to run Wine for one Pfanne: the engine folder to run from (with the
/// graphics overlay applied), the resolved graphics choice and the environment.
public struct WineRuntime: Sendable {
    public let pfanne: Pfanne
    public let engine: InstalledComponent
    /// The folder holding `bin/` and `lib/`: the engine itself or an assembly.
    public let engineRoot: URL
    public let wineBinary: URL
    public let wineserverBinary: URL
    public let graphics: ResolvedGraphics
    public let dxvk: InstalledComponent?
    public let overlay: InstalledComponent?
    /// Shared libraries Wine loads at runtime (temporary reference component for now).
    public let libraries: InstalledComponent?

    /// Resolves a Pfanne's pins against the store and builds the engine assembly if needed.
    public static func prepare(for pfanne: Pfanne, store: ComponentStore) throws -> WineRuntime {
        let pins = pfanne.settings.pins
        guard let engineVersion = pins.engine else { throw PfanneError.engineNotPinned }
        let engine = try store.require(.engine, engineVersion)
        let graphics = try ResolvedGraphics.resolve(layer: pfanne.settings.graphics.layer, pins: pins)

        var overlay: InstalledComponent?
        if let kind = graphics.provider.component, let version = pins.version(of: kind) {
            overlay = try store.require(kind, version)
        }
        let dxvk = try graphics.installsDXVK ? pins.dxvk.map { try store.require(.dxvk, $0) } : nil
        let libraries = try pins.libraries.map { try store.require(.libraries, $0) }

        let root = try store.engineRoot(engine: engine, provider: graphics.provider, overlay: overlay)
        let binary = root.appending(path: engine.manifest.wineBinary ?? "bin/wine")
        return WineRuntime(
            pfanne: pfanne, engine: engine, engineRoot: root, wineBinary: binary,
            wineserverBinary: root.appending(path: "bin/wineserver"),
            graphics: graphics, dxvk: dxvk, overlay: overlay, libraries: libraries)
    }

    /// The environment for Wine processes in this Pfanne.
    ///
    /// Built from scratch rather than inherited, so the user's shell settings can't change
    /// how games run. `WINEDLLOVERRIDES` is only ever set through `extra`, and never for
    /// graphics DLLs (see `PfanneRegistry`).
    public func environment(extra: [String: String] = [:]) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env: [String: String] = [
            "HOME": home,
            "USER": NSUserName(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "PATH": [engineRoot.appending(path: "bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                .joined(separator: ":"),
            "WINEPREFIX": pfanne.prefixURL.path,
            "WINEDEBUG": "fixme-all",
            // Wine finds its own libraries relative to its binary; this covers bundled
            // extras such as MoltenVK and D3DMetal's shared library.
            "DYLD_FALLBACK_LIBRARY_PATH": ([
                engineRoot.appending(path: "lib").path,
                engineRoot.appending(path: "lib/external").path
            ] + [libraries?.root.path].compactMap { $0 } + ["/usr/lib"]).joined(separator: ":")
        ]
        if let libraries {
            env.merge(RuntimeLibraries.environment(for: libraries)) { $1 }
        }
        env.merge(graphicsEnvironment) { $1 }
        pfanne.settings.environmentVariables(wineEnv: &env)
        env.merge(extra) { $1 }
        return env
    }

    /// Variables CodeWeavers' Wine reads to work with the active graphics layer (found in
    /// the CrossOver 26.3.0 source). `CX_APPLEGPTK_LIBD3DSHARED_PATH` lets ntdll register
    /// D3DMetal's code regions with Rosetta; without it D3DMetal can misbehave.
    /// `CX_ACTIVE_GRAPHICS_BACKEND` tells win32u which layer is active.
    var graphicsEnvironment: [String: String] {
        switch graphics.provider {
        case .d3dMetal:
            return [
                "CX_APPLEGPTK_LIBD3DSHARED_PATH": engineRoot.appending(path: "lib/external/libd3dshared.dylib").path,
                "CX_ACTIVE_GRAPHICS_BACKEND": "d3dmetal"
            ]
        case .dxmt:
            return ["CX_ACTIVE_GRAPHICS_BACKEND": "dxmt"]
        case .wineD3D:
            return [:]
        }
    }

    /// Fingerprint of everything `PfanneSetup.apply` writes into the prefix. When it
    /// changes, the prefix needs to be updated before the next launch.
    public var appliedFingerprint: String {
        let settings = pfanne.settings
        let parts = [
            "engine=\(engine.version)",
            "windows=\(settings.wine.windowsVersion.rawValue)",
            "highres=\(settings.wine.highResolutionMode)",
            "provider=\(graphics.provider.rawValue)",
            "overlay=\(overlay?.version ?? "-")",
            "slot=\(graphics.defaultSlot.rawValue)",
            "dxvk=\(dxvk?.version ?? "-")"
        ]
        return parts.joined(separator: ";")
    }
}
