import Foundation

public struct UnpackReport {
    /// Folder holding the final contents.
    public let folder: URL
    /// Every file inside `folder`, recursively.
    public var files: [URL]
    /// How many archive layers were removed.
    public let layers: Int
    /// True when a zip was left unopened because the layer limit was reached.
    public var stoppedAtLimit = false
    /// Folder input only: zips inside that couldn't be opened ("path: reason"). They are kept as files.
    public var failedInside: [String] = []
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
        if FolderOps.isDirectory(input) {
            return try unpackFolder(input, into: outputRoot, failure: failure, onProgress: onProgress, progress: progress)
        }
        guard ArchiveKind.detect(input).isArchive else { throw UnpackError.notAnArchive }

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

    /// A folder keeps its structure: every zip inside (and every split zip set) is replaced by its unpacked
    /// contents, other files are copied as they are. A zip that fails is kept as a file and listed in the report.
    func unpackFolder(_ input: URL, into outputRoot: URL, failure: FailureInfo?,
                      onProgress: ((UnpackProgress) -> Void)?, progress: ((Int64) -> Void)?) throws -> UnpackReport {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let root = work.appendingPathComponent(input.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: input, to: root)   // a clone on APFS: no extra space until files change

        let state = RunState(failure: failure ?? FailureInfo(), onProgress: onProgress, progress: progress)
        var failed: [String] = []
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        func rel(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
        }
        try expandNested(root, producedBy: 0, state: state) { archive, error in
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let layer = state.failure.layer
            failed.append("\(rel(archive)): \(layer > 1 ? "layer \(layer): " : "")\(why)")
        }

        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let folder = Self.unique(outputRoot.appendingPathComponent(input.lastPathComponent, isDirectory: true))
        try fm.moveItem(at: root, to: folder)
        var report = UnpackReport(folder: folder, files: Self.files(in: folder), layers: state.layers)
        report.stoppedAtLimit = state.stoppedAtLimit
        report.failedInside = failed
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
        try extractAll(parts: [archiveURL], into: dest, depth: depth, state: state)
    }

    /// Extracts one layer into `dest`, then opens whatever archives it contained.
    /// `parts` is one archive, the pieces of a byte-split archive (read in place), or the first volume of a
    /// multi-volume RAR / spanned zip (7-Zip finds the other volumes next to it).
    private func extractAll(parts archiveParts: [URL], into dest: URL, depth: Int, state: RunState) throws {
        state.layers = max(state.layers, depth)
        state.failure.layer = depth
        let first = archiveParts[0]
        let kind = ArchiveKind.detect(first)
        switch kind {
        case .zip where Volumes.isSpannedZip(first):
            try extractWithEngine("zip", parts: archiveParts, into: dest, depth: depth, state: state)
        case .zip:
            do {
                try extractZip(parts: archiveParts, into: dest, depth: depth, state: state)
            } catch let original as UnpackError {
                // Zip methods the built-in reader lacks (Deflate64, BZip2, LZMA, PPMd, XZ, Zstd) and odd layouts.
                guard case .unsupportedMethod = original else {
                    guard case .corrupt = original else { throw original }
                    do { try extractWithEngine("zip", parts: archiveParts, into: dest, depth: depth, state: state) }
                    catch { throw original }   // both readers failed: the built-in reader's message is clearer
                    break
                }
                try extractWithEngine("zip", parts: archiveParts, into: dest, depth: depth, state: state)
            }
        case .engine(let format):
            try extractWithEngine(format, parts: archiveParts, into: dest, depth: depth, state: state,
                                  defaultName: Self.streamName(of: first, kind: kind))
        case .ttImage:
            try extractTTImage(first, into: dest, depth: depth, state: state)
        case .other:
            throw UnpackError.notAnArchive
        }
        try expandNested(dest, producedBy: depth, state: state, onFailure: nil)
    }

    /// The built-in zip reader: every entry of one layer into `dest` (no nested handling here).
    private func extractZip(parts archiveParts: [URL], into dest: URL, depth: Int, state: RunState) throws {
        let fm = FileManager.default
        let zip = try ZipArchive(parts: archiveParts)
        zip.chunkSize = chunkSize
        let password = try choosePassword(for: zip, layer: depth)
        // extract() reports archive bytes read, so measure the layer in compressed bytes.
        let layerTotal = zip.entries.reduce(Int64(0)) { $0 + Int64(clamping: $1.compressedSize) }
        var layerBytes: Int64 = 0
        let tick: (Int) -> Void = { n in
            layerBytes += Int64(n)
            state.total += Int64(n)
            state.progress?(state.total)
            state.onProgress?(UnpackProgress(layer: depth, layerBytes: min(layerBytes, layerTotal), layerTotal: layerTotal,
                                             totalBytes: state.total))
        }
        defer {
            // Encryption headers aren't counted as payload; report the finished layer as complete.
            state.onProgress?(UnpackProgress(layer: depth, layerBytes: layerTotal, layerTotal: layerTotal,
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
            try autoreleasepool { try zip.extract(entry, to: target, password: password, progress: tick) }
        }
    }

    /// The file hidden in a TT-tools PNG, named after the PNG. Its password check needs no decoding.
    private func extractTTImage(_ image: URL, into dest: URL, depth: Int, state: RunState) throws {
        guard let header = TTImage.probe(image) else { throw UnpackError.notAnArchive }
        var password: String? = nil
        if header.isEncrypted {
            let candidates = passwords(forLayer: depth).filter { !$0.isEmpty }
            guard !candidates.isEmpty else { throw UnpackError.passwordRequired }
            guard let match = candidates.first(where: header.accepts) else { throw UnpackError.wrongPassword }
            password = match
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let name = image.deletingPathExtension().lastPathComponent + "." + header.fileExtension
        let start = state.total
        try TTImage.extract(image, header: header, password: password, to: dest.appendingPathComponent(name)) { done, total in
            state.total = start + done
            state.progress?(state.total)
            state.onProgress?(UnpackProgress(layer: depth, layerBytes: done, layerTotal: total, totalBytes: state.total))
        }
    }

    /// 7-Zip for everything else. Tries this layer's passwords in turn (the first one that works is kept);
    /// an archive without encryption never asks, so the first try just works.
    private func extractWithEngine(_ format: String, parts: [URL], into dest: URL, depth: Int, state: RunState,
                                   defaultName: String = "file") throws {
        let fm = FileManager.default
        let candidates = passwords(forLayer: depth).filter { !$0.isEmpty }
        let tries: [String?] = candidates.isEmpty ? [nil] : candidates.map { Optional($0) }
        let start = state.total
        var lastError: Error = UnpackError.wrongPassword
        for pw in tries {
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            state.failure.layer = depth
            do {
                try SevenZipEngine.extract(format: format, parts: parts, into: dest, defaultName: defaultName,
                                           password: pw) { done, total in
                    let d = Int64(clamping: done), t = Int64(clamping: max(total, done))
                    state.total = start + d
                    state.progress?(state.total)
                    state.onProgress?(UnpackProgress(layer: depth, layerBytes: d, layerTotal: t, totalBytes: state.total))
                }
                return
            } catch UnpackError.wrongPassword {
                lastError = UnpackError.wrongPassword
            } catch UnpackError.passwordRequired {
                throw candidates.isEmpty ? UnpackError.passwordRequired : UnpackError.wrongPassword
            }
        }
        try? fm.removeItem(at: dest)
        throw lastError
    }

    /// Opens the archives found among the files under `dir` that layer `depth` produced (a snapshot taken
    /// first, so deeper layers aren't visited twice): byte-split sets, multi-volume sets, single archives.
    /// With `onFailure`, an archive that fails is reported there and kept as a file; without, the error is thrown.
    private func expandNested(_ dir: URL, producedBy depth: Int, state: RunState,
                              onFailure: ((URL, Error) -> Void)?) throws {
        let fm = FileManager.default
        let files = Self.files(in: dir)
        let byFolder = Dictionary(grouping: files) { $0.deletingLastPathComponent().standardizedFileURL }
        var consumed = Set<URL>()

        func open(_ parts: [URL], named archive: URL, removing members: [URL]) throws {
            guard depth < depthLimit else { state.stoppedAtLimit = true; return }
            let kind = ArchiveKind.detect(parts[0])
            let sub = Self.unique(archive.deletingLastPathComponent()
                .appendingPathComponent(Self.folderName(for: archive.lastPathComponent), isDirectory: true))
            do {
                try extractAll(parts: parts, into: sub, depth: depth + 1, state: state)
            } catch {
                try? fm.removeItem(at: sub)
                guard let report = onFailure else { throw error }
                report(archive, error)
                return
            }
            members.forEach { try? fm.removeItem(at: $0) }
            // A single compressed stream ("x.mp4.gz") leaves its file next to where the archive was.
            if kind.isSingleStream {
                let inside = FolderOps.contents(sub)
                if inside.count == 1 {
                    let target = Self.unique(archive.deletingLastPathComponent().appendingPathComponent(inside[0].lastPathComponent))
                    if (try? fm.moveItem(at: inside[0], to: target)) != nil { try? fm.removeItem(at: sub) }
                }
            }
        }

        for (folder, list) in byFolder.sorted(by: { $0.key.path < $1.key.path }) {
            let siblings = Set(list.map { $0.lastPathComponent.lowercased() })
            for set in SplitArchive.sets(in: list) {
                consumed.formUnion(set.parts)
                let archive = folder.appendingPathComponent(set.name)
                guard set.isComplete else {
                    let error = UnpackError.missingPart(SplitArchive.message(for: set) ?? "Split archive “\(set.name)” is incomplete")
                    guard let report = onFailure else { throw error }
                    report(archive, error)
                    continue
                }
                try open(set.parts, named: archive, removing: set.parts)
            }
            for file in list where !consumed.contains(file) {
                guard !Self.zipBasedDocuments.contains(file.pathExtension.lowercased()) else { continue }
                let role = Volumes.role(file, siblings: siblings)
                if role == .later { continue }                   // read through the first volume
                guard ArchiveKind.detect(file).isArchive else { continue }
                let members = role == .first ? Volumes.members(of: file) : [file]
                consumed.formUnion(members)
                try open([file], named: file, removing: members)
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

    /// Folder for an archive's contents: its name without archive extensions ("x.part1.rar" → "x",
    /// "x.tar.gz" → "x", "7月17日.pdf" → "7月17日").
    public static func folderName(for name: String) -> String {
        var n = name
        if let p = Volumes.rarPart(n) { n = p.base }
        let archiveExts: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
                                         "zst", "lzma", "z", "cab", "iso", "arj", "lzh", "wim", "xar", "cpio", "pdf"]
        while true {
            let u = URL(fileURLWithPath: n)
            let e = u.pathExtension.lowercased()
            guard !e.isEmpty, archiveExts.contains(e) || (e.count >= 3 && e.allSatisfy(\.isNumber)) else { break }   // "10.11.zip" → "10.11"
            let stripped = u.deletingPathExtension().lastPathComponent
            guard !stripped.isEmpty else { break }
            n = stripped
        }
        return n.isEmpty ? name : n
    }

    /// Name for the one file inside a compressed stream: "x.tar.gz" → "x.tar", "x.tgz" → "x.tar", "x.mp4.xz" → "x.mp4".
    static func streamName(of url: URL, kind: ArchiveKind) -> String {
        let name = url.lastPathComponent
        let e = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        switch e {
        case "tgz", "tbz", "tbz2", "txz", "tzst": return stem + ".tar"
        case "gz", "bz2", "xz", "zst", "lzma", "z": return stem.isEmpty ? name + ".out" : stem
        default: return kind.isSingleStream ? name + ".out" : stem
        }
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

    /// Renames `files` to "<base>.<ext>" (one file) or "<base> (1).<ext>", "<base> (2).<ext>"… (several),
    /// numbered in natural name order. Each file stays in its own folder. Returns the new URLs in numbering order.
    public static func renameSequentially(_ files: [URL], base: String) throws -> [URL] {
        let fm = FileManager.default
        let clean = base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        guard !files.isEmpty, !clean.isEmpty else { return files }
        let ordered = files.sorted {
            let a = $0.lastPathComponent, b = $1.lastPathComponent
            let c = a.localizedStandardCompare(b)
            return c == .orderedSame ? $0.path < $1.path : c == .orderedAscending
        }
        // Move everything aside first so a new name can never collide with an old one.
        var temps: [(original: URL, temp: URL)] = []
        for f in ordered {
            let t = f.deletingLastPathComponent()
                .appendingPathComponent(".renaming-\(UUID().uuidString)" + (f.pathExtension.isEmpty ? "" : ".\(f.pathExtension)"))
            do {
                try fm.moveItem(at: f, to: t)
            } catch {
                for done in temps { try? fm.moveItem(at: done.temp, to: done.original) }
                throw error
            }
            temps.append((f, t))
        }
        var result: [URL] = []
        for (i, item) in temps.enumerated() {
            let name = ordered.count == 1 ? clean : "\(clean) (\(i + 1))"
            let ext = item.temp.pathExtension
            let target = unique(item.temp.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)"))
            do {
                try fm.moveItem(at: item.temp, to: target)
            } catch {
                for rest in temps[i...] { try? fm.moveItem(at: rest.temp, to: unique(rest.original)) }
                throw error
            }
            result.append(target)
        }
        return result
    }

    public static func files(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
