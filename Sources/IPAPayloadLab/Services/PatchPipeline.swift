import Foundation
import ForgeCore

enum PatchPipeline {
    static func run(
        ipa: PreparedIPA,
        target: ExecutableCandidate,
        assets: [PreparedPayloadAsset],
        options: InjectionOptions
    ) throws -> PatchPipelineResult {
        guard !assets.isEmpty else {
            throw ForgeError.invalidOption("chưa chọn payload")
        }
        try validateArchitectures(target: target, assets: assets)

        let workRoot = try IPAArchiveService.cloneExtraction(of: ipa)
        defer { try? FileManager.default.removeItem(at: workRoot) }

        let mainApp = workRoot.appendingPathComponent(ipa.mainAppRelativePath, isDirectory: true)
        let bundleRoot = target.bundleRootRelativePath.isEmpty
            ? mainApp
            : mainApp.appendingPathComponent(target.bundleRootRelativePath, isDirectory: true)
        let executableURL = mainApp.appendingPathComponent(target.relativePath)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ForgeError.io("executable đã chọn không còn tồn tại")
        }

        let destinationDirectory = options.destination.relativeDirectory.isEmpty
            ? bundleRoot
            : bundleRoot.appendingPathComponent(options.destination.relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var loadPaths: [String] = []
        var assetReports: [PatchedAssetReport] = []
        for asset in assets {
            let destination = try copyAsset(
                asset,
                to: destinationDirectory,
                replaceExisting: options.replaceExisting
            )
            let loadPath = try makeLoadPath(asset: asset, options: options)
            loadPaths.append(loadPath)
            let relativeDestination = relativePath(of: destination, beneath: mainApp)
            assetReports.append(PatchedAssetReport(
                name: asset.name,
                destination: relativeDestination,
                loadPath: loadPath
            ))
        }

        let rpaths = try requestedRPaths(options)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: executableURL.path)
        let executableData = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        let (patchedData, patchReport) = try MachOFile.patch(
            executableData,
            request: MachOPatchRequest(
                loadPaths: loadPaths,
                rpaths: rpaths,
                weakLoad: options.weakLoad
            )
        )
        try patchedData.write(to: executableURL, options: .atomic)
        if let permissions = originalAttributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: executableURL.path)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        }

        let postWriteData = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        let postWriteInspection = try MachOFile.inspect(postWriteData)
        for slice in postWriteInspection.slices {
            guard loadPaths.allSatisfy({ slice.loadPaths.contains($0) }),
                  rpaths.allSatisfy({ slice.rpaths.contains($0) }) else {
                throw ForgeError.invalidMachO("xác minh trên đĩa thất bại ở \(slice.architecture)")
            }
        }

        let outputURL = try outputURL(for: ipa.sourceURL)
        try IPAArchiveService.createIPA(from: workRoot, destination: outputURL)
        return PatchPipelineResult(
            outputURL: outputURL,
            executable: target.relativePath,
            assets: assetReports,
            patchReport: patchReport
        )
    }

    private static func validateArchitectures(
        target: ExecutableCandidate,
        assets: [PreparedPayloadAsset]
    ) throws {
        let required = Set(target.architectures)
        for asset in assets {
            let available = Set(asset.architectures)
            let missing = required.subtracting(available)
            guard missing.isEmpty else {
                throw ForgeError.invalidOption(
                    "\(asset.name) thiếu kiến trúc: \(missing.sorted().joined(separator: ", "))"
                )
            }
        }
    }

    private static func copyAsset(
        _ asset: PreparedPayloadAsset,
        to directory: URL,
        replaceExisting: Bool
    ) throws -> URL {
        guard !asset.name.contains("/"),
              (try? PathPolicy.sanitizedArchivePath(asset.name)) == asset.name else {
            throw ForgeError.unsafePath(asset.name)
        }

        let fileManager = FileManager.default
        let existing = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first { $0.lastPathComponent.caseInsensitiveCompare(asset.name) == .orderedSame }
        if let existing {
            guard replaceExisting else {
                throw ForgeError.io("đích đã có \(existing.lastPathComponent); bật “Ghi đè” nếu muốn thay")
            }
            try fileManager.removeItem(at: existing)
        }

        let destination = directory.appendingPathComponent(asset.name, isDirectory: asset.kind == .framework)
        guard destination.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw ForgeError.unsafePath(asset.name)
        }
        do {
            try fileManager.copyItem(at: asset.sourceURL, to: destination)
            let embeddedExecutable = asset.kind == .framework
                ? destination.appendingPathComponent(asset.executableName)
                : destination
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: embeddedExecutable.path)
        } catch {
            throw ForgeError.io("không nhúng được \(asset.name): \(error.localizedDescription)")
        }
        return destination
    }

    private static func makeLoadPath(
        asset: PreparedPayloadAsset,
        options: InjectionOptions
    ) throws -> String {
        let payloadComponent: String
        switch asset.kind {
        case .dylib:
            payloadComponent = asset.name
        case .framework:
            payloadComponent = "\(asset.name)/\(asset.executableName)"
        }

        let path: String
        if options.referenceRoot == .rpath {
            path = "@rpath/\(payloadComponent)"
        } else if options.destination.relativeDirectory.isEmpty {
            path = "\(options.referenceRoot.token)/\(payloadComponent)"
        } else {
            path = "\(options.referenceRoot.token)/\(options.destination.relativeDirectory)/\(payloadComponent)"
        }
        return try PathPolicy.validateLoadPath(path)
    }

    private static func requestedRPaths(_ options: InjectionOptions) throws -> [String] {
        let path: String?
        switch options.rpathChoice {
        case .automatic:
            path = options.destination.relativeDirectory.isEmpty
                ? "@executable_path"
                : "@executable_path/\(options.destination.relativeDirectory)"
        case .executableFrameworks:
            path = "@executable_path/Frameworks"
        case .loaderFrameworks:
            path = "@loader_path/Frameworks"
        case .custom:
            path = options.customRPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .none:
            path = nil
        }
        guard let path else { return [] }
        return [try PathPolicy.validateRPath(path)]
    }

    private static func outputURL(for source: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawBase = source.deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeBase = rawBase.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(safeBase)-patched-\(formatter.string(from: Date())).ipa"
        return directory.appendingPathComponent(name)
    }

    private static func relativePath(of url: URL, beneath root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return String(path.dropFirst(rootPath.count + 1))
    }
}
