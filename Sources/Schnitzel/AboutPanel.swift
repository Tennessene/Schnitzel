//
//  AboutPanel.swift
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

/// The standard macOS About panel, with Schnitzel's tagline, credits and license.
@MainActor
enum AboutPanel {
    struct Credit {
        let name: String
        let note: String
        let url: String
    }

    static let credits: [Credit] = [
        Credit(name: "Sikarugir", note: "successor to Kegworks and Wineskin",
               url: "https://github.com/Sikarugir-App/Sikarugir"),
        Credit(name: "Kegworks and Wineskin", note: "the original Mac Wine wrappers",
               url: "https://github.com/vitor251093/wineskin"),
        Credit(name: "Whisky", note: "parts of WhiskyKit are reused under GPL-3.0",
               url: "https://github.com/Whisky-App/Whisky"),
        Credit(name: "Wine", note: "runs Windows programs",
               url: "https://www.winehq.org"),
        Credit(name: "Gcenx", note: "Wine builds for macOS",
               url: "https://github.com/Gcenx")
    ]

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: creditsText(),
            // Shown when the app runs without its Info.plist (for example via `swift run`).
            .applicationName: SchnitzelInfo.appName
        ])
        NSApp.activate()
    }

    private static func creditsText() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4

        let plain: [NSAttributedString.Key: Any] = [
            .font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
        ]

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: SchnitzelInfo.tagline + "\n\n", attributes: plain))
        text.append(NSAttributedString(string: "Built on the work of\n", attributes: secondary))
        for credit in credits {
            var link = plain
            link[.font] = bold
            if let url = URL(string: credit.url) { link[.link] = url }
            text.append(NSAttributedString(string: credit.name, attributes: link))
            text.append(NSAttributedString(string: " — \(credit.note)\n", attributes: secondary))
        }
        text.append(NSAttributedString(
            string: "\nFree software under the GNU General Public License v3.0.\n"
                + "D3DMetal is not included; it comes from Apple's Game Porting Toolkit.",
            attributes: secondary))
        return text
    }
}
