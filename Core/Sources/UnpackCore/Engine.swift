import Foundation
import SevenZip

/// Thin Swift wrapper over the 7-Zip bridge (Sources/SevenZip/include/uz_bridge.h).
enum SevenZipEngine {
    private final class ProgressBox {
        let call: (UInt64, UInt64) -> Void
        init(_ call: @escaping (UInt64, UInt64) -> Void) { self.call = call }
    }

    static func has(_ format: String) -> Bool { uz_has_format(format) != 0 }

    /// Extracts everything into `dest`. Throws `UnpackError`.
    @discardableResult
    static func extract(format: String, parts: [URL], into dest: URL, defaultName: String, password: String?,
                        progress: @escaping (UInt64, UInt64) -> Void) throws -> Int {
        let box = Unmanaged.passRetained(ProgressBox(progress))
        defer { box.release() }
        let owned = parts.map { strdup($0.path) }
        defer { owned.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        var message = [CChar](repeating: 0, count: 512)
        var files: Int32 = 0
        let status = uz_extract(format, ptrs, Int32(ptrs.count), dest.path, defaultName, password,
                                { ctx, done, total in
                                    Unmanaged<ProgressBox>.fromOpaque(ctx!).takeUnretainedValue().call(done, total)
                                    return 0
                                },
                                box.toOpaque(), &message, message.count, &files)
        let text = String(cString: message)
        switch status {
        case UZ_OK: return Int(files)
        case UZ_NEED_PASSWORD: throw UnpackError.passwordRequired
        case UZ_WRONG_PASSWORD: throw UnpackError.wrongPassword
        case UZ_UNKNOWN_FORMAT: throw UnpackError.unsupportedArchive(format)
        case UZ_MISSING_VOLUME: throw UnpackError.missingPart(text)
        case UZ_NOT_ARCHIVE: throw UnpackError.corrupt("not a readable \(format) archive")
        case UZ_DATA_ERROR: throw UnpackError.corrupt(text.isEmpty ? "data error" : text)
        default: throw UnpackError.failed(text.isEmpty ? "\(format): extraction failed" : text)
        }
    }
}

/// What this build can open, for the Settings screen (checked live, so a broken link shows up there).
public enum SupportedFormats {
    static let engineFormats: [(String, String)] = [
        ("7z", "7z"), ("Rar5", "RAR 5"), ("Rar", "RAR 4"), ("tar", "tar"), ("gzip", "gz"), ("bzip2", "bz2"),
        ("xz", "xz"), ("zstd", "zst"), ("lzma", "lzma"), ("Z", "Z"), ("Iso", "iso"), ("Cab", "cab"),
        ("Arj", "arj"), ("Lzh", "lzh"), ("wim", "wim"), ("Xar", "xar"), ("Cpio", "cpio"),
    ]

    public static var names: [String] {
        ["zip"] + engineFormats.filter { SevenZipEngine.has($0.0) }.map(\.1) + ["TT-tools PNG"]
    }

    public static var engineMissing: [String] {
        engineFormats.filter { !SevenZipEngine.has($0.0) }.map(\.1)
    }
}
