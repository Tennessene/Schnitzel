//
//  RuntimeLibraries.swift
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

/// The shared libraries Wine loads at runtime but engines don't contain.
///
/// TEMPORARY: until the "Own engine builds" phase builds them, they come from Sikarugir's
/// Template download. Only the open-source libraries on the list below are kept. Sikarugir's
/// launcher, its SDK, Apple's D3DMetal and everything else in the download are deleted
/// during install and never used.
public enum RuntimeLibraries {
    /// The libraries Wine itself asks for (found in the engine's `.so` files).
    public static let required = [
        "libfreetype.6.dylib",   // fonts (win32u, dwrite)
        "libgnutls.30.dylib",    // HTTPS and certificates (bcrypt, crypt32, secur32)
        "libvulkan.1.dylib",     // Vulkan loader, which finds MoltenVK (DXVK, WineD3D Vulkan)
        "libSDL2-2.0.0.dylib",   // game controllers (winebus)
        "libinotify.0.dylib"     // file change notifications (winebus)
    ]

    /// Library names that may be kept, with any number of `.<digits>` version parts:
    /// the required ones and what they load in turn. All open source.
    static let allowedNames = [
        "libfreetype", "libpng16", "libz", "libbz2", "libbrotlicommon", "libbrotlidec", "libbrotlienc",
        "libgnutls", "libnettle", "libhogweed", "libgmp", "libtasn1", "libidn2", "libunistring",
        "libp11-kit", "libffi", "libiconv", "libintl", "libzstd",
        "libvulkan", "libMVK", "libMoltenVK",
        "libSDL2", "libSDL2-2",
        "libinotify"
    ]

    /// Names that must never end up in the component, as a second safety net.
    static let forbiddenFragments = [
        "d3dshared", "D3DMetal", "metalirconverter", "dxcompiler", "dxilconv", "dxccontainer",
        "SikarugirSdk", "wineskinlauncher"
    ]

    /// MoltenVK's own library in Sikarugir's Template (`libMoltenVK.dylib` there is a link to
    /// the Vulkan loader).
    static let moltenVKLibrary = "libMVK.dylib"
    static let icdPath = "vulkan/icd.d/MoltenVK_icd.json"

    static func isAllowed(_ name: String) -> Bool {
        guard name.hasSuffix(".dylib") else { return false }
        return allowedNames.contains { base in
            let pattern = "^" + NSRegularExpression.escapedPattern(for: base) + #"(\.[0-9]+)*\.dylib$"#
            return name.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Replaces the unpacked download in `staging` with just `lib/`: the allowed libraries
    /// and a Vulkan driver file for MoltenVK.
    static func extract(in staging: URL) throws {
        let fileManager = FileManager.default
        guard let frameworks = ComponentInspector.directories(in: staging, named: "Frameworks", maxDepth: 4)
            .first(where: { fileManager.fileExists(atPath: $0.appending(path: "libgnutls.30.dylib").path) }) else {
            throw ComponentError.unrecognizedContents(.libraries, "no Frameworks folder with the libraries Wine needs")
        }

        let lib = staging.appending(path: ".extracted-lib", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: lib, withIntermediateDirectories: true)
        let names = try fileManager.contentsOfDirectory(atPath: frameworks.path).filter(isAllowed).sorted()
        for name in names {
            let source = frameworks.appending(path: name)
            let destination = lib.appending(path: name)
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: source.path) {
                // Keep links like libfreetype.dylib → libfreetype.6.dylib, but only to allowed files
                // in the same folder.
                guard !target.contains("/"), isAllowed(target) else { continue }
                try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
        }

        let missing = (required + [moltenVKLibrary]).filter {
            !fileManager.fileExists(atPath: lib.appending(path: $0).resolvingSymlinksInPath().path)
        }
        guard missing.isEmpty else {
            throw ComponentError.unrecognizedContents(.libraries, "missing \(missing.joined(separator: ", "))")
        }

        try writeVulkanDriverFile(in: lib, apiVersion: originalAPIVersion(in: staging))

        // Everything else from the download goes.
        for item in try fileManager.contentsOfDirectory(atPath: staging.path) where item != lib.lastPathComponent {
            try fileManager.removeItem(at: staging.appending(path: item))
        }
        try fileManager.moveItem(at: lib, to: staging.appending(path: "lib", directoryHint: .isDirectory))

        let leftovers = (fileManager.enumerator(atPath: staging.path)?.allObjects as? [String]) ?? []
        if let bad = leftovers.first(where: { path in forbiddenFragments.contains { path.contains($0) } }) {
            throw ComponentError.unrecognizedContents(.libraries, "refusing to keep \(bad)")
        }
    }

    /// The Vulkan API version Sikarugir's MoltenVK driver file declares, if readable.
    static func originalAPIVersion(in staging: URL) -> String? {
        let files = ComponentInspector.files(in: staging, named: "MoltenVK_icd.json", maxDepth: 6)
        guard let file = files.first, let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icd = json["ICD"] as? [String: Any], let version = icd["api_version"] as? String else { return nil }
        return version
    }

    /// Vulkan finds MoltenVK through this file (`VK_DRIVER_FILES`).
    static func writeVulkanDriverFile(in lib: URL, apiVersion: String?) throws {
        let file = lib.appending(path: icdPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = [
            "file_format_version": "1.0.0",
            "ICD": [
                "library_path": "../../\(moltenVKLibrary)",
                "api_version": apiVersion ?? "1.2.0",
                "is_portability_driver": false
            ]
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }

    /// Environment entries that make Wine find these libraries.
    public static func environment(for component: InstalledComponent) -> [String: String] {
        let icd = component.root.appending(path: icdPath).path
        // VK_DRIVER_FILES for current Vulkan loaders, VK_ICD_FILENAMES for older ones.
        return ["VK_DRIVER_FILES": icd, "VK_ICD_FILENAMES": icd]
    }
}
