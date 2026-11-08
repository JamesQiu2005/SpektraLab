//  LightTableTouch.swift — what fingers do to the light table, as arithmetic: the view held by them,
//  a film carried by them, the loupe's lens kept clear of them, and the record of one gesture.
//
//  The owner on the host, 2026-10-17: "during some certain move the zoomed in view still perform
//  sudden jumps". The view used to be anchored once, when two fingers came down, at the middle of
//  the fingers *then down*; UIKit's pinch reports the middle of whichever fingers are down *now*, so
//  a finger lifting, or a third landing, moved that middle by half the fingers' spread in one frame,
//  and the table jumped with it. A one-finger pan and a pinch were two recognisers that could not
//  run together, so a second finger landing during a pan was ignored, and the pan's own middle leapt
//  to the other finger when the first one lifted.
//
//  The rule here: **whenever the fingers on the table change** — one lands, one lifts — **the hold
//  is taken again** from the view as it is that moment, under the fingers as they are that moment.
//  Nothing moves on that frame; from the next, the table point under the fingers' middle stays
//  under it, scaled by their spread when there are two or more. So one finger pans, a second makes
//  it a pinch, a lift makes it a pan again, a third finger changes nothing, and no step of it jumps.
//  Past the table's limits the view gives like a scroll view's rubber band (`LightTableViewport.hold`)
//  rather than stopping, and eases back when the fingers let go.
//
//  Pure Swift, no UIKit: `tools/lighttable_selftest.swift` drives these with touch sequences and
//  measures the jump. `LightTableGestures` feeds them the touches; `LightTableController` owns them.

import CoreGraphics
import Foundation

// MARK: - a seeded random

/// SplitMix64: a small random whose whole sequence is decided by its seed (Scatter's scatter).
struct LightTableRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ≤ u < 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

// MARK: - points

enum LightTableTouchMath {
    static func middle(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        let n = Double(p.count)
        return CGPoint(x: p.reduce(0) { $0 + $1.x } / n, y: p.reduce(0) { $0 + $1.y } / n)
    }

    /// How far the fingers are from their middle, on average, points.
    static func spread(_ p: [CGPoint]) -> Double {
        let m = middle(p)
        return p.reduce(0) { $0 + hypot($1.x - m.x, $1.y - m.y) } / Double(max(p.count, 1))
    }

    /// The first two fingers' angle on the screen, radians, clockwise (y down).
    static func angle(_ p: [CGPoint]) -> Double? {
        guard p.count >= 2 else { return nil }
        return atan2(p[1].y - p[0].y, p[1].x - p[0].x)
    }
}

// MARK: - the view, held

/// The view held by one or more fingers: pan with one, pan and zoom with two or more.
struct LightTableFingers: Sendable {
    /// How many fingers the hold was taken with.
    private(set) var count = 0
    private var zoom = 1.0
    private var world = CGPoint.zero
    private var spread: Double?

    init(_ points: [CGPoint], _ v: LightTableViewport) { rebase(points, v) }

    /// The hold taken again: the zoom and the table point under the fingers' middle as the view
    /// shows them now (before the rubber band's give), and the fingers' spread now.
    mutating func rebase(_ points: [CGPoint], _ v: LightTableViewport) {
        count = points.count
        let m = LightTableTouchMath.middle(points)
        let h = v.held(at: m)
        zoom = h.zoom
        world = h.world
        let s = LightTableTouchMath.spread(points)
        spread = points.count >= 2 && s > 1 ? s : nil
    }

    /// The fingers are where `points` says. A change in how many there are takes the hold again
    /// and moves nothing; otherwise the view follows them.
    mutating func move(_ points: [CGPoint], _ v: inout LightTableViewport) {
        guard !points.isEmpty else { return }
        guard points.count == count else { rebase(points, v); return }
        let m = LightTableTouchMath.middle(points)
        var z = zoom
        if let s0 = spread, points.count >= 2 { z = zoom * LightTableTouchMath.spread(points) / s0 }
        v.hold(zoom: z, world: world, screen: m)
    }
}

// MARK: - a film, carried

/// A film carried by one finger (moved) or two (moved and turned), taken again whenever the fingers
/// change, so the film neither jumps nor loses the turn it has.
struct LightTableCarry: Sendable {
    private(set) var count = 0
    /// The table point under the fingers' middle, and the film's centre, when the hold was taken.
    private var m0 = CGPoint.zero
    private var p0 = CGPoint.zero
    /// Its turn then, before settling square, and the fingers' angle since.
    private var r0 = 0.0
    private var last: Double?
    private var acc = 0.0
    /// Its turn now, before settling square.
    private(set) var turn = 0.0

    init(_ points: [CGPoint], _ v: LightTableViewport, centre: CGPoint, turn: Double) {
        rebase(points, v, centre: centre, turn: turn)
    }

    mutating func rebase(_ points: [CGPoint], _ v: LightTableViewport, centre: CGPoint, turn t: Double) {
        count = points.count
        m0 = v.toWorld(LightTableTouchMath.middle(points))
        p0 = centre
        r0 = t
        turn = t
        acc = 0
        last = LightTableTouchMath.angle(points)
    }

    /// Where the film is to be, and its turn (radians counter-clockwise on the table, unsettled);
    /// nil when the fingers changed, and the hold was taken again from `centre`, where it lies now.
    mutating func move(_ points: [CGPoint], _ v: LightTableViewport, centre: CGPoint) -> (centre: CGPoint, turn: Double)? {
        guard !points.isEmpty else { return nil }
        guard points.count == count else { rebase(points, v, centre: centre, turn: turn); return nil }
        if let a = LightTableTouchMath.angle(points), let l = last {
            acc += LightTable.unwind(a - l)
            last = a
            // clockwise on the screen is counter-clockwise on the table
            turn = r0 - acc
        }
        let m = v.toWorld(LightTableTouchMath.middle(points))
        return (CGPoint(x: p0.x + m.x - m0.x, y: p0.y + m.y - m0.y), turn)
    }
}

// MARK: - the loupe's lens, clear of the finger

/// Where the loupe's lens sits round the finger it follows (the owner, 2026-10-17: "the edge
/// behavior is not treated correctly and thoroughly with some visual ensuring that the edge
/// transition is smooth").
///
/// The lens goes round the finger at a fixed distance, so it never covers what the finger touches.
/// It is above the finger wherever it can be; near a side it slides along, kept inside the view;
/// near the top, where above would put it on the finger, it turns round the finger — beside it, then
/// below — choosing the side away from the nearer edge, and keeping the side it is on while that
/// still serves. The angle is eased (at most `turnRate` a second), and when the lens must go to the
/// other side it goes round underneath, the way that stays clear of the finger and of the edges, so
/// it never jumps and is never cut by the view's edge. No texture and no state but one angle.
struct LightTableLoupePlace: Sendable {
    /// Radians on the screen, y down: −π/2 is straight above the finger.
    private(set) var angle = -Double.pi / 2
    private var fresh = true
    static let above = -Double.pi / 2
    /// Between the finger and the lens's edge, points (the website's 40).
    static let gap = 40.0
    /// The finger's own room the lens never comes nearer than, from its edge, points.
    static let clearance = 24.0
    /// The fastest the lens goes round, radians a second.
    static let turnRate = 9.0
    static let samples = 72

    /// Laid down afresh: the next step puts the lens where it belongs at once.
    mutating func reset() { fresh = true }

    /// The lens's centre, at an angle, for a finger at `f`: round the finger, then kept in the view.
    static func centre(angle a: Double, finger f: CGPoint, view: CGSize, radius r: Double, rim: Double) -> CGPoint {
        let d = r + gap, out = r + rim + 2
        let x = f.x + d * cos(a), y = f.y + d * sin(a)
        let cx = view.width > 2 * out ? LightTableModel.clamp(x, out, view.width - out) : view.width / 2
        let cy = view.height > 2 * out ? LightTableModel.clamp(y, out, view.height - out) : view.height / 2
        return CGPoint(x: cx, y: cy)
    }

    func centre(finger f: CGPoint, view: CGSize, radius r: Double, rim: Double) -> CGPoint {
        Self.centre(angle: angle, finger: f, view: view, radius: r, rim: rim)
    }

    private static func distance(_ a: Double, _ b: Double) -> Double { abs(LightTable.unwind(a - b)) }

    /// Whether the lens at this angle is clear of the finger.
    static func clear(angle a: Double, finger f: CGPoint, view: CGSize, radius r: Double, rim: Double) -> Bool {
        let c = centre(angle: a, finger: f, view: view, radius: r, rim: rim)
        return hypot(c.x - f.x, c.y - f.y) >= r + clearance
    }

    /// Where the lens wants to be for a finger at `f`: clear of it, as near above as can be, as near
    /// where it is as can be, and slid as little by the view's edges as can be.
    func target(finger f: CGPoint, view: CGSize, radius r: Double, rim: Double) -> Double {
        let d = r + Self.gap
        var best = angle, cost = Double.infinity
        for i in 0...Self.samples {
            let a = i == Self.samples ? angle : Self.above + Double(i) * 2 * .pi / Double(Self.samples)
            let c = Self.centre(angle: a, finger: f, view: view, radius: r, rim: rim)
            let slid = hypot(c.x - (f.x + d * cos(a)), c.y - (f.y + d * sin(a)))
            var k = Self.distance(a, Self.above) + 0.5 * Self.distance(a, angle) + 0.002 * slid
            if hypot(c.x - f.x, c.y - f.y) < r + Self.clearance { k += 100 }
            if k < cost - 1e-9 { cost = k; best = a }
        }
        return best
    }

    /// One step of `dt` seconds towards where the lens wants to be. True while it is still going.
    @discardableResult
    mutating func step(finger f: CGPoint, view: CGSize, radius r: Double, rim: Double, dt: Double, reduce: Bool) -> Bool {
        let to = target(finger: f, view: view, radius: r, rim: rim)
        if fresh || reduce { angle = to; fresh = false; return false }
        let short = LightTable.unwind(to - angle)
        guard abs(short) > 1e-4 else { angle = to; return false }
        // Of the two ways round, the one that passes fewer places where the lens would cover the finger.
        let long = short > 0 ? short - 2 * .pi : short + 2 * .pi
        func blocked(_ way: Double) -> Int {
            let n = max(2, Int(abs(way) / (2 * .pi) * Double(Self.samples)))
            return (1..<n).filter { !Self.clear(angle: angle + way * Double($0) / Double(n), finger: f, view: view, radius: r, rim: rim) }.count
        }
        let way = blocked(long) < blocked(short) ? long : short
        let k = 1 - exp(-dt / 0.06)
        let move = way > 0 ? min(way * k, Self.turnRate * dt) : max(way * k, -Self.turnRate * dt)
        angle = LightTable.unwind(angle + (abs(move) < 1e-3 ? way : move))
        return abs(LightTable.unwind(to - angle)) > 1e-4
    }
}

// MARK: - one gesture, as the log says it

/// One gesture on the table, from the first finger down to the last up, as one record for the app's
/// log (`Log.note(.lighttable, "gesture", …)`): never a frame at a time, never a picture or a path.
struct LightTableTrace: Sendable {
    /// What the fingers did, in order: "view", "drag", "twist", "pending", "loupe".
    private(set) var kinds: [String] = []
    /// How many fingers were down, at the start and at each change.
    private(set) var counts: [Int] = []
    private(set) var start = 0.0
    private(set) var end = 0.0
    private(set) var zoomFrom = 1.0
    private(set) var zoomTo = 1.0
    private(set) var steps = 0
    /// The largest frame-to-frame move of the view's centre, points on the screen.
    private(set) var centreStep = 0.0
    /// The largest frame-to-frame slip of the table under a finger that stayed down, points: how far
    /// the table point that was under it lands from where the finger is now. A jump shows here.
    private(set) var slip = 0.0
    /// The largest frame-to-frame move of a finger, points: what a slip or a centre's move is held against.
    private(set) var fingerStep = 0.0
    private var before: [Int: CGPoint] = [:]

    init(at t: Double, zoom: Double) {
        start = t
        end = t
        zoomFrom = zoom
        zoomTo = zoom
    }

    mutating func kind(_ k: String) { if kinds.last != k { kinds.append(k) } }

    /// One step: the touches now (by finger), and the view before and after it.
    mutating func step(_ touches: [(id: Int, at: CGPoint)], at t: Double, from v0: LightTableViewport, to v1: LightTableViewport) {
        end = t
        steps += 1
        zoomTo = v1.zoom
        if counts.last != touches.count { counts.append(touches.count) }
        centreStep = max(centreStep, hypot(v1.cx - v0.cx, v1.cy - v0.cy) * v1.s)
        for (id, p) in touches {
            guard let q = before[id] else { continue }
            fingerStep = max(fingerStep, hypot(p.x - q.x, p.y - q.y))
            if v1 != v0 {
                let w = v1.toScreen(v0.toWorld(q))
                slip = max(slip, hypot(w.x - p.x, w.y - p.y))
            }
        }
        before = Dictionary(touches.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
    }

    mutating func finish(at t: Double, zoom: Double) {
        end = t
        zoomTo = zoom
        if counts.last != 0 { counts.append(0) }
    }

    static func round(_ v: Double, _ places: Double = 10) -> Double { (v * places).rounded() / places }

    var fields: [String: Any] {
        [
            "kind": kinds.joined(separator: ">"),
            "fingers": counts.map(String.init).joined(separator: "-"),
            "ms": Int(((end - start) * 1000).rounded()),
            "zoom_from": Self.round(zoomFrom, 100),
            "zoom_to": Self.round(zoomTo, 100),
            "steps": steps,
            "centre_step_max_pt": Self.round(centreStep),
            "slip_max_pt": Self.round(slip),
            "finger_step_max_pt": Self.round(fingerStep),
        ]
    }
}
