import Foundation

public struct MachOPatchRequest: Equatable, Sendable {
    public let loadPaths: [String]
    public let rpaths: [String]
    public let weakLoad: Bool

    public init(loadPaths: [String], rpaths: [String] = [], weakLoad: Bool = false) {
        self.loadPaths = loadPaths
        self.rpaths = rpaths
        self.weakLoad = weakLoad
    }
}

public struct MachOSliceInspection: Equatable, Sendable {
    public let architecture: String
    public let fileOffset: Int
    public let fileSize: Int
    public let headerSlack: Int
    public let loadPaths: [String]
    public let rpaths: [String]
}

public struct MachOInspection: Equatable, Sendable {
    public let slices: [MachOSliceInspection]

    public var architectures: [String] { slices.map(\.architecture) }
}

public struct MachOSlicePatchReport: Equatable, Sendable {
    public let architecture: String
    public let commandsAdded: Int
    public let bytesUsed: Int
    public let headerSlackRemaining: Int
}

public struct MachOPatchReport: Equatable, Sendable {
    public let slices: [MachOSlicePatchReport]

    public var totalCommandsAdded: Int { slices.reduce(0) { $0 + $1.commandsAdded } }
}

public enum MachOFile {
    private static let mhMagic64: UInt32 = 0xFEEDFACF
    private static let fatMagic: UInt32 = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let fatCigam: UInt32 = 0xBEBAFECA
    private static let fatCigam64: UInt32 = 0xBFBAFECA

    private static let lcSegment64: UInt32 = 0x19
    private static let lcLoadDylib: UInt32 = 0x0C
    private static let lcLoadWeakDylib: UInt32 = 0x80000018
    private static let lcLazyLoadDylib: UInt32 = 0x20
    private static let lcReexportDylib: UInt32 = 0x8000001F
    private static let lcLoadUpwardDylib: UInt32 = 0x80000023
    private static let lcRpath: UInt32 = 0x8000001C

    private struct SliceLocation {
        let offset: Int
        let size: Int
    }

    private struct ParsedSlice {
        let location: SliceLocation
        let architecture: String
        let ncmds: UInt32
        let sizeofcmds: UInt32
        let commandEnd: Int
        let firstDataOffset: Int
        let loadPaths: [String]
        let rpaths: [String]

        var slack: Int { max(0, firstDataOffset - commandEnd) }
    }

    private struct PatchPlan {
        let slice: ParsedSlice
        let commandData: Data
        let commandCount: Int
    }

    public static func looksLikeMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        guard let little = try? data.readUInt32LE(at: 0),
              let big = try? data.readUInt32BE(at: 0) else { return false }
        return little == mhMagic64 || [fatMagic, fatMagic64, fatCigam, fatCigam64].contains(big)
    }

    public static func inspect(_ data: Data) throws -> MachOInspection {
        let parsed = try parse(data)
        return MachOInspection(slices: parsed.map {
            MachOSliceInspection(
                architecture: $0.architecture,
                fileOffset: $0.location.offset,
                fileSize: $0.location.size,
                headerSlack: $0.slack,
                loadPaths: $0.loadPaths,
                rpaths: $0.rpaths
            )
        })
    }

    public static func patch(_ original: Data, request: MachOPatchRequest) throws -> (Data, MachOPatchReport) {
        let loadPaths = unique(try request.loadPaths.map { try PathPolicy.validateLoadPath($0) })
        let rpaths = unique(try request.rpaths.map { try PathPolicy.validateRPath($0) })
        guard !loadPaths.isEmpty || !rpaths.isEmpty else {
            throw ForgeError.invalidOption("không có load path hoặc rpath để thêm")
        }

        let parsed = try parse(original)
        var plans: [PatchPlan] = []
        plans.reserveCapacity(parsed.count)

        for slice in parsed {
            var additions = Data()
            var commandCount = 0

            for path in rpaths where !slice.rpaths.contains(path) {
                additions.append(try makeRPathCommand(path))
                commandCount += 1
            }
            for path in loadPaths where !slice.loadPaths.contains(path) {
                additions.append(try makeDylibCommand(path, weak: request.weakLoad))
                commandCount += 1
            }

            guard additions.count <= slice.slack else {
                throw ForgeError.insufficientHeaderSpace(
                    required: additions.count,
                    available: slice.slack,
                    architecture: slice.architecture
                )
            }
            guard UInt64(slice.ncmds) + UInt64(commandCount) <= UInt64(UInt32.max),
                  UInt64(slice.sizeofcmds) + UInt64(additions.count) <= UInt64(UInt32.max) else {
                throw ForgeError.invalidMachO("số lượng load command bị tràn")
            }
            plans.append(PatchPlan(slice: slice, commandData: additions, commandCount: commandCount))
        }

        var output = original
        var reports: [MachOSlicePatchReport] = []
        for plan in plans {
            if !plan.commandData.isEmpty {
                let range = try output.checkedRange(offset: plan.slice.commandEnd, count: plan.commandData.count)
                output.replaceSubrange(range, with: plan.commandData)
                try output.writeUInt32LE(
                    plan.slice.ncmds + UInt32(plan.commandCount),
                    at: plan.slice.location.offset + 16
                )
                try output.writeUInt32LE(
                    plan.slice.sizeofcmds + UInt32(plan.commandData.count),
                    at: plan.slice.location.offset + 20
                )
            }
            reports.append(MachOSlicePatchReport(
                architecture: plan.slice.architecture,
                commandsAdded: plan.commandCount,
                bytesUsed: plan.commandData.count,
                headerSlackRemaining: plan.slice.slack - plan.commandData.count
            ))
        }

        let verified = try inspect(output)
        for slice in verified.slices {
            guard loadPaths.allSatisfy({ slice.loadPaths.contains($0) }),
                  rpaths.allSatisfy({ slice.rpaths.contains($0) }) else {
                throw ForgeError.invalidMachO("xác minh sau patch thất bại ở \(slice.architecture)")
            }
        }
        return (output, MachOPatchReport(slices: reports))
    }

    private static func parse(_ data: Data) throws -> [ParsedSlice] {
        let locations = try sliceLocations(in: data)
        let result = try locations.map { try parseSlice(data, location: $0) }
        guard !result.isEmpty else {
            throw ForgeError.invalidMachO("không tìm thấy slice 64-bit")
        }
        return result
    }

    private static func sliceLocations(in data: Data) throws -> [SliceLocation] {
        guard data.count >= 4 else {
            throw ForgeError.invalidMachO("tệp quá nhỏ")
        }
        let magicBE = try data.readUInt32BE(at: 0)
        if ![fatMagic, fatMagic64, fatCigam, fatCigam64].contains(magicBE) {
            return [SliceLocation(offset: 0, size: data.count)]
        }

        let is64 = magicBE == fatMagic64 || magicBE == fatCigam64
        let littleEndian = magicBE == fatCigam || magicBE == fatCigam64
        let read32: (Int) throws -> UInt32 = { offset in
            if littleEndian { return try data.readUInt32LE(at: offset) }
            return try data.readUInt32BE(at: offset)
        }
        let read64: (Int) throws -> UInt64 = { offset in
            if littleEndian { return try data.readUInt64LE(at: offset) }
            return try data.readUInt64BE(at: offset)
        }
        let count = try read32(4)
        guard let sliceCount = count.decimalInt, sliceCount > 0, sliceCount <= 64 else {
            throw ForgeError.invalidMachO("số slice fat không hợp lệ")
        }

        let archSize = is64 ? 32 : 20
        guard 8 + sliceCount * archSize <= data.count else {
            throw ForgeError.invalidMachO("bảng fat arch bị cắt ngắn")
        }
        var locations: [SliceLocation] = []
        for index in 0..<sliceCount {
            let base = 8 + index * archSize
            let offsetValue: UInt64
            let sizeValue: UInt64
            if is64 {
                offsetValue = try read64(base + 8)
                sizeValue = try read64(base + 16)
            } else {
                offsetValue = UInt64(try read32(base + 8))
                sizeValue = UInt64(try read32(base + 12))
            }
            guard let offset = offsetValue.decimalInt,
                  let size = sizeValue.decimalInt,
                  offset >= 0,
                  size >= 32,
                  offset <= data.count,
                  size <= data.count - offset else {
                throw ForgeError.invalidMachO("slice fat vượt giới hạn tệp")
            }
            let candidate = SliceLocation(offset: offset, size: size)
            guard locations.allSatisfy({ !rangesOverlap($0, candidate) }) else {
                throw ForgeError.invalidMachO("các slice fat chồng lấn")
            }
            locations.append(candidate)
        }
        return locations
    }

    private static func parseSlice(_ data: Data, location: SliceLocation) throws -> ParsedSlice {
        let base = location.offset
        guard try data.readUInt32LE(at: base) == mhMagic64 else {
            throw ForgeError.unsupportedFormat("chỉ hỗ trợ Mach-O 64-bit little-endian")
        }
        let cpuType = try data.readUInt32LE(at: base + 4)
        let ncmds = try data.readUInt32LE(at: base + 16)
        let sizeofcmds = try data.readUInt32LE(at: base + 20)
        guard let commandCount = ncmds.decimalInt,
              let commandBytes = sizeofcmds.decimalInt,
              commandCount <= 100_000,
              commandBytes >= 0,
              commandBytes <= location.size - 32 else {
            throw ForgeError.invalidMachO("header load command không hợp lệ")
        }

        let commandStart = base + 32
        let commandEnd = commandStart + commandBytes
        var cursor = commandStart
        var loadPaths: [String] = []
        var rpaths: [String] = []
        var firstDataOffset: Int?

        for _ in 0..<commandCount {
            guard cursor <= commandEnd - 8 else {
                throw ForgeError.invalidMachO("load command bị cắt ngắn")
            }
            let command = try data.readUInt32LE(at: cursor)
            let rawSize = try data.readUInt32LE(at: cursor + 4)
            guard let commandSize = rawSize.decimalInt,
                  commandSize >= 8,
                  commandSize.isMultiple(of: 4),
                  commandSize <= commandEnd - cursor else {
                throw ForgeError.invalidMachO("cmdsize không hợp lệ")
            }

            if command == lcSegment64 {
                guard commandSize >= 72 else {
                    throw ForgeError.invalidMachO("LC_SEGMENT_64 quá ngắn")
                }
                let fileOffset = try data.readUInt64LE(at: cursor + 40)
                let fileSize = try data.readUInt64LE(at: cursor + 48)
                if fileSize > 0 {
                    guard let relative = fileOffset.decimalInt,
                          let length = fileSize.decimalInt,
                          relative >= 0,
                          relative <= location.size,
                          length <= location.size - relative else {
                        throw ForgeError.invalidMachO("LC_SEGMENT_64 vượt giới hạn slice")
                    }
                    if relative > 0 {
                        firstDataOffset = minimum(firstDataOffset, base + relative)
                    }
                }

                let sectionCountRaw = try data.readUInt32LE(at: cursor + 64)
                guard let sectionCount = sectionCountRaw.decimalInt,
                      sectionCount <= 100_000,
                      sectionCount <= (commandSize - 72) / 80 else {
                    throw ForgeError.invalidMachO("bảng section_64 không hợp lệ")
                }
                for section in 0..<sectionCount {
                    let sectionBase = cursor + 72 + section * 80
                    let size = try data.readUInt64LE(at: sectionBase + 40)
                    let relative = try data.readUInt32LE(at: sectionBase + 48)
                    if relative > 0 {
                        guard let offset = relative.decimalInt,
                              let length = size.decimalInt,
                              offset <= location.size,
                              length <= location.size - offset else {
                            throw ForgeError.invalidMachO("section_64 vượt giới hạn slice")
                        }
                        firstDataOffset = minimum(firstDataOffset, base + offset)
                    }
                }
            } else if dylibCommands.contains(command) {
                guard commandSize >= 24 else {
                    throw ForgeError.invalidMachO("dylib_command quá ngắn")
                }
                loadPaths.append(try commandString(
                    data,
                    commandOffset: cursor,
                    commandSize: commandSize,
                    fieldOffset: 8,
                    minimumStringOffset: 24
                ))
            } else if command == lcRpath {
                rpaths.append(try commandString(
                    data,
                    commandOffset: cursor,
                    commandSize: commandSize,
                    fieldOffset: 8,
                    minimumStringOffset: 12
                ))
            }

            cursor += commandSize
        }
        guard cursor == commandEnd else {
            throw ForgeError.invalidMachO("sizeofcmds không khớp load command")
        }
        guard let firstDataOffset,
              firstDataOffset >= commandEnd,
              firstDataOffset <= base + location.size else {
            throw ForgeError.invalidMachO("không xác định được khoảng trống header")
        }

        return ParsedSlice(
            location: location,
            architecture: architectureName(cpuType),
            ncmds: ncmds,
            sizeofcmds: sizeofcmds,
            commandEnd: commandEnd,
            firstDataOffset: firstDataOffset,
            loadPaths: loadPaths,
            rpaths: rpaths
        )
    }

    private static var dylibCommands: Set<UInt32> {
        [lcLoadDylib, lcLoadWeakDylib, lcLazyLoadDylib, lcReexportDylib, lcLoadUpwardDylib]
    }

    private static func commandString(
        _ data: Data,
        commandOffset: Int,
        commandSize: Int,
        fieldOffset: Int,
        minimumStringOffset: Int
    ) throws -> String {
        guard commandSize >= fieldOffset + 4 else {
            throw ForgeError.invalidMachO("load command thiếu trường chuỗi")
        }
        let rawOffset = try data.readUInt32LE(at: commandOffset + fieldOffset)
        guard let stringOffset = rawOffset.decimalInt,
              stringOffset >= minimumStringOffset,
              stringOffset < commandSize else {
            throw ForgeError.invalidMachO("offset chuỗi trong load command không hợp lệ")
        }
        return try data.cString(
            at: commandOffset + stringOffset,
            limit: commandSize - stringOffset
        )
    }

    private static func makeDylibCommand(_ path: String, weak: Bool) throws -> Data {
        let stringBytes = Array(path.utf8) + [0]
        let commandSize = aligned(24 + stringBytes.count, to: 8)
        guard commandSize <= Int(UInt32.max) else {
            throw ForgeError.invalidOption("load path quá dài")
        }
        var command = Data(repeating: 0, count: commandSize)
        try command.writeUInt32LE(weak ? lcLoadWeakDylib : lcLoadDylib, at: 0)
        try command.writeUInt32LE(UInt32(commandSize), at: 4)
        try command.writeUInt32LE(24, at: 8)
        try command.writeUInt32LE(2, at: 12)
        try command.writeUInt32LE(0, at: 16)
        try command.writeUInt32LE(0, at: 20)
        try command.replaceChecked(offset: 24, bytes: stringBytes)
        return command
    }

    private static func makeRPathCommand(_ path: String) throws -> Data {
        let stringBytes = Array(path.utf8) + [0]
        let commandSize = aligned(12 + stringBytes.count, to: 8)
        guard commandSize <= Int(UInt32.max) else {
            throw ForgeError.invalidOption("rpath quá dài")
        }
        var command = Data(repeating: 0, count: commandSize)
        try command.writeUInt32LE(lcRpath, at: 0)
        try command.writeUInt32LE(UInt32(commandSize), at: 4)
        try command.writeUInt32LE(12, at: 8)
        try command.replaceChecked(offset: 12, bytes: stringBytes)
        return command
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func minimum(_ current: Int?, _ candidate: Int) -> Int {
        current.map { min($0, candidate) } ?? candidate
    }

    private static func rangesOverlap(_ lhs: SliceLocation, _ rhs: SliceLocation) -> Bool {
        lhs.offset < rhs.offset + rhs.size && rhs.offset < lhs.offset + lhs.size
    }

    private static func architectureName(_ cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100000C: return "arm64"
        case 0x0200000C: return "arm64_32"
        case 0x01000007: return "x86_64"
        default: return String(format: "cpu-0x%08X", cpuType)
        }
    }
}
