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
//  - Swift 6 strict concurrency: `ProcessOutput` is Sendable and carries the pid and
//    exit status instead of the Process object.
//  - The pipe readability handlers are removed at end of file. Whisky's handlers kept
//    firing with empty data after the process exited, which wasted CPU.
//  - Output is split into lines before it is yielded, instead of yielding raw chunks.
//  - Remaining output is flushed into the stream and the log before termination.
//  - Logging goes to `Logger.schnitzelKit`.
//

import Foundation
import os.log

public enum ProcessOutput: Hashable, Sendable {
    case started(pid: Int32)
    case message(String)
    case error(String)
    case terminated(status: Int32)
}

public extension Process {
    /// Runs the process and returns a stream of its output, line by line.
    ///
    /// Everything the process prints is also written to `fileHandle` when given.
    /// Cancelling the stream terminates the process.
    func runStream(name: String, fileHandle: FileHandle?) throws -> AsyncStream<ProcessOutput> {
        let stream = makeStream(name: name, fileHandle: fileHandle)
        self.logProcessInfo(name: name)
        fileHandle?.writeInfo(for: self)
        try run()
        return stream
    }

    private func makeStream(name: String, fileHandle: FileHandle?) -> AsyncStream<ProcessOutput> {
        let pipe = Pipe()
        let errorPipe = Pipe()
        standardOutput = pipe
        standardError = errorPipe

        let process = self
        let log = fileHandle
        let outputBuffer = LineBuffer()
        let errorBuffer = LineBuffer()

        return AsyncStream<ProcessOutput> { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination, process.isRunning {
                    process.terminate()
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil // End of file.
                    return
                }
                for line in outputBuffer.append(data) {
                    continuation.yield(.message(line))
                    Logger.schnitzelKit.info("\(line, privacy: .public)")
                    log?.write(line: line + "\n")
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil // End of file.
                    return
                }
                for line in errorBuffer.append(data) {
                    continuation.yield(.error(line))
                    Logger.schnitzelKit.warning("\(line, privacy: .public)")
                    log?.write(line: line + "\n")
                }
            }

            terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                // Whatever is still in the pipes after the process exited.
                let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
                let errorRest = (try? errorPipe.fileHandleForReading.readToEnd()) ?? nil
                for line in outputBuffer.append(rest ?? Data()) + outputBuffer.flush() {
                    continuation.yield(.message(line))
                    log?.write(line: line + "\n")
                }
                for line in errorBuffer.append(errorRest ?? Data()) + errorBuffer.flush() {
                    continuation.yield(.error(line))
                    log?.write(line: line + "\n")
                }

                finished.logTermination(name: name)
                log?.write(line: "\nExited with status \(finished.terminationStatus)\n")
                try? log?.close()
                continuation.yield(.terminated(status: finished.terminationStatus))
                continuation.finish()
            }

            continuation.yield(.started(pid: process.processIdentifier))
        }
    }

    private func logTermination(name: String) {
        if terminationStatus == 0 {
            Logger.schnitzelKit.info(
                "Terminated \(name) with status code '\(self.terminationStatus, privacy: .public)'"
            )
        } else {
            Logger.schnitzelKit.warning(
                "Terminated \(name) with status code '\(self.terminationStatus, privacy: .public)'"
            )
        }
    }

    private func logProcessInfo(name: String) {
        Logger.schnitzelKit.info("Running process \(name)")

        if let arguments = arguments {
            Logger.schnitzelKit.info("Arguments: `\(arguments.joined(separator: " "))`")
        }
        if let executableURL = executableURL {
            Logger.schnitzelKit.info("Executable: `\(executableURL.path(percentEncoded: false))`")
        }
        if let directory = currentDirectoryURL {
            Logger.schnitzelKit.info("Directory: `\(directory.path(percentEncoded: false))`")
        }
    }
}

/// Collects bytes from a pipe and hands out complete UTF-8 lines.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    /// Adds `data` and returns every line that is now complete, without the newline.
    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    /// Returns the last line if it had no trailing newline.
    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [line]
    }
}
