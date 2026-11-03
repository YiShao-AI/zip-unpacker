import XCTest
@testable import UnpackCore

final class FolderOpsTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("folderops-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    /// Creates files (with their own path as contents) under `root`.
    func make(_ paths: [String]) throws {
        for p in paths {
            let u = root.appendingPathComponent(p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(p.utf8).write(to: u)
        }
    }

    /// Every file under `dir`, relative, with its contents.
    func tree(_ dir: String) -> [String: String] {
        let base = root.appendingPathComponent(dir)
        var out: [String: String] = [:]
        for f in Unpacker.files(in: base) {
            let rel = f.standardizedFileURL.resolvingSymlinksInPath().path
                .replacingOccurrences(of: base.standardizedFileURL.resolvingSymlinksInPath().path + "/", with: "")
            out[rel] = (try? String(contentsOf: f)) ?? "?"
        }
        return out
    }

    func url(_ p: String) -> URL { root.appendingPathComponent(p) }

    func testMoveFileIntoFolderKeepsNameAndAvoidsClash() throws {
        try make(["A/x/v.mp4", "B/x/v.mp4"])
        let moved = try FolderOps.transfer(url("A/x/v.mp4"), into: url("B/x"), move: true)
        XCTAssertEqual(moved.lastPathComponent, "v 2.mp4")
        XCTAssertEqual(tree("B"), ["x/v.mp4": "B/x/v.mp4", "x/v 2.mp4": "A/x/v.mp4"])
        XCTAssertFalse(fm.fileExists(atPath: url("A/x/v.mp4").path))
    }

    func testCopyLeavesSource() throws {
        try make(["A/x/v.mp4"])
        try FolderOps.transfer(url("A/x"), into: url("B"), move: false)
        XCTAssertEqual(tree("A"), ["x/v.mp4": "A/x/v.mp4"])
        XCTAssertEqual(tree("B"), ["x/v.mp4": "A/x/v.mp4"])
    }

    func testSameNamedFoldersMerge() throws {
        try make(["A/7月13日/1.mp4", "A/7月13日/2.mp4", "B/7月13日/2.mp4", "B/other/o.mp4"])
        try FolderOps.transfer(url("A/7月13日"), into: url("B"), move: true)
        XCTAssertEqual(tree("B"), ["7月13日/1.mp4": "A/7月13日/1.mp4", "7月13日/2.mp4": "B/7月13日/2.mp4",
                                   "7月13日/2 2.mp4": "A/7月13日/2.mp4", "other/o.mp4": "B/other/o.mp4"])
        XCTAssertFalse(fm.fileExists(atPath: url("A/7月13日").path))
    }

    func testCannotMoveFolderIntoItself() throws {
        try make(["A/x/v.mp4"])
        XCTAssertThrowsError(try FolderOps.transfer(url("A/x"), into: url("A/x/sub"), move: true)) {
            XCTAssertEqual($0 as? FolderOps.OpsError, .intoItself("x"))
        }
        XCTAssertEqual(tree("A"), ["x/v.mp4": "A/x/v.mp4"])
    }

    func testMoveIntoOwnParentIsNoOp() throws {
        try make(["A/x/v.mp4"])
        let r = try FolderOps.transfer(url("A/x/v.mp4"), into: url("A/x"), move: true)
        XCTAssertEqual(r.lastPathComponent, "v.mp4")
        XCTAssertEqual(tree("A"), ["x/v.mp4": "A/x/v.mp4"])
    }

    func testMergeBatchesMovesAndRemovesSources() throws {
        try make(["Batch 1/a/1.mp4", "Batch 2/a/1.mp4", "Batch 2/b/2.mp4", "Batch 3/c.mp4"])
        try FolderOps.merge([url("Batch 1"), url("Batch 2"), url("Batch 3")], into: url("Batch merged"), move: true)
        XCTAssertEqual(tree("Batch merged"), ["a/1.mp4": "Batch 1/a/1.mp4", "a/1 2.mp4": "Batch 2/a/1.mp4",
                                              "b/2.mp4": "Batch 2/b/2.mp4", "c.mp4": "Batch 3/c.mp4"])
        for b in ["Batch 1", "Batch 2", "Batch 3"] { XCTAssertFalse(fm.fileExists(atPath: url(b).path)) }
    }

    func testMergeCopyKeepsSources() throws {
        try make(["Batch 1/a/1.mp4", "Batch 2/b/2.mp4"])
        try FolderOps.merge([url("Batch 1"), url("Batch 2")], into: url("Batch merged"), move: false)
        XCTAssertEqual(tree("Batch merged").count, 2)
        XCTAssertEqual(tree("Batch 1"), ["a/1.mp4": "Batch 1/a/1.mp4"])
    }

    func testRenameAndCreateAndCleanUp() throws {
        try make(["A/x/v.mp4", "A/empty/.hidden"])
        let renamed = try FolderOps.rename(url("A/x"), to: "7月13日 / 舞蹈")
        XCTAssertEqual(renamed.lastPathComponent, "7月13日 _ 舞蹈")
        let made = try FolderOps.createFolder(named: "New", in: url("A"))
        XCTAssertEqual(made.lastPathComponent, "New")
        XCTAssertEqual(try FolderOps.createFolder(named: "New", in: url("A")).lastPathComponent, "New 2")
        XCTAssertThrowsError(try FolderOps.createFolder(named: "  ", in: url("A")))
        XCTAssertThrowsError(try FolderOps.rename(url("A/New"), to: ".."))
        FolderOps.removeEmptyFolders(in: url("A"))
        XCTAssertEqual(FolderOps.contents(url("A")).map(\.lastPathComponent).sorted(), ["7月13日 _ 舞蹈"])
    }
}
