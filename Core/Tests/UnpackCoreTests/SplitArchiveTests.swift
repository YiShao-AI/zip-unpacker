import XCTest
@testable import UnpackCore

final class SplitArchiveTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("split-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    /// Cuts `data` into `count` slices named `base.001`…; the last slice can be tiny.
    @discardableResult
    func split(_ data: Data, base: String, sizes: [Int]) throws -> [URL] {
        var urls: [URL] = [], offset = 0
        for (i, size) in sizes.enumerated() {
            let end = i == sizes.count - 1 ? data.count : offset + size
            let url = dir.appendingPathComponent(base + String(format: ".%03d", i + 1))
            try data.subdata(in: offset..<end).write(to: url)
            urls.append(url)
            offset = end
        }
        return urls
    }

    func testPartNames() {
        XCTAssertEqual(SplitArchive.part(URL(fileURLWithPath: "/a/10.9跳着.zip.011"))?.base, "10.9跳着.zip")
        XCTAssertEqual(SplitArchive.part(URL(fileURLWithPath: "/a/x.zip.011"))?.number, 11)
        XCTAssertNil(SplitArchive.part(URL(fileURLWithPath: "/a/x.zip")))
        XCTAssertNil(SplitArchive.part(URL(fileURLWithPath: "/a/x.01")))
        XCTAssertNil(SplitArchive.part(URL(fileURLWithPath: "/a/.001")))
    }

    func testCompleteSetJoinsAndUnpacks() throws {
        let data = try Data(contentsOf: fixture("nested.pdf"))
        let parts = try split(data, base: "dance.zip", sizes: [data.count / 3, data.count / 3, 0])
        let other = dir.appendingPathComponent("loose.pdf")
        try data.write(to: other)

        let sets = SplitArchive.sets(in: (parts + [other]).shuffled())
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].name, "dance.zip")
        XCTAssertEqual(sets[0].parts, parts)
        XCTAssertEqual(sets[0].state, .complete)

        let joined = dir.appendingPathComponent("dance.zip")
        try SplitArchive.join(sets[0].parts, to: joined)
        XCTAssertEqual(try Data(contentsOf: joined), data)

        let out = dir.appendingPathComponent("out")
        let report = try Unpacker(passwords: ["test-pw"]).unpack(joined, into: out)
        XCTAssertFalse(report.files.isEmpty)
    }

    func testTinyLastPartStillComplete() throws {
        let data = try Data(contentsOf: fixture("plain.zip"))
        try split(data, base: "p.zip", sizes: [data.count - 5, 5])
        XCTAssertEqual(SplitArchive.sets(in: Unpacker.files(in: dir))[0].state, .complete)
    }

    func testMissingAndUnfinishedSets() throws {
        let data = try Data(contentsOf: fixture("nested.pdf"))
        let parts = try split(data, base: "a.zip", sizes: [data.count / 4, data.count / 4, data.count / 4, 0])

        try FileManager.default.removeItem(at: parts[1])
        var set = SplitArchive.sets(in: Unpacker.files(in: dir))[0]
        XCTAssertEqual(set.state, .missing([2]))
        XCTAssertNotNil(SplitArchive.message(for: set))

        try data.subdata(in: data.count / 4..<data.count / 2).write(to: parts[1])
        try FileManager.default.removeItem(at: parts[3])
        set = SplitArchive.sets(in: Unpacker.files(in: dir))[0]
        XCTAssertEqual(set.state, .needsMore(after: 3))
    }

    func testNonZipSetIsLeftAlone() throws {
        let data = try Data(contentsOf: fixture("fake7z.pdf"))
        try split(data, base: "b.7z", sizes: [data.count / 2, 0])
        XCTAssertEqual(SplitArchive.sets(in: Unpacker.files(in: dir))[0].state, .notZip)
    }
}

extension SplitArchiveTests {
    /// Writes a stored, unencrypted zip holding `files` (name → data). Enough for the reader under test.
    func storedZip(_ files: [(String, Data)], to url: URL) throws {
        var out = Data(), central = Data()
        func put16(_ d: inout Data, _ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func put32(_ d: inout Data, _ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        for (name, data) in files {
            let n = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            let size = UInt32(data.count)
            put32(&out, 0x04034b50)
            for v in [20, 0x800, 0, 0, 0] { put16(&out, v) }
            put32(&out, crc); put32(&out, size); put32(&out, size)
            put16(&out, n.count); put16(&out, 0)
            out.append(n); out.append(data)

            put32(&central, 0x02014b50)
            for v in [20, 20, 0x800, 0, 0, 0] { put16(&central, v) }
            put32(&central, crc); put32(&central, size); put32(&central, size)
            for v in [n.count, 0, 0, 0, 0] { put16(&central, v) }
            put32(&central, 0); put32(&central, offset)
            central.append(n)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        put32(&out, 0x06054b50)
        for v in [0, 0, files.count, files.count] { put16(&out, v) }
        put32(&out, UInt32(central.count)); put32(&out, cdOffset); put16(&out, 0)
        try out.write(to: url)
    }

    func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c >> 1) ^ (0xEDB88320 & (0 &- (c & 1))) }
        }
        return ~c
    }

    /// Real Baidu layout: an outer zip holding x.zip.001…003, which join into the encrypted inner zip.
    func testSplitPartsInsideAZipAreJoinedAndOpened() throws {
        let inner = try Data(contentsOf: fixture("nested.pdf"))
        let c = inner.count / 3
        let parts = [(0, c), (c, 2 * c), (2 * c, inner.count)].enumerated().map { i, r in
            ("dance/dance.zip." + String(format: "%03d", i + 1), inner.subdata(in: r.0..<r.1))
        }
        let outer = dir.appendingPathComponent("dance.zip")
        try storedZip(parts, to: outer)

        let out = dir.appendingPathComponent("out")
        let report = try Unpacker(passwords: ["test-pw"]).unpack(outer, into: out)
        let direct = try Unpacker(passwords: ["test-pw"]).unpack(fixture("nested.pdf"), into: dir.appendingPathComponent("direct"))
        XCTAssertEqual(Set(report.files.map(\.lastPathComponent)), Set(direct.files.map(\.lastPathComponent)))
        XCTAssertFalse(report.files.contains { SplitArchive.part($0) != nil })
        XCTAssertGreaterThan(report.layers, direct.layers)
    }

    func testSplitInsideAZipWithMissingPartFails() throws {
        let inner = try Data(contentsOf: fixture("nested.pdf"))
        let half = inner.count / 2
        let outer = dir.appendingPathComponent("broken.zip")
        try storedZip([("broken.zip.001", inner.subdata(in: 0..<half))], to: outer)
        XCTAssertThrowsError(try Unpacker(passwords: ["test-pw"]).unpack(outer, into: dir.appendingPathComponent("o")))
    }

    /// A folder keeps its structure: loose files are copied, zips and split sets inside are unpacked in place.
    func testFolderKeepsStructure() throws {
        let src = dir.appendingPathComponent("My folder")
        let sub = src.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("clip.mp4"))
        try FileManager.default.copyItem(at: fixture("nested.pdf"), to: sub.appendingPathComponent("a.pdf"))
        let inner = try Data(contentsOf: fixture("nested.pdf"))
        try inner.subdata(in: 0..<inner.count / 2).write(to: src.appendingPathComponent("b.zip.001"))
        try inner.subdata(in: inner.count / 2..<inner.count).write(to: src.appendingPathComponent("b.zip.002"))
        try Data("not a zip".utf8).write(to: src.appendingPathComponent("bad.zip"))

        let out = dir.appendingPathComponent("out")
        let report = try Unpacker(passwords: ["test-pw"]).unpack(src, into: out)
        XCTAssertEqual(report.folder.lastPathComponent, "My folder")
        let base = report.folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let names = report.files.map { $0.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "") }
        XCTAssertTrue(names.contains("clip.mp4"))
        XCTAssertTrue(names.contains("bad.zip"))
        XCTAssertTrue(names.contains { $0.hasPrefix("sub/a/") })
        XCTAssertTrue(names.contains { $0.hasPrefix("b/") })
        XCTAssertFalse(names.contains { $0.hasSuffix(".001") || $0 == "sub/a.pdf" })
        XCTAssertEqual(report.failedInside.count, 0, "bad.zip isn't a zip, so it is just copied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "the source folder is left alone")
    }
}
