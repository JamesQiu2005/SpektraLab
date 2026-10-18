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
//  so both can be checked here. So does a third, which did fail silently in
//  1.3: **does the point sit on the colour it adds?** (`Wheel`, below.) The
//  triangle and the arcs are no longer drawn — the Colour section puts three
//  wheels in a row — and their tests stay with their arithmetic.

import AppKit
import CoreGraphics
import SwiftUI
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
        XCTAssertGreaterThan(layout.side, 2 * ColorBalanceLayout.arcBand(layout.side))
        // The band a wheel occupies is the wheel plus the arc overhang, and the
        // height the view lays out is the sum of those bands and the labels.
        XCTAssertEqual(ColorBalanceLayout.band(layout.side),
                       layout.side + 2 * ColorBalanceLayout.arcBand(layout.side))
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

    // MARK: - the wheel

    /// **A zone's point sits on the colour it adds.** The wheel's gradient is
    /// rendered and sampled where `Wheel.point` draws a zone of each hue, and
    /// the colour there must be the hue the picture is given
    /// (`ColorZone.rgbOffset`: 0° red, 120° green, 240° blue).
    ///
    /// 1.3's wheel failed this for every hue off the red–cyan axis: it drew
    /// and dragged the point counter-clockwise over a gradient SwiftUI paints
    /// clockwise, so a point on the blue of the wheel tinted the print green.
    /// **Seen red** with `Wheel.point`'s y negated (1.3's orientation): hue
    /// 120 sampled as 237.
    @MainActor
    func testAZonesPointSitsOnTheColourItAdds() throws {
        let size: CGFloat = 200, radius: CGFloat = 80
        let renderer = ImageRenderer(content: Circle().fill(ColorBalanceLayout.Wheel.gradient)
            .frame(width: size, height: size))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        for hue in stride(from: 0.0, to: 360, by: 30) {
            let p = ColorBalanceLayout.Wheel.point(hue: hue, saturation: 1, radius: radius)
            let c = try XCTUnwrap(rep.colorAt(x: Int(size / 2 + p.x), y: Int(size / 2 + p.y))?.usingColorSpace(.sRGB))
            var drawn = c.hueComponent * 360
            if drawn - hue > 180 { drawn -= 360 } else if hue - drawn > 180 { drawn += 360 }
            XCTAssertEqual(drawn, hue, accuracy: 12, "the point for hue \(hue)° sits on hue \(drawn)° of the wheel")
            // And the picture is given that hue: the offset's largest channel.
            let o = ColorZone(hue: hue, saturation: 1).rgbOffset
            if hue.truncatingRemainder(dividingBy: 120) == 0 {
                let strongest = [o.x, o.y, o.z].firstIndex(of: max(o.x, o.y, o.z))
                XCTAssertEqual(strongest, Int(hue / 120), "hue \(hue)° adds \(["red", "green", "blue"][Int(hue / 120)])")
            }
        }
    }

    /// The point and the zone are one mapping both ways, and a drag that has
    /// not moved leaves the zone exactly where it was: taking hold of a
    /// wheel never changes it.
    ///
    /// **Seen red** with the drag measured from the press rather than from the
    /// point (1.3's): a press 20 pt from the point moved it there.
    func testTakingHoldOfAWheelMovesNothing() {
        let W = ColorBalanceLayout.Wheel.self
        for (hue, sat) in [(0.0, 0.5), (75.0, 0.3), (210.0, 0.9), (330.0, 1.0)] {
            let p = W.point(hue: hue, saturation: sat, radius: 40)
            let z = W.zone(at: p, radius: 40)
            XCTAssertEqual(z.hue, hue, accuracy: 1e-9); XCTAssertEqual(z.saturation, sat, accuracy: 1e-9)
            let held = W.dragged(from: p, by: .zero, radius: 40)
            XCTAssertEqual(held.hue, hue, accuracy: 1e-9); XCTAssertEqual(held.saturation, sat, accuracy: 1e-9)
        }
        // A drag moves the point by its travel, and saturation stops at the rim.
        let moved = W.dragged(from: CGPoint(x: 10, y: 0), by: CGSize(width: 0, height: 10), radius: 40)
        XCTAssertEqual(moved.hue, 45, accuracy: 1e-9, "down-right is clockwise of 3 o'clock")
        XCTAssertEqual(W.dragged(from: .zero, by: CGSize(width: 400, height: 0), radius: 40).saturation, 1)
        XCTAssertEqual(W.zone(at: .zero, radius: 40).hue, 0, "no saturation, no hue")
    }

    /// Three wheels side by side fit the rail at every width it can have.
    func testThreeWheelsFitTheRailInARow() {
        let narrow = ColorBalanceLayout.interior(panelWidth: Theme.Metric.rightPanelRange.narrowest)
        let wide = ColorBalanceLayout.interior(panelWidth: Theme.Metric.rightPanelRange.widest)
        for width in [narrow, ColorBalanceLayout.assumedWidth, wide] {
            let row = ColorBalanceLayout.row(width: width - 8)
            XCTAssertTrue(row.fits, "three wheels do not fit \(width - 8) pt")
            XCTAssertGreaterThanOrEqual(row.wheel, 44)
            XCTAssertLessThanOrEqual(3 * row.wheel + 2 * row.gap, width - 8 + 0.5)
        }
        XCTAssertGreaterThan(ColorBalanceLayout.row(width: ColorBalanceLayout.assumedWidth - 8).wheel, 72,
                             "larger than the 3-way triangle's lower pair")
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
    /// The angle the **view** actually passes, not the arc's own.
    ///
    /// `ArcSlider` reads a touch through `Arc.angle(of:about:)`, which
    /// normalises to (−180, 180]. The left arc runs 115°…245°, so its whole
    /// lower half arrives negative — the bottom of it, 245°, comes back as
    /// −115°. That fell outside the span and clamped to the *maximum*, so
    /// dragging the lower half of the saturation arc slammed it to 1.
    ///
    /// The tests below this one never saw it because they pass
    /// `bottomTheta(.left)` — 245 — which is the one domain the call site
    /// never produces. This walks the arc the way a pointer does.
    func testAnArcTracksTheAnglesTheViewActuallyProduces() {
        let A = ColorBalanceLayout.Arc.self
        let centre = CGPoint.zero
        for side in [ColorBalanceLayout.Side.left, .right] {
            let range: ClosedRange<Double> = side == .left ? 0...1 : -1...1
            for step in 0...20 {
                let f = Double(step) / 20
                // A point on the arc at this fraction, in view coordinates.
                let theta = A.theta(fraction: f, on: side) * .pi / 180
                let p = CGPoint(x: cos(theta) * 50, y: -sin(theta) * 50)
                let got = A.value(atAngle: A.angle(of: p, about: centre), on: side, in: range)
                let want = range.lowerBound + f * (range.upperBound - range.lowerBound)
                XCTAssertEqual(got, want, accuracy: 1e-6,
                               "\(side) arc at fraction \(f): a touch on the track "
                             + "must read back as the value that put the thumb there")
            }
        }
    }

    /// The arcs' hit band must not reach into the wheel.
    ///
    /// It did: a 14 pt band centred 3.5 pt outside the rim covered the outer
    /// 3.5 pt of the wheel, so a drag started near the rim moved a slider
    /// instead of the colour.
    func testTheArcsDoNotReachIntoTheWheel() {
        // Every wheel the layouts can produce, from the narrow rail's smallest
        // three-way wheel to the widest single one.
        for wheel in stride(from: CGFloat(40), through: 160, by: 4) {
            let inner = ColorBalanceLayout.arcGap(wheel)
                      - ColorBalanceLayout.hitWidth(wheel) / 2
            XCTAssertGreaterThan(inner, 0,
                                 "at wheel \(wheel) the arc's hit band reaches "
                               + "\(-inner) pt into the wheel")
        }
    }

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
