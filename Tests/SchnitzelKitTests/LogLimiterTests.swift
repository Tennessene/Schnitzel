//
//  LogLimiterTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct LogLimiterTests {
    static let small = LogLimits(maxBytesPerLog: 1 << 20, keptBytesOnCut: 256 << 10, maxLogsPerPfanne: 3,
                                 maxBytesPerPfanne: 10 << 10)

    /// Opens `url` the way Wine's processes inherit a run log: write-only, append.
    static func appendHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        #expect(fd >= 0)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// The size on disk now (`URL` resource values are cached per URL object).
    static func size(_ url: URL) -> UInt64 {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_size) : 0
    }

    @Test func cutKeepsTheHeaderAndTheNewestOutput() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let log = scratch.url.appending(path: "run.log")
        let writer = try Self.appendHandle(log)
        let header = "Pfanne: Test\nArguments: game.exe\n\n"
        try writer.write(contentsOf: Data(header.utf8))
        for line in 0..<60_000 {
            try writer.write(contentsOf: Data("line \(line) some output from a Windows program\n".utf8))
        }
        #expect(Self.size(log) > Self.small.maxBytesPerLog)

        #expect(try LogLimiter.cut(path: log.path, headerLength: UInt64(header.utf8.count), limits: Self.small))
        let text = try #require(scratch.contents(log))
        #expect(text.hasPrefix(header + "\n[Schnitzel: this log reached "))
        #expect(text.contains("of older output was removed, the newest output follows]\n"))
        #expect(text.hasSuffix("line 59999 some output from a Windows program\n"))
        #expect(!text.contains("line 0 some"))
        // Whole lines only.
        let firstKept = text.split(separator: "\n")[3]
        #expect(firstKept.hasPrefix("line ") && firstKept.hasSuffix("program"))
        #expect(Self.size(log) <= UInt64(header.utf8.count) + 300 + Self.small.keptBytesOnCut)

        // The program's next write lands at the new end: no gap, no old size.
        try writer.write(contentsOf: Data("after the cut\n".utf8))
        let after = try #require(scratch.contents(log))
        #expect(after.hasSuffix("line 59999 some output from a Windows program\nafter the cut\n"))
        #expect(!after.contains("\0"))
    }

    @Test func smallLogsStayAsTheyAre() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let log = scratch.url.appending(path: "run.log")
        try Data("header\nshort output\n".utf8).write(to: log)
        #expect(try !LogLimiter.cut(path: log.path, headerLength: 7, limits: Self.small))
        #expect(scratch.contents(log) == "header\nshort output\n")
    }

    @Test func aProgramWritingTheLogKeepsRunning() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let log = scratch.url.appending(path: "run.log")
        let handle = try Self.appendHandle(log)
        try handle.write(contentsOf: Data("header\n".utf8))

        let program = Process()
        program.executableURL = URL(filePath: "/bin/sh")
        program.arguments = ["-c", "i=0; while :; do echo \"output line $i\"; i=$((i+1)); done"]
        program.standardOutput = handle
        program.standardError = handle
        try program.run()
        defer { if program.isRunning { program.terminate() } }

        let limiter = LogLimiter(limits: Self.small, interval: 3600)
        limiter.watch(log, headerLength: 7)
        var cuts = 0
        for _ in 0..<40 where cuts < 3 {
            try await Task.sleep(for: .milliseconds(100))
            if Self.size(log) > Self.small.maxBytesPerLog {
                limiter.checkNow()
                cuts += 1
            }
        }
        #expect(cuts >= 1)
        #expect(program.isRunning)
        try await Task.sleep(for: .milliseconds(200))
        #expect(program.isRunning)
        program.terminate()
        program.waitUntilExit()

        let text = try #require(scratch.contents(log))
        // The program may write a line between the cut and the note; the header stays first.
        #expect(text.hasPrefix("header\n"))
        #expect(text.contains("[Schnitzel: this log reached "))
        #expect(!text.contains("\0"))
        #expect(Self.size(log) < 3 * Self.small.maxBytesPerLog)
    }

    @Test func pruningKeepsRecentAndOlderUnmarkedLogs() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let folder = scratch.url
        let now = Date.now
        func make(_ name: String, kilobytes: Int, minutesAgo: Double, marked: Bool) throws -> URL {
            let url = folder.appending(path: name)
            try Data(repeating: UInt8(ascii: "x"), count: kilobytes << 10).write(to: url)
            if marked { LogLimiter.mark(url) }
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
            return url
        }
        let busy = try make("a busy.log", kilobytes: 20, minutesAgo: 1, marked: true)        // still written
        let newest = try make("b newest.log", kilobytes: 4, minutesAgo: 30, marked: true)
        let older = try make("c older.log", kilobytes: 4, minutesAgo: 60, marked: true)       // over 10 KB total
        let legacy = try make("d legacy.log", kilobytes: 40, minutesAgo: 90, marked: false)   // from before limits
        let oldest = try make("e oldest.log", kilobytes: 1, minutesAgo: 120, marked: false)   // over the count

        var limits = Self.small
        limits.maxLogsPerPfanne = 4
        RunLog.prune(folder, limits: limits, now: now)
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(exists(busy))
        #expect(!exists(newest))   // busy alone is over the total, so marked older ones go
        #expect(!exists(older))
        #expect(exists(legacy))
        #expect(!exists(oldest))   // the fifth log, over the count
    }
}
