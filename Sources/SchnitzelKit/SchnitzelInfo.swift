//
//  SchnitzelInfo.swift
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

/// Names and locations shared by the app and the core.
public enum SchnitzelInfo {
    public static let appName = "Schnitzel"
    public static let bundleIdentifier = "io.github.tennessene.Schnitzel"
    public static let tagline = "Windows games, pounded flat for your Mac."
    public static let repositoryURL = URL(string: "https://github.com/Tennessene/schnitzel")!

    /// User-facing name for one Wine prefix.
    public static let pfanneSingular = "Pfanne"
    /// User-facing name for several Wine prefixes.
    public static let pfannePlural = "Pfannen"

    /// `~/Library/Application Support/Schnitzel`
    public static func applicationSupportFolder(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: appName, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/Schnitzel/Pfannen`
    public static func pfannenFolder(fileManager: FileManager = .default) -> URL {
        applicationSupportFolder(fileManager: fileManager)
            .appending(path: pfannePlural, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/Schnitzel/Components`
    /// Wine engines, DXVK, MoltenVK and DXMT, stored per version so Pfannen can pin and roll back.
    public static func componentsFolder(fileManager: FileManager = .default) -> URL {
        applicationSupportFolder(fileManager: fileManager)
            .appending(path: "Components", directoryHint: .isDirectory)
    }

    /// `~/Library/Logs/Schnitzel`
    public static func logsFolder(fileManager: FileManager = .default) -> URL {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: appName, directoryHint: .isDirectory)
    }
}
