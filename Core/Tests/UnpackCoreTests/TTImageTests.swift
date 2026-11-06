import XCTest
import CommonCrypto
@testable import UnpackCore

/// Files hidden in PNGs by TT-tools. Fixtures: scripts/make_format_fixtures.py (password test-pw) and a real
/// sample from the TT-tools repo (Fixtures/formats/TT-SOURCE.txt).
final class TTImageTests: XCTestCase {
    var out: URL!

    override func setUpWithError() throws {
        out = FileManager.default.temporaryDirectory.appendingPathComponent("tt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: out) }

    func fx(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/formats"), name)
    }

    func unpack(_ name: String, _ passwords: [String] = []) throws -> UnpackReport {
        try Unpacker(passwords: passwords).unpack(fx(name), into: out.appendingPathComponent(UUID().uuidString))
    }

    func testEveryLayoutGivesTheHiddenFile() throws {
        let clip = try Data(contentsOf: fx("ttclip.bin"))
        for name in ["tt-new", "tt-old-rgba", "tt-noflag"] {
            XCTAssertEqual(ArchiveKind.detect(try fx(name + ".png")), .ttImage, name)
            let r = try unpack(name + ".png")
            XCTAssertEqual(r.files.map(\.lastPathComponent), [name + ".mp4"], name)
            XCTAssertEqual(try Data(contentsOf: r.files[0]), clip, name)
        }
    }

    func testPassword() throws {
        let clip = try Data(contentsOf: fx("ttclip.bin"))
        let r = try unpack("tt-pw.png", ["wrong", "test-pw"])
        XCTAssertEqual(try Data(contentsOf: r.files[0]), clip)
        XCTAssertThrowsError(try unpack("tt-pw.png")) { XCTAssertEqual($0 as? UnpackError, .passwordRequired) }
        XCTAssertThrowsError(try unpack("tt-pw.png", ["wrong"])) { XCTAssertEqual($0 as? UnpackError, .wrongPassword) }
    }

    func testZipInsideIsOpenedToo() throws {
        let clip = try Data(contentsOf: fx("ttclip.bin"))
        for name in ["tt-zip.png", "tt-rawzip.png"] {
            let r = try unpack(name)
            XCTAssertEqual(r.files.map(\.lastPathComponent), ["clip (1).mp4"], name)
            XCTAssertEqual(try Data(contentsOf: r.files[0]), clip, name)
            XCTAssertEqual(r.layers, 2, name)
        }
    }

    func testOrdinaryPNGIsLeftAlone() throws {
        XCTAssertEqual(ArchiveKind.detect(try fx("ordinary.png")), .other)
        XCTAssertThrowsError(try unpack("ordinary.png")) { XCTAssertEqual($0 as? UnpackError, .notAnArchive) }

        // In an imported folder it stays a picture while the TT image next to it is decoded.
        let folder = out.appendingPathComponent("pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx("ordinary.png"), to: folder.appendingPathComponent("ordinary.png"))
        try FileManager.default.copyItem(at: fx("tt-new.png"), to: folder.appendingPathComponent("tt-new.png"))
        let r = try Unpacker(passwords: []).unpack(folder, into: out.appendingPathComponent("result"))
        XCTAssertEqual(r.files.map(\.lastPathComponent).sorted(), ["ordinary.png", "tt-new.mp4"])
    }

    /// Baidu files often have the wrong extension; the bytes decide.
    func testExtensionDoesNotMatter() throws {
        let renamed = out.appendingPathComponent("movie.pdf")
        try FileManager.default.copyItem(at: fx("tt-new.png"), to: renamed)
        XCTAssertEqual(ArchiveKind.detect(renamed), .ttImage)
    }

    /// Cut inside the hidden data (it ends about 45 % of the way down this image).
    func testCutShortImageIsReported() throws {
        let whole = try Data(contentsOf: fx("tt-new.png"))
        let cut = out.appendingPathComponent("cut.png")
        try whole.prefix(whole.count * 3 / 10).write(to: cut)
        XCTAssertEqual(ArchiveKind.detect(cut), .ttImage)
        XCTAssertThrowsError(try Unpacker(passwords: []).unpack(cut, into: out.appendingPathComponent("r"))) {
            guard case .corrupt = $0 as? UnpackError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(FileManager.default.subpaths(atPath: out.appendingPathComponent("r").path)?.isEmpty ?? true)
    }

    /// A real image: made by TT-tools with password 123456, then watermarked by a hosting site.
    func testRealSample() throws {
        let r = try unpack("tt-real-watermark.png", ["123456"])
        XCTAssertEqual(r.files.map(\.lastPathComponent), ["tt-real-watermark.jpg"])
        let data = [UInt8](try Data(contentsOf: r.files[0]))
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(data, CC_LONG(data.count), &digest)
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                       "a4eb5c1bc88525a9b1a2b741118b7752e6ed86b9be2c63cbeaa349f778b2fb87")
    }
}
