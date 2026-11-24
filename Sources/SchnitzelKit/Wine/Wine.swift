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

    /// Starts a Wine process and returns its output stream. The output is also written to
    /// a new log file for this run.
    public static func runWineProcess(
        _ arguments: [String], runtime: WineRuntime, logName: String,
        environment: [String: String] = [:], currentDirectory: URL? = nil
    ) throws -> AsyncStream<ProcessOutput> {
        let process = Process()
        process.executableURL = runtime.wineBinary
        process.arguments = arguments
        process.environment = runtime.environment(extra: environment)
        process.currentDirectoryURL = currentDirectory ?? runtime.pfanne.driveC
        process.qualityOfService = .userInitiated
        let log = try RunLog.create(for: runtime, name: logName)
        return try process.runStream(name: logName, fileHandle: log)
    }

    /// Runs Wine and waits for it, returning everything it printed.
    @discardableResult
    public static func runWine(
        _ arguments: [String], runtime: WineRuntime, logName: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> String {
        var output = ""
        var status: Int32 = 0
        let stream = try runWineProcess(
            arguments, runtime: runtime, logName: logName ?? arguments.first ?? "wine",
            environment: environment)
        for await event in stream {
            switch event {
            case .message(let line):
                output += line + "\n"
            case .terminated(let code):
                status = code
            case .started:
                break
            }
        }
        guard status == 0 else {
            throw WineError.failed(arguments.joined(separator: " "), status: status, output: output)
        }
        return output
    }

    static func runWineserver(_ arguments: [String], runtime: WineRuntime) async throws {
        try await Command.run(runtime.wineserverBinary.path, arguments, environment: runtime.environment())
    }

    /// Waits until every Wine process in the Pfanne has exited and the registry is saved.
    public static func waitForExit(runtime: WineRuntime) async throws {
        try await runWineserver(["-w"], runtime: runtime)
    }

    /// Stops every Wine process in the Pfanne.
    public static func kill(runtime: WineRuntime) async throws {
        try await runWineserver(["-k"], runtime: runtime)
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
        throws -> AsyncStream<ProcessOutput> {
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
                          runtime: runtime, logName: "reg add")
    }

    public static func queryRegistryKey(
        _ key: String, name: String, type: RegistryType, runtime: WineRuntime
    ) async throws -> String? {
        let output = try await runWine(["reg", "query", key, "/v", name], runtime: runtime, logName: "reg query")
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
        try await runWine(["regedit", "/S", "C:\\\(fileName)"], runtime: runtime, logName: "regedit")
    }

    // MARK: Settings

    public static func changeWinVersion(_ version: WinVersion, runtime: WineRuntime) async throws {
        try await runWine(["winecfg", "/v", version.rawValue], runtime: runtime, logName: "winecfg")
    }

    public static func winVersion(runtime: WineRuntime) async throws -> WinVersion? {
        let output = try await runWine(["winecfg", "/v"], runtime: runtime, logName: "winecfg")
        return output.split(whereSeparator: \.isNewline).last.flatMap { WinVersion(rawValue: String($0)) }
    }
}

public enum WineError: Error, LocalizedError, Equatable {
    case failed(String, status: Int32, output: String)
    case rosettaMissing

    public var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let output):
            return "Wine couldn't finish “\(command)” (status \(status)).\n\(output.suffix(800))"
        case .rosettaMissing:
            return "Wine needs Rosetta 2. Install it with: softwareupdate --install-rosetta --agree-to-license"
        }
    }
}

public enum Rosetta {
    /// Whether Rosetta 2 is installed. Wine's engines are Intel programs and need it.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }
}
