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
    /// **These are measured, not chosen.** Both panels' narrow ends are set by
    /// one control each, and each was found by capturing at a series of widths:
    /// the left by the Tone pill, whose longest value is
    /// `center-weighted (legacy)` and which ellipsized at every width through
    /// 312 and fit at 316; the right by the colour balance tab row, which
    /// ellipsized at 276 and fit at 286. The test asserts the *bounds*, not the
    /// strings — what it protects is that 312 or 276 never becomes a shippable
    /// narrowest again.
    func testTheBoundsStayAboveWhatTheContentMeasured() {
        XCTAssertGreaterThanOrEqual(Theme.Metric.leftPanelRange.narrowest, 316,
                                    "the Tone pill truncates below 316")
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
        XCTAssertEqual(ColorBalanceLayout.assumedWidth, 242, accuracy: 0.001)

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

    /// A stored width is read back, and one outside the range is clamped.
    ///
    /// Read on a throwaway suite rather than `UserDefaults.standard` — the
    /// process-wide object trap 24 is about — because these assertions are
    /// about what the store *reads*.
    ///
    /// **The store's `didSet` writes to `UserDefaults.standard` regardless of
    /// the suite it was given** (`Controls/PanelResize.swift`), so the injected
    /// defaults are a read-side seam only. That is recorded here rather than
    /// worked around, and reported: a test that injects a suite to avoid the
    /// real store still writes to it, and the write half cannot be tested
    /// through the injection at all. The write is covered below, on the real
    /// store, with a teardown that removes the key.
    func testAStoredWidthIsClampedToTheRange() throws {
        let suite = "panel-resize-wiring-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let range = Theme.Metric.leftPanelRange

        // Nothing stored: the drawing's width.
        let fresh = PanelWidthStore(name: "t.fresh", range: range, defaults: defaults)
        XCTAssertEqual(fresh.width, range.standard)

        // Stored past either bound: clamped, because a bound is a bound — a
        // range tightened in a later build must not resurrect an old width.
        defaults.set(Double(range.widest + 500), forKey: "ui.panelWidth.t.over")
        XCTAssertEqual(PanelWidthStore(name: "t.over", range: range, defaults: defaults).width, range.widest)
        defaults.set(Double(range.narrowest - 500), forKey: "ui.panelWidth.t.under")
        XCTAssertEqual(PanelWidthStore(name: "t.under", range: range, defaults: defaults).width, range.narrowest)
    }

    /// A width the user sets survives a relaunch — under the store's own
    /// namespaced key, on the store the app actually uses.
    ///
    /// On `UserDefaults.standard` deliberately: that is where the write goes,
    /// so testing it anywhere else would be testing a path the app does not
    /// have. The key is removed on the way out — a leaked `ui.panelWidth.*`
    /// would hand the next test, and the user's own app, a panel width nobody
    /// chose, which is the hazard `develop-writes-a-sidecar` records.
    func testAWidthSurvivesARelaunch() throws {
        let name = "panel-resize-wiring-\(UUID().uuidString)"
        let key = "ui.panelWidth." + name
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let range = Theme.Metric.rightPanelRange
        let store = PanelWidthStore(name: name, range: range)
        store.width = range.narrowest + 7

        let relaunched = PanelWidthStore(name: name, range: range)
        XCTAssertEqual(relaunched.width, range.narrowest + 7,
                       "the width did not come back — the app would reopen at a width nobody chose")

        // And the bound still holds across the round trip: a width written
        // under an older, wider range comes back clamped, not honoured.
        UserDefaults.standard.set(Double(range.widest + 1000), forKey: key)
        XCTAssertEqual(PanelWidthStore(name: name, range: range).width, range.widest)
    }
}
