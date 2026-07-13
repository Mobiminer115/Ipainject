import Foundation

public enum TarEntryKind: String, Equatable, Sendable {
    case file
    case directory
    case symbolicLink
}

public struct TarEntry: Equatable, Sendable {
    public let path: String
    public let kind: TarEntryKind
    public let data: Data?
    public let linkTarget: String?

    public init(path: String, kind: TarEntryKind, data: Data? = nil, linkTarget: String? = nil) {
        self.path = path
        self.kind = kind
        self.data = data
        self.linkTarget = linkTarget
    }
}

public enum TarArchive {
    private static let blockSize = 512

    public static func open(
        _ archive: Data,
        maximumEntries: Int = 50_000,
        maximumExpandedSize: Int = 2_147_483_648
    ) throws -> [TarEntry] {
        guard archive.count >= blockSize else {
            throw ForgeError.invalidArchive("TAR quá nhỏ")
        }

        var cursor = 0
        var entries: [TarEntry] = []
        var expandedSize = 0
        var pendingLongName: String?
        var pendingPAXPath: String?
        var seenPaths = Set<String>()

        while archive.count - cursor >= blockSize {
            let headerBytes = try archive.checkedBytes(at: cursor, count: blockSize)
            if headerBytes.allSatisfy({ $0 == 0 }) { break }
            try validateChecksum(headerBytes)

            let rawName = nullTerminatedString(headerBytes[0..<100])
            let prefix = nullTerminatedString(headerBytes[345..<500])
            let rawPath = prefix.isEmpty ? rawName : "\(prefix)/\(rawName)"
            let size = try parseTarNumber(Array(headerBytes[124..<136]))
            guard let payloadSize = Int(exactly: size), payloadSize >= 0 else {
                throw ForgeError.invalidArchive("kích thước TAR vượt giới hạn")
            }

            let typeFlag = headerBytes[156]
            let linkName = nullTerminatedString(headerBytes[157..<257])
            let dataStart = cursor + blockSize
            guard payloadSize <= archive.count - dataStart else {
                throw ForgeError.invalidArchive("entry TAR bị cắt ngắn")
            }
            let payload = archive.subdata(in: try archive.checkedRange(offset: dataStart, count: payloadSize))

            if typeFlag == 76 { // GNU long name
                pendingLongName = nullTerminatedString(payload[...])
            } else if typeFlag == 120 { // POSIX PAX extended header
                pendingPAXPath = parsePAX(payload)["path"]
            } else {
                let chosenPath = pendingPAXPath ?? pendingLongName ?? rawPath
                pendingPAXPath = nil
                pendingLongName = nil
                let path = try PathPolicy.sanitizedArchivePath(chosenPath)

                let kind: TarEntryKind?
                switch typeFlag {
                case 0, 48:
                    kind = .file
                case 53:
                    kind = .directory
                case 50:
                    kind = .symbolicLink
                default:
                    kind = nil
                }

                if let kind {
                    guard seenPaths.insert(path.lowercased()).inserted else {
                        throw ForgeError.invalidArchive("TAR có entry trùng đường dẫn: \(path)")
                    }
                    expandedSize = try checkedAdd(expandedSize, payloadSize)
                    guard expandedSize <= maximumExpandedSize else {
                        throw ForgeError.invalidArchive("TAR vượt giới hạn dữ liệu giải nén")
                    }
                    switch kind {
                    case .file:
                        entries.append(TarEntry(path: path, kind: kind, data: payload))
                    case .directory:
                        entries.append(TarEntry(path: path, kind: kind))
                    case .symbolicLink:
                        guard PathPolicy.safeRelativeSymlinkTarget(linkName) else {
                            throw ForgeError.unsafePath("\(path) -> \(linkName)")
                        }
                        entries.append(TarEntry(path: path, kind: kind, linkTarget: linkName))
                    }
                    guard entries.count <= maximumEntries else {
                        throw ForgeError.invalidArchive("TAR có quá nhiều entry")
                    }
                }
            }

            let paddedSize = aligned(payloadSize, to: blockSize)
            guard paddedSize <= archive.count - dataStart else {
                throw ForgeError.invalidArchive("padding TAR bị cắt ngắn")
            }
            cursor = dataStart + paddedSize
        }

        guard !entries.isEmpty else {
            throw ForgeError.invalidArchive("TAR không có entry dùng được")
        }
        return entries
    }

    private static func validateChecksum(_ header: [UInt8]) throws {
        let stored = try parseTarNumber(Array(header[148..<156]))
        var copy = header
        for index in 148..<156 { copy[index] = 0x20 }
        let calculated = copy.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard stored == 0 || stored == calculated else {
            throw ForgeError.invalidArchive("checksum TAR không đúng")
        }
    }

    private static func parseTarNumber(_ bytes: [UInt8]) throws -> UInt64 {
        guard !bytes.isEmpty else { return 0 }
        if bytes[0] & 0x80 != 0 {
            var value = UInt64(bytes[0] & 0x7F)
            for byte in bytes.dropFirst() {
                guard value <= (UInt64.max >> 8) else {
                    throw ForgeError.invalidArchive("số base-256 trong TAR bị tràn")
                }
                value = (value << 8) | UInt64(byte)
            }
            return value
        }

        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard text.isEmpty || text.allSatisfy({ $0 >= "0" && $0 <= "7" }) else {
            throw ForgeError.invalidArchive("trường số TAR không hợp lệ")
        }
        if text.isEmpty { return 0 }
        guard let value = UInt64(text, radix: 8) else {
            throw ForgeError.invalidArchive("trường số TAR bị tràn")
        }
        return value
    }

    private static func nullTerminatedString<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsePAX(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var result: [String: String] = [:]
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let body = record[record.index(after: space)...]
            guard let equals = body.firstIndex(of: "=") else { continue }
            result[String(body[..<equals])] = String(body[body.index(after: equals)...])
        }
        return result
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ForgeError.invalidArchive("kích thước giải nén bị tràn")
        }
        return value
    }
}
