//
//  main.swift
//  schnitzel-cli
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
//  Drives SchnitzelKit from the command line: installs components, creates Pfannen and runs
//  programs through exactly the code the app's buttons use (Install from File, Download,
//  New Pfanne, Run). The CI checks use it so they test what users get, not a copy of it.
//  Set SCHNITZEL_DATA_DIR to keep everything out of the user's own Schnitzel folders.
//

import Foundation
import SchnitzelKit

let usage = """
    Usage: schnitzel-cli <command> ...
      install KIND FILE [--unverified]   Install from File (KIND: engine, dxvk, dxmt, libraries)
      download KIND [VERSION]            download from KIND's default source (default: the recommended version)
      create NAME --engine VERSION       new Pfanne with the app's default components, then its Windows environment
      run NAME FILE [ARGS...]            run a Windows program as the app does; waits until it exits
      set NAME graphics LAYER            change the graphics layer as the app's setting does (auto, d3dMetal, dxmt, dxvk, wineD3D)
      env NAME                           print the environment programs in NAME get
      stop NAME                          stop every Wine process in NAME
      wait NAME [SECONDS]                wait until every Wine process in NAME has exited
    Data folder: \(SchnitzelInfo.applicationSupportFolder().path)
    """

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func kind(_ text: String) throws -> ComponentKind {
    guard let kind = ComponentKind(rawValue: text) else { throw Failure(description: "unknown kind \(text)") }
    return kind
}

let componentStore = ComponentStore()
let pfanneStore = PfanneStore()

func pfanne(named name: String) throws -> Pfanne {
    guard let pfanne = pfanneStore.list().first(where: { $0.name == name }) else {
        throw Failure(description: "no Pfanne named \(name)")
    }
    return pfanne
}

func run(_ arguments: [String]) async throws -> Int32 {
    guard let command = arguments.first else { throw Failure(description: usage) }
    let rest = Array(arguments.dropFirst())
    switch (command, rest.count) {
    case ("install", 2...):
        let archive = try LocalArchive.inspect(URL(filePath: rest[1]), kind: try kind(rest[0]))
        let installed = try await componentStore.installLocal(archive, confirmedUnverified: rest.contains("--unverified"))
        print("installed \(installed.version) (SHA-256 \(archive.sha256), \(archive.checksum))")

    case ("download", 1...):
        let kind = try kind(rest[0])
        guard let source = ComponentSource.defaultSource(for: kind) else { throw Failure(description: "no default source for \(kind)") }
        let available = try await ReleaseCatalog().available(from: source)
        let chosen = rest.count > 1 ? available.first { $0.version == rest[1] } : available.first(where: \.isRecommended)
        guard let chosen else { throw Failure(description: "\(rest.count > 1 ? rest[1] : "no recommended version") not found in \(source.displayName)") }
        if componentStore.component(kind, chosen.version) != nil {
            print("already installed: \(chosen.version)")
        } else {
            let installed = try await ComponentDownloader(store: componentStore).download(chosen) { _ in }
            print("installed \(installed.version) from \(chosen.downloadURL.absoluteString)")
        }

    case ("create", 3...) where rest[1] == "--engine":
        var pfanne = try pfanneStore.create(name: rest[0], engine: rest[2])
        do {
            pfanne.settings.pins = componentStore.defaultPins(engine: rest[2])
            try pfanne.save()
            try await PfanneSetup(store: componentStore).createPrefix(for: pfanne)
        } catch {
            // Same as the app: no broken Pfanne is left behind.
            if let runtime = try? WineRuntime.prepare(for: pfanne, store: componentStore) {
                try? await Wine.kill(runtime: runtime)
            }
            try? FileManager.default.removeItem(at: pfanne.url)
            throw error
        }
        print("created \(pfanne.name) at \(pfanne.url.path)")
        print("pins: engine \(pfanne.settings.pins.engine ?? "-"), DXMT \(pfanne.settings.pins.dxmt ?? "-"), DXVK \(pfanne.settings.pins.dxvk ?? "-"), D3DMetal \(pfanne.settings.pins.d3dMetal ?? "-")")

    case ("run", 2...):
        let pfanne = try pfanne(named: rest[0])
        // The same two steps as the app's Run: apply changed settings, then start the program.
        let runtime = try await PfanneSetup(store: componentStore).applyIfNeeded(to: pfanne)
        let run = try Wine.runProgram(at: URL(filePath: rest[1]), arguments: Array(rest.dropFirst(2)), runtime: runtime)
        print("log: \(run.log.path)")
        var status: Int32 = -1
        for await event in run.events {
            if case .terminated(let code) = event { status = code }
        }
        print("exited with status \(status)")
        return status

    case ("set", 3) where rest[1] == "graphics":
        guard let layer = GraphicsLayer(rawValue: rest[2]) else { throw Failure(description: "unknown graphics layer \(rest[2])") }
        var pfanne = try pfanne(named: rest[0])
        pfanne.settings.graphics.layer = layer
        try pfanne.save()
        print("\(pfanne.name): graphics \(layer.pretty()); applied before the next run")

    case ("env", 1):
        let runtime = try WineRuntime.prepare(for: try pfanne(named: rest[0]), store: componentStore)
        for (key, value) in runtime.environment().sorted(by: { $0.key < $1.key }) { print("\(key)=\(value)") }
        print("engine root: \(runtime.engineRoot.path)")

    case ("stop", 1):
        try await Wine.kill(runtime: try WineRuntime.prepare(for: try pfanne(named: rest[0]), store: componentStore))

    case ("wait", 1...2):
        let runtime = try WineRuntime.prepare(for: try pfanne(named: rest[0]), store: componentStore)
        try await Wine.waitForExit(runtime: runtime, timeout: .seconds(Int(rest.count > 1 ? rest[1] : "120") ?? 120))

    default:
        throw Failure(description: usage)
    }
    return 0
}

do {
    exit(try await run(Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n".utf8))
    exit(1)
}
