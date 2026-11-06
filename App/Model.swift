import Foundation
import SwiftUI
import UIKit
import UnpackCore

struct FileItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let fileCount: Int
    let isDirectory: Bool
    let added: Date?
    /// Starred files inside, for folders.
    var favorites: [URL] = []
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// How a batch is unpacked: how many zip layers to open and which passwords to try.
struct UnpackFormat: Codable, Hashable {
    /// nil = Auto: keep opening zips found inside, up to 6 deep.
    var layers: Int?
    /// "Per layer" mode (needs a fixed layer count): one password per layer.
    var perLayer = false
    /// "Any layer" mode: tried in order on every layer until one works.
    var passwordList: [String] = ["123"]
    /// "Per layer" mode: index 0 = layer 1. Empty = that layer has no password.
    var layerPasswords: [String] = ["123", "123", "123"]

    static let standard = UnpackFormat()
    static let layerChoices: [Int?] = [nil, 1, 2, 3]

    var usesPerLayer: Bool { perLayer && layers != nil }

    var cleanList: [String] {
        passwordList.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func layerPassword(_ i: Int) -> String {
        i < layerPasswords.count ? layerPasswords[i].trimmingCharacters(in: .whitespaces) : ""
    }

    /// The passwords tried on layer `n` (1-based).
    func passwords(forLayer n: Int) -> [String] {
        guard usesPerLayer, let count = layers else { return cleanList }
        let p = layerPassword(min(n, count) - 1)
        return p.isEmpty ? [] : [p]
    }

    var unpacker: Unpacker {
        if usesPerLayer, let n = layers {
            return Unpacker(passwords: [], layerPasswords: (0..<n).map { passwords(forLayer: $0 + 1) }, layerLimit: n)
        }
        return Unpacker(passwords: cleanList, layerLimit: layers)
    }

    var layersText: String {
        guard let n = layers else { return "Auto layers" }
        return "\(n) layer\(n == 1 ? "" : "s")"
    }

    var passwordText: String {
        if usesPerLayer, let n = layers {
            return "passwords " + (0..<n).map { layerPassword($0).isEmpty ? "none" : layerPassword($0) }.joined(separator: " / ")
        }
        let list = cleanList
        guard let first = list.first else { return "no password" }
        return "password \(first)" + (list.count > 1 ? " +\(list.count - 1)" : "")
    }

    var summary: String { "\(layersText) · \(passwordText)" }

    /// Two formats with the same key unpack identically (unused fields are ignored).
    var key: String {
        let n = layers ?? 0
        let pw = usesPerLayer ? (0..<n).map(layerPassword) : cleanList
        return "\(n)|\(usesPerLayer)|\(pw.joined(separator: "\u{1F}"))"
    }

    /// Keeps the per-layer array long enough to edit every layer.
    mutating func normalize() {
        while layerPasswords.count < 3 { layerPasswords.append("") }
        if layers == nil { perLayer = false }
    }
}

struct QuickPick: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var format: UnpackFormat

    static let builtIn: [QuickPick] = [
        QuickPick(name: "Baidu Netdisk", format: UnpackFormat(layers: 2, passwordList: ["123"])),
        QuickPick(name: "Plain zip", format: UnpackFormat(layers: 1, passwordList: [], layerPasswords: ["", "", ""])),
    ]
}

/// Saved next to each batch's contents as a hidden file, so the batch remembers how it was made.
struct BatchInfo: Codable, Hashable {
    var format: String?
    var exportedTo: String?
    var exportedAt: Date?

    static let fileName = ".unpacker.json"

    static func load(_ folder: URL) -> BatchInfo {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let info = try? JSONDecoder().decode(BatchInfo.self, from: data) else { return BatchInfo() }
        return info
    }

    func save(_ folder: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName))
    }
}

struct Batch: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let fileCount: Int
    /// One sub-folder per original download.
    let originals: Int
    let info: BatchInfo
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Settings stored in UserDefaults.
enum Prefs {
    static let defaults = UserDefaults.standard
    static let legacyPasswordsKey = "passwords"
    static let deleteOriginalsKey = "deleteOriginals"
    static let formatKey = "format.default"
    static let lastFormatKey = "format.last"
    static let globalKey = "format.global"
    static let quickPicksKey = "format.quickPicks"
    static let autoCopyKey = "export.autoCopy"
    static let renameVideosKey = "names.videosAfterOriginal"

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    static func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    /// Version 1.0 kept a newline-separated password list; carry it over.
    static var initialFormat: UnpackFormat {
        if var f = load(UnpackFormat.self, formatKey) { f.normalize(); return f }
        var f = UnpackFormat.standard
        let old = (defaults.string(forKey: legacyPasswordsKey) ?? "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !old.isEmpty { f.passwordList = old }
        return f
    }
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
            do {
                try FileManager.default.copyItem(at: folder, to: url)
                try? FileManager.default.removeItem(at: url.appendingPathComponent(BatchInfo.fileName))
            } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
        return target
    }
}

/// One file in the batch that is running (or just finished).
struct RunItem: Identifiable {
    enum Status: Equatable {
        case waiting
        case unpacking(layer: Int, fraction: Double)
        case done(String)
        case failed(String)
        case notStarted
    }

    let url: URL
    let name: String
    var status: Status = .waiting
    var id: URL { url }
}

struct BatchRun {
    enum Phase { case running, exporting, done }
    enum Export: Equatable {
        case off
        case waiting(String)
        case copying(String)
        case copied(String)
        case failed(String)
        case notCopied
    }

    var batchName: String
    var batchURL: URL?
    var format: UnpackFormat
    var items: [RunItem]
    var phase: Phase = .running
    var stopRequested = false
    var export: Export = .off
    /// The finished batch folder, if anything unpacked.
    var result: Batch?

    var finished: Int { items.filter { if case .done = $0.status { return true }; if case .failed = $0.status { return true }; return false }.count }
    var succeeded: Int { items.filter { if case .done = $0.status { return true }; return false }.count }
    var failed: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var notStarted: Int { items.filter { $0.status == .notStarted }.count }

    var overall: Double {
        guard !items.isEmpty else { return 0 }
        if phase == .done { return 1 }
        let expected = Double(format.layers ?? 2)
        let sum = items.reduce(0.0) { t, item in
            switch item.status {
            case .done, .failed: return t + 1
            case .unpacking(let layer, let f): return t + min((Double(layer - 1) + f) / expected, 0.99)
            default: return t
            }
        }
        return sum / Double(items.count)
    }
}

enum Media {
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "mkv", "avi", "flv", "wmv", "webm", "ts",
                                               "m2ts", "mts", "mpg", "mpeg", "rmvb", "rm", "vob"]
    /// What AVFoundation plays on iPhone.
    static let playableExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp"]

    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    static func isPlayable(_ url: URL) -> Bool { playableExtensions.contains(url.pathExtension.lowercased()) }
}

func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func plural(_ n: Int, _ word: String) -> String {
    guard n != 1 else { return "1 \(word)" }
    let es = ["ch", "sh", "s", "x"].contains { word.hasSuffix($0) }
    return "\(n) \(word)\(es ? "es" : "s")"
}

extension View {
    /// A "Done" button above the keyboard plus swipe-down-to-dismiss. The password list is multi-line,
    /// so Return adds a line and there was no other way to put the keyboard away.
    func keyboardDoneButton() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
    }
}

// MARK: - Sorting

enum SortKey: String, CaseIterable, Identifiable {
    case name, size, added
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .added: return "Date added"
        }
    }
}

enum Sorting {
    static func date(_ url: URL) -> Date {
        let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
    }

    static func size(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if v?.isDirectory == true {
            return Unpacker.files(in: url).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return Int64(v?.fileSize ?? 0)
    }

    /// Sorts anything with a name, a size and a date. Name order is Finder-style ("2" before "10").
    static func sort<T>(_ items: [T], by key: SortKey, ascending: Bool,
                        name: (T) -> String, size: (T) -> Int64, date: (T) -> Date) -> [T] {
        let sorted: [T]
        switch key {
        case .name: sorted = items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .size: sorted = items.sorted { size($0) < size($1) }
        case .added: sorted = items.sorted { date($0) < date($1) }
        }
        return ascending ? sorted : sorted.reversed()
    }
}

/// Toolbar menu: pick Name / Size / Date added; picking the current one again flips the direction.
struct SortMenu: View {
    @Binding var key: String
    @Binding var ascending: Bool

    var body: some View {
        Menu {
            ForEach(SortKey.allCases) { k in
                Button {
                    if key == k.rawValue { ascending.toggle() } else {
                        key = k.rawValue
                        ascending = k == .name   // names A→Z; size and date biggest/newest first
                    }
                } label: {
                    if key == k.rawValue {
                        Label(k.label, systemImage: ascending ? "chevron.up" : "chevron.down")
                    } else {
                        Text(k.label)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }
}

/// Long-press menu that shows a file's full name and copies it.
struct FullNameMenu: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.contextMenu {
            Text(name)
            Button { UIPasteboard.general.string = name } label: { Label("Copy name", systemImage: "doc.on.doc") }
        }
    }
}
