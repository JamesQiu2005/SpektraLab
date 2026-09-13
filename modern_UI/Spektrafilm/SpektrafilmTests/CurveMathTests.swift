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
}
