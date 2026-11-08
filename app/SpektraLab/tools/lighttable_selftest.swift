//  lighttable_selftest.swift — the light table's arithmetic, checked on this Mac (RFC-045).
//
//      tools/lighttable_selftest.sh                # the checks
//      tools/lighttable_selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//      add --verbose to either                     # every check said, with its numbers
//
//  `LightTable/LightTableModel.swift` is the website's `table.js` arithmetic ported statement for
//  statement, and `LightTable/LightTableSizing.swift` sizes a library frame from the app's own film
//  layout. What could go wrong quietly, with no page and no GPU to show it:
//
//  - **settling a turn** — square within 4° (7° under fingers), 15° steps, JavaScript's rounding of
//    a negative half (`Math.round(-2.5)` is −2), degrees as a person reads them;
//  - **the pile** — the film last put down, moved or turned on top and touched first, one taken off
//    no longer touched, a turned film hit within its turned rectangle, the 99-film cap;
//  - **fingers** (`LightTableTouch.swift`) — a pinch whose finger lifts, a pan a second finger joins,
//    a third finger landing: the table under a finger that stayed never slips more than 2.5 points
//    in a step (the owner's "sudden jumps"); past 8× and the table's edge the view gives on every
//    step and comes back the way it went;
//  - **the loupe's lens** along every edge and into every corner: never cut by the view's edge,
//    never over the finger, never a jump from one step to the next;
//  - **Random** (随机, 2026-10-19) — square, on the light, 3 mm apart while there is room, a new table
//    for a new seed and the same for the same;
//  - **Tidy Up and Scatter with 99 films** of every size — none left out, every one on the light,
//    every one partly seen after Tidy Up; Scatter a new table for a new seed, the same for the same;
//  - **placing** — clear of the scale's 10 mm band and 3 mm from every film, the nearest free spot,
//    kept on the light when moved past its edge or turned;
//  - **the portrait turn** — a film keeps its place in proportion where that place is free;
//  - **the table's sizes and its way up** (2026-10-19) — A4, A5 and A6 either way up; the films
//    carried as one arrangement, a group keeping its millimetres where it fits, kept on the light,
//    never taken off or left out when the table shrinks (99 films onto A6); a sparse table turned
//    and turned back as it was, its films in their order along each axis; a film carried
//    over one it was clear of moved clear of it; a tidied table tidied again; a table kept before
//    there were sizes opening as the A4 it was; the glide between tables (a spring that never
//    overshoots, every film the short way round, lifted only on the way);
//  - **the view** — a table point and its screen point are each other's, a zoom keeps the point
//    under the finger, the clamp keeps the table in the view, the fit;
//  - **what is shown** — a film eases to its place and lands exactly, at once under Reduce Motion;
//  - **sizes in millimetres** for every format and both Film Edge views, as `FilmLayout` lays the
//    film out (the film's width across a strip, the gate and its carrier filed), a pair's piece and
//    strip, a bare frame at its Film Format under a crop;
//  - **the textures' budget** — steps, bytes with mips, the largest halved first and out of view first;
//  - **what is kept** — written and read back, a frame the library let go of left out, a place
//    scaled when the table was turned the other way.
//
//  Compiled with the model and the film layout's own sources (the list `tools/film_edge_parity.py`
//  compiles), no UIKit. AGENTS.md: a check that cannot fire is not a check — `--self-test` runs every
//  check against a rule broken on purpose, one at a time, and requires each run to fail.

import CoreGraphics
import Foundation
import SwiftUI

// `ImportService.root` is where the library is kept; the store's file goes beside it. A folder of the check's own.
enum ImportService {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("lighttable-selftest") }
}

struct Checker {
    var passed = 0
    var failed = 0
    var quiet = false
    /// Every check said, passed or not (`--verbose`).
    var all = false
    mutating func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1; if all { print("  ok: \(what())") } } else {
            failed += 1
            if !quiet { print("  FAILED: \(what())") }
        }
    }
    mutating func near(_ a: Double, _ b: Double, _ accuracy: Double, _ what: @autoclosure () -> String) {
        expect(abs(a - b) <= accuracy, "\(what()): \(a) against \(b)")
    }
}

/// The rules under check, each replaceable by a broken one (`--self-test`).
struct Rules {
    var name = "as written"
    var settle: (Double, Bool, Double) -> Double = { LightTable.settle($0, steps: $1, snap: $2) }
    var place: (inout LightTableModel, UUID, CGSize, CGPoint?) -> Bool = { m, id, s, at in m.place(id, size: s, at: at) }
    var hit: (LightTableModel, CGPoint) -> UUID? = { m, p in m.hit(p) }
    var film: (FilmGeometry) -> CGSize = { LightTableSizing.film($0) }
    var plain: (PixelSize, PixelSize, Double) -> CGSize = { LightTableSizing.plain(display: $0, original: $1, filmFormatMM: $2) }
    var pair: (HalfFramePair, Bool, FilmEdgeView) -> CGSize = { LightTableSizing.pair($0, filmEdge: $1, view: $2) }
    var plan: ([LightTableSteps.Need], Int) -> [UUID: Int] = { LightTableSteps.plan($0, budget: $1) }
    /// Where a film is read from at a step: its kept develop, its full render, or a job asked (2026-10-24).
    var choose: (Int, Int?, Bool, Bool) -> (readsFull: Bool, asks: Bool) = { LightTableSteps.choose(step: $0, keptEdge: $1, hasMore: $2, fullKept: $3) }
    var orient: (inout LightTableModel, Bool) -> Void = { m, p in m.orient(portrait: p) }
    var zoomAt: (inout LightTableViewport, Double, CGPoint, CGPoint) -> Void = { v, z, w, p in v.zoomAt(z, world: w, screen: p) }
    /// The view after each step of a sequence of touches (each step: the fingers down, by finger).
    var track: ([[Touch]], LightTableViewport) -> [LightTableViewport] = { steps, v0 in
        var v = v0, f: LightTableFingers?, out: [LightTableViewport] = []
        for step in steps {
            let p = step.map(\.at)
            if f == nil { f = LightTableFingers(p, v) } else { f!.move(p, &v) }
            out.append(v)
        }
        return out
    }
    /// The lens's centre after one step of a finger.
    var loupe: (inout LightTableLoupePlace, CGPoint, CGSize, Double, Double, Double) -> CGPoint = { l, f, view, r, rim, dt in
        l.step(finger: f, view: view, radius: r, rim: rim, dt: dt, reduce: false)
        return l.centre(finger: f, view: view, radius: r, rim: rim)
    }
    var tidy: (inout LightTableModel, [UUID]) -> Void = { m, ids in m.tidy(ids) }
    /// A layout pass: the view measured again at a size.
    var measure: (inout LightTableViewport, CGSize) -> Void = { v, size in
        v.measure(size: size, inset: .init(top: 10, left: 10, bottom: 10, right: 10), half: LightTable.half(portrait: true))
    }
    var scatter: (inout LightTableModel, UInt64) -> Void = { m, seed in m.scatter(seed: seed) }
    var random: (inout LightTableModel, UInt64) -> Void = { m, seed in m.random(seed: seed) }
    var half: (LightTablePaper, Bool) -> CGSize = { LightTable.half($0, portrait: $1) }
    var relayout: (inout LightTableModel, LightTablePaper, Bool) -> Void = { m, paper, p in m.relayout(paper: paper, portrait: p) }
    /// A kept file read back, every frame 36 × 24.
    var load: (Data) -> LightTableModel? = { data in
        (try? JSONDecoder().decode(StoredTable.self, from: data)).map { k in k.model(portrait: k.portrait) { _ in CGSize(width: 36, height: 24) } }
    }
    var glideShare: (Double) -> Double = { TableGlide.share($0) }
    var glidePose: (TableGlide, LightTableItem, Double) -> (pose: TableGlide.Pose, lift: Double)? = { g, it, f in g.pose(it, at: f) }
    /// The Mac's Actual Size (2026-10-24, `LightTableMacMath.swift`): Mac points a millimetre from the mode and
    /// the panel, and scene points a millimetre through the window's 0.77.
    var macPointsPerMM: (CGSize, CGSize) -> Double? = { MacActualSize.macPointsPerMM(points: $0, millimetres: $1) }
    var scenePointsPerMM: (MacDisplayReading) -> Double? = { MacActualSize.scenePointsPerMM($0) }
    /// The Mac's rail: its films' order, and each tile as the film lies.
    var railOrder: (LightTableModel) -> [UUID] = { LightTableRail.order($0) }
    var railTile: (LightTableItem, CGSize) -> (picture: CGSize, angle: Double, extent: CGSize) = { LightTableRail.tile($0, box: $1) }

    static var broken: [Rules] {
        var out: [Rules] = []
        var r = Rules(); r.name = "settle with Swift's rounding"
        r.settle = { a, steps, snap in
            if steps { return (a / LightTable.step).rounded() * LightTable.step }
            let q = (a / LightTable.quarter).rounded() * LightTable.quarter
            return abs(a - q) < snap ? q : a
        }
        out.append(r)
        r = Rules(); r.name = "settle with no snap"; r.settle = { a, steps, _ in steps ? LightTable.settle(a, steps: true) : a }; out.append(r)
        r = Rules(); r.name = "placed where asked, over other films"
        r.place = { m, id, s, at in
            guard m.place(id, size: s, at: at) else { return false }
            m.moveTo(id, at ?? .zero, keepOn: false); return true
        }
        out.append(r)
        r = Rules(); r.name = "the bottom film touched first"
        r.hit = { m, p in
            for it in m.pile where abs((p.x - it.x) * cos(it.rot) + (p.y - it.y) * sin(it.rot)) <= it.w / 2 + 0.5
                && abs(-(p.x - it.x) * sin(it.rot) + (p.y - it.y) * cos(it.rot)) <= it.h / 2 + 0.5 { return it.id }
            return nil
        }
        out.append(r)
        r = Rules(); r.name = "a turned film hit by its unturned box"
        r.hit = { m, p in
            for it in m.pile.reversed() where abs(p.x - it.x) <= it.w / 2 + 0.5 && abs(p.y - it.y) <= it.h / 2 + 0.5 { return it.id }
            return nil
        }
        out.append(r)
        r = Rules(); r.name = "a film edge sized by its gate"
        r.film = { g in CGSize(width: g.vertical ? g.gateAcross : g.gateAlong, height: g.vertical ? g.gateAlong : g.gateAcross) }
        out.append(r)
        r = Rules(); r.name = "a bare frame at its uncut size"; r.plain = { _, o, f in LightTableSizing.plain(display: o, original: o, filmFormatMM: f) }
        out.append(r)
        r = Rules(); r.name = "a pair's strip as its piece"; r.pair = { p, _, _ in p.pieceSizeMM }; out.append(r)
        r = Rules(); r.name = "the budget ignored"; r.plan = { needs, _ in LightTableSteps.plan(needs, budget: .max) }; out.append(r)
        r = Rules(); r.name = "a job asked though the kept develop is large enough"
        r.choose = { step, kept, more, full in kept != nil && more ? (full, !full) : LightTableSteps.choose(step: step, keptEdge: kept, hasMore: more, fullKept: full) }
        out.append(r)
        r = Rules(); r.name = "the kept develop drawn larger than it is, the render kept unread"
        r.choose = { step, kept, more, full in kept != nil ? (false, false) : LightTableSteps.choose(step: step, keptEdge: kept, hasMore: more, fullKept: full) }
        out.append(r)
        r = Rules(); r.name = "nothing asked for a frame cached nowhere"
        r.choose = { step, kept, more, full in let c = LightTableSteps.choose(step: step, keptEdge: kept, hasMore: more, fullKept: full); return (c.readsFull, false) }
        out.append(r)
        r = Rules(); r.name = "the films in view halved first"
        r.plan = { needs, budget in LightTableSteps.plan(needs.map { var n = $0; n.visible.toggle(); return n }, budget: budget) }
        out.append(r)
        r = Rules(); r.name = "the portrait turn keeps millimetres, not proportion"
        r.orient = { m, p in
            let pile = m.pile
            m.orient(portrait: p)
            for it in pile { m.moveTo(it.id, it.centre) }
        }
        out.append(r)
        r = Rules(); r.name = "a zoom about the middle"; r.zoomAt = { v, z, _, _ in v.setZoom(z) }; out.append(r)
        // The pinch as it was before 2026-10-17: anchored once, at the middle of the fingers then
        // down, its scale UIKit's (the first two fingers' distance), its middle that of the fingers
        // down now (UIPinchGestureRecognizer's `location(in:)`).
        r = Rules(); r.name = "the pinch anchored once, at its start (the old code)"
        r.track = { steps, v0 in
            var v = v0, out: [LightTableViewport] = []
            var anchor: (zoom: Double, world: CGPoint, d0: Double)?, scale = 1.0
            for step in steps {
                let p = step.map(\.at), m = LightTableTouchMath.middle(p)
                if anchor == nil { anchor = (v.zoom, v.toWorld(m), p.count >= 2 ? hypot(p[1].x - p[0].x, p[1].y - p[0].y) : 1) }
                if p.count >= 2, let a = anchor, a.d0 > 1 { scale = hypot(p[1].x - p[0].x, p[1].y - p[0].y) / a.d0 }
                if let a = anchor, step.count >= 2 || a.d0 > 1 { v.zoomAt(a.zoom * scale, world: a.world, screen: m) }
                out.append(v)
            }
            return out
        }
        out.append(r)
        r = Rules(); r.name = "the hold taken again, but stopped hard at 8x and the table's edges"
        r.track = { steps, v0 in
            var v = v0, out: [LightTableViewport] = []
            var hold: (zoom: Double, world: CGPoint, spread: Double, n: Int)?
            for step in steps {
                let p = step.map(\.at), m = LightTableTouchMath.middle(p), s = LightTableTouchMath.spread(p)
                if let h = hold, h.n == p.count {
                    v.zoomAt(p.count >= 2 && h.spread > 1 ? h.zoom * s / h.spread : h.zoom, world: h.world, screen: m)
                } else {
                    hold = (v.zoom, v.toWorld(m), s, p.count)
                }
                out.append(v)
            }
            return out
        }
        out.append(r)
        r = Rules(); r.name = "the lens flipped below the finger and clamped (the old code)"
        r.loupe = { _, f, view, R, rim, _ in
            let out = R + rim + 2
            var lx = f.x, ly = f.y
            ly = ly - R - 40 < out ? ly + R + 40 : ly - R - 40
            lx = LightTableModel.clamp(lx, out, view.width - out)
            ly = LightTableModel.clamp(ly, out, view.height - out)
            return CGPoint(x: lx, y: ly)
        }
        out.append(r)
        r = Rules(); r.name = "the lens above and clamped, never going round"
        r.loupe = { _, f, view, R, rim, _ in LightTableLoupePlace.centre(angle: LightTableLoupePlace.above, finger: f, view: view, radius: R, rim: rim) }
        out.append(r)
        r = Rules(); r.name = "Tidy Up leaving what does not fit in a pile at the middle"
        r.tidy = { m, ids in
            m.tidy(ids)
            for it in m.pile.dropFirst(30) { m.moveTo(it.id, .zero) }
        }
        out.append(r)
        r = Rules(); r.name = "a layout pass that clamps the view (the website's measureStage)"
        r.measure = { v, size in
            v.measure(size: size, inset: .init(top: 10, left: 10, bottom: 10, right: 10), half: LightTable.half(portrait: true))
            v.clampView()
        }
        out.append(r)
        r = Rules(); r.name = "Scatter with the same seed every time"; r.scatter = { m, _ in m.scatter(seed: 42) }; out.append(r)
        r = Rules(); r.name = "Random keeping each film's turn"
        r.random = { m, seed in
            let was = m.pile
            m.random(seed: seed)
            for it in was where it.rot != 0 { m.setRotation(it.id, it.rot) }
        }
        out.append(r)
        r = Rules(); r.name = "Random with the same seed every time"; r.random = { m, _ in m.random(seed: 7) }; out.append(r)
        r = Rules(); r.name = "Random laying every film at the middle, over each other"
        r.random = { m, seed in
            m.random(seed: seed)
            for it in m.pile { m.moveTo(it.id, .zero) }
        }
        out.append(r)
        r = Rules(); r.name = "A5 and A6 drawn at A4's size"; r.half = { _, p in LightTable.half(.a4, portrait: p) }; out.append(r)
        r = Rules(); r.name = "a smaller table takes off the films that no longer fit"
        r.relayout = { m, paper, p in
            m.relayout(paper: paper, portrait: p)
            if paper != .a4 { for it in m.pile.dropFirst(40) { m.takeOff(it.id) } }
        }
        out.append(r)
        r = Rules(); r.name = "a resized table leaves each film at its millimetres, off the light"
        r.relayout = { m, paper, p in
            let was = m.pile
            m.relayout(paper: paper, portrait: p)
            for it in was { m.moveTo(it.id, it.centre, keepOn: false) }
        }
        out.append(r)
        r = Rules(); r.name = "each film carried alone: over one another, and a group spread apart"
        r.relayout = { m, paper, p in
            let was = m.pile, before = LightTable.half(m.paper, portrait: m.portrait)
            m.relayout(paper: paper, portrait: p)
            for it in was { m.moveTo(it.id, LightTableModel.carried(it, from: before, to: m.half)) }
        }
        out.append(r)
        r = Rules(); r.name = "a tidied table turned is not tidied again"
        r.relayout = { m, paper, p in
            if let first = m.pile.first { m.moveTo(first.id, CGPoint(x: first.x + 1e-3, y: first.y)) }
            m.relayout(paper: paper, portrait: p)
        }
        out.append(r)
        r = Rules(); r.name = "a table kept before there were sizes opens as A6"
        r.load = { data in
            (try? JSONDecoder().decode(StoredTable.self, from: data)).map { k in
                k.model(paper: k.paper ?? .a6, portrait: k.portrait) { _ in CGSize(width: 36, height: 24) }
            }
        }
        out.append(r)
        r = Rules(); r.name = "the glide on an underdamped spring, overshooting"
        r.glideShare = { t in t >= TableGlide.duration ? 1 : 1 - exp(-8 * t) * cos(14 * t) }
        out.append(r)
        r = Rules(); r.name = "the glide turning a film the long way round"
        r.glidePose = { g, it, f in
            guard let p = g.films[it.id] else { return nil }
            return (TableGlide.Pose(x: p.x + (it.x - p.x) * f, y: p.y + (it.y - p.y) * f, angle: p.angle + (it.rot - p.angle) * f), 0)
        }
        out.append(r)
        r = Rules(); r.name = "Scatter off the light"
        r.scatter = { m, seed in
            m.scatter(seed: seed)
            if let it = m.pile.last { m.moveTo(it.id, CGPoint(x: m.half.width, y: 0), keepOn: false) }
        }
        out.append(r)
        r = Rules(); r.name = "Actual Size by the backing store's pixels, not the mode's points"
        r.macPointsPerMM = { _, mm in mm.width > 0 ? 2 * 2560 / Double(mm.width) : nil }
        out.append(r)
        r = Rules(); r.name = "Actual Size without the window's 0.77"
        r.scenePointsPerMM = { MacActualSize.macPointsPerMM(points: $0.points, millimetres: $0.millimetres) }
        out.append(r)
        r = Rules(); r.name = "Actual Size claimed for a display that does not know its size"
        r.macPointsPerMM = { p, mm in Double(p.width) / max(Double(mm.width), 300) }
        out.append(r)
        r = Rules(); r.name = "a turned display read across its millimetres"
        r.macPointsPerMM = { p, mm in mm.width >= 20 && mm.height >= 20 ? Double(p.width) / Double(mm.width) : nil }
        out.append(r)
        r = Rules(); r.name = "the rail in the pile's order"
        r.railOrder = { $0.order }
        out.append(r)
        r = Rules(); r.name = "the rail's tiles unturned"
        r.railTile = { it, box in
            let k = min(Double(box.width) / it.w, Double(box.height) / it.h)
            return (CGSize(width: it.w * k, height: it.h * k), 0, CGSize(width: it.w * k, height: it.h * k))
        }
        out.append(r)
        return out
    }
}

let deg = LightTable.deg
func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
typealias Touch = (id: Int, at: CGPoint)

// MARK: - checks

func settleChecks(_ c: inout Checker, _ r: Rules) {
    c.near(r.settle(88 * deg, false, LightTable.snap), 90 * deg, 1e-12, "88° settles square")
    c.near(r.settle(85 * deg, false, LightTable.snap), 85 * deg, 1e-12, "85° stays: 5° is past the 4° snap")
    c.near(r.settle(84 * deg, false, LightTable.snapTouch), 90 * deg, 1e-12, "84° under fingers settles square: within 7°")
    c.near(r.settle(-93 * deg, false, LightTable.snap), -90 * deg, 1e-12, "−93° settles to −90°")
    c.near(r.settle(361 * deg, false, LightTable.snap), 360 * deg, 1e-12, "a turn and a degree settles to a whole turn, kept as one")
    c.near(r.settle(22 * deg, true, LightTable.snap), 15 * deg, 1e-12, "steps: 22° → 15°")
    // Math.round(-2.5) is -2: a turn of -37.5° in steps goes to -30°, where Swift's rounding gives -45°.
    c.near(r.settle(-2.5 * LightTable.step, true, LightTable.snap), -2 * LightTable.step, 1e-9, "steps: −37.5° → −30° (JavaScript's rounding)")
    c.near(r.settle(-135 * deg, false, 50 * deg), -90 * deg, 1e-9, "−135° within a wide snap goes to −90° (Math.round(−1.5) = −1)")
    c.expect(LightTable.jsRound(-2.5) == -2 && LightTable.jsRound(2.5) == 3 && LightTable.jsRound(-2.6) == -3, "jsRound is Math.round")
    c.expect(LightTable.degrees(.pi) == "180°" && LightTable.degrees(-.pi) == "180°", "±π reads 180°: \(LightTable.degrees(.pi))")
    c.expect(LightTable.degrees(-90 * deg) == "-90°", "−90° reads -90°: \(LightTable.degrees(-90 * deg))")
    c.expect(LightTable.degrees(30.26 * deg) == "30.3°", "30.26° reads 30.3°: \(LightTable.degrees(30.26 * deg))")
    c.expect(LightTable.degrees(450 * deg) == "90°", "450° reads 90°: \(LightTable.degrees(450 * deg))")
    c.near(LightTable.unwind(1.9 * .pi), -0.1 * .pi, 1e-12, "a step across atan2's seam unwinds")
}

func pileChecks(_ c: inout Checker, _ r: Rules) {
    var m = LightTableModel()
    let a = id(1), b = id(2)
    _ = r.place(&m, a, CGSize(width: 36, height: 24), .zero)
    _ = r.place(&m, b, CGSize(width: 36, height: 24), .zero)
    c.expect(m.order == [a, b], "the pile is in the order put down")
    // laid over each other by hand: the top one is touched first
    m.moveTo(b, m.item(a)!.centre)
    c.expect(r.hit(m, m.item(a)!.centre) == b, "the film on top takes a touch first")
    m.toFront(a)
    c.expect(m.order == [b, a] && r.hit(m, m.item(a)!.centre) == a, "brought to the top, it takes the touch")
    m.takeOff(a)
    c.expect(r.hit(m, m.item(b)!.centre) == b && !m.order.contains(a) && m.item(a)?.on == false, "a film taken off waits, untouched")
    // a turned film: 36 × 24 standing upright after a quarter turn
    var t = LightTableModel()
    _ = t.place(a, size: CGSize(width: 36, height: 24), at: .zero)
    t.turnQuarter(a)
    let p = t.item(a)!
    c.near(p.rot, -.pi / 2, 1e-12, "turned right: −90°")
    c.expect(p.lying == CGSize(width: 24, height: 36) && p.quarter == 3, "it lies 24 × 36, in its third quarter")
    c.expect(r.hit(t, CGPoint(x: p.x, y: p.y + 16)) == a, "turned, it is touched 16 mm above its centre")
    c.expect(r.hit(t, CGPoint(x: p.x + 16, y: p.y)) == nil, "turned, it is not touched 16 mm to its side")
    // the cap
    var full = LightTableModel()
    var placed = 0
    for n in 0..<101 where full.place(id(100 + n), size: CGSize(width: 10, height: 8)) { placed += 1 }
    c.expect(LightTable.films == 99 && placed == 99 && full.isFull, "the table holds 99 films and refuses the 100th: \(placed)")
}

func placingChecks(_ c: inout Checker, _ r: Rules) {
    var m = LightTableModel()
    let half = m.half
    var ids: [UUID] = []
    for n in 0..<6 {
        let i = id(10 + n)
        _ = r.place(&m, i, CGSize(width: 36, height: 24), CGPoint(x: 0, y: 0))
        ids.append(i)
    }
    let pile = m.pile
    for it in pile {
        c.expect(it.x - it.w / 2 >= -half.width + LightTable.clear - 1e-9 && it.y + it.h / 2 <= half.height - LightTable.clear + 1e-9,
                 "placed clear of the scale's band: \(it.x), \(it.y)")
    }
    var apart = true
    for (i, a) in pile.enumerated() { for b in pile[(i + 1)...] {
        if abs(a.x - b.x) < a.w / 2 + b.w / 2 + LightTable.gap - 1e-9 && abs(a.y - b.y) < a.h / 2 + b.h / 2 + LightTable.gap - 1e-9 { apart = false }
    } }
    c.expect(apart, "six films put down at the same spot lie 3 mm apart")
    c.expect(pile.first.map { $0.x == 0 && $0.y == 0 } ?? false, "the first lies where it was asked: the spot is free")
    // the nearest free spot: a second 36 × 24 at the middle goes next to the first, the nearest way
    let second = pile[1]
    let d = hypot(second.x, second.y)
    c.expect(d <= 24 + LightTable.gap + 2.5 + 1e-9, "the second lies at the nearest free spot (\(d) mm away)")
    // kept on the light
    var k = LightTableModel()
    _ = k.place(id(30), size: CGSize(width: 36, height: 24))
    k.move(id(30), by: CGVector(dx: 500, dy: -500))
    let it = k.item(id(30))!
    c.near(it.x, half.width - 18, 1e-9, "moved past the right edge, it is kept on the light")
    c.near(it.y, -half.height + 12, 1e-9, "and past the bottom edge")
    // a film too large for the band lies clamped, not lost
    var big = LightTableModel()
    _ = big.place(id(31), size: CGSize(width: 290, height: 205))
    c.expect(big.item(id(31)).map { abs($0.x) < 10 && abs($0.y) < 10 } ?? false, "a film larger than the free area lies on the light")
}

func orientChecks(_ c: inout Checker, _ r: Rules) {
    var m = LightTableModel()
    _ = m.place(id(40), size: CGSize(width: 20, height: 14), at: CGPoint(x: 60, y: -40))
    let was = m.item(id(40))!
    r.orient(&m, true)
    let now = m.item(id(40))!
    c.expect(m.portrait && m.half == CGSize(width: 105, height: 148.5), "portrait: 210 × 297")
    // in proportion to the room its centre has: from the middle to where its edge meets the light's
    c.near(now.x, was.x / (148.5 - 10) * (105 - 10), 1e-9, "the portrait turn keeps x in proportion to its room")
    c.near(now.y, was.y / (105 - 7) * (148.5 - 7), 1e-9, "and y")
    r.orient(&m, false)
    let back = m.item(id(40))!
    c.near(back.x, was.x, 1e-9, "turned back, the film is where it was")
}

func viewChecks(_ c: inout Checker, _ r: Rules) {
    var v = LightTableViewport()
    v.measure(size: CGSize(width: 393, height: 852), inset: .init(top: 48, left: 10, bottom: 16, right: 10), half: LightTable.half(portrait: true))
    let box = v.box
    c.near(v.sFit, min((393 - 20) / box.width, (852 - 64) / box.height), 1e-12, "the table fitted in the room the controls leave")
    let p = CGPoint(x: 120, y: 400)
    let w = v.toWorld(p)
    c.near(v.toScreen(w).x, p.x, 1e-9, "screen → table → screen"); c.near(v.toScreen(w).y, p.y, 1e-9, "and y")
    let under = v.toWorld(CGPoint(x: 150, y: 420))
    r.zoomAt(&v, 3, under, CGPoint(x: 150, y: 420))
    let after = v.toScreen(under)
    c.near(after.x, 150, 1e-6, "a zoom keeps the table point under the finger")
    c.near(after.y, 420, 1e-6, "and its y")
    c.expect(v.zoom == 3 && v.isZoomed, "zoomed 3×")
    v.zoomAt(20, world: .zero, screen: .zero)
    c.expect(v.zoom == LightTable.zoomMax, "the zoom stops at 8×")
    // the clamp: panned far away, the table is still in the view
    v.pan(from: CGPoint(x: v.cx, y: v.cy), by: CGVector(dx: -100_000, dy: 0))
    let edge = v.toScreen(CGPoint(x: v.half.width + LightTable.rim + LightTable.desk, y: 0))
    c.near(edge.x, 393 - 10, 1e-6, "panned past it, the table's right edge stays at the view's")
    var still = v
    still.setZoom(1)
    c.near(still.cx, 0, 1e-6, "back at fit, the table is centred again")
    actualSizeChecks(&c, r)
}

/// The window's Actual Size (1:1): the view at the screen's points a millimetre, which may lie under
/// fit or past 8x, through the zoom's limits widened for it and narrowed again after.
func actualSizeChecks(_ c: inout Checker, _ r: Rules) {
    let perMM = 264 / 25.4 / 2
    c.near(perMM, 5.197, 0.001, "264 ppi at 2 pixels a point is 5.197 points a millimetre (design/ipad/lighttable.md)")
    // An A6 table on its side in a 13-inch window: fitted larger than life, so 1:1 is under fit.
    var v = LightTableViewport()
    v.measure(size: CGSize(width: 1376, height: 868), inset: .init(top: 10, left: 10, bottom: 10, right: 10),
              half: LightTable.half(.a6, portrait: false))
    let z = perMM / v.sFit
    c.expect(z < 1, "an A6 table fitted in a 13-inch window is larger than life")
    c.expect(v.zoomFloor == 1 && v.zoomCeiling == LightTable.zoomMax, "the limits are 1-8x until Actual Size asks")
    var clamped = v
    r.zoomAt(&clamped, z, .zero, clamped.middle)
    c.near(clamped.zoom, 1, 1e-12, "without Actual Size the zoom stops at fit")
    v.zoomFloor = min(1, z); v.zoomCeiling = max(LightTable.zoomMax, z)
    r.zoomAt(&v, z, .zero, v.middle)
    c.near(v.s, perMM, 1e-9, "at Actual Size the view is the screen's points a millimetre")
    let held = v.settled(about: v.middle)
    c.near(held.zoom, z, 1e-9, "Actual Size is at rest within its limits")
    var narrowed = v
    narrowed.zoomFloor = 1; narrowed.zoomCeiling = LightTable.zoomMax
    c.near(narrowed.settled(about: narrowed.middle).zoom, 1, 1e-9, "left, the limits narrow and the view settles at fit")
    // An A4 table in a small window: 1:1 is past 8x.
    var w = LightTableViewport()
    w.measure(size: CGSize(width: 200, height: 160), inset: .init(top: 10, left: 10, bottom: 10, right: 10),
              half: LightTable.half(.a4, portrait: true))
    let big = perMM / w.sFit
    c.expect(big > LightTable.zoomMax, "an A4 table in a 200 pt window is under an eighth of life size")
    w.zoomFloor = min(1, big); w.zoomCeiling = max(LightTable.zoomMax, big)
    r.zoomAt(&w, big, .zero, w.middle)
    c.near(w.s, perMM, 1e-9, "and Actual Size still reaches the real millimetre")
}

func shownChecks(_ c: inout Checker, _ r: Rules) {
    let it = LightTableItem(id: id(50), size: CGSize(width: 36, height: 24), x: 40, y: 10, rot: .pi / 2, on: true)
    var s = LightTableShown.placed(LightTableItem(id: id(50), size: it.size, x: 0, y: 0, rot: 0, on: true), kept: false)
    s.ready = true
    var steps = 0
    while s.step(towards: it, dt: 1.0 / 60, reduce: false) && steps < 600 { steps += 1 }
    c.expect(s.px == it.x && s.py == it.y && s.angle == it.rot && s.presence == 1 && s.lift == 0,
             "a film eases to its place and lands exactly (\(steps) frames)")
    c.expect(steps > 10 && steps < 120, "in under two seconds, not at once: \(steps) frames")
    var t = LightTableShown.placed(LightTableItem(id: id(50), size: it.size), kept: false)
    t.ready = true
    _ = t.step(towards: it, dt: 1.0 / 60, reduce: true)
    c.expect(t.px == it.x && t.angle == it.rot && t.presence == 1, "with Reduce Motion it lands at once")
    var turn = LightTableShown.atRest(LightTableItem(id: id(50), size: it.size, rot: 350 * deg), ready: true)
    _ = turn.step(towards: LightTableItem(id: id(50), size: it.size, rot: 10 * deg), dt: 1.0 / 60, reduce: false)
    c.expect(turn.angle > 350 * deg, "from 350° to 10° it turns the short way, through 360°: \(turn.angle / deg)°")
    var pressed = LightTableShown.atRest(it, ready: true)
    pressed.pressed = true
    for _ in 0..<120 { _ = pressed.step(towards: it, dt: 1.0 / 60, reduce: false) }
    c.near(pressed.drawnSize.width, 36 * 1.045, 1e-9, "a pressed film rises: 4.5 % larger")
    c.near(pressed.shadow.blur, LightTable.rest.blur + (LightTable.lift.blur - LightTable.rest.blur) * 0.6, 1e-9, "its shadow lifted to 0.6")
}

func sizeChecks(_ c: inout Checker, _ r: Rules) {
    // Every format, both views, both ways up: the film's width across a strip, the gate and its carrier filed.
    for format in FilmEdgeFormat.allCases {
        for view in FilmEdgeView.allCases {
            for turned in [false, true] {
                let along = format.alongMM, across = format.acrossMM, k = 100.0
                let frame = turned ? PixelSize(width: Int(across * k), height: Int(along * k)) : PixelSize(width: Int(along * k), height: Int(across * k))
                let req = FilmEdgeRequest(format: format, mode: view, cameraSeed: 7, frameSeed: 3, turn: turned ? 1 : 0, frame: frame)
                guard let g = FilmLayout.layout(req) else { c.expect(false, "\(format.rawValue) \(view.rawValue) lays out"); continue }
                let s = r.film(g)
                let down = g.vertical != (g.extraTurns % 2 == 1)   // the film runs down the canvas as shown
                let acrossMM = down ? s.width : s.height, alongMM = down ? s.height : s.width
                let name = "\(format.rawValue) \(view.rawValue)\(turned ? " turned" : "")"
                if view == .strip {
                    c.near(acrossMM, format.filmWidthMM, format.isPerforated ? 0.02 : 0.17, "\(name): the film's width across")
                    let margin = format.isPerforated ? (format.alongMM < 20 ? (0.40, 0.50) : (0.75, 0.95)) : (1.05, 2.35)
                    c.expect(alongMM >= format.alongMM + 2 * margin.0 - 0.02 && alongMM <= format.alongMM + 2 * margin.1 + 0.02,
                             "\(name): the frame and a sliver of the next along (\(alongMM) mm)")
                } else {
                    c.near(acrossMM, format.acrossMM + 2.2, 0.02, "\(name): the gate and 1.1 mm of carrier across")
                    c.expect(alongMM >= format.alongMM + 1.6 - 0.02 && alongMM <= format.alongMM + 2.0 + 0.02, "\(name): and along (\(alongMM) mm)")
                }
                c.expect(abs(s.width - g.canvasMM.width) < 1e-9 && s.height == g.canvasMM.height || r.name != "as written",
                         "\(name): the size is the layout's canvas")
            }
        }
    }
    // A bare frame: its Film Format's millimetres a pixel, under its crop.
    let z7 = PixelSize(width: 6000, height: 4000)
    let bare = r.plain(z7, z7, 36)
    c.expect(bare == CGSize(width: 36, height: 24), "a bare 135 frame is 36 × 24: \(bare)")
    let cropped = r.plain(PixelSize(width: 3000, height: 2000), z7, 36)
    c.expect(cropped == CGSize(width: 18, height: 12), "cropped to half, it is half as large: the film keeps its size under the cut: \(cropped)")
    let upright = r.plain(PixelSize(width: 4000, height: 6000), PixelSize(width: 4000, height: 6000), 36)
    c.expect(upright == CGSize(width: 24, height: 36), "an upright frame is 24 × 36: \(upright)")
    c.expect(r.plain(PixelSize(width: 6000, height: 4000), z7, 84) == CGSize(width: 84, height: 56), "6 × 9 by its Film Format: 84 × 56")
    // A pair.
    var pair = HalfFramePair()
    c.expect(r.pair(pair, false, .strip) == CGSize(width: 37, height: 24), "a pair's piece: 37 × 24")
    pair.onStrip = true
    c.expect(r.pair(pair, true, .strip) == CGSize(width: 38, height: 35), "a pair on its strip: 38 × 35: \(r.pair(pair, true, .strip))")
    let filed = r.pair(pair, true, .filed)
    c.expect(abs(filed.width - 39) < 1e-9 && abs(filed.height - 26.2) < 1e-9, "a pair filed: 39 × 26.2: \(filed)")
    pair.turned = true
    c.expect(r.pair(pair, true, .strip) == CGSize(width: 35, height: 38), "a pair turned: 35 × 38")
}

func budgetChecks(_ c: inout Checker, _ r: Rules) {
    // The ceiling (2026-10-24): the largest film any format makes — a 6 × 17 strip, 168 mm of gate and
    // 2.35 mm of strip each end — pixel for pixel on A6's 105 mm at the largest export's 5,000 px.
    let sixBySeventeen = 168.0 + 2 * 2.35
    let ceiling = Int((sixBySeventeen * 5000 / 105).rounded(.up))
    c.expect(ceiling == 8224 && LightTableSizing.sourceCeiling == ceiling,
             "the ceiling is a 6 × 17 strip on A6 at 5,000 px: \(LightTableSizing.sourceCeiling) (172.7 mm × 5,000 / 105 = \(ceiling))")
    c.expect(abs(LightTableSizing.largestFilmMM - sixBySeventeen) < 1e-9, "the largest film any format makes is the 6 × 17 strip: \(LightTableSizing.largestFilmMM) mm")
    c.expect(LightTableSteps.steps == [256, 512, 1024, 2048, 4096, ceiling], "steps 256…2,048, 4,096, the ceiling: \(LightTableSteps.steps)")
    c.expect(LightTableSteps.step(for: 1) == 256 && LightTableSteps.step(for: 257) == 512 && LightTableSteps.step(for: 3000) == 4096
             && LightTableSteps.step(for: 5000) == ceiling && LightTableSteps.step(for: 99999) == ceiling,
             "steps rounded up, never past the ceiling")
    // Where a film is read from (the owner, 2026-10-24: a render "only … where we have the cache nowhere").
    let read = r.choose
    c.expect(read(1024, 2400, true, false) == (false, false), "a kept develop as large as the step: read, nothing asked")
    c.expect(read(4096, 2400, true, true) == (true, false), "shown past its kept develop, a render kept: the render, nothing asked")
    c.expect(read(4096, 2400, true, false) == (false, true), "shown past its kept develop, no render kept: one asked, the develop shown meanwhile")
    c.expect(read(256, nil, true, true) == (true, false), "nothing developed, a render kept: the render, at any step")
    c.expect(read(256, nil, true, false) == (false, true), "cached nowhere: one asked, at any step")
    c.expect(read(8224, 2400, false, false) == (false, false), "no more to it than its kept develop: that, whatever the step")
    c.expect(read(256, nil, false, false) == (false, true), "no more to it than its preview and nothing kept: its develop asked")
    c.expect(LightTableSteps.bytes(width: 4, height: 2, mipmapped: true) == (8 + 2 + 1) * 4, "a 4 × 2 texture with mips: 44 bytes")
    c.expect(LightTableSteps.bytes(width: 2048, height: 1365, mipmapped: false) == 2048 * 1365 * 4, "without mips: w × h × 4")
    let a = LightTableSteps.Need(id: id(60), pixels: 2000, visible: true, aspect: 1.5)
    let b = LightTableSteps.Need(id: id(61), pixels: 2000, visible: false, aspect: 1.5)
    let full = r.plan([a, b], 1 << 40)
    c.expect(full[a.id] == 2048 && full[b.id] == 2048, "under a large budget each has the step it needs")
    let one = LightTableSteps.bytes(edge: 2048, aspect: 1.5)
    let tight = r.plan([a, b], one + LightTableSteps.bytes(edge: 1024, aspect: 1.5))
    c.expect(tight[a.id] == 2048 && tight[b.id] == 1024, "over budget, the film out of view is halved first: \(tight[a.id] ?? 0), \(tight[b.id] ?? 0)")
    let total = tight.reduce(0) { $0 + LightTableSteps.bytes(edge: $1.value, aspect: 1.5) }
    c.expect(total <= one + LightTableSteps.bytes(edge: 1024, aspect: 1.5), "and the total is within the budget")
    let floor = r.plan([a, b], 1)
    c.expect(floor[a.id] == 256 && floor[b.id] == 256, "never under the smallest step")
}

// MARK: fingers

/// A view at 3× in the middle of a portrait table, the page's room: the place a pinch is tried.
func zoomedView() -> LightTableViewport {
    var v = LightTableViewport()
    v.measure(size: CGSize(width: 393, height: 580), inset: .init(top: 10, left: 10, bottom: 10, right: 10), half: LightTable.half(portrait: true))
    v.zoomAt(3, world: CGPoint(x: 10, y: -20), screen: v.middle)
    return v
}

/// The largest slip, points, of the table under a finger that stayed down from one step to the
/// next: where the table point that was under it lands, against where the finger is now.
func slips(_ steps: [[Touch]], _ views: [LightTableViewport], _ v0: LightTableViewport) -> (max: Double, at: Int) {
    var worst = (max: 0.0, at: -1)
    var before = v0, prev: [Int: CGPoint] = [:]
    for (k, step) in steps.enumerated() {
        let v = views[k]
        for t in step {
            guard let q = prev[t.id] else { continue }
            let w = v.toScreen(before.toWorld(q))
            let d = hypot(w.x - t.at.x, w.y - t.at.y)
            if d > worst.max { worst = (d, k) }
        }
        prev = Dictionary(step.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
        before = v
    }
    return worst
}

/// Fingers moving a point a step: a pinch, a finger lifting, a pan, a finger landing, a pinch, a
/// third finger, a lift.
func fingerSequence() -> [[Touch]] {
    var steps: [[Touch]] = []
    var a = CGPoint(x: 150, y: 300), b = CGPoint(x: 250, y: 300)
    for _ in 0..<40 { a.x -= 1; b.x += 1; a.y += 0.5; b.y += 0.5; steps.append([(1, a), (2, b)]) }   // spread
    a.x += 1; steps.append([(1, a)])                                                                // the second finger lifts
    for _ in 0..<30 { a.x += 1; a.y += 0.5; steps.append([(1, a)]) }                                // a pan
    var d = CGPoint(x: 260, y: 380); steps.append([(1, a), (3, d)])                                 // a finger lands
    for _ in 0..<30 { a.x += 1; d.x -= 1; a.y += 0.5; d.y -= 0.5; steps.append([(1, a), (3, d)]) }  // a pinch in
    var e = CGPoint(x: 200, y: 450); steps.append([(1, a), (3, d), (4, e)])                         // a third finger
    for _ in 0..<20 { a.x += 0.5; d.x += 0.5; e.x += 0.5; a.y -= 0.5; d.y -= 0.5; e.y -= 0.5; steps.append([(1, a), (3, d), (4, e)]) }
    steps.append([(3, d), (4, e)])                                                                  // the first lifts
    for _ in 0..<10 { d.x += 1; e.x -= 1; steps.append([(3, d), (4, e)]) }
    return steps
}

func fingerChecks(_ c: inout Checker, _ r: Rules) {
    let v0 = zoomedView()
    let steps = fingerSequence()
    let views = r.track(steps, v0)
    let worst = slips(steps, views, v0)
    c.expect(worst.max <= 2.5, "pinch, lift, pan, land, pinch, a third finger, a lift: the table under a finger never slips more than 2.5 pt in a step (\(LightTableTrace.round(worst.max)) pt at step \(worst.at))")
    c.expect(views.contains { $0.zoom > v0.zoom * 1.4 } && abs(views.last!.zoom - v0.zoom) > 0.05, "and the fingers did zoom it")

    // Past 8×: two fingers spreading on, then back the same way. Every step moves the zoom (the
    // fingers are never ignored), it never gives more than the band, and it comes back.
    var v = zoomedView()
    v.zoomAt(7, world: .zero, screen: v.middle)
    var out: [[Touch]] = []
    var a = CGPoint(x: 160, y: 290), b = CGPoint(x: 230, y: 290)
    for _ in 0..<60 { a.x -= 1; b.x += 1; out.append([(1, a), (2, b)]) }
    for _ in 0..<59 { a.x += 1; b.x -= 1; out.append([(1, a), (2, b)]) }
    let zooms = r.track(out, v).map(\.zoom)
    let still = zip(zooms.dropFirst(2), zooms.dropFirst(1)).filter { abs(log($0) - log($1)) < 1e-6 }.count
    c.expect(still == 0, "spread past 8x and back: every step moves the zoom, none is ignored (\(still) steps did not)")
    c.expect(zooms.max()! > LightTable.zoomMax && zooms.max()! <= LightTable.zoomMax * exp(LightTableViewport.zoomGive) + 1e-9,
             "past 8x it gives, never more than the band: \(LightTableTrace.round(zooms.max()!, 100))x")
    c.near(zooms.last!, zooms.first!, 1e-6, "and comes back the way it went")

    // A pan past the table's edge, one finger: the view moves on every step, gives less and less,
    // and settles back inside when the finger lets go.
    var p = zoomedView()
    p.zoomAt(2, world: .zero, screen: p.middle)
    var f = CGPoint(x: 200, y: 300), pan: [[Touch]] = [[(1, f)]]
    for _ in 0..<400 { f.x += 1.5; pan.append([(1, f)]) }
    let panned = r.track(pan, p)
    let stuck = zip(panned.dropFirst(2), panned.dropFirst(1)).filter { abs($0.cx - $1.cx) * $0.s < 1e-6 }.count
    c.expect(stuck == 0, "a pan past the table's edge: the view follows on every step, giving (\(stuck) steps did not)")
    let last = panned.last!
    c.expect(!last.isSettled && last.settled(about: f).isSettled, "past the edge it is not at rest; let go, it settles inside")
    // A layout pass in the middle of it (SwiftUI lays the page out again as the status line
    // changes): the view the finger holds past the edge stays where it is.
    var laid = last
    r.measure(&laid, laid.size)
    c.expect(abs(laid.cx - last.cx) * last.s < 0.01 && abs(laid.cy - last.cy) * last.s < 0.01,
             "a layout pass while a finger holds the view past the edge leaves it there (moved \(LightTableTrace.round(abs(laid.cx - last.cx) * last.s)) pt)")
    // `held` is `hold`'s inverse: taking hold of a view that gives does not move it.
    var g = last
    let h = g.held(at: f)
    g.hold(zoom: h.zoom, world: h.world, screen: f)
    c.near(g.cx, last.cx, 1e-9, "a hold taken on a view past its edge leaves it where it is")
    c.near(g.zoom, last.zoom, 1e-12, "and its zoom")
}

func loupeChecks(_ c: inout Checker, _ r: Rules) {
    let view = CGSize(width: 393, height: 580), R = 72.0, rim = 5.0, out = R + rim + 2, dt = 1.0 / 120
    // The finger: from the middle up to the top, along the top, down the left edge, along the
    // bottom, up the right edge, then across from corner to corner; a point a step.
    var path: [CGPoint] = []
    func line(_ a: CGPoint, _ b: CGPoint) {
        let n = Int(max(abs(b.x - a.x), abs(b.y - a.y)).rounded(.up))
        for i in 0...max(n, 1) { path.append(CGPoint(x: a.x + (b.x - a.x) * Double(i) / Double(max(n, 1)), y: a.y + (b.y - a.y) * Double(i) / Double(max(n, 1)))) }
    }
    let e = 6.0
    line(CGPoint(x: 196, y: 400), CGPoint(x: 196, y: e))
    line(CGPoint(x: 196, y: e), CGPoint(x: e, y: e))
    line(CGPoint(x: e, y: e), CGPoint(x: e, y: 580 - e))
    line(CGPoint(x: e, y: 580 - e), CGPoint(x: 393 - e, y: 580 - e))
    line(CGPoint(x: 393 - e, y: 580 - e), CGPoint(x: 393 - e, y: e))
    line(CGPoint(x: 393 - e, y: e), CGPoint(x: e, y: e))
    line(CGPoint(x: e, y: e), CGPoint(x: 393 - e, y: 580 - e))
    line(CGPoint(x: 393 - e, y: 580 - e), CGPoint(x: 196, y: 40))
    var place = LightTableLoupePlace()
    var prev: CGPoint?, cut = 0, over = 0, jump = 0.0
    for f in path {
        let at = r.loupe(&place, f, view, R, rim, dt)
        if at.x < out - 1e-6 || at.x > view.width - out + 1e-6 || at.y < out - 1e-6 || at.y > view.height - out + 1e-6 { cut += 1 }
        if hypot(at.x - f.x, at.y - f.y) < R { over += 1 }
        if let p = prev { jump = max(jump, hypot(at.x - p.x, at.y - p.y)) }
        prev = at
    }
    c.expect(cut == 0, "the lens along every edge and into every corner is never cut by the view's edge (\(cut) steps were)")
    c.expect(over == 0, "and never lies over the finger (\(over) steps did)")
    c.expect(jump <= 12, "and never jumps: at most 12 pt in a 1/120 s step while the finger moves 1 pt (\(LightTableTrace.round(jump)) pt)")
    // At rest: at each corner and edge, the lens clear of the finger's own room.
    var unclear: [String] = []
    for f in [CGPoint(x: e, y: e), CGPoint(x: 393 - e, y: e), CGPoint(x: e, y: 580 - e), CGPoint(x: 393 - e, y: 580 - e),
              CGPoint(x: 196, y: e), CGPoint(x: e, y: 290), CGPoint(x: 393 - e, y: 290), CGPoint(x: 196, y: 580 - e), CGPoint(x: 196, y: 290)] {
        var at = CGPoint.zero
        for _ in 0..<240 { at = r.loupe(&place, f, view, R, rim, dt) }
        if hypot(at.x - f.x, at.y - f.y) < R + LightTableLoupePlace.clearance - 1e-6 { unclear.append("(\(f.x), \(f.y))") }
    }
    c.expect(unclear.isEmpty, "at rest at every corner and edge the lens is clear of the finger: \(unclear)")
    // Away from the edges it is straight above, 40 pt clear, as the website draws it.
    var mid = LightTableLoupePlace()
    let m = r.loupe(&mid, CGPoint(x: 196, y: 400), view, R, rim, dt)
    c.near(m.y, 400 - R - 40, 1e-6, "in the middle the lens is straight above the finger")
}

/// 99 films of every size the table knows, put down one by one where the table places them.
func ninetyNine(_ r: Rules = Rules()) -> (LightTableModel, [UUID]) {
    let sizes = [CGSize(width: 36, height: 24), CGSize(width: 24, height: 36), CGSize(width: 71.6, height: 58.2), CGSize(width: 67, height: 35.5),
                 CGSize(width: 38, height: 35), CGSize(width: 56, height: 56), CGSize(width: 37, height: 24)]
    var m = LightTableModel()
    m.orient(portrait: true)
    var ids: [UUID] = []
    for n in 0..<99 {
        let i = id(500 + n)
        _ = r.place(&m, i, sizes[n % sizes.count], .zero)
        if n % 5 == 0 { m.setRotation(i, Double(n) * deg) }
        ids.append(i)
    }
    return (m, ids)
}

func onLight(_ m: LightTableModel) -> Bool {
    m.pile.allSatisfy { it in
        let e = it.extent
        return abs(it.x) + e.width / 2 <= m.half.width + 1e-6 && abs(it.y) + e.height / 2 <= m.half.height + 1e-6
    }
}

/// The least share of a film that shows: points over each film's box, not under a film above it.
func leastSeen(_ m: LightTableModel) -> Double {
    var least = 1.0
    for it in m.pile {
        let e = it.extent
        var seen = 0, all = 0
        for i in 0..<12 { for j in 0..<8 {
            let p = CGPoint(x: it.x - e.width / 2 + e.width * (Double(i) + 0.5) / 12, y: it.y - e.height / 2 + e.height * (Double(j) + 0.5) / 8)
            all += 1
            if m.hit(p) == it.id { seen += 1 }
        } }
        least = min(least, Double(seen) / Double(all))
    }
    return least
}

func arrangeChecks(_ c: inout Checker, _ r: Rules) {
    // A few films: rows with room to spare, none over another, as before.
    var few = LightTableModel()
    few.orient(portrait: true)
    let some = (0..<8).map { id(400 + $0) }
    for (n, i) in some.enumerated() { _ = few.place(i, size: n % 2 == 0 ? CGSize(width: 36, height: 24) : CGSize(width: 56, height: 56), at: .zero) }
    r.tidy(&few, some)
    let pile = few.pile
    var touching = 0
    for (k, a) in pile.enumerated() { for b in pile[(k + 1)...] where LightTableModel.overlap(a, b) > 0 { touching += 1 } }
    c.expect(touching == 0 && pile.count == 8, "Tidy Up with room: eight films in rows, none over another (\(touching) overlap)")

    // 99 films of every size: none left out, all on the light, every one partly seen.
    var (m, ids) = ninetyNine(r)
    c.expect(m.order.count == 99, "99 films of every size go on the table: \(m.order.count)")
    let places = Set(m.pile.map { "\(LightTable.jsRound($0.x * 10)),\(LightTable.jsRound($0.y * 10))" })
    c.expect(places.count == 99, "put down one by one past the free spots, no two land on the same place (\(places.count) places: \(Dictionary(grouping: m.pile, by: { "\(LightTable.jsRound($0.x * 10)),\(LightTable.jsRound($0.y * 10))" }).filter { $0.value.count > 1 }.map { "\($0.key) \($0.value.map { "\($0.w)x\($0.h)" })" }))")
    r.tidy(&m, ids.reversed())
    c.expect(m.order.count == 99 && Set(m.order) == Set(ids), "Tidy Up with 99 leaves none out")
    c.expect(onLight(m), "Tidy Up with 99: every film on the light")
    c.expect(m.pile.allSatisfy { abs($0.rot - LightTable.jsRound($0.rot / LightTable.quarter) * LightTable.quarter) < 1e-9 }, "and square")
    let seen = leastSeen(m)
    c.expect(seen >= 0.1, "Tidy Up with 99: every film shows, overlapping evenly (the least seen shows \(Int(seen * 100)) %)")
    c.expect(m.order == Array(ids.reversed()), "in the order given, the last on top")

    // Scatter: a new table for a new seed, the same for the same; all on the light, a little turned.
    let (start, _) = ninetyNine()
    var a = start, b = start, a2 = start
    r.scatter(&a, 1)
    r.scatter(&b, 2)
    r.scatter(&a2, 1)
    c.expect(a.order.count == 99 && Set(a.order) == Set(start.order), "Scatter with 99 leaves none out")
    c.expect(onLight(a) && onLight(b), "Scatter: every film on the light")
    let moved = zip(a.pile.sorted { $0.id.uuidString < $1.id.uuidString }, b.pile.sorted { $0.id.uuidString < $1.id.uuidString })
        .filter { hypot($0.x - $1.x, $0.y - $1.y) > 1 }.count
    c.expect(moved > 90, "Scatter twice, two seeds: two different tables (\(moved) of 99 films elsewhere)")
    c.expect(a == a2, "the same seed, the same table")
    c.expect(a.pile.allSatisfy { abs($0.rot - LightTable.jsRound($0.rot / LightTable.quarter) * LightTable.quarter) <= LightTableModel.scatterTurn + 1e-9 },
             "each a little turned about its quarter, ±9° at most")
}

@MainActor
func keptChecks(_ c: inout Checker, _ r: Rules) {
    var m = LightTableModel()
    _ = m.place(id(70), size: CGSize(width: 36, height: 24), at: CGPoint(x: -50, y: 20))
    _ = m.place(id(71), size: CGSize(width: 24, height: 36), at: CGPoint(x: 50, y: -20))
    _ = m.place(id(72), size: CGSize(width: 36, height: 24))
    m.setRotation(id(71), 30 * deg)
    m.toFront(id(70))
    m.takeOff(id(72))
    let file = ImportService.root.appendingPathComponent("lighttable.json")
    try? FileManager.default.removeItem(at: file)
    let store = LightTableStore(url: file)
    store.saveNow(m)
    guard let kept = store.load() else { c.expect(false, "what is kept is read back"); return }
    let sizes: [UUID: CGSize] = [id(70): CGSize(width: 36, height: 24), id(71): CGSize(width: 24, height: 36), id(72): CGSize(width: 36, height: 24)]
    let again = kept.model(portrait: false) { sizes[$0] }
    c.expect(again.order == m.order, "the pile comes back in its order: \(again.order.count)")
    c.expect(zip(again.pile, m.pile).allSatisfy { $0.x == $1.x && $0.y == $1.y && $0.rot == $1.rot }, "each film where it lay, at its angle")
    c.expect(again.item(id(72))?.on == false, "a film taken off stays off")
    let without = kept.model(portrait: false) { $0 == id(71) ? nil : sizes[$0] }
    c.expect(without.item(id(71)) == nil && without.order == [id(70)], "a frame the library let go of is left out")
    let turned = kept.model(portrait: true) { sizes[$0] }
    c.near(turned.item(id(70))!.x, m.item(id(70))!.x / (148.5 - 18) * (105 - 18), 1e-9, "kept in landscape, opened in portrait: its place in proportion")
    let bigger = kept.model(portrait: false) { $0 == id(70) ? CGSize(width: 84, height: 56) : sizes[$0] }
    c.expect(bigger.item(id(70))?.size == CGSize(width: 84, height: 56), "the size is the library's, read again, never the kept one")
}

// MARK: the table's sizes and its way up

/// Films put down where the table places them, from the middle.
func laid(_ sizes: [CGSize], paper: LightTablePaper = .a4, portrait: Bool = true, from n0: Int = 800) -> LightTableModel {
    var m = LightTableModel()
    m.relayout(paper: paper, portrait: portrait)
    for (n, s) in sizes.enumerated() { _ = m.place(id(n0 + n), size: s, at: .zero) }
    return m
}

func clearPairs(_ m: LightTableModel) -> Set<String> {
    var out = Set<String>()
    let pile = m.pile
    for (i, a) in pile.enumerated() { for b in pile[(i + 1)...] where LightTableModel.overlap(a, b) <= 1e-6 { out.insert("\(a.id)|\(b.id)") } }
    return out
}

func tableChecks(_ c: inout Checker, _ r: Rules) {
    // the three sizes, either way up: ISO 216
    c.expect(r.half(.a4, true) == CGSize(width: 105, height: 148.5) && r.half(.a4, false) == CGSize(width: 148.5, height: 105),
             "A4: 210 × 297 portrait, 297 × 210 landscape")
    c.expect(r.half(.a5, true) == CGSize(width: 74, height: 105) && r.half(.a5, false) == CGSize(width: 105, height: 74),
             "A5: 148 × 210, either way up: \(r.half(.a5, true))")
    c.expect(r.half(.a6, true) == CGSize(width: 52.5, height: 74) && r.half(.a6, false) == CGSize(width: 74, height: 52.5),
             "A6: 105 × 148, either way up: \(r.half(.a6, true))")
    var sized = LightTableModel()
    r.relayout(&sized, .a6, false)
    c.expect(sized.paper == .a6 && !sized.portrait && sized.half == CGSize(width: 74, height: 52.5), "the table at A6, landscape, is A6 landscape")

    // a sparse table, with room: turned, every film clear of every film it was clear of; turned
    // back, every film where it was
    let three = [CGSize(width: 36, height: 24), CGSize(width: 56, height: 56), CGSize(width: 24, height: 36)]
    var sparse = laid(three)
    for (k, p) in [CGPoint(x: -40, y: 60), CGPoint(x: 30, y: 0), CGPoint(x: -20, y: -60)].enumerated() { sparse.moveTo(id(800 + k), p) }
    let start = sparse
    r.relayout(&sparse, .a4, false)
    c.expect(sparse.order == start.order && sparse.pile.count == 3, "turned, the pile keeps its order")
    c.expect(clearPairs(start).isSubset(of: clearPairs(sparse)), "turned, no film lies over one it was clear of")
    var kept = true
    for (i, a) in start.pile.enumerated() { for (j, b) in start.pile.enumerated() where j > i {
        let a1 = sparse.pile[i], b1 = sparse.pile[j]
        if (a.x < b.x) != (a1.x < b1.x) || (a.y < b.y) != (a1.y < b1.y) { kept = false }
    } }
    c.expect(kept, "turned, the films keep their order along each axis: what was left and above still is")
    r.relayout(&sparse, .a4, true)
    c.expect(zip(start.pile, sparse.pile).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 && $0.rot == $1.rot },
             "turned and turned back, every film is where it was")

    // a group in the middle that fits the smaller table keeps its shape, millimetre for millimetre,
    // there and back: it is not spread to the corners of the larger one
    var group = laid([CGSize(width: 36, height: 24), CGSize(width: 36, height: 24), CGSize(width: 36, height: 24)])
    for (k, p) in [CGPoint(x: -20, y: 30), CGPoint(x: 20, y: 30), CGPoint(x: 0, y: 2)].enumerated() { group.moveTo(id(800 + k), p) }
    func gaps(_ m: LightTableModel) -> [Double] {
        let p = m.pile
        return [hypot(p[0].x - p[1].x, p[0].y - p[1].y), hypot(p[1].x - p[2].x, p[1].y - p[2].y), hypot(p[0].x - p[2].x, p[0].y - p[2].y)]
    }
    let g0 = gaps(group)
    r.relayout(&group, .a6, true)
    c.expect(zip(g0, gaps(group)).allSatisfy { abs($0 - $1) < 1e-9 }, "a group that fits A6 keeps its shape there: \(gaps(group)) against \(g0)")
    r.relayout(&group, .a4, true)
    c.expect(zip(g0, gaps(group)).allSatisfy { abs($0 - $1) < 1e-9 }, "and back on A4 it is not spread out: \(gaps(group))")

    // the films a person put down close together near the middle: turned to landscape the table
    // is shorter, so carried in proportion some would lie over each other; none does
    var close = laid((0..<8).map { $0 % 2 == 0 ? CGSize(width: 36, height: 24) : CGSize(width: 24, height: 36) })
    let wasClear = clearPairs(close)
    r.relayout(&close, .a4, false)
    c.expect(close.pile.count == 8 && wasClear.isSubset(of: clearPairs(close)),
             "eight films put down close together, turned: none over a film it was clear of (\(wasClear.subtracting(clearPairs(close)).count) are)")
    c.expect(onLight(close), "and every one on the light")

    // films that lay over each other on purpose still do
    var stack = laid([CGSize(width: 36, height: 24), CGSize(width: 36, height: 24)])
    stack.moveTo(id(801), CGPoint(x: stack.item(id(800))!.x + 10, y: stack.item(id(800))!.y + 5))
    r.relayout(&stack, .a5, false)
    c.expect(LightTableModel.overlap(stack.item(id(800))!, stack.item(id(801))!) > 0, "two films laid over each other stay over each other")

    // 99 films of every size onto the smallest table: none taken off or left out, all on the light
    let (big, ids) = ninetyNine()
    var small = big
    r.relayout(&small, .a6, true)
    c.expect(small.order.count == 99 && Set(small.order) == Set(ids) && small.order == big.order,
             "99 films onto A6: all still on the table, in their pile (\(small.order.count))")
    c.expect(small.items.allSatisfy(\.on), "none taken off")
    c.expect(onLight(small) || small.pile.contains { $0.extent.width > 2 * small.half.width || $0.extent.height > 2 * small.half.height },
             "every one on the light")
    var smallTurned = small
    r.relayout(&smallTurned, .a6, false)
    c.expect(smallTurned.order.count == 99 && onLight(smallTurned), "turned on A6 too: 99 on the light")
    var back = small
    r.relayout(&back, .a4, true)
    c.expect(back.order.count == 99 && onLight(back), "and back onto A4: 99 on the light")

    // a tidied table is tidied again for its new shape, in the same order
    var tidy = laid((0..<8).map { $0 % 2 == 0 ? CGSize(width: 36, height: 24) : CGSize(width: 56, height: 56) })
    let order = (0..<8).map { id(800 + $0) }
    tidy.tidy(order)
    var fresh = tidy
    r.relayout(&tidy, .a5, false)
    fresh.moveTo(id(800), CGPoint(x: fresh.item(id(800))!.x + 1e-3, y: fresh.item(id(800))!.y))   // forget it was tidied
    fresh.relayout(paper: .a5, portrait: false)
    fresh.tidy(order)
    c.expect(zip(tidy.pile, fresh.pile).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 } && tidy.order == fresh.order,
             "a tidied table turned and made A5 is tidied again, in its order, for its new shape")
    var moved = laid([CGSize(width: 36, height: 24), CGSize(width: 36, height: 24)])
    moved.tidy([id(800), id(801)])
    moved.move(id(800), by: CGVector(dx: 5, dy: 0))
    c.expect(moved.tidied == nil, "a tidied film moved: the table is no longer tidied")

    // a film taken off waits where it would lie on the new table
    var off = laid([CGSize(width: 36, height: 24)])
    off.moveTo(id(800), CGPoint(x: 60, y: 100))
    off.takeOff(id(800))
    off.relayout(paper: .a6, portrait: true)
    _ = off.place(id(800), size: CGSize(width: 36, height: 24), kept: .init(x: off.item(id(800))!.x, y: off.item(id(800))!.y, rot: 0,
                                                                            portrait: true, paper: .a6))
    c.expect(onLight(off) && off.item(id(800))!.x > 0 && off.item(id(800))!.y > 0, "a film put back after the table shrank lies on it, where it was")
}

/// Random (随机, 2026-10-19): square, on the light, a new table for a new seed, the same for the same.
func randomChecks(_ c: inout Checker, _ r: Rules) {
    let (start, ids) = ninetyNine()
    var a = start, b = start, a2 = start
    r.random(&a, 1)
    r.random(&b, 2)
    r.random(&a2, 1)
    c.expect(a.order.count == 99 && Set(a.order) == Set(ids) && a.items.allSatisfy(\.on), "Random with 99: none left out or taken off")
    c.expect(a.pile.allSatisfy { $0.rot == 0 } && b.pile.allSatisfy { $0.rot == 0 }, "Random: every film square, no turn at all")
    c.expect(onLight(a) && onLight(b), "Random: all of every film on the light")
    let moved = zip(a.pile.sorted { $0.id.uuidString < $1.id.uuidString }, b.pile.sorted { $0.id.uuidString < $1.id.uuidString })
        .filter { hypot($0.x - $1.x, $0.y - $1.y) > 1 }.count
    c.expect(moved > 90, "Random twice, two seeds: two different tables (\(moved) of 99 films elsewhere)")
    c.expect(a == a2, "Random: the same seed, the same table")
    // With room, as films are first put down: none over another, each 3 mm clear, clear of the scale's band.
    for (paper, portrait) in [(LightTablePaper.a4, true), (.a5, false), (.a6, true), (.a6, false)] {
        var few = laid((0..<6).map { $0 % 2 == 0 ? CGSize(width: 36, height: 24) : CGSize(width: 24, height: 36) }, paper: paper, portrait: portrait)
        for k in [0, 3] { few.setRotation(id(800 + k), 20 * deg) }
        var seen = Set<String>()
        for seed in UInt64(1)...5 {
            var m = few
            r.random(&m, seed)
            let pile = m.pile, h = m.half
            var apart = true
            for (i, x) in pile.enumerated() { for y in pile[(i + 1)...] {
                if abs(x.x - y.x) < x.w / 2 + y.w / 2 + LightTable.gap - 1e-9 && abs(x.y - y.y) < x.h / 2 + y.h / 2 + LightTable.gap - 1e-9 { apart = false }
            } }
            let band = pile.allSatisfy { $0.x - $0.w / 2 >= -h.width + LightTable.clear - 1e-9 && $0.y + $0.h / 2 <= h.height - LightTable.clear + 1e-9 }
            c.expect(apart && band && pile.allSatisfy { $0.rot == 0 } && onLight(m),
                     "Random, six films on \(paper.name) \(portrait ? "portrait" : "landscape"), seed \(seed): square, 3 mm apart, clear of the scale")
            seen.insert(pile.map { "\(Int($0.x)),\(Int($0.y))" }.sorted().joined(separator: ";"))
        }
        c.expect(seen.count == 5, "Random on \(paper.name) \(portrait ? "portrait" : "landscape"): five seeds, five tables (\(seen.count))")
    }
}

@MainActor
func keptSizeChecks(_ c: inout Checker, _ r: Rules) {
    // A file kept on 2026-10-17/18, before there were sizes: schema 1, no paper, an A4 portrait table.
    let v1 = """
    {"places":[{"frame":"00000000-0000-0000-0000-000000000901","on":true,"rot":0,"x":-40.5,"y":61.25,"z":0},
    {"frame":"00000000-0000-0000-0000-000000000902","on":true,"rot":0.5,"x":30,"y":-80,"z":1}],"portrait":true,"schemaVersion":1}
    """
    if let m = r.load(Data(v1.utf8)) {
        c.expect(m.paper == .a4 && m.portrait, "a table kept before there were sizes opens as the A4 it was, portrait: \(m.paper)")
        c.expect(m.item(id(901)).map { $0.x == -40.5 && $0.y == 61.25 } ?? false && m.item(id(902)).map { $0.x == 30 && $0.y == -80 && $0.rot == 0.5 } ?? false
                 && m.order == [id(901), id(902)], "every film where it lay, at its angle, in its pile")
    } else {
        c.expect(false, "a schema 1 file is read")
    }
    // a table kept at A5, landscape: back at A5, landscape, every film where it lay
    var m = laid([CGSize(width: 36, height: 24), CGSize(width: 56, height: 56)], paper: .a5, portrait: false)
    m.moveTo(id(800), CGPoint(x: -60, y: 30))
    let data = try! JSONEncoder().encode(StoredTable(m))
    let stored = try! JSONDecoder().decode(StoredTable.self, from: data)
    c.expect(stored.schemaVersion == 2 && stored.paper == .a5, "the size is written: schema 2, A5")
    let again = stored.model(portrait: stored.portrait) { _ in CGSize(width: 36, height: 24) }
    c.expect(again.paper == .a5 && !again.portrait && abs(again.item(id(800))!.x + 60) < 1e-9 && abs(again.item(id(800))!.y - 30) < 1e-9,
             "kept at A5 landscape, it opens at A5 landscape, every film where it lay")
}

func glideChecks(_ c: inout Checker, _ r: Rules) {
    var prev = 0.0, rising = true, over = 0.0
    for k in 0...240 {
        let f = r.glideShare(Double(k) / 240 * 0.6)
        if f < prev - 1e-12 { rising = false }
        over = max(over, f - 1)
        prev = f
    }
    c.expect(r.glideShare(0) == 0 && r.glideShare(TableGlide.duration) == 1 && r.glideShare(9) == 1, "the glide goes from 0 to exactly 1 in half a second")
    c.expect(rising && over <= 1e-12, "and never turns back or overshoots: a light box does not bounce (\(over) over)")
    c.expect(r.glideShare(0.1) > 0.4 && r.glideShare(0.25) > 0.85, "quick away, slow into place: \(r.glideShare(0.1)), \(r.glideShare(0.25))")
    let g = TableGlide(from: CGSize(width: 105, height: 148.5), to: CGSize(width: 148.5, height: 105),
                       films: [id(950): .init(x: 10, y: 80, angle: 350 * deg), id(951): .init(x: 0, y: 0, angle: 0)],
                       zoom: 2, centre: CGPoint(x: 10, y: 10), t0: 0)
    let a = LightTableItem(id: id(950), size: CGSize(width: 36, height: 24), x: 40, y: 20, rot: 10 * deg, on: true)
    let still = LightTableItem(id: id(951), size: CGSize(width: 36, height: 24), x: 0, y: 0, rot: 0, on: true)
    c.expect(g.half(at: 0) == g.from && g.half(at: 1) == g.to && abs(g.half(at: 0.5).width - 126.75) < 1e-9, "the pad's size from the old table's to the new one's")
    if let p0 = r.glidePose(g, a, 0), let p1 = r.glidePose(g, a, 1), let mid = r.glidePose(g, a, 0.5) {
        c.expect(p0.pose.x == 10 && p0.pose.y == 80 && abs(p1.pose.x - 40) < 1e-9 && abs(p1.pose.y - 20) < 1e-9, "a film from where it was shown to where it lies")
        c.expect(abs(mid.pose.angle - 360 * deg) < 1e-9, "from 350° to 10° the short way, through 360°: \(mid.pose.angle / deg)°")
        c.expect(p0.lift == 0 && abs(p1.lift) < 1e-9 && mid.lift > 0.3, "lifted on the way, set down as it arrives")
    } else {
        c.expect(false, "a film the table showed glides")
    }
    c.expect((r.glidePose(g, still, 0.5)?.lift ?? 1) == 0, "a film that does not move is not lifted")
    c.expect(r.glidePose(g, LightTableItem(id: id(952), size: still.size), 0.5) == nil, "a film the table did not show then is left to itself")
}

/// The Mac's Light Table (2026-10-24): Actual Size from the display's own size, and the rail.
func macChecks(_ c: inout Checker, _ r: Rules) {
    // This Mac's display as the app read it on 2026-10-24: an LG HDR 5K (34-inch, 5,120 × 2,160) in its HiDPI mode
    // (2,560 × 1,080 points over 5,120 × 2,160 pixels), 797.84 × 330.51 mm.
    let wide = MacDisplayReading(displayID: 3, name: "wide", builtin: false, millimetres: CGSize(width: 797.84, height: 330.51),
                                 points: CGSize(width: 2560, height: 1080), pixels: CGSize(width: 5120, height: 2160),
                                 macPointsPerScenePoint: 0.77, drawableScale: 2)
    if let k = r.macPointsPerMM(wide.points, wide.millimetres) {
        c.near(k, 2560 / 797.84, 1e-9, "a Mac point is the mode's points over the panel's millimetres, along its long side")
    } else { c.expect(false, "the wide display knows its size") }
    if let s = r.scenePointsPerMM(wide) {
        c.near(s, 2560 / 797.84 / 0.77, 1e-9, "a scene point is 0.77 of a Mac point: \(s) scene points a millimetre")
        // 100 mm of table at 1:1, back on the glass: scene points, to Mac points, to the panel's millimetres.
        c.near(100 * s * 0.77 * 797.84 / 2560, 100, 1e-9, "100 mm on the table at 1:1 is 100 mm on the panel")
        if let back = MacActualSize.millimetres(drawablePixels: 100 * s * wide.drawableScale, wide) {
            c.near(back, 100, 1e-9, "the drawable's pixels read back as the panel's millimetres")
        }
    } else { c.expect(false, "the wide display has a 1:1") }
    // A 14-inch MacBook Pro (3,024 × 1,964 px, 254 ppi: 302.4 × 196.4 mm) at its default "looks like
    // 1,512 × 982" and at "more space" (1,800 × 1,169 over 3,600 × 2,338): the millimetre is the panel's either way.
    let mm14 = CGSize(width: 302.4, height: 196.4)
    for (points, pixels) in [(CGSize(width: 1512, height: 982), CGSize(width: 3024, height: 1964)),
                             (CGSize(width: 1800, height: 1169), CGSize(width: 3600, height: 2338))] {
        let d = MacDisplayReading(displayID: 1, name: "built-in", builtin: true, millimetres: mm14, points: points, pixels: pixels,
                                  macPointsPerScenePoint: 0.77, drawableScale: 2)
        if let s = r.scenePointsPerMM(d) {
            // 302.4 mm across: the whole panel's width in scene points at 1:1 is the mode's width over 0.77.
            c.near(302.4 * s, Double(points.width) / 0.77, 1e-6, "at \(Int(points.width)) points the panel's 302.4 mm are the window's \(Int(Double(points.width) / 0.77)) scene points")
        } else { c.expect(false, "the built-in display at \(Int(points.width)) points has a 1:1") }
    }
    // Turned in System Settings: the mode is upright, the EDID's millimetres are not.
    let turned = r.macPointsPerMM(CGSize(width: 1080, height: 2560), CGSize(width: 797.84, height: 330.51))
    c.near(turned ?? 0, 2560 / 797.84, 1e-9, "a display turned upright keeps its millimetre")
    // No size known: no 1:1.
    c.expect(r.macPointsPerMM(CGSize(width: 1920, height: 1080), .zero) == nil, "a display with no size (0 mm) has no 1:1")
    c.expect(r.macPointsPerMM(CGSize(width: 1920, height: 1080), CGSize(width: 50, height: 28)) == nil
             && r.macPointsPerMM(CGSize(width: 1920, height: 1080), CGSize(width: 520, height: 140)) == nil,
             "nor one whose size no screen has, or whose axes disagree (a capture card's EDID)")

    // The rail: in the order the films were first laid, whatever the pile.
    var m = LightTableModel()
    m.orient(portrait: true)
    for n in 1...3 { _ = m.place(id(900 + n), size: CGSize(width: 36, height: 24)) }
    m.toFront(id(901))
    c.expect(r.railOrder(m) == [id(901), id(902), id(903)], "the rail keeps the order the films were laid in when one comes to the top")
    m.takeOff(id(902))
    c.expect(r.railOrder(m) == [id(901), id(903)], "a film taken off leaves the rail")
    _ = m.place(id(902), size: CGSize(width: 36, height: 24))
    c.expect(r.railOrder(m) == [id(901), id(902), id(903)], "and comes back to its place in it")
    // Each tile as the film lies.
    let film = LightTableItem(id: id(904), size: CGSize(width: 36, height: 24), on: true)
    let flat = r.railTile(film, CGSize(width: 120, height: 100))
    c.near(Double(flat.picture.width), 120, 1e-9, "an unturned 36 × 24 fills a 120-wide tile")
    c.expect(abs(flat.angle) < 1e-12 && abs(Double(flat.extent.height) - 80) < 1e-9, "unturned, 80 high")
    var up = film; up.rot = LightTable.quarter
    let t = r.railTile(up, CGSize(width: 120, height: 100))
    c.near(t.angle, -LightTable.quarter, 1e-12, "a film turned a quarter left on the table is drawn turned a quarter left on the screen")
    c.expect(abs(Double(t.extent.width) - 66.666666) < 1e-3 && abs(Double(t.extent.height) - 100) < 1e-9
             && abs(Double(t.picture.width) - 100) < 1e-9, "and fitted as it lies: 66.7 × 100, its picture 100 × 66.7 before the turn")
    var tilted = film; tilted.rot = 30 * LightTable.deg
    let tt = r.railTile(tilted, CGSize(width: 120, height: 100))
    let c30 = cos(30 * LightTable.deg), s30 = sin(30 * LightTable.deg)
    let ew = Double(tt.picture.width) * c30 + Double(tt.picture.height) * s30, eh = Double(tt.picture.width) * s30 + Double(tt.picture.height) * c30
    c.expect(ew <= 120 + 1e-9 && eh <= 100 + 1e-9 && (abs(ew - 120) < 1e-9 || abs(eh - 100) < 1e-9),
             "a film turned 30° fits its tile whole, touching it (\(ew) × \(eh))")
}

@main
struct LightTableSelfTest {
    @MainActor static func main() {
        func run(_ rules: Rules, quiet: Bool, all: Bool = false) -> Checker {
            var c = Checker(quiet: quiet, all: all)
            settleChecks(&c, rules)
            pileChecks(&c, rules)
            placingChecks(&c, rules)
            orientChecks(&c, rules)
            viewChecks(&c, rules)
            shownChecks(&c, rules)
            sizeChecks(&c, rules)
            budgetChecks(&c, rules)
            fingerChecks(&c, rules)
            loupeChecks(&c, rules)
            arrangeChecks(&c, rules)
            keptChecks(&c, rules)
            tableChecks(&c, rules)
            randomChecks(&c, rules)
            keptSizeChecks(&c, rules)
            glideChecks(&c, rules)
            macChecks(&c, rules)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let rules = Rules.broken
            for rule in rules {
                let verbose = CommandLine.arguments.contains("--verbose")
                if verbose { print("- \(rule.name)") }
                if run(rule, quiet: !verbose).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("light table self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        var c = Checker(quiet: false, all: CommandLine.arguments.contains("--verbose"))
        c = run(Rules(), quiet: false, all: c.all)
        print("light table checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
