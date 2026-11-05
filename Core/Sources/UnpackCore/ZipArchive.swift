import Foundation
import Compression

public struct ZipEntry {
    /// Decoded path as stored in the archive ("/" separated, not yet sanitised).
    public let path: String
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    let flags: UInt16
    let method: UInt16
    let modTime: UInt16
    let crc32: UInt32
    let localHeaderOffset: UInt64
    let aes: AESInfo?

    struct AESInfo {
        let vendorVersion: UInt16  // 1 = AE-1 (CRC checked), 2 = AE-2 (CRC is 0)
        let strength: UInt8        // 1/2/3 = AES-128/192/256
        let actualMethod: UInt16
    }

    public var isDirectory: Bool { path.hasSuffix("/") }
    public var isEncrypted: Bool { flags & 1 != 0 }

    /// Path components that are safe to create under a destination folder
    /// (no "..", no absolute paths), or nil if nothing is left.
    public var safeComponents: [String]? {
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .map { $0.replacingOccurrences(of: ":", with: "_") }
        return parts.isEmpty ? nil : parts
    }
}

/// Minimal streaming zip reader: stored + deflate, ZipCrypto + WinZip AES, Zip64,
/// non-UTF-8 (GBK) filenames and the Info-ZIP Unicode Path field.
public final class ZipArchive {
    public let entries: [ZipEntry]
    /// Bytes read per step while extracting. Small values are only useful in tests.
    public var chunkSize = 4 << 20
    private let file: SegmentedFile
    private let fileSize: UInt64

    public convenience init(url: URL) throws { try self.init(parts: [url]) }

    /// Reads the pieces of a split zip (x.zip.001, .002…) as one archive, without joining them on disk.
    public init(parts: [URL]) throws {
        file = try SegmentedFile(parts)
        fileSize = file.size
        entries = try ZipArchive.readCentralDirectory(file, size: fileSize)
    }

    // MARK: Reading helpers

    private static func read(_ fh: SegmentedFile, at offset: UInt64, count: Int) throws -> [UInt8] {
        try fh.seek(toOffset: offset)
        return try readNext(fh, count: count)
    }

    private static func readNext(_ fh: SegmentedFile, count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            guard let d = try fh.read(upToCount: count - out.count), !d.isEmpty else {
                throw UnpackError.corrupt("unexpected end of file")
            }
            out.append(contentsOf: d)
        }
        return out
    }

    // MARK: Central directory

    private static func readCentralDirectory(_ fh: SegmentedFile, size: UInt64) throws -> [ZipEntry] {
        guard size >= 22 else { throw UnpackError.notAnArchive }
        let tailLen = Int(min(size, 22 + 0xFFFF))
        let tailStart = size - UInt64(tailLen)
        let tail = try read(fh, at: tailStart, count: tailLen)

        var i = tailLen - 22
        while i >= 0 && !(tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 5 && tail[i + 3] == 6) { i -= 1 }
        guard i >= 0 else { throw UnpackError.corrupt("no end-of-archive record") }

        let eocdPos = tailStart + UInt64(i)
        var count = UInt64(tail.u16(i + 10))
        var cdSize = UInt64(tail.u32(i + 12))
        var cdOffset = UInt64(tail.u32(i + 16))
        var isZip64 = false

        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocdPos >= 20 {
            let loc = try read(fh, at: eocdPos - 20, count: 20)
            if loc.u32(0) == 0x0706_4B50 {
                let rec = try read(fh, at: loc.u64(8), count: 56)
                guard rec.u32(0) == 0x0606_4B50 else { throw UnpackError.corrupt("bad Zip64 record") }
                count = rec.u64(32); cdSize = rec.u64(40); cdOffset = rec.u64(48)
                isZip64 = true
            }
        }

        // Data prepended to the archive (self-extractors etc.) shifts every offset.
        var shift: UInt64 = 0
        if !isZip64, cdOffset + cdSize < eocdPos { shift = eocdPos - (cdOffset + cdSize) }

        guard cdSize < 512 << 20, cdOffset + shift + cdSize <= size else { throw UnpackError.corrupt("bad directory size") }
        let cd = try read(fh, at: cdOffset + shift, count: Int(cdSize))

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(count, 100_000)))
        var p = 0
        while p + 46 <= cd.count && cd.u32(p) == 0x0201_4B50 {
            let flags = cd.u16(p + 8)
            let method = cd.u16(p + 10)
            let modTime = cd.u16(p + 12)
            let crc = cd.u32(p + 16)
            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            let nLen = Int(cd.u16(p + 28)), eLen = Int(cd.u16(p + 30)), cLen = Int(cd.u16(p + 32))
            var offset = UInt64(cd.u32(p + 42))
            guard p + 46 + nLen + eLen + cLen <= cd.count else { throw UnpackError.corrupt("truncated directory") }
            let rawName = Array(cd[(p + 46)..<(p + 46 + nLen)])
            let extra = Array(cd[(p + 46 + nLen)..<(p + 46 + nLen + eLen)])

            var aes: ZipEntry.AESInfo?
            var unicodePath: [UInt8]?
            var e = 0
            while e + 4 <= extra.count {
                let id = extra.u16(e), len = Int(extra.u16(e + 2))
                guard e + 4 + len <= extra.count else { break }
                let body = Array(extra[(e + 4)..<(e + 4 + len)])
                switch id {
                case 0x0001: // Zip64: only the fields that overflowed, in this order
                    var q = 0
                    if usize == 0xFFFF_FFFF, q + 8 <= body.count { usize = body.u64(q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= body.count { csize = body.u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= body.count { offset = body.u64(q); q += 8 }
                case 0x9901 where body.count >= 7:
                    aes = .init(vendorVersion: body.u16(0), strength: body[4], actualMethod: body.u16(5))
                case 0x7075 where body.count > 5:
                    unicodePath = body
                default: break
                }
                e += 4 + len
            }

            let name = decodeName(rawName, flags: flags, unicodePath: unicodePath)
                .replacingOccurrences(of: "\\", with: "/")
            entries.append(ZipEntry(path: name, uncompressedSize: usize, compressedSize: csize, flags: flags,
                                    method: method, modTime: modTime, crc32: crc,
                                    localHeaderOffset: offset + shift, aes: aes))
            p += 46 + nLen + eLen + cLen
        }
        return entries
    }

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func decodeName(_ raw: [UInt8], flags: UInt16, unicodePath: [UInt8]?) -> String {
        if flags & 0x800 != 0, let s = String(bytes: raw, encoding: .utf8) { return s }
        if let u = unicodePath, u[0] == 1, u.u32(1) == CRC32.checksum(raw),
           let s = String(bytes: u[5...], encoding: .utf8) { return s }
        if let s = String(bytes: raw, encoding: .utf8) { return s }
        if let s = String(bytes: raw, encoding: gb18030) { return s }
        return String(bytes: raw, encoding: .isoLatin1) ?? "file"
    }

    // MARK: Extraction

    private struct Payload {
        let decryptor: Decryptor?
        let length: UInt64       // encrypted/compressed bytes still to read
        let method: UInt16       // real compression method
    }

    /// Positions the file at the entry's data and sets up decryption.
    private func openPayload(_ entry: ZipEntry, password: [UInt8]?) throws -> Payload {
        let lh = try Self.read(file, at: entry.localHeaderOffset, count: 30)
        guard lh.u32(0) == 0x0403_4B50 else { throw UnpackError.corrupt("bad local header") }
        try file.seek(toOffset: entry.localHeaderOffset + 30 + UInt64(lh.u16(26)) + UInt64(lh.u16(28)))

        guard entry.isEncrypted else {
            return Payload(decryptor: nil, length: entry.compressedSize, method: entry.method)
        }
        guard let pw = password else { throw UnpackError.passwordRequired }
        if entry.flags & 0x40 != 0 { throw UnpackError.unsupportedArchive("PKWARE strong-encrypted zip") }

        if entry.method == 99 {
            guard let aes = entry.aes,
                  let saltLen = WinZipAESDecryptor.saltLength(strength: aes.strength),
                  let keyLen = WinZipAESDecryptor.keyLength(strength: aes.strength)
            else { throw UnpackError.corrupt("bad AES header") }
            let overhead = UInt64(saltLen + 2 + 10)
            guard entry.compressedSize >= overhead else { throw UnpackError.corrupt("AES entry too short") }
            let salt = try Self.readNext(file, count: saltLen)
            let verifier = try Self.readNext(file, count: 2)
            let d = try WinZipAESDecryptor(password: pw, salt: salt, verifier: verifier, keyLength: keyLen)
            return Payload(decryptor: d, length: entry.compressedSize - overhead, method: aes.actualMethod)
        }

        guard entry.compressedSize >= 12 else { throw UnpackError.corrupt("encrypted entry too short") }
        let header = try Self.readNext(file, count: 12)
        // With a data descriptor (bit 3) the check byte is the high byte of the DOS time instead of the CRC.
        let check = entry.flags & 0x8 != 0 ? UInt8(entry.modTime >> 8) : UInt8(entry.crc32 >> 24)
        let d = try ZipCryptoDecryptor(password: pw, header: header, check: check)
        return Payload(decryptor: d, length: entry.compressedSize - 12, method: entry.method)
    }

    /// True if `password` opens this entry (AES: exact check; ZipCrypto: 255/256 reliable).
    public func accepts(password: String?, for entry: ZipEntry) -> Bool {
        do {
            _ = try openPayload(entry, password: password.map { Array($0.utf8) })
            return true
        } catch {
            return false
        }
    }

    /// Streams one entry to `destination` (overwriting it). `progress` receives bytes read.
    public func extract(_ entry: ZipEntry, to destination: URL, password: String?,
                        progress: ((Int) -> Void)? = nil) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let out = try FileHandle(forWritingTo: destination)
        var ok = false
        defer {
            try? out.close()
            if !ok { try? fm.removeItem(at: destination) }
        }

        let payload = try openPayload(entry, password: password.map { Array($0.utf8) })
        var crc: UInt32 = 0
        var written: UInt64 = 0
        let sink: (Data) throws -> Void = { data in
            data.withUnsafeBytes { crc = CRC32.update(crc, $0) }
            written += UInt64(data.count)
            try out.write(contentsOf: data)
        }

        var filter: OutputFilter?
        switch payload.method {
        case 0: break
        case 8: filter = try OutputFilter(.decompress, using: .zlib) { if let d = $0 { try sink(d) } }
        default: throw UnpackError.unsupportedMethod(payload.method)
        }

        var remaining = payload.length
        while remaining > 0 {
            // FileHandle reads and the decompressor hand back autoreleased buffers. Without a pool per chunk they
            // pile up for the whole entry: a 2 GB entry grew memory until iOS killed the app.
            let n = try autoreleasepool { () throws -> Int in
                var chunk = try Self.readNext(file, count: Int(min(remaining, UInt64(chunkSize))))
                payload.decryptor?.decrypt(&chunk)
                do {
                    if let f = filter { try f.write(chunk) } else { try sink(Data(chunk)) }
                } catch is FilterError {
                    throw payload.decryptor == nil ? UnpackError.corrupt("bad compressed data") : UnpackError.wrongPassword
                }
                return chunk.count
            }
            remaining -= UInt64(n)
            progress?(n)
        }
        do { try filter?.finalize() } catch is FilterError { throw UnpackError.corrupt("bad compressed data") }

        if let aes = payload.decryptor as? WinZipAESDecryptor {
            let stored = try Self.readNext(file, count: 10)
            guard stored == aes.authCode() else { throw UnpackError.integrity("AES authentication code mismatch") }
        }
        guard written == entry.uncompressedSize else {
            throw UnpackError.integrity("size \(written) ≠ \(entry.uncompressedSize)")
        }
        let crcIsMeaningful = !(entry.aes?.vendorVersion == 2)
        if crcIsMeaningful, crc != entry.crc32 {
            throw payload.decryptor is ZipCryptoDecryptor ? UnpackError.wrongPassword : UnpackError.integrity("CRC mismatch")
        }
        ok = true
    }
}

// MARK: - Several files read as one

/// Files read back to back as if they were one file: a normal zip is one segment, a split zip several.
final class SegmentedFile {
    private let handles: [FileHandle]
    private let starts: [UInt64]     // offset of each segment in the whole
    let size: UInt64
    private var position: UInt64 = 0

    init(_ urls: [URL]) throws {
        guard !urls.isEmpty else { throw UnpackError.notAnArchive }
        var hs: [FileHandle] = [], st: [UInt64] = [], total: UInt64 = 0
        do {
            for url in urls {
                let h = try FileHandle(forReadingFrom: url)
                hs.append(h)
                st.append(total)
                total += try h.seekToEnd()
            }
        } catch {
            hs.forEach { try? $0.close() }
            throw error
        }
        handles = hs; starts = st; size = total
    }

    deinit { handles.forEach { try? $0.close() } }

    func seek(toOffset offset: UInt64) throws { position = offset }

    /// Up to `count` bytes from the current position; may return fewer at a segment boundary. Empty at the end.
    func read(upToCount count: Int) throws -> Data? {
        guard position < size, count > 0 else { return Data() }
        var i = starts.count - 1
        while starts[i] > position { i -= 1 }
        let segEnd = i + 1 < starts.count ? starts[i + 1] : size
        let n = Int(min(UInt64(count), segEnd - position))
        try handles[i].seek(toOffset: position - starts[i])
        let d = try handles[i].read(upToCount: n) ?? Data()
        position += UInt64(d.count)
        return d
    }
}

// MARK: - Little-endian access

extension Array where Element == UInt8 {
    func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}
