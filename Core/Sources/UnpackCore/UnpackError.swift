import Foundation

public enum UnpackError: Error, LocalizedError, Equatable {
    case notAnArchive
    case unsupportedArchive(String)
    case corrupt(String)
    case passwordRequired
    case wrongPassword
    case unsupportedMethod(UInt16)
    case integrity(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive: return "Not a zip archive."
        case .unsupportedArchive(let kind): return "\(kind) archives aren't supported yet."
        case .corrupt(let why): return "The archive is damaged (\(why))."
        case .passwordRequired: return "This archive needs a password. Add one in Settings."
        case .wrongPassword: return "None of the saved passwords worked."
        case .unsupportedMethod(let m): return "Unsupported compression method \(m)."
        case .integrity(let why): return "Integrity check failed: \(why)."
        }
    }
}
