//  CropGuides.swift — the crop page's guide lines (参考线), and what Apply makes of them.
//
//  Capture One's keystone (梯形校正) by guide lines, brought to the crop page.
//  The guides correct the **perspective**, not only the straighten (the
//  owner, 2026-10-20: "the rulers here is to do 梯形矫正 instead of just
//  straighten the image"). The user lays the lines on what in the picture
//  should be parallel or square and taps Apply; the page solves Vertical,
//  Horizontal and the straighten that make them so. Never by itself: nothing
//  here looks at the picture, there is **no auto crop** (the owner's own
//  words, in bold).
//
//  Three modes, Capture One's three (`capture_one_reference.png`):
//
//  - **Horizontals** (横向平行线, C1's ⊃): two lines on what should lie level
//    and parallel. Apply solves Horizontal and the straighten.
//  - **Verticals** (竖向平行线, C1's /\): two lines on what should stand
//    upright and parallel. Apply solves Vertical and the straighten.
//  - **Rectangle** (矩形, C1's ⌗): four points, the corners of a
//    quadrilateral that should be a rectangle
//    (`capture_one_control_dot_reference.png`). Apply solves all three.
//
//  Each by least squares, the other perspective held where it is. A RAW in
//  Develop's crop only, as Vertical and Horizontal are.
//
//  The points are kept **on the source** (normalised, before the perspective):
//  they stay on the picture whatever the dials do, so once applied the lines
//  are drawn level and upright — the result shows itself.
//
//  No view code: `tools/crop_selftest.swift` holds the solves.

import CoreGraphics
import Foundation

enum CropGuides {
    enum Mode: String, CaseIterable, Sendable, Identifiable {
        case horizontals, verticals, rectangle
        var id: String { rawValue }
    }

    // MARK: where the lines start, and where they are pulled out to

    /// Where a mode's four points come from, on the crop's own 0…1 frame:
    /// the horizontals out of the top and bottom edges, the verticals out of
    /// the left and right, the rectangle's corners out of the middle.
    static func edge(_ mode: Mode, in box: (CGPoint) -> CGPoint) -> [CGPoint] {
        switch mode {
        case .horizontals:
            [CGPoint(x: 0.2, y: 0), CGPoint(x: 0.8, y: 0), CGPoint(x: 0.2, y: 1), CGPoint(x: 0.8, y: 1)].map(box)
        case .verticals:
            [CGPoint(x: 0, y: 0.2), CGPoint(x: 0, y: 0.8), CGPoint(x: 1, y: 0.2), CGPoint(x: 1, y: 0.8)].map(box)
        case .rectangle:
            Array(repeating: box(CGPoint(x: 0.5, y: 0.5)), count: 4)
        }
    }

    /// Where they come to rest: a third of the way in from each edge for the
    /// two lines, a fifth for the rectangle, as the reference has it.
    /// Horizontals and verticals: [line a's two points, line b's two];
    /// the rectangle: its corners clockwise from the top left.
    static func pulled(_ mode: Mode, in box: (CGPoint) -> CGPoint) -> [CGPoint] {
        switch mode {
        case .horizontals:
            [CGPoint(x: 0.2, y: 1.0 / 3), CGPoint(x: 0.8, y: 1.0 / 3), CGPoint(x: 0.2, y: 2.0 / 3), CGPoint(x: 0.8, y: 2.0 / 3)].map(box)
        case .verticals:
            [CGPoint(x: 1.0 / 3, y: 0.2), CGPoint(x: 1.0 / 3, y: 0.8), CGPoint(x: 2.0 / 3, y: 0.2), CGPoint(x: 2.0 / 3, y: 0.8)].map(box)
        case .rectangle:
            [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)].map(box)
        }
    }

    /// A mode's lines as pairs of its four points, and whether each is meant
    /// level (else upright).
    static func lines(_ mode: Mode) -> [(a: Int, b: Int, level: Bool)] {
        switch mode {
        case .horizontals: [(0, 1, true), (2, 3, true)]
        case .verticals: [(0, 1, false), (2, 3, false)]
        case .rectangle: [(0, 1, true), (3, 2, true), (0, 3, false), (1, 2, false)]
        }
    }

    // MARK: Apply

    /// What a mode's four points ask: Vertical, Horizontal and the straighten
    /// under which its lines are level or upright, as each is meant. The
    /// horizontals leave Vertical where it is, the verticals Horizontal.
    /// Levenberg–Marquardt from where the frame is now; nil when a line is
    /// too short to have a direction.
    static func solve(_ mode: Mode, points: [CGPoint], geometry g: Geometry, imageSize: CGSize)
        -> (vertical: Double, horizontal: Double, angle: Double)? {
        guard points.count == 4 else { return nil }
        let w = max(Double(imageSize.width), 1), h = max(Double(imageSize.height), 1)
        let px = points.map { CGPoint(x: Double($0.x) * w, y: Double($0.y) * h) }
        let sides = lines(mode).map { (a: px[$0.a], b: px[$0.b], level: $0.level) }
        for s in sides where hypot(Double(s.b.x - s.a.x), Double(s.b.y - s.a.y)) < 4 { return nil }
        let free = SIMD3<Double>(mode == .horizontals ? 0 : 1, mode == .verticals ? 0 : 1, 1)

        func residuals(_ x: SIMD3<Double>) -> [Double] {
            let ks = Keystone.make(vertical: x[0], horizontal: x[1], size: imageSize)
            let t = -x[2] * .pi / 180, c = cos(t), s = sin(t)
            func seen(_ p: CGPoint) -> (Double, Double) {
                let q = ks.corrected(p)
                return (Double(q.x) * c - Double(q.y) * s, Double(q.x) * s + Double(q.y) * c)
            }
            return sides.map { side in
                let p = seen(side.a), q = seen(side.b)
                // 0 when straight across (level) or straight down (upright),
                // whichever way round its points were laid.
                var r = side.level ? atan2(q.1 - p.1, q.0 - p.0) : atan2(q.0 - p.0, q.1 - p.1)
                if r > .pi / 2 { r -= .pi } else if r <= -.pi / 2 { r += .pi }
                return r
            }
        }
        func cost(_ x: SIMD3<Double>) -> Double { residuals(x).reduce(0) { $0 + $1 * $1 } }
        func clamp(_ x: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(x[0].clamped(to: -Geometry.maxPerspective...Geometry.maxPerspective),
                  x[1].clamped(to: -Geometry.maxPerspective...Geometry.maxPerspective),
                  x[2].clamped(to: -Geometry.maxAngle...Geometry.maxAngle))
        }

        var x = clamp(SIMD3(g.vertical, g.horizontal, g.angle))
        var lambda = 1e-3
        var now = cost(x)
        for _ in 0..<60 {
            let r = residuals(x)
            // The Jacobian, numerically: a hundredth of a degree a side; a held
            // unknown has none.
            var jac = [[Double]](repeating: [0, 0, 0], count: r.count)
            for k in 0..<3 where free[k] > 0 {
                var up = x, down = x
                up[k] += 0.01; down[k] -= 0.01
                let ru = residuals(up), rd = residuals(down)
                for i in 0..<r.count { jac[i][k] = (ru[i] - rd[i]) / 0.02 }
            }
            // (JᵀJ + λ·diag) δ = −Jᵀr
            var a = [[Double]](repeating: [0, 0, 0], count: 3)
            var b = [0.0, 0.0, 0.0]
            for i in 0..<r.count {
                for p in 0..<3 {
                    b[p] -= jac[i][p] * r[i]
                    for q in 0..<3 { a[p][q] += jac[i][p] * jac[i][q] }
                }
            }
            for p in 0..<3 {
                if free[p] > 0 { a[p][p] *= 1 + lambda; a[p][p] += 1e-12 } else { a[p][p] = 1 }
            }
            guard let step = solve3(a, b) else { break }
            let next = clamp(x + SIMD3(step[0], step[1], step[2]) * free)
            let then = cost(next)
            if then < now {
                x = next; now = then
                lambda = max(lambda / 10, 1e-9)
                if abs(step[0]) + abs(step[1]) + abs(step[2]) < 1e-5 { break }
            } else {
                lambda *= 10
                if lambda > 1e8 { break }
            }
        }
        return (x[0], x[1], x[2])
    }

    /// A 3×3 system by Cramer's rule; nil when it is singular.
    private static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-18 else { return nil }
        return (0..<3).map { k in
            var m = a
            for i in 0..<3 { m[i][k] = b[i] }
            return det(m) / d
        }
    }
}
