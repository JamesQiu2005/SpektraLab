//  DetentSliderTests.swift — the one promise a detented slider makes.
//
//  The user asked for a control where "the slide need to stop at some point
//  controlling the amount of columns, not 无极" — so the thing worth pinning is
//  that no drag can leave the binding between two stops. That is arithmetic in
//  `DetentSlider.nearest(to:width:range:)`, and it is the kind of defect that
//  would fail nowhere: a thumb that rests a little off a stop still moves, still
//  changes the grid, and reads as a control that is merely sloppy.

import XCTest

final class DetentSliderTests: XCTestCase {

    private let width: CGFloat = 174.9
    private let range = 2...10
    private var knob: CGFloat { Theme.Metric.knobSize.width }
    private var travel: CGFloat { width - knob }

    private func stop(_ x: CGFloat) -> Int {
        DetentSlider.nearest(to: x, width: width, range: range)
    }

    /// A point in the middle of the gap between two stops, as a fraction of
    /// travel. Everything below is expressed this way because that is how a
    /// drag arrives: a continuous x, not a stop.
    private func x(_ fraction: CGFloat) -> CGFloat {
        knob / 2 + fraction * travel
    }

    func testEveryStopIsItsOwnPosition() {
        for v in range {
            let f = CGFloat(v - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
            XCTAssertEqual(stop(x(f)), v, "the position for \(v) must give back \(v)")
        }
    }

    /// The contract. Halfway between two stops is the only place it could go
    /// either way, and it must go one of them rather than neither.
    func testADragBetweenStopsLandsOnOne() {
        let span = CGFloat(range.upperBound - range.lowerBound)
        for i in 0..<range.count - 1 {
            let a = CGFloat(i) / span, b = CGFloat(i + 1) / span
            let lower = range.lowerBound + i
            for step in 1..<10 {
                let f = a + (b - a) * CGFloat(step) / 10
                let got = stop(x(f))
                XCTAssertTrue(got == lower || got == lower + 1,
                              "at \\(f) between \\(lower) and \\(lower + 1) got \\(got)")
            }
        }
    }

    /// And it never leaves the range, however far past the end a drag goes —
    /// which is what a press outside the control and a drag to the edge both
    /// do.
    func testDraggingPastEitherEndStaysOnTheEnds() {
        XCTAssertEqual(stop(-500), range.lowerBound)
        XCTAssertEqual(stop(0), range.lowerBound)
        XCTAssertEqual(stop(width + 500), range.upperBound)
        XCTAssertEqual(stop(width), range.upperBound)
        // And a hair either side of the very last stop still rounds to it.
        XCTAssertEqual(stop(x(1) - 1), range.upperBound)
        XCTAssertEqual(stop(x(0) + 1), range.lowerBound)
    }

    /// A track with no width has no meaningful position — a point on it is not
    /// between anything — so the only promise left is that it answers *inside
    /// the range* rather than dividing by zero. The control is laid out at
    /// least once before it has a size, so this is reached in practice, not
    /// only in principle.
    func testATrackWithoutAWidthStillAnswersInRange() {
        for w in [CGFloat(0), -3, knob] {
            for x in [CGFloat(-5), 0, 5, 500] {
                let got = DetentSlider.nearest(to: x, width: w, range: range)
                XCTAssertTrue(range.contains(got), "width \(w), x \(x) gave \(got)")
            }
        }
    }
}
