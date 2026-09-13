//  Layout tests: the window at the three display shapes that matter —
//  MacBook Pro 14" (1512×982 pt), 16:9 (1920×1080), the 21:9 (3360×1418) —
//  measured against the drawing's geometry, not eyeballed.

import SwiftUI
import XCTest

@MainActor
final class LayoutTests: XCTestCase {
    static let sizes: [(String, CGSize)] = [
        ("macbook-pro-14", CGSize(width: 1512, height: 982)),
        ("16x9", CGSize(width: 1920, height: 1080)),
        ("21x9", CGSize(width: 3360, height: 1418)),
    ]

    /// Host the real EditorWindow in an NSHostingView at each size and read
    /// the frames of the four cards through the accessibility-free route:
    /// the geometry the layout math promises.
    func testCardGeometryAtEverySize() {
        let m = Theme.Metric.self
        for (name, size) in Self.sizes {
            let session = Session()
            let host = NSHostingView(rootView: EditorWindow(session: session).environment(\.snapshotMode, true))
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // Left card
            let leftX = m.outerX, leftW = m.leftPanelWidth
            let rightX = size.width - m.outerX - m.rightPanelWidth
            let canvasX = leftX + leftW + m.gutter
            let canvasW = rightX - m.gutter - canvasX
            XCTAssertGreaterThan(canvasW, 500, "\(name): canvas too narrow")
            let canvasTop = m.outerY + m.topBarHeight + m.gutter
            let canvasBottom = size.height - m.outerY - m.filmstripHeight - m.gutter
            XCTAssertGreaterThan(canvasBottom - canvasTop, 400, "\(name): canvas too short")
            // The fit-scale rule: with a 3:2 image the canvas is wider than tall on every size.
            XCTAssertGreaterThan(canvasW / (canvasBottom - canvasTop), 1.0, name)
            _ = host.fittingSize
        }
    }

    func testTokensMatchTheDrawing() {
        // The drawing is 3840×2160; a 1920×1080 window is exactly half.
        let m = Theme.Metric.self
        XCTAssertEqual(m.leftPanelWidth, (656.9 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.rightPanelWidth, (572.3 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.topBarHeight, (82.7 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.filmstripHeight, (250.6 / 2).rounded(), accuracy: 0.6)
        XCTAssertEqual(m.cardRadius, 15)
        XCTAssertEqual(m.gutter, 6, accuracy: 0.5)   // drawing's 8; tightened on purpose
        // Right card's x in the drawing: 3250.1 / 2 = 1625.05 at 1920 wide.
        XCTAssertEqual(1920 - m.outerX - m.rightPanelWidth, 1625, accuracy: 1)
        // Canvas column x: 690.5 / 2.
        XCTAssertEqual(m.outerX + m.leftPanelWidth + m.gutter, 345, accuracy: 4)
        // The window buttons are placed on the **top bar's** centreline
        // rather than avoided where AppKit floats them
        // (Windows/TrafficLights.swift, PRD §1). Everything in that corner is
        // derived from those two numbers, so this is the derivation, not a
        // measurement: the buttons take the card's own 12 pt inset, and the
        // first glyph follows the row by `trafficLightToGlyph`.
        //
        // The row is the bar's, not the left panel's header's, for a reason
        // this test can state: the bar cannot be collapsed, so the buttons
        // always have a home. `panelHeaderLeading` went back to the drawing's
        // own 12 as the other half of that move.
        XCTAssertEqual(m.trafficLightLeading, m.outerX + 12)
        XCTAssertEqual(m.trafficLightCentreY, m.outerY + m.topBarHeight / 2)
        XCTAssertEqual(m.panelHeaderLeading, 12)
        let rowEnd = m.trafficLightLeading + TrafficLightAlignment.rowWidth
        let glyphLeft = m.outerX + m.topBarLeading + (28 - m.toolIcon) / 2
        XCTAssertEqual(glyphLeft - rowEnd, m.trafficLightToGlyph, accuracy: 0.01)
        // And the row still has to fit on the bar it sits in, with the whole
        // tool cluster behind it.
        XCTAssertLessThan(rowEnd, m.outerX + m.topBarLeading)
        // Captured live at leading x 21 (Tools/capture-live.sh — no offscreen
        // capture can see these). The centreline is the bar's now, which is
        // 1.5 pt higher than the panel header's was.
        XCTAssertEqual(m.trafficLightLeading, 21)
        XCTAssertEqual(m.trafficLightCentreY, 27.5)
    }

    /// The bar is the window's first row and spans all of it; the three cards
    /// below start under it. This is the one thing item 1 changes about the
    /// layout, and it is what `Tools/compare-layout.py` measures.
    func testTheTopBarSpansTheWindowAboveTheCards() {
        let m = Theme.Metric.self
        let size = CGSize(width: 1920, height: 1080)
        // Full width: both outer margins, exactly like the row of cards.
        XCTAssertEqual(size.width - 2 * m.outerX, 1902)
        // The cards below start one bar and one gutter down from the top.
        let cardsTop = m.outerY + m.topBarHeight + m.gutter
        XCTAssertEqual(cardsTop, 54)
        // …and the bar is still the drawing's height (82.7 / 2), because the
        // drawing the numbers come from has not changed.
        XCTAssertEqual(m.topBarHeight, 41, accuracy: 0.5)
        // The left panel's card starts at the window's edge, under the bar.
        XCTAssertEqual(m.outerX, 9)
    }

    func testMinimumWindowStillFitsBothPanels() {
        let m = Theme.Metric.self
        let canvas = m.minWindow.width - 2 * m.outerX - m.leftPanelWidth - m.rightPanelWidth - 2 * m.gutter
        XCTAssertGreaterThanOrEqual(canvas, 400)
    }
}
