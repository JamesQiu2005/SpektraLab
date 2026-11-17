//  MacWatermarkHandCheck.swift — `--watermark-canvas-check`'s hand (2.4.1 round 4, the owner's third hand test,
//  2026-11-16: "the watermark layer still cannot be rotated by dragging on the canvas, even though the last session
//  claimed to have been fixed"). Round 3's turn was proven through the session's own calls; no pointer reached the
//  canvas. Here a mouse's events do, posted into the app's own queue (`MacHIDPost`: AppKit's window, Catalyst's bridge,
//  UIKit's hit-test and the canvas's recognisers, as a hand's; nothing brought to the front, the real cursor not moved):
//  the pointer approaches, presses on the turn handle's dot — or just outside a corner —, drags along, rests, and lifts.
//
//  For a 底片 mark and a 成片 one, at 100 %, 150 % and 80 % interface scale, and at the canvas fitted and zoomed in:
//  - **the dot's drag turns the mark** by the pointer's sweep about its centre (within 2.5°), the centre and size kept,
//    and the picture not panned or zoomed by it;
//  - **a press just outside a corner turns it** the same way;
//  - **a press held still before the drag** (a hand's pause) still turns it — the canvas's hold for Original must not
//    take the stage away under the pointer;
//  - **the body's drag moves it** by the pointer's travel, and **a corner's drag sizes it**;
//  - each is one Undo step.
//
//  Where an act cannot be posted, each step says `UNREACHED` and is not a failure.

#if targetEnvironment(macCatalyst) && DEBUG
import UIKit

extension MacWatermarkCanvasCheck {
    /// The stage's pointer view (`WatermarkPointerView`) in the key window.
    static func pointerView() -> WatermarkPointerView? {
        guard let window = MacHIDPost.window else { return nil }
        func walk(_ v: UIView) -> WatermarkPointerView? {
            if let p = v as? WatermarkPointerView, p.window != nil, !p.isHidden { return p }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return walk(window)
    }

    static func hand(_ model: AppServices, _ s: OpenFrameSession, out: URL, check: (Bool, String) -> Void,
                     placement start: WatermarkPlacement, named label: String) async -> [String: Any] {
        let tag = "watermark-canvas-check"
        var facts: [String: Any] = [:]
        var unreached = 0
        func reached(_ posted: Bool, _ what: String) -> Bool {
            if !posted { unreached += 1; print("\(tag): UNREACHED \(what)") }
            return posted
        }
        let aspect: (UUID) -> Double = { id in model.watermarks.info(id).map { Double($0.w) / Double(max($0.h, 1)) } ?? 1 }
        func placement() -> WatermarkPlacement? { s.edit.watermarks.first { $0.id == start.id } }
        /// The mark as the stage draws it, in the window's points: its frame's centre, corners and the turn handle's dot.
        func drawn() -> (centre: CGPoint, corners: [CGPoint], knob: CGPoint, factor: CGFloat)? {
            guard let p = placement(), let view = pointerView(), let window = view.window else { return nil }
            let sp = WatermarkStageHit.space(p, shown: s.watermarkCanvas, canvases: s.watermarkCanvases, appliesFilm: s.edit.appliesFilm)
            let fr = WatermarkGeometry.frame(of: p, canvas: sp.canvas, aspect: aspect(p.mark)).through(sp.toLocal)
            let inset = WatermarkCanvasStage.pointerMargin
            func w(_ q: CGPoint) -> CGPoint { view.convert(CGPoint(x: q.x + inset, y: q.y + inset), to: window) }
            let knob = WatermarkGeometry.rotateHandle(of: fr, distance: WatermarkCanvasStage.rotateDistance)
            let factor = view.convert(view.bounds, to: window).width / max(view.bounds.width, 1)
            return (w(fr.center), fr.corners.map(w), w(knob), factor)
        }
        func angle(_ a: CGPoint, about c: CGPoint) -> Double { atan2(Double(a.y - c.y), Double(a.x - c.x)) }
        func around(_ p: CGPoint, _ c: CGPoint, by degrees: Double) -> CGPoint {
            let r = hypot(Double(p.x - c.x), Double(p.y - c.y)), a = angle(p, about: c) + degrees * .pi / 180
            return CGPoint(x: Double(c.x) + r * cos(a), y: Double(c.y) + r * sin(a))
        }

        func reset() async {
            s.change { e in
                if let i = e.watermarks.firstIndex(where: { $0.id == start.id }) { e.watermarks[i] = start } else { e.watermarks = [start] }
            }
            s.pick(row: .watermark(start.id))
            s.watermarkSelected = true
            await MacMasksCheck.pause(0.8)
        }

        /// A drag on the canvas, from `from` to `to` (window points), the press held `still` first.
        func gesture(_ name: String, from: CGPoint, to: CGPoint, still: Bool = false) async -> (WatermarkPlacement, WatermarkPlacement)? {
            guard let before = placement() else { check(false, "\(name): the mark is on the frame"); return nil }
            // A hand's pause on the press before it moves (`still`: 0.5 s, past the canvas's 0.25 s hold for Original).
            guard reached(await MacHIDPost.drag(from, to, hold: still ? 0.5 : 0), name) else { return nil }
            await MacMasksCheck.pause(0.6)
            guard let after = placement() else { return nil }
            facts[name] = ["rotation": [WatermarkGeometry.degrees(before.rotation), WatermarkGeometry.degrees(after.rotation)],
                           "dx": [before.dx, after.dx], "dy": [before.dy, after.dy], "size": [before.size, after.size]]
            await MacMasksCheck.capture("hand-\(name)")
            if after != before {
                _ = s.undo()
                check(placement() == before, "\(name): one Undo puts the whole gesture back")
                s.change { e in if let i = e.watermarks.firstIndex(where: { $0.id == start.id }) { e.watermarks[i] = after } }
            }
            return (before, after)
        }

        func turns(_ name: String, still: Bool = false, corner: Bool = false) async {
            await reset()
            guard let d = drawn() else { check(false, "\(name): the stage's pointer is on the page"); return }
            let from: CGPoint
            if corner {
                // Just outside the top right corner, along its diagonal: 12 of the stage's points (its turn zone is 22).
                let c = d.corners[1], len = max(hypot(c.x - d.centre.x, c.y - d.centre.y), 1)
                from = CGPoint(x: c.x + (c.x - d.centre.x) / len * 12 * d.factor, y: c.y + (c.y - d.centre.y) / len * 12 * d.factor)
            } else {
                from = d.knob
            }
            let sweep = corner ? -30.0 : 40.0
            guard let (before, after) = await gesture(name, from: from, to: around(from, d.centre, by: sweep), still: still) else { return }
            let turned = WatermarkGeometry.degrees(WatermarkGeometry.normalised(after.rotation - before.rotation))
            check(abs(turned - sweep) <= 2.5, "\(name): the drag turns the mark by the pointer's sweep (\(turned)° for \(sweep)°)")
            check(abs(after.size - before.size) < 1e-9, "\(name): the turn keeps the mark's size")
            if let d1 = drawn() {
                check(hypot(d1.centre.x - d.centre.x, d1.centre.y - d.centre.y) <= 1.5,
                      "\(name): the turn keeps the mark's centre where it is on the window (moved \(hypot(d1.centre.x - d.centre.x, d1.centre.y - d.centre.y)))")
            }
        }

        func moves(_ name: String) async {
            await reset()
            guard let d = drawn() else { check(false, "\(name): the stage's pointer is on the page"); return }
            let by = CGPoint(x: 40, y: 24)
            guard await gesture(name, from: d.centre, to: CGPoint(x: d.centre.x + by.x, y: d.centre.y + by.y)) != nil, let d1 = drawn() else { return }
            let moved = CGPoint(x: d1.centre.x - d.centre.x, y: d1.centre.y - d.centre.y)
            check(abs(moved.x - by.x) <= 2 && abs(moved.y - by.y) <= 2, "\(name): the body's drag moves the mark by the pointer's travel (\(moved) for \(by))")
        }

        func sizes(_ name: String) async {
            await reset()
            guard let d = drawn() else { check(false, "\(name): the stage's pointer is on the page"); return }
            let c = d.corners[2], len = max(hypot(c.x - d.centre.x, c.y - d.centre.y), 1)
            let to = CGPoint(x: c.x + (c.x - d.centre.x) / len * 30, y: c.y + (c.y - d.centre.y) / len * 30)
            guard let (before, after) = await gesture(name, from: c, to: to) else { return }
            check(after.size > before.size * 1.05, "\(name): the corner's drag sizes the mark up (\(before.size) → \(after.size))")
        }

        // `--hand-quick`: 100 % alone, not zoomed (a look while a fix is made).
        let quick = CommandLine.arguments.contains("--hand-quick")
        for scale in quick ? [InterfaceScale.p100] : [InterfaceScale.p100, .p150, .p80] {
            if scale == .p100 { UserDefaults.standard.removeObject(forKey: InterfaceScale.key) } else { UserDefaults.standard.set(scale.rawValue, forKey: InterfaceScale.key) }
            await MacMasksCheck.pause(1.2)
            await turns("\(label)-\(scale.rawValue)-turn-dot")
            await turns("\(label)-\(scale.rawValue)-turn-corner", corner: true)
            if scale == .p100 {
                await turns("\(label)-\(scale.rawValue)-turn-dot-held", still: true)
                await moves("\(label)-\(scale.rawValue)-move")
                await sizes("\(label)-\(scale.rawValue)-size")
            }
        }
        UserDefaults.standard.removeObject(forKey: InterfaceScale.key)
        if quick {
            facts["unreached"] = unreached; return facts
        }
        // Zoomed in, about the picture's middle: the mark at the middle, so it is on screen.
        NotificationCenter.default.post(name: MacDriver.zoomHundred, object: true)
        await MacMasksCheck.pause(1.5)
        await turns("\(label)-zoomed-turn-dot")
        await moves("\(label)-zoomed-move")
        NotificationCenter.default.post(name: MacDriver.zoomHundred, object: false)
        await MacMasksCheck.pause(1.0)
        await reset()
        facts["unreached"] = unreached
        if unreached > 0 { print("\(tag): UNREACHED \(unreached) posted acts did not reach the window — those cases are on the hand-check list") }
        return facts
    }
}
#endif
