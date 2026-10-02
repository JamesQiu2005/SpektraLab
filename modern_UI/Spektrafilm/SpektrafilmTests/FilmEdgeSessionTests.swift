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
        // The engine was handed that picture: the film is wider than it by 35/24 at most.
        let film = try XCTUnwrap(session.renderer.live)
        XCTAssertLessThanOrEqual(Double(min(film.width, film.height)),
                                 Double(min(picture.width, picture.height)) * 35 / 24 + 2)
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
