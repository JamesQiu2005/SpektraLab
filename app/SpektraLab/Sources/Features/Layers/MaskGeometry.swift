//  MaskGeometry.swift — the tools on the picture as arithmetic, with no view in them (design/masks/MASKS-SPEC.md §6.2,
//  §6.3; RFC-052 §3, §4.1): the brush's settings and their keys' steps, the tool's pill's words, and both gradients'
//  handles — where they are, which one the pointer is on, and what a drag of each does to the part.
//
//  **Everything a tool stores is in the photograph's own coordinates.** Points in S (normalised, top-left origin);
//  distances metric, a share of the source's long edge (`MaskMetric`): a brush is the same brush at every zoom and on
//  every tier, and a circle is a circle on any aspect. The handles' drags are worked in metric coordinates, so ⇧'s
//  15° steps are the photograph's own angles; the view only says where the pointer is and where a handle is drawn
//  (`MaskStage`, through `MaskFrame.view`: the one matrix of the surface, never a copy of the crop's arithmetic).
//  Hit targets are the view's: 22 units round a handle, 8 either side of a line (§6.3).
//
//  Foundation and CoreGraphics only: `tools/masks_selftest.swift` compiles this and holds every rule here.

import CoreGraphics
import Foundation

/// S ↔ metric: p = (x · W/L, y · H/L), L the source's long edge (RFC-052 §3).
struct MaskMetric: Equatable, Sendable {
    var ax: Double
    var ay: Double

    init(width: Int, height: Int) {
        let long = Double(max(width, height, 1))
        ax = Double(max(width, 1)) / long
        ay = Double(max(height, 1)) / long
    }
    init(source: PixelSize) { self.init(width: source.width, height: source.height) }

    func metric(_ s: MaskPoint) -> CGPoint { CGPoint(x: s.x * ax, y: s.y * ay) }
    func source(_ m: CGPoint) -> MaskPoint { MaskPoint(Double(m.x) / ax, Double(m.y) / ay) }
}

/// The four tools of the tool row (MASKS-SPEC §2): 画笔, 线性渐变, 径向渐变 | 橡皮.
enum MaskTool: String, CaseIterable, Sendable {
    case brush, linear, radial, eraser

    var isBrush: Bool { self == .brush || self == .eraser }
    /// What a new layer it makes is called by (MASKS-SPEC §4.1): 画笔 n, 渐变 n.
    var made: MaskRules.Made { isBrush ? .brush : .gradient }
    /// The kind of part it makes.
    var kind: MaskPart.Kind { switch self { case .brush, .eraser: .brush; case .linear: .linear; case .radial: .radial } }
    /// 橡皮 is 画笔 with the join 减去 (MASKS-SPEC §4.3).
    var join: MaskPart.Join { self == .eraser ? .subtract : .add }
    /// ⌥ held: the other of brush and eraser (§6.2).
    var other: MaskTool { switch self { case .brush: .eraser; case .eraser: .brush; default: self } }

    var title: String {
        switch self {
        case .brush: L("Brush")
        case .linear: L("Linear Gradient")
        case .radial: L("Radial Gradient")
        case .eraser: L("Eraser")
        }
    }
    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .linear: "linear"
        case .radial: "radial"
        case .eraser: "eraser"
        }
    }
}

/// A brush's settings (MASKS-SPEC §6.2, RFC-052 §4.1): the radius metric, hardness h and flow F in 0…1. What the
/// popover's 大小, 硬度 and 流量 show; kept by the page across pictures (`MaskTools.brushes`).
struct BrushSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case radius = "radius", hardness = "hardness", flow = "flow" }
    /// Metric: a share of the long edge. 0.01 is a 120 px brush (its diameter) on a 6,000 px photograph.
    var radius = 0.01
    var hardness = 0.5
    var flow = 1.0

    /// From a 1/2000 of the long edge to a quarter of it.
    static let radiusRange: ClosedRange<Double> = 0.0005...0.25

    /// `]` and `[`: larger and smaller by a tenth (§6.2), within the range.
    func larger() -> BrushSettings { var b = self; b.radius = min(radius * 1.1, Self.radiusRange.upperBound); return b }
    func smaller() -> BrushSettings { var b = self; b.radius = max(radius / 1.1, Self.radiusRange.lowerBound); return b }
    /// `⇧]` and `⇧[`: harder and softer by ten (of 100).
    func harder() -> BrushSettings { var b = self; b.hardness = min(((hardness * 100).rounded() + 10) / 100, 1); return b }
    func softer() -> BrushSettings { var b = self; b.hardness = max(((hardness * 100).rounded() - 10) / 100, 0); return b }

    /// 大小 as the pill and the popover say it: the brush's diameter in the photograph's own pixels.
    func sizePixels(longEdge: Int) -> Int { max(1, Int((radius * 2 * Double(max(longEdge, 1))).rounded())) }
    /// The radius for a diameter of `pixels` on a photograph of `longEdge`.
    static func radius(pixels: Double, longEdge: Int) -> Double {
        min(max(pixels / 2 / Double(max(longEdge, 1)), radiusRange.lowerBound), radiusRange.upperBound)
    }

    /// A stroke with these settings through `points` (S).
    func stroke(_ points: [MaskPoint], erase: Bool = false) -> BrushStroke {
        BrushStroke(radius: radius, hardness: hardness, flow: flow, erase: erase, points: points)
    }
}

extension MaskRules {
    /// The tool's pill (MASKS-SPEC §2, §7): shown while a tool with settings, or a join other than 加, is lit. Its
    /// words: the join when it is not the tool's own, the tool, and a brush's size — "减去 · 画笔 · 大小 120". Nil: no
    /// pill (a gradient lit as 加).
    static func pill(_ tool: MaskTool, join: MaskPart.Join, sizePixels: Int?) -> String? {
        let ownJoin = join == tool.join
        guard tool.isBrush || !ownJoin else { return nil }
        var words: [String] = []
        if !ownJoin { words.append(word(join)) }
        words.append(tool.title)
        if tool.isBrush, let sizePixels { words.append(L("Size", as: "a brush's") + " \(sizePixels)") }
        return words.joined(separator: " · ")
    }

    /// The pill's words, longest first, for a row too narrow for them all (`ViewThatFits`): the whole line, then the
    /// line without the tool's name — the lit slot beside it says the tool. Nothing is cut inside a word ("…" is never
    /// drawn): a part is left off whole, as the info strip does. Measured: "Subtract · Brush · Size 1200" is 173 units
    /// in the window where the pill has 152 (the four slots, the divider and the pill's own glyph and chevron take
    /// the rest of the card), "Subtract · Size 1200" 115.
    static func pillLines(_ tool: MaskTool, join: MaskPart.Join, sizePixels: Int?) -> [String] {
        guard let full = pill(tool, join: join, sizePixels: sizePixels) else { return [] }
        var words: [String] = []
        if join != tool.join { words.append(word(join)) }
        if tool.isBrush, let sizePixels { words.append(L("Size", as: "a brush's") + " \(sizePixels)") }
        let short = words.joined(separator: " · ")
        return short.isEmpty || short == full ? [full] : [full, short]
    }

    /// The tag on the picture while the mask is shown alone: "蒙版 · 主体 1".
    static func tag(_ layerName: String) -> String { L("Mask · \(layerName)") }
}

// MARK: - the gradients' handles

/// What the pointer holds of a gradient (MASKS-SPEC §6.3).
enum GradientGrip: Equatable, Sendable {
    /// 线性渐变: the middle's handle (moves it), the 100 % end's and the 0 % end's (turn and stretch about the other).
    case linearMiddle, linearFull, linearZero
    /// 径向渐变: the centre's (moves it), one of the four on the outer line (0 → +u, 1 → +v, 2 → −u, 3 → −v: sets
    /// that axis's radius), just outside one of them (turns it), the accent one on the dashed ring (the fall's width).
    case radialCentre, radialAxis(Int), radialTurn(Int), radialFeather
}

enum MaskHandles {
    /// MASKS-SPEC §6.3's hit targets, in view units: 22 round a handle, 8 either side of a line.
    static let handleTarget: CGFloat = 11
    static let lineTarget: CGFloat = 8
    /// "Just outside a handle" turns a radial: the ring past the handle's own target, out to twice it.
    static let turnTarget: CGFloat = 22
    /// ⇧'s steps.
    static let angleStep = 15.0

    // MARK: linear

    /// The three lines of a linear gradient, each as two far points across the picture (metric): full at `a`,
    /// the middle, none at `b`; each normal to a → b.
    static func linearLines(_ g: MaskLinear, metric: MaskMetric) -> [(GradientGrip, CGPoint, CGPoint)] {
        let a = metric.metric(g.a), b = metric.metric(g.b)
        var d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let len = hypot(d.x, d.y)
        d = len > 0 ? CGPoint(x: d.x / len, y: d.y / len) : CGPoint(x: 1, y: 0)
        let n = CGPoint(x: -d.y * 3, y: d.x * 3)        // three long edges: past the picture whatever its turn
        let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return [(.linearFull, a), (.linearMiddle, m), (.linearZero, b)].map { grip, p in
            (grip, CGPoint(x: p.x - n.x, y: p.y - n.y), CGPoint(x: p.x + n.x, y: p.y + n.y))
        }
    }

    /// The handles of a linear gradient, metric: the middle's on the middle line, each end's on its line.
    static func linearHandles(_ g: MaskLinear, metric: MaskMetric) -> [(GradientGrip, CGPoint)] {
        let a = metric.metric(g.a), b = metric.metric(g.b)
        return [(.linearMiddle, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)), (.linearFull, a), (.linearZero, b)]
    }

    /// A drag of `grip` from `from` to `to` (both metric), applied to `start` (the part when the drag began). ⇧
    /// (`steps`) holds an end's turn to 15° steps about the other end.
    static func drag(_ start: MaskLinear, _ grip: GradientGrip, from: CGPoint, to: CGPoint, steps: Bool, metric: MaskMetric) -> MaskLinear {
        let a = metric.metric(start.a), b = metric.metric(start.b)
        let dx = to.x - from.x, dy = to.y - from.y
        switch grip {
        case .linearMiddle:
            return MaskLinear(a: metric.source(CGPoint(x: a.x + dx, y: a.y + dy)), b: metric.source(CGPoint(x: b.x + dx, y: b.y + dy)))
        case .linearFull:
            let moved = CGPoint(x: a.x + dx, y: a.y + dy)
            return MaskLinear(a: metric.source(steps ? snapped(moved, about: b) : moved), b: start.b)
        case .linearZero:
            let moved = CGPoint(x: b.x + dx, y: b.y + dy)
            return MaskLinear(a: start.a, b: metric.source(steps ? snapped(moved, about: a) : moved))
        default:
            return start
        }
    }

    /// A new linear gradient dragged from `from` to `to` (metric): full where the drag began, none where it ends.
    static func linear(from: CGPoint, to: CGPoint, steps: Bool, metric: MaskMetric) -> MaskLinear {
        MaskLinear(a: metric.source(from), b: metric.source(steps ? snapped(to, about: from) : to))
    }

    /// `p` turned about `centre` to the nearest 15° step, its distance kept.
    static func snapped(_ p: CGPoint, about centre: CGPoint) -> CGPoint {
        let dx = Double(p.x - centre.x), dy = Double(p.y - centre.y)
        let r = (dx * dx + dy * dy).squareRoot()
        guard r > 0 else { return p }
        let step = angleStep * .pi / 180
        let a = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: Double(centre.x) + r * cos(a), y: Double(centre.y) + r * sin(a))
    }

    // MARK: radial

    /// The radial's own axes in metric: u (its x, turned by `angle`, clockwise with y down) and v.
    static func axes(_ g: MaskRadial) -> (u: CGPoint, v: CGPoint) {
        let t = g.angle * .pi / 180
        return (CGPoint(x: cos(t), y: sin(t)), CGPoint(x: -sin(t), y: cos(t)))
    }

    /// The point of the ring at distance `d` (1: the outer line, 1 − f: the dashed ring) at parameter `t` radians.
    static func ring(_ g: MaskRadial, _ d: Double, _ t: Double, metric: MaskMetric) -> CGPoint {
        let c = metric.metric(g.centre), (u, v) = axes(g)
        let x = g.rx * d * cos(t), y = g.ry * d * sin(t)
        return CGPoint(x: Double(c.x) + x * Double(u.x) + y * Double(v.x), y: Double(c.y) + x * Double(u.y) + y * Double(v.y))
    }

    /// The outer line and the dashed ring, as polylines (metric), `n` points each, closed.
    static func radialRings(_ g: MaskRadial, metric: MaskMetric, n: Int = 96) -> (outer: [CGPoint], inner: [CGPoint]) {
        let ts = (0...n).map { Double($0) / Double(n) * 2 * .pi }
        return (ts.map { ring(g, 1, $0, metric: metric) }, ts.map { ring(g, 1 - min(max(g.feather, 0), 1), $0, metric: metric) })
    }

    /// The handles of a radial gradient, metric: the centre, the four on the outer line, the feather's on the dashed
    /// ring (on −v, the top of an upright ellipse, where no axis handle is).
    static func radialHandles(_ g: MaskRadial, metric: MaskMetric) -> [(GradientGrip, CGPoint)] {
        var out: [(GradientGrip, CGPoint)] = [(.radialCentre, metric.metric(g.centre))]
        for k in 0..<4 { out.append((.radialAxis(k), ring(g, 1, Double(k) * .pi / 2, metric: metric))) }
        out.append((.radialFeather, ring(g, 1 - min(max(g.feather, 0), 1), 1.5 * .pi + 0.35, metric: metric)))
        return out
    }

    /// A drag of `grip` (metric points), on `start`. ⌥ (`both`) sets both radii together; ⇧ (`steps`) turns in 15°.
    static func drag(_ start: MaskRadial, _ grip: GradientGrip, from: CGPoint, to: CGPoint, both: Bool, steps: Bool,
                     metric: MaskMetric) -> MaskRadial {
        var g = start
        let c = metric.metric(start.centre), (u, v) = axes(start)
        let px = Double(to.x - c.x), py = Double(to.y - c.y)
        switch grip {
        case .radialCentre:
            g.centre = metric.source(CGPoint(x: c.x + to.x - from.x, y: c.y + to.y - from.y))
        case .radialAxis(let k):
            let along = k % 2 == 0 ? abs(px * Double(u.x) + py * Double(u.y)) : abs(px * Double(v.x) + py * Double(v.y))
            let r = max(along, 1e-4)
            if both {
                let ratio = r / max(k % 2 == 0 ? start.rx : start.ry, 1e-9)
                g.rx = max(start.rx * ratio, 1e-4); g.ry = max(start.ry * ratio, 1e-4)
            } else if k % 2 == 0 { g.rx = r } else { g.ry = r }
        case .radialTurn(let k):
            let base = atan2(Double(from.y - c.y), Double(from.x - c.x)), now = atan2(py, px)
            var angle = start.angle + (now - base) * 180 / .pi
            if steps { angle = (angle / angleStep).rounded() * angleStep }
            _ = k
            g.angle = angle.truncatingRemainder(dividingBy: 360)
        case .radialFeather:
            // The ring's distance where the pointer is, in the ellipse's own units: f = 1 − d.
            let x = (px * Double(u.x) + py * Double(u.y)) / max(start.rx, 1e-9), y = (px * Double(v.x) + py * Double(v.y)) / max(start.ry, 1e-9)
            g.feather = min(max(1 - (x * x + y * y).squareRoot(), 0), 1)
        default:
            break
        }
        return g
    }

    /// A new radial dragged out from its centre `from` to `to` (metric), upright in the photograph; ⇧ a circle.
    static func radial(from: CGPoint, to: CGPoint, circle: Bool) -> (centre: CGPoint, rx: Double, ry: Double) {
        var rx = abs(Double(to.x - from.x)), ry = abs(Double(to.y - from.y))
        if circle { let r = max(rx, ry); rx = r; ry = r }
        return (from, max(rx, 1e-4), max(ry, 1e-4))
    }

    // MARK: hit testing, in the view

    /// Which of `handles` (view points) and `lines` (view polylines) the pointer at `p` is on: the nearest handle
    /// within its target first, then a radial's turn ring round an axis handle, then the nearest line within its
    /// target (a line drags like its handle). Nil: none.
    static func grip(at p: CGPoint, handles: [(GradientGrip, CGPoint)], lines: [(GradientGrip, [CGPoint])]) -> GradientGrip? {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        if let h = handles.min(by: { d($0.1, p) < d($1.1, p) }), d(h.1, p) <= handleTarget { return h.0 }
        for (g, q) in handles {
            if case .radialAxis(let k) = g, d(q, p) <= turnTarget { return .radialTurn(k) }
        }
        var best: (GradientGrip, CGFloat)?
        for (g, line) in lines {
            for (a, b) in zip(line, line.dropFirst()) {
                let e = segmentDistance(p, a, b)
                if e <= lineTarget, e < (best?.1 ?? .infinity) { best = (g, e) }
            }
        }
        return best?.0
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
