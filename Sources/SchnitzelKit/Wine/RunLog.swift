//
//  RunLog.swift
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

/// One log file per Wine run, in `~/Library/Logs/Schnitzel/<Pfanne>/`.
public enum RunLog {
    /// Logs older than this many runs are deleted, per Pfanne.
    static let keep = 50

    static func create(for runtime: WineRuntime, name: String) throws -> FileHandle {
        let folder = runtime.pfanne.logsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prune(folder)

        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.dash))
        let safeName = name.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = folder.appending(path: "\(stamp) \(safeName).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        handle.writeApplicationInfo()
        let settings = runtime.pfanne.settings
        var header = "\(SchnitzelInfo.pfanneSingular): \(settings.name)\n"
        header += "Folder: \(runtime.pfanne.url.path)\n"
        header += "Engine: \(runtime.engine.version)\n"
        header += "Running from: \(runtime.engineRoot.path)\n"
        header += "Windows version: \(settings.wine.windowsVersion.pretty())\n"
        header += "Sync: \(settings.wine.enhancedSync.pretty())\n"
        header += "Graphics: \(settings.graphics.layer.pretty()) → builtin \(runtime.graphics.provider.pretty())"
        header += runtime.overlay.map { " \($0.version)" } ?? ""
        header += ", default \(runtime.graphics.defaultSlot == .native ? "DXVK" : "builtin")"
        header += runtime.dxvk.map { ", DXVK \($0.version) installed" } ?? ""
        header += "\nHigh Resolution Mode: \(settings.wine.highResolutionMode ? "on" : "off")\n\n"
        handle.write(line: header)
        return handle
    }

    /// The most recent log file of a Pfanne, if any.
    public static func latest(for pfanne: Pfanne) -> URL? {
        logs(in: pfanne.logsFolder).first
    }

    static func logs(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    static func prune(_ folder: URL) {
        for old in logs(in: folder).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}
