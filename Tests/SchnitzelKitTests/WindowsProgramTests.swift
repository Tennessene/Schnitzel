//
//  WindowsProgramTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct WindowsProgramTests {
    @Test func acceptsWindowsProgramsByExtensionInAnyCase() {
        for name in ["SteamSetup.exe", "GAME.EXE", "Setup.msi", "run.bat", "start.cmd", "Game.lnk", "old.com", "Installer.Exe"] {
            #expect(WindowsProgram.hasRunnableExtension(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["archive.zip", "manual.pdf", "notes.txt", "exe", "game.exe.zip", "Steam.app", "noextension"] {
            #expect(!WindowsProgram.hasRunnableExtension(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func pickerEnablesFoldersAndProgramsButNotOtherFilesOrApps() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        try scratch.tree("Downloads", ["SteamSetup.exe": "MZ", "readme.pdf": "%PDF", "Setup.MSI": "x"])
        let downloads = scratch.url.appending(path: "Downloads")
        let app = downloads.appending(path: "Some.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads.appending(path: "Games"), withIntermediateDirectories: true)

        #expect(WindowsProgram.isSelectableInPicker(downloads.appending(path: "SteamSetup.exe")))
        #expect(WindowsProgram.isSelectableInPicker(downloads.appending(path: "Setup.MSI")))
        #expect(WindowsProgram.isSelectableInPicker(downloads.appending(path: "Games")))
        #expect(!WindowsProgram.isSelectableInPicker(downloads.appending(path: "readme.pdf")))
        #expect(!WindowsProgram.isSelectableInPicker(downloads.appending(path: "Some.app")))
    }

    @Test func everyRunnableExtensionHasALaunchCommand() {
        for ext in WindowsProgram.extensions {
            #expect(!Wine.launchArguments(for: URL(fileURLWithPath: "/g/file.\(ext)")).isEmpty)
        }
    }
}
