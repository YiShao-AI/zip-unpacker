import Foundation
import SwiftUI
import UIKit
import UnpackCore

struct RunSummary {
    var batchFolder: URL?
    var succeeded: [UnpackReport] = []
    var failed: [(name: String, message: String)] = []
    var exportMessage: String?
    var outputFiles: [URL] { succeeded.flatMap(\.files) }

    var text: String {
        if succeeded.isEmpty && failed.isEmpty { return "Nothing to unpack." }
        var s = "Unpacked \(plural(succeeded.count, "file"))"
        if let b = batchFolder, !succeeded.isEmpty { s += " into “\(b.lastPathComponent)”" }
        s += "."
        if !failed.isEmpty { s += " \(failed.count) failed: " + failed.map { "\($0.name) (\($0.message))" }.joined(separator: "; ") + "." }
        if let e = exportMessage { s += " " + e }
        return s
    }
}

/// Everything lives in the app's Documents, which the Files app shows as On My iPhone › Unpacker:
///   To Unpack/                     files waiting
///   Batch 2026-11-03 14-30/<file>/ results, one folder per batch, one sub-folder per original
///   Originals/                     originals after a successful run (unless "delete originals" is on)
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    static let batchPrefix = "Batch "

    @Published private(set) var pending: [FileItem] = []
    @Published private(set) var batches: [Batch] = []
    @Published private(set) var favorites: [URL] = [] { didSet { favoritePaths = Set(favorites.map(\.standardizedFileURL.path)) } }
    @Published private(set) var originalsCount = 0
    @Published private(set) var exportName: String? = ExportDestination.name
    @Published private(set) var copying: Set<URL> = []
    @Published var run: BatchRun?
    @Published var errors: [String: String] = [:]
    @Published var toast: String?
    @Published var notice: String?

    @Published var defaultFormat = Prefs.initialFormat { didSet { Prefs.save(defaultFormat, Prefs.formatKey) } }
    @Published var lastFormat = Prefs.load(UnpackFormat.self, Prefs.lastFormatKey) { didSet { Prefs.save(lastFormat, Prefs.lastFormatKey) } }
    @Published var useGlobalFormat = Prefs.bool(Prefs.globalKey, default: true) { didSet { Prefs.defaults.set(useGlobalFormat, forKey: Prefs.globalKey) } }
    @Published var quickPicks = Prefs.load([QuickPick].self, Prefs.quickPicksKey) ?? QuickPick.builtIn { didSet { Prefs.save(quickPicks, Prefs.quickPicksKey) } }
    @Published var autoCopy = Prefs.bool(Prefs.autoCopyKey, default: true) { didSet { Prefs.defaults.set(autoCopy, forKey: Prefs.autoCopyKey) } }
    @Published var renameVideos = Prefs.bool(Prefs.renameVideosKey, default: true) { didSet { Prefs.defaults.set(renameVideos, forKey: Prefs.renameVideosKey) } }
    @Published var deleteOriginals = Prefs.defaults.bool(forKey: Prefs.deleteOriginalsKey) { didSet { Prefs.defaults.set(deleteOriginals, forKey: Prefs.deleteOriginalsKey) } }

    let fm = FileManager.default
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var pendingDir: URL { docs.appendingPathComponent("To Unpack", isDirectory: true) }
    var originalsDir: URL { docs.appendingPathComponent("Originals", isDirectory: true) }
    /// Where iOS drops files sent with "Open in…" / "Copy to…". Read/delete only.
    var systemInbox: URL { docs.appendingPathComponent("Inbox", isDirectory: true) }

    var isRunning: Bool { run.map { $0.phase != .done } ?? false }

    private var favoritePaths: Set<String> = []
    private var toastTask: Task<Void, Never>?

    private init() { prepare() }

    func prepare() {
        for d in [pendingDir, originalsDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        if joining.isEmpty { try? fm.removeItem(at: pendingDir.appendingPathComponent(".joining")) }
        if !isRunning { clearLeftovers() }
        sweepSystemInbox()
        refresh()
    }

    /// An unpack that ends normally (done or failed) deletes its work folder. One that was killed (crash,
    /// out of memory, force quit) leaves it in tmp/ as invisible files, so they are cleared on the next launch.
    private func clearLeftovers() {
        let tmp = fm.temporaryDirectory
        let leftovers = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("unpack-") }
        guard !leftovers.isEmpty else { return }
        let bytes = leftovers.flatMap { Unpacker.files(in: $0) }
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        leftovers.forEach { try? fm.removeItem(at: $0) }
        if bytes > 50_000_000 {
            say("Freed \(sizeText(bytes)) left over from an unpack that didn't finish.")
        }
    }

    func refresh() {
        let items = list(pendingDir)
        let splitSets = SplitArchive.sets(in: items.filter { !$0.isDirectory }.map(\.url))
        pending = items.filter { !joining.contains($0.name) }
        let folders = list(docs).filter { $0.isDirectory && $0.name.hasPrefix(Self.batchPrefix) }
        favorites = folders.flatMap(\.favorites)
        batches = folders
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            .map { item in
                let originals = ((try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? []).count
                return Batch(url: item.url, size: item.size, fileCount: item.fileCount, originals: originals,
                             info: BatchInfo.load(item.url))
            }
        originalsCount = (try? fm.contentsOfDirectory(atPath: originalsDir.path).filter { !$0.hasPrefix(".") }.count) ?? 0
        exportName = ExportDestination.name
        let names = Set(pending.map(\.name))
        errors = errors.filter { names.contains($0.key) }
        let siblings = Set(items.map { $0.name.lowercased() })
        for item in items where !item.isDirectory && Volumes.role(item.url, siblings: siblings) == .later {
            errors[item.name] = "Later part of a multi-part archive: unpacked together with its first part."
        }
        for set in splitSets {
            if set.isComplete {
                joinParts(set)
            } else if let message = SplitArchive.message(for: set) {
                for part in set.parts { errors[part.lastPathComponent] = message }
            }
        }
    }

    // MARK: Split zips (name.zip.001, .002, …)

    /// Part names being joined right now; hidden from the Inbox until the joined zip appears.
    private var joining: Set<String> = []

    /// Joins a complete set of parts into one zip in To Unpack, off the main thread, then removes the parts.
    private func joinParts(_ set: SplitArchive.PartSet) {
        let names = set.parts.map(\.lastPathComponent)
        guard joining.isDisjoint(with: names) else { return }
        joining.formUnion(names)
        pending.removeAll { names.contains($0.name) }
        say("Joining \(plural(set.parts.count, "part")) of “\(set.name)”…")
        let work = pendingDir.appendingPathComponent(".joining", isDirectory: true)
        let parts = set.parts
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    let tmp = Unpacker.unique(work.appendingPathComponent(set.name))
                    try SplitArchive.join(parts, to: tmp)
                    return tmp
                }
            }.value
            joining.subtract(names)
            switch result {
            case .success(let tmp):
                do {
                    try fm.moveItem(at: tmp, to: Unpacker.unique(pendingDir.appendingPathComponent(set.name)))
                    for part in parts { try? fm.removeItem(at: part) }
                    say("Joined \(plural(parts.count, "part")) into “\(set.name)”.")
                } catch {
                    try? fm.removeItem(at: tmp)
                    notice = "Couldn't join “\(set.name)”: \(error.localizedDescription)"
                }
            case .failure(let error):
                notice = "Couldn't join “\(set.name)”: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    private func list(_ dir: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let added = v?.addedToDirectoryDate ?? v?.creationDate
            if v?.isDirectory == true {
                let files = Unpacker.files(in: url)
                let size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                return FileItem(url: url, size: size, fileCount: files.count, isDirectory: true, added: added,
                                favorites: files.filter(Favorites.isFavorite))
            }
            return FileItem(url: url, size: Int64(v?.fileSize ?? 0), fileCount: 1, isDirectory: false, added: added)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func say(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Import

    private func sweepSystemInbox() {
        let items = (try? fm.contentsOfDirectory(at: systemInbox, includingPropertiesForKeys: nil)) ?? []
        for url in items where !url.lastPathComponent.hasPrefix(".") {
            try? fm.moveItem(at: url, to: Unpacker.unique(pendingDir.appendingPathComponent(url.lastPathComponent)))
        }
    }

    /// Copies one file into To Unpack. `url` may be security-scoped (Files picker) or a provider file.
    @discardableResult
    private func copyIn(_ url: URL) -> Bool {
        let dest = Unpacker.unique(pendingDir.appendingPathComponent(url.lastPathComponent))
        if (try? fm.copyItem(at: url, to: dest)) != nil { return true }
        // Some providers need a coordinated read.
        var ok = false
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
            ok = (try? self.fm.copyItem(at: readURL, to: dest)) != nil
        }
        return ok
    }

    /// Handles a file or folder handed over by another app (Open in / Share) or picked in the Files importer.
    /// Returns how many files were added (a folder counts each file inside it).
    @discardableResult
    func importFile(_ url: URL) -> Int {
        let before = Set(fileNames(pendingDir))
        if url.standardizedFileURL.path.hasPrefix(systemInbox.standardizedFileURL.path) {
            sweepSystemInbox()
        } else {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            copyIn(url)
        }
        refresh()
        return Set(fileNames(pendingDir)).subtracting(before).count
    }

    private func fileNames(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    func importFiles(_ urls: [URL]) {
        let added = urls.reduce(0) { $0 + importFile($1) }
        say("Added \(plural(added, "file")) from Files.")
    }

    /// Adds a picked folder as one Inbox item; unpacking it keeps its structure.
    func importFolder(_ folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let count = Unpacker.files(in: folder).count
        guard count > 0 else { notice = "No files found in “\(folder.lastPathComponent)”."; return }
        guard copyIn(folder) else { notice = "Couldn't add “\(folder.lastPathComponent)”."; return }
        refresh()
        say("Added folder “\(folder.lastPathComponent)” (\(plural(count, "file"))).")
    }

    /// Used by the Shortcuts action, which hands over file data instead of a URL.
    func importData(_ data: Data, named name: String) throws {
        let safe = name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "_")
        try data.write(to: Unpacker.unique(pendingDir.appendingPathComponent(safe)))
        refresh()
    }

    // MARK: Export destination

    func setExportDestination(_ url: URL) {
        do {
            try ExportDestination.save(url)
            say("Finished batches will be copied to “\(url.lastPathComponent)”.")
        } catch {
            notice = "Can't write to “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
        refresh()
    }

    func clearExportDestination() {
        ExportDestination.clear()
        refresh()
        say("Export turned off. Batches stay in Unpacker.")
    }

    /// Copies a batch folder to the export destination and remembers it in the batch's info.
    @discardableResult
    func export(_ folder: URL, quiet: Bool = false) async -> Result<String, Error>? {
        guard let dest = ExportDestination.resolve() else {
            notice = "Choose an export folder in Settings first."
            return nil
        }
        copying.insert(folder)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result { try ExportDestination.copy(folder, to: dest) }
        }.value
        copying.remove(folder)
        switch result {
        case .success(let target):
            var info = BatchInfo.load(folder)
            info.exportedTo = dest.lastPathComponent
            info.exportedAt = Date()
            info.save(folder)
            refresh()
            let text = "\(dest.lastPathComponent) › \(target.lastPathComponent)"
            if !quiet { say("Copied “\(folder.lastPathComponent)” to “\(dest.lastPathComponent)”.") }
            return .success(text)
        case .failure(let error):
            if !quiet { notice = "Copy to “\(dest.lastPathComponent)” failed: \(error.localizedDescription) The batch is still in Unpacker." }
            return .failure(error)
        }
    }

    // MARK: Favorites

    func isFavorite(_ url: URL) -> Bool { favoritePaths.contains(url.standardizedFileURL.path) }

    func toggleFavorite(_ url: URL) {
        let on = !isFavorite(url)
        do {
            try Favorites.set(on, url)
        } catch {
            notice = "Couldn't update Favorites: \(error.localizedDescription)"
            return
        }
        let path = url.standardizedFileURL.path
        if on { favorites.append(url) } else { favorites.removeAll { $0.standardizedFileURL.path == path } }
    }

    // MARK: Delete

    func delete(_ url: URL) {
        try? fm.removeItem(at: url)
        refresh()
    }

    /// Deletes a file or an original's folder inside a finished batch. A folder left empty goes too.
    func delete(_ url: URL, inBatch batch: URL) {
        let parent = url.deletingLastPathComponent()
        do {
            try fm.removeItem(at: url)
        } catch {
            notice = "Couldn't delete “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        let batchPath = batch.standardizedFileURL.path
        var dir = parent
        while dir.standardizedFileURL.path != batchPath, dir.standardizedFileURL.path.hasPrefix(batchPath + "/"),
              ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).isEmpty {
            try? fm.removeItem(at: dir)
            dir = dir.deletingLastPathComponent()
        }
        refresh()
        say("Deleted “\(url.lastPathComponent)”.")
    }

    // MARK: Organising batches

    enum Destination: Equatable {
        /// A batch: items keep their original's folder (a video from folder F goes into F there).
        case batch(URL)
        /// A folder inside a batch: items go straight in.
        case folder(URL)
    }

    @Published private(set) var busy: String?

    /// Copy / Cut, then Paste somewhere else.
    struct Clipboard: Equatable {
        var items: [URL]
        var cut: Bool
        var source: URL
        var text: String { "\(plural(items.count, "item")) \(cut ? "cut" : "copied")" }
    }
    @Published var clipboard: Clipboard?

    func copyToClipboard(_ items: [URL], from batch: URL, cut: Bool) {
        guard !items.isEmpty else { return }
        clipboard = Clipboard(items: items, cut: cut, source: batch)
        say("\(cut ? "Cut" : "Copied") \(plural(items.count, "item")). Open a batch or folder and tap Paste.")
    }

    func paste(to destination: Destination) async {
        guard let clip = clipboard else { return }
        let existing = clip.items.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            clipboard = nil
            notice = "The items on the clipboard aren't there any more."
            return
        }
        await transfer(existing, from: clip.source, to: destination, move: clip.cut)
        if clip.cut { clipboard = nil }
    }

    /// "Batch July dances" — the "Batch " prefix is what makes a folder show up in Results.
    func batchFolderName(_ name: String) -> String? {
        guard let n = FolderOps.cleanName(name) else { return nil }
        return n.hasPrefix(Self.batchPrefix) ? n : Self.batchPrefix + n
    }

    @discardableResult
    func createBatch(named name: String) -> URL? {
        guard let n = batchFolderName(name) else { notice = "That name can't be used."; return nil }
        do {
            let url = try FolderOps.createFolder(named: n, in: docs)
            refresh()
            return url
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func createFolder(named name: String, in batch: URL) {
        do {
            let url = try FolderOps.createFolder(named: name, in: batch)
            refresh()
            say("Made the folder “\(url.lastPathComponent)”.")
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @discardableResult
    func rename(_ item: URL, to name: String) -> URL? {
        let isBatch = item.deletingLastPathComponent().standardizedFileURL.path == docs.standardizedFileURL.path
        let newName = isBatch ? batchFolderName(name) : FolderOps.cleanName(name)
        guard let newName else { notice = "That name can't be used."; return nil }
        do {
            let url = try FolderOps.rename(item, to: newName)
            refresh()
            return url
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    func delete(_ urls: [URL], inBatch batch: URL) {
        for url in urls { try? fm.removeItem(at: url) }
        FolderOps.removeEmptyFolders(in: batch)
        refresh()
        say("Deleted \(plural(urls.count, "item")).")
    }

    func deleteBatches(_ urls: [URL]) {
        for url in urls { try? fm.removeItem(at: url) }
        refresh()
        say("Deleted \(plural(urls.count, "batch")).")
    }

    /// Moves or copies items picked inside `batch` to another place. Big copies run off the main thread.
    func transfer(_ items: [URL], from batch: URL, to destination: Destination, move: Bool) async {
        let batchPath = batch.standardizedFileURL.path
        let plan: [(URL, URL)] = items.map { item in
            switch destination {
            case .folder(let f):
                return (item, f)
            case .batch(let b):
                // A file inside an original's folder goes into the same-named folder in the target batch.
                let parent = item.deletingLastPathComponent()
                if parent.standardizedFileURL.path != batchPath { return (item, b.appendingPathComponent(parent.lastPathComponent)) }
                return (item, b)
            }
        }
        busy = move ? "Moving…" : "Copying…"
        let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
            var failed: [String] = []
            for (item, target) in plan {
                do { try FolderOps.transfer(item, into: target, move: move) } catch {
                    failed.append("\(item.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            }
            if move { FolderOps.removeEmptyFolders(in: batch) }
            return failed
        }.value
        busy = nil
        refresh()
        if failures.isEmpty {
            say("\(move ? "Moved" : "Copied") \(plural(items.count, "item")).")
        } else {
            notice = "Some items couldn't be \(move ? "moved" : "copied"):\n" + failures.joined(separator: "\n")
        }
    }

    /// Combines several batches into a new one. With `keepOld` the old batches stay as they are.
    func merge(_ batches: [URL], named name: String, keepOld: Bool) async -> URL? {
        guard let n = batchFolderName(name) else { notice = "That name can't be used."; return nil }
        let target = Unpacker.unique(docs.appendingPathComponent(n, isDirectory: true))
        let formats = Set(batches.compactMap { BatchInfo.load($0).format })
        busy = keepOld ? "Copying…" : "Merging…"
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result { try FolderOps.merge(batches, into: target, move: !keepOld) }
        }.value
        busy = nil
        BatchInfo(format: formats.count == 1 ? formats.first : "Merged from \(plural(batches.count, "batch"))").save(target)
        refresh()
        switch result {
        case .success(let url):
            say("Merged \(plural(batches.count, "batch")) into “\(url.lastPathComponent)”.")
            return url
        case .failure(let error):
            notice = "Merge stopped: \(error.localizedDescription) Nothing was deleted that wasn't copied."
            return nil
        }
    }

    func clearOriginals() {
        for url in (try? fm.contentsOfDirectory(at: originalsDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        refresh()
        say("Originals folder emptied.")
    }

    /// For batches made before renaming existed: names the videos in each original's folder after that folder.
    func renameVideos(inBatch batch: URL) {
        let folders = ((try? fm.contentsOfDirectory(at: batch, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var count = 0, failed = 0
        for folder in folders {
            let videos = Unpacker.files(in: folder).filter(Media.isVideo)
            guard !videos.isEmpty else { continue }
            if (try? Unpacker.renameSequentially(videos, base: folder.lastPathComponent)) != nil { count += videos.count } else { failed += 1 }
        }
        refresh()
        if failed > 0 {
            notice = "Some videos couldn't be renamed. The rest were."
        } else {
            say(count == 0 ? "No videos to rename." : "Renamed \(plural(count, "video")) after their folders.")
        }
    }

    // MARK: Quick picks

    func saveQuickPick(_ format: UnpackFormat, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        quickPicks.append(QuickPick(name: trimmed.isEmpty ? "Saved \(quickPicks.count + 1)" : trimmed, format: format))
        say("Saved as a quick pick: \(format.summary).")
    }

    func deleteQuickPick(_ pick: QuickPick) {
        quickPicks.removeAll { $0.id == pick.id }
    }

    // MARK: Unpack

    func nextBatchName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return Unpacker.unique(docs.appendingPathComponent(Self.batchPrefix + f.string(from: Date()), isDirectory: true))
            .lastPathComponent
    }

    func stopAfterCurrent() {
        guard run?.phase == .running else { return }
        run?.stopRequested = true
    }

    /// Clears a finished run so the Inbox shows again.
    func dismissRun() {
        guard !isRunning else { return }
        run = nil
    }

    /// Used by Shortcuts: everything waiting, with the default format.
    @discardableResult
    func unpackAll() async -> RunSummary {
        prepare()
        return await unpack(pending, format: defaultFormat)
    }

    @discardableResult
    func unpack(_ chosen: [FileItem], format: UnpackFormat) async -> RunSummary {
        var summary = RunSummary()
        guard !isRunning, !chosen.isEmpty else { return summary }
        // Later volumes of a multi-part RAR / spanned zip are read through the first volume.
        let siblings = Set(fileNames(pendingDir).map { $0.lowercased() })
        let files = chosen.filter { $0.isDirectory || Volumes.role($0.url, siblings: siblings) != .later }
        guard !files.isEmpty else {
            notice = "These are later parts of a multi-part archive. Unpack its first part (…part1.rar, .rar or .zip) — the other parts are read with it."
            return summary
        }
        lastFormat = format

        let batch = docs.appendingPathComponent(nextBatchName(), isDirectory: true)
        do {
            try fm.createDirectory(at: batch, withIntermediateDirectories: true)
        } catch {
            notice = "Couldn't create the batch folder: \(error.localizedDescription)"
            return summary
        }
        summary.batchFolder = batch

        let destName = autoCopy ? ExportDestination.name : nil
        run = BatchRun(batchName: batch.lastPathComponent, batchURL: batch, format: format,
                       items: files.map { RunItem(url: $0.url, name: $0.name) },
                       export: destName.map { .waiting($0) } ?? .off)

        let background = BackgroundTask(name: "Unpack")
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            background.end()
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let unpacker = format.unpacker
        let deleteOriginals = deleteOriginals
        let originalsDir = originalsDir

        for (i, item) in files.enumerated() {
            if run?.stopRequested == true {
                for j in i..<files.count { run?.items[j].status = .notStarted }
                break
            }
            run?.items[i].status = .unpacking(layer: 1, fraction: 0)
            let failure = Unpacker.FailureInfo()
            let result = await Task.detached(priority: .userInitiated) { () -> Result<UnpackReport, Error> in
                var lastShown = Date.distantPast
                return Result {
                    try unpacker.unpack(item.url, into: batch, failure: failure, onProgress: { p in
                        let now = Date()
                        guard now.timeIntervalSince(lastShown) > 0.15 || p.layerFraction >= 1 else { return }
                        lastShown = now
                        let layer = p.layer, fraction = p.layerFraction
                        Task { @MainActor in
                            let lib = Library.shared
                            // Show the deepest layer reached; the outer layer finishing afterwards isn't news.
                            guard let run = lib.run, run.items.indices.contains(i),
                                  case .unpacking(let shown, _) = run.items[i].status, layer >= shown else { return }
                            lib.run?.items[i].status = .unpacking(layer: layer, fraction: fraction)
                        }
                    })
                }
            }.value

            switch result {
            case .success(var report):
                if renameVideos && !item.isDirectory {
                    let videos = report.files.filter(Media.isVideo)
                    let base = Unpacker.folderName(for: item.name)
                    if !videos.isEmpty, let renamed = try? Unpacker.renameSequentially(videos, base: base) {
                        report.files = report.files.filter { !Media.isVideo($0) } + renamed
                    }
                }
                summary.succeeded.append(report)
                errors[item.name] = nil
                run?.items[i].status = .done(doneText(report, format: format))
                let volumes = !item.isDirectory && Volumes.role(item.url, siblings: siblings) == .first
                    ? Volumes.members(of: item.url) : [item.url]
                for original in volumes {
                    if deleteOriginals {
                        try? fm.removeItem(at: original)
                    } else {
                        try? fm.moveItem(at: original, to: Unpacker.unique(originalsDir.appendingPathComponent(original.lastPathComponent)))
                    }
                }
            case .failure(let error):
                let message = failureText(error, layer: failure.layer, format: format)
                summary.failed.append((item.name, message))
                errors[item.name] = message
                run?.items[i].status = .failed(message)
            }
            refresh()
        }

        if summary.succeeded.isEmpty {
            try? fm.removeItem(at: batch)
            summary.batchFolder = nil
            run?.batchURL = nil
            if case .waiting = run?.export { run?.export = .notCopied }
        } else {
            BatchInfo(format: format.summary).save(batch)
            if let name = destName, ExportDestination.resolve() != nil {
                run?.phase = .exporting
                run?.export = .copying(name)
                let outcome = await export(batch, quiet: true)
                switch outcome {
                case .some(.success(let target)):
                    run?.export = .copied(target)
                    summary.exportMessage = "Copied to “\(target)”."
                case .some(.failure(let error)):
                    run?.export = .failed(error.localizedDescription)
                    summary.exportMessage = "Copy to “\(name)” failed: \(error.localizedDescription)"
                case .none:
                    run?.export = .notCopied
                }
            }
        }
        refresh()
        run?.result = batches.first { $0.url.standardizedFileURL == batch.standardizedFileURL }
        run?.phase = .done
        return summary
    }

    private func doneText(_ r: UnpackReport, format: UnpackFormat) -> String {
        let videos = r.files.filter(Media.isVideo).count
        let what = videos == r.files.count && videos > 0 ? plural(videos, "video") : plural(r.files.count, "file")
        if !r.failedInside.isEmpty {
            return "Done · \(what) · \(plural(r.failedInside.count, "zip")) inside couldn't be opened, kept as files: "
                + r.failedInside.prefix(3).joined(separator: "; ") + (r.failedInside.count > 3 ? "…" : "")
        }
        if r.stoppedAtLimit { return "Done · \(plural(r.layers, "layer")) removed · inner zip kept as a file" }
        if let n = format.layers, r.layers < n { return "Done · only \(plural(r.layers, "layer")) found · \(what)" }
        return "Done · \(plural(r.layers, "layer")) removed · \(what)"
    }

    private func failureText(_ error: Error, layer: Int, format: UnpackFormat) -> String {
        switch error as? UnpackError {
        case .wrongPassword?:
            return "Failed on layer \(layer): wrong password (tried \(format.passwords(forLayer: layer).joined(separator: ", ")))"
        case .passwordRequired?:
            return "Failed on layer \(layer): needs a password, none set"
        case .notAnArchive? where layer == 1:
            return "Failed: not an archive Unpacker can read"
        default:
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return layer > 1 ? "Failed on layer \(layer): \(message)" : "Failed: \(message)"
        }
    }

    /// Screenshot mode only: a frozen mid-batch state.
    func showDemoRun() {
        var items = pending.map { RunItem(url: $0.url, name: $0.name) }
        let states: [RunItem.Status] = [.done("Done · 2 layers removed · 3 videos"), .done("Done · 2 layers removed · 3 videos"),
                                        .unpacking(layer: 2, fraction: 0.62)]
        for (i, s) in states.enumerated() where i < items.count { items[i].status = s }
        run = BatchRun(batchName: nextBatchName(), batchURL: nil, format: defaultFormat, items: items,
                       export: exportName.map { .waiting($0) } ?? .off)
    }
}

/// Asks iOS for extra time if the app is sent to the background mid-run.
@MainActor
final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        // iOS calls the expiration handler on the main thread and expects end() before it returns.
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
