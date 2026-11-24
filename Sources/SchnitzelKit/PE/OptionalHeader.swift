//
//  PortableExecutable+OptionalHeader.swift
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
//  copied from Whisky commit fd5480a. Fixed the stack and heap size fields,
//  which are 8 bytes in PE32+ (64-bit) files; Whisky read them as 4 bytes, so every
//  later field was misread for 64-bit executables. Added the data directories
//  (needed to find the import table).
//

import Foundation

extension PEFile {
    /// Optional Header
    /// 
    /// https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#optional-header-image-only
    /// One entry of the optional header's data directory table.
    public struct DataDirectory: Hashable, Equatable, Sendable {
        public let virtualAddress: UInt32
        public let size: UInt32
    }

    public struct OptionalHeader: Hashable, Equatable, Sendable {
        // Standard Fields

        public let magic: Magic
        public let majorLinkerVersion: UInt8
        public let minorLinkerVersion: UInt8
        public let sizeOfCode: UInt32
        public let sizeOfInitializedData: UInt32
        public let sizeOfUninitializedData: UInt32
        public let addressOfEntryPoint: UInt32
        public let baseOfCode: UInt32
        public let baseOfData: UInt32?

        // Windows-Specific Fields

        public let imageBase: UInt64
        public let sectionAlignment: UInt32
        public let fileAlignment: UInt32
        public let majorOperatingSystemVersion: UInt16
        public let minorOperatingSystemVersion: UInt16
        public let majorImageVersion: UInt16
        public let minorImageVersion: UInt16
        public let majorSubsystemVersion: UInt16
        public let minorSubsystemVersion: UInt16
        public let win32VersionValue: UInt32
        public let sizeOfImage: UInt32
        public let sizeOfHeaders: UInt32
        public let checkSum: UInt32
        public let subsystem: UInt16
        public let dllCharacteristics: UInt16
        public let sizeOfStackReserve: UInt64
        public let sizeOfStackCommit: UInt64
        public let sizeOfHeapReserve: UInt64
        public let sizeOfHeapCommit: UInt64
        public let loaderFlags: UInt32
        public let numberOfRvaAndSizes: UInt32

        // Data Directories

        /// Data directories in file order. Index 1 is the import table.
        /// https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#optional-header-data-directories-image-only
        public let dataDirectories: [DataDirectory]

        // swiftlint:disable:next function_body_length
        init?(handle: FileHandle, offset: UInt64) {
            var offset = offset
            let rawMagic = handle.extract(UInt16.self, offset: offset) ?? 0
            let magic = Magic(rawValue: rawMagic) ?? .unknown
            self.magic = magic
            offset += 2
            self.majorLinkerVersion = handle.extract(UInt8.self, offset: offset) ?? 0
            offset += 1
            self.minorLinkerVersion = handle.extract(UInt8.self, offset: offset) ?? 0
            offset += 1
            self.sizeOfCode = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.sizeOfInitializedData = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.sizeOfUninitializedData = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.addressOfEntryPoint = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.baseOfCode = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4

            switch magic {
            case .pe32Plus:
                // PE32+ does not contain this field, following BaseOfCode is a larger ImageBase instead.
                self.baseOfData = nil

                // PE32+ images have a 8 byte ImageBase field
                self.imageBase = handle.extract(UInt64.self, offset: offset) ?? 0
                offset += 8
            default:
                // PE32 contains this additional field, following BaseOfCode.
                self.baseOfData = handle.extract(UInt32.self, offset: offset) ?? 0
                offset += 4

                // PE32 images have a 4 byte ImageBase field
                let imageBase = handle.extract(UInt32.self, offset: offset) ?? 0
                self.imageBase = UInt64(imageBase)
                offset += 4
            }

            self.sectionAlignment = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.fileAlignment = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.majorOperatingSystemVersion = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.minorOperatingSystemVersion = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.majorImageVersion = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.minorImageVersion = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.majorSubsystemVersion = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.minorSubsystemVersion = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.win32VersionValue = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.sizeOfImage = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.sizeOfHeaders = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.checkSum = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.subsystem = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            self.dllCharacteristics = handle.extract(UInt16.self, offset: offset) ?? 0
            offset += 2
            if magic == .pe32Plus {
                self.sizeOfStackReserve = handle.extract(UInt64.self, offset: offset) ?? 0
                offset += 8
            } else {
                self.sizeOfStackReserve = UInt64(handle.extract(UInt32.self, offset: offset) ?? 0)
                offset += 4
            }
            if magic == .pe32Plus {
                self.sizeOfStackCommit = handle.extract(UInt64.self, offset: offset) ?? 0
                offset += 8
            } else {
                self.sizeOfStackCommit = UInt64(handle.extract(UInt32.self, offset: offset) ?? 0)
                offset += 4
            }
            if magic == .pe32Plus {
                self.sizeOfHeapReserve = handle.extract(UInt64.self, offset: offset) ?? 0
                offset += 8
            } else {
                self.sizeOfHeapReserve = UInt64(handle.extract(UInt32.self, offset: offset) ?? 0)
                offset += 4
            }
            if magic == .pe32Plus {
                self.sizeOfHeapCommit = handle.extract(UInt64.self, offset: offset) ?? 0
                offset += 8
            } else {
                self.sizeOfHeapCommit = UInt64(handle.extract(UInt32.self, offset: offset) ?? 0)
                offset += 4
            }
            self.loaderFlags = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4
            self.numberOfRvaAndSizes = handle.extract(UInt32.self, offset: offset) ?? 0
            offset += 4

            // At most 16 directories are defined; ignore larger (corrupt) counts.
            var directories: [DataDirectory] = []
            for _ in 0..<min(numberOfRvaAndSizes, 16) {
                let virtualAddress = handle.extract(UInt32.self, offset: offset) ?? 0
                let size = handle.extract(UInt32.self, offset: offset + 4) ?? 0
                directories.append(DataDirectory(virtualAddress: virtualAddress, size: size))
                offset += 8
            }
            self.dataDirectories = directories
        }
    }
}
