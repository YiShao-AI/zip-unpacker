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
