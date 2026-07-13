import Foundation
import ForgeCore
import ZIPFoundation

enum IPAArchiveService {
    private static let maximumEntries = 60_000
    private static let maximumExpandedBytes: UInt64 = 8_589_934_592
    private static let maximumExecutableBytes = 536_870_912

    static func prepare(_ ipaURL: URL) throws -> PreparedIPA {
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            throw ForgeError.unsupportedFormat("hãy chọn tệp .ipa")
        }

        try preflight(ipaURL)
        let extractionRoot = try makeWorkspace(named: "Inspect")
        var keepExtraction = false
        defer {
            if !keepExtraction { try? FileManager.default.removeItem(at: extractionRoot) }
        }
        do {
            try FileManager.default.unzipItem(at: ipaURL, to: extractionRoot)
        } catch {
            throw ForgeError.invalidArchive("không giải nén được IPA: \(error.localizedDescription)")
        }

        let payloadDirectory = extractionRoot.appendingPathComponent("Payload", isDirectory: true)
        let apps = try FileManager.default.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.pathExtension.lowercased() == "app"
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard apps.count == 1, let appURL = apps.first else {
            throw ForgeError.invalidArchive("Payload phải chứa đúng một app chính")
        }

        let appInfo = try propertyList(at: appURL.appendingPathComponent("Info.plist"))
        let displayName = stringValue(appInfo, keys: ["CFBundleDisplayName", "CFBundleName"])
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleIdentifier = appInfo["CFBundleIdentifier"] as? String ?? "Không rõ bundle ID"
        let version = stringValue(appInfo, keys: ["CFBundleShortVersionString", "CFBundleVersion"]) ?? "Không rõ"
        let executables = try executableCandidates(in: appURL, mainInfo: appInfo)
        guard executables.contains(where: \.isMainExecutable) else {
            throw ForgeError.invalidArchive("không tìm thấy executable chính hợp lệ")
        }

        let appRelative = "Payload/\(appURL.lastPathComponent)"
        keepExtraction = true
        return PreparedIPA(
            sourceURL: ipaURL,
            extractionRoot: extractionRoot,
            mainAppRelativePath: appRelative,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            version: version,
            executables: executables
        )
    }

    static func cloneExtraction(of prepared: PreparedIPA) throws -> URL {
        let destination = try makeWorkspace(named: "Patch")
        try FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: prepared.extractionRoot, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ForgeError.io("không tạo được bản làm việc sạch: \(error.localizedDescription)")
        }
        return destination
    }

    static func createIPA(from extractionRoot: URL, destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.zipItem(
                at: extractionRoot,
                to: destination,
                shouldKeepParent: false,
                compressionMethod: .deflate
            )
            try preflight(destination)
        } catch let error as ForgeError {
            try? fileManager.removeItem(at: destination)
            throw error
        } catch {
            try? fileManager.removeItem(at: destination)
            throw ForgeError.io("không tạo được IPA đầu ra: \(error.localizedDescription)")
        }
    }

    static func preflight(_ ipaURL: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: ipaURL, accessMode: .read)
        } catch {
            throw ForgeError.invalidArchive("ZIP không đọc được: \(error.localizedDescription)")
        }

        var count = 0
        var expanded: UInt64 = 0
        var hasPayload = false
        var normalizedPaths = Set<String>()
        for entry in archive {
            count += 1
            guard count <= maximumEntries else {
                throw ForgeError.invalidArchive("IPA có quá nhiều entry")
            }
            let path = try PathPolicy.sanitizedArchivePath(entry.path)
            guard normalizedPaths.insert(path.lowercased()).inserted else {
                throw ForgeError.invalidArchive("IPA có entry trùng đường dẫn: \(path)")
            }
            if path == "Payload" || path.hasPrefix("Payload/") { hasPayload = true }
            guard entry.type != .symlink else {
                throw ForgeError.invalidArchive("IPA chứa symlink; từ chối để tránh thoát thư mục")
            }
            let (next, overflow) = expanded.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, next <= maximumExpandedBytes else {
                throw ForgeError.invalidArchive("IPA giải nén vượt 8 GiB")
            }
            expanded = next
        }
        guard count > 0, hasPayload else {
            throw ForgeError.invalidArchive("ZIP không có thư mục Payload")
        }
    }

    private static func executableCandidates(
        in mainApp: URL,
        mainInfo: [String: Any]
    ) throws -> [ExecutableCandidate] {
        var bundleRoots = [mainApp]
        if let enumerator = FileManager.default.enumerator(
            at: mainApp,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "appex" {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    bundleRoots.append(url)
                }
            }
        }

        var candidates: [ExecutableCandidate] = []
        for bundleRoot in bundleRoots {
            let isMain = bundleRoot == mainApp
            let info = isMain ? mainInfo : try propertyList(at: bundleRoot.appendingPathComponent("Info.plist"))
            guard let executableName = info["CFBundleExecutable"] as? String,
                  !executableName.isEmpty,
                  executableName != ".",
                  executableName != "..",
                  !executableName.contains("/"),
                  !executableName.contains("\\"),
                  !executableName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                if isMain { throw ForgeError.invalidArchive("Info.plist thiếu CFBundleExecutable") }
                continue
            }
            let executableURL = bundleRoot.appendingPathComponent(executableName)
            let executableValues = try executableURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard executableValues.isRegularFile == true,
                  (executableValues.fileSize ?? 0) > 0,
                  (executableValues.fileSize ?? 0) <= maximumExecutableBytes else {
                throw ForgeError.invalidArchive("executable không phải file thường hoặc lớn hơn 512 MiB")
            }
            let executableData = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
            let inspection = try MachOFile.inspect(executableData)
            let bundleRelative = relativePath(of: bundleRoot, beneath: mainApp)
            let executableRelative = bundleRelative.isEmpty
                ? executableName
                : "\(bundleRelative)/\(executableName)"
            let bundleName = stringValue(info, keys: ["CFBundleDisplayName", "CFBundleName"])
                ?? bundleRoot.deletingPathExtension().lastPathComponent
            candidates.append(ExecutableCandidate(
                id: executableRelative,
                displayName: isMain ? "\(bundleName) (chính)" : bundleName,
                relativePath: executableRelative,
                bundleRootRelativePath: bundleRelative,
                architectures: inspection.architectures,
                headerSlack: inspection.slices.map(\.headerSlack).min() ?? 0,
                isMainExecutable: isMain
            ))
        }
        return candidates.sorted {
            if $0.isMainExecutable != $1.isMainExecutable { return $0.isMainExecutable }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private static func propertyList(at url: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw ForgeError.invalidArchive("Info.plist không phải dictionary")
            }
            return dictionary
        } catch let error as ForgeError {
            throw error
        } catch {
            throw ForgeError.invalidArchive("không đọc được \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func relativePath(of url: URL, beneath root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func makeWorkspace(named component: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAPayloadLab", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
