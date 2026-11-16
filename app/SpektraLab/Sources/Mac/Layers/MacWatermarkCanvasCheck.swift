//  MacWatermarkCanvasCheck.swift — a debug build's proof of 水印 on the develop page's canvas (the owner's hand test of
//  2.4.1, 2026-11-16), in the running app:
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --watermark-canvas-check <dir> --export-check-pictures <raw> [--export-check-exit]
//
//  The picture (copied into `<dir>/work/Card`) is linked and made a frame; the check's mark (`MacWatermarkCheck.markPNG`)
//  is added to the scratch home's library. Then, with the window captured at every state (`--capture-window`):
//
//  - **底片, picked and at rest** — a 底片 mark developed, its row picked: the page shows its developed picture, never a
//    pending one (the owner's "weird greyed out canvas").
//  - **底片 under a gesture** — while the mark is dragged, the page's picture carries **no mark at its old place** (the
//    owner's "the old location is still shown"): the picture under the drag is the develop without the moving mark, and
//    the overlay draws the mark where the pointer has it. After the lift, the picture is of the mark where it went.
//  - **填充** — a fill colour: the page, the overlay and the develop draw the mark's alpha in that colour.
//  - **The film edge** — a frame with a film edge: a 成片 mark is placed on the film's rebate, outside the picture, and the
//    page's pass draws it there.
//
//  `<dir>/report.json` and the captures are left for a look. Not in a release build.

#if targetEnvironment(macCatalyst) && DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UIKit

@MainActor
enum MacWatermarkCanvasCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = MacCheckFolder.index(of: "--watermark-canvas-check", in: arguments) else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--export-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        let exits = arguments.contains("--export-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let report = await run(model, out: out, picture: pictures.first)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            let failures = (report["failures"] as? [String]) ?? ["no report"]
            print("watermark-canvas-check: \(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))") — \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(failures.isEmpty ? 0 : 1)
            }
        }
    }

    /// The mean 8-bit RGB of `image` over the unit square `points` of a mark's frame `f` laid on `image` through `t`.
    static func mean(_ image: CGImage, _ f: WatermarkFrame, _ t: CGAffineTransform, _ points: [CGPoint]) -> SIMD3<Int>? {
        guard let read = MacWatermarkCheck.pixels(image), !points.isEmpty else { return nil }
        let px = points.map { q -> SIMD3<Int> in
            let r = q.applying(f.transform).applying(t)
            return read.at(Int(r.x), Int(r.y))
        }
        return px.reduce(SIMD3<Int>(0, 0, 0), &+) / px.count
    }

    static func run(_ model: AppServices, out: URL, picture: URL?) async -> [String: Any] {
        let fm = FileManager.default
        var failures: [String] = [], facts: [String: Any] = [:]
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("watermark-canvas-check: FAIL \(what)") } else { print("watermark-canvas-check: ok \(what)") }
        }
        guard let picture else { return ["failures": ["no picture (--export-check-pictures)"]] }
        let work = out.appending(path: "work"), card = work.appending(path: "Card")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: picture, to: card.appending(path: picture.lastPathComponent))
        guard let png = MacWatermarkCheck.markPNG(), case .success(let added) = await model.watermarks.add(png, name: "Check mark") else {
            return ["failures": ["the library takes the check's mark"]]
        }
        let mark = added.mark
        let store = model.macLibrary
        await store.start()
        do { _ = try await store.open(card) } catch { check(false, "the folder links: \(error.localizedDescription)") }
        await store.loadAll()
        guard let row = store.images.first(where: { $0.fileName == picture.lastPathComponent }),
              let id = (try? await store.frames(for: [row.id], focus: nil).frames)?[row.id] else {
            return ["failures": failures + ["the picture is a frame"]]
        }
        guard let s = await MacMasksCheck.develop(model, id) else { return ["failures": failures + ["the frame opens in Develop"]] }
        let (platePts, _) = MacWatermarkCheck.platePoints()

        // 1. A 底片 mark, developed, its row picked, at rest.
        let base = WatermarkPlacement(mark: mark.id, stage: .base, anchor: .tl, dx: 0.3, dy: 0.25, size: 0.111)
        var stamp = s.developed?.stamp
        s.change { $0.watermarks = [base] }
        _ = await MacMasksCheck.developed(s, model, from: stamp)
        s.pick(row: .watermark(base.id))
        await MacMasksCheck.pause(1.0)
        await MacMasksCheck.capture("canvas-base-picked")
        check(s.developedBaseMarks.contains(base), "底片 picked at rest: the page's picture is of the mark")
        guard let frame = model.library.frame(id), let developed = s.developedCGImage,
              let canvases = model.watermarkCanvases(frame, edit: s.edit, finished: CGSize(width: developed.width, height: developed.height))
        else { return ["failures": failures + ["the canvases"], "facts": facts] }
        let toPicture = canvases.baseToFull.concatenating(CGAffineTransform(scaleX: CGFloat(developed.width) / canvases.full.width,
                                                                              y: CGFloat(developed.width) / canvases.full.width))
        let f0 = WatermarkGeometry.frame(of: base, canvas: canvases.base, aspect: 2)
        let restPlate = mean(developed, f0, toPicture, platePts)
        facts["base_rest_plate"] = restPlate.map { [$0.x, $0.y, $0.z] } ?? []
        check((restPlate.map { MacWatermarkCheck.luma($0) } ?? 0) > 0.7, "底片 at rest: the plate is developed bright where it is")

        // 2. A gesture on it: the picture under the drag carries no mark at the old place.
        stamp = s.developed?.stamp
        s.watermarkSelected = true
        s.beganWatermark()
        for k in 1...10 { s.moveWatermark(base.id) { $0.dx = base.dx + 0.03 * Double(k); $0.dy = base.dy + 0.02 * Double(k) } }
        let underDrag = await MacMasksCheck.until(10, every: 50) { s.developed?.stamp != stamp && !s.developedBaseMarks.contains(base) }
        await MacMasksCheck.pause(0.5)
        await MacMasksCheck.capture("canvas-base-dragging")
        if let now = s.developedCGImage, let plate = mean(now, f0, toPicture, platePts) {
            facts["base_drag_old_plate"] = [plate.x, plate.y, plate.z]
            check(underDrag && MacWatermarkCheck.luma(plate) < 0.7, "底片 under a drag: no mark at its old place on the page's picture (\(plate))")
        } else {
            check(false, "底片 under a drag: the page has a picture")
        }
        s.endedWatermark()
        let moved = s.edit.watermarks.first { $0.id == base.id }!
        _ = await MacMasksCheck.developed(s, model, from: s.developed?.stamp)
        await MacMasksCheck.capture("canvas-base-lifted")
        check(s.developedBaseMarks.contains(moved), "底片 lifted: the page's picture is of the mark where it went")
        if let now = s.developedCGImage {
            let f1 = WatermarkGeometry.frame(of: moved, canvas: canvases.base, aspect: 2)
            let plate = mean(now, f1, toPicture, platePts)
            facts["base_lifted_plate"] = plate.map { [$0.x, $0.y, $0.z] } ?? []
            check((plate.map { MacWatermarkCheck.luma($0) } ?? 0) > 0.7, "底片 lifted: developed where it went")
            let old = mean(now, f0, toPicture, platePts)
            check((old.map { MacWatermarkCheck.luma($0) } ?? 1) < 0.7, "底片 lifted: nothing left at the old place")
        }
        // The develop under the drag was opened from the page's kept decode (no decode of the file).
        let how = model.scheduler.records.filter { $0.kind == JobKind.canvasDevelop.rawValue }.suffix(2).compactMap { $0.measurement?.decodedBy }
        facts["base_drag_decodes"] = how
        check(how.count == 2 && how.allSatisfy { $0 == "the kept decode" }, "底片 under a drag and at its lift: opened from the kept decode (\(how))")
        // 2b. The turn handle's drag (the owner's hand test, 2026-11-16: it did not turn): the session path the stage's
        // pointer takes — began, the turn the pointer's angle about the centre gives (`WatermarkGeometry.turned`), ended —
        // is one step, about the centre, and an Undo puts the turn back. (The pointer's own press is not posted here.)
        let pre = s.edit.watermarks.first { $0.id == base.id }!
        let fT = WatermarkGeometry.frame(of: pre, canvas: canvases.base, aspect: 2)
        let knob = WatermarkGeometry.rotateHandle(of: fT, distance: WatermarkCanvasStage.rotateDistance)
        let sweep = 40 * Double.pi / 180
        s.watermarkSelected = true
        s.beganWatermark()
        for k in 1...12 {
            let a = -Double.pi / 2 + sweep * Double(k) / 12
            let to = CGPoint(x: Double(fT.center.x) + 200 * cos(a), y: Double(fT.center.y) + 200 * sin(a))
            s.moveWatermark(pre.id) { $0 = WatermarkGeometry.turned(pre, canvas: canvases.base, aspect: 2, from: knob, to: to, shift: false) }
        }
        s.endedWatermark()
        let turned = s.edit.watermarks.first { $0.id == base.id }!
        facts["turn_degrees"] = WatermarkGeometry.degrees(turned.rotation - pre.rotation)
        check(abs(WatermarkGeometry.normalised(turned.rotation - pre.rotation) - sweep) < 1e-6, "the turn handle's drag turns the mark by the pointer's sweep (\(WatermarkGeometry.degrees(turned.rotation))°)")
        check(turned.dx == pre.dx && turned.dy == pre.dy && turned.size == pre.size, "the turn keeps the mark's centre and size")
        _ = s.undo()
        check(s.edit.watermarks.first { $0.id == base.id } == pre, "one Undo puts the whole turn back")
        _ = await MacMasksCheck.developed(s, model, from: s.developed?.stamp)
        // 2c. A person's mouse on the canvas (round 4, `MacWatermarkHandCheck.swift`): the turn by the dot and from just
        // outside a corner, a held press, a move and a size, at three interface scales and zoomed in; a 底片 mark, then a 成片
        // one, each at the canvas's middle.
        let keptMarks = s.edit.watermarks
        let shortBase = WatermarkGeometry.shortSide(canvases.base)
        let baseMid = WatermarkPlacement(mark: mark.id, stage: .base, anchor: .tl, dx: Double(canvases.base.width / 2 / shortBase),
                                         dy: Double(canvases.base.height / 2 / shortBase), size: 0.15)
        s.change { $0.watermarks = [baseMid] }
        _ = await MacMasksCheck.developed(s, model, from: s.developed?.stamp)
        facts["hand_base"] = await hand(model, s, out: out, check: { check($0, $1) }, placement: baseMid, named: "base")
        let shown = s.watermarkCanvas, shortShown = WatermarkGeometry.shortSide(shown)
        if shortShown > 0 {
            let fullMid = WatermarkPlacement(mark: mark.id, stage: .full, anchor: .tl, dx: Double(shown.width / 2 / shortShown),
                                             dy: Double(shown.height / 2 / shortShown), size: 0.15)
            s.change { $0.watermarks = [fullMid] }
            await MacMasksCheck.pause(0.8)
            facts["hand_full"] = await hand(model, s, out: out, check: { check($0, $1) }, placement: fullMid, named: "full")
        } else { check(false, "the stage's canvas is known (\(shown))") }
        s.change { $0.watermarks = keptMarks }
        _ = await MacMasksCheck.developed(s, model, from: s.developed?.stamp)
        s.pick(row: .film)
        await MacMasksCheck.pause(1.0)
        await MacMasksCheck.capture("canvas-base-unpicked")

        // 3. 填充: the 底片 mark filled blue develops blue; a 成片 one filled red is red on the page's pass.
        stamp = s.developed?.stamp
        s.changeWatermark(base.id) { $0.fill = "#2F6FDE" }
        let blue = await MacMasksCheck.developed(s, model, from: stamp)
        if let blue, let plate = mean(blue, WatermarkGeometry.frame(of: moved, canvas: canvases.base, aspect: 2), toPicture, platePts) {
            facts["fill_base_plate"] = [plate.x, plate.y, plate.z]
            check(plate.z > plate.x + 30 && plate.z > 80, "填充 底片: the plate develops in the fill's blue (\(plate))")
        } else { check(false, "填充 底片: a develop") }
        await MacMasksCheck.capture("canvas-fill-base")
        let full = WatermarkPlacement(mark: mark.id, stage: .full, anchor: .br, dx: 0.3, dy: 0.25, size: 0.15, fill: "#D0342C")
        s.change { $0.watermarks = [full] }
        let live = s.layer2
        if let d = s.developedCGImage { live.display(maxPixel: max(d.width, d.height)) }
        _ = await MacMasksCheck.until(20, every: 100) { live.marks?.marks.placements.first?.fill == "#D0342C" && live.shown != nil }
        await MacMasksCheck.pause(0.8)
        if let shown = live.shown, let laid = live.marks {
            let pl = laid.placing(picture: CGSize(width: shown.width, height: shown.height))
            let f = WatermarkGeometry.frame(of: full, canvas: pl.canvas, aspect: 2)
            if let plate = mean(shown, f, pl.toPicture, platePts) {
                facts["fill_full_plate"] = [plate.x, plate.y, plate.z]
                check(plate.x > 170 && plate.y < 90 && plate.z < 90, "填充 成片: the plate is the fill's red on the page (\(plate))")
            }
        } else { check(false, "填充 成片: the page's pass") }
        check(s.edit.watermarks.first?.fill == "#D0342C", "填充: the fill is the edit's")
        if let data = try? JSONEncoder().encode(s.edit.watermarks), let text = String(data: data, encoding: .utf8) {
            check(text.contains("\"fill\":\"#D0342C\""), "填充: written as \"fill\":\"#D0342C\"")
        }
        s.changeWatermark(full.id) { $0.fill = nil }
        if let data = try? JSONEncoder().encode(s.edit.watermarks), let text = String(data: data, encoding: .utf8) {
            check(!text.contains("fill"), "原样: nothing written for it")
        }
        s.pick(row: .watermark(full.id))
        await MacMasksCheck.pause(0.5)
        await MacMasksCheck.capture("canvas-fill-native")

        // 4. A film edge: a 成片 mark on the film's rebate, outside the picture.
        stamp = s.developed?.stamp
        s.change { e in e.filmEdge.active = true; e.filmEdge.format = .f135 }
        _ = await MacMasksCheck.developed(s, model, from: stamp)
        guard let edged = s.developedCGImage, let f2 = model.library.frame(id),
              let c2 = model.watermarkCanvases(f2, edit: s.edit, finished: CGSize(width: edged.width, height: edged.height))
        else { return ["failures": failures + ["the film edge's canvases"], "facts": facts] }
        // The mark's centre in the rebate: inside the canvas, outside the picture's box (its corners through baseToFull).
        let boxCorners = [CGPoint.zero, CGPoint(x: c2.base.width, y: 0), CGPoint(x: c2.base.width, y: c2.base.height), CGPoint(x: 0, y: c2.base.height)]
            .map { $0.applying(c2.baseToFull) }
        let top = boxCorners.map(\.y).min() ?? 0
        let short = WatermarkGeometry.shortSide(c2.full)
        facts["edge_canvas"] = ["full": [c2.full.width, c2.full.height], "base": [c2.base.width, c2.base.height], "picture_top": top]
        check(top > 0.02 * short, "the film edge leaves a rebate over the picture (\(top) of \(c2.full.height))")
        var onEdge = WatermarkPlacement(mark: mark.id, stage: .full, anchor: .tl, dx: 0.5, dy: 0, size: 0.05)
        onEdge.dy = Double(top / 2) / short
        onEdge = WatermarkGeometry.settled(onEdge, canvas: c2.full, aspect: 2)
        check(Double(WatermarkGeometry.frame(of: onEdge, canvas: c2.full, aspect: 2).center.y) < Double(top), "成片 on the edge: kept in the rebate by the gesture's clamp")
        s.change { $0.watermarks = [onEdge] }
        s.pick(row: .film)
        if let d = s.developedCGImage { live.display(maxPixel: max(d.width, d.height)) }
        _ = await MacMasksCheck.until(20, every: 100) { live.marks?.marks.placements.first?.id == onEdge.id && live.shown != nil }
        await MacMasksCheck.pause(0.8)
        if let shown = live.shown, let laid = live.marks {
            let pl = laid.placing(picture: CGSize(width: shown.width, height: shown.height))
            // The marks' canvas on the page's picture is the cut finished picture, in its pixels; the edge's canvas is in mm.
            let k = pl.canvas.width / c2.full.width
            let f = WatermarkGeometry.frame(of: onEdge, canvas: pl.canvas, aspect: 2)
            if let plate = mean(shown, f, pl.toPicture, platePts) {
                facts["edge_full_plate"] = [plate.x, plate.y, plate.z]
                check(MacWatermarkCheck.luma(plate) > 0.9, "成片 on the edge: drawn white on the rebate (\(plate))")
            }
            facts["edge_scale"] = k
        } else { check(false, "成片 on the edge: the page's pass") }
        s.pick(row: .watermark(onEdge.id))
        await MacMasksCheck.pause(0.8)
        await MacMasksCheck.capture("canvas-edge-full")
        // 底片 on a film edge: the page says where it can go (the picture), and how to reach the rebate (成片).
        s.switchWatermarkStage(onEdge.id, to: .base)
        await MacMasksCheck.pause(0.5)
        check(s.edit.watermarks.first?.stage == .base, "叠加于 底片 under a film edge")
        let converted = s.edit.watermarks.first!
        let cf = WatermarkGeometry.frame(of: converted, canvas: c2.base, aspect: 2)
        check(cf.center.y >= 0 && cf.center.y <= c2.base.height, "底片 under a film edge: held to the picture")
        _ = await MacMasksCheck.developed(s, model, from: s.developed?.stamp)
        await MacMasksCheck.capture("canvas-edge-base")

        // 5. The owner's session, as the log has it (a 底片 mark under a film edge, Enable HDR on, moved again and again a
        // second apart, its stage and eye switched): after each, the page shows a developed picture of the edit, never
        // the ground (`Theme.plot`) nor a picture with no mark where the mark is at rest.
        model.library.update(id) { $0.edit.hdrChoice = true }
        s.pick(row: .watermark(onEdge.id))
        var odd: [String] = []
        for k in 0..<8 {
            s.watermarkSelected = true
            s.beganWatermark()
            for j in 1...6 { s.moveWatermark(onEdge.id) { $0.dx += 0.004 * Double(j) * (k % 2 == 0 ? 1 : -1) } }
            try? await Task.sleep(for: .milliseconds(150))
            s.endedWatermark()
            try? await Task.sleep(for: .milliseconds(k % 3 == 0 ? 900 : 250))
            if k == 3 { s.switchWatermarkStage(onEdge.id, to: .full); try? await Task.sleep(for: .milliseconds(300)); s.switchWatermarkStage(onEdge.id, to: .base) }
            if k == 5 { s.changeWatermark(onEdge.id) { $0.on = false }; try? await Task.sleep(for: .milliseconds(300)); s.changeWatermark(onEdge.id) { $0.on = true } }
        }
        _ = await MacMasksCheck.developed(s, model, from: nil)
        await MacMasksCheck.capture("canvas-owner-session")
        if s.movingMarks != nil { odd.append("a gesture left open") }
        if s.developed == nil || s.developedCGImage == nil { odd.append("no picture") }
        if let p = s.edit.watermarks.first, !s.developedBaseMarks.contains(p) { odd.append("the picture at rest is not of the mark") }
        facts["owner_session"] = odd
        check(odd.isEmpty, "the owner's session: at rest the page shows the develop of the edit (\(odd))")
        return ["failures": failures, "facts": facts]
    }
}
#endif
