//  HalfFramePairTests.swift — two half frames on one piece of film.
//
//  The piece's arithmetic, its file, the session's handling of it, the decode
//  the composer makes of it, and one pair developed through the engine with
//  and without the film edge. What is most likely to break is listed in the
//  proposal's §8: an edit landing on the wrong hole, a stale render, a missing
//  frame. Each has a case here.

import CoreImage
import Metal
import XCTest

@MainActor
final class HalfFramePairTests: XCTestCase {

    // MARK: - the piece's arithmetic

    func testTheLayoutIsTwoHolesAndTheGap() {
        // The drawn pair: two 1600 × 2133 pictures 1.0 mm apart.
        let l = HalfFramePair.layout(holeHeight: 2133, spacingMM: 1.0)
        XCTAssertEqual(l.hole, CGSize(width: 1600, height: 2133))
        XCTAssertEqual(l.advance, 1689)
        XCTAssertEqual(l.size, CGSize(width: 3289, height: 2133))
        XCTAssertEqual(l.rect(.left), CGRect(x: 0, y: 0, width: 1600, height: 2133))
        XCTAssertEqual(l.rect(.right), CGRect(x: 1689, y: 0, width: 1600, height: 2133))
        // On a strip the piece is the gate and one advance: 37 × 24.
        XCTAssertEqual(l.size.width / l.size.height, 37.0 / 24.0, accuracy: 0.001)
        // A wider gap moves only the second hole.
        let wide = HalfFramePair.layout(holeHeight: 2133, spacingMM: 2.0)
        XCTAssertEqual(wide.hole, l.hole)
        XCTAssertEqual(wide.advance, 1778)
        // Hit-testing: the holes and the gap between them.
        XCTAssertEqual(l.side(atNormalised: CGPoint(x: 0.2, y: 0.5)), .left)
        XCTAssertEqual(l.side(atNormalised: CGPoint(x: 0.8, y: 0.5)), .right)
        XCTAssertNil(l.side(atNormalised: CGPoint(x: 0.5, y: 0.5)))
    }

    func testThePlacementCutsTheHolesShapeAndNeverShowsBase() {
        let source = CGSize(width: 6000, height: 4000)
        var p = HalfFramePair.Placement()
        var r = HalfFramePair.sourceRect(for: p, source: source)
        XCTAssertEqual(r, CGRect(x: 1500, y: 0, width: 3000, height: 4000), "1.00× fills the hole from the middle")
        p.x = 1
        r = HalfFramePair.sourceRect(for: p, source: source)
        XCTAssertEqual(r.maxX, 6000, accuracy: 0.001, "moved all the way, the picture's edge is the hole's")
        p.scale = 2; p.x = -1; p.y = 1
        r = HalfFramePair.sourceRect(for: p, source: source)
        XCTAssertEqual(r, CGRect(x: 0, y: 2000, width: 1500, height: 2000))
        // Out-of-range values are held, so no base ever shows in a filled hole.
        p.scale = 0.2; p.x = 9; p.y = -9
        r = HalfFramePair.sourceRect(for: p, source: source)
        XCTAssertTrue(CGRect(origin: .zero, size: source).contains(r))
        XCTAssertEqual(r.width / r.height, 0.75, accuracy: 1e-9)
        // Turned a quarter, a landscape frame is a portrait one.
        p = HalfFramePair.Placement(); p.quarterTurns = 1
        XCTAssertEqual(HalfFramePair.turned(source, by: p), CGSize(width: 4000, height: 6000))
    }

    func testTurnedThePieceIsStackedAndTheHolesAreLandscape() {
        let l = HalfFramePair.layout(holeHeight: 2400, spacingMM: 1.0, turned: true)
        XCTAssertEqual(l.hole, CGSize(width: 2400, height: 1800))
        XCTAssertEqual(l.size, CGSize(width: 2400, height: 3700))
        XCTAssertEqual(l.rect(.left).minY, 0); XCTAssertEqual(l.rect(.right).minY, 1900)
        XCTAssertEqual(l.side(atNormalised: CGPoint(x: 0.5, y: 0.2)), .left, "the first frame is the upper one")
        XCTAssertEqual(l.side(atNormalised: CGPoint(x: 0.5, y: 0.8)), .right)
        XCTAssertNil(l.side(atNormalised: CGPoint(x: 0.5, y: 0.5)))
        var pair = HalfFramePair(folder: "")
        pair.turned = true
        XCTAssertEqual(pair.holeAspect, 24.0 / 18.0, accuracy: 1e-9)
        // A 3:2 landscape frame fills a landscape hole from its middle.
        let r = HalfFramePair.sourceRect(for: .init(), source: CGSize(width: 6000, height: 4000), aspect: pair.holeAspect)
        XCTAssertEqual(r.height, 4000, accuracy: 0.001)
        XCTAssertEqual(r.width, 4000 * 24.0 / 18.0, accuracy: 0.001)
        XCTAssertEqual(r.midX, 3000, accuracy: 0.001)
    }

    func testADragMovesThePictureWithThePointerAndStopsAtItsEdge() {
        let source = CGSize(width: 6000, height: 4000)
        let origin = HalfFramePair.Placement()
        // Half a hole to the right: the picture follows, so the cut goes left.
        let moved = Session.placement(origin, draggedBy: CGSize(width: 0.25, height: 0), source: source)
        let before = HalfFramePair.sourceRect(for: origin, source: source)
        let after = HalfFramePair.sourceRect(for: moved, source: source)
        XCTAssertEqual(after.minX, before.minX - 0.25 * before.width, accuracy: 0.5)
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.001, "a 3:2 frame has no slack down a portrait hole at 1.00×")
        let far = Session.placement(origin, draggedBy: CGSize(width: 9, height: 0), source: source)
        XCTAssertEqual(HalfFramePair.sourceRect(for: far, source: source).minX, 0, accuracy: 0.001, "held at the picture's edge")
        // A level crop becomes the same rectangle under the hole.
        var g = Geometry.default
        g.crop = CropRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
        let p = Session.placement(from: g, source: source, aspect: 0.75)
        let cut = HalfFramePair.sourceRect(for: p, source: source)
        XCTAssertEqual(cut.minX, 3000, accuracy: 1); XCTAssertEqual(cut.minY, 1000, accuracy: 1)
        XCTAssertEqual(cut.height, 2000, accuracy: 1)
    }

    // MARK: - the file

    func testThePairIsAFileThatBelongsToItsFolder() throws {
        let (folder, frames) = try folderOfFrames(3)
        var pair = HalfFramePair(folder: folder.standardizedFileURL.path)
        pair.left = HalfFramePair.Hole(url: frames[1])
        let url = HalfFramePair.newURL(in: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try pair.save(to: url)
        XCTAssertTrue(HalfFramePair.isPair(url))
        XCTAssertEqual(HalfFramePair.load(url), pair)
        XCTAssertNotEqual(HalfFramePair.newURL(in: folder), url, "a second pair takes another file")
        XCTAssertEqual(HalfFramePair.pairs(in: folder).map(\.url.lastPathComponent), [url.lastPathComponent])
        let (other, _) = try folderOfFrames(1)
        XCTAssertTrue(HalfFramePair.pairs(in: other).isEmpty, "another folder's filmstrip does not list it")
        XCTAssertFalse(pair.isComplete)
        pair.right = HalfFramePair.Hole(url: frames[2])
        XCTAssertTrue(pair.isComplete)
        try FileManager.default.removeItem(at: frames[2])
        XCTAssertFalse(pair.isComplete, "a frame that is gone leaves its hole empty")
    }

    // MARK: - the session

    func testNewPairFillsTheHolesInOrderAndSitsAfterItsLeftFrame() throws {
        let (s, urls) = try openedSession(frameCount: 4)
        s.click(urls[2])
        s.click(urls[1], command: true)
        s.newPair()
        let pairURL = try XCTUnwrap(s.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        XCTAssertTrue(HalfFramePair.isPair(pairURL))
        let pair = try XCTUnwrap(s.pair)
        XCTAssertEqual(pair.left?.path, urls[1].standardizedFileURL.path, "the filmstrip's order, not the click's")
        XCTAssertEqual(pair.right?.path, urls[2].standardizedFileURL.path)
        XCTAssertEqual(s.frames.map(\.id), [urls[0], urls[1], pairURL, urls[2], urls[3]])
        XCTAssertFalse(s.sidecar.params.autoExposure, "the strip is metered per hole, not as one scene")
        XCTAssertFalse(s.sidecar.params.filmEdge.active)
        // The frames are still themselves.
        XCTAssertTrue(s.frames.contains { $0.id == urls[1] } && s.frames.contains { $0.id == urls[2] })

        // Another session opening the folder finds the pair in the same place.
        let again = Session(clipboardDefaults: try defaults())
        again.open(urls: [urls[0].deletingLastPathComponent()])
        XCTAssertEqual(again.frames.map(\.id.lastPathComponent),
                       s.frames.map(\.id.lastPathComponent))
        XCTAssertNil(again.pair, "nothing is open until it is clicked")
    }

    func testAHoleEditChangesThatHoleAndNothingElse() throws {
        let (s, urls) = try openedSession(frameCount: 4)
        s.click(urls[0])
        s.click(urls[1], command: true)
        s.newPair()
        let pairURL = try XCTUnwrap(s.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        let before = try XCTUnwrap(s.pair)

        s.setPlacement(.right) { $0.scale = 1.5; $0.x = 0.25 }
        XCTAssertEqual(s.pair?.left, before.left, "the left hole moved with the right one")
        XCTAssertEqual(s.pair?.right?.placement.scale, 1.5)
        XCTAssertEqual(HalfFramePair.load(pairURL), s.pair, "the file is behind the session")

        s.setHoleExposure(.left, 0.5)
        XCTAssertEqual(s.pair?.left?.exposureEV, 0.5)
        XCTAssertEqual(s.pair?.right?.exposureEV, 0)

        s.swapHoles()
        XCTAssertEqual(s.pair?.left?.path, urls[1].standardizedFileURL.path)
        XCTAssertEqual(s.pair?.left?.placement.scale, 1.5, "a hole's placement travels with its frame")
        XCTAssertEqual(s.pair?.right?.exposureEV, 0.5)

        s.setHole(.right, to: urls[3])
        XCTAssertEqual(s.pair?.right?.path, urls[3].standardizedFileURL.path)
        XCTAssertEqual(s.pair?.left?.path, urls[1].standardizedFileURL.path, "replacing one hole touched the other")
        XCTAssertEqual(s.pair?.right?.placement, HalfFramePair.Placement(), "a new frame starts from the middle")

        s.setHole(.left, to: nil)
        XCTAssertNil(s.pair?.left)
        XCTAssertEqual(s.pair?.isComplete, false)
        // ⌘Z puts the frame back in its hole: the piece undoes with the look.
        XCTAssertTrue(s.canUndo)
        s.undo()
        XCTAssertEqual(s.pair?.left?.path, urls[1].standardizedFileURL.path, "undo did not restore the removed frame")
        XCTAssertEqual(HalfFramePair.load(pairURL), s.pair)
        s.setHole(.left, to: nil)

        s.setPairSpacing(9)
        XCTAssertEqual(s.pair?.spacingMM, 2.0, "spacing is held to 0.5–2.0 mm")
        XCTAssertEqual(s.frameStates[pairURL], .stale)

        // No crop tool on a pair: each picture is placed under its own hole.
        s.tool = .crop
        XCTAssertEqual(s.tool, .select)
        XCTAssertTrue(s.pairPlacing, "the crop tool on a pair crops the filled hole")
        XCTAssertEqual(s.pairLayer, .right)
        XCTAssertTrue(s.endPlacement())
        // A frame opened afterwards is a frame: nothing of the pair stays.
        s.click(urls[0])
        XCTAssertNil(s.pair)
        XCTAssertFalse(s.sidecar.params.filmEdge.pair)
    }

    func testAHalfFrameEntersAPairAndTheCanvasPicksItsHoles() throws {
        let (s, urls) = try openedSession(frameCount: 3)
        s.click(urls[1])
        XCTAssertFalse(s.canEnterPair, "the way in is offered under the Half format only")
        var p = s.sidecar.params
        p.filmEdge.format = .f135Half
        s.sidecar.params = p
        XCTAssertTrue(s.canEnterPair)
        s.enterPair()
        let pairURL = try XCTUnwrap(s.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        let pair = try XCTUnwrap(s.pair)
        XCTAssertEqual(pair.left?.path, urls[1].standardizedFileURL.path, "the frame it was entered from is the first one")
        XCTAssertNil(pair.right, "the second hole is empty, for the + on the canvas")
        XCTAssertEqual(s.pairLayer, .right, "the empty hole is the one to fill")
        XCTAssertEqual(s.frames.map(\.id), [urls[0], urls[1], pairURL, urls[2]])
        XCTAssertFalse(s.canEnterPair, "a pair is not entered from a pair")
        // A click on the canvas picks the hole under it; the gap picks the film.
        XCTAssertEqual(s.pairHoleRects.count, 2)
        s.clicked(normalised: CGPoint(x: 0.2, y: 0.5)); XCTAssertEqual(s.pairLayer, .left)
        s.clicked(normalised: CGPoint(x: 0.5, y: 0.5)); XCTAssertEqual(s.pairLayer, .film)
        s.clicked(normalised: CGPoint(x: 0.8, y: 0.5)); XCTAssertEqual(s.pairLayer, .right)
        // Its menu is about that hole: empty, it offers a frame; and the picker opens on it.
        let empty = s.pairContextMenu().items.map(\.title)
        XCTAssertTrue(empty.first == "Add Frame…" || empty.first == "添加照片…", "\(empty)")
        s.clicked(normalised: CGPoint(x: 0.2, y: 0.5))
        let filled = s.pairContextMenu().items.map(\.title)
        XCTAssertTrue(filled.contains { $0 == "Replace Frame…" || $0 == "替换照片…" }, "\(filled)")
        XCTAssertTrue(filled.contains { $0 == "Crop This Frame" || $0 == "裁剪这一格" }, "\(filled)")
        // A frame dropped on a hole goes into it; on the gap, into the empty one.
        XCTAssertTrue(s.dropFrame(urls[2], atNormalised: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(s.pair?.right?.path, urls[2].standardizedFileURL.path)
        XCTAssertTrue(s.dropFrame(urls[0], atNormalised: CGPoint(x: 0.2, y: 0.5)))
        XCTAssertEqual(s.pair?.left?.path, urls[0].standardizedFileURL.path, "the drop replaced the frame under it")
        XCTAssertFalse(s.dropFrame(urls[1], atNormalised: CGPoint(x: 0.5, y: 0.5)), "both full, dropped on the gap")
        XCTAssertFalse(s.dropFrame(pairURL, atNormalised: CGPoint(x: 0.2, y: 0.5)), "a pair is not a frame")
        // Turned, the holes are one above the other.
        s.setPairTurned(true)
        s.clicked(normalised: CGPoint(x: 0.5, y: 0.2)); XCTAssertEqual(s.pairLayer, .left)
        s.clicked(normalised: CGPoint(x: 0.5, y: 0.8)); XCTAssertEqual(s.pairLayer, .right)
        // The crop mode is the picked, filled hole's; Return or Esc leaves it.
        s.clicked(normalised: CGPoint(x: 0.5, y: 0.2))
        s.tool = .crop
        XCTAssertTrue(s.pairPlacing)
        XCTAssertTrue(s.endPlacement()); XCTAssertFalse(s.pairPlacing)
    }

    func testAnEmptyPairAndAPairDuringExport() throws {
        let (s, urls) = try openedSession(frameCount: 2)
        s.newPair()
        let pairURL = try XCTUnwrap(s.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        XCTAssertNil(s.pair?.left); XCTAssertNil(s.pair?.right)
        XCTAssertEqual(s.frames.last?.id, pairURL, "an empty pair goes at the end")
        s.batchExporting = true
        s.setHole(.left, to: urls[0])
        XCTAssertNil(s.pair?.left, "the piece changed during an export")
        XCTAssertFalse(s.canMakePair)
    }

    // MARK: - the decode

    func testThePieceDecodesAsBothPicturesWithUnexposedFilmBetween() throws {
        let frames = try copies(2)
        var pair = HalfFramePair(folder: frames[0].deletingLastPathComponent().standardizedFileURL.path)
        pair.left = HalfFramePair.Hole(url: frames[0])
        pair.right = HalfFramePair.Hole(url: frames[1])
        let url = HalfFramePair.newURL(in: frames[0].deletingLastPathComponent())
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try pair.save(to: url)

        let d = try ImageDecoder.decode(url, settings: DecodeSettings())
        let one = try ImageDecoder.decode(frames[0], settings: DecodeSettings())
        let layout = PairComposer.layout(for: pair, sizes: [.left: one.pixelSize, .right: one.pixelSize])
        XCTAssertEqual(d.pixelSize, layout.size)
        // Two half frames are one frame's worth of film: the piece is no longer
        // than the frame it was made from, and neither picture is enlarged.
        XCTAssertLessThanOrEqual(max(layout.size.width, layout.size.height),
                                 max(one.pixelSize.width, one.pixelSize.height))
        XCTAssertLessThanOrEqual(layout.hole.height, HalfFramePair.sourceRect(for: .init(), source: one.pixelSize).height)
        XCTAssertEqual(d.linear.extent, CGRect(origin: .zero, size: layout.size))

        func mean(_ image: CIImage, _ r: CGRect) -> Float {
            var px = [Float](repeating: 0, count: 4)
            let avg = image.cropped(to: r).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
            ImageDecoder.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        format: .RGBAf, colorSpace: nil)
            return (px[0] + px[1] + px[2]) / 3
        }
        let H = layout.size.height
        let left = CGRect(x: 10, y: 10, width: layout.hole.width - 20, height: H - 20)
        let right = left.offsetBy(dx: CGFloat(layout.advance), dy: 0)
        let gap = CGRect(x: layout.hole.width + 2, y: 10, width: CGFloat(layout.advance) - layout.hole.width - 4, height: H - 20)
        XCTAssertGreaterThan(mean(d.linear, left), 0.01)
        XCTAssertEqual(mean(d.linear, left), mean(d.linear, right), accuracy: 1e-4, "the same frame twice is the same picture twice")
        XCTAssertEqual(mean(d.linear, gap), 0, accuracy: 1e-6, "no light reached the film between the holes")

        // One stop on the right hole doubles it and leaves the left alone.
        let exposed = PairComposer.exposed(d.linear, layout: layout, stops: [.right: 1])
        XCTAssertEqual(mean(exposed, right), 2 * mean(d.linear, right), accuracy: 1e-3)
        XCTAssertEqual(mean(exposed, left), mean(d.linear, left), accuracy: 1e-6)
        XCTAssertEqual(mean(exposed, gap), 0, accuracy: 1e-6)

        // A frame that is gone is an empty hole, not a failed pair.
        try FileManager.default.removeItem(at: frames[1])
        let half = try ImageDecoder.decode(url, settings: DecodeSettings())
        XCTAssertEqual(half.pixelSize, layout.size)
        XCTAssertEqual(mean(half.linear, right), 0, accuracy: 1e-6)
        XCTAssertGreaterThan(mean(half.linear, left), 0.01)
        XCTAssertNotNil(PairComposer.thumbnail(url, maxPixel: 320))
    }

    // MARK: - through the engine

    func testAPairDevelopsAsOnePieceAndAsOneStrip() async throws {
        let frames = try copies(2)
        let session = Session(clipboardDefaults: try defaults())
        session.open(urls: [frames[0].deletingLastPathComponent()])
        let urls = session.frames.map(\.id)
        session.click(urls[0])
        session.click(urls[1], command: true)
        session.newPair()
        let pairURL = try XCTUnwrap(session.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        try await waitUntil("the pair to develop", timeout: 180) {
            session.serviceSessionIDForExport != nil && session.frameStates[pairURL] == .processed && !session.busy
        }
        XCTAssertNil(session.lastError)
        let decoded = try XCTUnwrap(session.decoded?.pixelSize)
        let print = try XCTUnwrap(session.renderer.live)
        XCTAssertEqual(Double(print.width) / Double(print.height), decoded.width / decoded.height, accuracy: 0.01,
                       "the print is the piece")
        // Each hole was metered alone, and the readings are kept with the pair.
        let kept = try XCTUnwrap(HalfFramePair.load(pairURL))
        let l = try XCTUnwrap(kept.left?.meteredEV), r = try XCTUnwrap(kept.right?.meteredEV)
        XCTAssertEqual(l, r, accuracy: 0.05, "the same frame twice meters the same")
        XCTAssertEqual(session.sidecar.params.filmFormatMM, 37, accuracy: 0.001)

        // Film Edge: the engine's own strip, both frames on it.
        let before = session.renderer.live
        var p = session.params
        p.filmEdge.active = true
        session.params = p
        try await waitUntil("the strip", timeout: 180) {
            session.renderer.live !== before && session.serviceSessionIDForExport != nil && !session.busy
                && session.frameStates[pairURL] == .processed
        }
        XCTAssertNil(session.lastError, "the strip was refused")
        let strip = try XCTUnwrap(session.renderer.live)
        XCTAssertTrue(session.sidecar.params.filmEdge.pair)
        XCTAssertEqual(session.sidecar.params.filmEdge.format, .f135Half)
        func squareness(_ t: MTLTexture) -> Double { Double(min(t.width, t.height)) / Double(max(t.width, t.height)) }
        XCTAssertGreaterThan(squareness(strip), squareness(print) * 1.25, "35 mm of film across a 24 mm gate")
        // The clock stops: a develop started while another was unwinding left
        // `busy` set for good, and the status counted with the engine idle.
        try await waitUntil("the session to go idle", timeout: 60) { !session.working }
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(session.working, "the session is still counting with nothing running")
        XCTAssertEqual(session.pairHoleRects.count, 2, "the engine's gates are known on the strip")
        XCTAssertEqual(session.pair?.onStrip, true)

        // An empty hole is not exported (answer B9).
        session.setHole(.right, to: nil)
        do {
            _ = try await Exporter.export(session: session, recipe: ExportRecipe(),
                                          context: NamingRule.Context(originalName: "pair", filmStock: "", printStock: "",
                                                                      pixelSize: .zero, counter: 1, date: Date()),
                                          sessionID: "none")
            XCTFail("a pair with an empty hole was exported")
        } catch Exporter.ExportError.incompletePair {
        } catch { XCTFail("\(error)") }
    }

    /// A develop asked for while another is still unwinding. Each used to save
    /// `busy` on the way in and put it back on the way out; the second saved
    /// `true`, the first put back `false`, the second put back `true` — for
    /// good, and the status clock counted with the engine idle. That is what
    /// a pair did when its Film Edge was switched on (owner, 2026-10-03).
    func testOverlappingDevelopsLeaveTheSessionIdle() async throws {
        let frames = try copies(1)
        let session = Session(clipboardDefaults: try defaults())
        session.open(urls: [frames[0]])
        let url = try XCTUnwrap(session.selection)
        try await waitUntil("the frame to decode", timeout: 90) { session.decoded != nil }
        var overlapped = false
        session.afterOpenDeltaForTesting = { [weak session] in
            // Inside the first develop, with the engine about to be handed the
            // frame: drop it and ask again, as an edit landing mid-develop does.
            guard !overlapped, let session else { return }
            overlapped = true
            session.releaseEngineFrame()
            session.requestPrint()
        }
        session.requestPrint()
        try await waitUntil("the second develop to land", timeout: 120) {
            overlapped && session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed
        }
        try await waitUntil("the session to go idle", timeout: 30) { !session.working }
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertFalse(session.busy, "busy was left set by two overlapping develops")
        XCTAssertFalse(session.working)
    }

    // MARK: - each frame its own

    /// The second frame's Scene Placement and date ride on the pair's own
    /// rows; picking the other frame trades the two placements and changes
    /// nothing the engine is sent.
    func testEachFrameHasItsOwnPlacementAndDateOnTheWire() throws {
        let (s, urls) = try openedSession(frameCount: 3)
        s.click(urls[0]); s.click(urls[1], command: true)
        s.newPair()
        let pairURL = try XCTUnwrap(s.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        func wire() -> [String: ParamValue] { Dictionary(uniqueKeysWithValues: s.sidecar.params.wire.map { ($0.name, $0.value) }) }
        s.resolveFilmEdge()
        let split = try XCTUnwrap(wire()["scene_latitude_split"])
        XCTAssertEqual(split, .double(s.sidecar.params.pairSplit))
        XCTAssertEqual(s.sidecar.params.pairSplit, 0.5, accuracy: 0.001, "the middle of the gap")

        // A placement set with the left frame picked is the first frame's.
        s.pairLayer = .left
        var p = s.sidecar.params
        p.sceneLatitude.active = true; p.sceneLatitude.highlightRoom = 1.5
        s.sidecar.params = p
        XCTAssertEqual(wire()["scene_latitude_highlight_room"], .double(1.5))
        XCTAssertEqual(wire()["scene_latitude_b_active"], .bool(false))
        XCTAssertEqual(s.pairFitRegion?[0] ?? -1, 0, accuracy: 1e-9)
        let before = wire()
        // Picking the right frame shows *its* placement and sends the same thing.
        s.pairLayer = .right
        XCTAssertFalse(s.sidecar.params.sceneLatitude.active, "the right frame has no placement yet")
        XCTAssertEqual(s.sidecar.params.sceneLatitudeOther.highlightRoom, 1.5)
        XCTAssertEqual(wire(), before, "picking a frame changed what the engine is sent")
        XCTAssertGreaterThan(s.pairFitRegion?[0] ?? 0, 0.5, "the Fit measures the picked frame")
        p = s.sidecar.params
        p.sceneLatitude.active = true; p.sceneLatitude.shadowRoom = 0.75
        s.sidecar.params = p
        XCTAssertEqual(wire()["scene_latitude_b_active"], .bool(true))
        XCTAssertEqual(wire()["scene_latitude_b_shadow_room"], .double(0.75))
        XCTAssertEqual(wire()["scene_latitude_highlight_room"], .double(1.5), "the first frame's curve moved")
        // Swapped, each placement goes with its frame.
        s.swapHoles()
        XCTAssertEqual(wire()["scene_latitude_shadow_room"], .double(0.75))
        XCTAssertEqual(wire()["scene_latitude_b_highlight_room"], .double(1.5))
        // A frame replaced starts with no placement.
        s.setHole(.left, to: urls[2])
        XCTAssertEqual(wire()["scene_latitude_active"], .bool(false))
        XCTAssertEqual(wire()["scene_latitude_b_highlight_room"], .double(1.5))

        // The date with no film edge: the engine is told it is a pair, and
        // the second frame has its own text.
        p = s.sidecar.params
        p.dateBack.active = true
        p.dateBack.customText = "'26 10 4"
        s.sidecar.params = p
        s.resolveFilmEdge()
        let dated = wire()
        XCTAssertEqual(dated["date_imprint_active"], .bool(true))
        XCTAssertEqual(dated["overscan_pair"], .bool(true))
        XCTAssertEqual(dated["overscan_format"], .string("135_half"))
        XCTAssertNotNil(dated["date_imprint_text_b"])
        // A frame is never sent any of it.
        s.click(urls[0])
        s.resolveFilmEdge()
        XCTAssertNil(wire()["scene_latitude_split"])
        XCTAssertNil(wire()["overscan_pair"])
    }

    /// One negative, three prints: a frame's own enlarger and grade change
    /// that frame; *+ Film* moves the film around it by the same amount.
    func testAFramesOwnPrintAndGradeChangeThatFrameOnly() async throws {
        let frames = try copies(2)
        let session = Session(clipboardDefaults: try defaults())
        session.open(urls: [frames[0].deletingLastPathComponent()])
        let urls = session.frames.map(\.id)
        session.click(urls[0]); session.click(urls[1], command: true)
        session.newPair()
        let pairURL = try XCTUnwrap(session.selection)
        addTeardownBlock { try? FileManager.default.removeItem(at: pairURL); Sidecar.remove(for: pairURL) }
        try await waitUntil("the pair to develop", timeout: 180) {
            session.serviceSessionIDForExport != nil && session.frameStates[pairURL] == .processed && !session.busy
        }
        func means() throws -> (first: Double, second: Double) {
            let t = try XCTUnwrap(session.renderer.live)
            let rects = session.pairHoleRects
            return (try mean(t, try XCTUnwrap(rects[.left])), try mean(t, try XCTUnwrap(rects[.right])))
        }
        func settle(after previous: MTLTexture?) async throws {
            try await waitUntil("a new print", timeout: 120) {
                session.renderer.live !== previous && !session.busy && session.frameStates[pairURL] == .processed
            }
        }
        let start = try means()
        XCTAssertEqual(start.first, start.second, accuracy: start.first * 0.02, "the same frame twice prints the same")

        // The second frame alone, a stop and a half brighter.
        session.pairLayer = .right
        session.enlargerScope = .frame
        var before = session.renderer.live
        session.setEnlarger(.brightness, 1.5)
        try await settle(after: before)
        let own = try means()
        XCTAssertEqual(own.first, start.first, accuracy: start.first * 0.01, "the first frame moved with the second's print")
        XCTAssertGreaterThan(own.second, start.second * 1.15, "the second frame's own print did not show")
        XCTAssertEqual(session.sidecar.params.printBrightnessStops, 0, "Frame scope moved the film's print")
        XCTAssertEqual(session.enlargerValue(.brightness), 1.5)
        session.pairLayer = .left
        XCTAssertEqual(session.enlargerValue(.brightness), 0, "the Enlarger shows the picked frame's value")

        // + Film on the first frame: it and the film go up a stop; the second
        // frame, which has a print of its own, stays.
        session.enlargerScope = .film
        before = session.renderer.live
        session.setEnlarger(.brightness, 1.0)
        try await settle(after: before)
        let both = try means()
        XCTAssertGreaterThan(both.first, own.first * 1.1)
        XCTAssertEqual(both.second, own.second, accuracy: own.second * 0.01, "+ Film moved the other frame")
        XCTAssertEqual(session.sidecar.params.printBrightnessStops, 1.0, "the film's print follows by the same amount")

        // The second frame's own grade.
        session.pairLayer = .right
        before = session.renderer.live
        var grade = session.layerAdjustments
        grade.exposure = -1
        session.layerAdjustments = grade
        try await settle(after: before)
        let graded = try means()
        XCTAssertLessThan(graded.second, both.second * 0.8, "the frame's own grade did not show")
        XCTAssertEqual(graded.first, both.first, accuracy: both.first * 0.01, "the grade landed on the other frame")
        XCTAssertEqual(session.sidecar.adjustments, Adjustments(), "the film's grade was edited instead")
        XCTAssertEqual(HalfFramePair.load(pairURL)?.right?.adjustments?.exposure, -1)

        // ⌘Z takes the grade back off the frame.
        before = session.renderer.live
        session.undo()
        XCTAssertNil(session.pair?.right?.adjustments)
    }

    private func mean(_ t: MTLTexture, _ n: CGRect) throws -> Double {
        let bytes = t.rgba16Bytes()
        try XCTSkipIf(bytes.isEmpty, "the print is not a 16-bit texture")
        let x0 = Int(n.minX * CGFloat(t.width)) + 12, x1 = Int(n.maxX * CGFloat(t.width)) - 12
        let y0 = Int(n.minY * CGFloat(t.height)) + 12, y1 = Int(n.maxY * CGFloat(t.height)) - 12
        var sum = 0.0, count = 0.0
        bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for y in stride(from: y0, to: y1, by: 4) {
                for x in stride(from: x0, to: x1, by: 4) {
                    let i = (y * t.width + x) * 4
                    sum += Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2]); count += 3
                }
            }
        }
        return sum / max(count, 1)
    }

    // MARK: - helpers

    private func defaults() throws -> UserDefaults {
        let suite = "spk-pair-defaults-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    private func folderOfFrames(_ count: Int) throws -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let urls = try (0..<count).map { i -> URL in
            let url = dir.appending(path: String(format: "frame-%02d.png", i))
            try Data().write(to: url)
            return url
        }
        return (dir, urls)
    }

    private func openedSession(frameCount: Int) throws -> (Session, [URL]) {
        let (dir, _) = try folderOfFrames(frameCount)
        let session = Session(clipboardDefaults: try defaults())
        session.open(urls: [dir])
        return (session, session.frames.map(\.id))
    }

    /// Copies of the fixture in one folder, never the fixture itself.
    private func copies(_ count: Int) throws -> [URL] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "the fixture is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try (0..<count).map { i in
            let url = dir.appending(path: "frame-\(i).tif")
            try FileManager.default.copyItem(at: source, to: url)
            return url
        }
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
