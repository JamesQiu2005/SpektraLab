//  CurveMath.swift — Edit's Curve as data, with no view code in it.
//
//  The desktop's (`Model/CurveMath.swift`, desktop `df355fa`, the maintainer's;
//  UPSTREAM.md): a curve is a sorted list of control points in the unit square,
//  interpolated by a monotone cubic (Fritsch–Carlson), which is what keeps a
//  curve from overshooting between two close points — the Catmull-Rom "S"
//  wobble that makes a curve editor feel wrong. Its names are the desktop's, so
//  an edit can travel between the two.
//
//  Two things are the host's own:
//
//  - **The parametric curve** (`ParametricCurve`), Lightroom's other view of a
//    channel: four region amounts — Highlights, Lights, Darks, Shadows — under
//    three splits. It is applied **before** the point curve, as Lightroom
//    applies it: `out = point(parametric(in))`. Both are monotone, so their
//    composition is, and the table the shader reads is that composition.
//  - **The editor's gesture rules as functions** (`grab`, `drag`), the
//    desktop's `CurveEditor` rules stated once: a touch near a point takes it,
//    elsewhere it adds one; a point dragged well out of the square is
//    removed; the two ends are never removed.
//
//  **The ends move in x** (RFC-035 §3.5, the owner, 2026-10-25, of Capture
//  One's curve: the starting point "can only be dragged up and down, but it
//  should be also draggable to left and right"). The black point may go right
//  and the white point left, each short of its neighbour; `evaluate` is flat
//  beyond the ends, so what lies past the black point takes its output — C1's
//  clip, with no maths change. "First at x = 0, last at x = 1" is no longer an
//  invariant: nothing read it but `move` (the tables, the parametric curve, the
//  sidecar and the wire all go through `evaluate` or store the points as they
//  are). The host's Litti curve keeps its ends' x (`endsInX: false`).

import CoreGraphics
import Foundation

enum CurveChannel: String, CaseIterable, Codable, Sendable, Identifiable {
    case rgb = "rgb", luma = "luma", red = "red", green = "green", blue = "blue"
    var id: String { rawValue }

    /// The desktop's name for the channel.
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .luma: L("Luma")
        case .red: L("Red")
        case .green: L("Green")
        case .blue: L("Blue")
        }
    }

    /// The tab's word on the host's Curve (design/v5: RGB · Luma · R · G · B).
    var tab: String {
        switch self {
        case .rgb: "RGB"
        case .luma: L("Luma")
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        }
    }

    /// The row of the five-row table the shader reads (`CurveSet.tables`).
    var row: Int { CurveChannel.allCases.firstIndex(of: self) ?? 0 }
}

struct Curve: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case points = "points" }
    /// Always sorted by x, always at least two points. The ends start at x = 0 and x = 1 and may be
    /// moved in from there (RFC-035 §3.5); the curve is flat beyond them.
    var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    static let identity = Curve()
    var isIdentity: Bool { points == Curve.identity.points }

    static let tableSize = 256

    /// The point index nearest to `p` within `tolerance`, or nil.
    func index(near p: CGPoint, tolerance: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, q) in points.enumerated() {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= tolerance && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best?.0
    }

    /// Host hit-testing in points, so a wide, shallow plot keeps a circular
    /// 44 pt target rather than stretching it along the wider axis.
    func fingerIndex(near p: CGPoint, in size: CGSize, radius: CGFloat = 22) -> Int? {
        guard size.width > 0, size.height > 0 else { return nil }
        var best: (Int, CGFloat)?
        for (i, q) in points.enumerated() {
            let distance = hypot((q.x - p.x) * size.width, (q.y - p.y) * size.height)
            if distance <= radius && (best == nil || distance < best!.1) { best = (i, distance) }
        }
        return best?.0
    }

    /// How close a touch has to be, in unit-square terms, to count as a hit on
    /// a point in a plot of `size`: ten points of travel whatever the plot
    /// measures (design/v5 §3.3, the desktop's number). A plot not laid out
    /// yet has a zero side: nothing is under a finger that is not over it.
    static func hitTolerance(in size: CGSize, points tolerance: CGFloat = 10) -> CGFloat {
        let side = min(size.width, size.height)
        return side > 0 ? tolerance / side : 0
    }

    /// The point under a touch at `p` (unit square) in a plot of `size`.
    func index(near p: CGPoint, in size: CGSize) -> Int? {
        index(near: p, tolerance: Curve.hitTolerance(in: size))
    }

    /// Whether point `i` may be removed. The two ends are the curve's domain.
    func isDeletable(_ i: Int) -> Bool {
        points.count > 2 && i > 0 && i < points.count - 1
    }

    /// Insert a point, keeping the list sorted. Returns its index.
    @discardableResult
    mutating func insert(_ p: CGPoint) -> Int {
        let q = CGPoint(x: p.x.unitClamped, y: p.y.unitClamped)
        let i = points.firstIndex { $0.x > q.x } ?? points.count
        points.insert(q, at: i)
        return i
    }

    /// Move point `i` to `p`. No point crosses its neighbours (a 0.01 guard keeps
    /// the spline well-conditioned); an end is held in x only by its one neighbour
    /// and the square (RFC-035 §3.5). `endsInX: false` is the host's rule as it
    /// was: an end moves up and down and keeps the x it has.
    mutating func move(_ i: Int, to p: CGPoint, endsInX: Bool = true) {
        guard points.indices.contains(i) else { return }
        var q = CGPoint(x: p.x.unitClamped, y: p.y.unitClamped)
        let last = points.count - 1
        if !endsInX && (i == 0 || i == last) {
            q.x = points[i].x
        } else {
            let lo = i == 0 ? 0 : points[i - 1].x + 0.01
            let hi = i == last ? 1 : points[i + 1].x - 0.01
            q.x = min(max(q.x, min(lo, hi)), max(lo, hi))
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
        return y.unitClamped
    }

    /// The 1-D table: entry `i` is the curve at `i / (size − 1)`.
    func table(size: Int = Curve.tableSize) -> [Float] {
        (0..<size).map { Float(evaluate(CGFloat($0) / CGFloat(size - 1))) }
    }

    // MARK: the editor's gestures (the desktop's `CurveEditor`, as rules)

    /// How far outside the unit square a dragged point goes before it is
    /// taken off the curve: a fifth of the plot, on any side.
    static let removalMargin: CGFloat = 0.2

    /// A finger landed at `p` (unit square, clamped) on a plot of `size`: the
    /// point it lands on within the tolerance, or a new point there. Returns
    /// the index the drag then moves.
    mutating func grab(at p: CGPoint, in size: CGSize) -> Int {
        let q = CGPoint(x: p.x.unitClamped, y: p.y.unitClamped)
        if let i = index(near: q, in: size) { return i }
        return insert(q)
    }

    /// Litti's touch (Edit's 曲线, 2026-10-19): a finger landed at `p` (unit
    /// square) on a plot of `size`. It takes the point under it within a
    /// fingertip (22 pt), or one already at that input; anywhere else it puts a
    /// point **on the curve** at the finger's input, which changes nothing
    /// until the finger moves. Returns the point's index, the offset from the
    /// finger to the point — so the drag carries the point with the finger
    /// rather than jumping it there — and whether the point is new.
    mutating func touch(at p: CGPoint, in size: CGSize) -> (index: Int, offset: CGPoint, added: Bool) {
        if let near = fingerIndex(near: p, in: size) ?? points.firstIndex(where: { abs($0.x - p.x) < 0.02 }) {
            let q = points[near]
            return (near, CGPoint(x: q.x - p.x, y: q.y - p.y), false)
        }
        let x = p.x.unitClamped
        let on = CGPoint(x: x, y: evaluate(x))
        let i = insert(on)
        return (i, CGPoint(x: on.x - p.x, y: on.y - p.y), true)
    }

    /// The finger holding point `i` is at `u` (unit square, not clamped). An
    /// interior point taken more than `removalMargin` out of the square is
    /// removed and nil comes back; otherwise it moves, and its index comes
    /// back. The two ends move but never go (in x too, unless `endsInX` is false).
    mutating func drag(_ i: Int, to u: CGPoint, endsInX: Bool = true) -> Int? {
        let m = Curve.removalMargin
        let outside = u.x < -m || u.x > 1 + m || u.y < -m || u.y > 1 + m
        if outside && isDeletable(i) {
            remove(i)
            return nil
        }
        move(i, to: u, endsInX: endsInX)
        return i
    }

    /// The Mac's and the window's press (RFC-035 §3.4, Capture One's): at `p` (unit square) on a plot
    /// of `size`, the point within `radius` pt; else, between the two ends and within `radius` pt of
    /// the curve, a new point **on the curve** at that input; else nil — the press is on empty plot,
    /// which chooses nothing (the tool deselects). Past an end the curve is flat and is no place to
    /// add a point: there it would become a new end. The offset carries the point with the pointer.
    mutating func press(at p: CGPoint, in size: CGSize, radius: CGFloat = 22) -> (index: Int, offset: CGPoint, added: Bool)? {
        if let near = fingerIndex(near: p, in: size, radius: radius) {
            let q = points[near]
            return (near, CGPoint(x: q.x - p.x, y: q.y - p.y), false)
        }
        guard size.height > 0, let first = points.first, let last = points.last,
              p.x > first.x + 0.01, p.x < last.x - 0.01 else { return nil }
        let on = CGPoint(x: p.x, y: evaluate(p.x))
        guard abs(on.y - p.y) * size.height <= radius else { return nil }
        let i = insert(on)
        return (i, CGPoint(x: on.x - p.x, y: on.y - p.y), true)
    }
}

/// Lightroom's parametric curve: four region amounts under three splits.
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
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case highlights = "highlights", lights = "lights", darks = "darks", shadows = "shadows",
            shadowSplit = "shadowSplit", midtoneSplit = "midtoneSplit", highlightSplit = "highlightSplit"
    }
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

    enum Region: String, CaseIterable, Codable, Sendable, Identifiable {
        case highlights, lights, darks, shadows
        var id: String { rawValue }
        var title: String {
            switch self {
            case .highlights: L("Highlights")
            case .lights: L("Lights")
            case .darks: L("Darks")
            case .shadows: L("Shadows")
            }
        }
    }

    enum Split: Int, CaseIterable, Codable, Sendable { case shadow = 0, midtone = 1, highlight = 2 }

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

    /// The points this curve places, in the unit square, held non-decreasing.
    var curve: Curve {
        // Typed: untyped, the mixed literals here were past Xcode 26's type checker (2026-11-08).
        let s: [Double] = [0, shadowSplit, midtoneSplit, highlightSplit, 1]
        let amounts: [Double] = [shadows, darks, lights, highlights]
        // Each region's offset at its middle: ±100 is half the region's width.
        let offsets: [Double] = (0..<4).map { (r: Int) -> Double in amounts[r] / 100 * (s[r + 1] - s[r]) / 2 }
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
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case rgb = "rgb", luma = "luma", red = "red", green = "green", blue = "blue" }
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
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case rgb = "rgb", luma = "luma", red = "red", green = "green", blue = "blue", parametric = "parametric"
    }
    var rgb = Curve.identity
    var luma = Curve.identity
    var red = Curve.identity
    var green = Curve.identity
    var blue = Curve.identity
    /// The host's parametric curves, applied before the point curves. A key
    /// the desktop does not read; a desktop edit has none, and is neutral here.
    var parametric = ParametricSet()

    /// Applies nothing: every point curve the identity and every parametric neutral.
    var isIdentity: Bool {
        rgb.isIdentity && luma.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity && parametric.isNeutral
    }

    /// The point curve of a channel (the desktop's subscript).
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

    /// The channels that apply something, in the tabs' order.
    var changedChannels: [CurveChannel] { CurveChannel.allCases.filter { !isIdentity($0) } }

    /// A channel as applied: its parametric curve, then its point curve.
    func evaluate(_ channel: CurveChannel, _ x: CGFloat) -> CGFloat {
        let p = parametric[channel]
        return self[channel].evaluate(p.isNeutral ? x : p.curve.evaluate(x))
    }

    /// One channel's table, composed: entry `i` is the channel at `i / 255`.
    /// A channel with no parametric curve is the desktop's table exactly.
    func table(_ channel: CurveChannel, size: Int = Curve.tableSize) -> [Float] {
        let p = parametric[channel]
        guard !p.isNeutral else { return self[channel].table(size: size) }
        let pc = p.curve, point = self[channel]
        return (0..<size).map { Float(point.evaluate(pc.evaluate(CGFloat($0) / CGFloat(size - 1)))) }
    }

    /// Five rows of `Curve.tableSize` floats: rgb, luma, r, g, b — the layout
    /// the shader reads (`Layer2Kernel`).
    func tables() -> [Float] {
        CurveChannel.allCases.flatMap { table($0) }
    }

    /// Back to the identity: one channel, both views.
    mutating func reset(_ channel: CurveChannel) {
        self[channel] = .identity
        parametric[channel] = .neutral
    }

    init() {}

    /// Every key may be missing (a desktop edit has no `parametric`).
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

extension CGFloat {
    /// Into 0…1.
    var unitClamped: CGFloat { Swift.min(Swift.max(self, 0), 1) }
}

/// What a curve tab's plot draws behind its curve: the scene's distribution on the curve's own stop
/// axis, by channel (RFC-035 §3.2; the engine's `fractions` and `fractions_r/g/b`).
///
/// `none` is **not** a fallback to the luminance. A tab whose channel the reading does not carry draws
/// nothing and says why, so the luminance can never be passed off as a channel's hill — the same family
/// as trap 16 and trap 11: a drawing that silently shows the wrong thing looks exactly like a drawing
/// that shows the right one. The decision is here, in the model, so the self-test can hold it
/// (`tools/latitude_selftest.swift`) and the view can only draw what it returns.
enum SceneHills: Equatable, Sendable {
    /// Nothing to draw, and the plot says so (`CurveTool.noHillsNote`).
    case none
    /// 亮度: the luminance's fill alone.
    case luma([Double])
    /// RGB: the luminance's fill, on the channels' scale, under the three channels' lines.
    case rgb(luma: [Double], red: [Double], green: [Double], blue: [Double])
    /// 红 / 绿 / 蓝: that channel's own hill.
    case channel([Double])
}
