import CryptoKit
import XCTest
@testable import UnpackCore

final class UnpackCoreTests: XCTestCase {
    var out: URL!

    override func setUpWithError() throws {
        out = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: out) }

    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func expected(_ key: String) throws -> [String: String] {
        let data = try Data(contentsOf: fixture("expected.json"))
        let all = try JSONSerialization.jsonObject(with: data) as! [String: [String: String]]
        return try XCTUnwrap(all[key])
    }

    func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Relative path → sha256 for everything in the report folder.
    func contents(_ report: UnpackReport) throws -> [String: String] {
        let base = report.folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var result: [String: String] = [:]
        for f in report.files {
            let rel = f.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
            result[rel] = try sha256(f)
        }
        return result
    }

    // MARK: Baidu-style double layer

    func testNestedAESWithGBKNames() throws {
        let report = try Unpacker(passwords: ["wrong", "test-pw"]).unpack(fixture("nested.pdf"), into: out)
        XCTAssertEqual(report.layers, 2)
        XCTAssertEqual(report.folder.lastPathComponent, "nested")
        XCTAssertEqual(try contents(report), try expected("nested"))
    }

    func testNestedAESWithOddChunkSize() throws {
        // 1000 is not a multiple of the AES block size, so keystream carry-over is exercised.
        var u = Unpacker(passwords: ["test-pw"])
        u.chunkSize = 1000
        let report = try u.unpack(fixture("nested.pdf"), into: out)
        XCTAssertEqual(try contents(report), try expected("nested"))
    }

    func testGBKNamesDecoded() throws {
        let zip = try ZipArchive(url: fixture("nested.pdf"))
        XCTAssertEqual(zip.entries.map(\.path), ["外层文件夹/", "外层文件夹/内层.pdf"])
    }

    func testOutputFolderNamesDoNotCollide() throws {
        let u = Unpacker(passwords: ["test-pw"])
        let a = try u.unpack(fixture("nested.pdf"), into: out)
        let b = try u.unpack(fixture("nested.pdf"), into: out)
        XCTAssertEqual(a.folder.lastPathComponent, "nested")
        XCTAssertEqual(b.folder.lastPathComponent, "nested 2")
    }

    func testWrongPassword() throws {
        XCTAssertThrowsError(try Unpacker(passwords: ["nope"]).unpack(fixture("nested.pdf"), into: out)) {
            XCTAssertEqual($0 as? UnpackError, .wrongPassword)
        }
    }

    func testMissingPassword() throws {
        XCTAssertThrowsError(try Unpacker(passwords: []).unpack(fixture("nested.pdf"), into: out)) {
            XCTAssertEqual($0 as? UnpackError, .passwordRequired)
        }
    }

    func testProgressReported() throws {
        var last: Int64 = 0
        _ = try Unpacker(passwords: ["test-pw"]).unpack(fixture("nested.pdf"), into: out) { last = $0 }
        XCTAssertGreaterThan(last, 100_000)
    }

    // MARK: Other formats

    func testAES128Deflate() throws {
        let report = try Unpacker(passwords: ["test-pw"]).unpack(fixture("aes128.zip"), into: out)
        XCTAssertEqual(report.layers, 1)
        XCTAssertEqual(try contents(report), try expected("aes128"))
    }

    func testZipCrypto() throws {
        let report = try Unpacker(passwords: ["test-pw"]).unpack(fixture("zipcrypto.zip"), into: out)
        XCTAssertEqual(try contents(report), try expected("zipcrypto"))
    }

    func testZipCryptoWrongPassword() throws {
        XCTAssertThrowsError(try Unpacker(passwords: ["nope"]).unpack(fixture("zipcrypto.zip"), into: out))
    }

    func testPlainZipNestedDocxSlipAndUnicodePath() throws {
        let report = try Unpacker(passwords: []).unpack(fixture("plain.zip"), into: out)
        // inner.zip expanded, report.docx left alone, ../evil.txt kept inside, __MACOSX dropped
        XCTAssertEqual(try contents(report), try expected("plain"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deletingLastPathComponent()
            .appendingPathComponent("evil.txt").path))
    }

    func test7zRejected() throws {
        XCTAssertThrowsError(try Unpacker(passwords: []).unpack(fixture("fake7z.pdf"), into: out)) {
            XCTAssertEqual($0 as? UnpackError, .unsupportedArchive("7z"))
        }
    }

    func testNotAnArchive() throws {
        let f = out.appendingPathComponent("note.pdf")
        try Data("%PDF-1.4 hello".utf8).write(to: f)
        XCTAssertThrowsError(try Unpacker(passwords: []).unpack(f, into: out)) {
            XCTAssertEqual($0 as? UnpackError, .notAnArchive)
        }
    }

    func testTempFilesRemoved() throws {
        let tmp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix("unpack-") && !$0.hasPrefix("unpack-tests") })
        _ = try Unpacker(passwords: ["test-pw"]).unpack(fixture("nested.pdf"), into: out)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix("unpack-") && !$0.hasPrefix("unpack-tests") })
        XCTAssertEqual(before, after)
    }
}
