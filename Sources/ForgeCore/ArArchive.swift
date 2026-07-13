import Foundation

public struct ArMember: Equatable, Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ArArchive {
    private static let signature = Data("!<arch>\n".utf8)
    private static let headerSize = 60

    public static func open(_ archive: Data, maximumMemberSize: Int = 1_073_741_824) throws -> [ArMember] {
        guard archive.count >= signature.count,
              archive.starts(with: signature) else {
            throw ForgeError.invalidArchive("thiếu chữ ký ar của DEB")
        }

        var cursor = signature.count
        var members: [ArMember] = []
        var gnuStringTable: Data?

        while cursor < archive.count {
            guard archive.count - cursor >= headerSize else {
                throw ForgeError.invalidArchive("header ar bị cắt ngắn")
            }
            let headerStart = cursor
            let rawName = try archive.asciiString(at: headerStart, count: 16)
                .trimmingCharacters(in: .whitespaces)
            let rawSize = try archive.asciiString(at: headerStart + 48, count: 10)
                .trimmingCharacters(in: .whitespaces)
            let trailer = try archive.asciiString(at: headerStart + 58, count: 2)
            guard trailer == "`\n", let storedSize = Int(rawSize), storedSize >= 0 else {
                throw ForgeError.invalidArchive("header ar không hợp lệ")
            }
            guard storedSize <= maximumMemberSize else {
                throw ForgeError.invalidArchive("một member DEB vượt giới hạn kích thước")
            }

            cursor += headerSize
            guard storedSize <= archive.count - cursor else {
                throw ForgeError.invalidArchive("member ar bị cắt ngắn")
            }

            var memberName = rawName
            var contentOffset = cursor
            var contentSize = storedSize

            if rawName.hasPrefix("#1/") {
                guard let nameLength = Int(rawName.dropFirst(3)),
                      nameLength >= 0,
                      nameLength <= contentSize else {
                    throw ForgeError.invalidArchive("tên BSD ar không hợp lệ")
                }
                memberName = try archive.asciiString(at: contentOffset, count: nameLength)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                contentOffset += nameLength
                contentSize -= nameLength
            } else if rawName == "//" {
                gnuStringTable = archive.subdata(in: try archive.checkedRange(offset: cursor, count: storedSize))
            } else if rawName.hasPrefix("/"), rawName != "/", let tableOffset = Int(rawName.dropFirst()) {
                guard let table = gnuStringTable,
                      tableOffset >= 0,
                      tableOffset < table.count else {
                    throw ForgeError.invalidArchive("tham chiếu bảng tên GNU ar không hợp lệ")
                }
                let tail = table.suffix(from: table.index(table.startIndex, offsetBy: tableOffset))
                let bytes = tail.prefix { $0 != 0x0A && $0 != 0 }
                memberName = String(decoding: bytes, as: UTF8.self)
            }

            memberName = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
            while memberName.hasSuffix("/") { memberName.removeLast() }

            if rawName != "//", rawName != "/", !memberName.isEmpty {
                let payload = archive.subdata(in: try archive.checkedRange(offset: contentOffset, count: contentSize))
                members.append(ArMember(name: memberName, data: payload))
            }

            cursor += storedSize
            if !cursor.isMultiple(of: 2) {
                guard cursor < archive.count else { break }
                cursor += 1
            }
        }

        guard !members.isEmpty else {
            throw ForgeError.invalidArchive("DEB không có member nào")
        }
        return members
    }
}
