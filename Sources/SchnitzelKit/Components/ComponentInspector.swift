//
//  ComponentInspector.swift
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

/// Looks at an unpacked component and works out where its parts are.
///
/// Archive layouts differ between sources and versions (a Sikarugir engine unpacks to
/// `wswine.bundle/`, a WineHQ build to `Wine Staging.app/Contents/Resources/wine/`), so
/// nothing assumes a fixed layout: the inspector searches for the files it needs.
public enum ComponentInspector {
    /// What inspection found: the manifest fields that depend on the contents.
    public struct Findings: Equatable, Sendable {
        public var rootPath: String
        public var wineBinary: String?
        public var dlls: [String]?
        public var notes: [String]
    }

    public static func inspect(_ kind: ComponentKind, at folder: URL) throws -> Findings {
        switch kind {
        case .engine: return try inspectEngine(at: folder)
        case .dxvk: return try inspectDXVK(at: folder)
        case .dxmt: return try inspectDXMT(at: folder)
        case .d3dMetal: return try inspectD3DMetal(at: folder)
        case .libraries: return try inspectLibraries(at: folder)
        }
    }

    // MARK: Runtime libraries

    static func inspectLibraries(at folder: URL) throws -> Findings {
        let lib = folder.appending(path: "lib")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).filter { $0.hasSuffix(".dylib") }
        let missing = RuntimeLibraries.required.filter { !names.contains($0) }
        guard missing.isEmpty else {
            throw ComponentError.unrecognizedContents(.libraries, "missing \(missing.joined(separator: ", "))")
        }
        let realFiles = names.filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: lib.appending(path: $0).path)) == nil }
        return Findings(
            rootPath: "lib", wineBinary: nil, dlls: nil,
            notes: ["Temporary reference: Schnitzel will build these libraries itself",
                    "\(realFiles.count) open-source libraries: FreeType, GnuTLS, MoltenVK, Vulkan loader, SDL2 and their dependencies"])
    }

    // MARK: Engines

    static func inspectEngine(at folder: URL) throws -> Findings {
        // Every `bin` folder that holds a Wine loader, shallowest first.
        let candidates = directories(in: folder, named: "bin", maxDepth: 6)
            .filter { isFile($0.appending(path: "wine")) || isFile($0.appending(path: "wine64")) }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        guard let bin = candidates.first else {
            throw ComponentError.unrecognizedContents(.engine, "no bin/wine or bin/wine64 inside")
        }
        let root = bin.deletingLastPathComponent()
        guard isDirectory(root.appending(path: "lib/wine")) else {
            throw ComponentError.unrecognizedContents(.engine, "no lib/wine next to \(relativePath(of: bin, in: folder))")
        }

        // Older builds have a separate 64-bit loader `wine64`; WoW64 builds (Wine 9 and
        // later) only have `wine`, which handles both.
        let binary = isFile(bin.appending(path: "wine64")) ? "bin/wine64" : "bin/wine"

        var notes: [String] = []
        let wineDLLs = root.appending(path: "lib/wine/x86_64-windows")
        if isFile(wineDLLs.appending(path: "winemetal.dll")) {
            notes.append("Includes DXMT")
        }
        if !files(in: root.appending(path: "lib"), named: "libMoltenVK.dylib", maxDepth: 3).isEmpty {
            notes.append("Includes MoltenVK")
        }
        if let version = try? String(contentsOf: root.appending(path: "version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            notes.append("Reports version \(version)")
        }
        return Findings(rootPath: relativePath(of: root, in: folder), wineBinary: binary, dlls: nil, notes: notes)
    }

    /// Removes Apple's D3DMetal from an unpacked engine, if the archive contained it.
    /// Schnitzel only uses the user's own import. Returns a note when something was removed.
    static func removeBundledD3DMetal(engineRoot: URL) throws -> String? {
        let external = engineRoot.appending(path: "lib/external")
        let apple = ["D3DMetal.framework", "libd3dshared.dylib"]
            .map { external.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !apple.isEmpty else { return nil }
        for item in apple {
            try FileManager.default.removeItem(at: item)
        }
        return "Contained Apple's D3DMetal, which was removed. Import your own D3DMetal to use it"
    }

    // MARK: DXVK

    static func inspectDXVK(at folder: URL) throws -> Findings {
        guard let x64 = directories(in: folder, named: "x64", maxDepth: 4)
            .first(where: { isFile($0.appending(path: "d3d11.dll")) }) else {
            throw ComponentError.unrecognizedContents(.dxvk, "no x64/d3d11.dll inside")
        }
        let root = x64.deletingLastPathComponent()
        let dlls = ((try? FileManager.default.contentsOfDirectory(atPath: x64.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") }
            .map { String($0.dropLast(4)).lowercased() }
            .sorted()
        var notes: [String] = []
        if !isDirectory(root.appending(path: "x32")) {
            notes.append("No 32-bit DLLs: 32-bit games can't use DXVK")
        }
        return Findings(rootPath: relativePath(of: root, in: folder), wineBinary: nil, dlls: dlls, notes: notes)
    }

    // MARK: DXMT

    static func inspectDXMT(at folder: URL) throws -> Findings {
        guard let windows = directories(in: folder, named: "x86_64-windows", maxDepth: 5)
            .first(where: { isFile($0.appending(path: "d3d11.dll")) }) else {
            throw ComponentError.unrecognizedContents(.dxmt, "no x86_64-windows/d3d11.dll inside")
        }
        let root = windows.deletingLastPathComponent()
        guard isFile(root.appending(path: "x86_64-unix/winemetal.so")) else {
            throw ComponentError.unrecognizedContents(.dxmt, "no x86_64-unix/winemetal.so next to the DLLs")
        }
        var notes: [String] = []
        if !isDirectory(root.appending(path: "i386-windows")) {
            notes.append("No 32-bit DLLs: 32-bit games can't use DXMT")
        }
        return Findings(rootPath: relativePath(of: root, in: folder), wineBinary: nil, dlls: nil, notes: notes)
    }

    // MARK: D3DMetal

    /// Finds the `lib` folder of a Game Porting Toolkit redistributable: the folder that holds
    /// `external/D3DMetal.framework`. Accepts the mounted disk image, its `redist` folder or
    /// `redist/lib` itself.
    public static func d3dMetalLibFolder(in folder: URL) -> URL? {
        let candidates = [folder, folder.appending(path: "lib"), folder.appending(path: "redist/lib")]
            + directories(in: folder, named: "lib", maxDepth: 4)
        return candidates.first { isDirectory($0.appending(path: "external/D3DMetal.framework")) }
    }

    /// D3DMetal's version, read from the framework's Info.plist.
    public static func d3dMetalVersion(libFolder: URL) -> String? {
        let framework = libFolder.appending(path: "external/D3DMetal.framework")
        for plist in ["Resources/Info.plist", "Versions/A/Resources/Info.plist", "Info.plist"] {
            let url = framework.appending(path: plist)
            if let info = NSDictionary(contentsOf: url) as? [String: Any],
               let version = (info["CFBundleShortVersionString"] ?? info["CFBundleVersion"]) as? String {
                return version
            }
        }
        return nil
    }

    static func inspectD3DMetal(at folder: URL) throws -> Findings {
        guard let lib = d3dMetalLibFolder(in: folder) else {
            throw ComponentError.unrecognizedContents(.d3dMetal, "no external/D3DMetal.framework inside")
        }
        var notes: [String] = []
        if !isDirectory(lib.appending(path: "wine/x86_64-windows")) {
            notes.append("No wine/x86_64-windows DLLs found; D3DMetal may not work")
        }
        return Findings(rootPath: relativePath(of: lib, in: folder), wineBinary: nil, dlls: nil, notes: notes)
    }

    // MARK: File helpers

    static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Directories called `name` under `folder`, at most `maxDepth` levels down (including `folder`).
    static func directories(in folder: URL, named name: String, maxDepth: Int) -> [URL] {
        search(in: folder, maxDepth: maxDepth) { $0.lastPathComponent == name && isDirectory($0) }
    }

    static func files(in folder: URL, named name: String, maxDepth: Int) -> [URL] {
        search(in: folder, maxDepth: maxDepth) { $0.lastPathComponent == name && isFile($0) }
    }

    private static func search(in folder: URL, maxDepth: Int, where matches: (URL) -> Bool) -> [URL] {
        var results: [URL] = []
        var queue: [(URL, Int)] = [(folder, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if matches(current) { results.append(current) }
            guard depth < maxDepth, isDirectory(current) else { continue }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: current, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])) ?? []
            for child in children {
                // Don't follow symlinks while searching, to avoid loops.
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                queue.append((child, depth + 1))
            }
        }
        return results
    }

    static func relativePath(of url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.starts(with: base) else { return url.path }
        let rest = target.dropFirst(base.count)
        return rest.isEmpty ? "." : rest.joined(separator: "/")
    }
}
