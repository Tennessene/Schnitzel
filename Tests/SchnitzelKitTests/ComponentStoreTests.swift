//
//  ComponentStoreTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

/// A scratch folder with helpers to build fake component archives.
struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "schnitzel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// Writes `files` (relative path → contents) under `folder` and returns the folder.
    @discardableResult
    func tree(_ folder: String, _ files: [String: String]) throws -> URL {
        let base = url.appending(path: folder)
        for (path, contents) in files {
            let file = base.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        return base
    }

    /// Packs `folder`'s contents into a `.tar.gz`.
    func archive(_ folder: URL, name: String) async throws -> URL {
        let archive = url.appending(path: name)
        try await Command.run("/usr/bin/tar", ["-czf", archive.path, "-C", folder.path, "."])
        return archive
    }

    func contents(_ file: URL) -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }
}

@Suite struct ComponentStoreTests {
    static let sikarugirStyleEngine: [String: String] = [
        "wswine.bundle/bin/wine": "loader",
        "wswine.bundle/bin/wineserver": "server",
        "wswine.bundle/lib/wine/x86_64-windows/d3d11.dll": "wine d3d11",
        "wswine.bundle/lib/wine/x86_64-windows/dxgi.dll": "wine dxgi",
        "wswine.bundle/lib/wine/x86_64-unix/ntdll.so": "ntdll",
        "wswine.bundle/version": "11.0\n"
    ]

    @Test func installsAnEngineAndFindsItsLayout() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let source = try scratch.tree("engine-src", Self.sikarugirStyleEngine)
        let archive = try await scratch.archive(source, name: "engine.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))

        let engine = try await store.install(.engine, version: "WS12WineTest1.0", archive: archive, source: "test")
        #expect(engine.manifest.rootPath == "wswine.bundle")
        #expect(engine.manifest.wineBinary == "bin/wine")
        #expect(engine.manifest.notes.contains("Reports version 11.0"))
        #expect(store.installed(.engine).map(\.version) == ["WS12WineTest1.0"])
        #expect(scratch.contents(engine.root.appending(path: "bin/wine")) == "loader")
        // No staging folder is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.folder(for: .engine).path)
        #expect(leftovers == ["WS12WineTest1.0"])
    }

    @Test func recognizesAnEngineWithItsOwnLibraries() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        var files: [String: String] = [
            "schnitzel-engine-26.3.0-1/bin/wine": "loader",
            "schnitzel-engine-26.3.0-1/bin/wineserver": "server",
            "schnitzel-engine-26.3.0-1/lib/wine/x86_64-unix/ntdll.so": "ntdll",
            "schnitzel-engine-26.3.0-1/version": "26.3.0-1\n"
        ]
        for library in RuntimeLibraries.bundledInEngine {
            files["schnitzel-engine-26.3.0-1/lib/\(library)"] = "library"
        }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let own = try await store.install(
            .engine, version: "schnitzel-engine-26.3.0-1",
            archive: try await scratch.archive(try scratch.tree("own", files), name: "own.tar.gz"), source: "test")
        #expect(own.includesRuntimeLibraries)
        #expect(own.manifest.notes.contains("Includes its own runtime libraries"))

        // One library missing: the engine needs the runtime-libraries component.
        files.removeValue(forKey: "schnitzel-engine-26.3.0-1/lib/libMoltenVK.dylib")
        let partial = try await store.install(
            .engine, version: "partial",
            archive: try await scratch.archive(try scratch.tree("partial", files), name: "partial.tar.gz"), source: "test")
        #expect(!partial.includesRuntimeLibraries)

        let sikarugir = try await store.install(
            .engine, version: "WS12WineTest1.0",
            archive: try await scratch.archive(try scratch.tree("sik", Self.sikarugirStyleEngine), name: "sik.tar.gz"),
            source: "test")
        #expect(!sikarugir.includesRuntimeLibraries)
    }

    @Test func prefersWine64InOlderEngines() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        var files = Self.sikarugirStyleEngine
        files["wswine.bundle/bin/wine64"] = "64-bit loader"
        let archive = try await scratch.archive(try scratch.tree("src", files), name: "e.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let engine = try await store.install(.engine, version: "Old", archive: archive, source: "test")
        #expect(engine.manifest.wineBinary == "bin/wine64")
    }

    @Test func removesD3DMetalThatCameWithAnEngine() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        var files = Self.sikarugirStyleEngine
        files["wswine.bundle/lib/external/D3DMetal.framework/Versions/A/D3DMetal"] = "apple"
        files["wswine.bundle/lib/external/libd3dshared.dylib"] = "apple"
        files["wswine.bundle/lib/external/libother.dylib"] = "keep me"
        let archive = try await scratch.archive(try scratch.tree("src", files), name: "e.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))

        let engine = try await store.install(.engine, version: "WithApple", archive: archive, source: "test")
        let external = engine.root.appending(path: "lib/external")
        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "D3DMetal.framework").path))
        #expect(!FileManager.default.fileExists(atPath: external.appending(path: "libd3dshared.dylib").path))
        #expect(scratch.contents(external.appending(path: "libother.dylib")) == "keep me")
        #expect(engine.manifest.notes.contains { $0.contains("removed") })
    }

    @Test func rejectsArchivesWithoutWineAndLeavesNothing() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await scratch.archive(try scratch.tree("src", ["readme.txt": "hi"]), name: "bad.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))

        await #expect(throws: ComponentError.self) {
            try await store.install(.engine, version: "Bad", archive: archive, source: "test")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.folder(for: .engine).path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func refusesDuplicateAndUnsafeVersionNames() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await scratch.archive(try scratch.tree("src", Self.sikarugirStyleEngine), name: "e.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        _ = try await store.install(.engine, version: "One", archive: archive, source: "test")

        await #expect(throws: ComponentError.alreadyInstalled(.engine, "One")) {
            try await store.install(.engine, version: "One", archive: archive, source: "test")
        }
        for bad in ["", "../escape", "a/b", ".hidden"] {
            await #expect(throws: ComponentError.invalidVersionName(bad)) {
                try await store.install(.engine, version: bad, archive: archive, source: "test")
            }
        }
    }

    @Test func installsDXVKAndListsItsDLLs() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let source = try scratch.tree("dxvk", [
            "dxvk-macOS-async-v1.10.3/x64/d3d11.dll": "", "dxvk-macOS-async-v1.10.3/x64/dxgi.dll": "",
            "dxvk-macOS-async-v1.10.3/x64/d3d9.dll": "", "dxvk-macOS-async-v1.10.3/x32/d3d11.dll": ""
        ])
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let dxvk = try await store.install(.dxvk, version: "v1.10.3", archive: try await scratch.archive(source, name: "d.tar.gz"), source: "test")
        #expect(dxvk.manifest.rootPath == "dxvk-macOS-async-v1.10.3")
        #expect(dxvk.manifest.dlls == ["d3d11", "d3d9", "dxgi"])
    }

    @Test func refusesToRemoveAPinnedVersion() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let archive = try await scratch.archive(try scratch.tree("src", Self.sikarugirStyleEngine), name: "e.tar.gz")
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        _ = try await store.install(.engine, version: "Pinned", archive: archive, source: "test")
        #expect(throws: ComponentError.inUse(.engine, "Pinned", pfannen: ["GTA V"])) {
            try store.remove(.engine, "Pinned", usedBy: ["GTA V"])
        }
        #expect(store.component(.engine, "Pinned") != nil)
    }

    @Test func buildsADXMTAssemblyWithoutTouchingTheEngine() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let engine = try await store.install(
            .engine, version: "E1",
            archive: try await scratch.archive(try scratch.tree("e", Self.sikarugirStyleEngine), name: "e.tar.gz"),
            source: "test")
        let dxmt = try await store.install(
            .dxmt, version: "v0.80",
            archive: try await scratch.archive(try scratch.tree("m", [
                "dxmt-v0.80/x86_64-windows/d3d11.dll": "dxmt d3d11",
                "dxmt-v0.80/x86_64-windows/winemetal.dll": "winemetal",
                "dxmt-v0.80/x86_64-unix/winemetal.so": "winemetal unix"
            ]), name: "m.tar.gz"),
            source: "test")

        let root = try store.engineRoot(engine: engine, provider: .dxmt, overlay: dxmt)
        let dlls = root.appending(path: "lib/wine/x86_64-windows")
        #expect(scratch.contents(dlls.appending(path: "d3d11.dll")) == "dxmt d3d11")
        #expect(scratch.contents(dlls.appending(path: "dxgi.dll")) == "wine dxgi")
        #expect(scratch.contents(root.appending(path: "lib/wine/x86_64-unix/winemetal.so")) == "winemetal unix")
        // The engine itself is unchanged.
        #expect(scratch.contents(engine.root.appending(path: "lib/wine/x86_64-windows/d3d11.dll")) == "wine d3d11")
        // A second call reuses the cached assembly.
        #expect(try store.engineRoot(engine: engine, provider: .dxmt, overlay: dxmt) == root)
        // WineD3D runs the engine directly.
        #expect(try store.engineRoot(engine: engine, provider: .wineD3D, overlay: nil) == engine.root)
    }

    @Test func importsD3DMetalAndOverlaysIt() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let engine = try await store.install(
            .engine, version: "E1",
            archive: try await scratch.archive(try scratch.tree("e", Self.sikarugirStyleEngine), name: "e.tar.gz"),
            source: "test")
        let volume = try scratch.tree("Evaluation environment for Windows games 3.0", [
            "redist/lib/external/D3DMetal.framework/Versions/A/D3DMetal": "apple d3dmetal",
            "redist/lib/external/libd3dshared.dylib": "shared",
            "redist/lib/wine/x86_64-windows/d3d11.dll": "apple d3d11",
            "redist/lib/wine/x86_64-windows/d3d12.dll": "apple d3d12",
            "redist/lib/wine/x86_64-unix/d3d12.so": "apple unix"
        ])
        let lib = try #require(ComponentInspector.d3dMetalLibFolder(in: volume))
        #expect(lib.path.hasSuffix("redist/lib"))

        let d3dMetal = try await store.importFolder(.d3dMetal, version: "3.0", from: lib, sourceDescription: "test")
        #expect(d3dMetal.manifest.rootPath == "lib")

        var pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "D3DMetal", engine: "E1")
        pfanne.settings.pins.d3dMetal = d3dMetal.version
        let env = try WineRuntime.prepare(for: pfanne, store: store).environment()
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"]?.hasSuffix("lib/external/libd3dshared.dylib") == true)
        #expect(env["CX_ACTIVE_GRAPHICS_BACKEND"] == "d3dmetal")

        let root = try store.engineRoot(engine: engine, provider: .d3dMetal, overlay: d3dMetal)
        #expect(scratch.contents(root.appending(path: "lib/wine/x86_64-windows/d3d11.dll")) == "apple d3d11")
        #expect(scratch.contents(root.appending(path: "lib/wine/x86_64-windows/dxgi.dll")) == "wine dxgi")
        #expect(scratch.contents(root.appending(path: "lib/external/libd3dshared.dylib")) == "shared")
        #expect(scratch.contents(root.appending(path: "bin/wine")) == "loader")
    }
}

@Suite struct D3DMetalImportTests {
    @Test func findsMountedToolkitsAndImportsOnce() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let volumes = scratch.url.appending(path: "Volumes")
        try scratch.tree("Volumes/Evaluation environment for Windows games 3.0", [
            "redist/lib/external/D3DMetal.framework/Versions/A/D3DMetal": "apple",
            "redist/lib/wine/x86_64-windows/d3d12.dll": "apple d3d12"
        ])
        try scratch.tree("Volumes/Macintosh HD/Users/readme.txt", ["x": "y"])

        let toolkits = D3DMetalImport.mountedToolkits(volumes: volumes)
        #expect(toolkits.map(\.lastPathComponent) == ["Evaluation environment for Windows games 3.0"])

        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let first = try await D3DMetalImport.importD3DMetal(from: toolkits[0], store: store)
        #expect(first.version == "gptk-3.0") // No Info.plist in the fake framework, so from the name.
        #expect(first.manifest.sourceID == D3DMetalImport.sourceID)
        let again = try await D3DMetalImport.importD3DMetal(from: toolkits[0], store: store)
        #expect(again.id == first.id)
        #expect(store.installed(.d3dMetal).count == 1)
    }

    @Test func rejectsFoldersWithoutD3DMetal() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let folder = try scratch.tree("Random", ["file.txt": "x"])
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        await #expect(throws: ComponentError.self) {
            try await D3DMetalImport.importD3DMetal(from: folder, store: store)
        }
    }
}

@Suite struct RuntimeLibrariesTests {
    /// A fake Sikarugir Template with libraries Wine needs and things that must be dropped.
    func fakeTemplate(_ scratch: Scratch, missing: String? = nil) async throws -> URL {
        let frameworks = "Template-1.0.27.app/Contents/Frameworks"
        var files: [String: String] = [
            "\(frameworks)/libfreetype.6.dylib": "freetype",
            "\(frameworks)/libgnutls.30.dylib": "gnutls",
            "\(frameworks)/libnettle.8.11.dylib": "nettle",
            "\(frameworks)/libvulkan.1.4.363.dylib": "vulkan loader",
            "\(frameworks)/libMVK.dylib": "moltenvk",
            "\(frameworks)/libSDL2-2.0.0.dylib": "sdl2",
            "\(frameworks)/libinotify.0.dylib": "inotify",
            // Not needed by Wine, or not open source: must not be kept.
            "\(frameworks)/libgnutls-openssl.27.dylib": "no",
            "\(frameworks)/libavcodec.61.dylib": "no",
            "\(frameworks)/libdxcompiler.dylib": "no",
            "\(frameworks)/SikarugirSdk.framework/SikarugirSdk": "closed",
            "\(frameworks)/GStreamer.framework/Versions/1.0/lib/libz.1.dylib": "inside gstreamer",
            "Template-1.0.27.app/Contents/MacOS/wineskinlauncher": "closed",
            "Template-1.0.27.app/Contents/SharedSupport/renderer/d3dmetal/external/libd3dshared.dylib": "apple",
            "Template-1.0.27.app/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json":
                #"{"file_format_version": "1.0.0", "ICD": {"library_path": "../../../Frameworks/libMVK.dylib", "api_version": "1.4.0"}}"#
        ]
        if let missing { files["\(frameworks)/\(missing)"] = nil }
        let root = try scratch.tree("template", files)
        let fm = FileManager.default
        let fw = root.appending(path: frameworks)
        try fm.createSymbolicLink(atPath: fw.appending(path: "libvulkan.1.dylib").path, withDestinationPath: "libvulkan.1.4.363.dylib")
        try fm.createSymbolicLink(atPath: fw.appending(path: "libMoltenVK.dylib").path, withDestinationPath: "libvulkan.1.dylib")
        try fm.createSymbolicLink(atPath: fw.appending(path: "libnettle.8.dylib").path, withDestinationPath: "libnettle.8.11.dylib")
        try fm.createSymbolicLink(atPath: fw.appending(path: "libsneaky.dylib").path, withDestinationPath: "../MacOS/wineskinlauncher")
        return try await scratch.archive(root, name: "Template-1.0.27.tar.gz")
    }

    @Test func keepsOnlyTheOpenSourceLibrariesWineNeeds() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let libraries = try await store.install(
            .libraries, version: "sikarugir-template-1.0.27", archive: try await fakeTemplate(scratch),
            source: "test", sourceID: ComponentSource.sikarugirTemplateLibraries.id)

        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: libraries.root.path))
        #expect(kept == [
            "libfreetype.6.dylib", "libgnutls.30.dylib", "libnettle.8.11.dylib", "libnettle.8.dylib",
            "libvulkan.1.4.363.dylib", "libvulkan.1.dylib", "libMoltenVK.dylib", "libMVK.dylib",
            "libSDL2-2.0.0.dylib", "libinotify.0.dylib", "vulkan"
        ])
        // Nothing else from the download survives.
        let everything = (FileManager.default.enumerator(atPath: libraries.folder.path)?.allObjects as? [String]) ?? []
        #expect(!everything.contains { $0.contains("Template-1.0.27.app") || $0.contains("d3dshared") || $0.contains("Sikarugir") })
        #expect(libraries.manifest.notes.first?.contains("Temporary") == true)

        // The Vulkan driver file points at MoltenVK next to it.
        let icd = libraries.root.appending(path: "vulkan/icd.d/MoltenVK_icd.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: icd)) as? [String: Any]
        let entry = json?["ICD"] as? [String: Any]
        #expect(entry?["library_path"] as? String == "../../libMVK.dylib")
        #expect(entry?["api_version"] as? String == "1.4.0")
        #expect(scratch.contents(icd.deletingLastPathComponent().appending(path: "../../libMVK.dylib").standardizedFileURL) == "moltenvk")
    }

    @Test func refusesATemplateWithoutARequiredLibrary() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let archive = try await fakeTemplate(scratch, missing: "libSDL2-2.0.0.dylib")
        await #expect(throws: ComponentError.self) {
            try await store.install(.libraries, version: "sikarugir-template-1.0.27", archive: archive, source: "test")
        }
        #expect(store.installed(.libraries).isEmpty)
    }

    @Test func wineFindsTheLibraries() async throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        _ = try await store.install(
            .engine, version: "E1",
            archive: try await scratch.archive(try scratch.tree("e", ComponentStoreTests.sikarugirStyleEngine), name: "e.tar.gz"),
            source: "test")
        let libraries = try await store.install(
            .libraries, version: "L1", archive: try await fakeTemplate(scratch), source: "test")
        var pfanne = try PfanneStore(root: scratch.url.appending(path: "Pfannen")).create(name: "Test", engine: "E1")
        pfanne.settings.pins.libraries = "L1"

        let env = try WineRuntime.prepare(for: pfanne, store: store).environment()
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(libraries.root.path) == true)
        #expect(env["VK_DRIVER_FILES"]?.hasSuffix("vulkan/icd.d/MoltenVK_icd.json") == true)
        #expect(env["WINEDLLOVERRIDES"] == nil)
    }
}

/// Runs only with SCHNITZEL_TEMPLATE_ARCHIVE=/path/to/Template-1.0.27.tar.xz.
@Suite struct RealTemplateTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCHNITZEL_TEMPLATE_ARCHIVE"] != nil))
    func extractsFromTheRealTemplate() async throws {
        let archive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCHNITZEL_TEMPLATE_ARCHIVE"]!)
        let scratch = try Scratch(); defer { scratch.remove() }
        let store = ComponentStore(root: scratch.url.appending(path: "Components"))
        let libraries = try await store.install(.libraries, version: "sikarugir-template-1.0.27", archive: archive, source: "test")
        let names = try FileManager.default.contentsOfDirectory(atPath: libraries.root.path).sorted()
        print("Kept: \(names.joined(separator: " "))")
        for required in RuntimeLibraries.required {
            #expect(FileManager.default.fileExists(atPath: libraries.root.appending(path: required).resolvingSymlinksInPath().path))
        }
        let everything = (FileManager.default.enumerator(atPath: libraries.folder.path)?.allObjects as? [String]) ?? []
        for fragment in RuntimeLibraries.forbiddenFragments {
            #expect(!everything.contains { $0.contains(fragment) }, "\(fragment) was kept")
        }
    }
}
