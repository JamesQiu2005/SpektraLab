import AppKit
import SwiftUI
import XCTest

/// Nothing a rail shows may make the rail wider than itself (1.2.2).
///
/// Reported from Xiaohongshu on 1.2.1: a user dragged Scene Placement's
/// Highlight into the refused span, and the engine's refusal — a sentence,
/// drawn as the slider's sub-label with `.fixedSize()` — made the Parameters
/// rail's content wider than the window, pushing every value pill off its
/// right edge. It never showed on the author's machine because it needs a
/// refusal. These fail on 1.2.1 and pass on the fix.
@MainActor
final class RailFitTests: XCTestCase {

    /// The width a rail's rows get at its standard width: the Parameters
    /// rail less nothing — the sections pad themselves.
    private let railWidth = Theme.Metric.rightPanelWidth

    /// How wide a view wants to be when offered `width`.
    private func width<V: View>(of view: V, offered width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view.environment(\.railSliderMetrics, .parameters))
        return host.sizeThatFits(in: CGSize(width: width, height: 4000)).width
    }

    // MARK: - the unit

    /// A slider whose second line is a sentence stays inside what it is
    /// offered: the sentence wraps.
    func testASublabelNeverWidensTheRow() {
        let sentence = "the highlight pull-back lands the scene's top at or past the medium's boundary; "
            + "it must exceed the minimum"
        let slider = ScrubSlider(label: "Highlight", sublabel: sentence,
                                 value: .constant(0.5), range: 0...4)
        let w = width(of: slider, offered: railWidth)
        XCTAssertLessThanOrEqual(w, railWidth + 0.5,
                                 "a sub-label made the slider \(w) pt wide on a \(railWidth) pt rail")
    }

    // MARK: - the report, reproduced

    /// A real refusal on a real RAW: the Scene Placement section, with the
    /// refusal on its row, fits the rail — in both languages.
    func testARefusedPlacementKeepsTheRailInsideItsWidth() async throws {
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

        // Half the minimum on whichever side has one: a pull-back the Fit
        // must refuse.
        let hi = reply.fit.highlight.minimumPullBack, lo = reply.fit.shadow.minimumPullBack
        let side = hi > 0.2 ? "highlight" : "shadow"
        let minimum = side == "highlight" ? hi : lo
        try XCTSkipUnless(minimum > 0.2, "this frame has no refused span on either side (\(hi), \(lo))")
        let refused = await s.placeSceneNow(highlight: side == "highlight" ? minimum / 2 : 0,
                                            shadow: side == "shadow" ? minimum / 2 : 0)
        XCTAssertEqual(refused?.fit.valid, false, "the Fit accepted half its own minimum")
        let message = try XCTUnwrap(s.latitude.refusalMessage(for: side), "no refusal on the \(side) row")

        let language = Localization.shared.language
        defer { Localization.shared.language = language }
        for setting in [LanguageSetting.english, .simplifiedChinese] {
            Localization.shared.language = setting
            let w = width(of: ScenePlacementSection(session: s), offered: railWidth)
            XCTAssertLessThanOrEqual(w, railWidth + 0.5,
                                     "\(setting): Scene Placement is \(w) pt wide with its refusal shown")
        }

        // The row speaks the interface, names the number the slider's dimmed
        // stretch shows, and no longer says "medium".
        XCTAssertFalse(message.contains("medium"), message)
        Localization.shared.language = .simplifiedChinese
        let zh = try XCTUnwrap(s.latitude.refusalMessage(for: side))
        XCTAssertTrue(zh.contains(String(format: "%.2f", minimum)), zh)
        XCTAssertTrue(zh.contains("宽容度"), zh)
    }

    // MARK: - the CINE mark sits inside the selection

    /// The pill lies wholly inside the selection capsule, so a selected CINE
    /// stock never wears half a badge on the white (1.2.1 put it across the
    /// capsule's rounded end).
    func testTheCinePillSitsInsideTheSelection() {
        let m = Theme.Metric.self
        let pillTrailing = m.cinePillTrailing
        let pillLeading = m.cinePillTrailing + m.cinePill.width
        XCTAssertGreaterThanOrEqual(pillTrailing, m.stockTrailingInset + 2,
                                    "the pill's trailing edge is past the capsule's end")
        XCTAssertLessThan(pillLeading, m.leftPanelWidth - m.stockTextLeadingInset - 60,
                          "the pill leaves the stock's name no room")
    }

    // MARK: - helpers

    private func copy(of relativePath: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/\(relativePath)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "\(relativePath) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-railfit-\(UUID().uuidString)")
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
