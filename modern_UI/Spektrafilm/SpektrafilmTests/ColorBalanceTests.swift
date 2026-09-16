//  ColorBalanceTests.swift — the colour-balance editor's arithmetic.
//
//  What the wheels *look like* needs eyes: `Tools/snapshot.sh` is the check for
//  a layout, as it is for everything else in this repo (AGENTS trap 23). What
//  does not need eyes is the arithmetic underneath, and two pieces of it fail
//  silently in a way no capture would show clearly:
//
//    - **does the three-way triangle fit?** The panel is 286 pt wide and three
//      wheels in a row do not fit at a size anyone can aim at. That is why the
//      layout is a triangle, and "does it fit" is a comparison, not a picture.
//    - **which end of an arc is the maximum?** If a drag up makes saturation
//      *fall*, the control is still drawn correctly and still moves — it just
//      does the opposite of what it says.
//
//  Both live in `ColorBalanceLayout`, which is arithmetic with no view in it,
//  so both can be checked here.

import CoreGraphics
import XCTest

final class ColorBalanceTests: XCTestCase {

    // MARK: - the triangle

    /// The three-way triangle fits the width the editor is actually given.
    ///
    /// **Seen red first** by raising the lower wheels' share from 0.30 to 0.50
    /// of the width: the two wheel-and-arc columns stopped fitting side by side
    /// and `fits` went false.
    func testTheThreeWayTriangleFitsThePanel() {
        let width = ColorBalanceLayout.assumedWidth
        let layout = ColorBalanceLayout.threeWay(width: width)

        XCTAssertTrue(layout.fits, "the triangle does not fit \(width) pt")
        let columns = 2 * ColorBalanceLayout.band(layout.side) + layout.gap
        XCTAssertLessThanOrEqual(columns, width,
                                 "the two lower wheels and their arcs need \(columns) pt of \(width)")
        // The midtone wheel is the one the eye goes to: it must not be the
        // smallest.
        XCTAssertGreaterThan(layout.midtone, layout.side)
        // Every wheel keeps room for a thumb on both sides.
        XCTAssertGreaterThan(layout.side, 2 * ColorBalanceLayout.arcBand)
        // The band a wheel occupies is the wheel plus the arc overhang, and the
        // height the view lays out is the sum of those bands and the labels.
        XCTAssertEqual(ColorBalanceLayout.band(layout.side), layout.side + 2 * ColorBalanceLayout.arcBand)
        XCTAssertEqual(layout.height,
                       ColorBalanceLayout.band(layout.midtone) + ColorBalanceLayout.labelHeight + 6
                       + ColorBalanceLayout.labelHeight + ColorBalanceLayout.band(layout.side),
                       accuracy: 0.001)
    }

    /// The layout follows the width it is given, and has a floor rather than an
    /// overlap when it is given too little.
    ///
    /// **Seen red first** by removing the clamps (the widths below 100 pt then
    /// produced wheels smaller than their own arcs, and the floor assertions
    /// failed).
    func testTheLayoutFollowsTheWidthAndHasAFloor() {
        let wide = ColorBalanceLayout.threeWay(width: 320)
        let panel = ColorBalanceLayout.threeWay(width: ColorBalanceLayout.assumedWidth)
        let narrow = ColorBalanceLayout.threeWay(width: 170)
        XCTAssertTrue(wide.fits && panel.fits && narrow.fits)
        XCTAssertGreaterThan(wide.midtone, panel.midtone)
        XCTAssertGreaterThanOrEqual(panel.midtone, narrow.midtone)
        // The ceilings: a wide window must not grow the wheels without bound.
        XCTAssertLessThanOrEqual(wide.midtone, 120)
        XCTAssertLessThanOrEqual(wide.side, 96)

        // Below the panel's floor the layout says so instead of overlapping.
        let cramped = ColorBalanceLayout.threeWay(width: 100)
        XCTAssertFalse(cramped.fits, "a 100 pt strip cannot hold this triangle")
        XCTAssertGreaterThanOrEqual(cramped.midtone, 64)
        XCTAssertGreaterThanOrEqual(cramped.side, 44)

        // The single-zone tabs put one wheel and its two arcs in the same width.
        for width in [ColorBalanceLayout.assumedWidth, 320, 170] as [CGFloat] {
            let wheel = ColorBalanceLayout.single(width: width)
            XCTAssertLessThanOrEqual(ColorBalanceLayout.band(wheel), width,
                                     "the single wheel and its arcs do not fit \(width) pt")
            XCTAssertGreaterThanOrEqual(wheel, 64)
        }
    }

    /// The width the layout is checked against is the panel less the furniture
    /// it now sits in — the well's inset and padding on both sides.
    ///
    /// The literal is deliberate: if the furniture changes, this fails and
    /// points at the triangle rather than quietly shrinking the wheels.
    func testTheAssumedWidthIsThePanelMinusItsWell() {
        XCTAssertEqual(ColorBalanceLayout.assumedWidth, 264, accuracy: 0.001)
    }

    // MARK: - the arcs

    /// The top of an arc is the top of its range, on both sides — and the two
    /// sides get there round opposite ways.
    ///
    /// **Seen red first** by swapping the left side's bottom and top angles:
    /// dragging up made saturation fall, and the first assertion here failed.
    func testTheTopOfAnArcIsTheTopOfTheRange() {
        let A = ColorBalanceLayout.Arc.self
        // Saturation: 0 at the bottom of the left arc, 1 at the top.
        XCTAssertEqual(A.value(atAngle: A.bottomTheta(.left), on: .left, in: 0...1), 0, accuracy: 1e-9)
        XCTAssertEqual(A.value(atAngle: A.topTheta(.left), on: .left, in: 0...1), 1, accuracy: 1e-9)
        // Lightness: −1 … 1, same way up, on the right.
        XCTAssertEqual(A.value(atAngle: A.bottomTheta(.right), on: .right, in: -1...1), -1, accuracy: 1e-9)
        XCTAssertEqual(A.value(atAngle: A.topTheta(.right), on: .right, in: -1...1), 1, accuracy: 1e-9)
        // Halfway along either arc is zero for a symmetric range, which is what
        // makes a neutral zone's thumbs sit level with each other.
        XCTAssertEqual(A.value(atAngle: 180, on: .left, in: -1...1), 0, accuracy: 1e-9)
        XCTAssertEqual(A.value(atAngle: 0, on: .right, in: -1...1), 0, accuracy: 1e-9)

        // The two arcs really are the two sides of the wheel: the left one
        // faces left, the right one faces right.
        XCTAssertGreaterThan(A.bottomTheta(.left), 90)
        XCTAssertLessThan(A.topTheta(.left), 270)
        XCTAssertGreaterThan(A.topTheta(.left), 90)
        XCTAssertEqual(A.bottomTheta(.right), -65, accuracy: 1e-9)
    }

    /// A drag past either end clamps to that end, and the angle is measured
    /// about the wheel rather than about the touch's own radius — the arc is
    /// thin and a drag that wanders off it must still track.
    ///
    /// **Seen red first** by removing the clamp in `value(atAngle:on:in:)`
    /// (a touch well past the end then produced a value outside the range).
    func testAnArcClampsAtItsEndsAndMeasuresTheAngle() {
        let A = ColorBalanceLayout.Arc.self
        XCTAssertEqual(A.value(atAngle: 300, on: .left, in: 0...1), 0, accuracy: 1e-9)
        XCTAssertEqual(A.value(atAngle: 90, on: .left, in: 0...1), 1, accuracy: 1e-9)
        XCTAssertEqual(A.value(atAngle: 180, on: .left, in: 0...1), 0.5, accuracy: 1e-9)
        for theta in stride(from: -180.0, through: 180.0, by: 7.5) {
            let v = A.value(atAngle: theta, on: .right, in: -1...1)
            XCTAssertTrue((-1...1).contains(v), "theta \(theta) produced \(v)")
        }

        // Angle about the centre, y flipped: straight up is 90°, straight left
        // is 180°, straight down is −90°.
        let c = CGPoint(x: 100, y: 100)
        XCTAssertEqual(A.angle(of: CGPoint(x: 100, y: 0), about: c), 90, accuracy: 1e-9)
        XCTAssertEqual(A.angle(of: CGPoint(x: 0, y: 100), about: c), 180, accuracy: 1e-9)
        XCTAssertEqual(A.angle(of: CGPoint(x: 100, y: 200), about: c), -90, accuracy: 1e-9)
        XCTAssertEqual(A.angle(of: CGPoint(x: 200, y: 100), about: c), 0, accuracy: 1e-9)

        // And the two ends are 130° apart, the sweep the two arcs leave between
        // them.
        XCTAssertEqual(A.topTheta(.left) - A.bottomTheta(.left), -130, accuracy: 1e-9)
        XCTAssertEqual(A.topTheta(.right) - A.bottomTheta(.right), 130, accuracy: 1e-9)
    }
}
