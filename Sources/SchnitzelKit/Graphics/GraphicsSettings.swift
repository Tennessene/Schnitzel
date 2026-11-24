//
//  GraphicsSettings.swift
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

/// The graphics layer a user picks for a Pfanne.
public enum GraphicsLayer: String, CaseIterable, Codable, Sendable {
    /// D3DMetal if imported, otherwise DXMT if installed, otherwise WineD3D.
    case auto
    case d3dMetal
    case dxmt
    case dxvk
    case wineD3D

    public func pretty() -> String {
        switch self {
        case .auto: return "Auto"
        case .d3dMetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wineD3D: return "WineD3D"
        }
    }
}

/// What fills a Pfanne's builtin d3d slot. Only one per Pfanne, because D3DMetal and DXMT
/// both replace Wine's own builtin d3d11 and dxgi (see SCHNITZEL_PLAN.md, Architecture).
public enum BuiltinProvider: String, CaseIterable, Codable, Sendable {
    /// Whatever the engine ships, normally Wine's own WineD3D.
    case wineD3D
    case dxmt
    case d3dMetal

    public func pretty() -> String {
        switch self {
        case .wineD3D: return "WineD3D"
        case .dxmt: return "DXMT"
        case .d3dMetal: return "D3DMetal"
        }
    }

    /// The component the provider's files come from, if any.
    public var component: ComponentKind? {
        switch self {
        case .wineD3D: return nil
        case .dxmt: return .dxmt
        case .d3dMetal: return .d3dMetal
        }
    }
}

/// Which DLL slot games in a Pfanne use unless a per-game override says otherwise.
public enum DllSlot: String, Codable, Sendable {
    /// The builtin provider.
    case builtin
    /// DXVK's native DLLs in system32.
    case native
}

public struct GraphicsSettings: Codable, Equatable, Sendable {
    public var layer: GraphicsLayer = .auto
    public var dxvkAsync: Bool = true

    public init(layer: GraphicsLayer = .auto, dxvkAsync: Bool = true) {
        self.layer = layer
        self.dxvkAsync = dxvkAsync
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.layer = try container.decodeIfPresent(GraphicsLayer.self, forKey: .layer) ?? .auto
        self.dxvkAsync = try container.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? true
    }
}

/// A Pfanne's graphics choice, resolved against the components it has pinned.
public struct ResolvedGraphics: Equatable, Sendable {
    public var provider: BuiltinProvider
    public var defaultSlot: DllSlot
    /// Whether DXVK's DLLs go into system32 (so games can use DXVK per game).
    public var installsDXVK: Bool

    public init(provider: BuiltinProvider, defaultSlot: DllSlot, installsDXVK: Bool) {
        self.provider = provider
        self.defaultSlot = defaultSlot
        self.installsDXVK = installsDXVK
    }

    /// The best builtin provider among the pinned components.
    static func bestProvider(pins: ComponentPins) -> BuiltinProvider {
        if pins.d3dMetal != nil { return .d3dMetal }
        if pins.dxmt != nil { return .dxmt }
        return .wineD3D
    }

    /// Resolves `layer` against `pins`. Throws if the layer needs a component that isn't pinned.
    public static func resolve(layer: GraphicsLayer, pins: ComponentPins) throws -> ResolvedGraphics {
        let hasDXVK = pins.dxvk != nil
        switch layer {
        case .auto:
            return ResolvedGraphics(provider: bestProvider(pins: pins), defaultSlot: .builtin, installsDXVK: hasDXVK)
        case .d3dMetal:
            guard pins.d3dMetal != nil else { throw GraphicsError.notPinned(.d3dMetal) }
            return ResolvedGraphics(provider: .d3dMetal, defaultSlot: .builtin, installsDXVK: hasDXVK)
        case .dxmt:
            guard pins.dxmt != nil else { throw GraphicsError.notPinned(.dxmt) }
            return ResolvedGraphics(provider: .dxmt, defaultSlot: .builtin, installsDXVK: hasDXVK)
        case .dxvk:
            guard hasDXVK else { throw GraphicsError.notPinned(.dxvk) }
            // Keep the best builtin provider too, so single games can still use it later.
            return ResolvedGraphics(provider: bestProvider(pins: pins), defaultSlot: .native, installsDXVK: true)
        case .wineD3D:
            return ResolvedGraphics(provider: .wineD3D, defaultSlot: .builtin, installsDXVK: hasDXVK)
        }
    }
}

public enum GraphicsError: Error, LocalizedError, Equatable {
    case notPinned(ComponentKind)

    public var errorDescription: String? {
        switch self {
        case .notPinned(let kind):
            return "This graphics layer needs \(kind.displayName). Install it in Components and choose it for this \(SchnitzelInfo.pfanneSingular)."
        }
    }
}
