//
//  Process+Extensions.swift
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
//  copied from Whisky commit fd5480a. Changes:
//  - Output goes straight to the log file instead of through pipes. Wine starts
//    background processes (wineserver, winedevice, explorer) that inherit the
//    process's output and keep it open long after the process itself exits, so
//    waiting for a pipe to reach end-of-file could hang forever. A file never blocks.
//  - The stream reports `.started`, every line of output once the process has exited,
//    and `.terminated`. Output and errors are combined, in the order they were written.
//  - Swift 6 strict concurrency: `ProcessOutput` is Sendable and carries the pid and
//    exit status instead of the Process object.
//  - Logging goes to `Logger.schnitzelKit`.
//

import Foundation
import os.log

public enum ProcessOutput: Hashable, Sendable {
    case started(pid: Int32)
    /// One line of output (standard output and standard error combined).
    case message(String)
    case terminated(status: Int32)
}

public extension Process {
    /// Runs the process and returns a stream of events.
    ///
    /// Output is written to `fileHandle` (a log file). Without one, a temporary file is
    /// used and deleted afterwards. The output's lines are yielded after the process
    /// exits; output that background processes write later stays in the log only.
    /// Cancelling the stream terminates the process.
    func runStream(name: String, fileHandle: FileHandle?) throws -> AsyncStream<ProcessOutput> {
        let temporary: URL?
        let log: FileHandle
        if let fileHandle {
            temporary = nil
            log = fileHandle
        } else {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "schnitzel-process-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            temporary = url
            log = try FileHandle(forWritingTo: url)
        }

        logProcessInfo(name: name)
        log.writeInfo(for: self)
        try log.synchronize()
        let outputStart = try log.offset()
        let logPath = Self.path(of: log, fallback: temporary)

        // Child processes share this open file and its position, so their writes follow
        // each other in order.
        standardOutput = log
        standardError = log
        if standardInput == nil {
            standardInput = FileHandle.nullDevice
        }

        let process = self
        let stream = AsyncStream<ProcessOutput> { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination, process.isRunning {
                    process.terminate()
                }
            }

            terminationHandler = { finished in
                let lines = Self.lines(in: logPath, from: outputStart)
                for line in lines {
                    continuation.yield(.message(line))
                }
                finished.logTermination(name: name, lastLines: lines.suffix(5))
                log.write(line: "\nExited with status \(finished.terminationStatus)\n")
                try? log.close()
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                continuation.yield(.terminated(status: finished.terminationStatus))
                continuation.finish()
            }
        }

        do {
            try run()
        } catch {
            terminationHandler = nil
            try? log.close()
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
        return stream.withStart(pid: processIdentifier)
    }

    /// The lines in `path` from byte `offset` on.
    private static func lines(in path: String?, from offset: UInt64) -> [String] {
        guard let path, let reader = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: offset)) != nil,
              let data = try? reader.readToEnd() else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .reversed().drop(while: \.isEmpty).reversed()
    }

    private static func path(of handle: FileHandle, fallback: URL?) -> String? {
        if let fallback { return fallback.path }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle.fileDescriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func logTermination(name: String, lastLines: ArraySlice<String>) {
        if terminationStatus == 0 {
            Logger.schnitzelKit.info(
                "Terminated \(name, privacy: .public) with status code '\(self.terminationStatus, privacy: .public)'"
            )
        } else {
            let tail = lastLines.joined(separator: " | ")
            Logger.schnitzelKit.warning(
                "Terminated \(name, privacy: .public) with status code '\(self.terminationStatus, privacy: .public)': \(tail, privacy: .public)"
            )
        }
    }

    private func logProcessInfo(name: String) {
        Logger.schnitzelKit.info("Running process \(name, privacy: .public)")

        if let arguments = arguments {
            Logger.schnitzelKit.info("Arguments: `\(arguments.joined(separator: " "), privacy: .public)`")
        }
        if let executableURL = executableURL {
            Logger.schnitzelKit.info("Executable: `\(executableURL.path(percentEncoded: false), privacy: .public)`")
        }
    }
}

private extension AsyncStream where Element == ProcessOutput {
    /// Puts `.started` in front of the stream's events.
    func withStart(pid: Int32) -> AsyncStream<ProcessOutput> {
        let base = self
        return AsyncStream { continuation in
            continuation.yield(.started(pid: pid))
            let task = Task {
                for await event in base { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
