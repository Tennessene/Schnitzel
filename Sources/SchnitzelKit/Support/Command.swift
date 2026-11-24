//
//  Command.swift
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

import CryptoKit
import Foundation

/// Runs short helper commands (tar, xattr, …) and waits for them.
public enum Command {
    /// Runs `executable` with `arguments` and returns its combined output.
    /// Throws `ComponentError.commandFailed` on a non-zero exit status.
    ///
    /// Output goes to a temporary file rather than a pipe, so a chatty command can't
    /// fill the pipe buffer and hang.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil) async throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "schnitzel-command-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? output.close()

        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        guard status == 0 else {
            let name = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")
            throw ComponentError.commandFailed(name, status: status, output: text)
        }
        return text
    }

    /// Unpacks a `.tar.xz`, `.tar.gz` or `.tar` archive into `folder` (which must exist).
    public static func untar(_ archive: URL, into folder: URL) async throws {
        try await run("/usr/bin/tar", ["-xf", archive.path, "-C", folder.path])
    }

    /// Removes the quarantine flag macOS puts on downloaded files, so Wine's binaries can run.
    public static func removeQuarantine(_ folder: URL) async throws {
        // xattr exits with an error when no file has the attribute; that's fine.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", folder.path])
    }

    /// SHA-256 of a file, as lowercase hex.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
