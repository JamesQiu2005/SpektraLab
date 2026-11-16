// watermark_pointer_selftest.swift -- the rules the watermark canvas's pointer takes a press and a drag by (2.4.1, the
// owner's hand test, 2026-11-16: "I cannot drag to rotate like Photoshop"): where a press lands (the turn handle's dot
// is the turn, not the move; just outside a corner is the turn; a corner is a size; the mark is the move), and the turn a
// drag gives (the angle the pointer sweeps about the mark's centre; Shift to 15°; the centre stays).
//
//     python3 tools/gate.py selftest --only watermark_pointer_selftest   # the checks, then their own check
import CoreGraphics
import Foundation

struct Rules {
    var name = "the app's"
    var hit: (CGPoint, WatermarkFrame) -> WatermarkPart? = {
        WatermarkGeometry.hit($0, frame: $1, handles: true, handleRadius: 9, rotateDistance: 26, cornerTurnReach: 20)
    }
    var turned: (WatermarkPlacement, CGSize, CGPoint, CGPoint, Bool) -> WatermarkPlacement = {
        WatermarkGeometry.turned($0, canvas: $1, aspect: 2, from: $2, to: $3, shift: $4)
    }
    static var broken: [Rules] {
        var noRing = Rules(name: "no turn just outside a corner")
        noRing.hit = { WatermarkGeometry.hit($0, frame: $1, handles: true, handleRadius: 9, rotateDistance: 26) }
        var bodyFirst = Rules(name: "the body wins over the turn handle")
        bodyFirst.hit = { WatermarkGeometry.hit($0, frame: $1, handles: false, handleRadius: 0) }
        var noShift = Rules(name: "Shift does not snap")
        noShift.turned = { p, c, a, b, _ in WatermarkGeometry.turned(p, canvas: c, aspect: 2, from: a, to: b, shift: false) }
        var dragsCentre = Rules(name: "the turn moves the centre")
        dragsCentre.turned = { var q = WatermarkGeometry.turned($0, canvas: $1, aspect: 2, from: $2, to: $3, shift: $4); q.dx += 0.05; return q }
        var wrongWay = Rules(name: "the turn goes against the pointer")
        wrongWay.turned = { p, c, a, b, s in WatermarkGeometry.turned(p, canvas: c, aspect: 2, from: b, to: a, shift: s) }
        return [noRing, bodyFirst, noShift, dragsCentre, wrongWay]
    }
}

struct Checker {
    var passed = 0, failed = 0, quiet = false
    mutating func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed += 1; if !quiet { print("  FAILED: \(what())") } }
    }
}

func close(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
func close(_ a: CGPoint, _ b: CGPoint, _ eps: Double = 1e-6) -> Bool { close(Double(a.x), Double(b.x), eps) && close(Double(a.y), Double(b.y), eps) }
func deg(_ r: Double) -> Double { r * 180 / .pi }

let canvas = CGSize(width: 1000, height: 800)

func placed(rotation: Double = 0) -> WatermarkPlacement {
    var p = WatermarkPlacement(mark: UUID(), anchor: .br, dx: 0.4, dy: 0.3, size: 0.25)
    p.rotation = rotation
    return p
}

func checks(_ c: inout Checker, _ r: Rules) {
    for turn in [0.0, .pi / 6, -.pi / 3, 2.2] {
        let p = placed(rotation: turn)
        let f = WatermarkGeometry.frame(of: p, canvas: canvas, aspect: 2)
        let knob = WatermarkGeometry.rotateHandle(of: f, distance: 26)
        let t = Int(deg(turn))
        c.expect(r.hit(knob, f) == .rotate, "a press on the turn handle's dot turns, mark turned \(t)°")
        c.expect(r.hit(f.center, f) == .body, "a press in the mark moves, mark turned \(t)°")
        c.expect(r.hit(f.corner(.br), f) == .handle(.br), "a press on a corner sizes, mark turned \(t)°")
        // A point 14 out from a corner along the diagonal, off the mark and past the handle's own radius.
        let out = CGPoint(x: Double(f.corner(.tl).x) + (Double(f.corner(.tl).x) - Double(f.center.x)) / hypot(Double(f.corner(.tl).x - f.center.x), Double(f.corner(.tl).y - f.center.y)) * 14,
                          y: Double(f.corner(.tl).y) + (Double(f.corner(.tl).y) - Double(f.center.y)) / hypot(Double(f.corner(.tl).x - f.center.x), Double(f.corner(.tl).y - f.center.y)) * 14)
        c.expect(r.hit(out, f) == .rotate, "a press just outside a corner turns, mark turned \(t)°")
        c.expect(r.hit(CGPoint(x: f.center.x, y: f.center.y + 400), f) == nil, "a press far off hits nothing, mark turned \(t)°")
    }

    // The turn: the pointer's angle about the centre, from the dot's place.
    let p = placed()
    let f = WatermarkGeometry.frame(of: p, canvas: canvas, aspect: 2)
    let knob = WatermarkGeometry.rotateHandle(of: f, distance: 26)
    let right = CGPoint(x: f.center.x + 200, y: f.center.y)
    let a = r.turned(p, canvas, knob, right, false)
    c.expect(close(deg(a.rotation), 90, 1e-6), "the dot dragged from above the centre to its right turns the mark 90° clockwise (\(deg(a.rotation))°)")
    c.expect(a.dx == p.dx && a.dy == p.dy && a.anchor == p.anchor, "the turn keeps the centre")
    let ang = (-90.0 + 22) * .pi / 180
    let at22 = CGPoint(x: Double(f.center.x) + 300 * cos(ang), y: Double(f.center.y) + 300 * sin(ang))
    let free = r.turned(p, canvas, knob, at22, false)
    c.expect(close(deg(free.rotation), 22, 1e-6), "the turn follows the pointer's angle, not its distance (\(deg(free.rotation))°)")
    let snapped = r.turned(p, canvas, knob, at22, true)
    c.expect(close(deg(snapped.rotation), 15, 1e-6), "Shift snaps 22° to 15° (\(deg(snapped.rotation))°)")
    let ang2 = (-90.0 + 38) * .pi / 180
    let at38 = CGPoint(x: Double(f.center.x) + 120 * cos(ang2), y: Double(f.center.y) + 120 * sin(ang2))
    c.expect(close(deg(r.turned(p, canvas, knob, at38, true).rotation), 45, 1e-6), "Shift snaps 38° to 45°")
    // From a turned mark: Shift snaps the result, not the sweep.
    let q = placed(rotation: 10 * .pi / 180)
    let fq = WatermarkGeometry.frame(of: q, canvas: canvas, aspect: 2)
    let kq = WatermarkGeometry.rotateHandle(of: fq, distance: 26)
    let sweep = (-90.0 + 10 + 20) * .pi / 180
    let toQ = CGPoint(x: Double(fq.center.x) + 150 * cos(sweep), y: Double(fq.center.y) + 150 * sin(sweep))
    c.expect(close(deg(r.turned(q, canvas, kq, toQ, true).rotation), 30, 1e-6), "from 10° a 20° sweep is 30°, a multiple of 15° under Shift")
}

@main
enum Main {
    static func main() {
        func run(_ r: Rules, quiet: Bool) -> Checker { var c = Checker(quiet: quiet); checks(&c, r); return c }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in Rules.broken {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("watermark pointer self-test: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("watermark pointer checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
