//
//  Component.swift
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

/// The kinds of components Schnitzel keeps in its versioned store.
public enum ComponentKind: String, CaseIterable, Codable, Sendable {
    case engine
    case dxvk
    case dxmt
    case d3dMetal

    /// Folder name under `Components/`.
    public var folderName: String {
        switch self {
        case .engine: return "Engines"
        case .dxvk: return "DXVK"
        case .dxmt: return "DXMT"
        case .d3dMetal: return "D3DMetal"
        }
    }

    public var displayName: String {
        switch self {
        case .engine: return "Wine engine"
        case .dxvk: return "DXVK"
        case .dxmt: return "DXMT"
        case .d3dMetal: return "D3DMetal"
        }
    }
}

/// What Schnitzel found inside an installed component. Saved as `Component.plist`
/// next to the component's files.
public struct ComponentManifest: Codable, Equatable, Sendable {
    public var kind: ComponentKind
    /// The version identifier, also the folder name (for example `WS12WineSikarugir11.0_1`).
    public var version: String
    /// Where it came from: a download URL or "Imported from …".
    public var source: String
    /// SHA-256 of the downloaded archive, if downloaded.
    public var sha256: String?
    public var installedAt: Date
    /// Path of the component's root inside its folder (for engines: the folder holding `bin/`).
    public var rootPath: String
    /// Engines only: the Wine binary, relative to `rootPath` (`bin/wine` or `bin/wine64`).
    public var wineBinary: String?
    /// DXVK only: base names of the 64-bit DLLs it provides.
    public var dlls: [String]?
    /// Human-readable findings, shown in Components (for example "Includes DXMT").
    public var notes: [String]

    public init(kind: ComponentKind, version: String, source: String, sha256: String? = nil,
                installedAt: Date = .now, rootPath: String = ".", wineBinary: String? = nil,
                dlls: [String]? = nil, notes: [String] = []) {
        self.kind = kind
        self.version = version
        self.source = source
        self.sha256 = sha256
        self.installedAt = installedAt
        self.rootPath = rootPath
        self.wineBinary = wineBinary
        self.dlls = dlls
        self.notes = notes
    }
}

/// An installed component.
public struct InstalledComponent: Equatable, Hashable, Sendable, Identifiable {
    public var manifest: ComponentManifest
    /// The version's folder: `Components/<Kind>/<version>/`.
    public var folder: URL

    public var id: String { "\(manifest.kind.rawValue)/\(manifest.version)" }
    public var kind: ComponentKind { manifest.kind }
    public var version: String { manifest.version }

    /// The component's root folder.
    public var root: URL {
        manifest.rootPath == "." ? folder : folder.appending(path: manifest.rootPath, directoryHint: .isDirectory)
    }

    public static func == (lhs: InstalledComponent, rhs: InstalledComponent) -> Bool { lhs.id == rhs.id && lhs.manifest == rhs.manifest }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum ComponentError: Error, LocalizedError, Equatable {
    case invalidVersionName(String)
    case alreadyInstalled(ComponentKind, String)
    case notInstalled(ComponentKind, String)
    case inUse(ComponentKind, String, pfannen: [String])
    case unrecognizedContents(ComponentKind, String)
    case checksumMismatch(expected: String, actual: String)
    case commandFailed(String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .invalidVersionName(let name):
            return "“\(name)” isn't a valid version name."
        case .alreadyInstalled(let kind, let version):
            return "\(kind.displayName) \(version) is already installed."
        case .notInstalled(let kind, let version):
            return "\(kind.displayName) \(version) isn't installed."
        case .inUse(let kind, let version, let pfannen):
            return "\(kind.displayName) \(version) is still used by: \(pfannen.joined(separator: ", ")). Switch those \(SchnitzelInfo.pfannePlural) to another version first."
        case .unrecognizedContents(let kind, let detail):
            return "This doesn't look like a \(kind.displayName): \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "The download is damaged or was changed (expected SHA-256 \(expected.prefix(12))…, got \(actual.prefix(12))…). Nothing was installed. Try again."
        case .commandFailed(let command, let status, let output):
            return "“\(command)” failed with status \(status).\n\(output.suffix(800))"
        }
    }
}
