//  FilmEdgeSessionTests.swift — RFC-032's film edge and RFC-031's date back,
//  through the session that owns them: the canvas, the crop the gate holds,
//  and the frame the engine is handed.
//
//  The defect that opened this file: with Film Edge on, the engine returns
//  the film canvas — larger than the picture and of another shape — and the
//  canvas drew it into the frame's old rectangle, stretched. Every case here
//  asserts the *shape* on screen against the shape of the texture drawn,
//  within a pixel, rather than that something changed.

import Metal
import XCTest

@MainActor
final class FilmEdgeSessionTests: XCTestCase {

    // MARK: - the canvas keeps the print's proportion

    func testTheCanvasDrawsTheFilmCanvasInItsOwnProportion() async throws {
        let url = try copied("tests/Test_image/_smoke_1mp.tif")
        let session = try await developedSession(url)
        let decoded = try XCTUnwrap(session.decoded?.pixelSize)
        try assertCanvasMatchesPrint(session, "the bare frame")

        // On: the print is the film, wider across than the picture.
        var before = session.renderer.live
        edit(session) { $0.filmEdge.active = true }
        try await waitForPrint(session, after: before) { session.engineFraming != nil }
        let film = try XCTUnwrap(session.renderer.live)
        XCTAssertGreaterThan(film.width * film.height, Int(decoded.width * decoded.height),
                             "the film canvas is larger than the picture")
        XCTAssertFalse(Renderer.sameShape(decoded, CGSize(width: film.width, height: film.height)),
                       "the film canvas has the frame's own shape, so this case proves nothing")
        try assertCanvasMatchesPrint(session, "Film Edge on (135)")

        // Another format: another canvas.
        before = session.renderer.live
        edit(session) { $0.filmEdge.format = .f645 }
        try await waitForPrint(session, after: before) { true }
        try assertCanvasMatchesPrint(session, "Film Edge on (645)")

        // A panoramic format through the whole session: the gate cuts the
        // picture to 3:1 and the film around it is longer still.
        before = session.renderer.live
        edit(session) { $0.filmEdge.format = .f6x17 }
        try await waitForPrint(session, after: before) { true }
        let long = try XCTUnwrap(session.renderer.live)
        XCTAssertNil(session.lastError, "6x17 was refused")
        XCTAssertGreaterThan(Double(max(long.width, long.height)) / Double(min(long.width, long.height)), 2.5,
                             "6x17's film is \(long.width)x\(long.height)")
        try assertCanvasMatchesPrint(session, "Film Edge on (6x17)")

        // Another body: the canvas moves by a few pixels, and still is not stretched.
        before = session.renderer.live
        edit(session) { $0.filmEdge.cameraSeed += 17 }
        try await waitForPrint(session, after: before) { true }
        try assertCanvasMatchesPrint(session, "another camera seed")

        // Off: the frame's own size, and the user's crop back.
        before = session.renderer.live
        edit(session) { $0.filmEdge.active = false }
        try await waitForPrint(session, after: before) { session.engineFraming == nil }
        let back = try XCTUnwrap(session.renderer.live)
        XCTAssertTrue(Renderer.sameShape(decoded, CGSize(width: back.width, height: back.height)),
                      "off, the print is the frame again: \(back.width)x\(back.height) for \(decoded)")
        try assertCanvasMatchesPrint(session, "Film Edge off again")
        XCTAssertEqual(session.geometry, .default, "the user's own crop comes back")
    }

    /// The crop goes into the gate when the film edge goes on, the picture is
    /// measured against the photograph (not the film canvas on screen), and
    /// the user's own crop comes back, exactly, when it goes off.
    func testTheGateHoldsTheCropAndGivesItBack() async throws {
        let url = try copied("tests/Test_image/_smoke_1mp.tif")
        let session = try await developedSession(url)
        let decoded = try XCTUnwrap(session.decoded?.pixelSize)
        var mine = Geometry.default
        mine.crop = CropRect(x: 0.1, y: 0.2, width: 0.8, height: 0.5)
        session.geometry = mine
        var before = session.renderer.live
        edit(session) { $0.filmEdge.active = true }
        try await waitForPrint(session, after: before) { session.engineFraming != nil }
        XCTAssertEqual(session.sourceImageSize, decoded, "the crop is the photograph's")
        let picture = session.geometry.outputSize(for: session.sourceImageSize)
        let ratio = max(picture.width, picture.height) / min(picture.width, picture.height)
        XCTAssertEqual(ratio, 1.5, accuracy: 1 / min(picture.width, picture.height),
                       "\(picture) is not a 36 × 24 gate")
        XCTAssertLessThanOrEqual(picture.width, decoded.width)
        XCTAssertLessThanOrEqual(picture.height, decoded.height)
        // The engine was handed that picture: the film and its carrier are wider than it by 35.8/24 at most.
        let film = try XCTUnwrap(session.renderer.live)
        XCTAssertLessThanOrEqual(Double(min(film.width, film.height)),
                                 Double(min(picture.width, picture.height)) * 35.8 / 24 + 2)
        before = session.renderer.live
        edit(session) { $0.filmEdge.active = false }
        try await waitForPrint(session, after: before) { session.engineFraming == nil }
        XCTAssertEqual(session.geometry, mine)
        XCTAssertNil(session.sidecar.heldCrop)
    }

    /// Coming back to a frame shows its resident film print at once, before
    /// any develop — in the film's proportion, not the photograph's.
    func testAFrameSwitchShowsTheResidentFilmInItsOwnProportion() async throws {
        let a = try copied("tests/Test_image/_smoke_1mp.tif")
        let b = a.deletingLastPathComponent().appending(path: "second.tif")
        try FileManager.default.copyItem(at: a, to: b)
        let session = Session()
        session.open(urls: [a, b])
        session.click(a)
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        session.requestPrint()
        try await waitUntil("the print", timeout: 120) { session.frameStates[a] == .processed && !session.busy }
        let before = session.renderer.live
        edit(session) { $0.filmEdge.active = true }
        try await waitForPrint(session, after: before) { session.engineFraming != nil }
        let film = try XCTUnwrap(session.renderer.live)
        session.click(b)
        try await waitUntil("the other frame", timeout: 90) { session.decoded != nil && session.selection == b }
        session.click(a)
        // At once: the resident print is on the canvas before anything lands.
        XCTAssertTrue(session.renderer.live === film, "the resident film print is shown")
        try assertCanvasMatchesPrint(session, "back on the frame, resident print")
        // …and once the open has finished, which may stop at the decode or at
        // the print cache, either way without a develop.
        try await Task.sleep(for: .seconds(3))
        try assertCanvasMatchesPrint(session, "back on the frame, the open finished")
    }

    /// The latitude probe measures the medium on a neutral ramp; a film edge
    /// must not change what it finds. `medium_probe_params` (engine.cpp)
    /// switches overscan and the date off; without that the ramp is drawn as
    /// film and the probe reports "the medium probe's print has no tonal
    /// range".
    func testAFilmEdgeDoesNotMoveTheLatitude() async throws {
        let url = try copied("tests/Test_image/_smoke_1mp.tif")
        let session = try await developedSession(url)
        let measured = await session.measureLatitude()
        let bare = try XCTUnwrap(measured)
        let before = session.renderer.live
        edit(session) { $0.filmEdge.active = true }
        try await waitForPrint(session, after: before) { session.engineFraming != nil }
        let edged = await session.measureLatitude()
        XCTAssertEqual(edged?.medium.latitudeStops ?? -1, bare.medium.latitudeStops, accuracy: 0.01,
                       session.latitude.failure ?? "")
    }

    /// A film canvas reprints. The engine lays the film out when it develops,
    /// and a print edit reprints the cached negative: on the live tier after
    /// the full render has landed, and after a paper change has rebuilt the
    /// pipeline. Both failed with "the negative does not match this
    /// pipeline's overscan layout", and so did the export that followed.
    func testAFilmCanvasReprintsAfterTheFullRenderAndAPaperChange() async throws {
        let url = try copied("tests/Test_image/A7m3/DSC03710.ARW")
        let session = try await developedSession(url)
        var before = session.renderer.live
        edit(session) { $0.filmEdge.active = true }
        try await waitForPrint(session, after: before) { session.engineFraming != nil }
        try await waitUntil("the full render", timeout: 120) { session.renderer.fullRender != nil }
        let film = try XCTUnwrap(session.renderer.live)

        for (what, change) in [
            ("Brightness", { (p: inout FilmParams) in p.printBrightnessStops = 1 }),
            ("the paper", { (p: inout FilmParams) in p.printStock = "kodak_portra_endura" }),
            ("the Digital Intermediate", { (p: inout FilmParams) in p.digitalIntermediate = true }),
            ("the paper again", { (p: inout FilmParams) in p.digitalIntermediate = false }),
        ] as [(String, (inout FilmParams) -> Void)] {
            before = session.renderer.live
            edit(session, change)
            try await waitForPrint(session, after: before) { true }
            let print = try XCTUnwrap(session.renderer.live)
            XCTAssertFalse(print === before, "\(what): no new print; status: \(session.status)")
            XCTAssertEqual(CGSize(width: print.width, height: print.height),
                           CGSize(width: film.width, height: film.height), "\(what): the same film canvas")
            XCTAssertFalse(session.status.contains("overscan"), "\(what): \(session.status)")
        }

        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-filmedge-out-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for format in [ExportFormat.jpeg, .di] {
            var recipe = ExportRecipe()
            recipe.format = format
            recipe.folder = .fixed(path: dir.path)
            recipe.subfolder = ""
            recipe.outputSize = .longEdge(1600)
            let context = NamingRule.Context(
                originalName: "film", filmStock: session.params.filmStock, printStock: session.params.printStock,
                pixelSize: session.printPixelSize, counter: 1, date: Date())
            let sid = try XCTUnwrap(session.serviceSessionIDForExport)
            let outcome = try await Exporter.export(session: session, recipe: recipe, context: context, sessionID: sid)
            guard case .wrote(let urls, _, _) = outcome else { return XCTFail("\(format): \(outcome)") }
            XCTAssertFalse(urls.isEmpty, "\(format) wrote a file")
        }
    }

    /// The date back alone prints in the picture's own corner, upright,
    /// whatever the crop, the turn or the flip. The engine exposes the date on
    /// the frame it is handed, so the frame has to be the picture: handed the
    /// whole decode, a crop cut the date away, a quarter turn carried it round
    /// to another corner on its side, and a flip mirrored it.
    func testTheDateAloneFollowsTheCropTheTurnAndTheFlip() async throws {
        let url = try copied("tests/Test_image/A7m3/DSC03710.ARW")
        let session = try await developedSession(url)

        // The date's place on the canvas: where a print with it differs from
        // one whose date back is on with nothing to print (the same frame in
        // the engine, so nothing else moves), as a box in the drawn picture's
        // own unit square.
        func dateBox(_ geometry: Geometry, _ what: String) async throws -> CGRect {
            var images: [[UInt16]] = []
            var size = CGSize.zero
            for on in [false, true] {
                edit(session) { $0.dateBack.active = true; $0.dateBack.customText = on ? "'88 8 8" : " "; $0.dateBack.brightnessEV = 8 }
                if session.geometry != geometry { session.geometry = geometry }
                // An edit may or may not develop (the first pass changes
                // nothing); either way the canvas is settled after this.
                try await Task.sleep(for: .seconds(3))
                try await waitUntil("\(what): idle, date \(on)", timeout: 120) { !session.busy }
                session.renderer.hideFullRender()
                session.renderer.viewport.resize(viewport: CGSize(width: 900, height: 900),
                                                 image: session.renderer.viewport.image)
                session.renderer.viewport.fit()
                let frame = session.renderer.viewport.imageFrame
                let tex = try XCTUnwrap(session.renderer.renderOffscreen(size: CGSize(width: 900, height: 900),
                                                                         backingScale: 1))
                var px = [UInt16](repeating: 0, count: 900 * 900 * 4)
                tex.getBytes(&px, bytesPerRow: 900 * 8, from: MTLRegionMake2D(0, 0, 900, 900), mipmapLevel: 0)
                images.append(px)
                size = frame.size
                XCTAssertGreaterThan(frame.width, 100, what)
                // Everything outside the picture is the same in both; keep the frame for the box.
                if on {
                    var minX = 900, maxX = -1, minY = 900, maxY = -1
                    for y in 0..<900 { for x in 0..<900 {
                        let i = (y * 900 + x) * 4
                        let d = abs(Int(images[0][i]) - Int(px[i])) + abs(Int(images[0][i + 1]) - Int(px[i + 1]))
                        if d > 6000 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
                    } }
                    guard maxX >= 0 else { XCTFail("\(what): no date on the canvas"); return .zero }
                    return CGRect(x: (CGFloat(minX) - frame.minX) / frame.width,
                                  y: (CGFloat(minY) - frame.minY) / frame.height,
                                  width: CGFloat(maxX - minX) / frame.width,
                                  height: CGFloat(maxY - minY) / frame.height)
                }
            }
            _ = size
            return .zero
        }

        func assertLowerRightUpright(_ box: CGRect, _ what: String, picture: CGSize) {
            XCTAssertGreaterThan(box.midX, 0.6, "\(what): the date is in the right of the picture: \(box)")
            XCTAssertGreaterThan(box.midY, 0.7, "\(what): the date is at the bottom of the picture: \(box)")
            XCTAssertLessThan(box.maxX, 1.01, "\(what): inside the picture: \(box)")
            XCTAssertGreaterThan(box.width * picture.width, 2 * box.height * picture.height,
                                 "\(what): the date reads along the picture, upright: \(box)")
        }

        var g = Geometry.default
        let whole = try await dateBox(g, "the whole frame")
        assertLowerRightUpright(whole, "the whole frame", picture: CGSize(width: 3, height: 2))

        g.crop = CropRect(x: 0.05, y: 0.05, width: 0.5, height: 0.5)
        let cropped = try await dateBox(g, "a crop of the upper left")
        assertLowerRightUpright(cropped, "a crop of the upper left", picture: CGSize(width: 3, height: 2))
        XCTAssertEqual(cropped.width, whole.width, accuracy: 0.25 * whole.width,
                       "the date is as large in the cropped picture as in the whole one")

        g = .default
        g.flipH = true
        let flipped = try await dateBox(g, "flipped")
        assertLowerRightUpright(flipped, "flipped", picture: CGSize(width: 3, height: 2))
    }

    /// A sidecar from elsewhere can carry a film edge over a crop that was
    /// never held at the gate (the `params` setter holds it; a hand-written
    /// file does not). The engine refuses a frame that is not the gate's
    /// shape, so the session holds the crop before the develop.
    func testAFilmEdgeFromASidecarHoldsTheCropBeforeItDevelops() async throws {
        let url = try copied("tests/Test_image/_smoke_1mp.tif")
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        // As a loaded sidecar would be: the film edge on, the crop untouched.
        session.sidecar.params.filmEdge.active = true
        session.sidecar.params.filmEdge.format = .f6x6
        session.requestPrint()
        try await waitUntil("the print to land", timeout: 120) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }
        XCTAssertFalse(session.status.contains("gate's shape"), session.status)
        let size = try XCTUnwrap(session.decoded?.pixelSize)
        let picture = session.geometry.outputSize(for: size)
        XCTAssertEqual(picture.width / picture.height, 1, accuracy: 0.01, "the crop is the 6×6 gate's")
        XCTAssertNotNil(session.sidecar.heldCrop, "the crop it had is kept to give back")
        let film = try XCTUnwrap(session.renderer.live)
        XCTAssertGreaterThan(film.width, Int(picture.width) * 799 / Int(size.width), "a film canvas landed")
    }

    /// The renderer's half, with no engine: a print of another shape drawn
    /// into the frame of the last one.
    func testARendererTakesTheShapeOfAPrintOfAnotherShape() throws {
        let renderer = try XCTUnwrap(Renderer())
        let a = try XCTUnwrap(renderer.store.makeWritable(width: 300, height: 200))
        let film = try XCTUnwrap(renderer.store.makeWritable(width: 314, height: 291))
        renderer.setLive(a, logical: CGSize(width: 3000, height: 2000))
        renderer.setLive(film)
        XCTAssertEqual(renderer.viewport.image.width, 3140, accuracy: 1)
        XCTAssertEqual(renderer.viewport.image.height, 2910, accuracy: 1)
        // The native render of it, a pixel off the live tier's ratio, moves nothing…
        let native = try XCTUnwrap(renderer.store.makeWritable(width: 3141, height: 2910))
        renderer.setFullRender(native)
        XCTAssertEqual(renderer.viewport.image, CGSize(width: 3140, height: 2910))
        // …and one of another shape is the frame.
        let other = try XCTUnwrap(renderer.store.makeWritable(width: 2000, height: 3000))
        renderer.setFullRender(other)
        XCTAssertEqual(renderer.viewport.image, CGSize(width: 2000, height: 3000))
    }

    // MARK: - helpers

    /// The rectangle the canvas draws the image into, against the texture it
    /// draws: one shape, within a pixel.
    private func assertCanvasMatchesPrint(_ session: Session, _ when: String,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let base = try XCTUnwrap(session.renderer.base, when, file: file, line: line)
        let geometry = session.renderer.geometry
        let shown = geometry.outputSize(for: CGSize(width: base.width, height: base.height))
        let image = session.renderer.viewport.image
        let drawnHeight = shown.width * image.height / image.width
        XCTAssertEqual(drawnHeight, shown.height, accuracy: 1,
                       "\(when): the canvas draws \(image) for a \(base.width)x\(base.height) print",
                       file: file, line: line)
    }

    private func edit(_ session: Session, _ change: (inout FilmParams) -> Void) {
        var p = session.params
        change(&p)
        session.params = p
    }

    private func waitForPrint(_ session: Session, after previous: MTLTexture?,
                              _ also: @MainActor () -> Bool) async throws {
        try await waitUntil("a new print", timeout: 120) {
            session.renderer.live !== previous && session.serviceSessionIDForExport != nil
                && !session.busy && also()
        }
    }

    private func developedSession(_ url: URL) async throws -> Session {
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        session.requestPrint()
        try await waitUntil("the print to land", timeout: 120) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed
                && !session.busy
        }
        return session
    }

    private func checkout() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A copy, never the fixture itself: a develop writes a sidecar.
    private func copied(_ relative: String) throws -> URL {
        let source = checkout().appending(path: relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(relative) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-filmedge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
        throw XCTSkip("timed out")
    }
}
