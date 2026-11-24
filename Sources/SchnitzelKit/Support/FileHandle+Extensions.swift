//
//  FileHandle+Extensions.swift
//  SchnitzelKit (originally WhiskyKit)
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//
//  Modified for Schnitzel, November 2026 (GPL-3.0-or-later):
//  copied from Whisky commit fd5480a. Removed the Bottle and WhiskyWine log headers
//  (Schnitzel writes its own Pfanne header in RunLog.swift), renamed
//  `writeApplicaitonInfo` to `writeApplicationInfo` and made it print Schnitzel's
//  version, and print the environment sorted by key.
//

import Foundation
import os.log

extension FileHandle {
    /// Reads a value of type `T` at `offset`. Returns nil if the file is too short.
    func extract<T>(_ type: T.Type, offset: UInt64 = 0) -> T? {
        do {
            try self.seek(toOffset: offset)
            if let data = try self.read(upToCount: MemoryLayout<T>.size),
               data.count == MemoryLayout<T>.size {
                return data.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }

    func write(line: String) {
        do {
            guard let data = line.data(using: .utf8) else { return }
            try write(contentsOf: data)
        } catch {
            Logger.schnitzelKit.info("Failed to write line: \(error)")
        }
    }

    func writeApplicationInfo() {
        var header = String()
        let macOS = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"

        header += "\(SchnitzelInfo.appName) Version: \(version)\n"
        header += "Date: \(ISO8601DateFormatter().string(from: Date.now))\n"
        header += "macOS Version: \(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)\n\n"
        write(line: header)
    }

    func writeInfo(for process: Process) {
        var header = String()

        if let executable = process.executableURL {
            header += "Executable: \(executable.path(percentEncoded: false))\n"
        }
        if let arguments = process.arguments {
            header += "Arguments: \(arguments.joined(separator: " "))\n\n"
        }

        if let environment = process.environment, !environment.isEmpty {
            header += "Environment:\n"
            for key in environment.keys.sorted() {
                header += "  \(key)=\(environment[key] ?? "")\n"
            }
            header += "\n"
        }

        write(line: header)
    }
}
