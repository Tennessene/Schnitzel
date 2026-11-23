//
//  SchnitzelApp.swift
//  Schnitzel
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

import AppKit
import SchnitzelKit
import SwiftUI

@main
struct SchnitzelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(SchnitzelInfo.appName, id: AppDelegate.mainWindowID) {
            MainWindowContent(appDelegate: appDelegate)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(SchnitzelInfo.appName)") {
                    AboutPanel.show()
                }
            }
            CommandGroup(replacing: .help) {
                Link("\(SchnitzelInfo.appName) on GitHub", destination: SchnitzelInfo.repositoryURL)
            }
        }
    }
}

/// The main window's content. Also hands the app delegate a way to reopen this window.
private struct MainWindowContent: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .frame(minWidth: 720, minHeight: 440)
            .onAppear {
                let openWindow = openWindow
                appDelegate.reopenMainWindow = {
                    openWindow(id: AppDelegate.mainWindowID)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    /// Set by the main window once it has appeared.
    var reopenMainWindow: (@MainActor () -> Void)?

    // Like most Mac apps, Schnitzel keeps running when its window is closed.
    // It quits with Schnitzel > Quit Schnitzel (⌘Q).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clicking the Dock icon while no window is open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            reopenMainWindow?()
        }
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Lets `swift run` (no .app bundle) show a Dock icon and a menu bar.
        // Inside Schnitzel.app this is already the default.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }
}
