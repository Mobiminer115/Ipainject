import Foundation
import ForgeCore

struct ExecutableCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let relativePath: String
    let bundleRootRelativePath: String
    let architectures: [String]
    let headerSlack: Int
    let isMainExecutable: Bool
}

struct PreparedIPA: Sendable {
    let sourceURL: URL
    let extractionRoot: URL
    let mainAppRelativePath: String
    let displayName: String
    let bundleIdentifier: String
    let version: String
    let executables: [ExecutableCandidate]
}

enum PayloadKind: String, Hashable, Sendable {
    case dylib
    case framework

    var title: String {
        switch self {
        case .dylib: return "Dylib"
        case .framework: return "Framework"
        }
    }
}

struct PreparedPayloadAsset: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: PayloadKind
    let sourceURL: URL
    let name: String
    let executableName: String
    let architectures: [String]
    let origin: String

    init(
        id: UUID = UUID(),
        kind: PayloadKind,
        sourceURL: URL,
        name: String,
        executableName: String,
        architectures: [String],
        origin: String
    ) {
        self.id = id
        self.kind = kind
        self.sourceURL = sourceURL
        self.name = name
        self.executableName = executableName
        self.architectures = architectures
        self.origin = origin
    }
}

struct PreparedPayload: Sendable {
    let sourceName: String
    let assets: [PreparedPayloadAsset]
    let workspaceRoot: URL
}

enum DestinationLocation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case frameworks
    case executableDirectory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frameworks: return "Thư mục Frameworks"
        case .executableDirectory: return "Cạnh executable"
        }
    }

    var relativeDirectory: String {
        switch self {
        case .frameworks: return "Frameworks"
        case .executableDirectory: return ""
        }
    }
}

enum LoadReferenceRoot: String, CaseIterable, Hashable, Identifiable, Sendable {
    case rpath
    case executablePath
    case loaderPath

    var id: String { rawValue }

    var token: String {
        switch self {
        case .rpath: return "@rpath"
        case .executablePath: return "@executable_path"
        case .loaderPath: return "@loader_path"
        }
    }
}

enum RPathChoice: String, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case executableFrameworks
    case loaderFrameworks
    case custom
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Tự động theo vị trí"
        case .executableFrameworks: return "@executable_path/Frameworks"
        case .loaderFrameworks: return "@loader_path/Frameworks"
        case .custom: return "Tùy chỉnh"
        case .none: return "Không thêm"
        }
    }
}

struct InjectionOptions: Sendable {
    let destination: DestinationLocation
    let referenceRoot: LoadReferenceRoot
    let rpathChoice: RPathChoice
    let customRPath: String
    let weakLoad: Bool
    let replaceExisting: Bool
}

struct PatchedAssetReport: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let destination: String
    let loadPath: String
}

struct PatchPipelineResult: Sendable {
    let outputURL: URL
    let executable: String
    let assets: [PatchedAssetReport]
    let patchReport: MachOPatchReport
}
