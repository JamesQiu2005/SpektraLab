//  Layout tests: the window at the three display shapes that matter —
//  MacBook Pro 14" (1512×982 pt), 16:9 (1920×1080), the 21:9 (3360×1418) —
//  measured against the **v3** drawing's geometry, not eyeballed.
//
//  The derivation of every number asserted here is
//  `modern_UI/design/TOKENS-main-v3-2026-09-18.md`, which translates
//  `reference_layout/Main/sample_frontend_v3.ai` at artboard ÷ 2. The file it
//  replaces asserted the 2026-09-17 drawing, and §9 of the handoff is
//  explicit that those assertions "must be updated before their pass can
//  count as v3 evidence. Do not assert old reference pixels." Four of them
//  would now fail by construction — the floating bar's radius, its air above,
//  its inset, and the odd-row rule for a list that is grouped — and a fifth,
//  `actionHeight`, names a token that no longer exists.
//
//  **What this file can and cannot say.** Every number here is geometry the
//  layout math promises. None of it is evidence about type, ink, or whether
//  the thing looks like the drawing — that is `Tools/compare-design.swift`
//  and a real-window capture, and the cautionary note in `design/README.md`
//  about a pass that "meant much less than it sounded like" is about exactly
//  this file's predecessor.

import SwiftUI
import XCTest

@MainActor
final class LayoutTests: XCTestCase {
    static let sizes: [(String, CGSize)] = [
        ("macbook-pro-14", CGSize(width: 1512, height: 982)),
        ("16x9", CGSize(width: 1920, height: 1080)),
        ("21x9", CGSize(width: 3360, height: 1418)),
    ]

    /// Host the real EditorWindow in an NSHostingView at each size and check
    /// the geometry the layout math promises: three flush regions, a centre
    /// column that is what is left, and a canvas that is still a canvas.
    func testRegionGeometryAtEverySize() {
        let m = Theme.Metric.self
        for (name, size) in Self.sizes {
            let session = Session()
            let host = NSHostingView(rootView: EditorWindow(session: session).environment(\.snapshotMode, true))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // Flush: the left rail starts at the window's edge and the right
            // one ends at it. There is no outer margin to subtract — and the
            // full-height dividers are overlays, so they take none either.
            let centreX = m.leftPanelWidth
            let centreW = size.width - m.leftPanelWidth - m.rightPanelWidth
            XCTAssertEqual(centreX, 254, "\(name)")
            XCTAssertGreaterThan(centreW, 500, "\(name): centre column too narrow")
            // The bar is a row of its own now, and the hairline under it is
            // 1 pt of the column's height rather than air around a pill.
            let canvasTop = m.barStrip + m.rule
            let canvasBottom = size.height - m.filmstripHeight - m.rule
            XCTAssertGreaterThan(canvasBottom - canvasTop, 400, "\(name): canvas too short")
            // The fit-scale rule: with a 3:2 image the canvas is wider than tall.
            XCTAssertGreaterThan(centreW / (canvasBottom - canvasTop), 1.0, name)
            _ = host.fittingSize
        }
    }

    /// The v3 artboard is 3840×2160; a 1920×1080 window is exactly half of it.
    func testTokensMatchTheDrawing() {
        let m = Theme.Metric.self
        // The three regions.
        XCTAssertEqual(m.leftPanelWidth, 507.36 / 2, accuracy: 1)      // rail fill ends x 507.36
        XCTAssertEqual(m.rightPanelWidth, 288.07, accuracy: 0.1)       // x 3263.86, width 288.07
        XCTAssertEqual(m.filmstripHeight, 132.35, accuracy: 0.4)       // y 1895.30, height 132.35
        XCTAssertEqual(m.panelHeaderHeight, 75.59 / 2, accuracy: 0.3)  // first hairline, y 75.59
        // The right rail's x falls out of the two widths.
        XCTAssertEqual(1920 - m.rightPanelWidth, 3263.86 / 2, accuracy: 0.1)
        // **The bar does not float.** It fills the centre column's top from
        // y .59 to y 75.59 — flush with both rails and with the window's top
        // edge — so all three of its floating tokens are zero and its height
        // is the rail header's, not a number of its own.
        XCTAssertEqual(m.topBarHeight, m.panelHeaderHeight,
                       "the bar and the rail headers share one top row")
        XCTAssertEqual(m.topBarHeight, 75 / 2, accuracy: 0.5)
        XCTAssertEqual(m.barRadius, 0, "a flush bar has no corner")
        XCTAssertEqual(m.barTop, 0, "a flush bar has no air above it")
        XCTAssertEqual(m.barInset, 0, "a flush bar has nothing to be inset by")
        // …and with no air, the strip the column reserves *is* the bar. This
        // is the identity the old file asserted with two non-zero terms.
        XCTAssertEqual(m.barStrip, m.topBarHeight)
        // The percentage plate: x 2769.98…2852.56, y 17.63…59.01.
        XCTAssertEqual(m.zoomPill.width, (2852.56 - 2769.98) / 2, accuracy: 0.05)
        XCTAssertEqual(m.zoomPill.height, (59.01 - 17.63) / 2, accuracy: 0.05)
        // A section: the right rail's two collapsed headers measure 29.05 and
        // 31.05 between hairlines, so a header row is 30.
        XCTAssertEqual(m.headerHeight, 30, accuracy: 1.1)
        // A row: v3's labels start at 15.61…17.12, so the row is inset 16.
        XCTAssertEqual(m.rowInset, 16, accuracy: 0.8)
        XCTAssertEqual(m.controlHeight, 27.8 / 2, accuracy: 0.05)
        XCTAssertEqual(m.sliderValueWidth, 87.46 / 2, accuracy: 0.05)
        XCTAssertEqual(m.sliderValueGap, (383.67 - 353.56) / 2, accuracy: 0.05)
        // Camera's own column, narrower than the shared one: its labels are
        // at x 16 and its controls at x 86.35.
        XCTAssertEqual(m.cameraLabelWidth, (86.35 - 16) / 2 + 35, accuracy: 1.5)
        XCTAssertLessThan(m.cameraLabelWidth, m.sliderLabelWidth,
                          "Camera's rows are denser than Film's, not the same rows smaller")
        // Film's controls.
        XCTAssertEqual(m.pickerWidth, 214.06 / 2, accuracy: 0.05)
        XCTAssertEqual(m.fieldWidth, 99.53 / 2, accuracy: 0.05)
        XCTAssertEqual(m.unitWidth, 76.63 / 2, accuracy: 0.05)
        // The lists: a pitch of 18, and a mark that is **shorter than its own
        // row**. That inequality is the whole difference between v3's mark
        // and the full-width band it replaced.
        XCTAssertEqual(m.listRowHeight, 36 / 2, accuracy: 0.05)
        XCTAssertEqual(m.stockSelectionHeight, 30.53 / 2, accuracy: 0.05)
        XCTAssertLessThan(m.stockSelectionHeight, m.listRowHeight,
                          "a mark as tall as its row is a filled cell, not a selection")
        XCTAssertEqual(m.stockSelectionRadius, m.stockSelectionHeight / 2, accuracy: 0.01)
        // The capsule is inset **unequally**, which is why the list cannot be
        // padded with one number: x 33.57 leading, ending at 227.52 on a 254
        // pt rail.
        XCTAssertEqual(m.stockLeadingInset, 33.57 / 2, accuracy: 0.05)
        XCTAssertEqual(m.stockTrailingInset, 254 - 227.52, accuracy: 0.05)
        XCTAssertNotEqual(m.stockLeadingInset, m.stockTrailingInset)
        // …and the glyphs sit inside it, not flush with it.
        XCTAssertEqual(m.stockTextLeadingInset, 42.66 / 2, accuracy: 0.05)
        XCTAssertGreaterThan(m.stockTextLeadingInset, m.stockLeadingInset,
                             "the row's text would start on the capsule's own edge")
        // The two actions: 165.72 × 37.03 halved, `rx 18.52 / 2`.
        XCTAssertEqual(m.actionSize.width, 165.72 / 2, accuracy: 0.05)
        XCTAssertEqual(m.actionSize.height, 37.03 / 2, accuracy: 0.05)
        XCTAssertEqual(m.actionRadius, 18.52 / 2, accuracy: 0.05)
        // The gap is **not** halved, and that is the handoff's table being
        // consistent rather than sloppy: `actionLeading` 13.33, `actionSize`
        // 82.86 and "first end x 96.19, second x 108.37" are all already in
        // points — 13.33 + 82.86 = 96.19 is the check — so the two x values
        // are not artboard units and dividing them would halve a measurement
        // twice. This assertion exists because it caught exactly that.
        XCTAssertEqual(m.actionLeading + m.actionSize.width, 96.19, accuracy: 0.05)
        XCTAssertEqual(m.actionGap, 108.37 - 96.19, accuracy: 0.05)
        XCTAssertEqual(m.actionLeading + m.actionSize.width + m.actionGap, 108.37,
                       accuracy: 0.05)
        // The refreshed slider has a visible 3 pt track and 9 pt knob. The
        // checkbox retains its larger target than the reference artwork.
        XCTAssertEqual(m.trackHeight, 3, accuracy: 0.05)
        XCTAssertEqual(m.knobSize.width, 9, accuracy: 0.05)
        XCTAssertEqual(m.knobSize.height, 9, accuracy: 0.05)
        XCTAssertEqual(m.checkbox, 10, accuracy: 0.5)
        // The hairline, `.st1` at stroke-width 2 on a 2× drawing.
        XCTAssertEqual(m.rule, 1)
        // The one tab that survived, unchanged: rect 27.8 × 83.1 rx 13.9.
        XCTAssertEqual(m.tabThickness, 27.8 / 2, accuracy: 0.1)
        XCTAssertEqual(m.tabLength, 83.1 / 2, accuracy: 0.1)
    }

    /// Interactive ink and targets stay usable on a laptop.
    ///
    /// The slider and reset arrow keep their small drawn ink, while the
    /// checkbox was promoted to a product token after real use showed the
    /// reference artwork's 5 pt mark was unreadable and hard to click.
    func testSmallInkKeepsALargeTarget() {
        let m = Theme.Metric.self
        XCTAssertGreaterThanOrEqual(m.controlHitTarget, 28,
                                    "a toggle needs a target a pointer can find on a laptop")
        XCTAssertGreaterThan(m.controlHitTarget, m.checkbox * 2,
                             "the target is the ink again and then some")
        XCTAssertGreaterThanOrEqual(m.actionHitHeight, 28,
                                    "yellow action capsules need the same usable target")
        // The knob is never dragged by itself — the track's gesture covers a
        // whole row — so the row height is its effective target.
        XCTAssertGreaterThan(m.rowHeight, m.knobSize.height * 2,
                             "the slider's gesture must not be the size of its dot")
        // The reset arrow and the toolbar glyphs keep the boxes §6 names.
        XCTAssertLessThan(m.resetIcon, 12, "v3 draws the reset arrow at 8–9 pt")
        XCTAssertGreaterThan(m.toolIcon, m.resetIcon)
    }

    func testInterfaceScaleDefaultsPersistsAndOffersReadableSteps() throws {
        XCTAssertEqual(InterfaceScale.allCases, [.compact, .standard, .large])
        XCTAssertEqual(InterfaceScale.defaultValue, .standard)
        XCTAssertEqual(InterfaceScale.standard.factor, 1.15, accuracy: 0.001)

        let suite = "interface-scale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = InterfaceScaleStore(defaults: defaults)
        XCTAssertEqual(fresh.scale, .standard)
        fresh.scale = .large
        XCTAssertEqual(defaults.string(forKey: InterfaceScaleStore.key), InterfaceScale.large.rawValue)
        XCTAssertEqual(InterfaceScaleStore(defaults: defaults).scale, .large)
    }

    /// The window buttons sit on the **rail header's** centreline, which is
    /// also the bar's — and with the bar flush and the same height as a
    /// header, that is now an identity rather than a coincidence.
    func testTheWindowButtonsHaveOneRowInBothStates() {
        let m = Theme.Metric.self
        XCTAssertEqual(m.trafficLightCentreY, m.panelHeaderHeight / 2)
        XCTAssertEqual(m.trafficLightCentreY, 19)
        // Exactly equal, where the old drawing's floating bar was within 2 pt:
        // `topBarHeight` *is* `panelHeaderHeight` and `barTop` is 0.
        let barCentreY = m.barTop + m.topBarHeight / 2
        XCTAssertEqual(barCentreY, m.trafficLightCentreY,
                       "one placement has to serve both rows")
        // A 14 pt button centred on 19 clears both edges of a 38 pt header.
        XCTAssertGreaterThan(m.trafficLightCentreY - TrafficLightAlignment.buttonDiameter / 2, 8)
        XCTAssertLessThan(m.trafficLightCentreY + TrafficLightAlignment.buttonDiameter / 2,
                          m.panelHeaderHeight - 8)
        // Whoever reserves the row reserves the same width, measured from the
        // same window origin: the header from the window's edge, the bar from
        // its own — which, with `barInset` at 0, is the same origin.
        XCTAssertEqual(m.barLeadingWithButtons, m.trafficLightClearance - m.barInset)
        XCTAssertEqual(m.barLeadingWithButtons, m.trafficLightClearance)
        XCTAssertEqual(m.trafficLightClearance,
                       m.trafficLightLeading + TrafficLightAlignment.rowWidth + m.trafficLightToGlyph)
        // And the reservation actually clears the buttons.
        XCTAssertGreaterThan(m.trafficLightClearance,
                             m.trafficLightLeading + TrafficLightAlignment.rowWidth)
    }

    /// Folding a rail moves its `sidebar` button onto the bar, and the bar
    /// then also carries the window buttons' clearance.
    ///
    /// v3's artwork contains neither the sidebar buttons nor the traffic
    /// lights; handoff §8.2 says to keep both and record the deviation rather
    /// than hide the functionality. This is the recording: the two
    /// reservations are one number seen from two origins, so the buttons
    /// cannot end up under a glyph in one state and not the other.
    func testAFoldedRailHandsItsRowToTheBar() {
        let m = Theme.Metric.self
        for (name, size) in Self.sizes {
            let session = Session()
            session.leftCollapsed = true
            session.rightCollapsed = true
            let host = NSHostingView(rootView: EditorWindow(session: session).environment(\.snapshotMode, true))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            // With both rails folded the centre column is the whole window,
            // so the bar starts at its own edge and its first control has to
            // clear buttons placed from the window's edge.
            let barLeading = m.barInset + m.barLeadingWithButtons
            XCTAssertEqual(barLeading, m.trafficLightClearance, "\(name)")
            XCTAssertGreaterThan(barLeading,
                                 m.trafficLightLeading + TrafficLightAlignment.rowWidth,
                                 "\(name): the bar's first glyph would sit on a window button")
            // …and the buttons still fit inside the bar itself, which is the
            // only reason one centreline can serve both rows.
            XCTAssertGreaterThanOrEqual(m.trafficLightCentreY - TrafficLightAlignment.buttonDiameter / 2,
                                        m.barTop, "\(name)")
            XCTAssertLessThanOrEqual(m.trafficLightCentreY + TrafficLightAlignment.buttonDiameter / 2,
                                     m.barTop + m.topBarHeight, "\(name)")
        }
    }

    /// The rails are the user's, and both bounds have to leave a usable rail.
    func testPanelRangesContainTheDrawing() {
        let m = Theme.Metric.self
        XCTAssertEqual(m.leftPanelRange.standard, m.leftPanelWidth)
        XCTAssertEqual(m.rightPanelRange.standard, m.rightPanelWidth)
        // The left rail's floor is the Metering row: Camera's label column,
        // two row insets, and a pill wide enough for `center-weighted
        // (legacy)`. Camera's column is narrower than the shared one now, so
        // this floor has more room than it did, not less.
        let meteringFloor = m.cameraLabelWidth + 2 * m.rowInset
        XCTAssertGreaterThan(m.leftPanelRange.narrowest - meteringFloor, 110,
                             "the Metering pill has to hold its longest string")
        XCTAssertLessThanOrEqual(m.leftPanelRange.narrowest, m.leftPanelWidth)
        XCTAssertGreaterThanOrEqual(m.leftPanelRange.widest, m.leftPanelWidth)
    }

    func testMinimumWindowStillFitsBothRails() {
        let m = Theme.Metric.self
        let canvas = m.minWindow.width - m.leftPanelWidth - m.rightPanelWidth
        XCTAssertGreaterThanOrEqual(canvas, 400)
    }

    /// The two capsules fit the rail they are inset into.
    ///
    /// v3 draws them at a fixed 82.86 each rather than as two halves of the
    /// rail, so unlike the old full-width pair they can overflow — and the
    /// rail is resizable down to `narrowest`, which the drawing says nothing
    /// about.
    func testTheTwoActionsFitTheNarrowestRail() {
        let m = Theme.Metric.self
        let needed = m.actionLeading + m.actionSize.width * 2 + m.actionGap
        XCTAssertLessThanOrEqual(needed, m.leftPanelRange.narrowest,
                                 "Solve / Original would run off a narrowed rail")
        XCTAssertLessThanOrEqual(needed, m.leftPanelWidth)
    }
}
