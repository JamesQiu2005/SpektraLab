//  LightTableGestures.swift — the fingers on the light table's view (design/lighttable, "Gestures").
//
//  No long press anywhere (RFC-045 §2). Who owns a touch is settled before anything moves and kept
//  until the fingers change (RFC-043):
//
//  - **One finger** on a film carries it (lifted, to the top, chosen, kept on the light); on the empty
//    table it pans the view while the view is zoomed. *The film wins*: a finger on a film always means
//    the film (Freeform's rule).
//  - **Two fingers** zoom the table about their middle, and pan it with it — even over a film: films
//    never scale. Two fingers on the **chosen** film turn it, and carry it, only when they turn 5° before
//    their spread changes 8%; otherwise they zoom. An unchosen film is never turned by two fingers, so
//    a pinch over a crowded table cannot turn one by accident. The turn settles square within 7°.
//  - **A tap** chooses the film under it and brings it to the top, with no wait for a double tap; a tap
//    on the empty table, or on the chosen film again, puts the choice back.
//  - **A double tap** zooms: off a film to 2.5× there, on a film so the film fills the view; back to
//    fit when zoomed. The double tap's first tap has already chosen; its second is not taken as a tap.
//  - **The Loupe tool on**: one finger only magnifies — the lens follows it and stays where it lifts;
//    two fingers still zoom and pan.
//
//  **One recogniser for every finger** (`Fingers`), not a pan, a pinch and a rotation that UIKit
//  plays off against each other: the owner found the zoomed view jumping (2026-10-17). It hands the
//  page every finger down, by the order they landed, on every touch event; what they hold — the
//  view (`LightTableFingers`), a film (`LightTableCarry`) — is taken again whenever a finger lands or
//  lifts, so a pan becomes a pinch when a second finger lands, a pinch a pan when one lifts, and a
//  third finger changes nothing (`LightTableTouch.swift`). Taps stay Apple's recognisers.
//
//  **The log** (`Log.note(.lighttable, "gesture", …)`): one record a gesture — what the fingers did,
//  how many there were and when that changed, its length, the zoom from and to, the largest step of
//  the view's centre and the largest slip of the table under a finger (a jump shows there), and the
//  frames the screen was given meanwhile (`LightTableMetalView.FrameClock`: whether it ran at 120 Hz).
//
//  The page's own word for the loupe tool comes in as `loupeMode`.

import UIKit

@MainActor
final class LightTableGestures: NSObject, UIGestureRecognizerDelegate {
    /// The thresholds that decide two fingers on the chosen film (design/lighttable, "Conflicts").
    static let turnStart = 5 * LightTable.deg
    static let spreadStart = 0.08

    private weak var view: LightTableMetalView?
    private let loupeMode: () -> Bool
    /// Mac (2026-10-24): the Click tool is on (the website's 点击): a click picks a film up and the next puts
    /// it down; a drag from just outside a corner turns it. Off: the table's own fingers (拖动, Drag).
    private let clickMode: () -> Bool
    private var owner: Owner = .none
    private var count = 0
    private var middle = CGPoint.zero
    private var trace: LightTableTrace?
    /// The last single tap: a second one close to it in time and place is a double tap's, not a tap.
    private var lastTap: (time: TimeInterval, at: CGPoint)?

    /// What the fingers hold. `pending`: two fingers on the chosen film, from these points, waiting
    /// to turn it or to zoom.
    private enum Owner: Equatable {
        case none, view, film(UUID), twist(UUID), pending(UUID, [CGPoint]), loupe
        /// Mac: a film turned by the pointer from just outside a corner, about its centre: the turn it began
        /// at, the pointer's last angle about the centre, and how far the pointer has turned since.
        case corner(UUID, r0: Double, prev: Double, turned: Double)
        var name: String {
            switch self {
            case .none: "none"
            case .view: "view"
            case .film: "drag"
            case .twist: "twist"
            case .pending: "pending"
            case .loupe: "loupe"
            case .corner: "corner"
            }
        }
    }

    private static var kept: [ObjectIdentifier: LightTableGestures] = [:]

    private init(view: LightTableMetalView, loupeMode: @escaping () -> Bool, clickMode: @escaping () -> Bool) {
        self.view = view
        self.loupeMode = loupeMode
        self.clickMode = clickMode
    }

    static func attach(to view: LightTableMetalView, loupeMode: @escaping () -> Bool, clickMode: @escaping () -> Bool = { false }) {
        let g = LightTableGestures(view: view, loupeMode: loupeMode, clickMode: clickMode)
        kept[ObjectIdentifier(view)] = g
        let fingers = Fingers(target: g, action: #selector(fingers(_:)))
        fingers.atOnce = loupeMode
        fingers.allUp = { [weak view] in view?.controller.fingers(down: false) }
        let double = UITapGestureRecognizer(target: g, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: g, action: #selector(tap(_:)))
        let down = TouchDown { [weak view] p in
            guard let view, let p else { view?.controller.press(nil); return }
            view.controller.fingers(down: true)
            view.controller.press(loupeMode() || clickMode() ? nil : view.controller.film(at: p))
        }
        for r in [fingers, double, tap, down] as [UIGestureRecognizer] {
            r.delegate = g
            view.addGestureRecognizer(r)
        }
        // Mac: a mouse is one finger, so the table's only zoom was the double click. A wheel or a
        // two-finger scroll, and a trackpad's pinch (which reaches UIKit as a pinch, never as
        // touches, so `Fingers` cannot see it), zoom the table about the pointer (`MacTableZoom`).
        // The scroll is read whole, momentum included, by `MacScrollMonitor` (MacScrollZoom.swift);
        // UIKit's scroll-type pan, which never sees the momentum, only where the monitor cannot be had.
        // The pointer with no button down: a film in the Click tool's hand follows it, the loupe looks where it is.
        let hover = UIHoverGestureRecognizer(target: g, action: #selector(macHovered(_:)))
        var recognizers: [UIGestureRecognizer] = [UIPinchGestureRecognizer(target: g, action: #selector(macPinched(_:))),
                                                  UIRotationGestureRecognizer(target: g, action: #selector(macRotated(_:))), hover]
        if MacScrollMonitor.shared.install() {
            MacScrollMonitor.shared.register(view, accepts: { [weak view] p in
                guard let view, view.window != nil, !view.isHidden else { return false }
                return view.bounds.contains(p)
            }) { [weak g] phase, dy, p in
                let state: UIGestureRecognizer.State = switch phase { case .began: .began; case .changed: .changed; case .ended: .ended }
                g?.macZoomStep(state, scale: exp(Double(dy) * 0.006), at: p)
            }
        } else {
            let scroll = UIPanGestureRecognizer(target: g, action: #selector(macScrolled(_:)))
            scroll.allowedScrollTypesMask = .all
            scroll.allowedTouchTypes = []
            recognizers.append(scroll)
        }
        for r in recognizers {
            r.cancelsTouchesInView = false
            r.delegate = g
            view.addGestureRecognizer(r)
        }
    }

    /// Mac: the zoom as two fingers would make it, about the pointer — a hold of the view
    /// (`LightTableController.beginHold`) taken with two points either side of it, their spread
    /// scaled by the scroll's travel or the pinch's scale — so the limits, the rubber band and the
    /// settle are the fingers' own. 100 pt of scroll is ×1.8, as on the develop page.
    private static let macSpread = 100.0
    private var macZoom: (began: Bool, at: CGPoint)?

    private func macZoomStep(_ state: UIGestureRecognizer.State, scale k: Double, at p: CGPoint) {
        guard let view else { return }
        let c = view.controller
        let d = Self.macSpread * max(k, 0.05)
        let points = [CGPoint(x: p.x - d, y: p.y), CGPoint(x: p.x + d, y: p.y)]
        switch state {
        case .began:
            guard !loupeMode() else { return }
            c.fingers(down: true)
            c.beginHold([CGPoint(x: p.x - Self.macSpread, y: p.y), CGPoint(x: p.x + Self.macSpread, y: p.y)])
            c.hold(points)
            macZoom = (true, p)
        case .changed:
            guard macZoom != nil else { return }
            c.hold(points)
            macZoom = (true, p)
        default:
            guard macZoom != nil else { return }
            macZoom = nil
            c.endHold(about: p)
            c.fingers(down: false)
        }
    }

    @objc private func macScrolled(_ r: UIPanGestureRecognizer) {
        guard let view else { return }
        macZoomStep(r.state, scale: exp(Double(r.translation(in: view).y) * 0.006), at: r.location(in: view))
    }

    @objc private func macPinched(_ r: UIPinchGestureRecognizer) {
        guard let view else { return }
        macZoomStep(r.state, scale: Double(r.scale), at: r.location(in: view))
    }

    /// The pointer over the table with no button down (the website's `pointermove`): a film picked up follows
    /// it; with the loupe on, the lens is under it, and goes when the pointer leaves the table.
    @objc private func macHovered(_ r: UIHoverGestureRecognizer) {
        guard let view else { return }
        let c = view.controller, p = r.location(in: view)
        switch r.state {
        case .began, .changed:
            if c.held != nil { c.follow(p) }
            if loupeMode() { c.loupe(at: p) }
        default:
            if loupeMode() { c.loupe(at: nil) }
        }
    }

    /// The Click tool: two fingers turning on a trackpad turn the film under the pointer (Safari's
    /// `gesturechange` on the website), settling square within 4°.
    private var macTurn: (id: UUID, r0: Double)?

    @objc private func macRotated(_ r: UIRotationGestureRecognizer) {
        guard let view else { return }
        let c = view.controller
        switch r.state {
        case .began:
            guard clickMode(), !loupeMode(), c.held == nil, let id = c.film(at: r.location(in: view)), let it = c.model.item(id) else { macTurn = nil; return }
            macTurn = (id, it.rot)
            c.beginTurn(id)
        case .changed:
            guard let t = macTurn else { return }
            // UIKit's rotation runs clockwise on the screen; the table turns counter-clockwise.
            c.turnFreely(t.id, to: LightTable.settle(t.r0 - Double(r.rotation)))
        default:
            guard let t = macTurn else { return }
            macTurn = nil
            c.endTurn(t.id)
        }
    }

    /// Just outside a corner of a film, within 20 points (the website's `TURN_ZONE`), top film first: the
    /// film, for the Click tool's turn by a corner.
    static let cornerZone = 20.0

    private func cornerFilm(at p: CGPoint) -> UUID? {
        guard let view, view.controller.film(at: p) == nil else { return nil }
        let c = view.controller, w = c.viewport.toWorld(p), zone = Self.cornerZone / c.viewport.s
        for id in c.model.order.reversed() {
            guard let it = c.model.item(id), it.on else { continue }
            let co = cos(it.rot), si = sin(it.rot), dx = w.x - it.x, dy = w.y - it.y
            let u = dx * co + dy * si, v = -dx * si + dy * co
            let ku = u < 0 ? -1.0 : 1.0, kv = v < 0 ? -1.0 : 1.0
            if hypot(u - ku * it.w / 2, v - kv * it.h / 2) <= zone { return id }
        }
        return nil
    }

    /// The pointer's angle about a film's centre, on the table.
    private func angle(about id: UUID, _ p: CGPoint) -> Double? {
        guard let view, let it = view.controller.model.item(id) else { return nil }
        let w = view.controller.viewport.toWorld(p)
        return atan2(w.y - it.y, w.x - it.x)
    }

    static func detach(from view: LightTableMetalView) { kept[ObjectIdentifier(view)] = nil }

    /// Mac: a trackpad's two-finger turn is the Click tool's, over a film; anywhere else it leaves the pinch alone.
    nonisolated func gestureRecognizerShouldBegin(_ r: UIGestureRecognizer) -> Bool {
        guard r is UIRotationGestureRecognizer else { return true }
        return MainActor.assumeIsolated {
            guard let view, clickMode(), !loupeMode() else { return false }
            return view.controller.film(at: r.location(in: view)) != nil
        }
    }

    nonisolated func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        if a is TouchDown || b is TouchDown { return true }
        if a is UIHoverGestureRecognizer || b is UIHoverGestureRecognizer { return true }
        return a is UITapGestureRecognizer && b is UITapGestureRecognizer
    }

    // MARK: taps

    @objc private func tap(_ r: UITapGestureRecognizer) {
        guard let view else { return }
        let c = view.controller, p = r.location(in: view), now = ProcessInfo.processInfo.systemUptime
        // A second click that puts down the film the first picked up is the Click tool's, not a double's.
        if let last = lastTap, now - last.time < 0.4, hypot(p.x - last.at.x, p.y - last.at.y) < 40, !clickMode() {
            lastTap = nil
            return
        }
        lastTap = (now, p)
        if loupeMode() { c.loupe(at: p); return }
        if clickMode() {
            // The website's Click tool: a film in hand is put down where the pointer has carried it; else the
            // film under the click is picked up; a click on the empty table lets the choice go.
            if c.held != nil { c.follow(p); c.putDown() }
            else if let id = c.film(at: p) { c.pickUp(id, at: p) }
            else { c.select(nil) }
            return
        }
        if let id = c.film(at: p), id != c.selected {
            c.select(id)
            c.bringToTop(id)
        } else {
            c.select(nil)
        }
    }

    @objc private func doubleTap(_ r: UITapGestureRecognizer) {
        guard let view, !loupeMode() else { return }
        // The Click tool's two clicks on a film are a pick-up and a put-down (the website's: no zoom on a film).
        if clickMode(), view.controller.film(at: r.location(in: view)) != nil || view.controller.held != nil { return }
        view.controller.doubleTap(at: r.location(in: view))
    }

    // MARK: every finger

    @objc private func fingers(_ r: Fingers) {
        guard let view else { return }
        let c = view.controller, now = CACurrentMediaTime()
        switch r.state {
        case .began:
            trace = LightTableTrace(at: now, zoom: c.viewport.zoom)
            view.frameClock.start(at: now)
            c.fingers(down: true)
            count = r.points.count
            decide(r.points, starts: r.starts)
            step(r, at: now)
        case .changed:
            step(r, at: now)
        default:
            finish(at: now)
        }
    }

    /// Who owns the fingers now down: settled when they come down, and again when they change.
    private func decide(_ points: [CGPoint], starts: [CGPoint]) {
        guard let view, !points.isEmpty else { owner = .none; return }
        let c = view.controller
        if points.count == 1 {
            if loupeMode() { owner = .loupe; c.loupe(at: points[0]); return }
            if clickMode() {
                // The Click tool: a drag from just outside a corner turns the film about its centre; a drag
                // anywhere else moves no film (only Drag does), and pans the view while it is zoomed.
                let start = starts.first ?? points[0]
                if c.held == nil, let id = cornerFilm(at: start), let it = c.model.item(id), let a = angle(about: id, start) {
                    owner = .corner(id, r0: it.rot, prev: a, turned: 0)
                    c.beginTurn(id)
                    return
                }
                if c.viewport.isZoomed || !c.viewport.isSettled { owner = .view; c.beginHold(points) } else { owner = .none }
                return
            }
            // the film wins: the one under where the finger came down
            if let id = c.film(at: starts.first ?? points[0]) {
                owner = .film(id)
                c.beginCarry(id, [starts.first ?? points[0]], turns: false)
                return
            }
            if c.viewport.isZoomed || !c.viewport.isSettled { owner = .view; c.beginHold(points) } else { owner = .none }
            return
        }
        let m = LightTableTouchMath.middle(points)
        if !loupeMode(), let chosen = c.selected, ([m] + points).contains(where: { c.film(at: $0) == chosen }) {
            owner = .pending(chosen, points)
        } else {
            owner = .view
            c.beginHold(points)
        }
    }

    /// The fingers moved, landed or lifted.
    private func step(_ r: Fingers, at now: Double) {
        guard let view else { return }
        let c = view.controller, points = r.points
        guard !points.isEmpty else { return }
        let before = c.viewport
        if points.count != count {
            count = points.count
            changedFingers(points)
        }
        middle = LightTableTouchMath.middle(points)
        switch owner {
        case .view:
            c.hold(points)
        case .film, .twist:
            c.carry(points)
        case .loupe:
            c.loupe(at: points[0])
        case .pending(let id, let start):
            resolve(id, start, points)
        case .corner(let id, let r0, let prev, let turned):
            // Free, settling square within 4°; with ⇧ in 15° steps (Photoshop's free transform, the website's).
            guard let a = angle(about: id, points[0]) else { break }
            let total = turned + LightTable.unwind(a - prev)
            owner = .corner(id, r0: r0, prev: a, turned: total)
            c.turnFreely(id, to: LightTable.settle(r0 + total, steps: r.modifierFlags.contains(.shift)))
        case .none:
            break
        }
        trace?.kind(owner.name)
        trace?.step(r.traced, at: now, from: before, to: c.viewport)
    }

    /// A finger landed or lifted: what the fingers hold is taken again, as they are now.
    private func changedFingers(_ points: [CGPoint]) {
        guard let view else { return }
        let c = view.controller
        switch owner {
        case .loupe where points.count >= 2:
            owner = .view
            c.beginHold(points)
        case .film(let id) where points.count >= 2:
            // a second finger on the film carried: as two fingers on the chosen film, from here
            c.endCarry()
            owner = .pending(id, points)
        case .pending(let id, _):
            if points.count >= 2 { owner = .pending(id, points) } else { decide(points, starts: points) }
        case .none:
            decide(points, starts: points)
        case .view, .film, .twist, .loupe, .corner:
            break       // the hold takes itself again (`LightTableFingers`, `LightTableCarry`)
        }
    }

    /// Two fingers on the chosen film become a turn, when they turn 5° first, or a zoom, when they
    /// spread 8% first — the zoom held from where the fingers are now, so it starts without a jump.
    private func resolve(_ id: UUID, _ start: [CGPoint], _ points: [CGPoint]) {
        guard let view, points.count == start.count, points.count >= 2 else { return }
        let c = view.controller
        let s0 = LightTableTouchMath.spread(start), s1 = LightTableTouchMath.spread(points)
        let a0 = LightTableTouchMath.angle(start) ?? 0, a1 = LightTableTouchMath.angle(points) ?? 0
        if s0 > 1, abs(s1 / s0 - 1) >= Self.spreadStart {
            owner = .view
            c.beginHold(points)
        } else if abs(LightTable.unwind(a1 - a0)) >= Self.turnStart {
            owner = .twist(id)
            c.beginCarry(id, start, turns: true)
            c.carry(points)
        }
    }

    private func finish(at now: Double) {
        guard let view else { return }
        let c = view.controller
        switch owner {
        case .view: c.endHold(about: middle)
        case .film, .twist: c.endCarry()
        case .corner(let id, _, _, _): c.endTurn(id)
        case .pending, .loupe, .none: break
        }
        owner = .none
        count = 0
        guard var t = trace else { return }
        trace = nil
        t.finish(at: now, zoom: c.viewport.zoom)
        var fields = t.fields
        for (k, v) in view.frameClock.fields(at: now) { fields[k] = v }
        Log.note(.lighttable, "gesture", fields)
    }
}

/// Every finger on the view, in the order they landed, told on every touch event. It begins at once
/// with two fingers (or one, `atOnce`: the loupe), and with one once it has moved 10 points; a
/// finger that lifts before then was a tap's, and this fails so the taps can have it.
private final class Fingers: UIGestureRecognizer {
    var atOnce: () -> Bool = { false }
    /// The last finger lifted, whatever was recognised (a tap included).
    var allUp: (() -> Void)?
    private var touches: [UITouch] = []
    private var downAt: [ObjectIdentifier: CGPoint] = [:]
    static let slop = 10.0

    var points: [CGPoint] { touches.map { $0.location(in: view) } }
    /// Where each finger now down came down.
    var starts: [CGPoint] { touches.map { downAt[ObjectIdentifier($0)] ?? $0.location(in: view) } }
    var traced: [(id: Int, at: CGPoint)] { touches.map { (ObjectIdentifier($0).hashValue, $0.location(in: view)) } }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ t: Set<UITouch>, with event: UIEvent) {
        for x in t.sorted(by: { $0.timestamp < $1.timestamp }) where !touches.contains(x) {
            touches.append(x)
            downAt[ObjectIdentifier(x)] = x.location(in: view)
        }
        switch state {
        case .possible: if touches.count >= 2 || atOnce() { state = .began }
        case .began, .changed: state = .changed
        default: break
        }
    }

    override func touchesMoved(_ t: Set<UITouch>, with event: UIEvent) {
        switch state {
        case .possible:
            let moved = touches.contains { x in
                guard let d = downAt[ObjectIdentifier(x)] else { return false }
                let p = x.location(in: view)
                return hypot(p.x - d.x, p.y - d.y) > Self.slop
            }
            if moved { state = .began }
        case .began, .changed: state = .changed
        default: break
        }
    }

    override func touchesEnded(_ t: Set<UITouch>, with event: UIEvent) { lift(t) }
    override func touchesCancelled(_ t: Set<UITouch>, with event: UIEvent) { lift(t) }

    private func lift(_ t: Set<UITouch>) {
        touches.removeAll { t.contains($0) }
        for x in t { downAt[ObjectIdentifier(x)] = nil }
        switch state {
        case .possible: if touches.isEmpty { state = .failed }
        case .began, .changed: state = touches.isEmpty ? .ended : .changed
        default: break
        }
    }

    override func reset() {
        touches = []
        downAt = [:]
        allUp?()
    }
}

/// A finger coming down and lifting, told and never recognised: the press's look (`press`), and the
/// first finger down (`fingers(down:)`).
private final class TouchDown: UIGestureRecognizer {
    private let changed: (CGPoint?) -> Void
    init(_ changed: @escaping (CGPoint?) -> Void) {
        self.changed = changed
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    private var start: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first, numberOfTouches <= 1, let v = view else { start = nil; changed(nil); return }
        start = t.location(in: v)
        changed(start)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let s = start, let t = touches.first, let v = view else { return }
        let a = t.location(in: v)
        if hypot(a.x - s.x, a.y - s.y) > 8 { start = nil; changed(nil) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { changed(nil); state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { changed(nil); state = .failed }
    override func reset() { start = nil }
}
