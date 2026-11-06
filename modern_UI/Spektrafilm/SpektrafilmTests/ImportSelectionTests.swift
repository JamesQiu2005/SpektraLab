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
}
