import Foundation
import SwiftUI
import UIKit
import UnpackCore

struct FileItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let fileCount: Int
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct RunSummary {
    var batchFolder: URL?
    var succeeded: [UnpackReport] = []
    var failed: [(name: String, message: String)] = []
    var exportMessage: String?
    var outputFiles: [URL] { succeeded.flatMap(\.files) }

    var text: String {
        if succeeded.isEmpty && failed.isEmpty { return "Nothing to unpack." }
        var s = "Unpacked \(succeeded.count) file\(succeeded.count == 1 ? "" : "s")"
        if let b = batchFolder, !succeeded.isEmpty { s += " into “\(b.lastPathComponent)”" }
        s += "."
        if !failed.isEmpty { s += " \(failed.count) failed: " + failed.map { "\($0.name) (\($0.message))" }.joined(separator: "; ") + "." }
        if let e = exportMessage { s += " " + e }
        return s
    }
}

enum Settings {
    static let passwordsKey = "passwords"
    static let deleteOriginalsKey = "deleteOriginals"

    static var passwords: [String] {
        (UserDefaults.standard.string(forKey: passwordsKey) ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static var deleteOriginals: Bool { UserDefaults.standard.bool(forKey: deleteOriginalsKey) }
}

/// A folder outside the app (e.g. the Unzip app's folder in Files) that the user picked once.
/// Stored as a bookmark so access survives app restarts.
enum ExportDestination {
    private static let bookmarkKey = "exportBookmark"
    private static let nameKey = "exportName"

    static var name: String? { UserDefaults.standard.string(forKey: nameKey) }

    /// `url` comes straight from the folder picker (security-scoped).
    static func save(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Make sure we can actually write there before remembering it.
        let probe = url.appendingPathComponent(".unpacker-write-test-\(UUID().uuidString)")
        try Data().write(to: probe)
        try? FileManager.default.removeItem(at: probe)
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? save(url) }
        return url
    }

    /// Screenshot mode only: shows a destination name without a real bookmark.
    static func setDemoName(_ name: String) { UserDefaults.standard.set(name, forKey: nameKey) }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }

    /// Copies `folder` into the destination (as a new sub-folder). Blocking; call off the main thread.
    static func copy(_ folder: URL, to destination: URL) throws -> URL {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let target = Unpacker.unique(destination.appendingPathComponent(folder.lastPathComponent, isDirectory: true))
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordError) { url in
            do { try FileManager.default.copyItem(at: folder, to: url) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
        return target
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
    @Published private(set) var batches: [FileItem] = []
    @Published private(set) var originalsCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""
    @Published private(set) var progressFraction = 0.0
    @Published private(set) var exportName: String? = ExportDestination.name
    @Published var errors: [String: String] = [:]
    @Published var lastSummary: String?
    @Published var notice: String?

    let fm = FileManager.default
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var pendingDir: URL { docs.appendingPathComponent("To Unpack", isDirectory: true) }
    var originalsDir: URL { docs.appendingPathComponent("Originals", isDirectory: true) }
    /// Where iOS drops files sent with "Open in…" / "Copy to…". Read/delete only.
    var systemInbox: URL { docs.appendingPathComponent("Inbox", isDirectory: true) }

    private init() { prepare() }

    func prepare() {
        for d in [pendingDir, originalsDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        sweepSystemInbox()
        refresh()
    }

    func refresh() {
        pending = list(pendingDir)
        batches = Array(list(docs).filter { $0.isDirectory && $0.name.hasPrefix(Self.batchPrefix) }.reversed())
        originalsCount = (try? fm.contentsOfDirectory(atPath: originalsDir.path).filter { !$0.hasPrefix(".") }.count) ?? 0
        exportName = ExportDestination.name
        let names = Set(pending.map(\.name))
        errors = errors.filter { names.contains($0.key) }
    }

    private func list(_ dir: URL) -> [FileItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let files = Unpacker.files(in: url)
                let size = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                return FileItem(url: url, size: size, fileCount: files.count, isDirectory: true)
            }
            return FileItem(url: url, size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                            fileCount: 1, isDirectory: false)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Import

    private func sweepSystemInbox() {
        let items = (try? fm.contentsOfDirectory(at: systemInbox, includingPropertiesForKeys: nil)) ?? []
        for url in items where !url.lastPathComponent.hasPrefix(".") {
            try? fm.moveItem(at: url, to: Unpacker.unique(pendingDir.appendingPathComponent(url.lastPathComponent)))
        }
    }

    /// Handles a file handed over by another app (Open in / Share) or picked in the Files importer.
    func importFile(_ url: URL) {
        if url.standardizedFileURL.path.hasPrefix(systemInbox.standardizedFileURL.path) {
            sweepSystemInbox()
        } else {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = Unpacker.unique(pendingDir.appendingPathComponent(url.lastPathComponent))
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                // Some providers need a coordinated read.
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { readURL in
                    try? self.fm.copyItem(at: readURL, to: dest)
                }
            }
        }
        refresh()
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
            notice = "Finished batches will be copied to “\(url.lastPathComponent)”."
        } catch {
            notice = "Can't write to “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
        refresh()
    }

    func clearExportDestination() {
        ExportDestination.clear()
        refresh()
    }

    /// Copies a batch folder to the export destination. Returns a message for the user.
    @discardableResult
    func export(_ folder: URL) async -> String {
        guard let dest = ExportDestination.resolve() else {
            return "No export folder set."
        }
        let previous = progressText
        progressText = "Copying “\(folder.lastPathComponent)” to “\(dest.lastPathComponent)”…"
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
            Result { try ExportDestination.copy(folder, to: dest) }
        }.value
        progressText = previous
        switch result {
        case .success(let target):
            return "Copied to “\(dest.lastPathComponent)/\(target.lastPathComponent)”."
        case .failure(let error):
            return "Export to “\(dest.lastPathComponent)” failed: \(error.localizedDescription) The batch is still in the app."
        }
    }

    /// Screenshot mode only: a frozen mid-batch state.
    func showDemoProgress() {
        isRunning = true
        progressFraction = 0.55
        progressText = "3 of 5: 7月19日舞蹈.pdf · 31.2 MB"
    }

    // MARK: Delete

    func delete(_ item: FileItem) {
        try? fm.removeItem(at: item.url)
        refresh()
    }

    func clearOriginals() {
        for url in (try? fm.contentsOfDirectory(at: originalsDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        refresh()
    }

    // MARK: Unpack

    private func newBatchFolder() throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let url = Unpacker.unique(docs.appendingPathComponent(Self.batchPrefix + f.string(from: Date()), isDirectory: true))
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func unpackAll() async -> RunSummary {
        var summary = RunSummary()
        guard !isRunning else { return summary }
        prepare()
        let queue = pending.filter { !$0.isDirectory }
        guard !queue.isEmpty else {
            lastSummary = summary.text
            return summary
        }

        isRunning = true
        let background = BackgroundTask(name: "Unpack")
        defer {
            background.end()
            isRunning = false
            progressText = ""
            progressFraction = 0
            refresh()
        }

        let batch: URL
        do {
            batch = try newBatchFolder()
        } catch {
            lastSummary = "Couldn't create the batch folder: \(error.localizedDescription)"
            return summary
        }
        summary.batchFolder = batch

        let passwords = Settings.passwords
        let deleteOriginals = Settings.deleteOriginals
        let originalsDir = originalsDir

        for (i, item) in queue.enumerated() {
            let label = "\(i + 1) of \(queue.count): \(item.name)"
            progressText = label
            progressFraction = Double(i) / Double(queue.count)
            let total = max(item.size, 1), count = Double(queue.count)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<UnpackReport, Error> in
                var lastShown: Int64 = 0
                return Result {
                    try Unpacker(passwords: passwords).unpack(item.url, into: batch) { bytes in
                        guard bytes - lastShown > 4 << 20 else { return }
                        lastShown = bytes
                        // Two layers ≈ twice the file size in bytes processed.
                        let f = min(Double(bytes) / Double(total * 2), 1)
                        Task { @MainActor in
                            Library.shared.progressFraction = (Double(i) + f) / count
                            Library.shared.progressText = "\(label) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                        }
                    }
                }
            }.value

            switch result {
            case .success(let report):
                summary.succeeded.append(report)
                errors[item.name] = nil
                if deleteOriginals {
                    try? fm.removeItem(at: item.url)
                } else {
                    try? fm.moveItem(at: item.url, to: Unpacker.unique(originalsDir.appendingPathComponent(item.name)))
                }
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                summary.failed.append((item.name, message))
                errors[item.name] = message
            }
            refresh()
        }

        if summary.succeeded.isEmpty {
            try? fm.removeItem(at: batch)
            summary.batchFolder = nil
        } else if ExportDestination.resolve() != nil {
            progressFraction = 1
            summary.exportMessage = await export(batch)
        }
        lastSummary = summary.text
        return summary
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
