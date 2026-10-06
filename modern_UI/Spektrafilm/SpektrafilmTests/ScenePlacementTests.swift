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
        func verdict(_ x: Double) -> PlacementWindow.Verdict? {
            asked += 1
            if x <= low { return .refused(Issue(code: "room_below_minimum", side: "highlight", message: "")) }
            if x >= high { return .refused(Issue(code: "knees_cross", side: "both", message: "")) }
            return .valid
        }
    }

    // MARK: - the search

    func testTheSearchFindsBothEdgesToTheHundredth() async throws {
        let fit = FakeFit(1.37, 3.42)
        let found = await PlacementWindow.search(side: .highlight, minimum: 0.9, in: 0...8) { fit.verdict($0) }
        let window = try XCTUnwrap(found)
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

    func testAValueOutsideTheWindowLandsOnItsNearerEdge() async throws {
        let fit = FakeFit(1.37, 3.42)
        let found = await PlacementWindow.search(side: .shadow, minimum: 0.9, in: 0...8) { fit.verdict($0) }
        let window = try XCTUnwrap(found)
        let span = try XCTUnwrap(window.span)
        XCTAssertEqual(window.landing(0).value, 0, "off is off")
        XCTAssertNil(window.landing(0).why)
        XCTAssertEqual(window.landing(0.5).value, span.lowerBound)
        XCTAssertEqual(window.landing(0.5).why?.code, "room_below_minimum")
        XCTAssertEqual(window.landing(2).value, 2)
        XCTAssertNil(window.landing(2).why)
        XCTAssertEqual(window.landing(7).value, span.upperBound)
        XCTAssertEqual(window.landing(7).why?.code, "knees_cross")
        XCTAssertEqual(window.blocked(in: 0...8), [0...span.lowerBound, span.upperBound...8])
    }

    func testTheTopOfTheTrackIsTheMostWhenTheFitTakesIt() async throws {
        let fit = FakeFit(0, 99)
        let found = await PlacementWindow.search(side: .highlight, minimum: -1, in: 0...8) { fit.verdict($0) }
        let window = try XCTUnwrap(found)
        XCTAssertEqual(window.span?.upperBound, 8)
        XCTAssertNil(window.above)
        XCTAssertLessThanOrEqual(try XCTUnwrap(window.span).lowerBound, 0.011)
        XCTAssertEqual(window.blocked(in: 0...8), [], "nothing to dim when everything above zero is taken")
    }

    func testNoWindowTurnsTheSideOffAndSaysSo() async throws {
        // The owner's frame: the minimum 3.74 under a lift bound of 4, and
        // nothing between them the Fit takes.
        let found = await PlacementWindow.search(side: .shadow, minimum: 3.74, in: 0...8) { _ in
            .refused(Issue(code: "pull_back_exceeds_max_lift", side: "shadow", message: ""))
        }
        let window = try XCTUnwrap(found)
        XCTAssertNil(window.span)
        XCTAssertEqual(window.landing(5).value, 0)
        XCTAssertEqual(window.landing(5).why?.code, PlacementWindow.noWindowCode)
        XCTAssertEqual(window.blocked(in: 0...8), [0...8], "the whole track is dimmed")
    }

    func testAProbeThatCannotBeMadeIsNotAnEmptyWindow() async {
        let found = await PlacementWindow.search(side: .shadow, minimum: 1, in: 0...8) { _ in nil }
        XCTAssertNil(found, "an engine that did not answer was read as 'nothing works'")
    }

    func testWhatIsKnownBeforeTheSearchIsTheMinimumAndTheLiftBound() {
        let shadow = PlacementWindow.known(side: .shadow, minimum: 1.234, maxLift: 4, in: 0...8)
        XCTAssertEqual(try XCTUnwrap(shadow.span).lowerBound, 1.24, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(shadow.span).upperBound, 3.99, accuracy: 1e-9)
        let highlight = PlacementWindow.known(side: .highlight, minimum: -2, maxLift: 4, in: 0...8)
        XCTAssertEqual(try XCTUnwrap(highlight.span).upperBound, 8)
        XCTAssertEqual(highlight.blocked(in: 0...8), [])
        XCTAssertNil(PlacementWindow.known(side: .shadow, minimum: 4.2, maxLift: 4, in: 0...8).span)
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
        func place(_ v: Double) async {
            s.placeScene(highlight: side == .highlight ? v : 0, shadow: side == .shadow ? v : 0, moving: side)
            await withCheckedContinuation { done in s.whenPlacementSettles { done.resume() } }
        }

        // The agent's door still refuses half the minimum: the engine has not
        // changed, only what the slider asks it for.
        let refused = await s.placeSceneNow(highlight: side == .highlight ? minimum / 2 : 0,
                                            shadow: side == .shadow ? minimum / 2 : 0)
        XCTAssertEqual(refused?.fit.valid, false, "the Fit accepted half its own minimum")
        XCTAssertEqual(committed(), 0)

        let started = Date()
        let searched = await s.placementWindow(for: side, other: 0)
        let window = try XCTUnwrap(searched)
        print("placement window \(side): \(String(describing: window.span)) in "
              + "\(Int(Date().timeIntervalSince(started) * 1000)) ms, minimum \(minimum)")
        let span = try XCTUnwrap(window.span, "this frame's \(side) cannot be placed at all")
        XCTAssertGreaterThan(span.lowerBound, minimum)

        // Dragged into the refused stretch: it lands on the edge.
        await place(minimum / 2)
        XCTAssertEqual(committed(), span.lowerBound, accuracy: 1e-9, "the slider went back to where it was")
        XCTAssertTrue(s.params.sceneLatitude.active)
        XCTAssertNotNil(s.latitude.refusalMessage(for: side.rawValue), "the row does not say why it stopped")

        // Typed 5, then 0.5.
        await place(5)
        let five = committed()
        XCTAssertEqual(five, window.landing(5).value, accuracy: 1e-9)
        await place(0.5)
        XCTAssertEqual(committed(), window.landing(0.5).value, accuracy: 1e-9)
        if span.lowerBound < span.upperBound - 0.05, window.landing(0.5).value != five {
            XCTAssertNotEqual(committed(), five, "0.5 left the 5 that was typed before it")
        }

        // Inside the window nothing is moved and nothing is said.
        let inside = (span.lowerBound + span.upperBound) / 2
        await place(inside)
        XCTAssertEqual(committed(), inside, accuracy: 1e-9)
        XCTAssertNil(s.latitude.refusalMessage(for: side.rawValue))

        // Past the top of what the Fit takes: the upper edge.
        await place(8)
        XCTAssertEqual(committed(), span.upperBound, accuracy: 1e-9)

        // And off is still off.
        await place(0)
        XCTAssertEqual(committed(), 0)
        XCTAssertFalse(s.params.sceneLatitude.active)
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
