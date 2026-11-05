import Foundation

/// What a file is, from its first bytes (the extension is only used where a format has no signature).
public enum ArchiveKind: Equatable {
    /// Read by the built-in zip reader (falls back to 7-Zip for methods it lacks).
    case zip
    /// Read by 7-Zip; the value is its handler name.
    case engine(String)
    case other

    public var isArchive: Bool { self != .other }

    /// Formats that hold one compressed stream rather than files ("x.tar.gz", "x.mp4.xz").
    public var isSingleStream: Bool {
        if case .engine(let f) = self { return ["gzip", "bzip2", "xz", "zstd", "lzma", "Z"].contains(f) }
        return false
    }

    public static func detect(_ url: URL) -> ArchiveKind {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? fh.close() }
        let b = [UInt8]((try? fh.read(upToCount: 512)) ?? Data())
        func at(_ o: Int, _ sig: [UInt8]) -> Bool { b.count >= o + sig.count && Array(b[o..<(o + sig.count)]) == sig }
        func at(_ o: Int, _ s: String) -> Bool { at(o, Array(s.utf8)) }
        let ext = url.pathExtension.lowercased()

        if b.count >= 4, b[0] == 0x50, b[1] == 0x4B, [3, 5, 7].contains(b[2]), b[3] == b[2] + 1 { return .zip }
        if at(0, [0x50, 0x4B, 0x30, 0x30, 0x50, 0x4B]) { return .zip }                       // spanned zip marker
        if at(0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .engine("7z") }
        if at(0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) { return .engine("Rar5") }
        if at(0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) { return .engine("Rar") }
        if at(0, [0x1F, 0x8B, 0x08]) { return .engine("gzip") }
        if at(0, "BZh"), b.count > 3, (0x31...0x39).contains(b[3]) { return .engine("bzip2") }
        if at(0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .engine("xz") }
        if at(0, [0x28, 0xB5, 0x2F, 0xFD]) { return .engine("zstd") }
        if at(0, [0x1F, 0x9D]) { return .engine("Z") }
        if at(0, "MSCF"), at(4, [0, 0, 0, 0]) { return .engine("Cab") }
        if at(0, [0x60, 0xEA]), ["arj"].contains(ext) || b.count > 10 && b[10] == 2 { return .engine("Arj") }
        if b.count > 6, at(2, "-lh") || at(2, "-lz"), b[6] == 0x2D { return .engine("Lzh") }
        if at(0, "MSWIM\0\0\0") { return .engine("wim") }
        if at(0, "xar!") { return .engine("Xar") }
        if at(0, "070701") || at(0, "070702") || at(0, "070707") { return .engine("Cpio") }
        if at(257, "ustar") { return .engine("tar") }
        // No signature at the start: only trusted together with the extension.
        if ext == "lzma", at(0, [0x5D, 0x00, 0x00]) { return .engine("lzma") }
        if ext == "iso" || ext == "img" {
            try? fh.seek(toOffset: 32769)
            if (try? fh.read(upToCount: 5)) == Data("CD001".utf8) { return .engine("Iso") }
        }
        return .other
    }
}

/// Multi-volume sets that 7-Zip reads starting from the first volume:
/// RAR "x.part1.rar, x.part2.rar…", old RAR "x.rar, x.r00, x.r01…", spanned zip "x.z01, x.z02…, x.zip".
/// (Byte-split sets "x.7z.001, .002…" are handled by `SplitArchive` instead.)
public enum Volumes {
    public enum Role: Equatable { case first, later, none }

    /// "x.part3.rar" → ("x", 3)
    static func rarPart(_ name: String) -> (base: String, number: Int)? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".rar"), let r = lower.range(of: ".part", options: .backwards) else { return nil }
        let digits = lower[r.upperBound..<lower.index(lower.endIndex, offsetBy: -4)]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let n = Int(digits) else { return nil }
        return (String(name[..<r.lowerBound]), n)
    }

    /// Two-digit numbered extension with a letter: ("r", 0) for "x.r00", ("z", 1) for "x.z01".
    static func letterVolume(_ url: URL) -> (letter: Character, number: Int)? {
        let e = url.pathExtension.lowercased()
        guard e.count == 3, let l = e.first, ["r", "s", "z"].contains(l),
              e.dropFirst().allSatisfy(\.isNumber), let n = Int(e.dropFirst()) else { return nil }
        return (l, n)
    }

    /// `siblings`: lowercased names of the files in the same folder.
    public static func role(_ url: URL, siblings: Set<String>) -> Role {
        let name = url.lastPathComponent
        if let p = rarPart(name) { return p.number == 1 ? .first : .later }
        if letterVolume(url) != nil { return .later }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        switch url.pathExtension.lowercased() {
        case "rar": return siblings.contains(stem + ".r00") ? .first : .none
        case "zip": return siblings.contains(stem + ".z01") ? .first : .none
        default: return .none
        }
    }

    /// Every file of the set that `first` opens (including `first`), for removal after unpacking.
    public static func members(of first: URL) -> [URL] {
        let dir = first.deletingLastPathComponent()
        let files = FolderOps.contents(dir).filter { !FolderOps.isDirectory($0) }
        if let p = rarPart(first.lastPathComponent) {
            return files.filter { rarPart($0.lastPathComponent)?.base.lowercased() == p.base.lowercased() }
        }
        let stem = first.deletingPathExtension().lastPathComponent.lowercased()
        return files.filter {
            $0 == first || ($0.deletingPathExtension().lastPathComponent.lowercased() == stem && letterVolume($0) != nil)
        }
    }

    /// True for a spanned zip ("x.zip" next to "x.z01"), which only 7-Zip can read.
    static func isSpannedZip(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "zip" else { return false }
        let sib = url.deletingPathExtension().appendingPathExtension("z01")
        let upper = url.deletingPathExtension().appendingPathExtension("Z01")
        return FileManager.default.fileExists(atPath: sib.path) || FileManager.default.fileExists(atPath: upper.path)
    }
}
