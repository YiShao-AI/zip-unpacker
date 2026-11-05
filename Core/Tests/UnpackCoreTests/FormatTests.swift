import XCTest
@testable import UnpackCore

/// Everything 7-Zip handles for us. Fixtures: scripts/make_format_fixtures.py (password test-pw) and
/// libarchive's RAR samples (password "password"), in Fixtures/formats.
final class FormatTests: XCTestCase {
    var out: URL!

    override func setUpWithError() throws {
        out = FileManager.default.temporaryDirectory.appendingPathComponent("formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: out) }

    func fx(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/formats"), name)
    }

    func unpack(_ name: String, _ passwords: [String] = ["test-pw"]) throws -> UnpackReport {
        try Unpacker(passwords: passwords).unpack(fx(name), into: out.appendingPathComponent(UUID().uuidString))
    }

    func names(_ r: UnpackReport) -> [String] { r.files.map(\.lastPathComponent).sorted() }

    /// The payload every fixture holds: a Chinese-named folder with a text file and a 32 KB "video".
    func assertPayload(_ r: UnpackReport, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let clip = try Data(contentsOf: fx("clip.bin"))
        let video = r.files.first { $0.lastPathComponent == "clip (1).mp4" }
        XCTAssertNotNil(video, "\(label): \(names(r))", file: file, line: line)
        if let v = video { XCTAssertEqual(try Data(contentsOf: v), clip, label, file: file, line: line) }
        XCTAssertTrue(r.files.contains { $0.lastPathComponent == "说明.txt" && $0.path.contains("7月17日舞蹈") },
                      "\(label): \(names(r))", file: file, line: line)
        XCTAssertTrue(r.files.contains { $0.lastPathComponent == "readme.txt" }, label, file: file, line: line)
    }

    func testEngineIsLinked() {
        XCTAssertEqual(SupportedFormats.engineMissing, [])
        XCTAssertTrue(SupportedFormats.names.contains("7z"))
    }

    func testDetect() throws {
        let expect: [(String, ArchiveKind)] = [
            ("plain.7z", .engine("7z")), ("rar4.rar", .engine("Rar")), ("rar5.rar", .engine("Rar5")),
            ("a.tar", .engine("tar")), ("a.tar.gz", .engine("gzip")), ("a.tar.bz2", .engine("bzip2")),
            ("a.tar.xz", .engine("xz")), ("a.tar.zst", .engine("zstd")), ("one.mp4.lzma", .engine("lzma")),
            ("bzip2.zip", .zip), ("clip.bin", .other),
        ]
        for (n, k) in expect { XCTAssertEqual(ArchiveKind.detect(try fx(n)), k, n) }
    }

    func test7z() throws {
        for n in ["plain.7z", "enc.7z", "enchdr.7z"] { try assertPayload(try unpack(n), n) }
    }

    func test7zPasswords() throws {
        XCTAssertThrowsError(try unpack("enc.7z", [])) { XCTAssertEqual($0 as? UnpackError, .passwordRequired) }
        XCTAssertThrowsError(try unpack("enc.7z", ["nope"])) { XCTAssertEqual($0 as? UnpackError, .wrongPassword) }
        XCTAssertThrowsError(try unpack("enchdr.7z", ["nope"])) { XCTAssertEqual($0 as? UnpackError, .wrongPassword) }
        XCTAssertThrowsError(try unpack("enchdr.7z", [])) { XCTAssertEqual($0 as? UnpackError, .passwordRequired) }
        try assertPayload(try unpack("enc.7z", ["nope", "test-pw"]), "second password")
    }

    func testTarFamily() throws {
        for n in ["a.tar", "a.tar.gz", "a.tar.bz2", "a.tar.xz", "a.tar.zst"] {
            let r = try unpack(n, [])
            try assertPayload(r, n)
            XCTAssertFalse(r.files.contains { $0.pathExtension == "tar" }, "\(n): tar left behind \(names(r))")
        }
    }

    func testSingleStreams() throws {
        let clip = try Data(contentsOf: fx("clip.bin"))
        for n in ["one.mp4.gz", "one.mp4.bz2", "one.mp4.xz", "one.mp4.lzma", "one.mp4.zst"] {
            let r = try unpack(n, [])
            XCTAssertEqual(names(r), ["one.mp4"], n)
            XCTAssertEqual(try Data(contentsOf: r.files[0]), clip, n)
        }
    }

    /// Zip methods the built-in reader doesn't have go through 7-Zip's zip handler.
    func testZipOtherMethods() throws {
        for n in ["bzip2.zip", "lzma.zip"] { try assertPayload(try unpack(n, []), n) }
    }

    func testRar() throws {
        XCTAssertTrue(names(try unpack("rar4.rar", [])).contains("test.txt"))
        XCTAssertEqual(names(try unpack("rar5.rar", [])), ["test.bin"])
        XCTAssertEqual(names(try unpack("rar5-encnames.rar", ["password"])), ["a.txt", "b.txt", "c.txt", "d.txt"])
        XCTAssertThrowsError(try unpack("rar5-encnames.rar", ["x"])) { XCTAssertEqual($0 as? UnpackError, .wrongPassword) }
        XCTAssertThrowsError(try unpack("rar5-encnames.rar", [])) { XCTAssertEqual($0 as? UnpackError, .passwordRequired) }
    }

    func testRarMultiVolume() throws {
        let n = names(try unpack("multi.part01.rar", []))
        XCTAssertTrue(n.contains("bsdtar_test") && n.contains("bsdcat_test"), "\(n)")
    }

    func testRarMissingVolumeNamesThePart() throws {
        let dir = out.appendingPathComponent("vols")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 1...4 { try FileManager.default.copyItem(at: fx("multi.part0\(i).rar"), to: dir.appendingPathComponent("multi.part0\(i).rar")) }
        XCTAssertThrowsError(try Unpacker(passwords: []).unpack(dir.appendingPathComponent("multi.part01.rar"), into: out.appendingPathComponent("o"))) {
            guard case .missingPart(let why)? = $0 as? UnpackError else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("part05"), why)
        }
    }

    func testVolumeRoles() {
        let s: Set<String> = ["x.part1.rar", "x.part2.rar", "y.rar", "y.r00", "z.zip", "z.z01", "plain.rar"]
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/x.part1.rar"), siblings: s), .first)
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/x.part2.rar"), siblings: s), .later)
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/y.rar"), siblings: s), .first)
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/y.r00"), siblings: s), .later)
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/z.zip"), siblings: s), .first)
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/z.z01"), siblings: s), .later)
        XCTAssertEqual(Volumes.role(URL(fileURLWithPath: "/d/plain.rar"), siblings: s), .none)
        XCTAssertEqual(Unpacker.folderName(for: "x.part1.rar"), "x")
        XCTAssertEqual(Unpacker.folderName(for: "a.tar.gz"), "a")
        XCTAssertEqual(Unpacker.folderName(for: "10.11.zip"), "10.11")
        XCTAssertEqual(Unpacker.folderName(for: "dance.7z.001"), "dance")
    }

    func testNested7zInZip() throws {
        let r = try unpack("zip-with-7z.zip")
        try assertPayload(r, "7z in zip")
        XCTAssertGreaterThanOrEqual(r.layers, 2)
    }

    func testNestedSplit7zInZip() throws {
        try assertPayload(try unpack("zip-with-split7z.zip"), "split 7z in zip")
    }

    func testFolderWithSplit7zAndRar() throws {
        let src = out.appendingPathComponent("Imported")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for n in ["split.7z.001", "split.7z.002", "rar5.rar"] {
            try FileManager.default.copyItem(at: fx(n), to: src.appendingPathComponent(n))
        }
        try Data("keep me".utf8).write(to: src.appendingPathComponent("notes.txt"))
        let r = try Unpacker(passwords: ["test-pw"]).unpack(src, into: out.appendingPathComponent("o"))
        try assertPayload(r, "folder")
        XCTAssertTrue(names(r).contains("test.bin") && names(r).contains("notes.txt"), "\(names(r))")
        XCTAssertFalse(names(r).contains { $0.hasSuffix(".001") || $0.hasSuffix(".rar") }, "\(names(r))")
        XCTAssertEqual(r.failedInside, [])
    }

    func testSplit7zLengthCheck() throws {
        let a = try fx("split.7z.001"), b = try fx("split.7z.002")
        XCTAssertEqual(SplitArchive.sets(in: [a, b])[0].state, .complete)
        XCTAssertEqual(SplitArchive.sets(in: [a])[0].state, .needsMore(after: 1))
    }
}
