//  RatingsCatalogTests.swift — a rating belongs to a file, not to a name.
//
//  The cases PR #83's review raised against the JSON table, each as a test:
//  a rename keeps the rating, a new file at an old name does not inherit it,
//  a copy is its own frame, and a damaged catalog is set aside rather than
//  written over. Each test gets its own store, so no case sees another's rows.

import XCTest

@MainActor
final class RatingsCatalogTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-ratings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = Sidecar.storeDirectory
        Sidecar.useStore(at: dir.appending(path: "store/Sidecars"))
        Ratings.reload()
        let dir = dir!
        addTeardownBlock { @MainActor in
            Sidecar.useStore(at: previous)
            Ratings.reload()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func photo(_ name: String, bytes: String? = nil) throws -> URL {
        let url = dir.appending(path: name)
        try Data((bytes ?? UUID().uuidString).utf8).write(to: url)
        return url
    }

    func testRatingIsStoredInTheCatalogAndZeroClears() throws {
        let a = try photo("a.NEF")
        Ratings.set(4, for: a)
        XCTAssertEqual(Ratings.rating(for: a), 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Ratings.fileURL.path))
        // A fresh connection reads what the first one wrote.
        Ratings.reload()
        XCTAssertEqual(Ratings.rating(for: a), 4)
        Ratings.set(0, for: a)
        Ratings.reload()
        XCTAssertEqual(Ratings.rating(for: a), 0)
        Ratings.set(9, for: a)
        XCTAssertEqual(Ratings.rating(for: a), 5, "out of range is clamped")
    }

    func testRenameKeepsTheRating() throws {
        let a = try photo("a.NEF")
        Ratings.set(3, for: a)
        let renamed = dir.appending(path: "renamed.NEF")
        try FileManager.default.moveItem(at: a, to: renamed)
        Ratings.forgetLookups()
        XCTAssertEqual(Ratings.rating(for: renamed), 3)
        XCTAssertEqual(Ratings.rating(for: a), 0)
    }

    func testMoveToAnotherFolderOnTheSameDiskKeepsTheRating() throws {
        let a = try photo("a.NEF")
        Ratings.set(2, for: a)
        let sub = dir.appending(path: "2026-11 shoot")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appending(path: "a.NEF")
        try FileManager.default.moveItem(at: a, to: moved)
        Ratings.forgetLookups()
        XCTAssertEqual(Ratings.rating(for: moved), 2)
    }

    func testANewFileAtAnOldNameDoesNotInheritTheRating() throws {
        let a = try photo("a.NEF")
        Ratings.set(5, for: a)
        try FileManager.default.moveItem(at: a, to: dir.appending(path: "kept.NEF"))
        _ = try photo("a.NEF")
        Ratings.forgetLookups()
        XCTAssertEqual(Ratings.rating(for: a), 0)
        XCTAssertEqual(Ratings.rating(for: dir.appending(path: "kept.NEF")), 5)
    }

    func testARenameSwapMovesBothRatings() throws {
        let a = try photo("a.NEF"), b = try photo("b.NEF")
        Ratings.set(5, for: a)
        Ratings.set(1, for: b)
        let tmp = dir.appending(path: "swap.tmp")
        try FileManager.default.moveItem(at: a, to: tmp)
        try FileManager.default.moveItem(at: b, to: a)
        try FileManager.default.moveItem(at: tmp, to: b)
        Ratings.forgetLookups()
        XCTAssertEqual(Ratings.rating(for: a), 1)
        XCTAssertEqual(Ratings.rating(for: b), 5)
    }

    func testACopyIsItsOwnFrame() throws {
        let a = try photo("a.NEF", bytes: "same bytes")
        Ratings.set(4, for: a)
        let copy = dir.appending(path: "a copy.NEF")
        try FileManager.default.copyItem(at: a, to: copy)
        XCTAssertEqual(Ratings.rating(for: copy), 0)
        Ratings.set(1, for: copy)
        XCTAssertEqual(Ratings.rating(for: a), 4)
        XCTAssertEqual(Ratings.rating(for: copy), 1)
        // …but the import culler can still tell they are the same bytes.
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: a.path)[.size] as? Int)
        let digest = try XCTUnwrap(Sidecar.identity(of: a).headDigest)
        XCTAssertEqual(Set(Ratings.knownCopies(size: size, headDigest: digest)),
                       [a.standardizedFileURL.path, copy.standardizedFileURL.path])
    }

    func testDeletedThenAnIdenticalFileAddedStartsUnrated() throws {
        let a = try photo("a.NEF", bytes: "fixture")
        Ratings.set(3, for: a)
        try FileManager.default.removeItem(at: a)
        let again = try photo("b.NEF", bytes: "fixture")
        Ratings.forgetLookups()
        XCTAssertEqual(Ratings.rating(for: again), 0)
    }

    func testADamagedCatalogIsSetAsideNotOverwritten() throws {
        let garbage = Data("not a database".utf8)
        try FileManager.default.createDirectory(at: Ratings.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try garbage.write(to: Ratings.fileURL)
        Ratings.reload()
        let a = try photo("a.NEF")
        Ratings.set(2, for: a)
        XCTAssertEqual(Ratings.rating(for: a), 2)
        let parent = Ratings.fileURL.deletingLastPathComponent()
        let kept = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix("Catalog.sqlite.unreadable-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: parent.appending(path: kept[0])), garbage)
    }

    func testRatingOneFrameNeverTouchesAnother() throws {
        let urls = try (0..<20).map { try photo("f\($0).NEF") }
        for (i, url) in urls.enumerated() { Ratings.set(i % 5 + 1, for: url) }
        Ratings.set(0, for: urls[7])
        Ratings.reload()
        XCTAssertEqual(urls.map { Ratings.rating(for: $0) },
                       urls.indices.map { $0 == 7 ? 0 : $0 % 5 + 1 })
    }

    func testARatedFrameIsNotEdited() throws {
        let a = try photo("a.NEF")
        Ratings.set(5, for: a)
        XCTAssertNil(Sidecar.load(for: a))
    }
}
