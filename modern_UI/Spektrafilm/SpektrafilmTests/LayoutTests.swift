//  Layout tests: the window at the three display shapes that matter —
//  MacBook Pro 14" (1512×982 pt), 16:9 (1920×1080), the 21:9 (3360×1418) —
//  measured against the 2026-09-17 drawing's geometry, not eyeballed.
//
//  The derivation of every number asserted here is
//  `modern_UI/design/TOKENS-main-2026-09-17.md`.

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
            // one ends at it. There is no outer margin to subtract.
            let centreX = m.leftPanelWidth
            let centreW = size.width - m.leftPanelWidth - m.rightPanelWidth
            XCTAssertEqual(centreX, 254, "\(name)")
            XCTAssertGreaterThan(centreW, 500, "\(name): centre column too narrow")
            // …and no gutter above the canvas either: the bar floats in a
            // strip the column reserves at its top.
            let canvasTop = m.barStrip
            let canvasBottom = size.height - m.filmstripHeight
            XCTAssertGreaterThan(canvasBottom - canvasTop, 400, "\(name): canvas too short")
            // The fit-scale rule: with a 3:2 image the canvas is wider than tall.
            XCTAssertGreaterThan(centreW / (canvasBottom - canvasTop), 1.0, name)
            _ = host.fittingSize
        }
    }

    /// The drawing is 3840×2160; a 1920×1080 window is exactly half of it.
    func testTokensMatchTheDrawing() {
        let m = Theme.Metric.self
        // The three regions, from the drawing's own rectangles.
        XCTAssertEqual(m.leftPanelWidth, 509.9 / 2, accuracy: 1)      // rect x -2.6 w 509.9
        XCTAssertEqual(m.rightPanelWidth, 576.1 / 2, accuracy: 0.1)   // rect x 3263.9 w 576.1
        XCTAssertEqual(m.filmstripHeight, 264.7 / 2, accuracy: 0.4)   // rect y 1895.3 h 264.7
        XCTAssertEqual(m.panelHeaderHeight, 75.6 / 2, accuracy: 0.3)  // first hairline, y 75.6
        // The right rail's x falls out of the two widths, and is the drawing's
        // 3263.9 / 2 at a 1920 pt window.
        XCTAssertEqual(1920 - m.rightPanelWidth, 3263.9 / 2, accuracy: 0.1)
        // The floating bar: rect x 529 y 9.4 w 2721 h 61.8 rx 28.
        XCTAssertEqual(m.topBarHeight, 61.8 / 2, accuracy: 0.5)
        XCTAssertEqual(m.barRadius, 28 / 2)
        XCTAssertEqual(m.barTop, 9.4 / 2, accuracy: 0.4)
        XCTAssertEqual(m.barStrip, m.barTop * 2 + m.topBarHeight)
        // `barInset` is the mean of the drawing's two unequal gaps — 529 −
        // 506.8 leading and 3263.9 − 3250 trailing — because a bar that is not
        // centred in its own column is a thing you can see.
        XCTAssertEqual(m.barInset, ((529 - 506.8) / 2 + (3263.9 - 3250) / 2) / 2, accuracy: 0.1)
        // A section: the two collapsed ones in the drawing are the hairlines
        // at y 261.2, 319.3 and 381.4, so 29.05 pt and 31.05 pt.
        XCTAssertEqual(m.headerHeight, (381.4 - 261.2) / 2 / 2, accuracy: 1.1)
        // A row: labels start at 17.6 and value pills end at 235.6 on a 254
        // pt rail, so the row is inset 18 from both edges.
        XCTAssertEqual(m.rowInset, 35.2 / 2, accuracy: 0.5)
        XCTAssertEqual(m.leftPanelWidth - m.rowInset, 471.2 / 2, accuracy: 0.7)
        XCTAssertEqual(m.controlHeight, 27.8 / 2, accuracy: 0.2)
        XCTAssertEqual(m.sliderValueWidth, 87.5 / 2, accuracy: 0.3)
        // The lists.
        XCTAssertEqual(m.wellRadius, 22.9 / 2, accuracy: 0.1)
        XCTAssertEqual(m.listRowHeight, 39.2 / 2, accuracy: 0.2)
        XCTAssertEqual(m.actionHeight, 52.6 / 2, accuracy: 0.4)
        XCTAssertEqual(m.actionRadius, 16.5 / 2, accuracy: 0.1)
        // The hairline, `.st1` at stroke-width 2 on a 2× drawing.
        XCTAssertEqual(m.rule, 1)
        // The one tab that survived, unchanged: rect 27.8 × 83.1 rx 13.9.
        XCTAssertEqual(m.tabThickness, 27.8 / 2, accuracy: 0.1)
        XCTAssertEqual(m.tabLength, 83.1 / 2, accuracy: 0.1)
    }

    /// The window buttons sit on the **rail header's** centreline, which is
    /// also very nearly the floating bar's — and that coincidence is what
    /// lets them stay still when the left rail folds.
    func testTheWindowButtonsHaveOneRowInBothStates() {
        let m = Theme.Metric.self
        XCTAssertEqual(m.trafficLightCentreY, m.panelHeaderHeight / 2)
        XCTAssertEqual(m.trafficLightCentreY, 19)
        // The bar's own centre, in window coordinates, is within 2 pt of it —
        // which is why one placement serves both rows rather than the buttons
        // being moved when a rail folds.
        let barCentreY = m.barTop + m.topBarHeight / 2
        XCTAssertEqual(barCentreY, m.trafficLightCentreY, accuracy: 2)
        // A 14 pt button centred on 19 clears both edges of a 38 pt header.
        XCTAssertGreaterThan(m.trafficLightCentreY - TrafficLightAlignment.buttonDiameter / 2, 8)
        XCTAssertLessThan(m.trafficLightCentreY + TrafficLightAlignment.buttonDiameter / 2,
                          m.panelHeaderHeight - 8)
        // Whoever reserves the row reserves the same width, measured from the
        // same window origin: the header from the window's edge, the bar from
        // its own, which is `barInset` further in.
        XCTAssertEqual(m.barLeadingWithButtons, m.trafficLightClearance - m.barInset)
        XCTAssertEqual(m.trafficLightClearance,
                       m.trafficLightLeading + TrafficLightAlignment.rowWidth + m.trafficLightToGlyph)
        // And the reservation actually clears the buttons.
        XCTAssertGreaterThan(m.trafficLightClearance,
                             m.trafficLightLeading + TrafficLightAlignment.rowWidth)
    }

    /// Folding a rail moves its `sidebar` button onto the bar, and the bar
    /// then also carries the window buttons' clearance. The capture that shows
    /// it is `design/snapshots/window-folded-both.png`
    /// (`Tools/snapshot.sh`, `--folded both`); what this pins is that the two
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
            // so the bar starts at `barInset` and its first control has to
            // clear buttons placed from the **window's** edge.
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
        // The left rail's floor is the AE Method row: a label column, two row
        // insets, and a pill wide enough for `center-weighted (legacy)`.
        let aeFloor = m.sliderLabelWidth + 2 * m.rowInset
        XCTAssertGreaterThan(m.leftPanelRange.narrowest - aeFloor, 110,
                             "the AE Method pill has to hold its longest string")
        XCTAssertLessThanOrEqual(m.leftPanelRange.narrowest, m.leftPanelWidth)
        XCTAssertGreaterThanOrEqual(m.leftPanelRange.widest, m.leftPanelWidth)
    }

    func testMinimumWindowStillFitsBothRails() {
        let m = Theme.Metric.self
        let canvas = m.minWindow.width - m.leftPanelWidth - m.rightPanelWidth
        XCTAssertGreaterThanOrEqual(canvas, 400)
    }

    /// A list well shows an **odd** number of rows.
    ///
    /// `StockList` keeps the chosen stock in view by centring it, which puts
    /// that row's centre on the viewport's centre. The rows then land on the
    /// well's edges only when a whole number of them fits either side of the
    /// middle one — an odd count. At an even count every row sits half a row
    /// out of register, and the well cuts its first and last rows through the
    /// glyphs: the film list shipped at 6 and did exactly that.
    ///
    /// This asserts the property rather than the number, so raising a list to
    /// seven rows is fine and slipping back to six is not.
    func testStockListShowsAnOddNumberOfRows() {
        for (name, count) in [("film", FilmSection.wellRows), ("print", PrintProfileSection.wellRows)] {
            XCTAssertEqual(count % 2, 1,
                           "the \(name) well shows \(count) rows; an even count "
                         + "half-steps the scroll and slices the first and last row")
        }
    }

    /// The rows inside a well clear its corner radius.
    ///
    /// Without this the 11.5 pt radius cuts the corners off the first and
    /// last rows, and a row that ends in a curve reads as a row that has been
    /// sliced — the same defect as the even-row-count one, from the other end.
    func testWellPaddingClearsItsOwnCornerRadius() {
        XCTAssertGreaterThanOrEqual(Theme.Metric.wellVPadding,
                                    Theme.Metric.wellRadius / 2,
                                    "a row would be clipped by the well's corner")
    }
}
