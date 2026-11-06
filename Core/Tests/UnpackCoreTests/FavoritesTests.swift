import XCTest
@testable import UnpackCore

final class FavoritesTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("favorites-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func make(_ path: String) throws -> URL {
        let u = root.appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: u)
        return u
    }

    func testStarOnAndOff() throws {
        let f = try make("Batch a/7月13日舞蹈/7月13日舞蹈 (1).mp4")
        XCTAssertFalse(Favorites.isFavorite(f))
        try Favorites.set(true, f)
        try Favorites.set(true, f)
        XCTAssertTrue(Favorites.isFavorite(f))
        try Favorites.set(false, f)
        try Favorites.set(false, f)
        XCTAssertFalse(Favorites.isFavorite(f))
    }

    func testMissingFile() throws {
        let f = root.appendingPathComponent("gone.mp4")
        XCTAssertFalse(Favorites.isFavorite(f))
        XCTAssertThrowsError(try Favorites.set(true, f))
    }

    func testRenameKeepsStar() throws {
        let f = try make("Batch a/one/video.mp4")
        try Favorites.set(true, f)
        XCTAssertTrue(Favorites.isFavorite(try FolderOps.rename(f, to: "renamed.mp4")))
    }

    func testRenamingItsFolderKeepsStar() throws {
        let f = try make("Batch a/one/video.mp4")
        try Favorites.set(true, f)
        let folder = try FolderOps.rename(f.deletingLastPathComponent(), to: "two")
        XCTAssertTrue(Favorites.isFavorite(folder.appendingPathComponent("video.mp4")))
    }

    func testMoveKeepsStar() throws {
        let f = try make("Batch a/one/video.mp4")
        let target = root.appendingPathComponent("Batch b")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Favorites.set(true, f)
        XCTAssertTrue(Favorites.isFavorite(try FolderOps.transfer(f, into: target, move: true)))
    }

    func testSequentialRenameKeepsTheStarOnTheSameVideo() throws {
        let a = try make("Batch a/dance/a.mp4"), b = try make("Batch a/dance/b.mp4")
        try Favorites.set(true, b)
        let renamed = try Unpacker.renameSequentially([a, b], base: "dance")
        XCTAssertEqual(renamed.map(Favorites.isFavorite), [false, true])
    }

    func testMergeKeepsStar() throws {
        let f = try make("Batch a/one/video.mp4")
        _ = try make("Batch b/two/other.mp4")
        try Favorites.set(true, f)
        let merged = try FolderOps.merge([root.appendingPathComponent("Batch a"), root.appendingPathComponent("Batch b")],
                                         into: root.appendingPathComponent("Batch c"), move: true)
        let starred = Unpacker.files(in: merged).filter(Favorites.isFavorite).map(\.lastPathComponent)
        XCTAssertEqual(starred, ["video.mp4"])
    }

    func testDeletedFileLeavesNoStarBehind() throws {
        let f = try make("Batch a/one/video.mp4")
        try Favorites.set(true, f)
        try fm.removeItem(at: f)
        XCTAssertFalse(Favorites.isFavorite(try make("Batch a/one/video.mp4")))
    }
}
