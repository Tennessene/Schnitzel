//
//  RegistryPlan.swift
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

/// A registry value as written in a `.reg` file.
public enum RegistryValue: Equatable, Sendable {
    case string(String)
    case dword(UInt32)
    /// Deletes the value.
    case delete

    var regFileText: String {
        switch self {
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .dword(let value):
            return "dword:" + String(format: "%08x", value)
        case .delete:
            return "-"
        }
    }
}

/// A set of registry values, written in one go with `regedit /S`.
public struct RegistryPlan: Equatable, Sendable {
    /// Keys in insertion order, each with its values in insertion order.
    public private(set) var keys: [(key: String, values: [(name: String, value: RegistryValue)])] = []

    public init() {}

    public mutating func set(_ key: String, _ name: String, _ value: RegistryValue) {
        if let index = keys.firstIndex(where: { $0.key == key }) {
            if let valueIndex = keys[index].values.firstIndex(where: { $0.name == name }) {
                keys[index].values[valueIndex].value = value
            } else {
                keys[index].values.append((name, value))
            }
        } else {
            keys.append((key, [(name, value)]))
        }
    }

    public func value(_ key: String, _ name: String) -> RegistryValue? {
        keys.first(where: { $0.key == key })?.values.first(where: { $0.name == name })?.value
    }

    /// The plan as a `.reg` file Wine's `regedit` can import.
    public var regFileText: String {
        var text = "REGEDIT4\n"
        for entry in keys {
            text += "\n[\(entry.key)]\n"
            for value in entry.values {
                text += "\"\(value.name)\"=\(value.value.regFileText)\n"
            }
        }
        return text
    }

    public static func == (lhs: RegistryPlan, rhs: RegistryPlan) -> Bool {
        lhs.regFileText == rhs.regFileText
    }
}

/// The Pfanne-wide registry settings Schnitzel manages.
public enum PfanneRegistry {
    public static let dllOverridesKey = #"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#
    public static let macDriverKey = #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
    public static let desktopKey = #"HKEY_CURRENT_USER\Control Panel\Desktop"#
    /// Wine's per-program settings; one subkey per program file name.
    public static let appDefaultsKey = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults"#

    /// The d3d DLLs Schnitzel always sets explicitly, so nothing depends on Wine's
    /// default load order. DXVK's own DLL names are added on top.
    public static let managedGraphicsDLLs = ["d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "d3d12", "dxgi"]

    /// Builds the registry plan for a Pfanne.
    ///
    /// - Parameters:
    ///   - graphics: the resolved graphics choice.
    ///   - dxvkDLLs: base names of the DLLs the pinned DXVK provides (for example `d3d11`).
    ///   - highResolutionMode: Wine's Retina mode.
    ///   - programs: per-program settings in effect (`PfanneSettings.effectivePrograms`).
    public static func plan(graphics: ResolvedGraphics, dxvkDLLs: [String], highResolutionMode: Bool,
                            programs: [String: ProgramSettings] = [:]) -> RegistryPlan {
        var plan = RegistryPlan()

        let dxvk = Set(graphics.installsDXVK ? dxvkDLLs : [])
        let all = (managedGraphicsDLLs + dxvk.sorted()).reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        for dll in all {
            let useNative = graphics.defaultSlot == .native && dxvk.contains(dll)
            plan.set(dllOverridesKey, dll, .string(useNative ? "native,builtin" : "builtin"))
        }

        plan.set(macDriverKey, "RetinaMode", .string(highResolutionMode ? "y" : "n"))
        plan.set(desktopKey, "LogPixels", .dword(highResolutionMode ? 192 : 96))

        // Read by Schnitzel's Wine patch 0001 when the program starts.
        for program in programs.keys.sorted() {
            guard let append = programs[program]?.commandLineAppend else { continue }
            let trimmed = append.trimmingCharacters(in: .whitespaces)
            plan.set(appDefaultsKey + "\\" + program, "CommandLineAppend", trimmed.isEmpty ? .delete : .string(trimmed))
        }
        return plan
    }
}
