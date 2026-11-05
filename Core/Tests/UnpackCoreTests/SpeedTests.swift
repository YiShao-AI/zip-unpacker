import XCTest
@testable import UnpackCore

/// Prints throughput (MB/s) of the per-byte hot paths so CI logs show before/after numbers. No pass/fail on speed.
final class SpeedTests: XCTestCase {
    let mb = 1 << 20

    func bytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        var out = [UInt8](repeating: 0, count: n)
        out.withUnsafeMutableBytes { p in
            for i in stride(from: 0, to: n - 7, by: 8) { p.storeBytes(of: g.next() as UInt64, toByteOffset: i, as: UInt64.self) }
        }
        return out
    }

    func report(_ name: String, _ megabytes: Int, _ body: () throws -> Void) rethrows {
        let t0 = Date()
        try body()
        let s = Date().timeIntervalSince(t0)
        print(String(format: "SPEED %@: %d MB in %.2f s = %.0f MB/s", name, megabytes, s, Double(megabytes) / s))
    }

    func testCRCSpeed() {
        let data = bytes(256 * mb)
        var crc: UInt32 = 0
        report("crc32", 256) { data.withUnsafeBytes { crc = CRC32.update(0, $0) } }
        XCTAssertNotEqual(crc, 1)
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testZipCryptoSpeed() throws {
        let header = bytes(12)
        var made: ZipCryptoDecryptor?
        for check in 0...255 {
            if let d = try? ZipCryptoDecryptor(password: Array("123".utf8), header: header, check: UInt8(check)) { made = d; break }
        }
        let d = try XCTUnwrap(made)
        var data = bytes(4 * mb)
        report("zipcrypto", 128) { for _ in 0..<32 { d.decrypt(&data) } }
    }

    /// Stored zip of one 512 MB file, extracted through the whole pipeline (read, CRC, write).
    func testExtractSpeed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(bytes(512 * mb))
        let zip = dir.appendingPathComponent("big.zip")
        try SplitArchiveTests().writeStoredZip([("big.bin", payload)], to: zip)
        try report("extract stored", 512) {
            _ = try Unpacker(passwords: []).unpack(zip, into: dir.appendingPathComponent("out"))
        }
    }
}
