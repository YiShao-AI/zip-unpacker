import Foundation
import CommonCrypto
import zlib

/// Files hidden in a PNG's pixels by TT-tools (a ComfyUI plugin, "TT img enc" / "TT img enc pw").
///
/// The lowest bit of each R, G, B sample, left to right and top to bottom, makes a bit stream (high bit first):
///     [length: 4 bytes][blob: length bytes]      all numbers big-endian
/// The blob is one of:
///     [flag 0][ext len][ext][size: 4][data]                         current, no password
///     [flag 1][sha256: 32][salt: 16][ext len][ext][size: 4][data]   current, password
///     [ext len][ext][size: 4][data]                                 "TT img enc", no password
///     the bytes of a zip                                            before v1.0.5
/// The stream starts 5 % down the image in older versions, 20 % in newer ones (they leave room for the
/// watermark some hosts add), so every row near the top is tried. A row only counts when the whole header
/// adds up, which ordinary PNGs don't do by chance.
///
/// Pixels come from our own PNG reader: ImageIO may premultiply alpha or colour-match, which changes low bits.
public enum TTImage {
    public struct Header: Equatable {
        let startRow: Int
        /// Bytes of the blob.
        let length: Int
        /// Bytes of the blob in front of the data.
        let dataOffset: Int
        public let fileExtension: String
        let salt: [UInt8]?
        let passwordHash: [UInt8]?

        public var isEncrypted: Bool { salt != nil }

        public func accepts(_ password: String) -> Bool {
            guard let salt, let passwordHash else { return true }
            return sha256(Array((password + hex(salt)).utf8)) == passwordHash
        }
    }

    public static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Longest extension believed. Decides how many bytes a header check needs.
    private static let maxExtension = 16
    private static let headerBytes = 4 + 49 + 1 + maxExtension + 4

    /// The hidden file's header, or nil for an ordinary PNG. Reads only the top of the image.
    public static func probe(_ url: URL) -> Header? {
        guard let rows = try? PNGRows(url), rows.width > 0 else { return nil }
        let w = rows.width, h = rows.height
        let perRow = min(w * 3, headerBytes * 8)
        let rowsPerHeader = (headerBytes * 8 + perRow - 1) / perRow
        let lastStart = min(h - 1, h / 4)              // 20 % plus a margin
        let wanted = min(h, lastStart + rowsPerHeader)

        var bits = [UInt8](repeating: 0, count: wanted * perRow)
        for y in 0..<wanted {
            guard let row = try? rows.next() else { return nil }
            bits.withUnsafeMutableBufferPointer { rows.lowBits(of: row, pixels: (perRow + 2) / 3, count: perRow, into: $0.baseAddress! + y * perRow) }
        }
        var head = [UInt8](repeating: 0, count: headerBytes)
        for start in 0...lastStart {
            let available = (wanted - start) * perRow
            guard available >= headerBytes * 8 else { break }
            let from = start * perRow
            for i in 0..<headerBytes {
                var v: UInt8 = 0
                for b in 0..<8 { v = v << 1 | bits[from + i * 8 + b] }
                head[i] = v
            }
            if let header = parse(head, startRow: start, capacity: (h - start) * w * 3 / 8) { return header }
        }
        return nil
    }

    static func parse(_ b: [UInt8], startRow: Int, capacity: Int) -> Header? {
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        let length = u32(0)
        guard length > 0, length <= capacity - 4 else { return nil }

        /// `at`: where the extension length sits, counted from the start of the blob.
        func described(at: Int) -> (ext: String, dataOffset: Int)? {
            let n = Int(b[4 + at])
            guard (1...maxExtension).contains(n) else { return nil }
            let name = b[(4 + at + 1)..<(4 + at + 1 + n)]
            guard name.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else { return nil }
            let offset = at + 1 + n + 4
            guard u32(4 + at + 1 + n) == length - offset else { return nil }
            return (String(decoding: name, as: UTF8.self), offset)
        }

        if b[4] == 1, let d = described(at: 49) {
            return Header(startRow: startRow, length: length, dataOffset: d.dataOffset, fileExtension: d.ext,
                          salt: Array(b[37..<53]), passwordHash: Array(b[5..<37]))
        }
        if b[4] == 0, let d = described(at: 1) {
            return Header(startRow: startRow, length: length, dataOffset: d.dataOffset, fileExtension: d.ext, salt: nil, passwordHash: nil)
        }
        if let d = described(at: 0) {
            return Header(startRow: startRow, length: length, dataOffset: d.dataOffset, fileExtension: d.ext, salt: nil, passwordHash: nil)
        }
        if Array(b[4..<8]) == [0x50, 0x4B, 0x03, 0x04] {
            return Header(startRow: startRow, length: length, dataOffset: 0, fileExtension: "zip", salt: nil, passwordHash: nil)
        }
        return nil
    }

    /// Writes the hidden file to `target`. Works a row at a time, so memory stays flat however big the image.
    public static func extract(_ url: URL, header: Header, password: String?, to target: URL,
                               progress: ((_ done: Int64, _ total: Int64) -> Void)? = nil) throws {
        let rows = try PNGRows(url)
        for _ in 0..<header.startRow { _ = try rows.next() }

        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }

        let total = header.length - header.dataOffset
        var cipher: KeyStream? = nil
        if let salt = header.salt {
            guard let password else { throw UnpackError.passwordRequired }
            cipher = KeyStream(password: password, salt: salt)
        }

        var skip = 4 + header.dataOffset        // length field and header, then data
        var left = total
        var bits = [UInt8](repeating: 0, count: rows.width * 3)
        var packed = [UInt8](repeating: 0, count: rows.width * 3 / 8 + 1)
        var accumulator: UInt8 = 0
        var count = 0
        var reported = 0

        while left > 0 {
            guard let row = try rows.next() else { throw UnpackError.corrupt("the image ends before the hidden file does") }
            let made: Int = bits.withUnsafeMutableBufferPointer { b in
                packed.withUnsafeMutableBufferPointer { p in
                    rows.lowBits(of: row, pixels: rows.width, count: b.count, into: b.baseAddress!)
                    var n = 0
                    for i in 0..<b.count {
                        accumulator = accumulator << 1 | b[i]
                        count += 1
                        if count == 8 { p[n] = accumulator; n += 1; count = 0 }
                    }
                    return n
                }
            }
            let dropped = min(skip, made)
            skip -= dropped
            let n = min(made - dropped, left)
            guard n > 0 else { continue }
            try packed.withUnsafeMutableBufferPointer { p in
                let bytes = p.baseAddress! + dropped
                cipher?.apply(to: bytes, count: n)
                try autoreleasepool { try out.write(contentsOf: Data(bytes: bytes, count: n)) }
            }
            left -= n
            let done = total - left
            if done - reported >= 1 << 22 || left == 0 {
                reported = done
                progress?(Int64(done), Int64(total))
            }
        }
    }

    /// The bytes XORed over the data: SHA-256 of password + salt in hex + a decimal counter, repeated.
    struct KeyStream {
        private let material: [UInt8]
        private var counter = 0
        private var block = [UInt8]()
        private var used = 32

        init(password: String, salt: [UInt8]) { material = Array((password + hex(salt)).utf8) }

        mutating func apply(to bytes: UnsafeMutablePointer<UInt8>, count: Int) {
            for i in 0..<count {
                if used == 32 {
                    block = sha256(material + Array(String(counter).utf8))
                    counter += 1
                    used = 0
                }
                bytes[i] ^= block[used]
                used += 1
            }
        }
    }
}

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private func sha256(_ bytes: [UInt8]) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
    return digest
}

/// Non-interlaced PNG read one row at a time: pixels exactly as stored, with no colour handling.
final class PNGRows {
    let width: Int
    let height: Int
    private let colorType: UInt8
    private let depth: Int
    private let samples: Int
    private let stride: Int
    private let filterStep: Int
    private let palette: [UInt8]

    private let fd: Int32
    private var offset: off_t
    private var chunkLeft = 0
    /// On the heap because zlib remembers the stream's address.
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private var inflating = false
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    private var current: UnsafeMutablePointer<UInt8>
    private var previous: UnsafeMutablePointer<UInt8>
    private var row = 0

    init(_ url: URL) throws {
        let file = open(url.path, O_RDONLY)
        guard file >= 0 else {
            stream.deallocate(); input.deallocate()
            throw UnpackError.notAnArchive
        }
        func read(_ n: Int, at: off_t) -> [UInt8]? {
            var b = [UInt8](repeating: 0, count: n)
            return pread(file, &b, n, at) == n ? b : nil
        }
        /// Everything in front of the pixel data, or nil when this isn't a PNG we can read.
        func layout() -> (w: Int, h: Int, depth: Int, type: UInt8, channels: Int, palette: [UInt8], data: off_t)? {
            guard read(8, at: 0) == TTImage.pngSignature else { return nil }
            var fields: (w: Int, h: Int, depth: Int, type: UInt8, interlace: UInt8)? = nil
            var table: [UInt8] = []
            var position: off_t = 8
            while true {
                guard let c = read(8, at: position) else { return nil }
                let n = Int(c[0]) << 24 | Int(c[1]) << 16 | Int(c[2]) << 8 | Int(c[3])
                let name = String(decoding: c[4..<8], as: UTF8.self)
                if name == "IDAT" { break }
                if name == "IEND" { return nil }
                if name == "IHDR" {
                    guard n == 13, let d = read(13, at: position + 8) else { return nil }
                    func u32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
                    fields = (u32(0), u32(4), Int(d[8]), d[9], d[12])
                } else if name == "PLTE" {
                    guard n % 3 == 0, n <= 768, let d = read(n, at: position + 8) else { return nil }
                    table = d
                }
                position += off_t(n) + 12
            }
            guard let f = fields, f.w > 0, f.h > 0, f.w < 1 << 24, f.h < 1 << 24, f.interlace == 0 else { return nil }
            let channels: Int
            switch (f.type, f.depth) {
            case (2, 8): channels = 3
            case (6, 8): channels = 4
            case (0, 8): channels = 1
            case (4, 8): channels = 2
            case (3, 1), (3, 2), (3, 4), (3, 8):
                guard !table.isEmpty else { return nil }
                channels = 1
            default: return nil
            }
            return (f.w, f.h, f.depth, f.type, channels, table, position)
        }
        guard let png = layout() else {
            close(file); stream.deallocate(); input.deallocate()
            throw UnpackError.notAnArchive
        }

        fd = file
        width = png.w; height = png.h; depth = png.depth; colorType = png.type; samples = png.channels
        palette = png.palette
        offset = png.data
        stride = (png.w * png.channels * png.depth + 7) / 8
        filterStep = max(1, png.channels * png.depth / 8)
        current = .allocate(capacity: stride + 1)
        previous = .allocate(capacity: stride + 1)
        previous.initialize(repeating: 0, count: stride + 1)
        current.initialize(repeating: 0, count: stride + 1)

        memset(stream, 0, MemoryLayout<z_stream>.size)
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw UnpackError.notAnArchive
        }
        inflating = true
    }

    deinit {
        if inflating { inflateEnd(stream) }
        close(fd)
        stream.deallocate(); input.deallocate(); current.deallocate(); previous.deallocate()
    }

    /// More compressed bytes from the IDAT chunks. False at the end of the pixel data.
    private func refill() -> Bool {
        while chunkLeft == 0 {
            var c = [UInt8](repeating: 0, count: 8)
            guard pread(fd, &c, 8, offset) == 8 else { return false }
            let n = Int(c[0]) << 24 | Int(c[1]) << 16 | Int(c[2]) << 8 | Int(c[3])
            guard String(decoding: c[4..<8], as: UTF8.self) == "IDAT" else { return false }
            offset += 8
            chunkLeft = n
            if n == 0 { offset += 4 }
        }
        let got = pread(fd, input, min(chunkLeft, 1 << 20), offset)
        guard got > 0 else { return false }
        offset += off_t(got)
        chunkLeft -= got
        if chunkLeft == 0 { offset += 4 }               // the chunk's CRC
        stream.pointee.next_in = input
        stream.pointee.avail_in = uInt(got)
        return true
    }

    /// The next row, unfiltered, or nil after the last one. Valid until the next call.
    func next() throws -> UnsafePointer<UInt8>? {
        guard row < height else { return nil }
        row += 1
        swap(&current, &previous)
        stream.pointee.next_out = current
        stream.pointee.avail_out = uInt(stride + 1)
        while stream.pointee.avail_out > 0 {
            if stream.pointee.avail_in == 0, !refill() { throw UnpackError.corrupt("the image is cut short") }
            let status = inflate(stream, Z_NO_FLUSH)
            if status == Z_STREAM_END, stream.pointee.avail_out > 0 { throw UnpackError.corrupt("the image is cut short") }
            if status != Z_OK, status != Z_STREAM_END { throw UnpackError.corrupt("the image's pixel data is damaged") }
        }

        let line = current + 1, above = previous + 1, step = filterStep, n = stride
        switch current[0] {
        case 0: break
        case 1: if n > step { for i in step..<n { line[i] = line[i] &+ line[i - step] } }
        case 2: for i in 0..<n { line[i] = line[i] &+ above[i] }
        case 3:
            for i in 0..<n {
                let left = i >= step ? Int(line[i - step]) : 0
                line[i] = line[i] &+ UInt8((left + Int(above[i])) / 2)
            }
        case 4:
            for i in 0..<n {
                let a = i >= step ? Int(line[i - step]) : 0, b = Int(above[i]), c = i >= step ? Int(above[i - step]) : 0
                let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                line[i] = line[i] &+ UInt8(pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
            }
        default: throw UnpackError.corrupt("the image's pixel data is damaged")
        }
        return UnsafePointer(line)
    }

    /// One byte (0 or 1) per sample, R, G, B of each pixel. Grey images count as R = G = B, as the encoder's reader does.
    func lowBits(of line: UnsafePointer<UInt8>, pixels: Int, count: Int, into out: UnsafeMutablePointer<UInt8>) {
        var o = 0
        func put(_ a: UInt8, _ b: UInt8, _ c: UInt8) {
            if o < count { out[o] = a & 1; o += 1 }
            if o < count { out[o] = b & 1; o += 1 }
            if o < count { out[o] = c & 1; o += 1 }
        }
        switch colorType {
        case 2, 6:
            let n = min(count, pixels * 3)
            let step = samples
            var p = 0
            while o < n {
                out[o] = line[p] & 1
                if o + 1 < n { out[o + 1] = line[p + 1] & 1 }
                if o + 2 < n { out[o + 2] = line[p + 2] & 1 }
                o += 3
                p += step
            }
        case 3:
            let mask = (1 << depth) - 1
            for x in 0..<pixels {
                let bit = x * depth
                let index = Int(line[bit / 8]) >> (8 - depth - bit % 8) & mask
                guard index * 3 + 2 < palette.count else { put(0, 0, 0); continue }
                put(palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2])
            }
        default:
            for x in 0..<pixels { let v = line[x * samples]; put(v, v, v) }
        }
    }
}
