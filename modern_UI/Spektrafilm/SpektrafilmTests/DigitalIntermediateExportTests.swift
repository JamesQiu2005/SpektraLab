//  DigitalIntermediateExportTests.swift — RFC-028, the file a DI export writes.
//
//  A real frame on a paper, exported with the Digital Intermediate recipe:
//  the DI comes out whatever paper is chosen, as the Cineon master — untagged
//  (a profile would make viewers "correct" the codes), the film base on Cineon
//  black, the two view LUTs beside it, a mid-range median. The same frame on
//  the DI, exported as an ordinary TIFF, is its *view*: tagged, like a print.

import ImageIO
import XCTest

@MainActor
final class DigitalIntermediateExportTests: XCTestCase {

    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-di-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func waitUntil(_ what: String, timeout: Double = 240,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testADIExportIsTheCineonMasterWithItsLUTsBeside() async throws {
        let url = try frame()
        let folder = url.deletingLastPathComponent().appending(path: "out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { session.serviceReady }
        var p = session.params
        p.filmStock = "kodak_portra_400"
        session.params = p
        XCTAssertFalse(session.digitalIntermediateActive, "the frame starts on a paper")
        session.solveNow()
        try await waitUntil("the print to land", timeout: 240) {
            session.serviceSessionIDForExport != nil
                && session.frameStates[url] == .processed && !session.busy
        }

        var recipe = ExportRecipe()
        recipe.format = .di
        recipe.folder = .fixed(path: folder.path)
        recipe.subfolder = ""
        recipe.colorSpace = .displayP3
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: CGSize(width: 6000, height: 4000), counter: 1, date: Date())
        let outcome = try await Exporter.export(
            session: session, recipe: recipe, context: context,
            sessionID: try XCTUnwrap(session.serviceSessionIDForExport))
        guard case .wrote(let files, let note, _) = outcome, let file = files.first else {
            return XCTFail("the export wrote nothing: \(outcome)")
        }

        // The two LUTs, beside it, once.
        for target in CineonLUT.Target.allCases {
            let lut = file.deletingLastPathComponent().appending(path: target.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: lut.path), "\(target.fileName) is missing")
        }
        XCTAssertTrue(note?.contains("Cineon") ?? false, "the export page should say what it wrote")
        XCTAssertTrue(file.lastPathComponent.hasSuffix("_DI.tif"), file.lastPathComponent)

        // Untagged, 16 bits.
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertNil(props?[kCGImagePropertyProfileName], "a Cineon master must not carry a display profile")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)

        // The codes: nothing below the film base, and the picture's median in
        // Cineon's mid range (grey ~467), decoding to a mid-tone positive.
        let w = 64, h = 64
        var px = [UInt16](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 16,
                                          bytesPerRow: w * 8, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder16Little.rawValue))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let greens = stride(from: 1, to: px.count, by: 4).map { Double(px[$0]) / 65535 * 1023 }.sorted()
        XCTAssertGreaterThanOrEqual(greens.first!, 94, "a code below the film base")
        let median = greens[greens.count / 2]
        XCTAssertTrue((250...700).contains(median), "median code \(median) is not a picture's middle")
        let decoded = CineonLUT.decode(median / 1023)
        XCTAssertTrue((0.005...1.0).contains(decoded), "median decodes to \(decoded)")
    }

    func testADIFrameExportsItsViewLikeAPrint() async throws {
        let url = try frame()
        let folder = url.deletingLastPathComponent().appending(path: "view")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { session.serviceReady }
        session.selectDigitalIntermediate()
        XCTAssertTrue(session.digitalIntermediateActive)
        session.solveNow()
        try await waitUntil("the DI to land", timeout: 240) {
            session.serviceSessionIDForExport != nil
                && session.frameStates[url] == .processed && !session.busy
        }
        var recipe = ExportRecipe()
        recipe.format = .tiff
        recipe.folder = .fixed(path: folder.path)
        recipe.subfolder = ""
        recipe.colorSpace = .displayP3
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: CGSize(width: 6000, height: 4000), counter: 1, date: Date())
        let outcome = try await Exporter.export(
            session: session, recipe: recipe, context: context,
            sessionID: try XCTUnwrap(session.serviceSessionIDForExport))
        guard case .wrote(let files, _, _) = outcome, let file = files.first else {
            return XCTFail("the export wrote nothing: \(outcome)")
        }
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyProfileName] as? String, "Display P3",
                       "the view is a picture, and goes out in the recipe's space")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appending(path: CineonLUT.Target.proPhoto.fileName).path),
            "a view export is a print; it carries no LUTs")
    }
}
