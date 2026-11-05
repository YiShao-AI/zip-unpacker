import Foundation

public enum UnpackError: Error, LocalizedError, Equatable {
    case notAnArchive
    case unsupportedArchive(String)
    case corrupt(String)
    case passwordRequired
    case wrongPassword
    case unsupportedMethod(UInt16)
    case integrity(String)
    /// A part of a multi-part archive is missing (message names it when known).
    case missingPart(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive: return "Not an archive Unpacker can read."
        case .unsupportedArchive(let kind): return "\(kind) archives aren't supported yet."
        case .corrupt(let why): return "The archive is damaged (\(why))."
        case .passwordRequired: return "This archive needs a password. Add one in Settings."
        case .wrongPassword: return "None of the saved passwords worked."
        case .unsupportedMethod(let m): return "Unsupported compression method \(m)."
        case .integrity(let why): return "Integrity check failed: \(why)."
        case .missingPart(let why): return why.isEmpty ? "A part of this multi-part archive is missing." : why + "."
        case .failed(let why): return why
        }
    }
}
