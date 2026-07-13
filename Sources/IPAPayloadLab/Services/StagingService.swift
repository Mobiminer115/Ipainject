import Foundation
import ForgeCore

enum StagingService {
    private static let maximumBytes: Int64 = 2_147_483_648

    static func stage(_ externalURL: URL) throws -> URL {
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { externalURL.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("IPAPayloadLab", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let values = try externalURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            let size = try recursiveSize(of: externalURL)
            guard size <= maximumBytes else {
                throw ForgeError.io("payload lớn hơn 2 GiB")
            }
        } else {
            guard Int64(values.fileSize ?? 0) <= maximumBytes else {
                throw ForgeError.io("tệp lớn hơn 2 GiB")
            }
        }

        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(externalURL.lastPathComponent)
        do {
            try fileManager.copyItem(at: externalURL, to: destination)
            let copiedValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let copiedSize: Int64
            if copiedValues.isDirectory == true {
                copiedSize = try recursiveSize(of: destination)
            } else {
                copiedSize = Int64(copiedValues.fileSize ?? 0)
            }
            guard copiedSize <= maximumBytes else {
                throw ForgeError.io("bản sao staging lớn hơn 2 GiB")
            }
        } catch let error as ForgeError {
            try? fileManager.removeItem(at: base)
            throw error
        } catch {
            try? fileManager.removeItem(at: base)
            throw ForgeError.io("không thể sao chép tệp đã chọn: \(error.localizedDescription)")
        }
        return destination
    }

    private static func recursiveSize(of directory: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw ForgeError.io("không thể đọc thư mục payload")
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw ForgeError.io("framework được chọn chứa symlink; hãy dùng bundle iOS dạng phẳng")
            }
            if values.isRegularFile == true {
                let (next, overflow) = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
                guard !overflow, next <= maximumBytes else {
                    throw ForgeError.io("payload lớn hơn 2 GiB")
                }
                total = next
            }
        }
        return total
    }
}
