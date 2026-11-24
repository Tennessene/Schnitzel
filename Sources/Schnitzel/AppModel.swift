//
//  AppModel.swift
//  Schnitzel
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

import AppKit
import Observation
import SchnitzelKit

/// App-wide state: Pfannen, components and the work in progress.
@MainActor
@Observable
final class AppModel {
    let pfanneStore = PfanneStore()
    let componentStore = ComponentStore()

    private(set) var pfannen: [Pfanne] = []
    var selection: Pfanne.ID?

    private(set) var installed: [ComponentKind: [InstalledComponent]] = [:]
    private(set) var available: [String: [AvailableComponent]] = [:]
    private(set) var catalogErrors: [String: String] = [:]
    private(set) var loadingCatalogs: Set<String> = []
    private(set) var downloads: [String: ComponentDownloader.Progress] = [:]

    /// Pfannen being created or updated, with a short status.
    private(set) var busy: [Pfanne.ID: String] = [:]
    /// Programs running per Pfanne.
    private(set) var running: [Pfanne.ID: [String]] = [:]

    var errorMessage: String?

    init() {
        reload()
    }

    // MARK: Loading

    func reload() {
        pfannen = pfanneStore.list()
        for kind in ComponentKind.allCases {
            installed[kind] = componentStore.installed(kind)
        }
        if let selection, !pfannen.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    var selectedPfanne: Pfanne? {
        pfannen.first { $0.id == selection }
    }

    func installed(_ kind: ComponentKind) -> [InstalledComponent] {
        installed[kind] ?? []
    }

    /// The version new Pfannen use: the newest one installed from the kind's default
    /// source, otherwise the newest one installed from anywhere.
    func preferred(_ kind: ComponentKind) -> InstalledComponent? {
        let all = installed(kind)
        let defaultID = ComponentSource.defaultSource(for: kind)?.id
        return all.first { $0.manifest.sourceID == defaultID } ?? all.first
    }

    func loadCatalog(_ source: ComponentSource, force: Bool = false) async {
        guard force || available[source.id] == nil, !loadingCatalogs.contains(source.id) else { return }
        loadingCatalogs.insert(source.id)
        defer { loadingCatalogs.remove(source.id) }
        do {
            available[source.id] = try await ReleaseCatalog().available(from: source)
            catalogErrors[source.id] = nil
        } catch {
            catalogErrors[source.id] = error.localizedDescription
        }
    }

    func isLoadingCatalog(_ source: ComponentSource) -> Bool {
        loadingCatalogs.contains(source.id)
    }

    // MARK: Components

    func download(_ component: AvailableComponent) async {
        guard downloads[component.id] == nil else { return }
        downloads[component.id] = .downloading(received: 0, total: component.size)
        defer { downloads[component.id] = nil }
        let id = component.id
        do {
            _ = try await ComponentDownloader(store: componentStore).download(component) { progress in
                Task { @MainActor [weak self] in
                    if self?.downloads[id] != nil { self?.downloads[id] = progress }
                }
            }
            reload()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importD3DMetal(from folder: URL) async {
        do {
            _ = try await D3DMetalImport.importD3DMetal(from: folder, store: componentStore)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func usage(of component: InstalledComponent) -> [String] {
        pfanneStore.pfannen(using: component.kind, component.version)
    }

    func remove(_ component: InstalledComponent) {
        do {
            try componentStore.remove(component.kind, component.version, usedBy: usage(of: component))
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Pfannen

    /// Creates a Pfanne with the given engine and the newest graphics components, then
    /// creates its Wine prefix.
    func createPfanne(name: String, engine: String) async -> Pfanne? {
        do {
            var pfanne = try pfanneStore.create(name: name, engine: engine)
            pfanne.settings.pins.d3dMetal = preferred(.d3dMetal)?.version
            pfanne.settings.pins.dxmt = preferred(.dxmt)?.version
            pfanne.settings.pins.dxvk = preferred(.dxvk)?.version
            pfanne.settings.pins.libraries = preferred(.libraries)?.version
            try pfanne.save()
            reload()
            selection = pfanne.id

            busy[pfanne.id] = "Setting up the Windows environment…"
            defer { busy[pfanne.id] = nil }
            try await PfanneSetup(store: componentStore).createPrefix(for: pfanne)
            reload()
            return pfanne
        } catch {
            errorMessage = error.localizedDescription
            reload()
            return nil
        }
    }

    /// Saves changed settings. They are written into the prefix before the next launch.
    func update(_ pfanne: Pfanne, _ change: (inout PfanneSettings) -> Void) {
        var updated = pfanne
        change(&updated.settings)
        guard updated.settings != pfanne.settings else { return }
        do {
            try updated.save()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rollBack(_ pfanne: Pfanne) {
        update(pfanne) { settings in
            if !settings.rollBack() { errorMessage = PfanneError.nothingToRollBack.localizedDescription }
        }
    }

    func moveToTrash(_ pfanne: Pfanne) async {
        do {
            if pfanne.isPrefixCreated, let runtime = try? WineRuntime.prepare(for: pfanne, store: componentStore) {
                try? await Wine.kill(runtime: runtime)
            }
            try pfanneStore.moveToTrash(pfanne)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a Windows program in a Pfanne, applying changed settings first.
    func run(_ file: URL, in pfanne: Pfanne) async {
        let name = file.lastPathComponent
        do {
            busy[pfanne.id] = "Applying settings…"
            let runtime: WineRuntime
            do {
                defer { busy[pfanne.id] = nil }
                if !pfanne.isPrefixCreated {
                    busy[pfanne.id] = "Setting up the Windows environment…"
                    try await PfanneSetup(store: componentStore).createPrefix(for: pfanne)
                }
                runtime = try await PfanneSetup(store: componentStore).applyIfNeeded(to: pfanne)
            }

            running[pfanne.id, default: []].append(name)
            defer {
                if let index = running[pfanne.id]?.firstIndex(of: name) { running[pfanne.id]?.remove(at: index) }
            }
            // Output goes to the run's log file. Many games exit with a non-zero status
            // normally, so the exit status is only recorded there, not shown as an error.
            for await _ in try Wine.runProgram(at: file, runtime: runtime) {}
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopAll(in pfanne: Pfanne) async {
        do {
            let runtime = try WineRuntime.prepare(for: pfanne, store: componentStore)
            try await Wine.kill(runtime: runtime)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openDriveC(of pfanne: Pfanne) {
        NSWorkspace.shared.open(pfanne.driveC)
    }

    func showLatestLog(of pfanne: Pfanne) {
        if let log = RunLog.latest(for: pfanne) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            try? FileManager.default.createDirectory(at: pfanne.logsFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(pfanne.logsFolder)
        }
    }
}
