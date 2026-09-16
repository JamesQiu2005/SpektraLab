//  PanelResizeWiringTests.swift — the editor's end of the resizable panels.
//
//  `Controls/PanelResize.swift` owns the range and the grip and is tested by
//  whoever owns it; what this pins is the *editor's* use of it, which is the
//  half that can silently disagree:
//
//  * the bounds the editor ships, and that the standard is still the drawing's
//    width — a fresh install has to measure what every snapshot before the
//    panels were resizable measured;
//  * the relationship between a panel's width and the width the colour balance
//    triangle sizes itself against, which is a *derived* number and was a
//    constant until it had to stop being one.

import SwiftUI
import XCTest

@MainActor
final class PanelResizeWiringTests: XCTestCase {

    /// The standard is the drawing's own width, and the bounds contain it.
    ///
    /// `PanelWidthRange` clamps a standard that falls outside its own bounds,
    /// so a range written the wrong way round would not fail here — it would
    /// come back with a different standard. This asserts all three.
    func testTheRangesKeepTheDrawingAsTheStandard() {
        let left = Theme.Metric.leftPanelRange
        XCTAssertEqual(left.standard, Theme.Metric.leftPanelWidth)
        XCTAssertLessThan(left.narrowest, left.standard)
        XCTAssertGreaterThan(left.widest, left.standard)

        let right = Theme.Metric.rightPanelRange
        XCTAssertEqual(right.standard, Theme.Metric.rightPanelWidth)
        XCTAssertLessThan(right.narrowest, right.standard)
        XCTAssertGreaterThan(right.widest, right.standard)
    }

    /// The floors the captures found, so a later edit cannot quietly go below
    /// them.
    ///
    /// **These are measured, not chosen.** Both rails' narrow ends are set by
    /// one control each, and each was found by capturing at a series of
    /// widths: the left by the AE Method pill, whose longest value is
    /// `center-weighted (legacy)`; the right by the colour balance tab row,
    /// which ellipsized at 276 and fit at 286. The test asserts the *bounds*,
    /// not the strings — what it protects is that a narrowest which truncates
    /// never ships again.
    ///
    /// The left figure changed with the 2026-09-17 drawing and had to: the old
    /// 316 was measured on a 328 pt panel whose rows were inset 9 and whose
    /// labels were 70 pt of 11 pt semibold. The new rail is 254 with an 18 pt
    /// inset and a 74 pt label column, so the pill's own floor is
    /// `rowInset × 2 + sliderLabelWidth` plus the longest string — 110 pt of
    /// it at 10.5 pt — and 232 is that with air.
    func testTheBoundsStayAboveWhatTheContentMeasured() {
        let aeFloor = 2 * Theme.Metric.rowInset + Theme.Metric.sliderLabelWidth + 110
        XCTAssertGreaterThanOrEqual(Theme.Metric.leftPanelRange.narrowest, aeFloor,
                                    "the AE Method pill truncates below \(aeFloor)")
        XCTAssertGreaterThanOrEqual(Theme.Metric.rightPanelRange.narrowest, 268,
                                    "the colour balance tab row is past what 0.85 scale covers")
        // And the widest ends stay where the controls stop growing, rather than
        // drifting into "as wide as the window".
        XCTAssertLessThanOrEqual(Theme.Metric.leftPanelRange.widest, 420)
        XCTAssertLessThanOrEqual(Theme.Metric.rightPanelRange.widest, 364)
    }

    /// The colour balance wheels and the panel they sit in are the same
    /// number, arrived at from one place.
    ///
    /// `assumedWidth` is the fallback for a caller with no panel width to give,
    /// and it has to *be* the editor's own panel — otherwise a test, or the
    /// export page, would check the triangle against a well the editor never
    /// draws. The editor passes `interior(panelWidth:)` with its live width.
    func testTheColourBalanceWidthFollowsThePanel() {
        XCTAssertEqual(ColorBalanceLayout.assumedWidth,
                       ColorBalanceLayout.interior(panelWidth: Theme.Metric.rightPanelWidth),
                       "the wheels' fallback is not what the drawing's panel gives them")
        // 288 − 2 × (4 + 12): the 2026-09-17 drawing's rail, and its wells,
        // which are held 4 pt off the rail's edges rather than the old 9.
        XCTAssertEqual(ColorBalanceLayout.assumedWidth, 256, accuracy: 0.001)

        // It has to actually move with the panel, and a narrower panel must
        // give the wheels less room — a `max()` anywhere in there would make
        // the narrow end silently stop working.
        let narrow = ColorBalanceLayout.interior(panelWidth: Theme.Metric.rightPanelRange.narrowest)
        let wide = ColorBalanceLayout.interior(panelWidth: Theme.Metric.rightPanelRange.widest)
        XCTAssertLessThan(narrow, ColorBalanceLayout.assumedWidth)
        XCTAssertGreaterThan(wide, ColorBalanceLayout.assumedWidth)

        // And the triangle has to report that it still fits at the narrow end,
        // which is the wheels' own floor and not the tab row's.
        XCTAssertTrue(ColorBalanceLayout.threeWay(width: narrow).fits,
                      "the triangle does not fit at the panel's narrowest")
    }

    /// Everything about the store, on a **throwaway suite**.
    ///
    /// Its `defaults:` parameter is a real injection — it reads *and* writes
    /// through it — so this never touches the user's own preferences, which is
    /// the whole point of the parameter and the hazard trap 24 is about. (It
    /// was not, for one round: the `didSet` wrote to `UserDefaults.standard`
    /// whatever suite it was handed, so a test that injected one to stay away
    /// from the real store wrote to it anyway. Found here by a test failing for
    /// the right reason, and fixed in `Controls/PanelResize.swift`.)
    func testStoredWidthsRoundTripAndAreClamped() throws {
        let suite = "panel-resize-wiring-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let range = Theme.Metric.leftPanelRange

        // Nothing stored: the drawing's width.
        XCTAssertEqual(PanelWidthStore(name: "t.fresh", range: range, defaults: defaults).width,
                       range.standard)

        // A width the user sets survives a relaunch, under the store's key.
        let store = PanelWidthStore(name: "t.round", range: range, defaults: defaults)
        store.width = range.narrowest + 7
        XCTAssertEqual(PanelWidthStore(name: "t.round", range: range, defaults: defaults).width,
                       range.narrowest + 7,
                       "the width did not come back — the app would reopen at a width nobody chose")

        // Stored past either bound: clamped, because a bound is a bound — a
        // range tightened in a later build must not resurrect an old width.
        defaults.set(Double(range.widest + 500), forKey: "ui.panelWidth.t.over")
        XCTAssertEqual(PanelWidthStore(name: "t.over", range: range, defaults: defaults).width, range.widest)
        defaults.set(Double(range.narrowest - 500), forKey: "ui.panelWidth.t.under")
        XCTAssertEqual(PanelWidthStore(name: "t.under", range: range, defaults: defaults).width,
                       range.narrowest)

        // And the write goes through the *injected* suite, which is what makes
        // the test above safe to run at all.
        //
        // Cleared first, and cleaned up after: an earlier version of this test
        // ran against the pre-fix store, which wrote through
        // `UserDefaults.standard` regardless of the suite — so the process-wide
        // domain on this machine still holds what it leaked. Removing the key
        // makes this assertion about *this* run rather than about that one.
        let escaped = "ui.panelWidth.t.round"
        UserDefaults.standard.removeObject(forKey: escaped)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: escaped) }
        XCTAssertEqual(defaults.object(forKey: escaped) as? Double, Double(range.narrowest + 7))
        XCTAssertNil(UserDefaults.standard.object(forKey: escaped),
                     "the store wrote to the process-wide preferences despite being handed a suite")
    }
}
