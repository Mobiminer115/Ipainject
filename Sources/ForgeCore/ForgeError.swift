import Foundation

public enum ForgeError: LocalizedError, Equatable, Sendable {
    case invalidArchive(String)
    case unsafePath(String)
    case unsupportedFormat(String)
    case invalidMachO(String)
    case insufficientHeaderSpace(required: Int, available: Int, architecture: String)
    case invalidOption(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail):
            return "Gói nén không hợp lệ: \(detail)"
        case .unsafePath(let path):
            return "Đường dẫn không an toàn: \(path)"
        case .unsupportedFormat(let detail):
            return "Định dạng chưa được hỗ trợ: \(detail)"
        case .invalidMachO(let detail):
            return "Mach-O không hợp lệ: \(detail)"
        case .insufficientHeaderSpace(let required, let available, let architecture):
            return "Không đủ khoảng trống header cho \(architecture) (cần \(required) byte, có \(available) byte)."
        case .invalidOption(let detail):
            return "Tùy chọn không hợp lệ: \(detail)"
        case .io(let detail):
            return "Lỗi tệp: \(detail)"
        }
    }
}
