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

/// One log file per Wine run, in `~/Library/Logs/Schnitzel/<Pfanne>/`, kept within
/// `LogLimiter.shared.limits` (see `LogLimiter`).
public enum RunLog {
    /// Logs touched this recently may still be written by a running program; pruning skips them.
    static let busyInterval: TimeInterval = 15 * 60

    static func create(for runtime: WineRuntime, name: String) throws -> (handle: FileHandle, url: URL) {
        let folder = runtime.pfanne.logsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prune(folder, limits: LogLimiter.shared.limits)

        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.dash))
        let safeName = name.replacingOccurrences(of: "/", with: "-").prefix(60)
        let url = folder.appending(path: "\(stamp) \(safeName).log")
        // Append-only, so writes from every Wine process go to the end even after the
        // limiter has shortened the file (Wine's processes inherit this open file).
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644) } ?? -1
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        LogLimiter.mark(url)

        handle.writeApplicationInfo()
        let settings = runtime.pfanne.settings
        var header = "\(SchnitzelInfo.pfanneSingular): \(settings.name)\n"
        header += "Folder: \(runtime.pfanne.url.path)\n"
        header += "Engine: \(runtime.engine.version)\n"
        let libraries = runtime.libraries?.version
            ?? (runtime.engine.includesRuntimeLibraries ? "included in the engine"
                : "none (fonts, HTTPS, Vulkan and controllers may not work)")
        header += "Runtime libraries: \(libraries)\n"
        header += "Running from: \(runtime.engineRoot.path)\n"
        header += "Windows version: \(settings.wine.windowsVersion.pretty())\n"
        header += "Sync: \(settings.wine.enhancedSync.pretty())\n"
        header += "Graphics: \(settings.graphics.layer.pretty()) → builtin \(runtime.graphics.provider.pretty())"
        header += runtime.overlay.map { " \($0.version)" } ?? ""
        header += ", default \(runtime.graphics.defaultSlot == .native ? "DXVK" : "builtin")"
        header += runtime.dxvk.map { ", DXVK \($0.version) installed" } ?? ""
        header += "\nHigh Resolution Mode: \(settings.wine.highResolutionMode ? "on" : "off")\n"
        for program in settings.effectivePrograms.keys.sorted() {
            if let append = settings.effectivePrograms[program]?.commandLineAppend, !append.isEmpty {
                header += "Program setting: \(program) gets \(append)\n"
            }
            if let wine = settings.effectivePrograms[program], wine.usesWineGraphics == true,
               runtime.graphics.provider != .wineD3D {
                header += "Program setting: \(wine.pathEnding ?? program) uses Wine's own graphics DLLs\n"
            }
        }
        header += "\n"
        handle.write(line: header)
        return (handle, url)
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

    /// Starts keeping the log within its size limit. Everything in it so far counts as its
    /// header and is never cut.
    static func watch(_ url: URL) {
        var info = stat()
        let size = stat(url.path, &info) == 0 ? UInt64(info.st_size) : 0
        LogLimiter.shared.watch(url, headerLength: size)
    }

    /// Deletes the oldest logs beyond the limits. Never deletes a log touched in the last
    /// `busyInterval`, and deletes by total size only logs Schnitzel wrote with limits (older
    /// logs, for example from before log limits existed, stay until the user removes them).
    static func prune(_ folder: URL, limits: LogLimits, now: Date = .now) {
        var total: UInt64 = 0
        for (index, log) in logs(in: folder).enumerated() {
            let values = try? log.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = UInt64(values?.fileSize ?? 0)
            total += size
            let modified = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > busyInterval else { continue }
            if index >= limits.maxLogsPerPfanne
                || (total > limits.maxBytesPerPfanne && LogLimiter.isMarked(log)) {
                try? FileManager.default.removeItem(at: log)
                total -= size
            }
        }
    }

    /// Logs in a Pfanne's folder bigger than `bytes`, newest first, for telling the user.
    public static func largeLogs(for pfanne: Pfanne, over bytes: UInt64) -> [(url: URL, size: UInt64)] {
        logs(in: pfanne.logsFolder).compactMap { log in
            let size = UInt64((try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return size > bytes ? (log, size) : nil
        }
    }
}
