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
    /// True when a zip was left unopened because the layer limit was reached.
    public var stoppedAtLimit = false
}

/// Progress inside one archive layer.
public struct UnpackProgress {
    /// 1 = the downloaded file, 2 = a zip inside it, …
    public let layer: Int
    /// Bytes written so far for the archive being extracted at `layer`.
    public let layerBytes: Int64
    /// Uncompressed size of that archive.
    public let layerTotal: Int64
    /// Bytes written so far for the whole file, all layers.
    public let totalBytes: Int64

    public var layerFraction: Double { layerTotal > 0 ? min(Double(layerBytes) / Double(layerTotal), 1) : 0 }
}

/// Removes every archive layer from a file and leaves the final contents in one folder.
public struct Unpacker {
    /// Tried in order on every layer (unless `layerPasswords` is set).
    public var passwords: [String]
    /// When set, layer n tries only `layerPasswords[n - 1]` (empty = no password). Layers past the end use the last entry.
    public var layerPasswords: [[String]]?
    /// Open exactly this many layers; anything still zipped after that is kept as a file. nil = automatic (up to `maxDepth`).
    public var layerLimit: Int?
    /// Archives nested deeper than this are left as files.
    public var maxDepth = 6
    public var chunkSize = 1 << 20

    /// Zip-based document formats that must never be treated as another layer.
    static let zipBasedDocuments: Set<String> = [
        "docx", "xlsx", "pptx", "docm", "xlsm", "pptm", "odt", "ods", "odp", "epub", "apk", "ipa",
        "jar", "pages", "numbers", "key", "kmz", "usdz", "xpi", "aar", "vsix", "3mf", "sketch",
    ]

    public init(passwords: [String], layerPasswords: [[String]]? = nil, layerLimit: Int? = nil) {
        self.passwords = passwords
        self.layerPasswords = layerPasswords
        self.layerLimit = layerLimit
    }

    var depthLimit: Int { min(max(layerLimit ?? maxDepth, 1), maxDepth) }

    /// The passwords tried on `layer` (1-based).
    public func passwords(forLayer layer: Int) -> [String] {
        guard let lp = layerPasswords, !lp.isEmpty else { return passwords }
        return lp[min(layer - 1, lp.count - 1)]
    }

    /// Reports the layer whose archive failed, alongside the error thrown by `unpack`.
    public final class FailureInfo { public internal(set) var layer = 1; public init() {} }

    /// - Parameters:
    ///   - input: the downloaded file (any extension).
    ///   - outputRoot: the folder that receives a new sub-folder named after `input`.
    ///   - progress: called with the cumulative number of bytes processed.
    ///   - onProgress: called with per-layer progress.
    ///   - failure: if given, holds the layer that was being opened when an error was thrown.
    public func unpack(_ input: URL, into outputRoot: URL,
                       failure: FailureInfo? = nil,
                       onProgress: ((UnpackProgress) -> Void)? = nil,
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

        let state = RunState(failure: failure ?? FailureInfo(), onProgress: onProgress, progress: progress)
        try extractAll(input, into: stage, depth: 1, state: state)

        let content = Self.collapse(stage)
        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let folder = Self.unique(outputRoot.appendingPathComponent(input.deletingPathExtension().lastPathComponent,
                                                                   isDirectory: true))
        try fm.moveItem(at: content, to: folder)
        var report = UnpackReport(folder: folder, files: Self.files(in: folder), layers: state.layers)
        report.stoppedAtLimit = state.stoppedAtLimit
        return report
    }

    final class RunState {
        let failure: FailureInfo
        let onProgress: ((UnpackProgress) -> Void)?
        let progress: ((Int64) -> Void)?
        var layers = 0
        var total: Int64 = 0
        var stoppedAtLimit = false
        init(failure: FailureInfo, onProgress: ((UnpackProgress) -> Void)?, progress: ((Int64) -> Void)?) {
            self.failure = failure; self.onProgress = onProgress; self.progress = progress
        }
    }

    private func extractAll(_ archiveURL: URL, into dest: URL, depth: Int, state: RunState) throws {
        state.layers = max(state.layers, depth)
        state.failure.layer = depth
        let fm = FileManager.default
        let zip = try ZipArchive(url: archiveURL)
        zip.chunkSize = chunkSize
        let password = try choosePassword(for: zip, layer: depth)
        let layerTotal = zip.entries.reduce(Int64(0)) { $0 + Int64(clamping: $1.uncompressedSize) }
        var layerBytes: Int64 = 0
        let tick: (Int) -> Void = { n in
            layerBytes += Int64(n)
            state.total += Int64(n)
            state.progress?(state.total)
            state.onProgress?(UnpackProgress(layer: depth, layerBytes: layerBytes, layerTotal: layerTotal,
                                             totalBytes: state.total))
        }

        for entry in zip.entries {
            guard let parts = entry.safeComponents, parts.first != "__MACOSX", parts.last != ".DS_Store" else { continue }
            let target = parts.reduce(dest) { $0.appendingPathComponent($1) }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            state.failure.layer = depth
            try zip.extract(entry, to: target, password: password, progress: tick)

            guard !Self.zipBasedDocuments.contains(target.pathExtension.lowercased()) else { continue }
            let kind = ArchiveKind.detect(target)
            guard depth < depthLimit else {
                if kind == .zip { state.stoppedAtLimit = true }
                continue
            }
            switch kind {
            case .zip:
                let sub = Self.unique(target.deletingPathExtension())
                try extractAll(target, into: sub, depth: depth + 1, state: state)
                try fm.removeItem(at: target)
            case .sevenZip: throw UnpackError.unsupportedArchive("7z (inner layer)")
            case .rar: throw UnpackError.unsupportedArchive("RAR (inner layer)")
            case .other: break
            }
        }
    }

    /// Picks the first password for this layer that opens the archive's first encrypted file.
    private func choosePassword(for zip: ZipArchive, layer: Int) throws -> String? {
        guard let probe = zip.entries.first(where: { $0.isEncrypted && !$0.isDirectory }) else { return nil }
        let candidates = passwords(forLayer: layer).filter { !$0.isEmpty }
        guard !candidates.isEmpty else { throw UnpackError.passwordRequired }
        for pw in candidates where zip.accepts(password: pw, for: probe) { return pw }
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
