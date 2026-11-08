import XCTest

final class ImportSelectionTests: XCTestCase {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/import-tests/" + $0) }
    }

    func testShiftRangeIncludesBothEndsInEitherDirection() {
        let u = urls(["a.nef", "b.nef", "c.nef", "d.nef"])
        XCTAssertEqual(ImportSelection.range(in: u, anchor: u[1], end: u[3]), Set(u[1...3]))
        XCTAssertEqual(ImportSelection.range(in: u, anchor: u[3], end: u[1]), Set(u[1...3]))
        XCTAssertEqual(ImportSelection.range(in: u, anchor: nil, end: u[2]), [u[2]])
        XCTAssertEqual(ImportSelection.range(in: [u[0], u[3]], anchor: u[1], end: u[3]), [u[3]])
        XCTAssertTrue(ImportSelection.range(in: [], anchor: u[0], end: u[1]).isEmpty)
    }

    func testRAWPairSuppressionRetainsUnpairedJPEGAndOtherFormats() {
        let u = urls(["DJI_01.DNG", "DJI_01.JPG", "dji_01.jpeg", "alone.JPG", "DJI_01.tif", "other.ARW"])
        XCTAssertEqual(ImportSelection.removingPairedJPEGs(u, rawExtensions: ["dng", "arw"]), [u[0], u[3], u[4], u[5]])
        let otherFolder = URL(fileURLWithPath: "/tmp/elsewhere/DJI_01.JPG")
        XCTAssertEqual(ImportSelection.removingPairedJPEGs([u[0], otherFolder], rawExtensions: ["dng"]), [u[0], otherFolder])
    }

    func testRatingAndCheckedFiltersPreserveVisibleOrder() {
        let u = urls(["a.nef", "b.nef", "c.nef"])
        let ratings = [u[0]: 2, u[1]: 5]
        XCTAssertEqual(ImportSelection.filtered(u, checked: [], ratings: ratings), u)
        XCTAssertEqual(ImportSelection.filtered(u, minimumRating: 3, checked: [], ratings: ratings), [u[1]])
        XCTAssertEqual(ImportSelection.filtered(u, checkedOnly: true, checked: [u[2], u[0]], ratings: ratings), [u[0], u[2]])
        XCTAssertEqual(ImportSelection.filtered(u, minimumRating: 3, checkedOnly: true, checked: [u[0]], ratings: ratings), [])
    }

    func testImportOrderUsesFilenamesAndContainsOnlyCheckedPhotos() {
        let u = urls(["frame10.nef", "frame2.nef", "frame1.nef"])
        XCTAssertEqual(ImportSelection.importURLs(Set(u)), [u[2], u[1], u[0]])
        XCTAssertEqual(ImportSelection.importURLs([u[1]]), [u[1]])
        XCTAssertTrue(ImportSelection.importURLs([]).isEmpty)
    }

    func testSuspectedDuplicatesWithinTheFolderAndAgainstKnownFrames() {
        let u = urls(["a.nef", "a copy.nef", "b.nef", "c.nef", "d.nef"])
        let x = ImportSelection.Fingerprint(size: 10, headDigest: "x")
        let y = ImportSelection.Fingerprint(size: 10, headDigest: "y")
        let z = ImportSelection.Fingerprint(size: 20, headDigest: "x")
        let prints = [u[0]: x, u[1]: x, u[2]: y, u[3]: z]   // d has no fingerprint (unreadable)
        let known: [ImportSelection.Fingerprint: [String]] = [
            y: ["/Volumes/Archive/2026/b.nef"],
            // Its own path (a folder opened again) and a sibling already listed
            // are not "elsewhere".
            z: [u[3].path, u[0].path],
        ]
        let found = ImportSelection.suspectedDuplicates(u, fingerprints: prints) { known[$0] ?? [] }
        XCTAssertEqual(found, [u[1]: u[0].path, u[2]: "/Volumes/Archive/2026/b.nef"])
    }

    func testHiddenDuplicatesLeaveTheFilteredList() {
        let u = urls(["a.nef", "b.nef"])
        XCTAssertEqual(ImportSelection.filtered(u, checked: [], ratings: [:], hiding: [u[1]]), [u[0]])
        XCTAssertEqual(ImportSelection.filtered(u, checked: [], ratings: [:]), u)
    }

    func testFingerprintIsSizePlusHeadDigest() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "a.nef"), b = dir.appending(path: "b.nef"), c = dir.appending(path: "c.nef")
        try Data("same".utf8).write(to: a)
        try Data("same".utf8).write(to: b)
        try Data("diff".utf8).write(to: c)
        XCTAssertEqual(ImportSelection.Fingerprint.of(a), ImportSelection.Fingerprint.of(b))
        XCTAssertNotEqual(ImportSelection.Fingerprint.of(a), ImportSelection.Fingerprint.of(c))
        XCTAssertNil(ImportSelection.Fingerprint.of(dir.appending(path: "missing.nef")))
    }
}
