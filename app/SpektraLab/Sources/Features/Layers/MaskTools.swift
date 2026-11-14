//  MaskTools.swift — the page's mask tools: which tool is lit, which part the picture's handles are for, the overlay
//  and the mask alone, the brushes' settings, and what a stroke or a gradient's drag does to the edit
//  (design/masks/MASKS-SPEC.md §4.3, §6, §8; PRD-E §4 flows 2–4, §5.1).
//
//  **One press-to-release is one step of Undo**, for a stroke and for a drag alike: the drag opens the layer's step
//  (`OpenFrameSession.beganLayer(adjusting: false)`), each pointer event moves the layer as a slider does
//  (`moveLayer`, never a commit per tick), and the lift closes it (`endedLayer`). So a 成片 layer follows the pointer
//  in Edit's pass with nothing developed, and a 场景 layer develops at the live tier when the pointer rests — as every
//  film-side control. With 胶片 picked the drag's first event makes the layer (`makeLayer`, inside the same step: one
//  Undo takes the layer and its stroke away together); with a mask layer picked the part joins its mask.
//
//  **How a stroke joins a mask.** A brush part holds strokes in order (`BrushStrokes`), drawn into its own plane; a
//  part is folded into the layer's mask with its join. A stroke goes into the layer's last part when that is a brush
//  part with the stroke's join (画笔 加, 橡皮 减去), and starts a new part otherwise — so the fold's order is the order
//  the person painted in: an erasure after a subject takes from the subject (橡皮 is 画笔 with 减去, MASKS-SPEC §4.3,
//  not a brush's own erase, which would take only from the brush's paint), and paint after an erasure lands on top
//  of it. 橡皮 with 胶片 picked has nothing to take from and makes no layer (Capture One's eraser on no mask does
//  nothing either).
//
//  Page state (`@Observable`, `@MainActor`): never written with an edit. The brushes' settings are the page's and kept
//  across pictures and launches in the app's defaults (`masks.brushes.v1`), as `DevelopPanelPrefs` keeps the
//  column's.

import CoreGraphics
import Foundation
import Observation
import QuartzCore

@MainActor @Observable
final class MaskTools {
    static let shared = MaskTools()

    /// The tool lit in the tool row; nil: none (MASKS-SPEC §4.3).
    var lit: MaskTool?
    /// The join a drawn tool was lit with by 组合蒙版 (M1c); nil: the tool's own (画笔 加, 橡皮 减去).
    var join: MaskPart.Join?
    /// The part the picture's handles are for: the one a gradient's drag made, or a click on its row (§5).
    var chosenPart: UUID?
    /// `M` and the 蒙版 section's eye: the overlay held on (§6.1).
    var held = false
    /// `⌥M`: the picked layer's mask alone, white on black (§6.1). The page's state; never stored.
    var alone = false
    /// The overlay showing itself for a change: while a tool's drag is under way and for 0.6 s after one (§6.1).
    private(set) var flashing = false
    /// A tool's drag is under way on the picture.
    private(set) var dragging = false
    /// ⌥ as it was at the pointer's last event: the other of brush and eraser while held (§6.2).
    var optionHeld = false
    /// The tool's pill's popover (大小, 硬度, 流量).
    var popover = false
    /// 组合蒙版's popover, under its button (MASKS-SPEC §7).
    var combineOpen = false
    /// 完善蒙版…'s popover: under its button in the panel, or under 羽化's pill on the page (the same popover).
    enum RefineAnchor: Sendable { case panel, page }
    var refineOpen: RefineAnchor?
    /// The mask alone as it was before 完善蒙版… opened: put back as it closes (§6.1, §7).
    @ObservationIgnored private var aloneBeforeRefining: Bool?
    /// The brushes' settings, 画笔's and 橡皮's.
    private(set) var brushes: [MaskTool: BrushSettings]
    /// Where the last stroke ended, for ⇧-click's straight stroke (§6.2): on which picture and layer.
    var lastPoint: (frame: UUID, layer: UUID, point: MaskPoint)?

    static let flashSeconds = 0.6
    static let defaultsKey = "masks.brushes.v1"
    @ObservationIgnored private var flashEnd: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var kept: [String: BrushSettings] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey), let read = try? JSONDecoder().decode([String: BrushSettings].self, from: data) {
            kept = read
        }
        brushes = [.brush: kept[MaskTool.brush.rawValue] ?? BrushSettings(), .eraser: kept[MaskTool.eraser.rawValue] ?? BrushSettings()]
    }

    // MARK: the tool

    /// A click on a tool's slot: lit, or put down when it was lit (§4.3).
    func click(_ tool: MaskTool) { lit == tool ? putDown() : light(tool) }

    func light(_ tool: MaskTool) {
        if lit != tool { join = nil }
        lit = tool
        // A gradient's handles stay for the part chosen of its own kind; another tool's choice is let go.
        popover = false
    }

    /// Esc and a second click: the tool put down, its handles gone.
    func putDown() {
        lit = nil
        join = nil
        popover = false
    }

    /// The tool in the hand: the lit one, or with ⌥ held the other of brush and eraser.
    var inHand: MaskTool? { lit.map { optionHeld ? $0.other : $0 } }

    /// The join the tool in hand joins with.
    var handJoin: MaskPart.Join { join ?? inHand?.join ?? .add }

    func settings(_ tool: MaskTool) -> BrushSettings { brushes[tool.isBrush ? tool : .brush] ?? BrushSettings() }

    func setSettings(_ tool: MaskTool, _ s: BrushSettings) {
        guard tool.isBrush else { return }
        var clamped = s
        clamped.radius = min(max(s.radius, BrushSettings.radiusRange.lowerBound), BrushSettings.radiusRange.upperBound)
        clamped.hardness = min(max(s.hardness, 0), 1)
        clamped.flow = min(max(s.flow, 0.01), 1)
        brushes[tool] = clamped
        let words = Dictionary(uniqueKeysWithValues: brushes.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(words) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// `[` `]` `⇧[` `⇧]` on the lit brush (§6.2).
    func step(_ change: (BrushSettings) -> BrushSettings) {
        guard let tool = lit, tool.isBrush else { return }
        setSettings(tool, change(settings(tool)))
    }

    // MARK: 完善蒙版…

    /// 完善蒙版… opened: the mask alone on the picture while it is (drawing 09).
    func beginRefining() {
        if aloneBeforeRefining == nil { aloneBeforeRefining = alone }
        alone = true
    }

    /// It closed: the view as it was.
    func endRefining() {
        if let was = aloneBeforeRefining { alone = was }
        aloneBeforeRefining = nil
    }

    // MARK: the overlay

    /// Shows the overlay for a change that is not a drag (a stroke's Undo, a part removed): for 0.6 s.
    func flash() {
        flashing = true
        flashEnd?.cancel()
        flashEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.flashSeconds))
            guard !Task.isCancelled else { return }
            self?.flashing = false
        }
    }

    /// Whether the overlay is on the picture now (§6.1): a mask layer picked, the mask not shown alone, no adjustment
    /// being dragged; and held by `M`, or a tool's drag under way, or 0.6 s after a change.
    func overlayShown(_ session: OpenFrameSession) -> Bool {
        session.chromeMaskLayer != nil && !alone && !session.adjusting && (held || dragging || flashing)
    }

    func aloneShown(_ session: OpenFrameSession) -> Bool { alone && session.chromeMaskLayer != nil }

    /// The pick moved, or the picture: the part chosen and the mask alone are the old layer's.
    func pickChanged(_ session: OpenFrameSession) {
        if let id = chosenPart, !(session.pickedMaskLayer?.parts.contains { $0.id == id } ?? false) { chosenPart = nil }
        if session.pickedMaskLayer == nil { alone = false }
    }

    // MARK: a drag on the picture

    /// A drag under way: what it made and what it holds.
    struct Drag {
        var tool: MaskTool
        /// The layer it acts on (made by its first event where 胶片 was picked).
        var layer: UUID
        var part: UUID
        /// A stroke: its points so far (S), and which of its part's strokes it is.
        var points: [MaskPoint] = []
        var stroke = 0
        /// A gradient: the grip held, where the drag began (metric), the part as it was then.
        var grip: GradientGrip?
        var from: CGPoint = .zero
        var startLinear: MaskLinear?
        var startRadial: MaskRadial?
    }
    @ObservationIgnored private(set) var drag: Drag?

    /// A stroke begins at `p` (S) with the tool in hand. Nil where nothing is painted (橡皮 with 胶片 picked, a pair, a
    /// refusal: the drag does nothing).
    @discardableResult
    func beginStroke(_ session: OpenFrameSession, at p: MaskPoint, frame: UUID, straight: Bool) -> Bool {
        guard let tool = inHand, tool.isBrush, LayerRules.takesMasks(session.layerPiece) else { return false }
        let picked = session.pickedMaskLayer
        if picked == nil, tool == .eraser { return false }
        let brush = settings(tool), join = handJoin
        var points = [p]
        if straight, let last = lastPoint, last.frame == frame, last.layer == picked?.id { points = [last.point, p] }
        let stroke = brush.stroke(points)
        let t0 = CACurrentMediaTime()
        session.beganLayer(adjusting: false)
        guard session.isMovingLayer else { return false }
        owed = nil
        var joins = false
        if let layer = picked {
            if let last = layer.parts.last, last.kind == .brush, last.join == join, last.on, let b = last.brush {
                joins = true
                drag = Drag(tool: tool, layer: layer.id, part: last.id, points: points, stroke: b.strokes.count)
                session.moveLayer(layer.id) { l in
                    guard let i = l.parts.firstIndex(where: { $0.id == last.id }) else { return }
                    l.parts[i].brush?.strokes.append(stroke)
                }
            } else {
                let part = MaskPart.brush(BrushStrokes(strokes: [stroke]), join: join)
                drag = Drag(tool: tool, layer: layer.id, part: part.id, points: points, stroke: 0)
                session.moveLayer(layer.id) { $0.parts.append(part) }
            }
        } else {
            let part = MaskPart.brush(BrushStrokes(strokes: [stroke]), join: .add)
            guard let id = session.makeLayer(.brush, parts: [part]) else { session.endedLayer(); return false }
            drag = Drag(tool: tool, layer: id, part: part.id, points: points, stroke: 0)
        }
        dragging = true
        flashing = true
        if let d = drag, MaskLive.shared.begin(layerID: d.layer, before: picked, join: picked == nil ? .add : join, joins: joins,
                                               alone: aloneShown(session)) {
            MaskLive.shared.draw(points, brush: brush, at: t0)
            // The overlay asked here, where the stage laid it: the stage does not ask under a live stroke.
            if let p = MaskLive.shared.place, let l = session.pickedMaskLayer {
                var ask = MaskOverlay.Ask(layer: l, source: p.source, shown: p.shown, toS: p.toS, visible: p.visible, scale: p.scale,
                                          mode: aloneShown(session) ? .alone : .overlay)
                #if DEBUG
                if MaskStageProbe.broken == "halftexel" { ask.nudge = 0.5 }
                #endif
                MaskOverlay.shared.want(ask)
            }
        }
        return true
    }

    /// The stroke goes on to `p`. A point closer than a twentieth of the radius to the last adds nothing the dabs
    /// (every 0.1 r) would show.
    func continueStroke(_ session: OpenFrameSession, to p: MaskPoint, metric: MaskMetric) {
        continueStroke(session, to: [p], metric: metric)
    }

    /// The stroke goes on through `points` (one pointer event's samples, oldest first: `MaskPointerView` hands the
    /// coalesced ones too).
    ///
    /// **Drawn at once, kept when the overlay is ready** (2.4.0 A1). The live stroke (`MaskLive`) is drawn first, in
    /// this event; the layer's move — the session's moving layers, Edit's pass, the overlay's exact bake — is made now
    /// when the overlay is idle, and otherwise owed: the one owed move is the stroke as it stands when the overlay's
    /// picture lands (`payOwed`), and the lift pays it before the step closes. So a stroke's moves never queue behind
    /// a bake, and the main actor does a move's session work at most once per overlay (measured: each move was ~9 ms
    /// of the main actor — the session and the stage's update — before the overlay's bake could begin). The points
    /// and so the stroke the edit keeps are the same; only how often the moving layer is shown changes.
    /// `at`: the event's own time (`UITouch.timestamp`, the clock `CACurrentMediaTime` reads), from which the live
    /// stroke's time to the screen is counted; nil: now.
    func continueStroke(_ session: OpenFrameSession, to points: [MaskPoint], metric: MaskMetric, at eventTime: CFTimeInterval? = nil) {
        guard var d = drag, d.tool.isBrush else { return }
        let t0 = eventTime ?? CACurrentMediaTime()
        let r = settings(d.tool).radius * 0.05
        var added = false
        for p in points {
            guard let last = d.points.last else { break }
            let a = metric.metric(last), b = metric.metric(p)
            guard hypot(a.x - b.x, a.y - b.y) >= r else { continue }
            d.points.append(p)
            added = true
        }
        guard added else { return }
        drag = d
        let live = MaskLive.shared.isLive
        if live { MaskLive.shared.draw(d.points, brush: settings(d.tool), at: t0) }
        owed = session
        if !live || !MaskOverlay.shared.busy { payOwed() }
    }

    #if DEBUG
    /// Each owed move's main-actor time (`--masks-check`'s cost).
    @ObservationIgnored var paid: [Double] = []
    #endif

    /// The session a stroke's move is owed to (`continueStroke`).
    @ObservationIgnored private weak var owed: OpenFrameSession?

    /// The owed move made: the stroke as it stands into the moving layer, and the overlay asked for it.
    func payOwed() {
        guard let session = owed else { return }
        owed = nil
        guard let d = drag, d.tool.isBrush else { return }
        let stroke = settings(d.tool).stroke(d.points)
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { paid.append((CACurrentMediaTime() - t0) * 1000) }
        #endif
        session.moveLayer(d.layer) { l in
            guard let i = l.parts.firstIndex(where: { $0.id == d.part }), var b = l.parts[i].brush, b.strokes.indices.contains(d.stroke) else { return }
            b.strokes[d.stroke] = stroke
            l.parts[i].brush = b
        }
        follow(session)
    }

    /// The overlay asked for the layer as the move left it, now (`MaskOverlay.follow`).
    private func follow(_ session: OpenFrameSession) {
        if let l = session.pickedMaskLayer { MaskOverlay.shared.follow(l) }
    }

    /// A gradient's drag begins at `p` (metric) with the tool in hand: on `grip` of the chosen part, or (nil) a new
    /// part, which is made at the first move past `minimum` (a click alone makes nothing).
    func beginGradient(_ session: OpenFrameSession, grip: GradientGrip?, at p: CGPoint) {
        guard let tool = inHand, !tool.isBrush, LayerRules.takesMasks(session.layerPiece) else { return }
        if let grip, let layer = session.pickedMaskLayer, let id = chosenPart, let part = layer.parts.first(where: { $0.id == id }) {
            session.beganLayer(adjusting: false)
            guard session.isMovingLayer else { return }
            drag = Drag(tool: tool, layer: layer.id, part: id, grip: grip, from: p, startLinear: part.linear, startRadial: part.radial)
            dragging = true; flashing = true
        } else {
            drag = Drag(tool: tool, layer: session.pickedMaskLayer?.id ?? UUID(), part: UUID(), grip: nil, from: p)
        }
    }

    /// The gradient's drag goes on to `p` (metric). ⇧ (`shift`): 15° steps and a circle; ⌥ (`option`): both radii.
    func continueGradient(_ session: OpenFrameSession, to p: CGPoint, shift: Bool, option: Bool, metric: MaskMetric, minimum: Double) {
        guard var d = drag, !d.tool.isBrush else { return }
        if let grip = d.grip {
            let part = d.part
            if let s = d.startLinear {
                let g = MaskHandles.drag(s, grip, from: d.from, to: p, steps: shift, metric: metric)
                session.moveLayer(d.layer) { l in if let i = l.parts.firstIndex(where: { $0.id == part }) { l.parts[i].linear = g } }
            } else if let s = d.startRadial {
                let g = MaskHandles.drag(s, grip, from: d.from, to: p, both: option, steps: shift, metric: metric)
                session.moveLayer(d.layer) { l in if let i = l.parts.firstIndex(where: { $0.id == part }) { l.parts[i].radial = g } }
            }
            follow(session)
            return
        }
        // A new part: made once the pointer has gone `minimum` (metric) from where it pressed.
        let made = dragging
        if !made {
            guard hypot(p.x - d.from.x, p.y - d.from.y) >= minimum else { return }
        }
        let part: MaskPart
        if d.tool == .linear {
            part = MaskPart(id: d.part, join: handJoin, kind: .linear, linear: MaskHandles.linear(from: d.from, to: p, steps: shift, metric: metric))
        } else {
            let r = MaskHandles.radial(from: d.from, to: p, circle: shift)
            part = MaskPart(id: d.part, join: handJoin, kind: .radial,
                            radial: MaskRadial(centre: metric.source(r.centre), rx: r.rx, ry: r.ry))
        }
        if !made {
            session.beganLayer(adjusting: false)
            guard session.isMovingLayer else { drag = nil; return }
            if let layer = session.pickedMaskLayer {
                d.layer = layer.id
                session.moveLayer(layer.id) { $0.parts.append(part) }
            } else {
                var first = part
                first.join = .add
                guard let id = session.makeLayer(.gradient, parts: [first]) else { session.endedLayer(); drag = nil; return }
                d.layer = id
            }
            drag = d
            chosenPart = d.part
            dragging = true; flashing = true
        } else {
            session.moveLayer(d.layer) { l in if let i = l.parts.firstIndex(where: { $0.id == part.id }) { l.parts[i] = part } }
        }
        follow(session)
    }

    /// The pointer lifted: the drag's one step closes, and the overlay stays 0.6 s more.
    func endDrag(_ session: OpenFrameSession, frame: UUID) {
        // The stroke's last points, owed to a bake under way, are the edit's before its step closes.
        payOwed()
        let d = drag
        drag = nil
        guard dragging else { return }
        dragging = false
        session.endedLayer()
        if let d, d.tool.isBrush, let last = d.points.last {
            lastPoint = (frame, d.layer, last)
            let source = MaskLive.shared.place?.source ?? session.frame?.originalSize
            MaskLive.shared.end(awaiting: session.pickedMaskLayer.flatMap { l in source.map { MaskBaker.planeKey(l, source: $0) } })
        }
        flash()
    }

    // MARK: ⌫

    /// ⌫ (§8): the chosen part, or with none chosen the picked layer. False: nothing to remove.
    @discardableResult
    func delete(_ session: OpenFrameSession) -> Bool {
        guard let layer = session.pickedMaskLayer else { return false }
        if let part = chosenPart, layer.parts.contains(where: { $0.id == part }) {
            session.removePart(layer.id, part: part)
            chosenPart = nil
            flash()
        } else {
            session.removeLayer(layer.id)
        }
        return true
    }
}

extension OpenFrameSession {
    /// **The layers as the panel and the page draw them** (M1c step 0c): the moving ones under a slider's drag (the
    /// slider follows its value), the edit's under a tool's drag on the picture — so a stroke's every pointer event
    /// redraws the picture's overlay and not the 图层 card and the layer's page as well, which held the main actor
    /// ~25 ms a move (`--masks-check`'s cost). The card and the page catch up at the lift.
    var chromeMaskLayers: LocalLayers? { MaskTools.shared.dragging ? maskLayers : shownMaskLayers }
    /// The picked layer as the panel and the page draw it.
    var chromeMaskLayer: LocalLayer? { maskPick.flatMap { chromeMaskLayers?[$0] } }
}
