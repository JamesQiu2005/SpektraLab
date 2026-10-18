//  CurveMath.swift — the tone curve as data, with no view code in it.
//
//  A curve is a sorted list of control points in the unit square. The
//  interpolation is a monotone cubic (Fritsch–Carlson), which is what keeps a
//  curve from overshooting between two close points — the classic
//  Catmull-Rom "S" wobble that makes a curve editor feel wrong. Sampling it to
//  a 1-D table is what the shader consumes.
//
//  Each channel has two views, applied in this order:
//
//  - **the parametric curve** (`ParametricCurve`): four region amounts —
//    Highlights, Lights, Darks, Shadows — under three splits, the way
//    Lightroom's parametric curve is driven. It moves a tone region without a
//    single point being placed;
//  - **the point curve** (`Curve`), on what the parametric curve made:
//    `out = point(parametric(in))`. Both are monotone, so their composition
//    is, and the table the shader reads is that composition — one lookup per
//    channel, as before.
//
//  The editor's gesture rules live here as functions too (`grab`, `drag`), so
//  a test can hold them without a window: a click near a point takes it,
//  elsewhere it adds one; a point dragged well out of the plot is removed;
//  the two ends are never removed.

import CoreGraphics
import Foundation

enum CurveChannel: String, CaseIterable, Codable, Sendable, Identifiable {
    case rgb, luma, red, green, blue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .luma: "Luma"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }
}

struct Curve: Codable, Equatable, Sendable {
    /// Always sorted by x, always at least two points, first at x=0 and last at x=1.
    var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    static let identity = Curve()
    var isIdentity: Bool { points == Curve.identity.points }

    static let tableSize = 256

    /// The point index nearest to `x` within `tolerance`, or nil.
    func index(near p: CGPoint, tolerance: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, q) in points.enumerated() {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= tolerance && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best?.0
    }

    /// How close a click has to be, in unit-square terms, to count as a hit on
    /// a point in a plot of `size`: ten points of travel whatever the plot
    /// measures.
    ///
    /// It is one function because there are two ways to click a point — grabbing
    /// it (the drag) and asking about it (the context menu) — and a point you
    /// can grab has to be a point you can right-click. Two tolerances that
    /// agree today are two tolerances that disagree after the next change.
    /// The degenerate case is not decoration: a plot that has not been laid out
    /// yet has a zero side, and an infinite tolerance would make every click a
    /// hit. Zero — nothing is under a pointer that is not over the plot — is
    /// the honest answer.
    static func hitTolerance(in size: CGSize) -> CGFloat {
        let side = min(size.width, size.height)
        return side > 0 ? 10 / side : 0
    }

    /// The point under a click at `p` (unit square) in a plot of `size`, by the
    /// shared tolerance above.
    func index(near p: CGPoint, in size: CGSize) -> Int? {
        index(near: p, tolerance: Curve.hitTolerance(in: size))
    }

    /// Whether point `i` may be removed.
    ///
    /// The two ends define the curve's domain — its x runs 0…1 only because
    /// they are there — so they are not deletable, and the menu greys its item
    /// out for them rather than accepting the click and doing nothing. `remove`
    /// asks the same question, so the menu's state and the model's behaviour
    /// cannot drift apart.
    func isDeletable(_ i: Int) -> Bool {
        points.count > 2 && i > 0 && i < points.count - 1
    }

    /// Insert a point, keeping the list sorted. Returns its index.
    @discardableResult
    mutating func insert(_ p: CGPoint) -> Int {
        let q = CGPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
        let i = points.firstIndex { $0.x > q.x } ?? points.count
        points.insert(q, at: i)
        return i
    }

    /// Move point `i` to `p`. End points keep their x; interior points cannot
    /// cross their neighbours (a 0.01 guard keeps the spline well-conditioned).
    /// That guard is also what keeps a dragged point's **index** stable for the
    /// whole drag: nothing can pass it, so `i` names the same point at every
    /// step.
    mutating func move(_ i: Int, to p: CGPoint) {
        guard points.indices.contains(i) else { return }
        var q = CGPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
        if i == 0 { q.x = 0 } else if i == points.count - 1 { q.x = 1 } else {
            let lo = points[i - 1].x + 0.01, hi = points[i + 1].x - 0.01
            q.x = q.x.clamped(to: min(lo, hi)...max(lo, hi))
        }
        points[i] = q
    }

    mutating func remove(_ i: Int) {
        guard isDeletable(i) else { return }
        points.remove(at: i)
    }

    /// Fritsch–Carlson monotone cubic evaluation at `x` ∈ [0, 1].
    func evaluate(_ x: CGFloat) -> CGFloat {
        let n = points.count
        if n < 2 { return x }
        if x <= points[0].x { return points[0].y }
        if x >= points[n - 1].x { return points[n - 1].y }
        // Secants and tangents.
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = max(points[i + 1].x - points[i].x, 1e-6)
            d[i] = (points[i + 1].y - points[i].y) / dx
        }
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        // Locate the segment.
        var i = 0
        while i < n - 2 && x > points[i + 1].x { i += 1 }
        let h = max(points[i + 1].x - points[i].x, 1e-6)
        let t = (x - points[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
        let y = h00 * points[i].y + h10 * h * m[i] + h01 * points[i + 1].y + h11 * h * m[i + 1]
        return y.clamped(to: 0...1)
    }

    /// The 1-D table for the shader.
    func table(size: Int = Curve.tableSize) -> [Float] {
        (0..<size).map { Float(evaluate(CGFloat($0) / CGFloat(size - 1))) }
    }

    // MARK: the editor's gestures, as rules

    /// How far outside the unit square a dragged point goes before it is
    /// taken off the curve: a fifth of the plot, on any side.
    static let removalMargin: CGFloat = 0.2

    /// A click landed at `p` (unit square, clamped) on a plot of `size`: the
    /// point it lands on within the hit tolerance, or a new point there.
    /// Returns the index the drag then moves.
    mutating func grab(at p: CGPoint, in size: CGSize) -> Int {
        let q = CGPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
        if let i = index(near: q, in: size) { return i }
        return insert(q)
    }

    /// The pointer holding point `i` is at `u` (unit square, not clamped). An
    /// interior point taken more than `removalMargin` out of the square is
    /// removed and nil comes back; otherwise it moves, and its index comes
    /// back. The two ends move but never go.
    ///
    /// A nil is the end of that drag: the view stops moving anything until
    /// the button comes up, so a point dragged out and back in does not come
    /// back as a new one.
    mutating func drag(_ i: Int, to u: CGPoint) -> Int? {
        let m = Curve.removalMargin
        let outside = u.x < -m || u.x > 1 + m || u.y < -m || u.y > 1 + m
        if outside && isDeletable(i) {
            remove(i)
            return nil
        }
        move(i, to: u)
        return i
    }
}

// MARK: - the parametric curve

/// Four region amounts under three splits.
///
/// The regions are Shadows `[0, s1]`, Darks `[s1, s2]`, Lights `[s2, s3]` and
/// Highlights `[s3, 1]`. An amount of ±100 moves the curve at its region's
/// middle by half the region's width; each split sits halfway between the two
/// regions it parts, so two neighbouring amounts make one smooth swell rather
/// than two bumps with a pinch between them. The two ends stay where they are:
/// the parametric curve neither lifts the black nor dims the white, which is
/// Light's Blacks and Whites. The points it places go through the same
/// monotone cubic as a point curve, held non-decreasing first, so no setting
/// of the four can fold the tone scale back on itself.
struct ParametricCurve: Codable, Equatable, Sendable {
    /// −100…100 each; zero is nothing applied.
    var highlights: Double = 0
    var lights: Double = 0
    var darks: Double = 0
    var shadows: Double = 0
    /// The three splits, in order: Shadows | Darks, Darks | Lights, Lights | Highlights.
    var shadowSplit: Double = 0.25
    var midtoneSplit: Double = 0.5
    var highlightSplit: Double = 0.75

    static let neutral = ParametricCurve()
    static let amountRange: ClosedRange<Double> = -100...100
    /// The closest two splits may come, and the closest a split may come to an end.
    static let splitGap = 0.05

    /// Applies nothing: every amount is zero, wherever the splits are.
    var isNeutral: Bool { highlights == 0 && lights == 0 && darks == 0 && shadows == 0 }

    /// The four regions, lightest first (the order the section lists them).
    enum Region: String, CaseIterable, Codable, Sendable, Identifiable {
        case highlights, lights, darks, shadows
        var id: String { rawValue }
        /// The English name; the rail asks for its localized one.
        var title: String {
            switch self {
            case .highlights: "Highlights"
            case .lights: "Lights"
            case .darks: "Darks"
            case .shadows: "Shadows"
            }
        }
        /// The region's span along the tone axis, from the splits.
        func span(in p: ParametricCurve) -> ClosedRange<Double> {
            let s = p.heldSplits
            switch self {
            case .shadows: return 0...s.shadow
            case .darks: return s.shadow...s.midtone
            case .lights: return s.midtone...s.highlight
            case .highlights: return s.highlight...1
            }
        }
    }

    enum Split: Int, CaseIterable, Codable, Sendable { case shadow = 0, midtone, highlight
        /// Where the split rests, and goes back to on a double-click.
        var rest: Double { Double(rawValue + 1) * 0.25 }
    }

    subscript(region: Region) -> Double {
        get {
            switch region {
            case .highlights: highlights
            case .lights: lights
            case .darks: darks
            case .shadows: shadows
            }
        }
        set {
            let v = min(max(newValue, Self.amountRange.lowerBound), Self.amountRange.upperBound)
            switch region {
            case .highlights: highlights = v
            case .lights: lights = v
            case .darks: darks = v
            case .shadows: shadows = v
            }
        }
    }

    var splits: [Double] { [shadowSplit, midtoneSplit, highlightSplit] }

    subscript(split: Split) -> Double {
        get { splits[split.rawValue] }
        set { setSplit(split, to: newValue) }
    }

    /// Move one split; it stays between its neighbours (and the ends) by `splitGap`.
    mutating func setSplit(_ split: Split, to value: Double) {
        let g = Self.splitGap
        switch split {
        case .shadow: shadowSplit = min(max(value, g), midtoneSplit - g)
        case .midtone: midtoneSplit = min(max(value, shadowSplit + g), highlightSplit - g)
        case .highlight: highlightSplit = min(max(value, midtoneSplit + g), 1 - g)
        }
    }

    /// Whether the stored splits are in order and apart by `splitGap`, as
    /// `setSplit` keeps them. A hand-written or agent-written edit may not be.
    var splitsAreOrdered: Bool {
        let g = Self.splitGap - 1e-9
        return shadowSplit >= g && midtoneSplit - shadowSplit >= g
            && highlightSplit - midtoneSplit >= g && 1 - highlightSplit >= g
    }

    /// The splits as the curve uses them: in order and apart, whatever was
    /// stored. Splits that are already so come back unchanged, so this costs
    /// an edit made through `setSplit` nothing.
    var heldSplits: (shadow: Double, midtone: Double, highlight: Double) {
        let g = Self.splitGap
        let s = min(max(shadowSplit, g), 1 - 3 * g)
        let m = min(max(midtoneSplit, s + g), 1 - 2 * g)
        let h = min(max(highlightSplit, m + g), 1 - g)
        return (s, m, h)
    }

    /// The points this curve places, in the unit square, held non-decreasing.
    var curve: Curve {
        let held = heldSplits
        let s = [0, held.shadow, held.midtone, held.highlight, 1]
        let amounts = [shadows, darks, lights, highlights]
        // Each region's offset at its middle: ±100 is half the region's width.
        let offsets = (0..<4).map { r in amounts[r] / 100 * (s[r + 1] - s[r]) / 2 }
        var pts: [(Double, Double)] = [(0, 0)]
        for r in 0..<4 {
            let mid = (s[r] + s[r + 1]) / 2
            pts.append((mid, mid + offsets[r]))
            if r < 3 { pts.append((s[r + 1], s[r + 1] + (offsets[r] + offsets[r + 1]) / 2)) }
        }
        pts.append((1, 1))
        // Within the square, and never falling: a fall would fold the tones.
        var out: [CGPoint] = []
        var floor = 0.0
        for (i, p) in pts.enumerated() {
            var y = min(max(p.1, 0), 1)
            if i == pts.count - 1 { y = 1 }
            y = max(y, floor)
            floor = y
            out.append(CGPoint(x: p.0, y: y))
        }
        return Curve(points: out)
    }

    /// The curve at `x`; exactly `x` while it is neutral.
    func evaluate(_ x: CGFloat) -> CGFloat {
        isNeutral ? x : curve.evaluate(x)
    }

    init() {}

    /// Every key may be missing: a field not written is the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        lights = try c.decodeIfPresent(Double.self, forKey: .lights) ?? 0
        darks = try c.decodeIfPresent(Double.self, forKey: .darks) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        shadowSplit = try c.decodeIfPresent(Double.self, forKey: .shadowSplit) ?? 0.25
        midtoneSplit = try c.decodeIfPresent(Double.self, forKey: .midtoneSplit) ?? 0.5
        highlightSplit = try c.decodeIfPresent(Double.self, forKey: .highlightSplit) ?? 0.75
    }
}

/// The parametric curve of each channel.
struct ParametricSet: Codable, Equatable, Sendable {
    var rgb = ParametricCurve()
    var luma = ParametricCurve()
    var red = ParametricCurve()
    var green = ParametricCurve()
    var blue = ParametricCurve()

    var isNeutral: Bool { rgb.isNeutral && luma.isNeutral && red.isNeutral && green.isNeutral && blue.isNeutral }

    subscript(channel: CurveChannel) -> ParametricCurve {
        get {
            switch channel {
            case .rgb: rgb
            case .luma: luma
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .luma: luma = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    init() {}

    /// Every key may be missing: a channel not written is neutral.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try c.decodeIfPresent(ParametricCurve.self, forKey: .rgb) ?? .neutral
        luma = try c.decodeIfPresent(ParametricCurve.self, forKey: .luma) ?? .neutral
        red = try c.decodeIfPresent(ParametricCurve.self, forKey: .red) ?? .neutral
        green = try c.decodeIfPresent(ParametricCurve.self, forKey: .green) ?? .neutral
        blue = try c.decodeIfPresent(ParametricCurve.self, forKey: .blue) ?? .neutral
    }
}

struct CurveSet: Codable, Equatable, Sendable {
    var rgb = Curve.identity
    var luma = Curve.identity
    var red = Curve.identity
    var green = Curve.identity
    var blue = Curve.identity
    /// The parametric curves, applied before the point curves. Absent from
    /// every sidecar written before 2.0, which reads as all five neutral.
    var parametric = ParametricSet()

    /// Applies nothing: every point curve the identity and every parametric neutral.
    var isIdentity: Bool {
        rgb.isIdentity && luma.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity && parametric.isNeutral
    }

    /// The point curve of a channel.
    subscript(channel: CurveChannel) -> Curve {
        get {
            switch channel {
            case .rgb: rgb
            case .luma: luma
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .luma: luma = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// Whether a channel applies nothing, in either view.
    func isIdentity(_ channel: CurveChannel) -> Bool { self[channel].isIdentity && parametric[channel].isNeutral }

    /// The channels that apply something, in the menu's order.
    var changedChannels: [CurveChannel] { CurveChannel.allCases.filter { !isIdentity($0) } }

    /// A channel as applied: its parametric curve, then its point curve.
    func evaluate(_ channel: CurveChannel, _ x: CGFloat) -> CGFloat {
        let p = parametric[channel]
        return self[channel].evaluate(p.isNeutral ? x : p.curve.evaluate(x))
    }

    /// One channel's table, composed: entry `i` is the channel at `i / 255`.
    /// A channel with no parametric curve is its point curve's table exactly,
    /// so every curve written before the parametric one draws as it did.
    func table(_ channel: CurveChannel, size: Int = Curve.tableSize) -> [Float] {
        let p = parametric[channel]
        guard !p.isNeutral else { return self[channel].table(size: size) }
        let pc = p.curve, point = self[channel]
        return (0..<size).map { Float(point.evaluate(pc.evaluate(CGFloat($0) / CGFloat(size - 1)))) }
    }

    /// Five rows of `Curve.tableSize` floats: rgb, luma, r, g, b — the layout
    /// of the `curveTable` texture (width = tableSize, height = 5, r32Float).
    func tables() -> [Float] {
        CurveChannel.allCases.flatMap { table($0) }
    }

    /// Back to the identity: one channel, both views.
    mutating func reset(_ channel: CurveChannel) {
        self[channel] = .identity
        parametric[channel] = .neutral
    }

    init() {}

    /// Every key may be missing (a sidecar from before 2.0 has no `parametric`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try c.decodeIfPresent(Curve.self, forKey: .rgb) ?? .identity
        luma = try c.decodeIfPresent(Curve.self, forKey: .luma) ?? .identity
        red = try c.decodeIfPresent(Curve.self, forKey: .red) ?? .identity
        green = try c.decodeIfPresent(Curve.self, forKey: .green) ?? .identity
        blue = try c.decodeIfPresent(Curve.self, forKey: .blue) ?? .identity
        parametric = try c.decodeIfPresent(ParametricSet.self, forKey: .parametric) ?? ParametricSet()
    }
}
