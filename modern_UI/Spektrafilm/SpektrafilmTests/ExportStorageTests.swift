//  ExportStorageTests.swift — 1.3.6: the TIFF storage choice, the Fast recipe
//  an old recipe file is given once, and the page's file-size estimate.

import XCTest

@MainActor
final class ExportStorageTests: XCTestCase {
    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appending(path: "export-recipes.json")
    }

    func testAFreshStoreHasTheFastRecipeBesideTheLZWOne() throws {
        let store = ExportRecipeStore(url: try tempStoreURL())
        let tiffs = store.recipes.filter { $0.format == .tiff }
        XCTAssertEqual(tiffs.map(\.tiffCompression), [.lzw, .uncompressed])
        XCTAssertEqual(tiffs.last?.name, ExportRecipe.fastTIFFName)
    }

    /// A file written before 1.3.6 has no `tiffCompression` anywhere: its
    /// recipes keep LZW and it gains the Fast recipe, once.
    func testAnOldFileGainsTheFastRecipeOnceAndKeepsLZW() throws {
        let url = try tempStoreURL()
        let old = #"[{"name":"Mine","format":"TIFF 16-bit"},{"name":"Web","format":"JPEG"}]"#
        try Data(old.utf8).write(to: url)

        let first = ExportRecipeStore(url: url)
        XCTAssertEqual(first.recipes.map(\.name), ["Mine", ExportRecipe.fastTIFFName, "Web"])
        XCTAssertEqual(first.recipes[0].tiffCompression, .lzw)
        XCTAssertEqual(first.recipes[1].tiffCompression, .uncompressed)

        // Deleting it sticks: the file now carries the field.
        first.remove(first.recipes[1])
        let second = ExportRecipeStore(url: url)
        XCTAssertEqual(second.recipes.map(\.name), ["Mine", "Web"])
    }

    func testAFileThatAlreadyChoseStorageIsLeftAlone() throws {
        let url = try tempStoreURL()
        let new = #"[{"name":"Mine","format":"TIFF 16-bit","tiffCompression":5}]"#
        try Data(new.utf8).write(to: url)
        XCTAssertEqual(ExportRecipeStore(url: url).recipes.map(\.name), ["Mine"])
    }

    /// The uncompressed estimate is arithmetic; checked against the files
    /// measured on 2026-11-06 (6000×4000 ARW: 144,012,034 bytes, and
    /// 152,399,880 with the preview page).
    func testTheUncompressedEstimateMatchesMeasuredFiles() {
        var r = ExportRecipe.fastTIFF
        let px = CGSize(width: 6000, height: 4000)
        let plain = r.estimatedFileSize(pixels: px)
        XCTAssertTrue(plain.exact)
        XCTAssertEqual(Double(plain.bytes), 144_012_034, accuracy: 144_012_034 * 0.001)
        r.embedsPreview = true
        XCTAssertEqual(Double(r.estimatedFileSize(pixels: px).bytes), 152_399_880, accuracy: 152_399_880 * 0.001)
        // The DI always carries its preview.
        var di = r; di.format = .di; di.embedsPreview = false
        XCTAssertEqual(Double(di.estimatedFileSize(pixels: px).bytes), 152_399_300, accuracy: 152_399_300 * 0.001)
    }

    func testCompressedEstimatesAreApproximateAndOrdered() {
        let px = CGSize(width: 6000, height: 4000)
        var jpeg = ExportRecipe(format: .jpeg)
        var last = 0
        for q in stride(from: 0.3, through: 1.0, by: 0.05) {
            jpeg.quality = q
            let e = jpeg.estimatedFileSize(pixels: px)
            XCTAssertFalse(e.exact)
            XCTAssertGreaterThanOrEqual(e.bytes, last, "quality \(q)")
            last = e.bytes
        }
        let lzw = ExportRecipe(format: .tiff, tiffCompression: .lzw).estimatedFileSize(pixels: px)
        let fast = ExportRecipe.fastTIFF.estimatedFileSize(pixels: px)
        XCTAssertGreaterThan(lzw.bytes, fast.bytes, "measured: LZW is larger on a print with grain")
        XCTAssertEqual(ExportRecipe(format: .jpeg).estimatedFileSize(pixels: .zero).bytes, 0)
    }
}
