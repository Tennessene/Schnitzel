//
//  Wine.swift
//  SchnitzelKit (originally WhiskyKit)
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//
//  Modified for Schnitzel, November 2026 (GPL-3.0-or-later):
//  based on Wine.swift from Whisky commit fd5480a. Kept: running wine and wineserver as
//  streamed processes with a log file, `runWine` collecting output, the registry
//  helpers (`reg add` / `reg query` and the RegistryType list), winecfg for the Windows
//  version, killing a prefix with `wineserver -k`. Changes:
//  - Works on a WineRuntime (per-Pfanne engine and environment) instead of one global
//    WhiskyWine install and a Bottle.
//  - Removed `enableDXVK` and the global WINEDLLOVERRIDES; graphics are in PfanneSetup.
//  - Programs run directly (`wine <exe>`, from the exe's folder) instead of through
//    `wine start /unix`, so the log captures the program's output and Schnitzel knows
//    when it exits. .msi, .bat and .lnk files get the matching Wine launcher.
//  - Added `importRegistry` (one `regedit /S` call for many values) and `waitForExit`.
//  - Logs go to ~/Library/Logs/Schnitzel/<Pfanne>/ with a Pfanne header (RunLog).
//

import Foundation

public enum RegistryType: String, Sendable {
    case binary = "REG_BINARY"
    case dword = "REG_DWORD"
    case qword = "REG_QWORD"
    case string = "REG_SZ"
}

public enum Wine {
    // MARK: Processes

    /// A started Wine process: its events and its log file.
    public struct Run: Sendable {
        public let events: AsyncStream<ProcessOutput>
        public let log: URL
    }

    /// Starts a Wine process. Its output goes to a new log file for this run.
    public static func runWineProcess(
        _ arguments: [String], runtime: WineRuntime, logName: String,
        environment: [String: String] = [:], currentDirectory: URL? = nil
    ) throws -> Run {
        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = arguments
        process.environment = runtime.environment(extra: environment)
        // drive_c doesn't exist until wineboot has created it, and macOS refuses to start a
        // process in a folder that doesn't exist. So setup commands start in the Pfanne's folder.
        let driveC = runtime.pfanne.driveC
        process.currentDirectoryURL = currentDirectory
            ?? (FileManager.default.fileExists(atPath: driveC.path) ? driveC : runtime.pfanne.url)
        process.qualityOfService = .userInitiated
        let log = try RunLog.create(for: runtime, name: logName)
        return Run(events: try process.runStream(name: logName, fileHandle: log.handle), log: log.url)
    }

    /// Runs Wine and waits for it, returning everything it printed.
    ///
    /// With a `timeout`, the process and the rest of the Pfanne's Wine processes are
    /// stopped when it runs out, and `WineError.timedOut` is thrown.
    @discardableResult
    public static func runWine(
        _ arguments: [String], runtime: WineRuntime, logName: String? = nil,
        environment: [String: String] = [:], timeout: Duration? = nil
    ) async throws -> String {
        let command = arguments.joined(separator: " ")
        let run = try runWineProcess(
            arguments, runtime: runtime, logName: logName ?? arguments.first ?? "wine",
            environment: environment)

        let result = try await withThrowingTaskGroup(of: (status: Int32, output: [String])?.self) { group in
            group.addTask {
                var lines: [String] = []
                var status: Int32 = -1
                for await event in run.events {
                    switch event {
                    case .message(let line): lines.append(line)
                    case .terminated(let code): status = code
                    case .started: break
                    }
                }
                return (status, lines)
            }
            if let timeout {
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
            }
            let first = try await group.next() ?? nil
            group.cancelAll() // Cancelling the stream terminates the process.
            return first
        }

        guard let result else {
            try? await kill(runtime: runtime)
            throw WineError.timedOut(command, after: timeout ?? .zero, log: run.log)
        }
        guard result.status == 0 else {
            throw WineError.failed(command, status: result.status,
                                   details: WineError.keyLines(in: result.output), log: run.log)
        }
        return result.output.joined(separator: "\n")
    }

    static func runWineserver(_ arguments: [String], runtime: WineRuntime, timeout: Duration? = nil) async throws {
        try await Command.run(runtime.wineserverBinary.path, arguments, environment: runtime.environment(),
                              timeout: timeout)
    }

    /// Waits until every Wine process in the Pfanne has exited and the registry is saved.
    public static func waitForExit(runtime: WineRuntime, timeout: Duration = .seconds(120)) async throws {
        try await runWineserver(["-w"], runtime: runtime, timeout: timeout)
    }

    /// Stops every Wine process in the Pfanne.
    public static func kill(runtime: WineRuntime) async throws {
        try await runWineserver(["-k"], runtime: runtime, timeout: .seconds(30))
    }

    // MARK: Programs

    /// The Wine arguments that open `file`.
    public static func launchArguments(for file: URL) -> [String] {
        let path = file.path(percentEncoded: false)
        switch file.pathExtension.lowercased() {
        case "msi":
            return ["msiexec", "/i", path]
        case "bat", "cmd":
            return ["cmd", "/c", path]
        case "lnk":
            return ["start", "/unix", path]
        default:
            return [path]
        }
    }

    /// Runs a Windows program from its own folder, as Windows would.
    public static func runProgram(at file: URL, arguments: [String] = [], runtime: WineRuntime)
        throws -> Run {
        try runWineProcess(
            launchArguments(for: file) + arguments, runtime: runtime,
            logName: file.deletingPathExtension().lastPathComponent,
            currentDirectory: file.deletingLastPathComponent())
    }

    // MARK: Registry

    public static func addRegistryKey(
        _ key: String, name: String, data: String, type: RegistryType, runtime: WineRuntime
    ) async throws {
        try await runWine(["reg", "add", key, "/v", name, "/t", type.rawValue, "/d", data, "/f"],
                          runtime: runtime, logName: "reg add", timeout: .seconds(120))
    }

    public static func queryRegistryKey(
        _ key: String, name: String, type: RegistryType, runtime: WineRuntime
    ) async throws -> String? {
        let output = try await runWine(["reg", "query", key, "/v", name], runtime: runtime, logName: "reg query",
                                       timeout: .seconds(120))
        let lines = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        guard let line = lines.first(where: { $0.contains(type.rawValue) }) else { return nil }
        let array = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let value = array.last else { return nil }
        return String(value)
    }

    /// Writes many registry values with a single `regedit /S` call.
    public static func importRegistry(_ plan: RegistryPlan, runtime: WineRuntime) async throws {
        let fileName = "schnitzel-\(UUID().uuidString).reg"
        let file = runtime.pfanne.driveC.appending(path: fileName)
        try plan.regFileText.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await runWine(["regedit", "/S", "C:\\\(fileName)"], runtime: runtime, logName: "regedit",
                          timeout: .seconds(120))
    }

    // MARK: Settings

    public static func changeWinVersion(_ version: WinVersion, runtime: WineRuntime) async throws {
        try await runWine(["winecfg", "/v", version.rawValue], runtime: runtime, logName: "winecfg",
                          timeout: .seconds(120))
    }

    public static func winVersion(runtime: WineRuntime) async throws -> WinVersion? {
        let output = try await runWine(["winecfg", "/v"], runtime: runtime, logName: "winecfg", timeout: .seconds(120))
        return output.split(whereSeparator: \.isNewline).last.flatMap { WinVersion(rawValue: String($0)) }
    }
}

public enum WineError: Error, LocalizedError, Equatable {
    case failed(String, status: Int32, details: [String], log: URL?)
    case timedOut(String, after: Duration, log: URL?)
    case rosettaMissing

    public var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let details, let log):
            var text = "Wine couldn't finish “\(command)” (exit status \(status))."
            if !details.isEmpty { text += "\n\n" + details.joined(separator: "\n") }
            if let log { text += "\n\nLog: \(log.path)" }
            return text
        case .timedOut(let command, let after, let log):
            var text = "Wine didn't finish “\(command)” within \(after.components.seconds) seconds and was stopped."
            if let log { text += "\n\nLog: \(log.path)" }
            return text
        case .rosettaMissing:
            return "Wine needs Rosetta 2. Install it with: softwareupdate --install-rosetta --agree-to-license"
        }
    }

    /// The log file of the failed run, if any.
    public var log: URL? {
        switch self {
        case .failed(_, _, _, let log), .timedOut(_, _, let log): return log
        case .rosettaMissing: return nil
        }
    }

    /// The lines of Wine's output that explain a failure: errors and loader messages, or
    /// the last few lines if none stand out.
    static func keyLines(in output: [String], limit: Int = 6) -> [String] {
        let markers = ["err:", "Library not loaded", "dyld[", "failed", "Failed", "error", "Error", "wine: "]
        let important = output.filter { line in markers.contains { line.contains($0) } }
        let chosen = important.isEmpty ? Array(output.suffix(limit)) : Array(important.prefix(limit))
        return chosen.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
    }
}

public enum Rosetta {
    /// Whether Rosetta 2 is installed. Wine's engines are Intel programs and need it.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }
}
