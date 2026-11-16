//  Watermark.swift — 水印 on a photograph (PRD-8, RFC-067 §3; a layer of 图层): the placements an edit
//  holds, and the one geometry the canvas's overlay and the composite draw them by. Its persisted shape
//  is fixed: renaming a property must not move its key, and a key's meaning does not change.
//
//  **The model.** `FrameEdit.watermarks` is a list of `WatermarkPlacement`s in z-order (first = bottom): it
//  is read as layers (the 图层 panel's rows, topmost first: `LayerRules.watermarkRows`). A placement names a mark of
//  the library (`mark`, the file's id) and says where it sits: measured from a corner of the canvas (`anchor`), its
//  centre `dx`, `dy` in from that corner and its width `size`, all in fractions of the canvas's **short side**, so a
//  corner logo stays in its corner, the same size, on a portrait and a landscape frame alike (PRD-8 §4.4). The corner
//  is re-chosen when a gesture ends (`WatermarkGeometry.reanchored`): the stored numbers are always from the nearest
//  corner. The corner enum is the date back's (`DateBackCorner`, `br` · `bl` · `tr` · `tl`), in the canvas's own
//  terms: right is the picture's right, whatever the language. Rotation is radians, clockwise (y down).
//
//  **`on` and `fill`** are written only when not at rest, so an edit that does not use them is the nine keys alone:
//  `on`, the row's eye (absent = shown; a reader that does not know the key shows the mark), and `fill`.
//
//  **The geometry** (`WatermarkGeometry`) is pure arithmetic with no UIKit and no view in it, the single source of
//  truth for overlay/composite parity (RFC-067 §4.1). Canvas coordinates: origin at the canvas's top-left, x right,
//  y **down**, in whatever unit the caller's canvas is measured in — pixels for a composite, points for the overlay.
//
//  **Two clamps, said apart** (a drag could carry half a mark off the canvas):
//  - drawing (`clamped`, never to change): the width held to its limits and the centre held to the canvas — so an
//    edit already written draws where it always drew;
//  - a gesture (`kept`): the mark's turned box held wholly inside the canvas where it fits, and where it
//    cannot (a mark wider than the canvas once turned) its centre on the canvas. A move, a size and a turn end there.
//
//  Marks are outside every reset (`FrameEdit.resetting`, `resetDevelop`) as the film edge and the date are: only
//  删除, a row's ⌫ and Paste change the list.

import CoreGraphics
import Foundation

/// Which picture a mark is laid on (RFC-067 §4): 成片, the finished picture, over everything; or 底片, the base the
/// engine is handed, so the film develops it.
enum WatermarkStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case full = "full", base = "base"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: L("Full image")
        case .base: L("Base")
        }
    }
    /// The row's word for it, as a mask row says its stage: 成片 · 底片.
    var word: String {
        switch self {
        case .full: L("Finished")
        case .base: L("Base")
        }
    }
}

/// One mark on a photograph (RFC-067 §3). A list in z-order (first = bottom).
struct WatermarkPlacement: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// This placement.
    var id: UUID
    /// The library's file (`WatermarkStore`); a mark since deleted draws nothing (its row says so).
    var mark: UUID
    var stage: WatermarkStage = .full
    /// The corner the numbers are measured from (paste keeps it).
    var anchor: DateBackCorner = .br
    /// The centre's distance in from `anchor`, across and down (or up), in fractions of the canvas's short side.
    var dx: Double
    var dy: Double
    /// The mark's width, in fractions of the canvas's short side; its height follows the PNG's aspect.
    var size: Double
    /// Radians, clockwise.
    var rotation: Double = 0
    /// 0…1.
    var opacity: Double = 1
    /// The row's eye (the layer's): off draws nothing. Written only when off.
    var on = true
    /// 填充 (the owner, 2026-11-16: "native style or new filled color"): nil draws the PNG's own colours
    /// (原样); a colour fills the mark's alpha with it, "#RRGGBB" in sRGB (`WatermarkFill`). Written only when set.
    var fill: String? = nil

    init(id: UUID = UUID(), mark: UUID, stage: WatermarkStage = .full, anchor: DateBackCorner = .br,
         dx: Double, dy: Double, size: Double, rotation: Double = 0, opacity: Double = 1, on: Bool = true, fill: String? = nil) {
        self.id = id; self.mark = mark; self.stage = stage; self.anchor = anchor
        self.dx = dx; self.dy = dy; self.size = size; self.rotation = rotation; self.opacity = opacity; self.on = on
        self.fill = WatermarkFill.normalised(fill)
    }

    /// The keys as they are written: nine always, and `on` and `fill` only when not at rest.
    enum CodingKeys: String, CodingKey {
        case id = "id", mark = "mark", stage = "stage", anchor = "anchor", dx = "dx", dy = "dy", size = "size",
            rotation = "rotation", opacity = "opacity", on = "on", fill = "fill"
    }

    /// Lenient where a newer build might write a word this one does not know (a stage, a corner): it falls back
    /// rather than failing the edit. The numbers and the ids are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mark = try c.decode(UUID.self, forKey: .mark)
        stage = (try? c.decodeIfPresent(WatermarkStage.self, forKey: .stage)) ?? .full
        anchor = (try? c.decodeIfPresent(DateBackCorner.self, forKey: .anchor)) ?? .br
        dx = try c.decode(Double.self, forKey: .dx)
        dy = try c.decode(Double.self, forKey: .dy)
        size = try c.decode(Double.self, forKey: .size)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? true
        // A word this build cannot read as a colour draws the PNG's own (and is not written back).
        fill = WatermarkFill.normalised((try? c.decodeIfPresent(String.self, forKey: .fill)) ?? nil)
    }

    /// The nine keys, every one of them, as a synthesised coder writes them; `on` only when off.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mark, forKey: .mark)
        try c.encode(stage, forKey: .stage)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(dx, forKey: .dx)
        try c.encode(dy, forKey: .dy)
        try c.encode(size, forKey: .size)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        if !on { try c.encode(on, forKey: .on) }
        if let fill { try c.encode(fill, forKey: .fill) }
    }

    /// The same place, size, turn and opacity of the same mark: what a paste compares, ids aside.
    func samePlace(as other: WatermarkPlacement) -> Bool {
        var a = self; a.id = other.id
        return a == other
    }
}

/// Where a mark is on a canvas, in the canvas's units (y down).
struct WatermarkFrame: Equatable, Sendable {
    var center: CGPoint
    /// Width and height before the turn.
    var size: CGSize
    /// Radians, clockwise.
    var rotation: Double
    var opacity: Double

    /// The mark's unit square — u right, v down, (0,0) its top-left — onto the canvas.
    var transform: CGAffineTransform {
        CGAffineTransform.identity
            .translatedBy(x: center.x, y: center.y)
            .rotated(by: CGFloat(rotation))
            .scaledBy(x: size.width, y: size.height)
            .translatedBy(x: -0.5, y: -0.5)
    }

    /// The mark's own pixels (origin top-left, y down) onto the canvas.
    func transform(markPixels: CGSize) -> CGAffineTransform {
        guard markPixels.width > 0, markPixels.height > 0 else { return transform }
        return CGAffineTransform(scaleX: 1 / markPixels.width, y: 1 / markPixels.height).concatenating(transform)
    }

    /// The corner of the mark itself (its own top-left is `tl`, before the turn) on the canvas.
    func corner(_ c: DateBackCorner) -> CGPoint {
        let u: CGFloat = c.isRight ? 1 : 0, v: CGFloat = c.isBottom ? 1 : 0
        return CGPoint(x: u, y: v).applying(transform)
    }

    /// The four corners, tl · tr · br · bl.
    var corners: [CGPoint] { [corner(.tl), corner(.tr), corner(.br), corner(.bl)] }

    /// The axis-aligned box round the turned mark.
    var bounds: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// `point` in the mark's unit square (u right, v down); inside the mark is 0…1 on both.
    func unit(of point: CGPoint) -> CGPoint { point.applying(transform.inverted()) }
}

/// The guides a snap is holding, as the overlay draws them (a 1 pt dashed accent line).
struct WatermarkGuides: OptionSet, Hashable, Sendable {
    let rawValue: Int
    /// The centre on the canvas's vertical centre line (x = W/2).
    static let centreX = WatermarkGuides(rawValue: 1 << 0)
    /// The centre on the horizontal centre line (y = H/2).
    static let centreY = WatermarkGuides(rawValue: 1 << 1)
    /// The mark's edge on the safe margin (4 % of the short side in from each edge).
    static let marginLeft = WatermarkGuides(rawValue: 1 << 2)
    static let marginRight = WatermarkGuides(rawValue: 1 << 3)
    static let marginTop = WatermarkGuides(rawValue: 1 << 4)
    static let marginBottom = WatermarkGuides(rawValue: 1 << 5)
    /// The turn on a right angle (no line is drawn for it).
    static let rightAngle = WatermarkGuides(rawValue: 1 << 6)
}

/// A line to draw for a guide, in canvas units.
struct WatermarkGuideLine: Equatable, Sendable {
    var from: CGPoint
    var to: CGPoint
}

/// What a pointer lands on.
enum WatermarkPart: Equatable, Hashable, Sendable {
    /// The mark itself: a drag moves it.
    case body
    /// One of the picked mark's four corner handles (the mark's own corner, before its turn): a drag sizes it about
    /// the opposite corner, aspect kept; with ⌥ it turns it about its centre.
    case handle(DateBackCorner)
    /// The turn handle above the mark's top edge (Keynote's and Preview's Markup's): a drag turns it about its centre.
    case rotate
}

struct WatermarkTouch: Equatable, Hashable, Sendable {
    var placement: UUID
    var part: WatermarkPart
}

/// The marks' arithmetic. Pure; no UIKit.
enum WatermarkGeometry {
    /// At most this many marks on one photograph (W2).
    static let maxPerFrame = 4
    /// A new mark's width, of the short side (N10).
    static let defaultSize = 0.3
    /// The safe margin, of the short side (RFC-067 §5).
    static let safeMargin = 0.04
    /// A turn snaps to a right angle within this (RFC-067 §5).
    static let rightAngleTolerance = 3.0 * .pi / 180
    /// The least width, of the short side: small enough for a signature in a corner, big enough to find.
    static let minSize = 0.02

    // MARK: canvas

    static func shortSide(_ canvas: CGSize) -> Double { Double(min(canvas.width, canvas.height)) }
    static func longSide(_ canvas: CGSize) -> Double { Double(max(canvas.width, canvas.height)) }

    /// The corner's point on the canvas.
    static func point(of corner: DateBackCorner, canvas: CGSize) -> CGPoint {
        CGPoint(x: corner.isRight ? canvas.width : 0, y: corner.isBottom ? canvas.height : 0)
    }

    /// The widest a mark may be, of the short side: neither its width nor its height past the long side.
    static func maxSize(canvas: CGSize, aspect: Double) -> Double {
        let s = shortSide(canvas), l = longSide(canvas)
        guard s > 0 else { return minSize }
        let a = aspect > 0 && aspect.isFinite ? aspect : 1
        return max(minSize, l * min(1, a) / s)
    }

    // MARK: placement ↔ canvas

    /// Where the placement's centre is, as stored (not clamped).
    static func storedCenter(of p: WatermarkPlacement, canvas: CGSize) -> CGPoint {
        let s = shortSide(canvas), o = Self.point(of: p.anchor, canvas: canvas)
        return CGPoint(x: Double(o.x) + (p.anchor.isRight ? -p.dx : p.dx) * s,
                       y: Double(o.y) + (p.anchor.isBottom ? -p.dy : p.dy) * s)
    }

    /// `p` with its centre at `point`, measured from its own anchor (which a drag keeps until it ends).
    static func placement(_ p: WatermarkPlacement, centeredAt point: CGPoint, canvas: CGSize) -> WatermarkPlacement {
        let s = shortSide(canvas)
        guard s > 0 else { return p }
        let o = Self.point(of: p.anchor, canvas: canvas)
        var out = p
        out.dx = Double(p.anchor.isRight ? o.x - point.x : point.x - o.x) / s
        out.dy = Double(p.anchor.isBottom ? o.y - point.y : point.y - o.y) / s
        return out
    }

    /// The placement held to the canvas for drawing: its width between `minSize` and `maxSize`, its
    /// centre on the canvas, its opacity 0…1 and its turn in (−π, π]. What every drawing of it uses (`frame(of:)`).
    static func clamped(_ p: WatermarkPlacement, canvas: CGSize, aspect: Double) -> WatermarkPlacement {
        var out = p
        out.size = min(max(p.size.isFinite ? p.size : defaultSize, minSize), maxSize(canvas: canvas, aspect: aspect))
        out.opacity = min(max(p.opacity.isFinite ? p.opacity : 1, 0), 1)
        out.rotation = normalised(p.rotation)
        let c = storedCenter(of: out, canvas: canvas)
        let held = CGPoint(x: min(max(c.x.isFinite ? c.x : canvas.width / 2, 0), canvas.width),
                           y: min(max(c.y.isFinite ? c.y : canvas.height / 2, 0), canvas.height))
        return held == c ? out : placement(out, centeredAt: held, canvas: canvas)
    }

    /// **A gesture's clamp** (the header's second rule): `clamped`, and then the turned box moved wholly
    /// inside the canvas where it fits in it; on an axis where it cannot fit, its centre on the canvas's centre line.
    static func kept(_ p: WatermarkPlacement, canvas: CGSize, aspect: Double) -> WatermarkPlacement {
        let q = clamped(p, canvas: canvas, aspect: aspect)
        let f = frame(of: q, canvas: canvas, aspect: aspect)
        let b = f.bounds
        func hold(_ c: CGFloat, half: CGFloat, length: CGFloat) -> CGFloat {
            half * 2 > length ? length / 2 : min(max(c, half), length - half)
        }
        let c = CGPoint(x: hold(f.center.x, half: b.width / 2, length: canvas.width),
                        y: hold(f.center.y, half: b.height / 2, length: canvas.height))
        guard abs(c.x - f.center.x) > 1e-9 || abs(c.y - f.center.y) > 1e-9 else { return q }
        return placement(q, centeredAt: c, canvas: canvas)
    }

    /// Where the mark is drawn on a canvas of `canvas`, for a PNG of `aspect` (width ÷ height). Clamped first.
    static func frame(of p: WatermarkPlacement, canvas: CGSize, aspect: Double) -> WatermarkFrame {
        let q = clamped(p, canvas: canvas, aspect: aspect)
        let a = aspect > 0 && aspect.isFinite ? aspect : 1
        let w = q.size * shortSide(canvas)
        return WatermarkFrame(center: storedCenter(of: q, canvas: canvas), size: CGSize(width: w, height: w / a),
                              rotation: q.rotation, opacity: q.opacity)
    }

    /// The canvas corner nearest `point`; on a centre line the side `keeping` is on stays.
    static func nearestCorner(to point: CGPoint, canvas: CGSize, keeping: DateBackCorner = .br) -> DateBackCorner {
        let right = point.x > canvas.width / 2 ? true : point.x < canvas.width / 2 ? false : keeping.isRight
        let bottom = point.y > canvas.height / 2 ? true : point.y < canvas.height / 2 ? false : keeping.isBottom
        switch (right, bottom) {
        case (true, true): return .br
        case (false, true): return .bl
        case (true, false): return .tr
        case (false, false): return .tl
        }
    }

    /// The anchor re-chosen as the corner nearest the mark's centre, the mark where it is (a gesture's end).
    static func reanchored(_ p: WatermarkPlacement, canvas: CGSize) -> WatermarkPlacement {
        let c = storedCenter(of: p, canvas: canvas)
        var out = p
        out.anchor = nearestCorner(to: c, canvas: canvas, keeping: p.anchor)
        return out.anchor == p.anchor ? p : placement(out, centeredAt: c, canvas: canvas)
    }

    /// What a gesture's end writes: kept on the canvas, then measured from its nearest corner.
    static func settled(_ p: WatermarkPlacement, canvas: CGSize, aspect: Double) -> WatermarkPlacement {
        reanchored(kept(p, canvas: canvas, aspect: aspect), canvas: canvas)
    }

    /// A new mark (N10): centred, 0.3 of the short side wide, upright, opaque, on 成片, measured from the bottom-right
    /// corner (the centre is on both centre lines, so the anchor is the default's).
    static func newPlacement(mark: UUID, canvas: CGSize, aspect: Double, id: UUID = UUID()) -> WatermarkPlacement {
        let p = WatermarkPlacement(id: id, mark: mark, dx: 0, dy: 0, size: defaultSize)
        let centred = placement(p, centeredAt: CGPoint(x: canvas.width / 2, y: canvas.height / 2), canvas: canvas)
        return clamped(centred, canvas: canvas, aspect: aspect)
    }

    // MARK: 成片 ↔ 底片

    /// `p` moved from a canvas at `from` to one at `to`, both rects in one coordinate space: the mark keeps its place
    /// and its width on screen where `to` covers it; outside, its centre is clamped in. Then measured from the
    /// nearest corner of `to`.
    static func converted(_ p: WatermarkPlacement, from: CGRect, to: CGRect, aspect: Double) -> WatermarkPlacement {
        let fromCanvas = from.size, toCanvas = to.size
        guard shortSide(fromCanvas) > 0, shortSide(toCanvas) > 0 else { return p }
        let f = frame(of: p, canvas: fromCanvas, aspect: aspect)
        let shared = CGPoint(x: from.minX + f.center.x, y: from.minY + f.center.y)
        var out = p
        out.size = Double(f.size.width) / shortSide(toCanvas)
        out = placement(out, centeredAt: CGPoint(x: shared.x - to.minX, y: shared.y - to.minY), canvas: toCanvas)
        return reanchored(clamped(out, canvas: toCanvas, aspect: aspect), canvas: toCanvas)
    }

    /// `p` moved from a canvas of `from` to one of `to`, `t` taking a point of the first to the second (a similarity):
    /// the mark keeps its place, its width and its turn on screen where `to` covers it; outside, its centre is clamped
    /// in. Then measured from the nearest corner of `to`.
    static func converted(_ p: WatermarkPlacement, from: CGSize, to: CGSize, through t: CGAffineTransform,
                          aspect: Double) -> WatermarkPlacement {
        guard shortSide(from) > 0, shortSide(to) > 0 else { return p }
        let f = frame(of: p, canvas: from, aspect: aspect).through(t)
        var out = p
        out.size = Double(f.size.width) / shortSide(to)
        out.rotation = f.rotation
        out = placement(out, centeredAt: f.center, canvas: to)
        return reanchored(clamped(out, canvas: to, aspect: aspect), canvas: to)
    }

    /// `p` put on `stage`, converted between the two canvases (`WatermarkCanvases`: the 成片 one and the 底片 one on it).
    /// Already on it: as it is.
    static func switched(_ p: WatermarkPlacement, to stage: WatermarkStage, canvases c: WatermarkCanvases,
                         aspect: Double) -> WatermarkPlacement {
        guard p.stage != stage else { return p }
        var out = stage == .base ? converted(p, from: c.full, to: c.base, through: c.baseToFull.inverted(), aspect: aspect)
                                 : converted(p, from: c.base, to: c.full, through: c.baseToFull, aspect: aspect)
        out.stage = stage
        return out
    }

    /// `p` put on `stage`, converted between the two canvases (`full` the finished picture's rect, `base` the engine's
    /// picture's, in one space). Already on it: as it is.
    static func switched(_ p: WatermarkPlacement, to stage: WatermarkStage, full: CGRect, base: CGRect,
                         aspect: Double) -> WatermarkPlacement {
        guard p.stage != stage else { return p }
        var out = stage == .base ? converted(p, from: full, to: base, aspect: aspect)
                                 : converted(p, from: base, to: full, aspect: aspect)
        out.stage = stage
        return out
    }

    // MARK: gestures

    /// Moved by `delta` (canvas units), from its own anchor.
    static func moved(_ p: WatermarkPlacement, by delta: CGSize, canvas: CGSize) -> WatermarkPlacement {
        let c = storedCenter(of: p, canvas: canvas)
        return placement(p, centeredAt: CGPoint(x: c.x + delta.width, y: c.y + delta.height), canvas: canvas)
    }

    /// Sized by `factor` about its centre (a pinch; a nudge), held to the canvas.
    static func scaled(_ p: WatermarkPlacement, by factor: Double, canvas: CGSize, aspect: Double) -> WatermarkPlacement {
        var out = p
        out.size = p.size * (factor.isFinite && factor > 0 ? factor : 1)
        out.size = min(max(out.size, minSize), maxSize(canvas: canvas, aspect: aspect))
        return out
    }

    /// Turned by `angle` radians clockwise.
    static func rotated(_ p: WatermarkPlacement, by angle: Double) -> WatermarkPlacement {
        var out = p
        out.rotation = normalised(p.rotation + angle)
        return out
    }

    /// The turn a pointer at `point` gives a mark centred at `center`, when the drag began at `start` with the mark at
    /// `from` radians: the angle the pointer swept about the centre, added (the rotate handle; ⌥ on a corner).
    static func turn(from: Double, center: CGPoint, start: CGPoint, point: CGPoint) -> Double {
        let a0 = atan2(Double(start.y - center.y), Double(start.x - center.x))
        let a1 = atan2(Double(point.y - center.y), Double(point.x - center.x))
        return normalised(from + a1 - a0)
    }

    /// The turn a drag gives a mark (the Photoshop way): the mark's own turn plus the angle the pointer has swept about the
    /// mark's centre since the press at `from`, now at `to`; **Shift** sets the result to the nearest 15°. The centre stays
    /// where it is (the box is not pushed back inside the canvas while the pointer holds it; the lift's `settled` does).
    static func turned(_ p: WatermarkPlacement, canvas: CGSize, aspect: Double, from: CGPoint, to: CGPoint,
                       shift: Bool) -> WatermarkPlacement {
        let f = frame(of: p, canvas: canvas, aspect: aspect)
        var out = p
        var angle = turn(from: p.rotation, center: f.center, start: from, point: to)
        if shift { angle = normalised((angle / turnStep).rounded() * turnStep) }
        out.rotation = angle
        return out
    }

    /// Shift's step on the turn: 15°.
    static let turnStep = 15 * Double.pi / 180

    /// Sized from a corner handle, aspect kept: the opposite corner stays where it is, and the handle follows the
    /// pointer along the mark's diagonal.
    static func resized(_ p: WatermarkPlacement, handle: DateBackCorner, to point: CGPoint, canvas: CGSize,
                        aspect: Double) -> WatermarkPlacement {
        let s = shortSide(canvas)
        guard s > 0 else { return p }
        let f = frame(of: p, canvas: canvas, aspect: aspect)
        let opposite = f.corner(opposite(of: handle))
        let corner = f.corner(handle)
        let diag = CGVector(dx: corner.x - opposite.x, dy: corner.y - opposite.y)
        let length = hypot(Double(diag.dx), Double(diag.dy))
        guard length > 0 else { return p }
        let ux = Double(diag.dx) / length, uy = Double(diag.dy) / length
        let along = Double(point.x - opposite.x) * ux + Double(point.y - opposite.y) * uy
        let width = Double(f.size.width) * along / length
        let size = min(max(width / s, minSize), maxSize(canvas: canvas, aspect: aspect))
        let reach = length * size * s / Double(f.size.width)
        var out = p
        out.size = size
        out.rotation = f.rotation
        let centre = CGPoint(x: Double(opposite.x) + ux * reach / 2, y: Double(opposite.y) + uy * reach / 2)
        return placement(out, centeredAt: centre, canvas: canvas)
    }

    static func opposite(of c: DateBackCorner) -> DateBackCorner {
        switch c {
        case .br: .tl
        case .bl: .tr
        case .tr: .bl
        case .tl: .br
        }
    }

    // MARK: snapping

    /// `p` snapped (RFC-067 §5): its centre to the centre lines and its turned box's edges to the safe margin when
    /// within `tolerance` (canvas units: 8 pt in the canvas's scale), its turn to a right angle within 3°. Returns the
    /// guides it holds.
    static func snapped(_ p: WatermarkPlacement, canvas: CGSize, aspect: Double,
                        tolerance: Double) -> (placement: WatermarkPlacement, guides: WatermarkGuides) {
        var out = p
        var guides: WatermarkGuides = []
        let quarter = Double.pi / 2
        let nearest = (p.rotation / quarter).rounded() * quarter
        if abs(p.rotation - nearest) <= rightAngleTolerance {
            out.rotation = normalised(nearest)
            guides.insert(.rightAngle)
        }
        let f = frame(of: out, canvas: canvas, aspect: aspect)
        let b = f.bounds, m = safeMargin * shortSide(canvas)
        let hx = Double(b.width) / 2, hy = Double(b.height) / 2
        let w = Double(canvas.width), h = Double(canvas.height)
        func pick(_ value: Double, _ candidates: [(Double, WatermarkGuides)]) -> (Double, WatermarkGuides)? {
            candidates.filter { abs(value - $0.0) <= tolerance }.min { abs(value - $0.0) < abs(value - $1.0) }
        }
        var c = f.center
        if let (x, g) = pick(Double(c.x), [(w / 2, .centreX), (m + hx, .marginLeft), (w - m - hx, .marginRight)]) {
            c.x = x; guides.insert(g)
        }
        if let (y, g) = pick(Double(c.y), [(h / 2, .centreY), (m + hy, .marginTop), (h - m - hy, .marginBottom)]) {
            c.y = y; guides.insert(g)
        }
        if c != f.center { out = placement(out, centeredAt: c, canvas: canvas) }
        return (out, guides)
    }

    /// The lines to draw for `guides` on `canvas` (a right angle draws none).
    static func lines(for guides: WatermarkGuides, canvas: CGSize) -> [WatermarkGuideLine] {
        let w = canvas.width, h = canvas.height, m = CGFloat(safeMargin * shortSide(canvas))
        var out: [WatermarkGuideLine] = []
        func v(_ x: CGFloat) { out.append(WatermarkGuideLine(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: h))) }
        func hz(_ y: CGFloat) { out.append(WatermarkGuideLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: w, y: y))) }
        if guides.contains(.centreX) { v(w / 2) }
        if guides.contains(.marginLeft) { v(m) }
        if guides.contains(.marginRight) { v(w - m) }
        if guides.contains(.centreY) { hz(h / 2) }
        if guides.contains(.marginTop) { hz(m) }
        if guides.contains(.marginBottom) { hz(h - m) }
        return out
    }

    // MARK: hit-testing

    /// Where the turn handle is: `distance` (canvas units) out from the middle of the mark's top edge, along the
    /// mark's own up.
    static func rotateHandle(of f: WatermarkFrame, distance: Double) -> CGPoint {
        let top = CGPoint(x: (f.corner(.tl).x + f.corner(.tr).x) / 2, y: (f.corner(.tl).y + f.corner(.tr).y) / 2)
        let up = CGVector(dx: sin(f.rotation), dy: -cos(f.rotation))
        return CGPoint(x: Double(top.x) + Double(up.dx) * distance, y: Double(top.y) + Double(up.dy) * distance)
    }

    /// What `point` lands on of one mark: the turn handle and the corner handles (within `handleRadius`, only when
    /// `handles`), else the mark's turned body (grown by `slop` on each side), else nothing.
    static func hit(_ point: CGPoint, frame f: WatermarkFrame, handles: Bool, handleRadius: Double,
                    slop: Double = 0, rotateDistance: Double = 0, cornerTurnReach: Double = 0) -> WatermarkPart? {
        if handles {
            if rotateDistance > 0 {
                let r = rotateHandle(of: f, distance: rotateDistance)
                if hypot(Double(point.x - r.x), Double(point.y - r.y)) <= handleRadius { return .rotate }
            }
            let near = [DateBackCorner.tl, .tr, .br, .bl]
                .map { ($0, hypot(Double(point.x - f.corner($0).x), Double(point.y - f.corner($0).y))) }
                .filter { $0.1 <= handleRadius }
                .min { $0.1 < $1.1 }
            if let near { return .handle(near.0) }
        }
        guard f.size.width > 0, f.size.height > 0 else { return nil }
        let u = f.unit(of: point)
        let su = slop / Double(f.size.width), sv = slop / Double(f.size.height)
        if Double(u.x) >= -su && Double(u.x) <= 1 + su && Double(u.y) >= -sv && Double(u.y) <= 1 + sv { return .body }
        // Just outside a corner, off the mark: the turn, as Photoshop's free transform (a corner handle's own radius first).
        if handles, cornerTurnReach > 0,
           [DateBackCorner.tl, .tr, .br, .bl].contains(where: { hypot(Double(point.x - f.corner($0).x), Double(point.y - f.corner($0).y)) <= cornerTurnReach }) {
            return .rotate
        }
        return nil
    }

    /// What `point` lands on among a photograph's marks: the picked mark's handles first, then the marks from the top
    /// of the list (the last drawn) down. `aspect` is each mark's PNG's (1 for one since deleted). A mark switched off
    /// (its eye) is not there to be found.
    static func hit(_ point: CGPoint, in placements: [WatermarkPlacement], selected: UUID?, canvas: CGSize,
                    aspect: (UUID) -> Double, handleRadius: Double, slop: Double = 0,
                    rotateDistance: Double = 0, cornerTurnReach: Double = 0) -> WatermarkTouch? {
        if let selected, let p = placements.first(where: { $0.id == selected }) {
            let f = frame(of: p, canvas: canvas, aspect: aspect(p.mark))
            if let part = hit(point, frame: f, handles: true, handleRadius: handleRadius, slop: 0, rotateDistance: rotateDistance,
                           cornerTurnReach: cornerTurnReach),
               part != .body {
                return WatermarkTouch(placement: p.id, part: part)
            }
        }
        for p in placements.reversed() where p.on {
            let f = frame(of: p, canvas: canvas, aspect: aspect(p.mark))
            if hit(point, frame: f, handles: false, handleRadius: 0, slop: slop) != nil {
                return WatermarkTouch(placement: p.id, part: .body)
            }
        }
        return nil
    }

    // MARK: the list

    static func canAdd(to placements: [WatermarkPlacement]) -> Bool { placements.count < maxPerFrame }

    /// `p` added on top, or nil at the cap (W2).
    static func adding(_ p: WatermarkPlacement, to placements: [WatermarkPlacement]) -> [WatermarkPlacement]? {
        canAdd(to: placements) ? placements + [p] : nil
    }

    /// The marks a paste puts on a photograph (PRD-8 §4.4): the source's, each with a new placement id, those whose
    /// mark is gone dropped (`exists`), at most `maxPerFrame`. And how many were dropped as gone, for the note.
    static func pasted(_ source: [WatermarkPlacement],
                       exists: (UUID) -> Bool = { _ in true }) -> (placements: [WatermarkPlacement], dropped: Int) {
        let kept = source.filter { exists($0.mark) }
        let out = kept.prefix(maxPerFrame).map { p -> WatermarkPlacement in var q = p; q.id = UUID(); return q }
        return (Array(out), source.count - kept.count)
    }

    /// The list with `id` moved one place up the z-order (`by` +1: drawn later, the row higher) or down (−1); as it is
    /// at an end.
    static func reordered(_ placements: [WatermarkPlacement], moving id: UUID, by delta: Int) -> [WatermarkPlacement] {
        guard let i = placements.firstIndex(where: { $0.id == id }) else { return placements }
        let j = min(max(i + delta, 0), placements.count - 1)
        guard j != i else { return placements }
        var out = placements
        out.swapAt(i, j)
        return out
    }

    /// An angle in (−π, π].
    static func normalised(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a <= -.pi { a += 2 * .pi } else if a > .pi { a -= 2 * .pi }
        return a == -0 ? 0 : a
    }

    /// A turn as the page's field says it: degrees, clockwise, in (−180, 180].
    static func degrees(_ radians: Double) -> Double { normalised(radians) * 180 / .pi }
}

/// **What a photograph's marks are, as every reader takes them** (the panel, the page, the canvas and every composite):
/// one rule, so no surface shows what another leaves out (else a pair or a double could export marks
/// its page never showed).
enum WatermarkRules {
    /// The marks a photograph draws: a single photograph's own; **none on a pair or a double in this version** (W5) —
    /// a composite's edit that holds some (a paste, a hand-made file) keeps them and draws none.
    static func placements(_ edit: FrameEdit, isComposite: Bool) -> [WatermarkPlacement] {
        isComposite ? [] : edit.watermarks
    }

    /// Why a pair or a double has no watermark row, said at the panel's foot beside the masks' line; nil for a photograph.
    static func refusal(isComposite: Bool) -> String? {
        isComposite ? L("Watermarks are for single photographs for now") : nil
    }

    /// Whether a mark is drawn over the finished picture: 成片 always; 底片 wherever the film is off (N9: Apple's decode
    /// has no film to lay it under, so it works as 成片, on the 成片 canvas, and the page says so). A 底片 mark with the
    /// film on is laid into the source before the engine (`base`).
    static func drawnAsFull(_ p: WatermarkPlacement, appliesFilm: Bool) -> Bool {
        p.stage == .full || !appliesFilm
    }

    /// The marks drawn over the finished picture, in z-order: on, of the library or not (a renderer skips a mark it
    /// cannot read), each on 成片 (`drawnAsFull`).
    static func finished(_ edit: FrameEdit, isComposite: Bool) -> [WatermarkPlacement] {
        placements(edit, isComposite: isComposite)
            .filter { $0.on && $0.opacity > 0 && drawnAsFull($0, appliesFilm: edit.appliesFilm) }
            .map { var p = $0; p.stage = .full; return p }
    }

    /// **The marks laid into the source before the engine** (RFC-067 §4.2), in z-order: a single photograph's 底片 marks
    /// that are on and not clear, the film on. Empty for every other edit — what keeps a markless edit's develop, its
    /// stamp and its source word what they were (`WatermarkComposite.Base`).
    static func base(_ edit: FrameEdit, isComposite: Bool) -> [WatermarkPlacement] {
        placements(edit, isComposite: isComposite).filter { $0.on && $0.opacity > 0 && !drawnAsFull($0, appliesFilm: edit.appliesFilm) }
    }

    /// **The edit the page develops under a gesture on its marks** (the owner's hand test, 2026-11-16: "when dragging it,
    /// the old location of watermark is still shown on canvas"): the edit without its 底片 marks (`base`), every other
    /// mark and field as it is — the overlay draws the 底片 marks where the pointer has them meanwhile. The edit itself
    /// where it has none, so a gesture on a 成片 mark develops nothing.
    static func underGesture(_ edit: FrameEdit, isComposite: Bool) -> FrameEdit {
        let laid = base(edit, isComposite: isComposite)
        guard !laid.isEmpty else { return edit }
        var clean = edit
        clean.watermarks.removeAll { laid.contains($0) }
        return clean
    }

    /// Whether the develop of this edit carries marks of its own (the histogram counts them: they are in the
    /// developed picture, as a 场景 layer's light is; a 成片 mark is not).
    static func developsMarks(_ edit: FrameEdit, isComposite: Bool) -> Bool { !base(edit, isComposite: isComposite).isEmpty }
}

/// **Where the 底片 canvas lies on the 成片 canvas** (RFC-067 §3): the 底片 canvas is the picture the engine is handed
/// and gives back (Format's crop made, no film edge, turned as the finished picture is); the 成片 canvas is the finished
/// picture — the film's canvas where a film edge is on — cut by Edit's crop. `baseToFull` takes a point of the first
/// (its own units, y down) to the second; both in one isotropic unit (the film's millimetres under a film edge, the
/// picture's pixels otherwise), so it is a similarity: a place, a turn and one scale.
struct WatermarkCanvases: Equatable, Sendable {
    var full: CGSize
    var base: CGSize
    var baseToFull: CGAffineTransform

    /// The finished picture `finished` (uncut), the picture's box on it under a film edge (`box` in the same units,
    /// tilted `tilt` degrees clockwise about `centre`: `FilmGeometry.pictureBox`), and Edit's crop.
    static func of(finished: CGSize, film: (box: CGRect, tilt: Double, centre: CGPoint)?, printCrop: Geometry) -> WatermarkCanvases {
        var base = finished
        var toFinished = CGAffineTransform.identity
        if let film {
            base = film.box.size
            let a = film.tilt * .pi / 180
            toFinished = CGAffineTransform(translationX: film.box.minX, y: film.box.minY)
                .concatenating(CGAffineTransform(translationX: -film.centre.x, y: -film.centre.y))
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(a)))
                .concatenating(CGAffineTransform(translationX: film.centre.x, y: film.centre.y))
        }
        guard !printCrop.isIdentity, finished.width > 0, finished.height > 0 else {
            return WatermarkCanvases(full: finished, base: base, baseToFull: toFinished)
        }
        let crop = printCrop.onFinished(finished)
        let cut = crop.outputSize(for: finished)
        let finishedToCut = crop.outputToSourceTransform(imageSize: finished).inverted()
        return WatermarkCanvases(full: cut, base: base, baseToFull: toFinished.concatenating(finishedToCut))
    }

    /// The same canvases, the 成片 one measured in `shown`'s units (the canvas's points): base → shown.
    func baseToShown(_ shown: CGSize) -> CGAffineTransform {
        guard full.width > 0 else { return baseToFull }
        let k = shown.width / full.width
        return baseToFull.concatenating(CGAffineTransform(scaleX: k, y: k))
    }
}

extension WatermarkFrame {
    /// The same mark seen through `t`, a similarity (a place, a turn, one scale): the frame on the canvas `t` maps to.
    func through(_ t: CGAffineTransform) -> WatermarkFrame {
        let s = sqrt(abs(t.a * t.d - t.b * t.c))
        return WatermarkFrame(center: center.applying(t), size: CGSize(width: size.width * s, height: size.height * s),
                              rotation: WatermarkGeometry.normalised(rotation + atan2(Double(t.b), Double(t.a))), opacity: opacity)
    }
}

extension FrameEdit {
    /// Whether a surface draws watermarks over this edit's finished picture (`WatermarkRules.finished`).
    func drawsMarks(isComposite: Bool) -> Bool { !WatermarkRules.finished(self, isComposite: isComposite).isEmpty }
    /// Whether anything is laid over the developed picture after the print: Edit's pass, or the watermarks. What a
    /// surface asks before it shows its edited picture (`Layer2Copies.served`, the develop page's canvas).
    func finishedActs(isComposite: Bool) -> Bool { editPassActs || drawsMarks(isComposite: isComposite) }
}

/// One mark of the library: an entry of `index.json`, its keys fixed.
struct WatermarkMark: Codable, Identifiable, Equatable, Sendable {
    /// The keys as they are written (the persisted shape): renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case id = "id", name = "name", added = "added", w = "w", h = "h", sha256 = "sha256" }
    var id: UUID
    var name: String
    var added: Date
    /// The PNG's size in pixels.
    var w: Int
    var h: Int
    /// The file's SHA-256, hex.
    var sha256: String
}

/// Where a renderer reads a mark's pixels: the app's library (`WatermarkStore`), or a check's own.
protocol WatermarkPixels: AnyObject, Sendable {
    /// The mark in sRGB, premultiplied 8-bit RGBA, `width` pixels wide; nil when deleted.
    func bitmap(_ id: UUID, width: Int?) -> CGImage?
    /// The mark's entry (its pixel size, its file's hash); nil when deleted.
    func info(_ id: UUID) -> WatermarkMark?
}

/// The mark library's names as the model sees them, handed in by whoever holds the library (`WatermarkStore`), so the
/// model needs no store: a placement's mark is there when it has a name here. `unknown` — no library at hand (a check,
/// a page before the library is read) — takes every mark as there, unnamed.
struct WatermarkNames: Equatable, Sendable {
    /// nil: not known here.
    var names: [UUID: String]?
    static let unknown = WatermarkNames(names: nil)
    /// The app's library's names as they are now (set by the app's model, `AppServices`): what Copy Settings' row says,
    /// what a paste leaves out, what the history names a step by. `unknown` where nothing set it (a check).
    nonisolated(unsafe) static var library: () -> WatermarkNames = { .unknown }
    init(names: [UUID: String]?) { self.names = names }

    func exists(_ mark: UUID) -> Bool { names.map { $0[mark] != nil } ?? true }
    /// The mark's name; nil when it is gone or not known.
    func name(_ mark: UUID) -> String? { names?[mark] }
}

extension DateBackCorner {
    /// The corner a watermark is measured from, as Copy Settings' row says it: 右下角.
    var watermarkSays: String {
        switch self {
        case .br: L("Bottom right", as: "a watermark's corner")
        case .bl: L("Bottom left", as: "a watermark's corner")
        case .tr: L("Top right", as: "a watermark's corner")
        case .tl: L("Top left", as: "a watermark's corner")
        }
    }
}

extension Array where Element == WatermarkPlacement {
    /// Copy Settings' line for a photograph's marks (N13): the first mark's name, its stage and its corner, "+1" for
    /// each more; 无水印 for none. A mark since deleted is said as 水印已删除.
    func summary(names: WatermarkNames) -> String {
        guard let first else { return L("No watermark") }
        let name = !names.exists(first.mark) ? L("Watermark deleted")
            : (names.name(first.mark).flatMap { $0.isEmpty ? nil : $0 } ?? L("Watermark"))
        let more = count > 1 ? " +\(count - 1)" : ""
        return [name, first.stage.label, first.anchor.watermarkSays].joined(separator: " · ") + more
    }
}

/// **填充**: a mark drawn in one colour (the owner's hand test of 2.4.1, 2026-11-16: "other than opacity control, the
/// watermark should also have one section to control the fill color of it. So, native style or new filled color").
/// The PNG's alpha is kept, its colours replaced: every pixel the fill's colour at that pixel's own cover — a logo's
/// antialiased edge stays soft, its holes stay clear. Applied where a mark's pixels are fetched for drawing
/// (`WatermarkComposite.resolve`, so 成片 and 底片 alike — a 底片 mark in a colour develops through the film as that colour
/// would — and the canvas's overlay), never to the library's file. Stored as "#RRGGBB", sRGB, upper case.
enum WatermarkFill {
    /// The swatches the page offers before its picker: white, black, and the colours a signature is usually wanted in.
    static let swatches = ["#FFFFFF", "#000000", "#E1A95F", "#D0342C", "#2F6FDE", "#3A9D5D"]

    /// `word` as this build writes a fill: "#RRGGBB" upper case; nil for none or anything that is not six hex digits.
    static func normalised(_ word: String?) -> String? {
        guard var w = word?.trimmingCharacters(in: .whitespaces) else { return nil }
        if w.hasPrefix("#") { w.removeFirst() }
        guard w.count == 6, w.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + w.uppercased()
    }

    /// The fill's sRGB components, 0…255; nil for none.
    static func rgb(_ word: String?) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let w = normalised(word), let v = UInt32(w.dropFirst(), radix: 16) else { return nil }
        return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    /// The word for sRGB components 0…1.
    static func word(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// `image` (any layout) as premultiplied 8-bit sRGB RGBA with every pixel `fill` at its own alpha: the mark filled.
    /// Nil fill, or a picture that cannot be drawn: nil (draw the mark as it is).
    static func filled(_ image: CGImage, _ fill: String?) -> CGImage? {
        guard let (r, g, b) = rgb(fill), image.width > 0, image.height > 0,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = ctx.data else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = data.assumingMemoryBound(to: UInt8.self)
        let fr = UInt32(r), fg = UInt32(g), fb = UInt32(b)
        for i in 0..<(image.width * image.height) {
            let a = UInt32(px[i * 4 + 3])
            // Premultiplied: the colour × its cover, rounded as Core Graphics rounds (x·a + 127) / 255.
            px[i * 4] = UInt8((fr * a + 127) / 255)
            px[i * 4 + 1] = UInt8((fg * a + 127) / 255)
            px[i * 4 + 2] = UInt8((fb * a + 127) / 255)
        }
        return ctx.makeImage()
    }
}
