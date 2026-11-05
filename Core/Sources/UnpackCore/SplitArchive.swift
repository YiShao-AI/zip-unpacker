import Foundation

/// Zips cut into numbered pieces: `name.zip.001`, `name.zip.002`, … (7-Zip / Baidu style).
/// The pieces are plain byte slices, so joining them in order gives the original zip.
public enum SplitArchive {
    public struct PartSet: Equatable {
        /// Name of the joined file, e.g. `name.zip`.
        public let name: String
        /// Parts found, sorted by number.
        public let parts: [URL]
        public let numbers: [Int]
        public let state: State

        public var isComplete: Bool { state == .complete }
    }

    public enum State: Equatable {
        case complete
        /// Numbers absent between 1 and the highest part found.
        case missing([Int])
        /// Parts 1…n are all here but none of them is the end of the zip.
        case needsMore(after: Int)
        /// Part 1 isn't an archive Unpacker can read.
        case notZip
    }

    /// `name.zip.003` → ("name.zip", 3). Needs a suffix of 3+ digits and a non-empty base.
    public static func part(_ url: URL) -> (base: String, number: Int)? {
        let name = url.lastPathComponent
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let suffix = name[name.index(after: dot)...]
        let base = String(name[..<dot])
        guard suffix.count >= 3, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber),
              !base.isEmpty, let n = Int(suffix) else { return nil }
        return (base, n)
    }

    /// Groups numbered parts by base name. Files that aren't parts are ignored.
    public static func sets(in urls: [URL]) -> [PartSet] {
        var groups: [String: [(Int, URL)]] = [:]
        for url in urls {
            guard let p = part(url) else { continue }
            groups[p.base, default: []].append((p.number, url))
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { base in
            let items = groups[base]!.sorted { $0.0 < $1.0 }
            let numbers = items.map(\.0), parts = items.map(\.1)
            return PartSet(name: base, parts: parts, numbers: numbers, state: state(numbers: numbers, parts: parts))
        }
    }

    static func state(numbers: [Int], parts: [URL]) -> State {
        let have = Set(numbers)
        let top = numbers.max() ?? 0
        let missing = (1...max(top, 1)).filter { !have.contains($0) }
        if !missing.isEmpty { return .missing(missing) }
        guard let first = parts.first else { return .notZip }
        if startsLikeZip(first) { return endsWithZipEnd(parts) ? .complete : .needsMore(after: top) }
        switch ArchiveKind.detect(first) {
        case .engine("7z"):
            // The 7z start header says how long the whole archive is.
            guard let want = sevenZipLength(first) else { return .notZip }
            let have = parts.reduce(UInt64(0)) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return have >= want ? .complete : .needsMore(after: top)
        case .engine:
            return .complete      // RAR, tar…: no cheap length check; 7-Zip reports a short set as a missing part
        default:
            return .notZip
        }
    }

    static func sevenZipLength(_ url: URL) -> UInt64? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let b = [UInt8](h.readData(ofLength: 32))
        guard b.count == 32 else { return nil }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
        let (offset, size) = (u64(12), u64(20))
        guard offset < 1 << 50, size < 1 << 40 else { return nil }
        return 32 + offset + size
    }

    static func startsLikeZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let b = [UInt8](h.readData(ofLength: 4))
        // Local file header, or the "spanned" marker some tools write first.
        return b == [0x50, 0x4B, 0x03, 0x04] || b == [0x50, 0x4B, 0x07, 0x08] || b == [0x50, 0x4B, 0x30, 0x30]
    }

    /// True when the joined bytes end with a zip end-of-central-directory record (plus its comment).
    static func endsWithZipEnd(_ parts: [URL]) -> Bool {
        let want = 22 + 0xFFFF
        var tail = Data()
        for url in parts.reversed() where tail.count < want {
            guard let h = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let take = min(UInt64(want - tail.count), size)
            try? h.seek(toOffset: size - take)
            tail = h.readData(ofLength: Int(take)) + tail
        }
        let b = [UInt8](tail)
        guard b.count >= 22 else { return false }
        var i = b.count - 22
        while i >= 0 {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 {
                let comment = Int(b[i + 20]) | Int(b[i + 21]) << 8
                if i + 22 + comment == b.count { return true }
            }
            i -= 1
        }
        return false
    }

    /// Writes the parts, in order, into `dest` (which must not exist yet).
    public static func join(_ parts: [URL], to dest: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: dest.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
        }
        do {
            let out = try FileHandle(forWritingTo: dest)
            defer { try? out.close() }
            for url in parts {
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while true {
                    let chunk = try autoreleasepool { () -> Data in
                        let d = input.readData(ofLength: 4 << 20)
                        if !d.isEmpty { try out.write(contentsOf: d) }
                        return d
                    }
                    if chunk.isEmpty { break }
                }
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    /// One line for the Inbox under a part that can't be joined yet.
    public static func message(for set: PartSet) -> String? {
        func n(_ x: Int) -> String { String(format: ".%03d", x) }
        switch set.state {
        case .complete: return nil
        case .missing(let m):
            let list = m.prefix(6).map(n).joined(separator: ", ") + (m.count > 6 ? "…" : "")
            return "Part of split archive “\(set.name)”. Missing \(list) — add all parts."
        case .needsMore(let after):
            return "Part of split archive “\(set.name)”. Add the parts after \(n(after))."
        case .notZip:
            return "“\(set.name)” is split into parts but isn't an archive Unpacker can read."
        }
    }
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif
