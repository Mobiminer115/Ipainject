import Foundation

public enum PathPolicy {
    private static let loaderRoots = ["@rpath", "@executable_path", "@loader_path"]

    public static func sanitizedArchivePath(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty, rawPath.utf8.count <= 4_096 else {
            throw ForgeError.unsafePath(rawPath)
        }
        guard !rawPath.contains("\0"),
              !rawPath.contains("\\"),
              !rawPath.hasPrefix("/"),
              !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeError.unsafePath(rawPath)
        }

        var components: [Substring] = []
        for component in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != "..", !component.contains(":") else {
                throw ForgeError.unsafePath(rawPath)
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            throw ForgeError.unsafePath(rawPath)
        }
        return components.joined(separator: "/")
    }

    public static func validateLoadPath(_ path: String) throws -> String {
        try validateLoaderPath(path, label: "load path", allowRootOnly: false)
    }

    public static func validateRPath(_ path: String) throws -> String {
        try validateLoaderPath(path, label: "rpath", allowRootOnly: true)
    }

    private static func validateLoaderPath(
        _ path: String,
        label: String,
        allowRootOnly: Bool
    ) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= 1_024,
              !path.contains("\0"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeError.invalidOption("\(label) trống, quá dài hoặc chứa ký tự cấm")
        }
        guard !path.hasSuffix("/"), !path.contains("//") else {
            throw ForgeError.invalidOption("\(label) có dấu gạch chéo thừa")
        }

        guard let root = loaderRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw ForgeError.invalidOption("\(label) phải bắt đầu bằng @rpath, @executable_path hoặc @loader_path")
        }
        if !allowRootOnly && path == root {
            throw ForgeError.invalidOption("\(label) phải trỏ tới một tệp")
        }

        let suffix = path.dropFirst(root.count)
        for component in suffix.split(separator: "/", omittingEmptySubsequences: true) {
            guard component != ".", component != "..", !component.contains(":") else {
                throw ForgeError.invalidOption("\(label) chứa thành phần đường dẫn không an toàn")
            }
        }
        return path
    }

    public static func safeRelativeSymlinkTarget(_ target: String) -> Bool {
        guard !target.isEmpty,
              !target.hasPrefix("/"),
              !target.contains("\\"),
              !target.contains("\0"),
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return !target.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
