import XCTest

final class CurveMathTests: XCTestCase {
    func testIdentityIsIdentity() {
        let c = Curve.identity
        for i in 0...10 { let x = CGFloat(i) / 10; XCTAssertEqual(c.evaluate(x), x, accuracy: 1e-9) }
        XCTAssertTrue(c.isIdentity)
    }

    func testMonotoneNoOvershoot() {
        var c = Curve.identity
        c.insert(CGPoint(x: 0.25, y: 0.1))
        c.insert(CGPoint(x: 0.3, y: 0.9))    // a violent step
        var last: CGFloat = -1
        for i in 0...200 {
            let y = c.evaluate(CGFloat(i) / 200)
            XCTAssertGreaterThanOrEqual(y, last - 1e-9, "curve must be monotone")
            XCTAssertTrue((0...1).contains(y))
            last = y
        }
    }

    func testInsertKeepsSortedAndMoveRespectsNeighbours() {
        var c = Curve.identity
        let i = c.insert(CGPoint(x: 0.7, y: 0.6))
        let j = c.insert(CGPoint(x: 0.3, y: 0.2))
        XCTAssertEqual(j, 1); XCTAssertEqual(i, 1)  // 0.7 was index 1 before 0.3 came in
        XCTAssertEqual(c.points.map(\.x), [0, 0.3, 0.7, 1])
        c.move(1, to: CGPoint(x: 0.95, y: 0.5))    // cannot cross 0.7
        XCTAssertLessThan(c.points[1].x, c.points[2].x)
        c.move(0, to: CGPoint(x: 0.5, y: 0.5))     // end point keeps x = 0
        XCTAssertEqual(c.points[0].x, 0)
        c.remove(0); XCTAssertEqual(c.points.count, 4)  // ends are not removable
        c.remove(1); XCTAssertEqual(c.points.count, 3)
    }

    /// A point you can grab is a point you can right-click.
    ///
    /// Both ask `Curve.index(near:in:)`, and this pins what that tolerance is
    /// at the boundary — so a second tolerance written into the context menu
    /// later would have to disagree with this test to exist. Ten points of the
    /// plot, whatever the plot measures.
    ///
    /// **Seen red first** by changing the constant from 10 to 4: the nine-point
    /// click stopped being a hit.
    func testTheHitTestIsSharedAndItsToleranceIsTenPointsOfPlot() {
        let size = CGSize(width: 200, height: 200)
        XCTAssertEqual(Curve.hitTolerance(in: size), 0.05, accuracy: 1e-9)

        var c = Curve.identity
        c.insert(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(c.index(near: CGPoint(x: 0.545, y: 0.5), in: size), 1,
                       "nine points from the point is a hit")
        XCTAssertNil(c.index(near: CGPoint(x: 0.556, y: 0.5), in: size),
                     "eleven points from the point is not a hit")
        // The nearest of two candidates wins, not the first within reach.
        c.insert(CGPoint(x: 0.563, y: 0.5))
        XCTAssertEqual(c.index(near: CGPoint(x: 0.566, y: 0.5), in: size), 2)

        // A plot with no area has no tolerance to give: an infinite one would
        // make every click a hit on every point.
        XCTAssertEqual(Curve.hitTolerance(in: .zero), 0)
        XCTAssertNil(Curve.identity.index(near: CGPoint(x: 0.5, y: 0.5), in: .zero))
    }

    /// The ends are the curve's domain, and the menu's enabled state is the
    /// model's own answer rather than a second rule written into the view.
    ///
    /// **Seen red first** by deleting the guard from `remove`: the endpoint went
    /// and both the `points == before` and the `x == 0` assertions failed.
    func testTheEndpointsCannotBeDeleted() {
        var c = Curve.identity
        c.insert(CGPoint(x: 0.25, y: 0.2))
        c.insert(CGPoint(x: 0.5, y: 0.6))
        c.insert(CGPoint(x: 0.75, y: 0.9))
        XCTAssertEqual(c.points.count, 5)
        XCTAssertFalse(c.isDeletable(0))
        XCTAssertFalse(c.isDeletable(4))
        XCTAssertTrue(c.isDeletable(1))
        XCTAssertTrue(c.isDeletable(3))

        // Ask for the illegal deletions too: the guard is what the menu greys
        // its item out from, so it has to hold when it is actually called.
        let before = c.points
        c.remove(0)
        c.remove(c.points.count - 1)
        XCTAssertEqual(c.points, before, "an endpoint was deleted")
        XCTAssertEqual(c.points.first?.x, 0)
        XCTAssertEqual(c.points.last?.x, 1)

        // An interior point goes, and what is left is still a curve.
        c.remove(2)
        XCTAssertEqual(c.points.count, 4)
        XCTAssertEqual(c.points.map(\.x), [0, 0.25, 0.75, 1])
        XCTAssertEqual(c.points.map(\.x), c.points.map(\.x).sorted(), "the points stay sorted")
        for i in 0...50 {
            let y = c.evaluate(CGFloat(i) / 50)
            XCTAssertTrue((0...1).contains(y), "the curve left the unit square after a deletion")
        }

        // Two points is the floor, and neither of them is deletable.
        var pair = Curve.identity
        pair.remove(0); pair.remove(1)
        XCTAssertEqual(pair.points.count, 2)
        XCTAssertTrue(pair.isIdentity)
    }

    func testTableLayout() {
        var set = CurveSet()
        set.red.insert(CGPoint(x: 0.5, y: 0.25))
        let t = set.tables()
        XCTAssertEqual(t.count, Curve.tableSize * 5)
        XCTAssertEqual(t[Curve.tableSize * 2 + 128], 0.25, accuracy: 0.02)   // row 2 = red
        XCTAssertEqual(t[128], 128.0 / 255.0, accuracy: 0.01)               // row 0 = rgb identity
    }

    // MARK: - the editor's gestures, as rules

    /// A press off the points adds one; a press on one takes it; a point
    /// dragged a little out of the plot stays, held to it; a fifth of the
    /// plot out, it goes, and the drag says so with nil; an end never goes.
    ///
    /// **Seen red** with `removalMargin` at 0: the point dragged a little out
    /// was removed.
    func testTheGestureRules() {
        let size = CGSize(width: 200, height: 200)
        var g = Curve.identity
        XCTAssertEqual(g.grab(at: CGPoint(x: 0.4, y: 0.6), in: size), 1)
        XCTAssertEqual(g.points.count, 3, "a press off the curve's points adds one there")
        XCTAssertEqual(g.grab(at: CGPoint(x: 0.41, y: 0.6), in: size), 1)
        XCTAssertEqual(g.points.count, 3, "a press on a point takes it")
        XCTAssertEqual(g.drag(1, to: CGPoint(x: 0.45, y: 1.15)), 1)
        XCTAssertEqual(g.points[1].y, 1, "a little out, it stays, held to the square")
        XCTAssertNil(g.drag(1, to: CGPoint(x: 0.45, y: 1.25)), "a fifth of the plot out, it is gone")
        XCTAssertEqual(g.points.count, 2)
        XCTAssertEqual(g.drag(0, to: CGPoint(x: -0.5, y: -0.5)), 0, "an end dragged out stays")
        XCTAssertEqual(g.points.count, 2)
    }

    // MARK: - the parametric curve

    func testANeutralParametricCurveIsExactlyTheIdentity() {
        let p = ParametricCurve()
        XCTAssertTrue(p.isNeutral)
        for i in 0...20 { XCTAssertEqual(p.evaluate(CGFloat(i) / 20), CGFloat(i) / 20) }
        var split = ParametricCurve()
        split.setSplit(.midtone, to: 0.4)
        XCTAssertTrue(split.isNeutral, "a split with no amounts applies nothing")
    }

    /// ±100 moves the middle of the region by half its width, and the ends stay.
    func testAnAmountMovesItsRegionsMiddle() {
        var lift = ParametricCurve()
        lift.shadows = 100
        XCTAssertEqual(lift.evaluate(0.125), 0.25, accuracy: 1e-9, "Shadows +100 doubles the middle of the shadows")
        XCTAssertEqual(lift.evaluate(0), 0); XCTAssertEqual(lift.evaluate(1), 1)
        XCTAssertEqual(lift.evaluate(0.75), 0.75, accuracy: 1e-3, "and leaves the highlights alone")
        var hl = ParametricCurve()
        hl.highlights = -100
        XCTAssertEqual(hl.evaluate(0.875), 0.75, accuracy: 1e-9)
    }

    /// Any setting of the four, with the splits anywhere, is a curve that
    /// never falls and never leaves the square — including splits stored out
    /// of order, which `heldSplits` puts back in order.
    func testEveryParametricSettingIsMonotone() {
        var state: UInt64 = 42
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for trial in 0..<400 {
            var q = ParametricCurve()
            for r in ParametricCurve.Region.allCases { q[r] = next() * 200 - 100 }
            if trial % 4 == 0 {
                // Crossed, as a hand-written file could store them.
                q.shadowSplit = next(); q.midtoneSplit = next(); q.highlightSplit = next()
            } else {
                q.setSplit(.midtone, to: 0.1 + next() * 0.8)
                q.setSplit(.shadow, to: next())
                q.setSplit(.highlight, to: next())
            }
            var last: CGFloat = 0
            for i in 0...256 {
                let y = q.evaluate(CGFloat(i) / 256)
                XCTAssertGreaterThanOrEqual(y, last - 1e-12, "trial \(trial) falls at \(i)")
                XCTAssertTrue((0...1).contains(y))
                last = y
            }
        }
        var crossed = ParametricCurve()
        crossed.setSplit(.shadow, to: 0.9)
        crossed.setSplit(.highlight, to: 0.1)
        XCTAssertTrue(crossed.splitsAreOrdered, "setSplit keeps the order and the gap")
    }

    /// The parametric curve is applied **first**: the point curve reads what
    /// it made, and the table is that composition. A channel with no
    /// parametric curve is its point curve's table exactly, so 1.3's curves
    /// draw as they did.
    ///
    /// **Seen red** with the composition reversed in `CurveSet.evaluate`.
    func testTheParametricCurveComesBeforeThePointCurve() {
        var set = CurveSet()
        set.parametric.rgb.shadows = 100
        set.rgb.insert(CGPoint(x: 0.25, y: 0.1))
        let x: CGFloat = 0.125
        XCTAssertEqual(set.evaluate(.rgb, x), set.rgb.evaluate(set.parametric.rgb.evaluate(x)), accuracy: 1e-12)
        XCTAssertGreaterThan(abs(set.evaluate(.rgb, x) - set.parametric.rgb.evaluate(set.rgb.evaluate(x))), 0.01,
                             "which is not the other order")
        XCTAssertEqual(set.changedChannels, [.rgb])
        XCTAssertEqual(Double(set.table(.rgb)[32]), Double(set.evaluate(.rgb, 32.0 / 255)), accuracy: 1e-6)
        var plain = CurveSet()
        plain.green.insert(CGPoint(x: 0.3, y: 0.5))
        XCTAssertEqual(plain.table(.green), plain.green.table())
        set.reset(.rgb)
        XCTAssertTrue(set.isIdentity, "a channel's reset is both views")
    }
}
