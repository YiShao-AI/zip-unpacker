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

    func testSavingFavoritesLeavesTheRestBehind() throws {
        let keep = try make("Batch a/one/keep.mp4")
        let other = try make("Batch a/one/other.mp4")
        try Favorites.set(true, keep)
        let target = root.appendingPathComponent("Batch Favorites")
        XCTAssertEqual(try FolderOps.saveFavorites(in: root.appendingPathComponent("Batch a"), to: target), 1)
        let saved = target.appendingPathComponent("one/keep.mp4")
        XCTAssertTrue(Favorites.isFavorite(saved))
        XCTAssertEqual(try String(contentsOf: saved), "Batch a/one/keep.mp4")
        XCTAssertFalse(fm.fileExists(atPath: keep.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }

    func testSameNameFromTwoBatchesBothSurvive() throws {
        let a = try make("Batch a/one/video.mp4"), b = try make("Batch b/one/video.mp4")
        try Favorites.set(true, a)
        try Favorites.set(true, b)
        let target = root.appendingPathComponent("Batch Favorites")
        try FolderOps.saveFavorites(in: root.appendingPathComponent("Batch a"), to: target)
        try FolderOps.saveFavorites(in: root.appendingPathComponent("Batch b"), to: target)
        let saved = Unpacker.files(in: target)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(try saved.map { try String(contentsOf: $0) }), ["Batch a/one/video.mp4", "Batch b/one/video.mp4"])
        XCTAssertTrue(saved.allSatisfy(Favorites.isFavorite))
    }

    func testLooseFavoriteGoesStraightIn() throws {
        let f = try make("Batch a/video.mp4")
        try Favorites.set(true, f)
        let target = root.appendingPathComponent("Batch Favorites")
        try FolderOps.saveFavorites(in: root.appendingPathComponent("Batch a"), to: target)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("video.mp4").path))
    }

    func testNoFavoritesMakesNoFolder() throws {
        _ = try make("Batch a/one/video.mp4")
        let target = root.appendingPathComponent("Batch Favorites")
        XCTAssertEqual(try FolderOps.saveFavorites(in: root.appendingPathComponent("Batch a"), to: target), 0)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func testAFavoriteThatCantMoveStaysPutAndThrows() throws {
        let f = try make("Batch a/one/video.mp4")
        try Favorites.set(true, f)
        let blocked = try make("Batch Favorites")   // a file where the folder should go
        XCTAssertThrowsError(try FolderOps.saveFavorites(in: root.appendingPathComponent("Batch a"), to: blocked))
        XCTAssertTrue(Favorites.isFavorite(f))
    }

    func testDeletedFileLeavesNoStarBehind() throws {
        let f = try make("Batch a/one/video.mp4")
        try Favorites.set(true, f)
        try fm.removeItem(at: f)
        XCTAssertFalse(Favorites.isFavorite(try make("Batch a/one/video.mp4")))
    }
}
