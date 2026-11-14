//  MaskStage.swift — the view over the picture while mask layers are worked (design/masks/MASKS-SPEC.md §6; gap G3):
//  the overlay and the mask alone with its tag, a gradient's lines and handles, the brush's cursor, and the pointer
//  taken to the photograph's own coordinates.
//
//  **One mapping.** The canvas hands the stage the picture's rect in the view (`shown`, the cut picture as drawn,
//  zoomed and panned) and the view → S matrix of that rect (`MaskFrame.view`: Edit's crop, then the finished canvas
//  → S — the turns, a flip, the crop, a straighten, a perspective and a film edge's gate — built from the model's own
//  maps, `AppServices.finishedToSource`). The pointer goes through it to S; a handle comes back through its inverse.
//  There is no other copy of the crop's arithmetic here.
//
//  **Units.** What a tool stores is in S (points) and metric (distances, a share of the long edge: `MaskMetric`);
//  the view's units are only for where a handle is drawn and what the pointer is near (22 round a handle, 8 either side
//  of a line). So a brush keeps its size at every zoom, and its cursor grows with the zoom.
//
//  The pointer: a press-to-release is one stroke or one drag, one step of Undo (`MaskTools`). ⇧ and ⌥ are read from
//  AppKit's own modifier state at each event (`MacModifiers`), since a touch carries none. The system arrow is hidden
//  over the picture while a brush is lit: the cursor is the brush's circle (§6.2), a layer the pointer's own event
//  moves (`MaskPointer`, 2.4.0 A1), never this view's state. While a stroke is drawn live (`MaskLive`) the made
//  overlay of its layer is left off: the live drawing is the whole overlay until the exact one of the stroke lands.

import SwiftUI
import UIKit

struct MaskStage: View {
    let session: OpenFrameSession
    let frameID: UUID
    let source: PixelSize
    /// The picture's rect in the view, as drawn.
    let shown: CGRect
    /// The view's area (the canvas).
    let area: CGSize
    /// `shown`'s normalised coordinates → S.
    let toS: MaskMatrix
    @Environment(\.displayScale) private var scale
    @State private var pressed = false
    private var tools: MaskTools { .shared }
    private var overlay: MaskOverlay { .shared }
    private var metric: MaskMetric { MaskMetric(source: source) }

    // MARK: the mapping

    func toSource(_ q: CGPoint) -> MaskPoint {
        let n = CGPoint(x: (q.x - shown.minX) / max(shown.width, 1), y: (q.y - shown.minY) / max(shown.height, 1))
        let s = toS.apply(n)
        return MaskPoint(Double(s.x), Double(s.y))
    }

    func toView(_ s: MaskPoint) -> CGPoint {
        let n = toS.inverted.apply(CGPoint(x: s.x, y: s.y))
        return CGPoint(x: shown.minX + n.x * shown.width, y: shown.minY + n.y * shown.height)
    }

    func viewOfMetric(_ m: CGPoint) -> CGPoint { toView(metric.source(m)) }

    /// View points per metric unit about `s` (the mapping is a similarity locally: the mean of its two axes).
    func viewPerMetric(at s: MaskPoint) -> CGFloat {
        let p = metric.metric(s), o = viewOfMetric(p)
        let ex = viewOfMetric(CGPoint(x: p.x + 0.01, y: p.y)), ey = viewOfMetric(CGPoint(x: p.x, y: p.y + 0.01))
        return (hypot(ex.x - o.x, ex.y - o.y) + hypot(ey.x - o.x, ey.y - o.y)) / 2 / 0.01
    }

    private var visible: CGRect { shown.intersection(CGRect(origin: .zero, size: area)) }

    // MARK: the view

    /// The person under the pointer in 人's menu (MASKS-SPEC §6.4): shown in the overlay over whatever else is.
    private var preview: LocalLayer? { MaskFinding.shared.preview }

    /// A brush stroke drawn live is under way (`MaskLive`): its moves reach the screen through the live drawing and
    /// the overlay's `follow`, never through this view.
    private var liveStroke: Bool { tools.dragging && MaskLive.shared.covering != nil }

    /// The layer the stage draws: under a live stroke the edit's (the chrome's, `chromeMaskLayer`), so a stroke's moves
    /// do not make this view again — each did, with its three plane keys (each a JSON of every stroke) and the
    /// overlay's ask (2.4.0 A1, by `sample`).
    private var stageLayer: LocalLayer? { liveStroke ? session.chromeMaskLayer : session.pickedMaskLayer }

    var body: some View {
        let preview = preview
        let layer = preview ?? stageLayer
        let alone = preview == nil && tools.aloneShown(session)
        let overlayShown = preview != nil || tools.overlayShown(session)
        let live = preview == nil && MaskLive.shared.covering != nil && MaskLive.shared.covering == session.maskPick
        ZStack(alignment: .topLeading) {
            if live {
                // The live stroke stands for the overlay (`MaskLive`, in the pointer's layer). The made picture is not
                // read here meanwhile: each of the stroke's overlays landing would make this view again (measured:
                // ~15 ms of the main actor every third frame of a stroke in a Debug build).
            } else if let made = overlay.made, made.layer == layer?.id, (alone && made.mode == .alone) || (overlayShown && made.mode == .overlay) {
                Image(uiImage: made.image).resizable().interpolation(.medium)
                    .frame(width: made.rect.width, height: made.rect.height)
                    .position(x: made.rect.midX, y: made.rect.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if alone {
                // The mask alone before its picture lands: black, never the photograph.
                Color.black.frame(width: visible.width, height: visible.height).position(x: visible.midX, y: visible.midY)
                    .allowsHitTesting(false)
            }
            if alone, let layer { tag(layer) }
            if let lines = handleDrawing { lines.allowsHitTesting(false) }
            if let part = handled { handleElements(part) }
            #if DEBUG
            // The brush's circle a check places for a capture (drawing 04); the pointer's own is `MaskPointer`'s.
            if let p = MaskStageProbe.hover, let cursor = brushCursor(at: p) { cursor.allowsHitTesting(false) }
            #endif
            pointer
        }
        .frame(width: area.width, height: area.height)
        // Under a live stroke the overlay is asked by the stroke (`MaskTools.beginStroke`, `follow`).
        .task(id: askKey) { if !liveStroke { overlay.want(ask) } }
        #if DEBUG
        .task(id: "\(shown)|\(area)|\(toS.key)") { MaskStageProbe.placed = (frameID, shown, area, toS) }
        #endif
        .onChange(of: layer?.id) { _, _ in tools.pickChanged(session) }
        .onChange(of: layer.map { MaskBaker.planeKey($0, source: source) }) { old, new in
            // A change of the mask that is not a tool's drag (an Undo of a stroke, a part removed): 0.6 s of overlay.
            if old != nil, new != nil, !tools.dragging { tools.flash() }
        }
        .onDisappear { overlay.want(nil); MacCursor.arrow() }
    }

    // MARK: the overlay's ask

    private var ask: MaskOverlay.Ask? {
        if let preview, visible.width > 1, visible.height > 1 {
            return MaskOverlay.Ask(layer: preview, source: source, shown: shown, toS: toS, visible: visible,
                                   scale: min(scale, 2048 / max(visible.width, visible.height, 1)), mode: .overlay)
        }
        guard let layer = stageLayer, visible.width > 1, visible.height > 1 else { return nil }
        let alone = tools.aloneShown(session)
        guard alone || tools.overlayShown(session) else { return nil }
        var ask = MaskOverlay.Ask(layer: layer, source: source, shown: shown, toS: toS, visible: visible,
                                  scale: min(scale, 2048 / max(visible.width, visible.height, 1)), mode: alone ? .alone : .overlay)
        #if DEBUG
        if MaskStageProbe.broken == "halftexel" { ask.nudge = 0.5 }
        #endif
        return ask
    }
    private var askKey: String? { ask?.key }

    /// "蒙版 · 主体 1" at the top of the picture, centred (drawing 07).
    private func tag(_ layer: LocalLayer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(MaskRules.tag(layer.name)).font(Theme.Font.ui(12, .medium)).foregroundStyle(Color.white).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(.black.opacity(0.7), in: Capsule())
        .fixedSize()
        .position(x: visible.midX, y: visible.minY + 12 + 13)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mask.tag")
    }

    // MARK: a gradient's lines and handles

    /// The chosen part, where the lit tool is of its kind: its handles are on the picture (§6.3).
    private var handled: MaskPart? {
        guard let lit = tools.lit, !lit.isBrush, let id = tools.chosenPart, let part = session.pickedMaskLayer?.parts.first(where: { $0.id == id }),
              part.kind == lit.kind, !tools.aloneShown(session) else { return nil }
        return part
    }

    /// The handles in view points, and the lines as polylines, with the grip each one is.
    private func handles(_ part: MaskPart) -> (points: [(GradientGrip, CGPoint)], lines: [(GradientGrip, [CGPoint])]) {
        if let g = part.linear {
            let pts = MaskHandles.linearHandles(g, metric: metric).map { ($0.0, viewOfMetric($0.1)) }
            let lines = MaskHandles.linearLines(g, metric: metric).map { ($0.0, [viewOfMetric($0.1), viewOfMetric($0.2)]) }
            return (pts, lines)
        }
        if let g = part.radial {
            let pts = MaskHandles.radialHandles(g, metric: metric).map { ($0.0, viewOfMetric($0.1)) }
            // The outer line in four arcs, each the radius handle's in its middle: a line drags like its handle.
            let n = 96
            let outer = MaskHandles.radialRings(g, metric: metric, n: n).outer.map(viewOfMetric)
            var lines: [(GradientGrip, [CGPoint])] = []
            for k in 0..<4 {
                let from = (k * n / 4 - n / 8 + n) % n
                let arc = (0...(n / 4)).map { outer[(from + $0) % n] }
                lines.append((.radialAxis(k), arc))
            }
            return (pts, lines)
        }
        return ([], [])
    }

    private var handleDrawing: AnyView? {
        guard let part = handled else { return nil }
        let (points, _) = handles(part)
        let white = Color.white, shadow = Color.black.opacity(0.45)
        func line(_ path: Path, dashed: Bool) -> some View {
            ZStack {
                path.stroke(shadow, style: StrokeStyle(lineWidth: 3, dash: dashed ? [5, 4] : []))
                path.stroke(white, style: StrokeStyle(lineWidth: dashed ? 1 : 1.5, dash: dashed ? [5, 4] : []))
            }
        }
        func knob(_ p: CGPoint, _ r: CGFloat, accent: Bool = false) -> some View {
            Circle().fill(accent ? Theme.accent : white).frame(width: 2 * r, height: 2 * r)
                .overlay(Circle().stroke(shadow, lineWidth: 1))
                .position(p)
        }
        if let g = part.linear {
            let lines = MaskHandles.linearLines(g, metric: metric)
            return AnyView(ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let (grip, a, b) = lines[i]
                    line(Path { $0.move(to: viewOfMetric(a)); $0.addLine(to: viewOfMetric(b)) }, dashed: grip == .linearMiddle)
                }
                ForEach(0..<points.count, id: \.self) { i in knob(points[i].1, points[i].0 == .linearMiddle ? 6.5 : 4.5) }
                if pressedShown {
                    // "100 %" and "0 %" where each line enters the picture on the left (drawing 05).
                    endTag("100 %", label: L("100 % line"), on: lines[0])
                    endTag("0 %", label: L("0 % line"), on: lines[2])
                }
            }
            .frame(width: area.width, height: area.height).clipShape(Rectangle().path(in: visible)))
        }
        if let g = part.radial {
            let rings = MaskHandles.radialRings(g, metric: metric)
            return AnyView(ZStack {
                line(Path { p in p.addLines(rings.outer.map(viewOfMetric)) }, dashed: false)
                line(Path { p in p.addLines(rings.inner.map(viewOfMetric)) }, dashed: true)
                ForEach(0..<points.count, id: \.self) { i in
                    let (grip, p) = points[i]
                    knob(p, grip == .radialCentre ? 6.5 : 4.5, accent: grip == .radialFeather)
                }
            }
            .frame(width: area.width, height: area.height).clipShape(Rectangle().path(in: visible)))
        }
        return nil
    }

    /// VoiceOver's gradient (MASKS-SPEC §9): each handle an adjustable element where it is drawn, named 100 % 线, 中线,
    /// 0 % 线, 中心, 羽化 (a radial's four radius handles by the gradient's name and their number). Up and down move it by
    /// a hundredth of the long edge: a linear's lines across the gradient, the centre to the right, a radius out or in,
    /// the feather ring out or in. Each is one step of Undo, as a drag is.
    private func handleElements(_ part: MaskPart) -> some View {
        let points = handles(part).points
        return ZStack(alignment: .topLeading) {
            ForEach(0..<points.count, id: \.self) { i in
                let (grip, p) = points[i]
                Color.clear.frame(width: 22, height: 22).position(p)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(handleName(grip))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAdjustableAction { d in nudge(part, grip, by: d == .increment ? 0.01 : -0.01) }
                    .accessibilityIdentifier("mask.handle.\(i)")
            }
        }
        .frame(width: area.width, height: area.height)
    }

    private func handleName(_ grip: GradientGrip) -> String {
        switch grip {
        case .linearFull: L("100 % line")
        case .linearMiddle: L("Middle line")
        case .linearZero: L("0 % line")
        case .radialCentre: L("Centre")
        case .radialFeather: L("Feather")
        case .radialAxis(let k), .radialTurn(let k): L("Radial Gradient") + " \(k + 1)"
        }
    }

    /// A handle moved by `amount` (metric) along its own direction, as a drag of it would.
    private func nudge(_ part: MaskPart, _ grip: GradientGrip, by amount: Double) {
        guard let layer = session.pickedMaskLayer else { return }
        func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let l = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
            return CGPoint(x: (b.x - a.x) / l, y: (b.y - a.y) / l)
        }
        if let g = part.linear {
            let h = MaskHandles.linearHandles(g, metric: metric)
            guard let from = h.first(where: { $0.0 == grip })?.1 else { return }
            let u = unit(metric.metric(g.a), metric.metric(g.b))
            let to = CGPoint(x: from.x + u.x * amount, y: from.y + u.y * amount)
            let moved = MaskHandles.drag(g, grip, from: from, to: to, steps: false, metric: metric)
            session.changePart(layer.id, part: part.id) { $0.linear = moved }
        } else if let g = part.radial {
            let h = MaskHandles.radialHandles(g, metric: metric)
            guard let from = h.first(where: { $0.0 == grip })?.1 else { return }
            let c = metric.metric(g.centre)
            let u = grip == .radialCentre ? CGPoint(x: 1, y: 0) : unit(c, from)
            let to = CGPoint(x: from.x + u.x * amount, y: from.y + u.y * amount)
            let moved = MaskHandles.drag(g, grip, from: from, to: to, both: false, steps: false, metric: metric)
            session.changePart(layer.id, part: part.id) { $0.radial = moved }
        }
    }

    private var pressedShown: Bool {
        #if DEBUG
        if MaskStageProbe.pressed { return true }
        #endif
        return pressed
    }

    private func endTag(_ words: String, label: String, on line: (GradientGrip, CGPoint, CGPoint)) -> some View {
        let a = viewOfMetric(line.1), b = viewOfMetric(line.2)
        let (l, r) = a.x <= b.x ? (a, b) : (b, a)
        let x = visible.minX + 34
        let t = r.x - l.x > 0.001 ? (x - l.x) / (r.x - l.x) : 0.5
        let y = l.y + (r.y - l.y) * t
        return Text(verbatim: words).font(Theme.Font.ui(12, .semibold)).foregroundStyle(Color.white)
            .padding(.horizontal, 7).frame(height: 20)
            .background(.black.opacity(0.65), in: Capsule())
            .fixedSize()
            .position(x: x + 8, y: min(max(y + 20, visible.minY + 12), visible.maxY - 12))
            .accessibilityLabel(label)
    }

    // MARK: the brush's cursor

    /// The circle's radius and the hardness's inner radius at `p` (view points), where a brush is in hand over the
    /// picture; nil elsewhere. What `MaskPointer`'s layer and the probe's capture draw.
    func ringAt(_ p: CGPoint) -> (r: CGFloat, inner: CGFloat)? {
        guard let tool = tools.inHand, tool.isBrush, visible.contains(p), !tools.aloneShown(session) else { return nil }
        let s = tools.settings(tool)
        let r = max(CGFloat(s.radius) * viewPerMetric(at: toSource(p)), 2)
        let inner = r * CGFloat(s.hardness)
        return (r, inner > 2 && s.hardness < 1 ? inner : 0)
    }

    private func brushCursor(at p: CGPoint) -> AnyView? {
        guard let (r, inner) = ringAt(p) else { return nil }
        return AnyView(ZStack {
            Circle().stroke(Color.black.opacity(0.4), lineWidth: 3).frame(width: 2 * r, height: 2 * r)
            Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 2 * r, height: 2 * r)
            if inner > 0 {
                Circle().stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 2 * inner, height: 2 * inner)
            }
            Path { c in
                c.move(to: CGPoint(x: -4, y: 0)); c.addLine(to: CGPoint(x: 4, y: 0))
                c.move(to: CGPoint(x: 0, y: -4)); c.addLine(to: CGPoint(x: 0, y: 4))
            }
            .stroke(Color.white, lineWidth: 1)
            .shadow(color: .black.opacity(0.6), radius: 0.5)
            .frame(width: 0, height: 0)
        }
        .position(p))
    }

    // MARK: the pointer

    /// Where the overlay is laid (the ask's fields): the live stroke draws on its pixels.
    private var livePlace: MaskLive.Place? {
        guard visible.width > 1, visible.height > 1 else { return nil }
        return MaskLive.Place(source: source, shown: shown, toS: toS, visible: visible,
                              scale: min(scale, 2048 / max(visible.width, visible.height, 1)))
    }

    /// What the circle is drawn from: a change redraws it where the pointer is.
    private var ringKey: String {
        let tool = tools.inHand
        let s = tool.map { tools.settings($0) }
        return "\(tool?.rawValue ?? "-")|\(s?.radius ?? 0)|\(s?.hardness ?? 0)|\(tools.aloneShown(session))|\(shown)|\(toS.key)"
    }

    private var pointer: some View {
        MaskPointer(lit: tools.lit != nil, label: L("\(tools.lit?.title ?? ""): drag on the picture"), ringKey: ringKey, place: livePlace,
                    ring: { p in ringAt(p) },
                    began: { p in pointerBegan(p) },
                    moved: { start, samples, time in pointerMoved(start, samples, at: time) },
                    ended: {
                        pressed = false
                        tools.endDrag(session, frame: frameID)
                    },
                    hovered: { p in
                        guard let p else { MacCursor.arrow(); return }
                        let option = MacModifiers.option
                        if tools.optionHeld != option { tools.optionHeld = option }
                        if tools.inHand?.isBrush == true, visible.contains(p) { MacCursor.hidden() } else { MacCursor.arrow() }
                    })
            .allowsHitTesting(tools.lit != nil)
    }

    private func pointerBegan(_ start: CGPoint) {
        let shift = MacModifiers.shift, option = MacModifiers.option
        tools.optionHeld = option
        guard visible.contains(start), let tool = tools.inHand else { return }
        if tool.isBrush {
            tools.beginStroke(session, at: toSource(start), frame: frameID, straight: shift)
        } else {
            pressed = true
            var grip: GradientGrip?
            if let part = handled {
                let h = handles(part)
                grip = MaskHandles.grip(at: start, handles: h.points, lines: h.lines)
            }
            tools.beginGradient(session, grip: grip, at: metric.metric(toSource(start)))
        }
    }

    /// One drag event's samples, oldest first: a stroke takes them all, a gradient the last.
    private func pointerMoved(_ start: CGPoint, _ samples: [CGPoint], at time: TimeInterval? = nil) {
        guard let d = tools.drag, let now = samples.last else { return }
        if d.tool.isBrush {
            tools.continueStroke(session, to: samples.map(toSource), metric: metric, at: time)
        } else {
            let shift = MacModifiers.shift, option = MacModifiers.option
            // A new gradient is made past 3 view points of travel, in metric units at the press.
            let minimum = 3 / max(viewPerMetric(at: toSource(start)), 1e-6)
            tools.continueGradient(session, to: metric.metric(toSource(now)), shift: shift, option: option, metric: metric, minimum: Double(minimum))
        }
    }
}

/// ⇧ and ⌥ as AppKit has them now (`NSEvent.modifierFlags`, through the Objective-C runtime: Catalyst links AppKit but
/// its headers are not ours). A SwiftUI drag carries no modifiers.
enum MacModifiers {
    static var flags: UInt {
        guard let cls = NSClassFromString("NSEvent") as AnyObject?, cls.responds(to: NSSelectorFromString("modifierFlags")),
              let n = cls.value(forKey: "modifierFlags") as? NSNumber else { return 0 }
        return n.uintValue
    }
    static var shift: Bool { flags & (1 << 17) != 0 }
    static var option: Bool { flags & (1 << 19) != 0 }
}

#if DEBUG
/// What `--masks-check` reads of the stage and how it breaks it (`MacMaskToolsCheck`): where the picture was placed and
/// the matrix it was placed with, a cursor and the end tags drawn for a capture, and one term of the view's mapping
/// dropped for the self-test (the overlay then leaves the developed effect, which is made by the engine's and the pass's
/// own maps).
@MainActor
enum MaskStageProbe {
    static var placed: (frame: UUID, shown: CGRect, area: CGSize, toS: MaskMatrix)?
    static var hover: CGPoint?
    static var pressed = false
    /// "crop", "printcrop", "straighten", "turn", "flip", "film": that term left out of the stage's matrix.
    static var broken: String?

    static func breaking(_ e: FrameEdit) -> (edit: FrameEdit, printCrop: Geometry) {
        var e = e, printCrop = e.printCrop
        switch broken {
        case "crop": e.geometry.crop = .full
        case "printcrop": printCrop = .default
        case "straighten": e.geometry.angle = 0
        case "turn": e.geometry.quarterTurns = 0
        case "flip": e.geometry.flipH = false; e.geometry.flipV = false
        case "film": e.filmEdge.active = false
        default: break
        }
        return (e, printCrop)
    }
}
#endif
