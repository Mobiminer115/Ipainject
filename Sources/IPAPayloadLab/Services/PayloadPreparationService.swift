import Foundation
import ForgeCore
import SWCompression

enum PayloadPreparationService {
    private static let maximumDebBytes = 536_870_912
    private static let maximumTarBytes = 2_147_483_648
    private static let maximumMachOBytes = 536_870_912

    static func prepare(_ stagedURL: URL) throws -> PreparedPayload {
        let values = try stagedURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let workspace = try makeWorkspace()
        var keepWorkspace = false
        defer {
            if !keepWorkspace { try? FileManager.default.removeItem(at: workspace) }
        }

        if values.isDirectory == true || stagedURL.pathExtension.lowercased() == "framework" {
            let localURL = workspace.appendingPathComponent(stagedURL.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: stagedURL, to: localURL)
            let asset = try frameworkAsset(at: localURL, origin: stagedURL.lastPathComponent)
            keepWorkspace = true
            return PreparedPayload(sourceName: stagedURL.lastPathComponent, assets: [asset], workspaceRoot: workspace)
        }

        switch stagedURL.pathExtension.lowercased() {
        case "dylib":
            let localURL = workspace.appendingPathComponent(stagedURL.lastPathComponent)
            try FileManager.default.copyItem(at: stagedURL, to: localURL)
            let asset = try dylibAsset(at: localURL, origin: stagedURL.lastPathComponent)
            keepWorkspace = true
            return PreparedPayload(sourceName: stagedURL.lastPathComponent, assets: [asset], workspaceRoot: workspace)
        case "deb":
            let assets = try assetsFromDeb(stagedURL, workspace: workspace)
            keepWorkspace = true
            return PreparedPayload(sourceName: stagedURL.lastPathComponent, assets: assets, workspaceRoot: workspace)
        default:
            throw ForgeError.unsupportedFormat("chỉ nhận .dylib, .framework hoặc .deb")
        }
    }

    private static func assetsFromDeb(_ debURL: URL, workspace: URL) throws -> [PreparedPayloadAsset] {
        let values = try debURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumDebBytes else {
            throw ForgeError.invalidArchive("DEB lớn hơn 512 MiB")
        }
        let debData = try Data(contentsOf: debURL, options: [.mappedIfSafe])
        let members = try ArArchive.open(debData, maximumMemberSize: maximumDebBytes)
        guard let versionMember = members.first(where: { $0.name == "debian-binary" }),
              String(decoding: versionMember.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "2.0" else {
            throw ForgeError.invalidArchive("thiếu hoặc sai member debian-binary")
        }
        let dataMembers = members.filter { $0.name.hasPrefix("data.tar") }
        guard dataMembers.count == 1, let dataMember = dataMembers.first else {
            throw ForgeError.invalidArchive("DEB phải có đúng một member data.tar")
        }

        let tarData: Data
        if dataMember.name == "data.tar" {
            tarData = dataMember.data
        } else if dataMember.name.hasSuffix(".gz") {
            tarData = try GzipArchive.unarchive(archive: dataMember.data)
        } else if dataMember.name.hasSuffix(".xz") {
            tarData = try XZArchive.unarchive(archive: dataMember.data)
        } else if dataMember.name.hasSuffix(".zst") || dataMember.name.hasSuffix(".zstd") {
            throw ForgeError.unsupportedFormat("DEB dùng data.tar.zst; hãy đóng gói lại bằng gzip hoặc xz")
        } else {
            throw ForgeError.unsupportedFormat(dataMember.name)
        }
        guard tarData.count <= maximumTarBytes else {
            throw ForgeError.invalidArchive("data.tar giải nén vượt 2 GiB")
        }

        let entries = try TarArchive.open(tarData)
        let frameworkRoots = Set(entries.compactMap { frameworkRoot(in: $0.path) }).sorted()
        let dylibPaths = entries.compactMap { entry -> String? in
            guard entry.kind == .file,
                  entry.path.lowercased().hasSuffix(".dylib"),
                  frameworkRoot(in: entry.path) == nil else { return nil }
            return entry.path
        }.sorted()

        var usedNames = Set<String>()
        var assets: [PreparedPayloadAsset] = []
        let frameworksDirectory = workspace.appendingPathComponent("Frameworks", isDirectory: true)
        let dylibsDirectory = workspace.appendingPathComponent("Dylibs", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dylibsDirectory, withIntermediateDirectories: true)

        for root in frameworkRoots {
            let name = URL(fileURLWithPath: root).lastPathComponent
            guard usedNames.insert(name.lowercased()).inserted else {
                throw ForgeError.invalidArchive("DEB có payload trùng tên: \(name)")
            }
            let destination = frameworksDirectory.appendingPathComponent(name, isDirectory: true)
            try materializeFramework(root: root, entries: entries, destination: destination)
            assets.append(try frameworkAsset(at: destination, origin: "\(debURL.lastPathComponent):\(root)"))
        }

        for path in dylibPaths {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard usedNames.insert(name.lowercased()).inserted else {
                throw ForgeError.invalidArchive("DEB có payload trùng tên: \(name)")
            }
            guard let entry = entries.first(where: { $0.path == path }), let data = entry.data else {
                throw ForgeError.invalidArchive("thiếu dữ liệu cho \(path)")
            }
            let destination = dylibsDirectory.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            try setExecutablePermission(destination)
            assets.append(try dylibAsset(at: destination, origin: "\(debURL.lastPathComponent):\(path)"))
        }

        guard !assets.isEmpty else {
            throw ForgeError.invalidArchive("DEB không chứa dylib hoặc framework Mach-O hợp lệ")
        }
        return assets
    }

    private static func frameworkAsset(at url: URL, origin: String) throws -> PreparedPayloadAsset {
        guard url.pathExtension.lowercased() == "framework" else {
            throw ForgeError.unsupportedFormat("thư mục đã chọn không có đuôi .framework")
        }
        let executableName = try frameworkExecutableName(at: url)
        let executableURL = url.appendingPathComponent(executableName)
        try validateMachOFile(executableURL)
        let data = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        let inspection = try MachOFile.inspect(data)
        return PreparedPayloadAsset(
            kind: .framework,
            sourceURL: url,
            name: url.lastPathComponent,
            executableName: executableName,
            architectures: inspection.architectures,
            origin: origin
        )
    }

    private static func dylibAsset(at url: URL, origin: String) throws -> PreparedPayloadAsset {
        try validateMachOFile(url)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let inspection = try MachOFile.inspect(data)
        return PreparedPayloadAsset(
            kind: .dylib,
            sourceURL: url,
            name: url.lastPathComponent,
            executableName: url.lastPathComponent,
            architectures: inspection.architectures,
            origin: origin
        )
    }

    private static func frameworkExecutableName(at frameworkURL: URL) throws -> String {
        let infoURL = frameworkURL.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: infoURL),
           let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = object as? [String: Any],
           let value = dictionary["CFBundleExecutable"] as? String,
           !value.isEmpty,
           value != ".",
           value != "..",
           !value.contains("/"),
           !value.contains("\\"),
           !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard FileManager.default.fileExists(atPath: frameworkURL.appendingPathComponent(value).path) else {
                throw ForgeError.invalidArchive("framework khai báo executable không tồn tại: \(value)")
            }
            return value
        }

        let fallback = frameworkURL.deletingPathExtension().lastPathComponent
        guard FileManager.default.fileExists(atPath: frameworkURL.appendingPathComponent(fallback).path) else {
            throw ForgeError.invalidArchive("không tìm thấy executable trong \(frameworkURL.lastPathComponent)")
        }
        return fallback
    }

    private static func frameworkRoot(in path: String) -> String? {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".framework") }) else {
            return nil
        }
        return components[...index].joined(separator: "/")
    }

    private static func materializeFramework(root: String, entries: [TarEntry], destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let prefix = root + "/"
        for entry in entries where entry.path == root || entry.path.hasPrefix(prefix) {
            guard entry.path != root else { continue }
            let relative = String(entry.path.dropFirst(prefix.count))
            let safeRelative = try PathPolicy.sanitizedArchivePath(relative)
            let output = destination.appendingPathComponent(safeRelative)
            guard output.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw ForgeError.unsafePath(entry.path)
            }
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
            case .file:
                guard let data = entry.data else {
                    throw ForgeError.invalidArchive("entry TAR thiếu dữ liệu: \(entry.path)")
                }
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
            case .symbolicLink:
                throw ForgeError.invalidArchive("framework trong DEB chứa symlink; hãy dùng bundle iOS dạng phẳng")
            }
        }
        let executable = try frameworkExecutableName(at: destination)
        try setExecutablePermission(destination.appendingPathComponent(executable))
    }

    private static func setExecutablePermission(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func validateMachOFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) > 0,
              (values.fileSize ?? 0) <= maximumMachOBytes else {
            throw ForgeError.invalidArchive("Mach-O không phải file thường hoặc lớn hơn 512 MiB")
        }
    }

    private static func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAPayloadLab", isDirectory: true)
            .appendingPathComponent("Payloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
