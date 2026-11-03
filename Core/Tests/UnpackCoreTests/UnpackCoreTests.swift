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
        _ = try Unpacker(passwords: ["test-pw"]).unpack(fixture("nested.pdf"), into: out, progress: { last = $0 })
        XCTAssertGreaterThan(last, 100_000)
    }

    // MARK: Unpack format: layer limit and per-layer passwords

    func testLayerLimitKeepsInnerZip() throws {
        let report = try Unpacker(passwords: ["test-pw"], layerLimit: 1).unpack(fixture("nested.pdf"), into: out)
        XCTAssertEqual(report.layers, 1)
        XCTAssertTrue(report.stoppedAtLimit)
        XCTAssertEqual(report.files.map(\.lastPathComponent), ["内层.pdf"])
        XCTAssertEqual(ArchiveKind.detect(report.files[0]), .zip)
    }

    func testLayerLimitAboveRealDepth() throws {
        let report = try Unpacker(passwords: ["test-pw"], layerLimit: 3).unpack(fixture("nested.pdf"), into: out)
        XCTAssertEqual(report.layers, 2)
        XCTAssertFalse(report.stoppedAtLimit)
        XCTAssertEqual(try contents(report), try expected("nested"))
    }

    func testPerLayerPasswords() throws {
        let u = Unpacker(passwords: [], layerPasswords: [["x", "test-pw"], ["test-pw"]], layerLimit: 2)
        let report = try u.unpack(fixture("nested.pdf"), into: out)
        XCTAssertEqual(try contents(report), try expected("nested"))
    }

    func testPerLayerWrongPasswordNamesLayer() throws {
        let failure = Unpacker.FailureInfo()
        let u = Unpacker(passwords: ["test-pw"], layerPasswords: [["test-pw"], ["nope"]], layerLimit: 2)
        XCTAssertThrowsError(try u.unpack(fixture("nested.pdf"), into: out, failure: failure)) {
            XCTAssertEqual($0 as? UnpackError, .wrongPassword)
        }
        XCTAssertEqual(failure.layer, 2)
        XCTAssertEqual(u.passwords(forLayer: 2), ["nope"])
        XCTAssertEqual(u.passwords(forLayer: 5), ["nope"])
    }

    func testLayerProgressReported() throws {
        var seen = Set<Int>()
        var lastFraction = 0.0
        _ = try Unpacker(passwords: ["test-pw"]).unpack(fixture("nested.pdf"), into: out, onProgress: {
            seen.insert($0.layer)
            if $0.layer == 2 { lastFraction = $0.layerFraction }
        })
        XCTAssertEqual(seen, [1, 2])
        XCTAssertEqual(lastFraction, 1, accuracy: 0.001)
    }

    // MARK: Naming videos after the original

    func touch(_ dir: URL, _ names: [String]) throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try names.map { n in
            let u = dir.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(n.utf8).write(to: u)
            return u
        }
    }

    func testRenameSingleFile() throws {
        let files = try touch(out, ["a8f3e9c1d0.mp4"])
        let renamed = try Unpacker.renameSequentially(files, base: "7月17日舞蹈")
        XCTAssertEqual(renamed.map(\.lastPathComponent), ["7月17日舞蹈.mp4"])
        XCTAssertEqual(try String(contentsOf: renamed[0]), "a8f3e9c1d0.mp4")
    }

    func testRenameSeveralInNaturalOrder() throws {
        let files = try touch(out, ["clip_10.mp4", "clip_2.mp4", "clip_1.mov"])
        let renamed = try Unpacker.renameSequentially(files, base: "7月17日舞蹈")
        XCTAssertEqual(renamed.map(\.lastPathComponent), ["7月17日舞蹈 (1).mov", "7月17日舞蹈 (2).mp4", "7月17日舞蹈 (3).mp4"])
        XCTAssertEqual(try renamed.map { try String(contentsOf: $0) }, ["clip_1.mov", "clip_2.mp4", "clip_10.mp4"])
    }

    func testRenameAvoidsCollisionsAndIsRepeatable() throws {
        // One file already carries a target name; renaming twice gives the same result.
        let files = try touch(out, ["x (2).mp4", "b.mp4", "a.mp4"])
        let first = try Unpacker.renameSequentially(files, base: "x")
        XCTAssertEqual(Set(first.map(\.lastPathComponent)), ["x (1).mp4", "x (2).mp4", "x (3).mp4"])
        let second = try Unpacker.renameSequentially(first, base: "x")
        XCTAssertEqual(second.map(\.lastPathComponent), ["x (1).mp4", "x (2).mp4", "x (3).mp4"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(),
                       ["x (1).mp4", "x (2).mp4", "x (3).mp4"])
    }

    func testRenameKeepsFilesInTheirFolders() throws {
        let files = try touch(out, ["sub/one.mp4", "two.mp4"])
        let renamed = try Unpacker.renameSequentially(files, base: "d/a:y")
        XCTAssertEqual(renamed.map { $0.deletingLastPathComponent().lastPathComponent }, ["sub", out.lastPathComponent])
        XCTAssertEqual(renamed.map(\.lastPathComponent), ["d_a_y (1).mp4", "d_a_y (2).mp4"])
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
