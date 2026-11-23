// swift-tools-version: 6.0
//
//  Package.swift
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

import PackageDescription

let package = Package(
    name: "Schnitzel",
    platforms: [
        // D3DMetal (Game Porting Toolkit) needs macOS Sonoma or later.
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Schnitzel", targets: ["Schnitzel"]),
        .library(name: "SchnitzelKit", targets: ["SchnitzelKit"])
    ],
    targets: [
        // Core logic: Pfannen, Wine engines, components. No UI code.
        .target(name: "SchnitzelKit"),
        // The SwiftUI app.
        .executableTarget(
            name: "Schnitzel",
            dependencies: ["SchnitzelKit"]
        ),
        .testTarget(
            name: "SchnitzelKitTests",
            dependencies: ["SchnitzelKit"]
        )
    ]
)
