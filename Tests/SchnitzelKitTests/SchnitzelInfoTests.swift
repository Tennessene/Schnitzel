//
//  SchnitzelInfoTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct SchnitzelInfoTests {
    @Test func foldersLiveUnderSchnitzelApplicationSupport() {
        let support = SchnitzelInfo.applicationSupportFolder()
        #expect(support.lastPathComponent == "Schnitzel")
        #expect(support.deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(SchnitzelInfo.pfannenFolder().deletingLastPathComponent() == support)
        #expect(SchnitzelInfo.componentsFolder().deletingLastPathComponent() == support)
    }

    @Test func dataFolderCanBeMovedForChecks() {
        #expect(SchnitzelInfo.dataFolderOverride([:]) == nil)
        #expect(SchnitzelInfo.dataFolderOverride([SchnitzelInfo.dataFolderVariable: ""]) == nil)
        #expect(SchnitzelInfo.dataFolderOverride([SchnitzelInfo.dataFolderVariable: "/tmp/check"])?.path == "/tmp/check")
    }

    @Test func userFacingTermsUsePfanne() {
        #expect(SchnitzelInfo.pfanneSingular == "Pfanne")
        #expect(SchnitzelInfo.pfannePlural == "Pfannen")
    }
}
