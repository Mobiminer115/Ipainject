import Foundation
import XCTest
@testable import ForgeCore

final class MachOTests: XCTestCase {
    func testAddsAndVerifiesCommands() throws {
        let original = makeThinMachO(firstSectionOffset: 0x400)
        let (patched, report) = try MachOFile.patch(
            original,
            request: MachOPatchRequest(
                loadPaths: ["@rpath/Test.dylib"],
                rpaths: ["@executable_path/Frameworks"]
            )
        )

        XCTAssertEqual(report.slices.count, 1)
        XCTAssertEqual(report.totalCommandsAdded, 2)
        let inspection = try MachOFile.inspect(patched)
        XCTAssertEqual(inspection.slices[0].loadPaths, ["@rpath/Test.dylib"])
        XCTAssertEqual(inspection.slices[0].rpaths, ["@executable_path/Frameworks"])
        XCTAssertLessThan(inspection.slices[0].headerSlack, try MachOFile.inspect(original).slices[0].headerSlack)
    }

    func testPatchIsIdempotent() throws {
        let request = MachOPatchRequest(
            loadPaths: ["@rpath/Test.dylib"],
            rpaths: ["@executable_path/Frameworks"]
        )
        let (once, _) = try MachOFile.patch(makeThinMachO(firstSectionOffset: 0x400), request: request)
        let (twice, report) = try MachOFile.patch(once, request: request)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(report.totalCommandsAdded, 0)
    }

    func testRejectsInsufficientHeaderSpaceWithoutMutation() throws {
        let original = makeThinMachO(firstSectionOffset: 184)
        XCTAssertThrowsError(
            try MachOFile.patch(
                original,
                request: MachOPatchRequest(loadPaths: ["@rpath/Test.dylib"])
            )
        ) { error in
            guard case ForgeError.insufficientHeaderSpace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try MachOFile.inspect(original).slices[0].loadPaths, [])
    }

    func testPatchesEveryFatSlice() throws {
        let fat = makeFatMachO()
        let (patched, report) = try MachOFile.patch(
            fat,
            request: MachOPatchRequest(loadPaths: ["@executable_path/Test.dylib"])
        )
        XCTAssertEqual(report.slices.count, 2)
        XCTAssertEqual(report.totalCommandsAdded, 2)
        XCTAssertTrue(try MachOFile.inspect(patched).slices.allSatisfy {
            $0.loadPaths.contains("@executable_path/Test.dylib")
        })
    }
}

private func makeThinMachO(firstSectionOffset: UInt32) -> Data {
    var data = Data(repeating: 0, count: 0x1000)
    data.putLE32(0xFEEDFACF, at: 0)
    data.putLE32(0x0100000C, at: 4) // arm64
    data.putLE32(0, at: 8)
    data.putLE32(2, at: 12) // MH_EXECUTE
    data.putLE32(1, at: 16)
    data.putLE32(152, at: 20)
    data.putLE32(0, at: 24)
    data.putLE32(0, at: 28)

    let command = 32
    data.putLE32(0x19, at: command)
    data.putLE32(152, at: command + 4)
    data.putASCII("__TEXT", at: command + 8, width: 16)
    data.putLE64(0x100000000, at: command + 24)
    data.putLE64(0x1000, at: command + 32)
    data.putLE64(0, at: command + 40)
    data.putLE64(0x1000, at: command + 48)
    data.putLE32(7, at: command + 56)
    data.putLE32(5, at: command + 60)
    data.putLE32(1, at: command + 64)

    let section = command + 72
    data.putASCII("__text", at: section, width: 16)
    data.putASCII("__TEXT", at: section + 16, width: 16)
    data.putLE64(0x100000000 + UInt64(firstSectionOffset), at: section + 32)
    data.putLE64(16, at: section + 40)
    data.putLE32(firstSectionOffset, at: section + 48)
    return data
}

private func makeFatMachO() -> Data {
    let first = makeThinMachO(firstSectionOffset: 0x400)
    var second = makeThinMachO(firstSectionOffset: 0x400)
    second.putLE32(0x01000007, at: 4) // x86_64
    var fat = Data(repeating: 0, count: 0x3000)
    fat.putBE32(0xCAFEBABE, at: 0)
    fat.putBE32(2, at: 4)
    fat.putBE32(0x0100000C, at: 8)
    fat.putBE32(0, at: 12)
    fat.putBE32(0x1000, at: 16)
    fat.putBE32(UInt32(first.count), at: 20)
    fat.putBE32(12, at: 24)
    fat.putBE32(0x01000007, at: 28)
    fat.putBE32(0, at: 32)
    fat.putBE32(0x2000, at: 36)
    fat.putBE32(UInt32(second.count), at: 40)
    fat.putBE32(12, at: 44)
    fat.replaceSubrange(0x1000..<0x2000, with: first)
    fat.replaceSubrange(0x2000..<0x3000, with: second)
    return fat
}

private extension Data {
    mutating func putLE32(_ value: UInt32, at offset: Int) {
        put([
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)
        ], at: offset)
    }

    mutating func putBE32(_ value: UInt32, at offset: Int) {
        put([
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)
        ], at: offset)
    }

    mutating func putLE64(_ value: UInt64, at offset: Int) {
        put((0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }, at: offset)
    }

    mutating func putASCII(_ value: String, at offset: Int, width: Int) {
        let bytes = Array(value.utf8).prefix(width)
        put(Array(bytes) + Array(repeating: 0, count: width - bytes.count), at: offset)
    }

    mutating func put(_ bytes: [UInt8], at offset: Int) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
