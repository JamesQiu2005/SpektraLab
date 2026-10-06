import XCTest

/// Scene Placement's sliders always land somewhere (1.3.2).
///
/// Reported by the owner on 1.3.1: a slider pulled anywhere but a narrow
/// stretch of its track went back to where it was on release, or did not move
/// at all, and typing 5 and then 0.5 left 5. All three are one thing — the Fit
/// takes a window of pull-backs, and the slider asked for whatever was under
/// the pointer and kept nothing when it was refused. The unit tests pin the
/// window search; the session test is the report, on a real RAW.
@MainActor
final class ScenePlacementTests: XCTestCase {
    private typealias Issue = SceneLatitudeResponse.Fit.Issue

    /// A Fit that takes the open interval `(low, high)` and refuses the rest
    /// the way the engine does, counting what it was asked.
    private final class FakeFit {
        let low: Double, high: Double
        var asked = 0
        init(_ low: Double, _ high: Double) { self.low = low; self.high = high }
        func verdict(_ x: Double) -> PlacementWindow.Verdict {
            asked += 1
            if x <= low { return .refused(Issue(code: "room_below_minimum", side: "highlight", message: "")) }
            if x >= high { return .refused(Issue(code: "knees_cross", side: "both", message: "")) }
            return .valid
        }
    }

    // MARK: - the search

    func testTheSearchFindsBothEdgesToTheHundredth() throws {
        let fit = FakeFit(1.37, 3.42)
        let window = PlacementWindow.search(side: .highlight, minimum: 0.9, in: 0...8) { fit.verdict($0) }
        let span = try XCTUnwrap(window.span)
        XCTAssertEqual(fit.verdict(span.lowerBound), .valid)
        XCTAssertEqual(fit.verdict(span.upperBound), .valid)
        XCTAssertLessThan(span.lowerBound - 1.37, 0.02, "the least is not at the edge")
        XCTAssertLessThan(3.42 - span.upperBound, 0.02, "the most is not at the edge")
        // The reasons are the edges' own, and each is about this row.
        XCTAssertEqual(window.below.code, "room_below_minimum")
        XCTAssertEqual(window.above?.code, "knees_cross")
        XCTAssertEqual(window.above?.side, "highlight", "a both-sides refusal would print on the other row too")
        XCTAssertLessThan(fit.asked, 40, "the search is meant to cost a few dozen probes")
    }

    func testAValueOutsideTheWindowLandsOnItsNearerEdge() throws {
        let fit = FakeFit(1.37, 3.42)
        let window = PlacementWindow.search(side: .shadow, minimum: 0.9, in: 0...8) { fit.verdict($0) }
        let span = try XCTUnwrap(window.span)
        XCTAssertEqual(window.landing(0).value, 0, "off is off")
        XCTAssertNil(window.landing(0).why)
        XCTAssertEqual(window.landing(0.5).value, span.lowerBound)
        XCTAssertEqual(window.landing(0.5).why?.code, "room_below_minimum")
        XCTAssertEqual(window.landing(2).value, 2)
        XCTAssertNil(window.landing(2).why)
        XCTAssertEqual(window.landing(7).value, span.upperBound)
        XCTAssertEqual(window.landing(7).why?.code, "knees_cross")
    }

    func testTheTopOfTheTrackIsTheMostWhenTheFitTakesIt() throws {
        let fit = FakeFit(0, 99)
        let window = PlacementWindow.search(side: .highlight, minimum: -1, in: 0...8) { fit.verdict($0) }
        XCTAssertEqual(window.span?.upperBound, 8)
        XCTAssertNil(window.above)
        XCTAssertLessThanOrEqual(try XCTUnwrap(window.span).lowerBound, 0.011)
    }

    func testNoWindowTurnsTheSideOffAndSaysSo() throws {
        // The owner's frame: the minimum 3.74 under a lift bound of 4, and
        // nothing between them the Fit takes.
        let window = PlacementWindow.search(side: .shadow, minimum: 3.74, in: 0...8) { _ in
            .refused(Issue(code: "pull_back_exceeds_max_lift", side: "shadow", message: ""))
        }
        XCTAssertNil(window.span)
        XCTAssertEqual(window.landing(5).value, 0)
        XCTAssertEqual(window.landing(5).why?.code, PlacementWindow.noWindowCode)
    }

    // MARK: - the report, reproduced

    /// On a real RAW, through the call the sliders make: a pull-back the Fit
    /// refuses is committed at the nearest one it takes, with the reason on
    /// the row — and 5 then 0.5 does not leave 5.
    func testASliderValueTheFitRefusesStillLands() async throws {
        let raw = try copy(of: "A7m3/DSC03710.ARW")
        let s = Session()
        s.open(urls: [raw])
        try await waitUntil("the engine to warm up") { s.serviceReady }
        s.click(raw)
        try await waitUntil("the frame to decode", timeout: 60) { s.selection == raw && s.decoded != nil }
        s.requestPrint()
        try await settle(s)
        let measured = await s.measureLatitude()
        let reply = try XCTUnwrap(measured, "cannot be measured: \(s.latitude.failure ?? "no reason")")

        let hi = reply.fit.highlight.minimumPullBack, lo = reply.fit.shadow.minimumPullBack
        let side: PlacementSide = hi > 0.2 ? .highlight : .shadow
        let minimum = side == .highlight ? hi : lo
        try XCTSkipUnless(minimum > 0.2, "this frame has no refused span on either side (\(hi), \(lo))")
        func committed() -> Double {
            side == .highlight ? s.params.sceneLatitude.highlightPullBack : s.params.sceneLatitude.shadowPullBack
        }
        func place(_ v: Double) {
            s.placeScene(highlight: side == .highlight ? v : 0, shadow: side == .shadow ? v : 0, moving: side)
        }

        // The agent's door still refuses half the minimum: the engine has not
        // changed, only what the slider asks it for.
        let refused = await s.placeSceneNow(highlight: side == .highlight ? minimum / 2 : 0,
                                            shadow: side == .shadow ? minimum / 2 : 0)
        XCTAssertEqual(refused?.fit.valid, false, "the Fit accepted half its own minimum")
        XCTAssertEqual(committed(), 0)

        let window = try XCTUnwrap(s.placementWindow(for: side, other: 0), "measured, and no window to draw")
        let span = try XCTUnwrap(window.span, "this frame's \(side) cannot be placed at all")
        XCTAssertGreaterThan(span.lowerBound, minimum)

        // Dragged into the refused stretch: it lands on the edge, and it has
        // landed by the time the call returns — nothing is in flight for the
        // knob to wait on, which is what made the drag late.
        place(minimum / 2)
        XCTAssertEqual(committed(), span.lowerBound, accuracy: 1e-9, "the slider went back to where it was")
        XCTAssertTrue(s.params.sceneLatitude.active)
        XCTAssertNotNil(s.latitude.refusalMessage(for: side.rawValue), "the row does not say why it stopped")

        // Typed 5, then 0.5.
        place(5)
        let five = committed()
        XCTAssertEqual(five, window.landing(5).value, accuracy: 1e-9)
        place(0.5)
        XCTAssertEqual(committed(), window.landing(0.5).value, accuracy: 1e-9)
        if span.lowerBound < span.upperBound - 0.05, window.landing(0.5).value != five {
            XCTAssertNotEqual(committed(), five, "0.5 left the 5 that was typed before it")
        }

        // Inside the window nothing is moved and nothing is said.
        let inside = (span.lowerBound + span.upperBound) / 2
        place(inside)
        XCTAssertEqual(committed(), inside, accuracy: 1e-9)
        XCTAssertNil(s.latitude.refusalMessage(for: side.rawValue))

        // Past the top of what the Fit takes: the upper edge.
        place(8)
        XCTAssertEqual(committed(), span.upperBound, accuracy: 1e-9)

        // And off is still off.
        place(0)
        XCTAssertEqual(committed(), 0)
        XCTAssertFalse(s.params.sceneLatitude.active)
    }

    // MARK: - a drag, step by step

    /// The steps a drag makes, in order, through the call the slider's
    /// binding makes: each one has moved the committed value by the time it
    /// returns, the value follows out and back, and nothing arrives later to
    /// move it again. (The gesture itself is `ScrubSlider`'s, shared with
    /// every slider; an offscreen window does not deliver mouse events to it,
    /// so this starts one call below the hand.)
    func testEachStepOfADragIsCommittedAtOnce() async throws {
        let raw = try copy(of: "A7m3/DSC03710.ARW")
        let s = Session()
        s.open(urls: [raw])
        try await waitUntil("the engine to warm up") { s.serviceReady }
        s.click(raw)
        try await waitUntil("the frame to decode", timeout: 60) { s.selection == raw && s.decoded != nil }
        s.requestPrint()
        try await settle(s)
        try await waitUntil("the frame to be measured") { s.placementMeasure != nil }
        let span = try XCTUnwrap(s.placementWindow(for: .highlight, other: 0)?.span,
                                 "this frame's highlights cannot be placed")
        try XCTSkipUnless(span.upperBound - span.lowerBound > 1, "too narrow a window to drag in: \(span)")
        func highlight() -> Double { s.params.sceneLatitude.highlightPullBack }

        // From off, up through the refused stretch, across the window, past
        // its top, and back.
        let out = Array(stride(from: 0.2, through: 9, by: 0.2))
        var trace: [Double] = []
        let started = Date()
        for v in out + out.reversed() {
            s.placeScene(highlight: v, shadow: 0, moving: .highlight)
            XCTAssertEqual(highlight(), min(max(v, span.lowerBound), span.upperBound), accuracy: 1e-9,
                           "asked for \(v): the step was not committed where it lands")
            trace.append(highlight())
        }
        let perStep = Date().timeIntervalSince(started) / Double(trace.count)
        XCTAssertLessThan(perStep, 0.004, "a step costs \(perStep * 1000) ms on the main thread")
        let held = highlight()
        try await settle(s)
        XCTAssertEqual(highlight(), held, "the value moved after the drag ended")
        XCTAssertEqual(s.sidecar.params.sceneLatitude.highlightRoom > 0, true)
        print(String(format: "placement drag: %d steps, %.3f ms each", trace.count, perStep * 1000))
    }

    // MARK: - the solve is the engine's

    /// `PlacementFit` against `spk_scene_latitude`, on a real frame, over
    /// pull-backs on both sides of every refusal and at each roll-off, lift
    /// bound and percentile the wire takes: the same verdict, the same first
    /// reason, the same knees and rooms. The engine's is the reference; this
    /// fails when either is changed without the other.
    func testTheLocalSolveIsTheEngines() async throws {
        let raw = try copy(of: "A7m3/DSC03710.ARW")
        let s = Session()
        s.open(urls: [raw])
        try await waitUntil("the engine to warm up") { s.serviceReady }
        s.click(raw)
        try await waitUntil("the frame to decode", timeout: 60) { s.selection == raw && s.decoded != nil }
        s.requestPrint()
        try await settle(s)

        var compared = 0, solved = 0
        var refusals = Set<String>()
        for (rolloff, lift, percentile) in [(2.0, 4.0, 0.1), (2.0, 8.0, 0.1), (2.0, 4.0, 1.0), (1.0, 8.0, 1.0),
                                            (3.0, 12.0, 0.1)] {
            var base = SceneLatitudeSettings()
            base.rolloff = rolloff; base.maxLift = lift; base.shadowPercentile = percentile
            var request = base.request
            request.highlightPullBack = 0; request.shadowPullBack = 0
            let at = PlacementFit.Measured(try await s.client.sceneLatitude(request).fit)
            let hs = [0, at.minimum(.highlight) * 0.5, at.minimum(.highlight) + 0.004, at.minimum(.highlight) + 0.3,
                      at.minimum(.highlight) + 1.5, 7.9, 12]
            let ss = [0, at.minimum(.shadow) * 0.5, at.minimum(.shadow) + 0.004, at.minimum(.shadow) + 0.3,
                      at.minimum(.shadow) + 1.5, lift - 0.01, lift, 7.9]
            for h in hs.map({ max($0, 0) }) {
                for sh in ss.map({ max($0, 0) }) {
                    request.highlightPullBack = h; request.shadowPullBack = sh
                    let engine = try await s.client.sceneLatitude(request).fit
                    let local = PlacementFit.fit(at, highlight: h, shadow: sh, base: base)
                    let what = "m \(rolloff), lift \(lift), P\(percentile), highlight \(h), shadow \(sh)"
                    compared += 1
                    switch local {
                    case .refused(let why):
                        XCTAssertFalse(engine.valid, "the engine takes what the app refuses: \(what)")
                        XCTAssertEqual(why.code, engine.issues.first?.code, what)
                        XCTAssertEqual(why.side, engine.issues.first?.side, what)
                        refusals.insert(why.code)
                    case .solved(let placed):
                        XCTAssertTrue(engine.valid, "the app takes what the engine refuses (\(engine.issues)): \(what)")
                        var viaEngine = base
                        guard viaEngine.apply(engine) else { continue }
                        solved += 1
                        XCTAssertEqual(placed.active, viaEngine.active, what)
                        XCTAssertEqual(placed.highlightPullBack, viaEngine.highlightPullBack, what)
                        XCTAssertEqual(placed.shadowPullBack, viaEngine.shadowPullBack, what)
                        XCTAssertEqual(placed.highlightRoom, viaEngine.highlightRoom, accuracy: 1e-9, what)
                        XCTAssertEqual(placed.shadowRoom, viaEngine.shadowRoom, accuracy: 1e-9, what)
                        if placed.highlightRoom > 0 {
                            XCTAssertEqual(placed.highlightKnee, viaEngine.highlightKnee, accuracy: 1e-9, what)
                        }
                        if placed.shadowRoom > 0 {
                            XCTAssertEqual(placed.shadowKnee, viaEngine.shadowKnee, accuracy: 1e-9, what)
                        }
                    }
                }
            }
        }
        // It compared something on each side of the line, or it proved nothing.
        print("placement parity: \(compared) fits, \(solved) solved, refusals \(refusals.sorted())")
        XCTAssertGreaterThan(solved, 20)
        XCTAssertGreaterThanOrEqual(refusals.count, 3, "\(refusals)")
    }

    // MARK: - helpers

    private func copy(of relativePath: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/\(relativePath)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "\(relativePath) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-placement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func settle(_ s: Session) async throws {
        try await waitUntil("the develop", timeout: 90) {
            s.serviceSessionIDForExport != nil && !s.busy && !s.scheduler.pending
        }
        try await Task.sleep(for: .milliseconds(800))
        try await waitUntil("the queue to drain", timeout: 30) { !s.busy && !s.scheduler.pending }
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
