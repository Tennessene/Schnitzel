//
//  ComponentsWindow.swift
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

/// Installed and downloadable components. Minimal layout; Phase 7 adds the full updater.
struct ComponentsWindow: View {
    static let id = "components"
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ForEach([ComponentKind.engine, .libraries, .dxvk, .dxmt, .d3dMetal], id: \.self) { kind in
                ComponentKindView(kind: kind)
                    .tabItem { Text(kind == .engine ? "Wine Engines" : kind == .libraries ? "Libraries" : kind.displayName) }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ComponentKindView: View {
    @Environment(AppModel.self) private var model
    let kind: ComponentKind

    var body: some View {
        Form {
            Section {
                let installed = model.installed(kind)
                if installed.isEmpty {
                    Text("Nothing installed yet.").foregroundStyle(.secondary)
                }
                ForEach(installed) { component in
                    InstalledRow(component: component)
                }
            } header: {
                HStack {
                    Text("Installed")
                    Spacer()
                    if kind != .d3dMetal {
                        if let local = model.localInstall, local.kind == kind {
                            ProgressView().controlSize(.small)
                            Text(local.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Install from File…") { chooseArchive() }
                            .buttonStyle(.borderless)
                            .disabled(model.localInstall != nil)
                            .help("Install an archive you downloaded yourself, for example from a draft release. A SHA256SUMS file next to it is checked automatically.")
                    }
                }
            }

            if kind == .d3dMetal {
                D3DMetalImportSection()
            } else {
                ForEach(ComponentSource.sources(for: kind)) { source in
                    AvailableSection(source: source)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Install \(model.pendingUnverified?.fileName ?? "") without a checksum file?",
            isPresented: Binding(get: { model.pendingUnverified?.kind == kind },
                                 set: { if !$0 { model.pendingUnverified = nil } }),
            titleVisibility: .visible
        ) {
            Button("Install") { Task { await model.confirmPendingUnverified() } }
            Button("Cancel", role: .cancel) { model.pendingUnverified = nil }
        } message: {
            Text("There's no SHA256SUMS file next to it, so Schnitzel can't check it. Install it only if this SHA-256 matches the one on the release page:\n\n\(model.pendingUnverified?.sha256 ?? "")")
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.archive, .gzip, .data]
        panel.prompt = "Install"
        panel.message = "Choose a \(kind.displayName) archive, for example schnitzel-engine-26.3.0-1.tar.xz. Keep its original file name."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.installFromFile(url, kind: kind) }
    }
}

private struct InstalledRow: View {
    @Environment(AppModel.self) private var model
    let component: InstalledComponent
    @State private var confirmingRemoval = false

    var body: some View {
        let usedBy = model.usage(of: component)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(component.version).font(.body.monospaced())
                    if component.componentSource?.isTemporaryReference == true {
                        TemporaryBadge()
                    }
                }
                if let problem = model.knownProblem(of: component) {
                    Label(problem, systemImage: "exclamationmark.octagon")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(component.manifest.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Text(usedBy.isEmpty ? "Not used by any \(SchnitzelInfo.pfanneSingular)" : "Used by \(usedBy.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([component.folder])
            }
            Button("Move to Trash", role: .destructive) { confirmingRemoval = true }
                .disabled(!usedBy.isEmpty)
                .help(usedBy.isEmpty ? "" : "Switch these \(SchnitzelInfo.pfannePlural) to another version first.")
        }
        .confirmationDialog("Move \(component.kind.displayName) \(component.version) to the Trash?",
                            isPresented: $confirmingRemoval) {
            Button("Move to Trash", role: .destructive) { model.remove(component) }
        }
    }
}

private struct AvailableSection: View {
    @Environment(AppModel.self) private var model
    let source: ComponentSource

    var body: some View {
        Section {
            if let error = model.catalogErrors[source.id] {
                Text(error).foregroundStyle(.red)
            }
            if model.isLoadingCatalog(source) {
                ProgressView().controlSize(.small)
            }
            ForEach(model.available[source.id] ?? []) { component in
                AvailableRow(component: component, match: model.match(component))
            }
        } header: {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(source.displayName)
                        if source.isTemporaryReference { TemporaryBadge() }
                    }
                    Text(source.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await model.loadCatalog(source, force: true) } }
                    .buttonStyle(.borderless)
            }
        }
        .task { await model.loadCatalog(source) }
    }
}

private struct AvailableRow: View {
    @Environment(AppModel.self) private var model
    let component: AvailableComponent
    let match: ComponentMatch

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(component.version).font(.body.monospaced())
                    if component.isPrerelease {
                        Text("Test build").font(.caption.bold()).foregroundStyle(.orange)
                            .help("Published as a pre-release on GitHub: a build that is still being tested.")
                    }
                    if component.isRecommended {
                        Text("Recommended").font(.caption.bold()).foregroundStyle(.tint)
                    } else if component.knownProblem != nil {
                        Text("Doesn't work in Schnitzel").font(.caption.bold()).foregroundStyle(.red)
                    } else if !component.isSupported {
                        Text("Not supported by its maintainers").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("\(component.published.formatted(date: .abbreviated, time: .omitted)) · \(ByteCountFormatter.string(fromByteCount: component.size, countStyle: .file))\(component.sha256 == nil ? " · no checksum" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.downloads[component.id] {
                switch progress {
                case .downloading(let received, let total):
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                        .frame(width: 120)
                case .verifying:
                    Text("Verifying…").foregroundStyle(.secondary)
                case .installing:
                    Text("Installing…").foregroundStyle(.secondary)
                }
            } else if match == .sameFile {
                Text("Installed").foregroundStyle(.secondary)
            } else if match == .differentFile {
                Text("A different file is installed under this name")
                    .font(.caption).foregroundStyle(.red)
                    .help("The installed version's SHA-256 differs from this download. Schnitzel never replaces it on its own.")
            } else {
                Button("Download") { Task { await model.download(component) } }
            }
        }
    }
}

/// Marks components that Schnitzel's own builds will replace.
private struct TemporaryBadge: View {
    var body: some View {
        Text("Temporary reference")
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
            .help("A stand-in until Schnitzel's own builds are ready.")
    }
}

private struct D3DMetalImportSection: View {
    @Environment(AppModel.self) private var model
    @State private var mounted: [URL] = []

    var body: some View {
        Section {
            Text("D3DMetal is part of Apple's Game Porting Toolkit. Schnitzel can't include it, so you download it from Apple yourself (free Apple ID needed), open the disk image, then import it here.")
                .foregroundStyle(.secondary)
            Link("Get the Game Porting Toolkit from Apple", destination: D3DMetalImport.downloadPage)
            ForEach(mounted, id: \.self) { volume in
                HStack {
                    Text(volume.lastPathComponent)
                    Spacer()
                    Button("Import") { Task { await model.importD3DMetal(from: volume) } }
                }
            }
            HStack {
                Button("Choose Folder…") { chooseFolder() }
                Button("Look Again") { mounted = D3DMetalImport.mountedToolkits() }
            }
        } header: {
            Text("Import D3DMetal")
        }
        .onAppear { mounted = D3DMetalImport.mountedToolkits() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Choose the opened Game Porting Toolkit disk image, or its redist folder."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importD3DMetal(from: url) }
    }
}
