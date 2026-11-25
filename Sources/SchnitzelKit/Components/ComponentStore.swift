//
//  ComponentStore.swift
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
import os.log

/// Wine engines, DXVK, DXMT and D3DMetal, each version in its own folder:
///
///     Components/
///       Engines/WS12WineSikarugir11.0_1/   (Component.plist + files)
///       DXVK/v1.10.3-20230507-repack/
///       DXMT/v0.80/
///       D3DMetal/3.0/
///       Assemblies/<engine>+<provider>-<version>/   (engine clone with an overlay)
///
/// Installs unpack into a hidden staging folder and are moved into place only once
/// complete, so an interrupted install never leaves a half-finished version behind.
/// Versions are never changed after install; Pfannen pin them, so an update is always
/// a new folder and the old one stays for rollback.
public struct ComponentStore: Sendable {
    public static let manifestName = "Component.plist"
    /// Version 2 adds `wineGraphicsFolder`; assemblies without it are rebuilt.
    static let assemblyMarker = ".schnitzel-assembly-complete-2"
    /// Inside an assembly's `lib/`: Wine's own copies of the files the overlay replaced, in
    /// the same `<arch>/` layout as `lib/wine`. Programs with `ProgramSettings.usesWineGraphics`
    /// load from here first (Wine patch 0002).
    public static let wineGraphicsFolder = "lib/schnitzel-wine-graphics"

    public let root: URL

    public init(root: URL = SchnitzelInfo.componentsFolder()) {
        self.root = root
    }

    public func folder(for kind: ComponentKind) -> URL {
        root.appending(path: kind.folderName, directoryHint: .isDirectory)
    }

    var assembliesFolder: URL {
        root.appending(path: "Assemblies", directoryHint: .isDirectory)
    }

    // MARK: Listing

    /// Installed versions of `kind`, newest install first.
    public func installed(_ kind: ComponentKind) -> [InstalledComponent] {
        let folder = folder(for: kind)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> InstalledComponent? in
                let versionFolder = folder.appending(path: name, directoryHint: .isDirectory)
                let manifestURL = versionFolder.appending(path: Self.manifestName)
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? PropertyListDecoder().decode(ComponentManifest.self, from: data),
                      manifest.kind == kind, manifest.version == name else { return nil }
                return InstalledComponent(manifest: manifest, folder: versionFolder)
            }
            .sorted { $0.manifest.installedAt > $1.manifest.installedAt }
    }

    public func component(_ kind: ComponentKind, _ version: String) -> InstalledComponent? {
        installed(kind).first { $0.version == version }
    }

    public func require(_ kind: ComponentKind, _ version: String) throws -> InstalledComponent {
        guard let component = component(kind, version) else {
            throw PfanneError.componentMissing(kind, version)
        }
        return component
    }

    // MARK: Installing

    /// Unpacks `archive` as version `version` of `kind`.
    public func install(_ kind: ComponentKind, version: String, archive: URL,
                        source: String, sourceID: String? = nil, sha256: String? = nil) async throws -> InstalledComponent {
        try await install(kind, version: version, source: source, sourceID: sourceID, sha256: sha256) { staging in
            try await Command.untar(archive, into: staging)
        }
    }

    /// Copies an existing folder (for example the Game Porting Toolkit's `redist/lib`) in
    /// as version `version` of `kind`.
    public func importFolder(_ kind: ComponentKind, version: String, from source: URL,
                             sourceDescription: String, sourceID: String? = nil) async throws -> InstalledComponent {
        try await install(kind, version: version, source: sourceDescription, sourceID: sourceID, sha256: nil) { staging in
            try FileManager.default.copyItem(at: source, to: staging.appending(path: source.lastPathComponent))
        }
    }

    private func install(_ kind: ComponentKind, version: String, source: String, sourceID: String?, sha256: String?,
                         fill: (URL) async throws -> Void) async throws -> InstalledComponent {
        try Self.validate(versionName: version)
        let destination = folder(for: kind).appending(path: version, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ComponentError.alreadyInstalled(kind, version)
        }

        let staging = folder(for: kind).appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try await fill(staging)
            if kind == .libraries {
                try RuntimeLibraries.extract(in: staging)
            }
            var findings = try ComponentInspector.inspect(kind, at: staging)
            if kind == .engine {
                let engineRoot = findings.rootPath == "." ? staging : staging.appending(path: findings.rootPath)
                if let note = try ComponentInspector.removeBundledD3DMetal(engineRoot: engineRoot) {
                    findings.notes.append(note)
                }
            }
            try await Command.removeQuarantine(staging)

            let manifest = ComponentManifest(
                kind: kind, version: version, source: source, sourceID: sourceID, sha256: sha256, installedAt: .now,
                rootPath: findings.rootPath, wineBinary: findings.wineBinary, dlls: findings.dlls,
                notes: findings.notes)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(manifest).write(to: staging.appending(path: Self.manifestName))

            try FileManager.default.moveItem(at: staging, to: destination)
            Logger.schnitzelKit.info("Installed \(kind.rawValue, privacy: .public) \(version, privacy: .public)")
            return InstalledComponent(manifest: manifest, folder: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Version names become folder names, so they must be plain.
    static func validate(versionName: String) throws {
        let forbidden = CharacterSet(charactersIn: "/:\\\0")
        guard !versionName.isEmpty, !versionName.hasPrefix("."), versionName.count <= 128,
              versionName.rangeOfCharacter(from: forbidden) == nil else {
            throw ComponentError.invalidVersionName(versionName)
        }
    }

    // MARK: Removing

    /// Moves a version to the Trash. `usedBy` lists the Pfannen that pin it (currently or
    /// as their rollback version); removal is refused while that list isn't empty.
    public func remove(_ kind: ComponentKind, _ version: String, usedBy: [String]) throws {
        guard usedBy.isEmpty else { throw ComponentError.inUse(kind, version, pfannen: usedBy) }
        guard let component = component(kind, version) else { throw ComponentError.notInstalled(kind, version) }
        try FileManager.default.trashItem(at: component.folder, resultingItemURL: nil)
        // Assemblies built from it are now stale.
        for assembly in (try? FileManager.default.contentsOfDirectory(atPath: assembliesFolder.path)) ?? []
        where Self.assembly(assembly, uses: kind, version) {
            try? FileManager.default.removeItem(at: assembliesFolder.appending(path: assembly))
        }
    }

    // MARK: Engine assemblies

    /// The folder to run Wine from: the engine itself for WineD3D, or a cached clone of the
    /// engine with D3DMetal's or DXMT's files laid over it.
    ///
    /// Clones are APFS copy-on-write copies, so they take almost no extra disk space.
    public func engineRoot(engine: InstalledComponent, provider: BuiltinProvider,
                           overlay: InstalledComponent?) throws -> URL {
        guard provider != .wineD3D else { return engine.root }
        guard let overlay, overlay.kind == provider.component else {
            throw GraphicsError.notPinned(provider.component ?? .engine)
        }

        let name = Self.assemblyName(engine: engine.version, provider: provider, version: overlay.version)
        let assembly = assembliesFolder.appending(path: name, directoryHint: .isDirectory)
        let assemblyRoot = engine.manifest.rootPath == "." ? assembly : assembly.appending(path: engine.manifest.rootPath)
        if FileManager.default.fileExists(atPath: assembly.appending(path: Self.assemblyMarker).path) {
            return assemblyRoot
        }

        try? FileManager.default.removeItem(at: assembly) // An earlier attempt that didn't finish.
        try FileManager.default.createDirectory(at: assembliesFolder, withIntermediateDirectories: true)
        let staging = assembliesFolder.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.copyItem(at: engine.folder, to: staging)
            let stagingRoot = engine.manifest.rootPath == "." ? staging : staging.appending(path: engine.manifest.rootPath)
            let wineLib = stagingRoot.appending(path: "lib/wine")
            let wineGraphics = stagingRoot.appending(path: Self.wineGraphicsFolder)

            switch provider {
            case .d3dMetal:
                // The Game Porting Toolkit's redist/lib merges into the engine's lib.
                try Self.keepOriginals(replacedBy: overlay.root.appending(path: "wine"), in: wineLib, into: wineGraphics)
                try Self.merge(overlay.root, into: stagingRoot.appending(path: "lib"))
            case .dxmt:
                for arch in ["x86_64-windows", "x86_64-unix", "i386-windows"] {
                    let source = overlay.root.appending(path: arch)
                    if ComponentInspector.isDirectory(source) {
                        try Self.keepOriginals(replacedBy: overlay.root, in: wineLib, into: wineGraphics, archs: [arch])
                        try Self.merge(source, into: wineLib.appending(path: arch))
                    }
                }
            case .wineD3D:
                break
            }

            FileManager.default.createFile(atPath: staging.appending(path: Self.assemblyMarker).path, contents: nil)
            try FileManager.default.moveItem(at: staging, to: assembly)
            return assemblyRoot
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func assemblyName(engine: String, provider: BuiltinProvider, version: String) -> String {
        "\(engine)+\(provider.rawValue)-\(version)"
    }

    static func assembly(_ name: String, uses kind: ComponentKind, _ version: String) -> Bool {
        switch kind {
        case .engine:
            return name.hasPrefix("\(version)+")
        case .dxmt:
            return name.hasSuffix("+\(BuiltinProvider.dxmt.rawValue)-\(version)")
        case .d3dMetal:
            return name.hasSuffix("+\(BuiltinProvider.d3dMetal.rawValue)-\(version)")
        case .dxvk, .libraries:
            return false
        }
    }

    /// Copies the files in `wineLib/<arch>/` that `overlayWine/<arch>/` is about to replace into
    /// `destination/<arch>/`, so programs that need Wine's own versions can still load them.
    static func keepOriginals(replacedBy overlayWine: URL, in wineLib: URL, into destination: URL,
                              archs: [String]? = nil) throws {
        let fileManager = FileManager.default
        let archNames = archs ?? ((try? fileManager.contentsOfDirectory(atPath: overlayWine.path)) ?? []).sorted()
        for arch in archNames {
            let overlayArch = overlayWine.appending(path: arch)
            guard ComponentInspector.isDirectory(overlayArch) else { continue }
            for name in try fileManager.contentsOfDirectory(atPath: overlayArch.path).sorted() {
                let original = wineLib.appending(path: arch).appending(path: name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: original.path, isDirectory: &isDirectory), !isDirectory.boolValue
                else { continue }
                let folder = destination.appending(path: arch, directoryHint: .isDirectory)
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try fileManager.copyItem(at: original, to: folder.appending(path: name))
            }
        }
    }

    /// Copies everything in `source` into `destination`, replacing files that exist.
    static func merge(_ source: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            let from = source.appending(path: name)
            let to = destination.appending(path: name)
            let isRealDirectory = ComponentInspector.isDirectory(from)
                && (try? from.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
            // Bundles like D3DMetal.framework are replaced whole, not merged.
            if isRealDirectory && ComponentInspector.isDirectory(to) && from.pathExtension.isEmpty {
                try merge(from, into: to)
            } else {
                if fileManager.fileExists(atPath: to.path) || (try? to.checkResourceIsReachable()) == true
                    || (try? fileManager.destinationOfSymbolicLink(atPath: to.path)) != nil {
                    try fileManager.removeItem(at: to)
                }
                try fileManager.copyItem(at: from, to: to)
            }
        }
    }
}
