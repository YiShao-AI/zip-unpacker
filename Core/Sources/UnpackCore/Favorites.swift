import Foundation

/// The star on a favorite file. It is an extended attribute on the file itself rather than an
/// entry in a list, so it follows moves, renames and merges and goes when the file goes.
public enum Favorites {
    private static let attribute = "com.yishao.unpacker.favorite"

    public static func isFavorite(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, attribute, nil, 0, 0, 0) >= 0
        }
    }

    public static func set(_ on: Bool, _ url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            if on {
                var flag: UInt8 = 1
                return setxattr(path, attribute, &flag, 1, 0, 0)
            }
            return removexattr(path, attribute, 0)
        }
        guard result != 0 else { return }
        let code = errno
        if !on && code == ENOATTR { return }      // already off
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
