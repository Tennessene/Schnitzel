//
//  ProgramSettings.swift
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

/// Settings for one Windows program inside a Pfanne, applied every time that program starts.
///
/// Programs are identified by their file name (`steamwebhelper.exe`), the way Wine's own
/// per-program settings (`HKCU\Software\Wine\AppDefaults\<file name>`) identify them.
/// Recipes (Phase 4) add entries for single games; `ProgramDefaults` holds the ones every
/// Pfanne needs.
public struct ProgramSettings: Codable, Equatable, Sendable {
    /// Options added to the end of the program's command line whenever it starts, even when
    /// another program starts it (Steam starting its web helper, for example). Needs an
    /// engine with Schnitzel's Wine patch 0001 (`engines/patches/wine`). An empty string
    /// turns off a built-in default.
    public var commandLineAppend: String?
    /// Run the program with Wine's own d3d DLLs (WineD3D) when the Pfanne's builtin slot holds
    /// D3DMetal or DXMT. Other programs in the Pfanne, the ones it starts included, keep the
    /// Pfanne's graphics. Needs an engine with Schnitzel's Wine patch 0002.
    public var usesWineGraphics: Bool?
    /// For generic file names such as `launcher.exe`: `usesWineGraphics` only applies when the
    /// program's Windows path ends with this (for example `Rockstar Games\Launcher\Launcher.exe`).
    public var pathEnding: String?
    /// Why the program needs this, for logs and the interface.
    public var reason: String?

    public init(commandLineAppend: String? = nil, usesWineGraphics: Bool? = nil, pathEnding: String? = nil,
                reason: String? = nil) {
        self.commandLineAppend = commandLineAppend
        self.usesWineGraphics = usesWineGraphics
        self.pathEnding = pathEnding
        self.reason = reason
    }

    /// Normalizes a program name the way Wine compares them: file name only, lowercased.
    public static func key(for program: String) -> String {
        let name = program.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? program
        return name.lowercased()
    }
}

/// Program settings every Pfanne gets, for programs known to need them on Wine for macOS.
///
/// Each entry was observed in CrossOver 26.3 (November 2026), which adds the same options
/// through its closed compatibility layer; see SCHNITZEL_PLAN.md, "Program settings".
public enum ProgramDefaults {
    public static let builtIn: [String: ProgramSettings] = [
        // Steam's interface is a Chromium browser. On Wine for macOS its sandbox and its
        // separate GPU process can't show anything: the window stays invisible or black.
        // CrossOver runs it without the sandbox, with the GPU part in-process, drawing in
        // software. Checked with CrossOver 26.3 and Steam's client of November 2026.
        "steamwebhelper.exe": ProgramSettings(
            commandLineAppend: "--no-sandbox --in-process-gpu --disable-gpu",
            reason: "Steam's window stays invisible or black without these on Wine for macOS"),
        // Rockstar's Social Club (Rockstar Games Launcher, GTA V) is Chromium too. CrossOver
        // keeps its GPU part in-process and draws it with ANGLE's software renderer.
        "socialclubhelper.exe": ProgramSettings(
            commandLineAppend: "--in-process-gpu --use-gl=angle --use-angle=swiftshader",
            reason: "Rockstar's launcher and Social Club overlay need these on Wine for macOS"),
        // The Rockstar Games Launcher draws with Direct2D, which needs a Direct3D 10.1 device;
        // D3DMetal's dxgi doesn't implement that, so the launcher fails to initialize.
        // CrossOver 26.3 gives this launcher Wine's own d3d DLLs and Social Club D3DMetal's
        // (observed with lsof, November 25, 2026). The file name alone is too generic.
        "launcher.exe": ProgramSettings(
            usesWineGraphics: true, pathEnding: #"Rockstar Games\Launcher\Launcher.exe"#,
            reason: "The Rockstar Games Launcher fails to initialize with D3DMetal's DLLs")
    ]

    /// The programs that use Wine's own graphics DLLs, as patch 0002 reads them from
    /// `SCHNITZEL_WINE_GRAPHICS_PROGRAMS` (`;`-separated path endings or file names).
    public static func wineGraphicsList(_ programs: [String: ProgramSettings]) -> String {
        programs.keys.sorted().compactMap { key -> String? in
            guard let settings = programs[key], settings.usesWineGraphics == true else { return nil }
            let ending = settings.pathEnding?.trimmingCharacters(in: .whitespaces) ?? ""
            let entry = ending.isEmpty ? key : ending
            return entry.contains(";") || !entry.allSatisfy(\.isASCII) ? nil : entry
        }.joined(separator: ";")
    }

    /// The built-in settings with a Pfanne's own entries laid over them (the Pfanne's win;
    /// an empty `commandLineAppend` turns a built-in one off). Keys are normalized.
    public static func effective(_ pfanne: [String: ProgramSettings]) -> [String: ProgramSettings] {
        var result = builtIn
        for (program, settings) in pfanne {
            result[ProgramSettings.key(for: program)] = settings
        }
        return result
    }
}
