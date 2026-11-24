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
            "dxvk-macos-v1.10.3-20230507-repack",
            "dxvk-macos-v1.10.3-20230402"
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
                == "sikarugir-engine-WS12WineSikarugir11.0_1")
        #expect(ComponentSource.wineHQEngines.version(fromAssetName: "wine-staging-11.21-osx64.tar.xz")
                == "winehq-staging-11.21")
        #expect(ComponentSource.dxmt.version(fromAssetName: "dxmt-v0.80-builtin.tar.gz") == "dxmt-v0.80")
        #expect(ComponentSource.sikarugirTemplateLibraries.version(fromAssetName: "Template-1.0.27.tar.xz")
                == "sikarugir-template-1.0.27")
        #expect(!ComponentSource.sikarugirTemplateLibraries.matches(assetName: "Template-1.0.tar.xz"))
    }

    @Test func versionNamesCannotClashBetweenSources() {
        // Versions are "<prefix>-<core>". If no prefix equals another or starts with
        // another followed by "-", two sources can never produce the same name.
        let prefixes = ComponentSource.all.map(\.versionPrefix) + [D3DMetalImport.versionPrefix]
        #expect(Set(prefixes).count == prefixes.count)
        for prefix in prefixes {
            for other in prefixes where other != prefix {
                #expect(!prefix.hasPrefix(other + "-"), "\(prefix) starts with \(other)-")
            }
        }
        #expect(Set(ComponentSource.all.map(\.id)).count == ComponentSource.all.count)
    }

    @Test func oneDefaultSourcePerKind() {
        #expect(ComponentSource.defaultSource(for: .engine) == .sikarugirEngines)
        #expect(ComponentSource.defaultSource(for: .libraries) == .sikarugirTemplateLibraries)
        #expect(ComponentSource.defaultSource(for: .d3dMetal) == nil) // Imported, never downloaded.
        #expect(!ComponentSource.wineHQEngines.isDefault)
        for kind in ComponentKind.allCases {
            #expect(ComponentSource.sources(for: kind).filter(\.isDefault).count <= 1)
        }
    }

    @Test func followsGitHubPagination() {
        let header = #"<https://api.github.com/repositories/1/releases?per_page=100&page=2>; rel="next", <https://api.github.com/repositories/1/releases?per_page=100&page=4>; rel="last""#
        #expect(ReleaseCatalog.nextPage(fromLinkHeader: header)?.absoluteString
                == "https://api.github.com/repositories/1/releases?per_page=100&page=2")
        #expect(ReleaseCatalog.nextPage(fromLinkHeader: #"<https://x/?page=1>; rel="prev""#) == nil)
    }

    @Test func tagPrefixFiltersReleases() throws {
        var source = ComponentSource.dxvk
        source.tagPrefix = "v1.10.3-20230402"
        let available = try ReleaseCatalog.parse(Self.dxvkReleases, source: source)
        #expect(available.map(\.version) == ["dxvk-macos-v1.10.3-20230402"])
    }

    @Test func supportedListDecidesOrderAndRecommendation() throws {
        let available = try ReleaseCatalog.parse(Self.dxvkReleases, source: .dxvk)
        let ordered = ReleaseCatalog.order(available, supported: ["dxvk-macOS-async-v1.10.3-20230402", "missing"],
                                           isDefaultSource: true)
        #expect(ordered.map(\.version) == ["dxvk-macos-v1.10.3-20230402", "dxvk-macos-v1.10.3-20230507-repack"])
        #expect(ordered[0].isRecommended && ordered[0].isSupported)
        #expect(!ordered[1].isRecommended && !ordered[1].isSupported)

        let unlisted = ReleaseCatalog.order(available, supported: nil, isDefaultSource: true)
        #expect(unlisted[0].version == "dxvk-macos-v1.10.3-20230507-repack" && unlisted[0].isRecommended)

        // Only the default source of a kind gets a "Recommended" version.
        let notDefault = ReleaseCatalog.order(available, supported: nil, isDefaultSource: false)
        #expect(notDefault.allSatisfy { !$0.isRecommended })
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
