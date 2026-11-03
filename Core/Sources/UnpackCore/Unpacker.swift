import Foundation

public enum ArchiveKind: Equatable {
    case zip, sevenZip, rar, other

    /// Detects the format from the file's first bytes; the extension is ignored.
    public static func detect(_ url: URL) -> ArchiveKind {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? fh.close() }
        let b = [UInt8]((try? fh.read(upToCount: 8)) ?? Data())
        guard b.count >= 4 else { return .other }
        if b[0] == 0x50, b[1] == 0x4B, [3, 5, 7].contains(b[2]), b[3] == b[2] + 1 { return .zip }
        if b.count >= 6, b[0...5] == [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C] { return .sevenZip }
        if b.count >= 6, b[0...5] == [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07] { return .rar }
        return .other
    }
}

public struct UnpackReport {
    /// Folder holding the final contents.
    public let folder: URL
    /// Every file inside `folder`, recursively.
    public let files: [URL]
    /// How many archive layers were removed.
    public let layers: Int
}

/// Removes every archive layer from a file and leaves the final contents in one folder.
public struct Unpacker {
    public var passwords: [String]
    /// Archives nested deeper than this are left as files.
    public var maxDepth = 6
    public var chunkSize = 1 << 20

    /// Zip-based document formats that must never be treated as another layer.
    static let zipBasedDocuments: Set<String> = [
        "docx", "xlsx", "pptx", "docm", "xlsm", "pptm", "odt", "ods", "odp", "epub", "apk", "ipa",
        "jar", "pages", "numbers", "key", "kmz", "usdz", "xpi", "aar", "vsix", "3mf", "sketch",
    ]

    public init(passwords: [String]) { self.passwords = passwords }

    /// - Parameters:
    ///   - input: the downloaded file (any extension).
    ///   - outputRoot: the folder that receives a new sub-folder named after `input`.
    ///   - progress: called with the cumulative number of bytes processed.
    public func unpack(_ input: URL, into outputRoot: URL,
                       progress: ((Int64) -> Void)? = nil) throws -> UnpackReport {
        switch ArchiveKind.detect(input) {
        case .zip: break
        case .sevenZip: throw UnpackError.unsupportedArchive("7z")
        case .rar: throw UnpackError.unsupportedArchive("RAR")
        case .other: throw UnpackError.notAnArchive
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var done: Int64 = 0
        let tick: (Int) -> Void = { n in
            done += Int64(n)
            progress?(done)
        }
        var layers = 0
        try extractAll(input, into: stage, depth: 1, layers: &layers, tick: tick)

        let content = Self.collapse(stage)
        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let folder = Self.unique(outputRoot.appendingPathComponent(input.deletingPathExtension().lastPathComponent,
                                                                   isDirectory: true))
        try fm.moveItem(at: content, to: folder)
        return UnpackReport(folder: folder, files: Self.files(in: folder), layers: layers)
    }

    private func extractAll(_ archiveURL: URL, into dest: URL, depth: Int, layers: inout Int,
                            tick: @escaping (Int) -> Void) throws {
        layers = max(layers, depth)
        let fm = FileManager.default
        let zip = try ZipArchive(url: archiveURL)
        zip.chunkSize = chunkSize
        let password = try choosePassword(for: zip)

        for entry in zip.entries {
            guard let parts = entry.safeComponents, parts.first != "__MACOSX", parts.last != ".DS_Store" else { continue }
            let target = parts.reduce(dest) { $0.appendingPathComponent($1) }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.extract(entry, to: target, password: password, progress: tick)

            guard depth < maxDepth,
                  !Self.zipBasedDocuments.contains(target.pathExtension.lowercased()) else { continue }
            switch ArchiveKind.detect(target) {
            case .zip:
                let sub = Self.unique(target.deletingPathExtension())
                try extractAll(target, into: sub, depth: depth + 1, layers: &layers, tick: tick)
                try fm.removeItem(at: target)
            case .sevenZip: throw UnpackError.unsupportedArchive("7z (inner layer)")
            case .rar: throw UnpackError.unsupportedArchive("RAR (inner layer)")
            case .other: break
            }
        }
    }

    /// Picks the first saved password that opens the archive's first encrypted file.
    private func choosePassword(for zip: ZipArchive) throws -> String? {
        guard let probe = zip.entries.first(where: { $0.isEncrypted && !$0.isDirectory }) else { return nil }
        guard !passwords.isEmpty else { throw UnpackError.passwordRequired }
        for pw in passwords where zip.accepts(password: pw, for: probe) { return pw }
        throw UnpackError.wrongPassword
    }

    // MARK: Helpers

    /// Follows a chain of folders that each contain only one sub-folder.
    static func collapse(_ dir: URL) -> URL {
        var current = dir
        while let items = try? FileManager.default.contentsOfDirectory(
                at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
              items.count == 1,
              (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            current = items[0]
        }
        return current
    }

    /// `url`, or `url` with " 2", " 3"… appended if something already exists there.
    public static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    public static func files(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
