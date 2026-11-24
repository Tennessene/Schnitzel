//
//  PfanneDetailView.swift
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
import SchnitzelKit
import SwiftUI

/// A Pfanne's actions and settings. Minimal layout for testing the core; Phase 2 redesigns it.
struct PfanneDetailView: View {
    @Environment(AppModel.self) private var model
    let pfanne: Pfanne
    @State private var confirmingTrash = false

    var body: some View {
        let busy = model.busy[pfanne.id]
        let running = model.running[pfanne.id] ?? []
        let state = pfanne.prefixState
        Form {
            if state != .ready, busy == nil {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This \(SchnitzelInfo.pfanneSingular)'s Windows environment is missing or incomplete.")
                                .bold()
                            Text(PfanneSetup.describe(state))
                            Text("Repair runs Wine's setup again. Files already in its C: drive are kept.")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Repair") { Task { await model.repair(pfanne) } }
                            .buttonStyle(.borderedProminent)
                        Button("Show Log") { model.showLatestLog(of: pfanne) }
                    }
                }
            }
            Section {
                if let busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(busy)
                    }
                }
                ForEach(Array(running.enumerated()), id: \.offset) { _, name in
                    Label("Running: \(name)", systemImage: "play.circle")
                }
                HStack {
                    Button("Run Program…", systemImage: "play.fill") { chooseProgram() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state != .ready)
                    Button("Open C: Drive", systemImage: "folder") { model.openDriveC(of: pfanne) }
                        .disabled(state != .ready)
                    Button("Show Log", systemImage: "doc.text") { model.showLatestLog(of: pfanne) }
                    Button("Stop All", systemImage: "stop.fill") { Task { await model.stopAll(in: pfanne) } }
                        .disabled(running.isEmpty && busy == nil)
                }
                .disabled(busy != nil)
            }

            Section("Wine") {
                componentPicker(.engine, title: "Engine", allowNone: false)
                componentPicker(.libraries, title: "Runtime libraries", allowNone: true)
                if pfanne.settings.pins.libraries == nil {
                    Label("Without runtime libraries, text, HTTPS, Vulkan and controllers won't work.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if pfanne.settings.previousPins != nil {
                    LabeledContent("Previous versions") {
                        Button("Roll Back") { model.rollBack(pfanne) }
                    }
                }
                Picker("Windows version", selection: binding(\.wine.windowsVersion)) {
                    ForEach(WinVersion.allCases.reversed(), id: \.self) { Text($0.pretty()).tag($0) }
                }
                Picker("Sync", selection: binding(\.wine.enhancedSync)) {
                    ForEach(EnhancedSync.allCases, id: \.self) { Text($0.pretty()).tag($0) }
                }
                Toggle("High Resolution Mode", isOn: binding(\.wine.highResolutionMode))
            }

            Section {
                Picker("Graphics", selection: binding(\.graphics.layer)) {
                    ForEach(GraphicsLayer.allCases, id: \.self) { Text($0.pretty()).tag($0) }
                }
                LabeledContent("In use", value: resolvedDescription)
                componentPicker(.d3dMetal, title: "D3DMetal", allowNone: true)
                componentPicker(.dxmt, title: "DXMT", allowNone: true)
                componentPicker(.dxvk, title: "DXVK", allowNone: true)
                Toggle("DLSS (D3DMetal)", isOn: binding(\.metal.dlssEnabled))
                    .disabled(pfanne.settings.pins.d3dMetal == nil)
                Toggle("Metal HUD", isOn: binding(\.metal.metalHud))
            } header: {
                Text("Graphics")
            } footer: {
                Text("Changes are applied the next time a program starts in this \(SchnitzelInfo.pfanneSingular).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Move to Trash…", role: .destructive) { confirmingTrash = true }
                    .disabled(busy != nil)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(pfanne.name)
        .confirmationDialog(
            "Move “\(pfanne.name)” to the Trash?", isPresented: $confirmingTrash
        ) {
            Button("Move to Trash", role: .destructive) { Task { await model.moveToTrash(pfanne) } }
        } message: {
            Text("Everything installed in it goes with it. You can get it back from the Trash until you empty it.")
        }
    }

    private var resolvedDescription: String {
        guard let resolved = try? ResolvedGraphics.resolve(layer: pfanne.settings.graphics.layer, pins: pfanne.settings.pins) else {
            return "Missing component: choose a version below"
        }
        let fallback = resolved.defaultSlot == .native ? "DXVK" : resolved.provider.pretty()
        return resolved.installsDXVK && resolved.defaultSlot == .builtin
            ? "\(fallback) (DXVK also installed)"
            : fallback
    }

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<PfanneSettings, Value>) -> Binding<Value> {
        Binding(
            get: { pfanne.settings[keyPath: keyPath] },
            set: { value in model.update(pfanne) { $0[keyPath: keyPath] = value } }
        )
    }

    @ViewBuilder
    private func componentPicker(_ kind: ComponentKind, title: String, allowNone: Bool) -> some View {
        let versions = model.installed(kind).map(\.version)
        let current = pfanne.settings.pins.version(of: kind)
        Picker(title, selection: Binding(
            get: { current },
            set: { version in model.update(pfanne) { settings in settings.changePins { $0.set(version, for: kind) } } }
        )) {
            if allowNone || current == nil {
                Text("None").tag(String?.none)
            }
            if let current, !versions.contains(current) {
                Text("\(current) (missing)").tag(Optional(current))
            }
            ForEach(model.installed(kind)) { component in
                Text(component.componentSource?.isTemporaryReference == true
                     ? "\(component.version) (temporary reference)" : component.version)
                    .tag(Optional(component.version))
            }
        }
    }

    private func chooseProgram() {
        let panel = NSOpenPanel()
        panel.title = "Run a Windows program in \(pfanne.name)"
        panel.message = "Choose a Windows program, installer, batch file or shortcut (.exe, .msi, .bat, .cmd, .lnk, .com)."
        panel.prompt = "Run"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // No allowedContentTypes: macOS has no real type for .exe, so a type filter greys
        // out every program. The delegate checks extensions instead.
        let filter = WindowsProgramPanelFilter()
        panel.delegate = filter
        // Installers are usually in Downloads; programs installed in the Pfanne are in
        // its C: drive, which the user can reach with Open C: Drive or by browsing.
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let response = panel.runModal()
        withExtendedLifetime(filter) {}
        guard response == .OK, let url = panel.url else { return }
        Task { await model.run(url, in: pfanne) }
    }
}

/// Lets an open panel enable folders and Windows programs, judged by file extension.
final class WindowsProgramPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        WindowsProgram.isSelectableInPicker(url)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard WindowsProgram.hasRunnableExtension(url) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” isn't a Windows program.",
                NSLocalizedRecoverySuggestionErrorKey: "Choose an .exe, .msi, .bat, .cmd, .lnk or .com file."
            ])
        }
    }
}
