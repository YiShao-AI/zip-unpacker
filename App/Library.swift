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
    @Published var deleteOriginals = Prefs.defaults.bool(forKey: Prefs.deleteOriginalsKey) { didSet { Prefs.defaults.set(deleteOriginals, forKey: Prefs.deleteOriginalsKey) } }

    let fm = FileManager.default
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var pendingDir: URL { docs.appendingPathComponent("To Unpack", isDirectory: true) }
    var originalsDir: URL { docs.appendingPathComponent("Originals", isDirectory: true) }
    /// Where iOS drops files sent with "Open in…" / "Copy to…". Read/delete only.
    var systemInbox: URL { docs.appendingPathComponent("Inbox", isDirectory: true) }

    var isRunning: Bool { run.map { $0.phase != .done } ?? false }

    private var toastTask: Task<Void, Never>?

    private init() { prepare() }

    func prepare() {
        for d in [pendingDir, originalsDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        sweepSystemInbox()
        refresh()
    }

    func refresh() {
        pending = list(pendingDir).filter { !$0.isDirectory }
        batches = list(docs)
            .filter { $0.isDirectory && $0.name.hasPrefix(Self.batchPrefix) }
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
                return FileItem(url: url, size: size, fileCount: files.count, isDirectory: true, added: added)
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

    /// Handles a file handed over by another app (Open in / Share) or picked in the Files importer.
    func importFile(_ url: URL) {
        if url.standardizedFileURL.path.hasPrefix(systemInbox.standardizedFileURL.path) {
            sweepSystemInbox()
        } else {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            copyIn(url)
        }
        refresh()
    }

    func importFiles(_ urls: [URL]) {
        urls.forEach(importFile)
        say("Added \(plural(urls.count, "file")) from Files.")
    }

    /// Adds every file inside a picked folder (and its sub-folders).
    func importFolder(_ folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var added = 0
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .withoutChanges, error: &coordError) { readURL in
            for file in Unpacker.files(in: readURL) where self.copyIn(file) { added += 1 }
        }
        refresh()
        if added == 0 {
            notice = "No files found in “\(folder.lastPathComponent)”."
        } else {
            say("Added \(plural(added, "file")) from folder “\(folder.lastPathComponent)”.")
        }
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

    // MARK: Delete

    func delete(_ url: URL) {
        try? fm.removeItem(at: url)
        refresh()
    }

    func clearOriginals() {
        for url in (try? fm.contentsOfDirectory(at: originalsDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
        refresh()
        say("Originals folder emptied.")
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
    func unpack(_ files: [FileItem], format: UnpackFormat) async -> RunSummary {
        var summary = RunSummary()
        guard !isRunning, !files.isEmpty else { return summary }
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
            case .success(let report):
                summary.succeeded.append(report)
                errors[item.name] = nil
                run?.items[i].status = .done(doneText(report, format: format))
                if deleteOriginals {
                    try? fm.removeItem(at: item.url)
                } else {
                    try? fm.moveItem(at: item.url, to: Unpacker.unique(originalsDir.appendingPathComponent(item.name)))
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
            return "Failed: not a zip file"
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
