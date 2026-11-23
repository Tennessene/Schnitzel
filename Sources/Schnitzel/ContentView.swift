//
//  ContentView.swift
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

import SchnitzelKit
import SwiftUI

/// Main window. Phase 1 placeholder: the real sidebar and Pfanne views come in Phase 2.
struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section(SchnitzelInfo.pfannePlural) {
                    Text("No \(SchnitzelInfo.pfannePlural) yet")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            ContentUnavailableView {
                Label("Welcome to \(SchnitzelInfo.appName)", systemImage: "frying.pan")
            } description: {
                Text(SchnitzelInfo.tagline)
            }
        }
        .navigationTitle(SchnitzelInfo.appName)
    }
}
