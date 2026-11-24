//
//  D3DMetalImport.swift
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

/// Imports D3DMetal from the user's own copy of Apple's Game Porting Toolkit.
///
/// Schnitzel never downloads or ships D3DMetal. The user downloads the Game Porting Toolkit
/// disk image from Apple (free Apple ID required), opens it, and Schnitzel copies its
/// `redist/lib` folder into the component store on the same Mac.
public enum D3DMetalImport {
    /// Apple's download page for the Game Porting Toolkit.
    public static let downloadPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    /// `ComponentManifest.sourceID` of imported D3DMetal versions.
    public static let sourceID = "game-porting-toolkit"
    /// Installed version names are `gptk-<version>`, like downloads are `<source prefix>-<version>`.
    static let versionPrefix = "gptk"

    /// Mounted disk images that contain D3DMetal, for example
    /// `/Volumes/Evaluation environment for Windows games 3.0`.
    public static func mountedToolkits(volumes: URL = URL(fileURLWithPath: "/Volumes")) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volumes.path)) ?? []
        return names.sorted().compactMap { name in
            let volume = volumes.appending(path: name, directoryHint: .isDirectory)
            let lib = volume.appending(path: "redist/lib")
            return ComponentInspector.isDirectory(lib.appending(path: "external/D3DMetal.framework")) ? volume : nil
        }
    }

    /// Imports D3DMetal from `folder` (a mounted disk image, its `redist` folder or
    /// `redist/lib`). Returns the installed component, or the existing one if this version
    /// is already imported.
    public static func importD3DMetal(from folder: URL, store: ComponentStore) async throws -> InstalledComponent {
        guard let lib = ComponentInspector.d3dMetalLibFolder(in: folder) else {
            throw ComponentError.unrecognizedContents(
                .d3dMetal, "choose the opened Game Porting Toolkit disk image, or its redist folder")
        }
        let version = "\(versionPrefix)-" + (ComponentInspector.d3dMetalVersion(libFolder: lib) ?? versionFromName(folder.lastPathComponent))
        if let existing = store.component(.d3dMetal, version) {
            return existing
        }
        return try await store.importFolder(
            .d3dMetal, version: version, from: lib,
            sourceDescription: "Imported from \(folder.path)", sourceID: sourceID)
    }

    /// "Evaluation environment for Windows games 3.0" → "3.0"; anything else → a dated name.
    static func versionFromName(_ name: String) -> String {
        if let range = name.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) {
            return String(name[range])
        }
        return "imported-" + Date.now.formatted(.iso8601.year().month().day())
    }
}
