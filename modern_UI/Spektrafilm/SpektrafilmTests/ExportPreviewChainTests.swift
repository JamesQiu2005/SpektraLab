//  ExportPreviewChainTests.swift — the whole chain, end to end and for real.
//
//  `ExportPreviewTests` tests the reader against a TIFF the test made itself,
//  and the writer's own suite tests the writer against a recipe it made up.
//  Neither of them crosses: nothing had driven a **recipe's flag** through
//  `Exporter` into a **file on disk** and back through **the reader the page
//  uses**, which is the four lines that join them and the only link in this
//  feature that was ever unverified.
//
//  So this is the check the export page asked for in as many words — "one
//  export by hand against a TIFF recipe is the whole check, and I would rather
//  it were done than assumed" — done as a test rather than by hand, and for a
//  reason: a hand run would have to write a TIFF recipe into the user's real
//  `export-recipes.json`, and the app rewrites that file on every edit. A test
//  owns its own store URL the way `ExportRecipeStore(url:)` was built for.
//
//  Slower than the rest of the page's tests — it develops a 24 MP frame — and
//  it skips where the fixture is not checked out, like every other test that
//  needs one.

import CoreGraphics
import ImageIO
import XCTest

@MainActor
final class ExportPreviewChainTests: XCTestCase {

    /// The A7 III frame, copied out of the checkout: a develop writes a
    /// sidecar beside the frame it opens, and that copy is the reference
    /// tree's (`develop-writes-a-sidecar-copy-the-fixture`).
    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-preview-chain-\(UUID().uuidString)")
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

    /// A session with the frame open, developed, and a recipe that writes into
    /// a folder of this test's own.
    private func developedSession(folder: URL) async throws -> (Session, ExportRecipe, URL) {
        let url = try frame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { session.serviceReady }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 240) {
            session.serviceSessionIDForExport != nil
                && session.frameStates[url] == .processed && !session.busy
        }

        var recipe = ExportRecipe()
        recipe.format = .tiff
        recipe.folder = .fixed(path: folder.path)
        recipe.subfolder = ""
        recipe.colorSpace = .displayP3
        return (session, recipe, url)
    }

    /// The width of a file's first page — what an export actually wrote.
    private func pageCount(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(src)
    }

    private func centreColour(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        var px: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2,
                                   width: image.width, height: image.height))
        return (px[0], px[1], px[2])
    }

    /// **The check.** A TIFF recipe with the flag on writes a file with two
    /// pages, and the page the export page would read is the second one.
    func testATIFFRecipeAskingForAPreviewWritesAPageThePageCanRead() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "spk-preview-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let (session, base, url) = try await developedSession(folder: folder)
        var recipe = base
        recipe.embedsPreview = true
        XCTAssertTrue(recipe.format.carriesPreviewPage,
                      "the toggle the page shows is this rule, and it has to say yes to TIFF")

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

        // 1. The file has a second page.
        XCTAssertEqual(pageCount(file), 2,
                       "a TIFF recipe that asked for a preview did not get one")

        // 2. The page's reader finds it.
        let preview = try XCTUnwrap(ExportPage.embeddedPreview(of: file),
                                    "the page would find nothing to show after this export")

        // 3. And it is the **page the writer wrote**, at the size it chose.
        //
        //    **The size is the assertion that discriminates here**, and this is
        //    the one place the two tests have to be read together. Both pages
        //    carry the same picture in the real chain — the preview is a
        //    resample of the file's own pixels, which is exactly what makes it
        //    a *proof* rather than a second rendering — so no pixel comparison
        //    can tell page 1 from a downscale of page 0. What can is the size:
        //    2048 is the writer's chosen long edge and a thumbnail call's
        //    result is not. `ExportPreviewTests` is where the pages are
        //    different colours and the pixels *do* discriminate.
        //
        //    2048 is right for the pane rather than merely the writer's
        //    round number: the pane is about 950 pt wide, so a 2× display wants
        //    1900 px and this covers it with a little to spare.
        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(file as CFURL, nil)!, 0, nil))
        XCTAssertEqual(max(preview.width, preview.height), 2048,
                       "the writer's long edge — if this moves, this line moves with it")
        XCTAssertLessThan(preview.width, full.width,
                          "the preview is smaller than the file's first page")
        let previewCentre = centreColour(preview)
        let fullCentre = centreColour(full)
        XCTAssertEqual(Int(previewCentre.r), Int(fullCentre.r), accuracy: 24,
                       "and it is the file's own picture, not another one")
    }

    /// And with the flag off there is nothing to read, which is what makes the
    /// page keep the render rather than blank the pane.
    func testWithoutTheFlagThereIsNoPageAndThePageKeepsTheRender() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "spk-preview-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let (session, recipe, url) = try await developedSession(folder: folder)
        XCTAssertFalse(recipe.embedsPreview, "off is the default and the point of the field")

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

        XCTAssertEqual(pageCount(file), 1, "nothing was asked for and nothing should be there")
        XCTAssertNil(ExportPage.embeddedPreview(of: file),
                     "and the page therefore keeps the render it already had")
    }
}
