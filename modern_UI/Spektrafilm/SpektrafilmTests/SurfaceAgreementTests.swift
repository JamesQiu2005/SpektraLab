//  SurfaceAgreementTests.swift — every surface that shows the frame shows
//  the frame the canvas shows.
//
//  The defect class this file exists for is the one the navigator had until
//  2f6e460: it compiled, every suite was green, and after a crop it showed the
//  whole uncropped photograph. Nothing was *wrong* with any unit — the
//  thumbnail was a correct thumbnail and the geometry was correct geometry —
//  the surface simply read its picture from a different source than the
//  canvas does. No component test can see that; only a test that puts a
//  non-identity geometry on the frame and then asks each surface what it
//  shows can.
//
//  So every test here does the same three things: give the frame a crop (and
//  a quarter turn where the surface could get the orientation wrong), read a
//  surface, and compare it with what the canvas holds. A new surface that
//  shows the frame — a panel, a readout, a file, an agent tool — belongs here.
//
//  Known defects are pinned with `XCTExpectFailure(strict: true)`: the suite
//  stays green while the defect stands, and goes red the day it is fixed, so
//  the marker cannot outlive the bug.

import AppKit
import ImageIO
import Metal
import XCTest

@MainActor
final class SurfaceAgreementTests: XCTestCase {

    // MARK: - the histogram (GPU, no fixture)

    /// The canvas histogram describes the picture the canvas shows: after a
    /// crop to the red half of a red | blue frame, there is no blue in it.
    ///
    /// **Known defect, found 2026-09-26.** `Renderer.encodeHistogram` reads
    /// the Layer 2 texture, which is the *uncropped* print — the crop is
    /// applied later, when the canvas samples through `geometryMap` — so the
    /// histogram still counts the half of the frame the crop removed. The
    /// fix is to sample the histogram through the same geometry uniform the
    /// canvas draws with (or over the output-sized texture export makes).
    func testTheHistogramDescribesTheCroppedPicture() throws {
        let renderer = try XCTUnwrap(Renderer())
        let card = try halves(renderer, width: 64, height: 32)
        var bins: [Float] = []
        renderer.onHistogram = { bins = $0 }
        renderer.setLive(card)
        renderer.viewport.backingScale = 1

        // Uncropped: both halves are counted. This is the control — without
        // it, a histogram that never published would pass the assertion below.
        renderer.viewport.resize(viewport: CGSize(width: 64, height: 32), image: CGSize(width: 64, height: 32))
        _ = try XCTUnwrap(renderer.renderOffscreen(size: CGSize(width: 64, height: 32), backingScale: 1))
        XCTAssertEqual(bins.count, 1024, "the histogram did not publish")
        XCTAssertGreaterThan(bins[512 + 255], 0.5, "the control frame has no blue in its histogram")

        var g = Geometry()
        g.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        renderer.geometry = g
        let out = g.outputSize(for: CGSize(width: 64, height: 32))
        renderer.viewport.resize(viewport: out, image: out)
        bins = []
        _ = try XCTUnwrap(renderer.renderOffscreen(size: out, backingScale: 1))
        XCTAssertEqual(bins.count, 1024, "the histogram did not publish")
        XCTExpectFailure("Known defect: the histogram counts the uncropped print", strict: true) {
            XCTAssertEqual(bins[512 + 255], 0, "the histogram counts blue the crop removed")
        }
    }

    // MARK: - the exported file (camera fixture: it has EXIF to carry)

    /// The written file is the frame the canvas shows: a cropped, quarter-
    /// turned frame exports at the canvas's aspect and orientation, and the
    /// EXIF carried from the source (ef1ae0c) describes the file's pixels,
    /// not the camera's.
    func testACroppedTurnedExportIsTheCanvasFrame() async throws {
        let (session, url) = try await developedSession(try cameraFrame())
        var g = Geometry()
        g.crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        g.quarterTurns = 1
        session.geometry = g
        let canvas = session.renderer.logicalSize(forSource: session.sourceImageSize)
        XCTAssertLessThan(canvas.width, canvas.height,
                          "the fixture's landscape crop turned once should be portrait on the canvas")
        XCTAssertNotNil(session.decoded?.sourceEXIF, "the fixture carries no EXIF, so this test proves nothing")

        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-agree-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var recipe = ExportRecipe()
        recipe.format = .jpeg
        recipe.folder = .fixed(path: dir.path)
        recipe.subfolder = ""
        recipe.outputSize = .longEdge(1024)
        let file = try await export(session, url, recipe)

        let (pixels, exif) = try properties(of: file)
        XCTAssertEqual(pixels.width / pixels.height, canvas.width / canvas.height, accuracy: 0.01,
                       "the file's aspect is not the canvas's")
        XCTAssertEqual(max(pixels.width, pixels.height), 1024, accuracy: 1)
        XCTAssertEqual(exif?.width, pixels.width, "the EXIF width describes the camera, not the file")
        XCTAssertEqual(exif?.height, pixels.height, "the EXIF height describes the camera, not the file")
    }

    // MARK: - the agent's preview (RFC-026, camera fixture)

    /// What an agent is shown is what the person would be shown: the
    /// `preview` tool's picture of a cropped frame has the crop's aspect.
    func testTheAgentPreviewIsTheCroppedFrame() async throws {
        let url = try cameraFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        try s.applyAgentEdit(["geometry": ["crop": ["x": 0.25, "y": 0, "width": 0.5, "height": 1]]])
        let canvas = s.renderer.logicalSize(forSource: s.sourceImageSize)
        let preview = try await ws.preview(longEdge: 512)
        addTeardownBlock { try? FileManager.default.removeItem(at: preview) }
        let (pixels, _) = try properties(of: preview)
        XCTAssertEqual(max(pixels.width, pixels.height), 512, accuracy: 1)
        XCTAssertEqual(pixels.width / pixels.height, canvas.width / canvas.height, accuracy: 0.01,
                       "the agent is shown a different picture from the canvas")
    }

    // MARK: - the filmstrip and export cells (Capture One's mask)

    /// A thumbnail shows the whole photograph with the outside of the crop
    /// masked dark: on a red | blue frame cropped to the red half, the red is
    /// untouched and the blue is still there, but nearly black.
    func testAThumbnailMasksWhatTheCropRemoves() throws {
        let image = try halvesImage(width: 200, height: 100)
        XCTAssertTrue(CropMask.masked(image, by: .default) === image, "an identity geometry should not redraw")

        var g = Geometry()
        g.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        let m = CropMask.masked(image, by: g)
        XCTAssertEqual(m.width, 200, "the thumbnail is the whole picture, not the crop")
        let inside = try rgb(m, x: 50, y: 50), outside = try rgb(m, x: 150, y: 50)
        XCTAssertEqual(inside.r, 1, accuracy: 0.02, "the crop is masked")
        XCTAssertEqual(outside.b, 1 - CropMask.opacity, accuracy: 0.03,
                       "the outside of the crop is not under the mask")
    }

    /// The thumbnail is turned and flipped the way the canvas is.
    func testAThumbnailIsTurnedAsTheCanvasIs() throws {
        let image = try halvesImage(width: 200, height: 100)
        var g = Geometry()
        g.quarterTurns = 1
        let m = CropMask.masked(image, by: g)
        XCTAssertEqual(m.width, 100); XCTAssertEqual(m.height, 200)
        // Turned clockwise, the red left half is now the top.
        XCTAssertEqual(try rgb(m, x: 50, y: 20).r, 1, accuracy: 0.02)
        XCTAssertEqual(try rgb(m, x: 50, y: 180).b, 1, accuracy: 0.02)
    }

    /// Each cell is drawn with *its own* frame's geometry: the open frame's
    /// live one, and every other frame's saved one — which survives moving
    /// to another frame, and is what a fresh session reads back.
    func testEachThumbnailUsesItsOwnFramesGeometry() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-thumb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<2 { try Data().write(to: dir.appending(path: "frame-\(i).png")) }
        let session = Session()
        session.open(urls: [dir])
        let urls = session.frames.map(\.id)
        XCTAssertEqual(urls.count, 2)

        session.click(urls[0])
        var g = Geometry()
        g.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        session.geometry = g
        XCTAssertEqual(session.thumbnailGeometry(for: urls[0]), g, "the open frame's cell does not follow the crop")
        XCTAssertEqual(session.thumbnailGeometry(for: urls[1]), .default)

        session.click(urls[1])
        XCTAssertEqual(session.thumbnailGeometry(for: urls[0]), g, "leaving a frame lost its crop from the strip")
        XCTAssertEqual(session.thumbnailGeometry(for: urls[1]), .default)

        let reopened = Session()
        reopened.open(urls: [dir])
        XCTAssertEqual(reopened.thumbnailGeometry(for: urls[0]), g, "a new session does not read the saved crop")
    }

    // MARK: - fixtures and helpers

    /// A frame whose left half is pure red and right half pure blue.
    private func halves(_ renderer: Renderer, width w: Int, height h: Int) throws -> MTLTexture {
        let tex = try XCTUnwrap(renderer.store.makeWritable(width: w, height: h))
        let M: UInt16 = 65535
        var px: [UInt16] = []
        px.reserveCapacity(w * h * 4)
        for _ in 0..<h {
            for x in 0..<w { px += x < w / 2 ? [M, 0, 0, M] : [0, 0, M, M] }
        }
        px.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: w * 8)
        }
        return tex
    }

    private func halvesImage(width w: Int, height h: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// One pixel, top-left origin, 0…1.
    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (r: Double, g: Double, b: Double) {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
    }

    private func checkout() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/SpektrafilmTests
            .deletingLastPathComponent()   // …/Spektrafilm
            .deletingLastPathComponent()   // …/modern_UI
            .deletingLastPathComponent()   // the checkout
    }

    /// A copy, never the fixture itself: a develop writes a sidecar beside
    /// the frame it opens.
    private func copied(_ relative: String) throws -> URL {
        let source = checkout().appending(path: relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(relative) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-agree-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func cameraFrame() throws -> URL { try copied("tests/Test_image/A7m3/DSC03710.ARW") }

    private func developedSession(_ url: URL) async throws -> (Session, URL) {
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        session.requestPrint()
        try await waitUntil("the print to land", timeout: 120) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed
                && !session.busy
        }
        return (session, url)
    }

    private func export(_ session: Session, _ url: URL, _ recipe: ExportRecipe) async throws -> URL {
        let sid = try XCTUnwrap(session.serviceSessionIDForExport)
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: session.decoded?.pixelSize ?? .zero, counter: 1, date: Date())
        let outcome = try await Exporter.export(session: session, recipe: recipe,
                                                context: context, sessionID: sid)
        guard case .wrote(let urls, _, _) = outcome else {
            XCTFail("the export was skipped: \(outcome)")
            throw XCTSkip("no file")
        }
        return try XCTUnwrap(urls.first)
    }

    /// The file's own pixel size, and the EXIF pixel dimensions it carries.
    private func properties(of file: URL) throws
        -> (pixels: CGSize, exif: (width: CGFloat, height: CGFloat)?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let p = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = try XCTUnwrap(p[kCGImagePropertyPixelWidth] as? CGFloat)
        let h = try XCTUnwrap(p[kCGImagePropertyPixelHeight] as? CGFloat)
        let e = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exif = (e?[kCGImagePropertyExifPixelXDimension] as? CGFloat).flatMap { ew in
            (e?[kCGImagePropertyExifPixelYDimension] as? CGFloat).map { (ew, $0) }
        }
        return (CGSize(width: w, height: h), exif)
    }

    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
