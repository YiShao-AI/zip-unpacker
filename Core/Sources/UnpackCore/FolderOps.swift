import Foundation

/// Moving, copying, renaming and merging inside the app's folders. Nothing is ever overwritten:
/// a folder whose name already exists is merged into, and a clashing file name gets " 2", " 3"…
public enum FolderOps {
    public enum OpsError: Error, LocalizedError, Equatable {
        case intoItself(String)
        case badName

        public var errorDescription: String? {
            switch self {
            case .intoItself(let name): return "“\(name)” can't go inside itself."
            case .badName: return "That name can't be used."
            }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func contents(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    /// A name that is safe as a single path component.
    public static func cleanName(_ name: String) -> String? {
        let n = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != ".", n != "..", !n.hasPrefix(".") else { return nil }
        return n
    }

    /// Moves or copies `item` into `folder` (created if needed). Returns where it ended up.
    @discardableResult
    public static func transfer(_ item: URL, into folder: URL, move: Bool) throws -> URL {
        let fm = FileManager.default
        let src = item.standardizedFileURL
        let dst = folder.standardizedFileURL
        if dst.path == src.path || dst.path.hasPrefix(src.path + "/") {
            throw OpsError.intoItself(item.lastPathComponent)
        }
        // Already directly inside the target: nothing to do for a move.
        if move, src.deletingLastPathComponent().path == dst.path { return item }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let target = folder.appendingPathComponent(item.lastPathComponent)
        if isDirectory(item), isDirectory(target) {
            for child in contents(item) { try transfer(child, into: target, move: move) }
            if move, contents(item).isEmpty { try? fm.removeItem(at: item) }
            return target
        }
        let final = Unpacker.unique(target)
        if move { try fm.moveItem(at: item, to: final) } else { try fm.copyItem(at: item, to: final) }
        return final
    }

    @discardableResult
    public static func createFolder(named name: String, in parent: URL) throws -> URL {
        guard let n = cleanName(name) else { throw OpsError.badName }
        let url = Unpacker.unique(parent.appendingPathComponent(n, isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    public static func rename(_ item: URL, to name: String) throws -> URL {
        guard let n = cleanName(name) else { throw OpsError.badName }
        if n == item.lastPathComponent { return item }
        let target = Unpacker.unique(item.deletingLastPathComponent().appendingPathComponent(n))
        try FileManager.default.moveItem(at: item, to: target)
        return target
    }

    /// Removes folders under `root` (not `root` itself) that hold nothing visible.
    public static func removeEmptyFolders(in root: URL) {
        for child in contents(root) where isDirectory(child) {
            removeEmptyFolders(in: child)
            if contents(child).isEmpty { try? FileManager.default.removeItem(at: child) }
        }
    }

    /// Moves the favorites in `batch` into `target`, each into a folder named after its own, so the
    /// batch can be deleted. Stops at the first one that can't move; the rest stay where they are.
    @discardableResult
    public static func saveFavorites(in batch: URL, to target: URL) throws -> Int {
        let base = batch.standardizedFileURL.path
        let starred = Unpacker.files(in: batch).filter(Favorites.isFavorite)
        for file in starred {
            let parent = file.deletingLastPathComponent()
            let isLoose = parent.standardizedFileURL.path == base
            try transfer(file, into: isLoose ? target : target.appendingPathComponent(parent.lastPathComponent), move: true)
        }
        return starred.count
    }

    /// Combines `sources` into one new folder `destination` (folders with the same name merge).
    /// With `move`, the sources are emptied and removed.
    @discardableResult
    public static func merge(_ sources: [URL], into destination: URL, move: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for source in sources where source.standardizedFileURL != destination.standardizedFileURL {
            for child in contents(source) { try transfer(child, into: destination, move: move) }
            if move { try? fm.removeItem(at: source) }
        }
        return destination
    }
}
