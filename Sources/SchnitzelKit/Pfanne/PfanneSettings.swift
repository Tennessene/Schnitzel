//
//  PfanneSettings.swift
//  SchnitzelKit (originally WhiskyKit's BottleSettings.swift)
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//
//  Modified for Schnitzel, November 2026 (GPL-3.0-or-later):
//  based on BottleSettings.swift from Whisky commit fd5480a. Kept the overall shape:
//  a versioned property list, grouped sub-configs, tolerant decoding that falls back to
//  defaults for missing keys, the WinVersion list and the sync and Metal env vars.
//  Changes:
//  - Renamed Bottle to Pfanne throughout.
//  - Replaced the single global Wine version with pinned component versions plus the
//    previous pins, for one-click rollback (ComponentPins).
//  - Replaced the DXVK on/off switch, which set a global WINEDLLOVERRIDES, with the
//    graphics model in GraphicsSettings: never a global override for the d3d DLLs.
//  - Added High Resolution Mode and DLSS toggles; removed pins, blocklist and Metal trace.
//  - An unknown file version no longer silently resets the settings; it throws instead,
//    so a newer Schnitzel's Pfanne is never overwritten by an older one.
//  - Codable types are Sendable; no SemanticVersion package.
//

import Foundation

public enum WinVersion: String, CaseIterable, Codable, Sendable {
    case winXP = "winxp64"
    case win7 = "win7"
    case win8 = "win8"
    case win81 = "win81"
    case win10 = "win10"
    case win11 = "win11"

    public func pretty() -> String {
        switch self {
        case .winXP: return "Windows XP"
        case .win7: return "Windows 7"
        case .win8: return "Windows 8"
        case .win81: return "Windows 8.1"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }
}

public enum EnhancedSync: String, CaseIterable, Codable, Sendable {
    case none, esync, msync

    public func pretty() -> String {
        switch self {
        case .none: return "Off"
        case .esync: return "ESync"
        case .msync: return "MSync"
        }
    }
}

/// The component versions a Pfanne uses. Nil means "not used".
public struct ComponentPins: Codable, Equatable, Hashable, Sendable {
    public var engine: String?
    public var dxvk: String?
    public var dxmt: String?
    public var d3dMetal: String?
    public var libraries: String?

    public init(engine: String? = nil, dxvk: String? = nil, dxmt: String? = nil, d3dMetal: String? = nil,
                libraries: String? = nil) {
        self.engine = engine
        self.dxvk = dxvk
        self.dxmt = dxmt
        self.d3dMetal = d3dMetal
        self.libraries = libraries
    }

    public func version(of kind: ComponentKind) -> String? {
        switch kind {
        case .engine: return engine
        case .dxvk: return dxvk
        case .dxmt: return dxmt
        case .d3dMetal: return d3dMetal
        case .libraries: return libraries
        }
    }

    public mutating func set(_ version: String?, for kind: ComponentKind) {
        switch kind {
        case .engine: engine = version
        case .dxvk: dxvk = version
        case .dxmt: dxmt = version
        case .d3dMetal: d3dMetal = version
        case .libraries: libraries = version
        }
    }
}

public struct PfanneWineConfig: Codable, Equatable, Sendable {
    public var windowsVersion: WinVersion = .win10
    public var enhancedSync: EnhancedSync = .msync
    public var avxEnabled: Bool = false
    /// Wine's Retina mode: full display resolution instead of scaled.
    public var highResolutionMode: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.windowsVersion = try container.decodeIfPresent(WinVersion.self, forKey: .windowsVersion) ?? .win10
        self.enhancedSync = try container.decodeIfPresent(EnhancedSync.self, forKey: .enhancedSync) ?? .msync
        self.avxEnabled = try container.decodeIfPresent(Bool.self, forKey: .avxEnabled) ?? false
        self.highResolutionMode = try container.decodeIfPresent(Bool.self, forKey: .highResolutionMode) ?? false
    }
}

public struct PfanneMetalConfig: Codable, Equatable, Sendable {
    public var metalHud: Bool = false
    public var dxrEnabled: Bool = false
    public var dlssEnabled: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metalHud = try container.decodeIfPresent(Bool.self, forKey: .metalHud) ?? false
        self.dxrEnabled = try container.decodeIfPresent(Bool.self, forKey: .dxrEnabled) ?? false
        self.dlssEnabled = try container.decodeIfPresent(Bool.self, forKey: .dlssEnabled) ?? false
    }
}

public struct PfanneSettings: Codable, Equatable, Sendable {
    public static let currentFileVersion = 1

    public var fileVersion: Int = Self.currentFileVersion
    public var name: String
    public var wine = PfanneWineConfig()
    public var metal = PfanneMetalConfig()
    public var graphics = GraphicsSettings()
    /// The component versions in use.
    public var pins = ComponentPins()
    /// The pins before the last change, for one-click rollback. Nil if nothing changed yet.
    public var previousPins: ComponentPins?

    public init(name: String) {
        self.name = name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileVersion = try container.decodeIfPresent(Int.self, forKey: .fileVersion) ?? Self.currentFileVersion
        guard fileVersion <= Self.currentFileVersion else {
            throw PfanneError.newerFileVersion(fileVersion)
        }
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? SchnitzelInfo.pfanneSingular
        self.wine = try container.decodeIfPresent(PfanneWineConfig.self, forKey: .wine) ?? PfanneWineConfig()
        self.metal = try container.decodeIfPresent(PfanneMetalConfig.self, forKey: .metal) ?? PfanneMetalConfig()
        self.graphics = try container.decodeIfPresent(GraphicsSettings.self, forKey: .graphics) ?? GraphicsSettings()
        self.pins = try container.decodeIfPresent(ComponentPins.self, forKey: .pins) ?? ComponentPins()
        self.previousPins = try container.decodeIfPresent(ComponentPins.self, forKey: .previousPins)
    }

    /// Changes the pins and remembers the old ones for rollback.
    public mutating func changePins(_ change: (inout ComponentPins) -> Void) {
        var new = pins
        change(&new)
        guard new != pins else { return }
        previousPins = pins
        pins = new
    }

    /// Swaps the current and previous pins. Returns false if there is nothing to roll back to.
    @discardableResult
    public mutating func rollBack() -> Bool {
        guard let previous = previousPins else { return false }
        previousPins = pins
        pins = previous
        return true
    }

    public static func decode(from url: URL) throws -> PfanneSettings {
        try PropertyListDecoder().decode(PfanneSettings.self, from: Data(contentsOf: url))
    }

    public func encode(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Environment variables for Wine processes in this Pfanne.
    ///
    /// Never contains `WINEDLLOVERRIDES`: graphics DLL choices live in the registry so
    /// per-game overrides can work (see `DllOverridePlan`).
    public func environmentVariables(wineEnv: inout [String: String]) {
        switch wine.enhancedSync {
        case .none:
            break
        case .esync:
            wineEnv["WINEESYNC"] = "1"
        case .msync:
            wineEnv["WINEMSYNC"] = "1"
            // From Whisky: D3DMetal detects ESYNC and changes behaviour accordingly,
            // so it has to be told ESYNC is on or it breaks under MSYNC.
            wineEnv["WINEESYNC"] = "1"
        }

        if metal.metalHud {
            wineEnv["MTL_HUD_ENABLED"] = "1"
        }
        if wine.avxEnabled {
            wineEnv["ROSETTA_ADVERTISE_AVX"] = "1"
        }
        if metal.dxrEnabled {
            wineEnv["D3DM_SUPPORT_DXR"] = "1"
        }
        if metal.dlssEnabled {
            // DLSS through MetalFX. Variable name from Apple's Game Porting Toolkit 2.0
            // read-me; check it against newer versions when they come out.
            wineEnv["D3DM_ENABLE_METALFX"] = "1"
        }
        if graphics.dxvkAsync {
            wineEnv["DXVK_ASYNC"] = "1"
        }
    }
}

public enum PfanneError: Error, LocalizedError, Equatable {
    case newerFileVersion(Int)
    case nameInUse(String)
    case invalidName
    case notFound(String)
    case engineNotPinned
    case componentMissing(ComponentKind, String)
    case nothingToRollBack

    public var errorDescription: String? {
        switch self {
        case .newerFileVersion(let version):
            return "This \(SchnitzelInfo.pfanneSingular) was saved by a newer version of Schnitzel (file version \(version)). Update Schnitzel to open it."
        case .nameInUse(let name):
            return "A \(SchnitzelInfo.pfanneSingular) named “\(name)” already exists."
        case .invalidName:
            return "Enter a name that isn't empty and doesn't contain “/” or “:”."
        case .notFound(let name):
            return "The \(SchnitzelInfo.pfanneSingular) “\(name)” couldn't be found."
        case .engineNotPinned:
            return "This \(SchnitzelInfo.pfanneSingular) has no Wine engine yet. Choose one first."
        case .componentMissing(let kind, let version):
            return "\(kind.displayName) \(version) isn't installed. Install it in Components, or pick another version."
        case .nothingToRollBack:
            return "There is no earlier version to go back to."
        }
    }
}
