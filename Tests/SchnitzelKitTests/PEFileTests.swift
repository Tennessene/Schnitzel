//
//  PEFileTests.swift
//  SchnitzelKitTests
//
//  This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
//  See the LICENSE file in the repository root.
//

import Foundation
import Testing
@testable import SchnitzelKit

/// Builds minimal PE headers in memory, with no sections.
struct PEBuilder {
    var bytes = Data()

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }

    static func make(pe32Plus: Bool, importTable: (UInt32, UInt32)) -> Data {
        var builder = PEBuilder()
        // DOS header: "MZ", padding, e_lfanew at 0x3C pointing to 0x40.
        builder.bytes.append(contentsOf: [0x4D, 0x5A])
        builder.bytes.append(Data(count: 0x3C - 2))
        builder.u32(0x40)
        // PE signature.
        builder.bytes.append(contentsOf: Array("PE\0\0".utf8))
        // COFF header.
        let optionalHeaderSize: UInt16 = pe32Plus ? 240 : 224
        builder.u16(pe32Plus ? 0x8664 : 0x14C) // machine
        builder.u16(0)                          // number of sections
        builder.u32(0)                          // time stamp
        builder.u32(0)                          // symbol table
        builder.u32(0)                          // number of symbols
        builder.u16(optionalHeaderSize)
        builder.u16(0x22)                       // characteristics
        // Optional header, standard fields.
        builder.u16(pe32Plus ? 0x20B : 0x10B)
        builder.u8(14); builder.u8(0)           // linker version
        builder.u32(0x1000); builder.u32(0x2000); builder.u32(0) // code, initialized, uninitialized
        builder.u32(0x1100)                     // entry point
        builder.u32(0x1000)                     // base of code
        if pe32Plus {
            builder.u64(0x1_4000_0000)          // image base
        } else {
            builder.u32(0x2000)                 // base of data
            builder.u32(0x40_0000)              // image base
        }
        // Windows-specific fields.
        builder.u32(0x1000); builder.u32(0x200) // section and file alignment
        builder.u16(6); builder.u16(0); builder.u16(0); builder.u16(0); builder.u16(6); builder.u16(0)
        builder.u32(0)                          // win32 version
        builder.u32(0x5000); builder.u32(0x400) // size of image, headers
        builder.u32(0)                          // checksum
        builder.u16(2); builder.u16(0x8160)     // subsystem (GUI), dll characteristics
        let sizes: [UInt64] = [0x10_0000, 0x1000, 0x20_0000, 0x2000]
        for size in sizes {
            if pe32Plus { builder.u64(size) } else { builder.u32(UInt32(size)) }
        }
        builder.u32(0)                          // loader flags
        builder.u32(16)                         // number of data directories
        for index in 0..<16 {
            if index == 1 {
                builder.u32(importTable.0); builder.u32(importTable.1)
            } else {
                builder.u32(0); builder.u32(0)
            }
        }
        return builder.bytes
    }
}

@Suite struct PEFileTests {
    func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "schnitzel-test-\(UUID().uuidString).exe")
        try data.write(to: url)
        return url
    }

    @Test func readsPE32PlusHeadersAndImportDirectory() throws {
        let url = try write(PEBuilder.make(pe32Plus: true, importTable: (0x3000, 0x64)))
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try PEFile(url: url)
        let header = try #require(file.optionalHeader)
        #expect(file.architecture == .x64)
        #expect(header.imageBase == 0x1_4000_0000)
        #expect(header.sizeOfStackReserve == 0x10_0000)
        #expect(header.sizeOfHeapCommit == 0x2000)
        #expect(header.numberOfRvaAndSizes == 16)
        #expect(header.dataDirectories.count == 16)
        #expect(header.dataDirectories[1] == PEFile.DataDirectory(virtualAddress: 0x3000, size: 0x64))
    }

    @Test func readsPE32HeadersAndImportDirectory() throws {
        let url = try write(PEBuilder.make(pe32Plus: false, importTable: (0x2400, 0x28)))
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try PEFile(url: url)
        let header = try #require(file.optionalHeader)
        #expect(file.architecture == .x32)
        #expect(header.sizeOfStackReserve == 0x10_0000)
        #expect(header.dataDirectories[1] == PEFile.DataDirectory(virtualAddress: 0x2400, size: 0x28))
    }

    @Test func rejectsFilesThatAreNotPE() throws {
        let url = try write(Data("not an exe".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PEError.self) { try PEFile(url: url) }
    }
}
