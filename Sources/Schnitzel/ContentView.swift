//
//  ContentView.swift
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

import SchnitzelKit
import SwiftUI

/// Main window. A minimal working layout for testing the core; Phase 2 replaces it.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showingNewPfanne = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section(SchnitzelInfo.pfannePlural) {
                    if model.pfannen.isEmpty {
                        Text("No \(SchnitzelInfo.pfannePlural) yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.pfannen) { pfanne in
                        Label(pfanne.name, systemImage: "frying.pan")
                            .badge(model.running[pfanne.id]?.count ?? 0)
                            .tag(pfanne.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                Button {
                    openWindow(id: ComponentsWindow.id)
                } label: {
                    Label("Components", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            if let pfanne = model.selectedPfanne {
                PfanneDetailView(pfanne: pfanne)
                    .id(pfanne.id)
            } else {
                WelcomeView(showingNewPfanne: $showingNewPfanne)
            }
        }
        .navigationTitle(SchnitzelInfo.appName)
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewPfanne = true
                } label: {
                    Label("New \(SchnitzelInfo.pfanneSingular)", systemImage: "plus")
                }
                .help("New \(SchnitzelInfo.pfanneSingular)")
            }
        }
        .sheet(isPresented: $showingNewPfanne) {
            NewPfanneSheet()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil; model.errorLog = nil } }
        )) {
            if let log = model.errorLog {
                Button("Show Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                    model.errorMessage = nil
                    model.errorLog = nil
                }
            }
            Button("OK", role: .cancel) { model.errorMessage = nil; model.errorLog = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Binding var showingNewPfanne: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to \(SchnitzelInfo.appName)", systemImage: "frying.pan")
        } description: {
            if !model.canCreatePfanne {
                Text("\(SchnitzelInfo.tagline)\nStart by downloading a Wine engine and the runtime libraries in Components.")
            } else {
                Text("\(SchnitzelInfo.tagline)\nCreate a \(SchnitzelInfo.pfanneSingular) to install a game or launcher.")
            }
        } actions: {
            if !model.canCreatePfanne {
                Button("Open Components") { openWindow(id: ComponentsWindow.id) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("New \(SchnitzelInfo.pfanneSingular)") { showingNewPfanne = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct NewPfanneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var name = ""
    @State private var engine: String?

    var body: some View {
        let engines = model.installed(.engine)
        Form {
            TextField("Name", text: $name, prompt: Text("For example: GTA V"))
            Picker("Wine engine", selection: $engine) {
                if engines.isEmpty {
                    Text("None installed").tag(String?.none)
                }
                ForEach(engines) { engine in
                    Text(model.knownProblem(of: engine) != nil ? "\(engine.version) (doesn't work in Schnitzel)"
                         : engine.componentSource?.isTemporaryReference == true
                         ? "\(engine.version) (temporary reference)" : engine.version)
                        .tag(Optional(engine.version))
                }
            }
            if engines.isEmpty {
                Button("Download an engine in Components…") {
                    openWindow(id: ComponentsWindow.id)
                }
            }
            if let engine, let chosen = engines.first(where: { $0.version == engine }),
               let problem = model.knownProblem(of: chosen) {
                Label(problem, systemImage: "exclamationmark.octagon")
                    .foregroundStyle(.red)
            }
            if model.installed(.libraries).isEmpty && model.needsLibraries(engine: engine) {
                Label("No runtime libraries installed: text, HTTPS, Vulkan and controllers won't work. Download them in Components first.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Windows 10, \(model.installed(.d3dMetal).isEmpty ? "no D3DMetal yet" : "D3DMetal") and the default versions of the other components. You can change all of this later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .navigationTitle("New \(SchnitzelInfo.pfanneSingular)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    guard let engine else { return }
                    let name = name
                    dismiss()
                    Task { await model.createPfanne(name: name, engine: engine) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || engine == nil
                          || engines.first(where: { $0.version == engine }).flatMap(model.knownProblem(of:)) != nil)
            }
        }
        .onAppear { engine = engine ?? model.preferred(.engine)?.version }
    }
}
