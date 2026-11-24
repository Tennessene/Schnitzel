//
//  WindowsProgram.swift
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

/// Which files Schnitzel can start in a Pfanne.
///
/// macOS has no built-in file type for Windows programs. `UTType(filenameExtension: "exe")`
/// makes up a dynamic type that real `.exe` files on disk don't match (they may carry
/// another app's declared type, or none), so filtering an open panel by type greys out
/// every program. Schnitzel decides by file extension instead.
public enum WindowsProgram {
    /// Extensions Wine can start: programs, installers, batch files and shortcuts.
    public static let extensions: Set<String> = ["exe", "msi", "bat", "cmd", "lnk", "com"]

    /// Whether `url` names a file Schnitzel can run, judged by its extension.
    public static func hasRunnableExtension(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Whether an open panel should let the user pick (or open) `url`: folders, so the user
    /// can browse into them, and files with a runnable extension. App bundles and other
    /// packages are not folders here.
    public static func isSelectableInPicker(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true {
            return values?.isPackage != true
        }
        return hasRunnableExtension(url)
    }
}
