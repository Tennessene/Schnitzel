//
//  ProcessStreamTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct ProcessStreamTests {
    @Test func capturesOutputErrorsAndExitStatusInTheStreamAndTheLog() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let logURL = scratch.url.appending(path: "run.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo first; echo problem >&2; printf 'no newline'; exit 3"]
        var messages: [String] = []
        var status: Int32?
        for await event in try process.runStream(name: "sh", fileHandle: log) {
            switch event {
            case .message(let line): messages.append(line)
            case .terminated(let code): status = code
            case .started: break
            }
        }
        #expect(messages == ["first", "problem", "no newline"])
        #expect(status == 3)

        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("first\n"))
        #expect(text.contains("problem\n"))
        #expect(text.contains("Exited with status 3"))
    }

    /// Wine leaves background processes running that keep the output open. The stream
    /// must still finish as soon as the process itself exits.
    @Test func finishesWhenTheProcessExitsEvenIfABackgroundChildKeepsRunning() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The child sleeps 30 s with our output still open; the shell exits at once.
        process.arguments = ["-c", "(sleep 30; echo late) & echo started-child; exit 1"]
        let start = Date()
        var status: Int32?
        var messages: [String] = []
        for await event in try process.runStream(name: "sh", fileHandle: nil) {
            if case .terminated(let code) = event { status = code }
            if case .message(let line) = event { messages.append(line) }
        }
        #expect(status == 1)
        #expect(messages == ["started-child"])
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
