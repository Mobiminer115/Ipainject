import Foundation
import XCTest
@testable import ForgeCore

final class ArchiveTests: XCTestCase {
    func testReadsDebianArMembers() throws {
        var archive = Data("!<arch>\n".utf8)
        archive.append(arMember(name: "debian-binary", payload: Data("2.0\n".utf8)))
        archive.append(arMember(name: "data.tar", payload: Data([1, 2, 3, 4])))
        let members = try ArArchive.open(archive)
        XCTAssertEqual(members.map(\.name), ["debian-binary", "data.tar"])
        XCTAssertEqual(members[1].data, Data([1, 2, 3, 4]))
    }

    func testReadsSafeTarEntry() throws {
        let tar = makeTar(path: "./usr/lib/Test.dylib", payload: Data([0xCF, 0xFA, 0xED, 0xFE]))
        let entries = try TarArchive.open(tar)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "usr/lib/Test.dylib")
        XCTAssertEqual(entries[0].data, Data([0xCF, 0xFA, 0xED, 0xFE]))
    }

    func testRejectsTraversalInTar() {
        let tar = makeTar(path: "../../escape", payload: Data([1]))
        XCTAssertThrowsError(try TarArchive.open(tar)) { error in
            guard case ForgeError.unsafePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private func arMember(name: String, payload: Data) -> Data {
    func field(_ value: String, width: Int) -> String {
        String(value.prefix(width)).padding(toLength: width, withPad: " ", startingAt: 0)
    }
    let header = field(name + "/", width: 16)
        + field("0", width: 12)
        + field("0", width: 6)
        + field("0", width: 6)
        + field("100644", width: 8)
        + field(String(payload.count), width: 10)
        + "`\n"
    var result = Data(header.utf8)
    result.append(payload)
    if !payload.count.isMultiple(of: 2) { result.append(0x0A) }
    return result
}

private func makeTar(path: String, payload: Data) -> Data {
    var header = Data(repeating: 0, count: 512)
    header.putTarString(path, at: 0, width: 100)
    header.putTarOctal(0o644, at: 100, width: 8)
    header.putTarOctal(0, at: 108, width: 8)
    header.putTarOctal(0, at: 116, width: 8)
    header.putTarOctal(UInt64(payload.count), at: 124, width: 12)
    header.putTarOctal(0, at: 136, width: 12)
    header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
    header[156] = 48
    header.putTarString("ustar", at: 257, width: 6)
    header.putTarString("00", at: 263, width: 2)
    let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
    let checksumText = String(format: "%06llo", checksum)
    header.replaceSubrange(148..<156, with: Array(checksumText.utf8) + [0, 0x20])

    var archive = header
    archive.append(payload)
    archive.append(Data(repeating: 0, count: (512 - payload.count % 512) % 512))
    archive.append(Data(repeating: 0, count: 1024))
    return archive
}

private extension Data {
    mutating func putTarString(_ string: String, at offset: Int, width: Int) {
        let bytes = Array(string.utf8.prefix(width))
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    mutating func putTarOctal(_ value: UInt64, at offset: Int, width: Int) {
        let text = String(value, radix: 8).paddingLeft(to: width - 1, with: "0") + "\0"
        replaceSubrange(offset..<(offset + width), with: text.utf8)
    }
}

private extension String {
    func paddingLeft(to length: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
