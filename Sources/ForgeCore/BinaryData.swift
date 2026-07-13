import Foundation

extension Data {
    func checkedRange(offset: Int, count: Int) throws -> Range<Data.Index> {
        guard offset >= 0, count >= 0, offset <= self.count, count <= self.count - offset else {
            throw ForgeError.invalidArchive("vùng dữ liệu vượt giới hạn")
        }
        let lower = index(startIndex, offsetBy: offset)
        let upper = index(lower, offsetBy: count)
        return lower..<upper
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        let bytes = try checkedBytes(at: offset, count: 4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    func readUInt32BE(at offset: Int) throws -> UInt32 {
        let bytes = try checkedBytes(at: offset, count: 4)
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | (UInt32(bytes[3]))
    }

    func readUInt64LE(at offset: Int) throws -> UInt64 {
        let bytes = try checkedBytes(at: offset, count: 8)
        return bytes.enumerated().reduce(UInt64(0)) { result, pair in
            result | (UInt64(pair.element) << UInt64(pair.offset * 8))
        }
    }

    func readUInt64BE(at offset: Int) throws -> UInt64 {
        let bytes = try checkedBytes(at: offset, count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    func checkedBytes(at offset: Int, count: Int) throws -> [UInt8] {
        Array(self[try checkedRange(offset: offset, count: count)])
    }

    func asciiString(at offset: Int, count: Int) throws -> String {
        let bytes = try checkedBytes(at: offset, count: count)
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    func cString(at offset: Int, limit: Int) throws -> String {
        guard limit >= 0 else {
            throw ForgeError.invalidArchive("giới hạn chuỗi âm")
        }
        let bytes = try checkedBytes(at: offset, count: limit)
        guard let end = bytes.firstIndex(of: 0) else {
            throw ForgeError.invalidMachO("chuỗi load command không kết thúc")
        }
        guard let result = String(bytes: bytes[..<end], encoding: .utf8) else {
            throw ForgeError.invalidMachO("chuỗi load command không phải UTF-8")
        }
        return result
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) throws {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ]
        try replaceChecked(offset: offset, bytes: bytes)
    }

    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) throws {
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
        try replaceChecked(offset: offset, bytes: bytes)
    }

    mutating func replaceChecked(offset: Int, bytes: [UInt8]) throws {
        let range = try checkedRange(offset: offset, count: bytes.count)
        replaceSubrange(range, with: bytes)
    }
}

extension FixedWidthInteger {
    var decimalInt: Int? { Int(exactly: self) }
}

func aligned(_ value: Int, to alignment: Int) -> Int {
    precondition(alignment > 0 && alignment.nonzeroBitCount == 1)
    return (value + alignment - 1) & ~(alignment - 1)
}
