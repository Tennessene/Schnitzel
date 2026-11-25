//
//  LogLimiter.swift
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
import os.log

/// How big run logs may get.
public struct LogLimits: Equatable, Sendable {
    /// A log that grows past this is cut while its programs keep running.
    public var maxBytesPerLog: UInt64
    /// What a cut keeps: the header and this much of the newest output.
    public var keptBytesOnCut: UInt64
    /// At most this many logs per Pfanne; older ones are deleted when a new log starts.
    public var maxLogsPerPfanne: Int
    /// At most this much in logs per Pfanne; the oldest are deleted when a new log starts.
    public var maxBytesPerPfanne: UInt64

    /// A normal run writes a few kilobytes; a run with Wine's debug channels on, or a program
    /// that keeps printing for hours (Steam started by its installer), can write gigabytes.
    public static let standard = LogLimits(
        maxBytesPerLog: 64 << 20, keptBytesOnCut: 16 << 20, maxLogsPerPfanne: 50, maxBytesPerPfanne: 512 << 20)
}

/// Keeps run logs within `LogLimits` while Wine writes them.
///
/// Wine and every program it starts write straight into the log file, and some of them
/// (Steam, launchers, wineserver's children) keep the file open long after the program
/// Schnitzel started has exited. So Schnitzel can't sit between them and the file. Instead,
/// logs are opened append-only (`O_APPEND`), which every child inherits: each write goes to
/// the current end of the file, even after the file was shortened. The limiter checks the
/// logs of this session every few seconds and cuts one that got too big: it keeps the header,
/// a note, and the newest output, and shortens the file. Writers are never blocked, signalled
/// or stopped; output written in the moment between reading the newest part and shortening
/// the file is lost.
public final class LogLimiter: @unchecked Sendable {
    public static let shared = LogLimiter()

    /// Extended attribute marking logs written with limits, so pruning by size never deletes
    /// logs from before this change (or files someone put in the folder).
    static let markerAttribute = "io.github.tennessene.schnitzel.run-log"

    public var limits: LogLimits
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "io.github.tennessene.Schnitzel.LogLimiter")
    private var watched: [String: UInt64] = [:] // path → header length
    private var timer: DispatchSourceTimer?

    public init(limits: LogLimits = .standard, interval: TimeInterval = 5) {
        self.limits = limits
        self.interval = interval
    }

    /// Starts watching a log whose first `headerLength` bytes must always be kept.
    public func watch(_ url: URL, headerLength: UInt64) {
        queue.sync {
            watched[url.path] = headerLength
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
                timer.setEventHandler { [weak self] in self?.checkAll() }
                timer.resume()
                self.timer = timer
            }
        }
    }

    /// Checks every watched log now (the timer does this every few seconds).
    public func checkNow() {
        queue.sync { checkAll() }
    }

    private func checkAll() {
        for (path, header) in watched {
            guard FileManager.default.fileExists(atPath: path) else {
                watched[path] = nil
                continue
            }
            do {
                if try Self.cut(path: path, headerLength: header, limits: limits) {
                    Logger.schnitzelKit.info("Cut the run log \(path, privacy: .public) to its newest output")
                }
            } catch {
                Logger.schnitzelKit.warning("Couldn't cut the run log \(path, privacy: .public): \(error)")
            }
        }
    }

    /// Cuts the log at `path` if it's larger than `limits.maxBytesPerLog`. Returns true if it did.
    @discardableResult
    static func cut(path: String, headerLength: UInt64, limits: LogLimits) throws -> Bool {
        let fd = open(path, O_RDWR | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let size = UInt64(info.st_size)
        guard size > limits.maxBytesPerLog, size > headerLength else { return false }

        // The newest output, starting at a line break so no line is cut in half.
        let keep = min(limits.keptBytesOnCut, size - headerLength)
        var tail = [UInt8](repeating: 0, count: Int(keep))
        let read = tail.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(keep), off_t(size - keep)) }
        guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var kept = tail.prefix(read)
        if let newline = kept.firstIndex(of: UInt8(ascii: "\n")), newline < kept.endIndex - 1 {
            kept = kept[(newline + 1)...]
        }

        let removed = size - headerLength - UInt64(kept.count)
        let note = "\n[\(SchnitzelInfo.appName): this log reached \(Self.megabytes(size)); "
            + "\(Self.megabytes(removed)) of older output was removed, the newest output follows]\n"
        guard ftruncate(fd, off_t(headerLength)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let data = Array(note.utf8) + kept
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += written
        }
        return true
    }

    static func megabytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Marker

    static func mark(_ url: URL) {
        let value: [UInt8] = [1]
        _ = url.withUnsafeFileSystemRepresentation { path in
            path.map { setxattr($0, markerAttribute, value, value.count, 0, 0) }
        }
    }

    static func isMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            path.map { getxattr($0, markerAttribute, nil, 0, 0, 0) >= 0 } ?? false
        }
    }
}
