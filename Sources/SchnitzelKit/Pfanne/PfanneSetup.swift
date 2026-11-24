//
//  PfanneSetup.swift
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

/// Creates Wine prefixes and keeps them in line with their Pfanne's settings.
public struct PfanneSetup: Sendable {
    public let store: ComponentStore

    public init(store: ComponentStore) {
        self.store = store
    }

    /// How long `wineboot` may take to create a prefix. A first run on a slow Mac takes
    /// about a minute; anything far beyond that has hung.
    static let winebootTimeout: Duration = .seconds(300)

    /// Creates the Wine prefix for a new Pfanne, checks that it really exists and applies
    /// the Pfanne's settings. Throws `PfanneError.prefixNotCreated` with the reason if Wine
    /// didn't create a complete prefix.
    public func createPrefix(for pfanne: Pfanne) async throws {
        try await initializePrefix(for: pfanne)
    }

    /// Runs `wineboot --init` again on a Pfanne whose prefix is missing or incomplete.
    /// `wineboot` fills in what's missing and keeps what's there (installed programs and
    /// files in drive_c), then the settings are applied again.
    public func repairPrefix(for pfanne: Pfanne) async throws {
        try? FileManager.default.removeItem(at: pfanne.appliedStateURL)
        try await initializePrefix(for: pfanne)
    }

    private func initializePrefix(for pfanne: Pfanne) async throws {
        guard Rosetta.isInstalled else { throw WineError.rosettaMissing }
        let runtime = try WineRuntime.prepare(for: pfanne, store: store)
        try FileManager.default.createDirectory(at: pfanne.prefixURL, withIntermediateDirectories: true)

        // Skip the Mono and Gecko install prompts while the prefix is created; games that
        // need .NET or a browser engine get them through Winetricks. This is the only
        // WINEDLLOVERRIDES Schnitzel sets, and it doesn't touch graphics DLLs.
        var failure: WineError?
        do {
            try await Wine.runWine(["wineboot", "--init"], runtime: runtime, logName: "wineboot",
                                   environment: ["WINEDLLOVERRIDES": "mscoree,mshtml="],
                                   timeout: Self.winebootTimeout)
            try await Wine.waitForExit(runtime: runtime)
        } catch let error as WineError {
            failure = error
        }

        // Trust the files, not the exit status: wineboot can report success without having
        // created anything, and fail after having created everything.
        let state = pfanne.prefixState
        guard state == .ready else {
            throw PfanneError.prefixNotCreated(
                reason: Self.describe(state), wine: failure?.errorDescription,
                hint: knownProblemHint(for: runtime.engine), log: failure?.log ?? RunLog.latest(for: pfanne))
        }
        try await apply(runtime: runtime, engineChanged: false)
    }

    public static func describe(_ state: Pfanne.PrefixState) -> String {
        switch state {
        case .missing: return "Wine didn't create the Windows environment (no registry, no C: drive)."
        case .incomplete(let what): return "The Windows environment is incomplete: \(what)."
        case .ready: return ""
        }
    }

    /// A known reason why this engine can't create prefixes, if any.
    func knownProblemHint(for engine: InstalledComponent) -> String? {
        engine.componentSource?.knownProblems[engine.version]
    }

    /// Updates the prefix if the settings changed since they were last applied.
    /// Call before every launch.
    @discardableResult
    public func applyIfNeeded(to pfanne: Pfanne) async throws -> WineRuntime {
        guard Rosetta.isInstalled else { throw WineError.rosettaMissing }
        let state = pfanne.prefixState
        guard state == .ready else {
            throw PfanneError.needsRepair(name: pfanne.name, reason: Self.describe(state))
        }
        let runtime = try WineRuntime.prepare(for: pfanne, store: store)
        let applied = Self.appliedState(of: pfanne)
        if applied?.fingerprint != runtime.appliedFingerprint {
            try await apply(runtime: runtime, engineChanged: applied.map { $0.engine != runtime.engine.version } ?? false)
        }
        return runtime
    }

    /// Writes the Pfanne's settings into its prefix.
    func apply(runtime: WineRuntime, engineChanged: Bool) async throws {
        let pfanne = runtime.pfanne
        if engineChanged {
            // A different Wine version updates the prefix's own files on first run;
            // do it now, while nothing else is running.
            try await Wine.runWine(["wineboot", "--update"], runtime: runtime, logName: "wineboot update",
                                   timeout: Self.winebootTimeout)
            try await Wine.waitForExit(runtime: runtime)
        }

        try await Wine.changeWinVersion(pfanne.settings.wine.windowsVersion, runtime: runtime)
        try DXVKInstaller.sync(dxvk: runtime.dxvk, prefix: pfanne.prefixURL)
        let plan = PfanneRegistry.plan(
            graphics: runtime.graphics, dxvkDLLs: runtime.dxvk?.manifest.dlls ?? [],
            highResolutionMode: pfanne.settings.wine.highResolutionMode)
        try await Wine.importRegistry(plan, runtime: runtime)
        try await Wine.waitForExit(runtime: runtime)

        let state = AppliedState(fingerprint: runtime.appliedFingerprint, engine: runtime.engine.version)
        try JSONEncoder().encode(state).write(to: pfanne.appliedStateURL, options: .atomic)
        Logger.schnitzelKit.info("Applied settings to \(pfanne.name, privacy: .public)")
    }

    struct AppliedState: Codable, Equatable {
        var fingerprint: String
        var engine: String
    }

    static func appliedState(of pfanne: Pfanne) -> AppliedState? {
        guard let data = try? Data(contentsOf: pfanne.appliedStateURL) else { return nil }
        return try? JSONDecoder().decode(AppliedState.self, from: data)
    }
}

/// Copies DXVK's DLLs into a prefix and takes them out again.
///
/// Wine's own files that DXVK replaces in `system32` and `syswow64` are kept in
/// `.schnitzel-dxvk-backup/` inside the prefix and put back when DXVK is removed or replaced.
public enum DXVKInstaller {
    static let backupFolderName = ".schnitzel-dxvk-backup"
    static let recordName = "installed.json"

    /// `(DXVK folder, prefix folder)` pairs: 64-bit DLLs into system32, 32-bit into syswow64.
    static let targets = [("x64", "drive_c/windows/system32"), ("x32", "drive_c/windows/syswow64")]

    struct Record: Codable, Equatable {
        var version: String
        /// Installed files, relative to the prefix.
        var files: [String]
    }

    /// The DXVK version currently copied into `prefix`, if any.
    public static func installedVersion(prefix: URL) -> String? {
        record(prefix: prefix)?.version
    }

    static func record(prefix: URL) -> Record? {
        let url = prefix.appending(path: backupFolderName).appending(path: recordName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    /// Makes the prefix contain exactly `dxvk`'s DLLs, or none if `dxvk` is nil.
    public static func sync(dxvk: InstalledComponent?, prefix: URL) throws {
        let backup = prefix.appending(path: backupFolderName, directoryHint: .isDirectory)
        let current = record(prefix: prefix)
        if current?.version == dxvk?.version { return }

        if let current {
            try restore(current, prefix: prefix, backup: backup)
        }
        guard let dxvk else { return }

        let fileManager = FileManager.default
        var installed: [String] = []
        for (source, target) in targets {
            let sourceFolder = dxvk.root.appending(path: source)
            let targetFolder = prefix.appending(path: target)
            guard ComponentInspector.isDirectory(sourceFolder), ComponentInspector.isDirectory(targetFolder) else { continue }
            let backupFolder = backup.appending(path: target)
            try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            for dll in try fileManager.contentsOfDirectory(atPath: sourceFolder.path).sorted()
            where dll.lowercased().hasSuffix(".dll") {
                let destination = targetFolder.appending(path: dll)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.moveItem(at: destination, to: backupFolder.appending(path: dll))
                }
                try fileManager.copyItem(at: sourceFolder.appending(path: dll), to: destination)
                installed.append("\(target)/\(dll)")
            }
        }
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(version: dxvk.version, files: installed))
        try data.write(to: backup.appending(path: recordName), options: .atomic)
    }

    static func restore(_ record: Record, prefix: URL, backup: URL) throws {
        let fileManager = FileManager.default
        for file in record.files {
            let installed = prefix.appending(path: file)
            if fileManager.fileExists(atPath: installed.path) {
                try fileManager.removeItem(at: installed)
            }
            let original = backup.appending(path: file)
            if fileManager.fileExists(atPath: original.path) {
                try fileManager.moveItem(at: original, to: installed)
            }
        }
        try fileManager.removeItem(at: backup)
    }
}
