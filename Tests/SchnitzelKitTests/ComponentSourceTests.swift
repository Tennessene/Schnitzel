//
//  ComponentSourceTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

@Suite struct ComponentSourceTests {
    static let dxvkReleases = Data(#"""
    [
      {"tag_name": "v1.10.3-20230507-repack", "draft": false, "prerelease": false,
       "published_at": "2024-07-23T10:00:00Z",
       "assets": [
         {"name": "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz", "size": 10,
          "browser_download_url": "https://example.com/builtin.tar.gz", "digest": null,
          "updated_at": "2024-07-23T10:00:00Z"},
         {"name": "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz", "size": 20,
          "browser_download_url": "https://example.com/plain.tar.gz",
          "digest": "sha256:9909b486aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "updated_at": "2024-07-23T10:00:00Z"}
       ]},
      {"tag_name": "v1.10.3-20230402", "draft": false, "prerelease": false,
       "published_at": "2023-04-02T10:00:00Z",
       "assets": [
         {"name": "dxvk-macOS-async-v1.10.3-20230402-CrossOver.tar.gz", "size": 30,
          "browser_download_url": "https://example.com/cx.tar.gz", "updated_at": "2023-04-02T10:00:00Z"},
         {"name": "dxvk-macOS-async-v1.10.3-20230402.tar.gz", "size": 40,
          "browser_download_url": "https://example.com/old.tar.gz", "updated_at": "2023-04-02T10:00:00Z"}
       ]},
      {"tag_name": "v2-beta", "draft": false, "prerelease": true, "published_at": "2025-01-01T10:00:00Z",
       "assets": [
         {"name": "dxvk-macOS-async-v2-beta.tar.gz", "size": 50,
          "browser_download_url": "https://example.com/beta.tar.gz", "updated_at": "2025-01-01T10:00:00Z"}
       ]}
    ]
    """#.utf8)

    @Test func keepsOnlyMatchingStableAssetsNewestFirst() throws {
        let available = try ReleaseCatalog.parse(Self.dxvkReleases, source: .dxvk)
        #expect(available.map(\.version) == [
            "dxvk-macOS-async-v1.10.3-20230507-repack",
            "dxvk-macOS-async-v1.10.3-20230402"
        ])
        #expect(available[0].sha256 == "9909b486aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(available[1].sha256 == nil)
        #expect(available[0].kind == .dxvk)
    }

    @Test func sourcePatternsMatchRealAssetNames() {
        #expect(ComponentSource.sikarugirEngines.matches(assetName: "WS12WineSikarugir11.0_1.tar.xz"))
        #expect(!ComponentSource.sikarugirEngines.matches(assetName: "WS11WineCX21.2.0.tar.xz"))
        #expect(ComponentSource.wineHQEngines.matches(assetName: "wine-staging-11.21-osx64.tar.xz"))
        #expect(ComponentSource.dxmt.matches(assetName: "dxmt-v0.80-builtin.tar.gz"))
        #expect(ComponentSource.sikarugirEngines.version(fromAssetName: "WS12WineSikarugir11.0_1.tar.xz")
                == "WS12WineSikarugir11.0_1")
    }

    @Test func supportedListDecidesOrderAndRecommendation() throws {
        let available = try ReleaseCatalog.parse(Self.dxvkReleases, source: .dxvk)
        let ordered = ReleaseCatalog.order(available, supported: ["dxvk-macOS-async-v1.10.3-20230402", "missing"])
        #expect(ordered.map(\.version) == ["dxvk-macOS-async-v1.10.3-20230402", "dxvk-macOS-async-v1.10.3-20230507-repack"])
        #expect(ordered[0].isRecommended && ordered[0].isSupported)
        #expect(!ordered[1].isRecommended && !ordered[1].isSupported)

        let unlisted = ReleaseCatalog.order(available, supported: nil)
        #expect(unlisted[0].version == "dxvk-macOS-async-v1.10.3-20230507-repack" && unlisted[0].isRecommended)
    }

    @Test func rejectsMalformedDigests() {
        #expect(ReleaseCatalog.sha256(fromDigest: "md5:abc") == nil)
        #expect(ReleaseCatalog.sha256(fromDigest: "sha256:xyz") == nil)
    }

    @Test func downloadsVerifiesAndInstalls() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await scratch.archive(
            try scratch.tree("src", ComponentStoreTests.sikarugirStyleEngine), name: "engine.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let hash = try Command.sha256(of: archive)

        let good = AvailableComponent(
            source: ComponentSourceID(id: "test"), kind: .engine, version: "Good", assetName: "engine.tar.gz",
            downloadURL: archive, size: 0, sha256: hash, published: .now, releaseTag: "t")
        let installed = try await ComponentDownloader(store: store).download(good) { _ in }
        #expect(installed.manifest.sha256 == hash)

        let tampered = AvailableComponent(
            source: ComponentSourceID(id: "test"), kind: .engine, version: "Bad", assetName: "engine.tar.gz",
            downloadURL: archive, size: 0, sha256: String(repeating: "0", count: 64), published: .now,
            releaseTag: "t")
        await #expect(throws: ComponentError.self) {
            try await ComponentDownloader(store: store).download(tampered) { _ in }
        }
        #expect(store.component(.engine, "Bad") == nil)
    }

    /// Checks the source definitions against GitHub. Only runs with SCHNITZEL_NETWORK_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCHNITZEL_NETWORK_TESTS"] == "1"))
    func everySourceListsVersionsOnGitHub() async throws {
        for source in ComponentSource.all {
            let available = try await ReleaseCatalog().available(from: source)
            #expect(!available.isEmpty, "\(source.id) lists nothing")
            if let newest = available.first {
                print("\(source.id): \(available.count) versions, recommended \(newest.version), sha256: \(newest.sha256 != nil)")
            }
        }
    }
}
