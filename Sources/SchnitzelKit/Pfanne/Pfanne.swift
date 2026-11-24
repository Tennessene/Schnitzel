//
//  Pfanne.swift
//  SchnitzelKit
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

import Foundation

/// A Pfanne: a folder holding `Pfanne.plist` and a Wine prefix.
///
///     Pfannen/GTA V/
///       Pfanne.plist
///       prefix/          (WINEPREFIX: drive_c, *.reg, dosdevices)
///       .applied.json    (the settings last written into the prefix)
public struct Pfanne: Identifiable, Hashable, Sendable {
    public static let settingsFileName = "Pfanne.plist"

    public let url: URL
    public var settings: PfanneSettings

    public init(url: URL, settings: PfanneSettings) {
        self.url = url
        self.settings = settings
    }

    public var id: URL { url }
    public var name: String { settings.name }
    public var settingsURL: URL { url.appending(path: Self.settingsFileName) }
    public var prefixURL: URL { url.appending(path: "prefix", directoryHint: .isDirectory) }
    public var driveC: URL { prefixURL.appending(path: "drive_c", directoryHint: .isDirectory) }
    var appliedStateURL: URL { url.appending(path: ".applied.json") }

    /// How far the Wine prefix got.
    public enum PrefixState: Equatable, Sendable {
        /// Nothing usable yet: `wineboot` hasn't run or didn't get anywhere.
        case missing
        /// Started but unusable: the registry or the C: drive's Windows folder is missing.
        case incomplete(String)
        case ready
    }

    public var prefixState: PrefixState {
        let fileManager = FileManager.default
        let registry = ["system.reg", "user.reg"].filter {
            fileManager.fileExists(atPath: prefixURL.appending(path: $0).path)
        }
        let system32 = driveC.appending(path: "windows/system32")
        let windowsFiles = (try? fileManager.contentsOfDirectory(atPath: system32.path).count) ?? 0
        let hasDriveC = fileManager.fileExists(atPath: driveC.path)

        if registry.isEmpty && !hasDriveC { return .missing }
        if !hasDriveC { return .incomplete("the C: drive (drive_c) is missing") }
        if registry.count < 2 { return .incomplete("the Windows registry is missing") }
        // A real prefix has several hundred files in system32; wineboot that stopped early
        // leaves it empty.
        if windowsFiles < 50 { return .incomplete("the Windows system folder is empty or nearly empty") }
        return .ready
    }

    /// Whether the prefix is complete and programs can run.
    public var isPrefixCreated: Bool { prefixState == .ready }

    /// `~/Library/Logs/Schnitzel/<folder name>/`
    public var logsFolder: URL {
        SchnitzelInfo.logsFolder().appending(path: url.lastPathComponent, directoryHint: .isDirectory)
    }

    public func save() throws {
        try settings.encode(to: settingsURL)
    }

    public static func == (lhs: Pfanne, rhs: Pfanne) -> Bool { lhs.url == rhs.url && lhs.settings == rhs.settings }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// The Pfannen folder.
public struct PfanneStore: Sendable {
    public let root: URL

    public init(root: URL = SchnitzelInfo.pfannenFolder()) {
        self.root = root
    }

    /// All Pfannen, sorted by name. Folders whose settings can't be read are skipped.
    public func list() -> [Pfanne] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> Pfanne? in
                let folder = root.appending(path: name, directoryHint: .isDirectory)
                guard let settings = try? PfanneSettings.decode(from: folder.appending(path: Pfanne.settingsFileName))
                else { return nil }
                return Pfanne(url: folder, settings: settings)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates the folder and settings file for a new Pfanne. The Wine prefix is created
    /// separately by `PfanneSetup`.
    public func create(name rawName: String, engine: String?) throws -> Pfanne {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(name: name) else { throw PfanneError.invalidName }
        guard !list().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw PfanneError.nameInUse(name)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root.appending(path: name, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appending(path: "\(name) \(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        var settings = PfanneSettings(name: name)
        settings.pins.engine = engine
        let pfanne = Pfanne(url: folder, settings: settings)
        try pfanne.save()
        return pfanne
    }

    /// Moves a Pfanne to the Trash, so it can be recovered.
    public func moveToTrash(_ pfanne: Pfanne) throws {
        try FileManager.default.trashItem(at: pfanne.url, resultingItemURL: nil)
    }

    /// Names of the Pfannen that pin `version` of `kind`, now or as their rollback version.
    public func pfannen(using kind: ComponentKind, _ version: String) -> [String] {
        list()
            .filter { $0.settings.pins.version(of: kind) == version || $0.settings.previousPins?.version(of: kind) == version }
            .map(\.name)
    }

    static func isValid(name: String) -> Bool {
        !name.isEmpty && name.count <= 100 && !name.hasPrefix(".")
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\\0")) == nil
    }
}
