//  MacMaskFindCheck.swift — 主体 · 背景 · 人, 组合蒙版, 完善蒙版…, the geometry mark and the found masks' files in the
//  running app (design/masks/MASKS-SPEC.md §4.3, §6.4, §6.5, §7, §12's table; PRD-E §7 items 5, 6, 8; RFC-052 §5, §8.2;
//  traps 26, 33, 34): `--masks-check`'s M1c cases, run from `MacMasksCheck.walk` (run 1) and `MacMasksCheck.kept`
//  (run 2).
//
//  **How far it reaches.** A find goes through what the buttons call (`MaskFinding.find`, `.openPeople`,
//  `.choosePerson`, `.findAgain`, `.keepAsIs`), with Apple's Vision on this Mac on the frame's own file — a RAW's
//  decode, with and without lens correction — so the request inside the Catalyst process, the rendition, the file, the
//  layer act and its step are the app's. The popovers are opened by their own state (`MaskTools.combineOpen`,
//  `.refineOpen`, `MaskFinding.peopleOpen`) and captured from the window server; their rows call the functions above.
//  Clone Variant is pressed in the Image menu, as a person does. On A (the RAW) and B (`plain_bund.jpg`, a person):
//
//    - **unavailable**: a detector that is not there (`UnavailableDetector`): no layer, the buttons stand down with the
//      reason, the foot's line;
//    - **主体** in 场景 (冲洗) while it is looked for: 正在查找 (a slowed detector, captured for drawing 16), then 主体 1,
//      picked, its file written, one step; Undo takes it, Redo brings the same file's name back;
//    - **背景**: the same file, inverted; **背景 + 主体 covers the frame exactly** (their planes sum to 65,535 ± 1);
//    - **canvas is export** for a found subject in each stage: block means (bar 3) and the mask's edge in the same
//      place to a pixel of the smaller picture (the effect's region in both, every disagreeing pixel with an agreeing
//      one beside it);
//    - **人**: the menu with its count and rows (drawing 10, a row lit), 人物 1 and 全部人物 made from it;
//    - **组合蒙版**: 加, 减去 and 相交 of 主体 onto 背景 1 (the whole frame, 背景 alone, nothing), and a drawn tool lit with
//      减去 (its pill and its part's join); drawing 08;
//    - **完善蒙版…**: open, the mask alone on the picture; a feather drag is one step and changes the plane; closed, the
//      view back (drawing 09);
//    - **the geometry mark**: 镜头校正 switched after a find marks the row and the page (drawing 14); 保持现状 clears it;
//      switched again and 重新查找: a new file, the mark cleared, Undo the old file back;
//    - **RAW with lens correction on**: the found plane on the subject of the canvas as developed (Vision's subject of the
//      canvas picture, IoU at ½), beside the same frame found with lens correction off;
//    - **the files**: a missing file marks its row and the page and clears when it is back; *Clear Working Copies* and
//      the launch's tidy lose none; Clone Variant (the Image menu) adopts A's file into its own folder; the clone removed
//      takes its folder and leaves A's;
//    - **kept** (run 2, on B): rows, names, opacity, stage and each found plane byte-equal after a relaunch, and an Undo
//      of 主体 after it.
//
//  `--masks-check-break find-<rule>` breaks one rule of `MaskFinding` (`MaskFindingProbe.broken`) and runs these cases
//  alone: red.

#if DEBUG && SPK_ENGINE
import CoreGraphics
import CryptoKit
import Foundation
import UIKit
import Vision

@MainActor
enum MacMaskFindCheck {
    typealias R = MacMasksCheck.Report
    static var finding: MaskFinding { .shared }
    static var tools: MaskTools { .shared }

    /// A detector slowed by `seconds`: what keeps 正在查找 on the button long enough to be captured.
    struct Slowed: MaskDetector {
        var inner: any MaskDetector = VisionDetector()
        var seconds: Double
        func subject(_ image: CGImage) async throws -> FoundPicture? { try await Task.sleep(for: .seconds(seconds)); return try await inner.subject(image) }
        func persons(_ image: CGImage) async throws -> [FoundPicture] { try await Task.sleep(for: .seconds(seconds)); return try await inner.persons(image) }
        func people(_ image: CGImage) async throws -> FoundPicture? { try await inner.people(image) }
    }

    struct FoundKept: Codable {
        var frame: UUID
        var rows: [MacMasksCheck.KeptRow]
        /// Each layer's plane, SHA-256 of its 16-bit values, by layer name.
        var planes: [String: String]
        var assets: [String]
        var beforeLast: [MacMasksCheck.KeptRow]
    }

    // MARK: helpers

    static func use(_ finder: SubjectFinder, _ s: OpenFrameSession) async {
        finding.useFinder(finder)
        finding.pageOpened(s)
        await MacMasksCheck.pause(0.3)
    }

    /// The find under way ends (a layer landed, or a line said why).
    static func landed() async { _ = await MacMasksCheck.until(90, every: 50) { finding.finding == nil } ; await MacMasksCheck.pause(0.3) }

    static func plane(_ s: OpenFrameSession, _ id: UUID?) async -> [UInt16]? {
        guard let id, let l = s.edit.layers?[id], let src = s.frame?.originalSize else { return nil }
        return await MacMasksCheck.plane(l, src)
    }

    static func hash(_ v: [UInt16]) -> String {
        v.withUnsafeBytes { SHA256.hash(data: Data($0)) }.map { String(format: "%02x", $0) }.joined()
    }

    static func assets(_ s: OpenFrameSession) -> Set<String> { FoundMaskKeeping.assets(s.edit.layers) }

    /// 镜头校正 switched on every RAW photograph of the library, each a step of its own (`elsewhere`), as 2.3's
    /// Settings switch did. Since 2.4.0 it is each frame's own control and no launch holds a frame to a setting
    /// (`AppServices.holdLensCorrection` is gone), so the next launch records no step of its own either (M1c review
    /// item 1).
    static func setLens(_ m: AppServices, _ on: Bool) {
        let moved = m.library.frames.filter { $0.isRAW && !$0.isComposite && !$0.isDemo && $0.edit.decode.lensCorrection != on }.map(\.id)
        guard !moved.isEmpty else { return }
        for id in moved { m.change(id, as: .elsewhere, HistoryLabel("Lens correction")) { $0.decode.lensCorrection = on } }
        m.decodesChanged(Set(moved))
    }
    /// A's switch as the run found it, put back at its end.
    static var lensAsFound: Bool?

    /// Whether `frame`'s own folder holds the file (`FoundMaskFiles.url` would find it in any folder: found by the
    /// self-test's find-adopt, which it let through).
    static func fileExists(_ asset: String, in frame: UUID) async -> Bool {
        guard let folder = await FoundMaskFiles.shared.folder else { return false }
        let own = folder.appendingPathComponent(frame.uuidString).appendingPathComponent(FoundMaskFiles.fileName(asset))
        return FileManager.default.fileExists(atPath: own.path)
    }

    /// The share of texels of `a` at ½ or more that `b` also has at ½ or more, and the IoU.
    static func iou(_ a: [UInt16], _ b: [UInt16]) -> Double {
        var i = 0, u = 0
        for k in 0..<min(a.count, b.count) {
            let x = a[k] >= 32768, y = b[k] >= 32768
            if x && y { i += 1 }
            if x || y { u += 1 }
        }
        return u == 0 ? 0 : Double(i) / Double(u)
    }

    /// Where the effect of a layer is, as a binary picture at `w × h`: the luma difference past half its 99th
    /// percentile.
    static func region(_ layered: CGImage, _ plain: CGImage, long: Int) -> (w: Int, h: Int, on: [Bool])? {
        guard let f = MacMaskToolsCheck.difference(layered, plain, long: long) else { return nil }
        let sorted = f.d.sorted()
        let top = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        guard top > 4 else { return nil }
        return (f.w, f.h, f.d.map { $0 > top / 2 })
    }

    /// The effect as a map (0…1: the luma difference over its 99th percentile), at `long`.
    static func effectMap(_ layered: CGImage, _ plain: CGImage, long: Int) -> (w: Int, h: Int, v: [Double])? {
        guard let f = MacMaskToolsCheck.difference(layered, plain, long: long) else { return nil }
        let top = f.d.sorted()[min(f.d.count - 1, Int(Double(f.d.count) * 0.99))]
        guard top > 4 else { return nil }
        return (f.w, f.h, f.d.map { min($0 / top, 1) })
    }

    /// **Where the effect sits**, apart from its edge's profile: the shift (−2…2 px, quarter steps) of `b` that best lays
    /// it on `a` over `a`'s edge band (0.1–0.9), by least squares on maps scaled to agree in the band's mean. A mapping
    /// that put the mask elsewhere moves this; a soft edge rendered softer or harder at another resolution does not.
    static func bestShift(_ a: (w: Int, h: Int, v: [Double]), _ b: (w: Int, h: Int, v: [Double])) -> (dx: Double, dy: Double)? {
        guard a.w == b.w, a.h == b.h else { return nil }
        var band: [Int] = []
        for i in 0..<a.v.count where a.v[i] > 0.1 && a.v[i] < 0.9 { band.append(i) }
        guard band.count > 50 else { return nil }
        if band.count > 40_000 { band = stride(from: 0, to: band.count, by: band.count / 40_000 + 1).map { band[$0] } }
        func sample(_ x: Double, _ y: Double) -> Double? { MacMaskFlatCheck.sample(b.v, b.w, b.h, x, y) }
        var best: (Double, Double, Double)? = nil
        for iy in -8...8 { for ix in -8...8 {
            let dx = Double(ix) / 4, dy = Double(iy) / 4
            var sse = 0.0, n = 0
            for i in band {
                let x = Double(i % a.w) + 0.5 + dx, y = Double(i / a.w) + 0.5 + dy
                guard let v = sample(x, y) else { continue }
                sse += (v - a.v[i]) * (v - a.v[i]); n += 1
            }
            guard n > 0 else { continue }
            let e = sse / Double(n)
            if best == nil || e < best!.2 { best = (dx, dy, e) }
        } }
        return best.map { ($0.0, $0.1) }
    }

    /// Two regions' edges agree to a pixel: every pixel where they differ has, within one pixel, one where the other
    /// says the same as this. The disagreements past a pixel, and how many pixels differ at all.
    static func edgeAgreement(_ a: (w: Int, h: Int, on: [Bool]), _ b: (w: Int, h: Int, on: [Bool])) -> (far: Int, differ: Int, edge: Int) {
        guard a.w == b.w, a.h == b.h else { return (Int.max, 0, 0) }
        var far = 0, differ = 0, edge = 0
        for y in 0..<a.h { for x in 0..<a.w {
            let i = y * a.w + x
            // The edge's length: pixels of a with a neighbour of the other value.
            if x + 1 < a.w, a.on[i] != a.on[i + 1] { edge += 1 }
            guard a.on[i] != b.on[i] else { continue }
            differ += 1
            var near = false
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < a.w, yy < a.h else { continue }
                if b.on[yy * a.w + xx] == a.on[i] || a.on[yy * a.w + xx] == b.on[i] { near = true }
            } }
            if !near { far += 1 }
        } }
        return (far, differ, edge)
    }

    // MARK: run 1

    static func run(_ m: AppServices, _ r: R, a: LibraryFrame, b: LibraryFrame, out: URL, broken: String?) async {
        let rule = broken?.hasPrefix("find-") == true ? String(broken!.dropFirst("find-".count)) : nil
        MaskFindingProbe.broken = rule
        defer { MaskFindingProbe.broken = nil }
        guard let s = await MacMasksCheck.develop(m, a.id) else { return r.check(false, "find: A opens in Develop") }
        s.show(.develop)
        lensAsFound = m.library.frame(a.id)?.edit.decode.lensCorrection
        setLens(m, false)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        tools.putDown(); tools.held = false; tools.alone = false
        await MacMasksCheck.settle(m)

        await unavailable(r, s)
        await subjectAndBackground(m, r, s, a: a, capture: rule == nil)
        if rule == nil { await canvasIsExport(m, r, a: a, out: out) }
        await combine(m, r, s: m.openSession(a.id) ?? s, a: a, capture: rule == nil)
        if rule == nil {
            await people(m, r, a: a)
            await refine(m, r, a: a)
        }
        await geometryMark(m, r, a: a, capture: rule == nil)
        if rule == nil { await lensCorrectionOn(m, r, a: a, out: out) }
        await files(m, r, a: a, picture: b.developSource, out: out)
        if rule == nil { await keptRun1(m, r, b: b, out: out) }
        if let s = m.openSession(a.id) { s.change { $0.layers = nil } }
        if let was = lensAsFound { setLens(m, was) }
        tools.putDown(); tools.held = false; tools.alone = false; tools.combineOpen = false; tools.refineOpen = nil
    }

    // MARK: unavailable

    static func unavailable(_ r: R, _ s: OpenFrameSession) async {
        await use(SubjectFinder(detector: UnavailableDetector()), s)
        let before = s.edit.layers?.items.count ?? 0
        finding.find(.subject, session: s)
        await landed()
        finding.find(.people, session: s)
        await landed()
        let why = finding.unavailable[.subject], whyPeople = finding.unavailable[.people]
        r.check(why != nil && whyPeople != nil && !finding.takes(.subject) && !finding.takes(.background) && !finding.takes(.people)
                && (s.edit.layers?.items.count ?? 0) == before && s.maskNote == L("Finding subjects and people is not available on this Mac."),
                "unavailable: a request this Mac cannot run stands its buttons down, makes no layer, says so",
                "reason \(why ?? "nil"); foot \"\(s.maskNote ?? "")\"; the button's help \"\(L("not available on this Mac"))\"")
        await use(SubjectFinder(), s)
        s.maskNote = nil
    }

    // MARK: 主体 and 背景

    static func subjectAndBackground(_ m: AppServices, _ r: R, _ s: OpenFrameSession, a: LibraryFrame, capture: Bool) async {
        // 正在查找 while it looks: slowed, for the window's capture (drawing 16's finding state).
        await use(SubjectFinder(detector: Slowed(seconds: capture ? 9 : 1)), s)
        let before = await MacMaskToolsCheck.steps(m, a.id)
        finding.find(.subject, session: s)
        let lookingNow = finding.finding == .subject && !finding.takes(.background)
        if capture { await MacMasksCheck.captured("16-finding") }
        await landed()
        await use(SubjectFinder(), s)
        guard let id = s.layerPick.maskID, let layer = s.edit.layers?[id], let part = layer.parts.first, let asset = part.asset else {
            return r.check(false, "主体: a layer landed", "foot \"\(s.maskNote ?? "")\"")
        }
        let after = await MacMaskToolsCheck.steps(m, a.id)
        let onDisk = await fileExists(asset, in: a.id)
        r.check(lookingNow, "主体: while it looks the button says 正在查找 and the other two wait")
        r.check(layer.name == MaskRules.name(.subject, among: LocalLayers()) && layer.stage == .scene && layer.parts.count == 1 && part.kind == .found
                && part.found?.what == .subject && part.found?.invert == false && onDisk && after == before + 1 && s.layerPick == .mask(id),
                "主体 in 冲洗: \(layer.name), 场景, picked, one found part, its file written, one step of Undo",
                "asset \(asset), on disk \(onDisk), steps \(before) → \(after)")
        _ = s.undo(); await MacMasksCheck.pause(0.4)
        let undone = s.edit.layers?[id] == nil
        _ = s.redo(); await MacMasksCheck.pause(0.4)
        r.check(undone && s.edit.layers?[id]?.parts.first?.asset == asset,
                "主体: Undo takes the layer away, Redo brings it back with its file's name (\(asset.prefix(8))…)")

        // 背景: the same file, the part inverted; the two planes sum to the whole frame.
        s.pick(row: .film)
        finding.find(.background, session: s)
        await landed()
        guard let bid = s.layerPick.maskID, bid != id, let bl = s.edit.layers?[bid], let bp = bl.parts.first else {
            return r.check(false, "背景: a layer landed")
        }
        r.check(bl.name == MaskRules.name(.background, among: LocalLayers()) && bp.asset == asset && bp.found?.invert == true,
                "背景: \(bl.name), the same file as 主体's, the part inverted", "asset \(bp.asset ?? "nil"), invert \(bp.found?.invert == true)")
        guard let ps = await plane(s, id), let pb = await plane(s, bid), ps.count == pb.count else {
            return r.check(false, "背景 + 主体: the planes")
        }
        var worst = 0
        for k in 0..<ps.count { worst = max(worst, abs(Int(ps[k]) + Int(pb[k]) - 65535)) }
        r.check(worst <= 1, "背景 + 主体 covers the frame exactly: the planes sum to 65,535 at every texel", "worst \(worst) counts over \(ps.count) texels")
    }

    // MARK: canvas is export

    static func canvasIsExport(_ m: AppServices, _ r: R, a: LibraryFrame, out: URL) async {
        for stage in [LayerStage.scene, .finished] {
            guard let s = m.openSession(a.id) else { return r.check(false, "found canvas is export: A") }
            s.show(stage == .scene ? .develop : .edit)
            // Grain, halation and glare off: the Full export's grain, read at the canvas's size, is not the canvas's grain
            // (trap 1), and on a found mask's soft edge it moved the effect's ½ by more than a pixel at 11–17 of ~6,000
            // edge pixels (2026-11-13). Put back after.
            let effects = s.edit.params.effects
            s.change { $0.layers = nil; $0.params.effects.grain = 0; $0.params.effects.halation = 0; $0.params.effects.glare = 0 }
            defer { s.change { $0.params.effects = effects } }
            s.pick(row: .film)
            await MacMasksCheck.settle(m)
            finding.find(.subject, session: s)
            await landed()
            guard let id = s.layerPick.maskID, s.edit.layers?[id]?.stage == stage else {
                r.check(false, "found canvas is export (\(stage.rawValue)): 主体 made in the stage of the mode in front"); continue
            }
            let stamp = s.developed?.stamp
            s.changeLayer(id) { l in if stage == .scene { l.scene?.exposure = 1.5 } else { l.finished?.exposure = 1.5 } }
            if stage == .scene { _ = await MacMasksCheck.until(90, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp } }
            await MacMasksCheck.settle(m)
            let plainStamp = s.developed?.stamp
            guard let layered = await MacMaskToolsCheck.canvas(s, m, stage: stage) else { r.check(false, "found canvas is export (\(stage.rawValue)): the canvas"); continue }
            let edge = max(layered.width, layered.height), tag = stage.rawValue
            guard let exported = await MacMaskToolsCheck.export(m, a.id, longEdge: edge, to: out.appendingPathComponent("found-export-\(tag).png")) else {
                r.check(false, "found canvas is export (\(tag)): the export landed"); continue
            }
            // And at Full: the original's size, read at the canvas's (the mask's edge to a pixel of the smaller).
            let full = await MacMaskToolsCheck.export(m, a.id, longEdge: a.originalSize.longEdge, to: out.appendingPathComponent("found-export-\(tag)-full.png"))
            s.setLayerOn(id, false)
            if stage == .scene { _ = await MacMasksCheck.until(90, every: 100) { s.developed?.stamp != plainStamp && !s.isCatchingUp } }
            await MacMasksCheck.settle(m)
            let plain = s.developedCGImage
            let plainExport = await MacMaskToolsCheck.export(m, a.id, longEdge: edge, to: out.appendingPathComponent("found-export-\(tag)-plain.png"))
            let plainFull = await MacMaskToolsCheck.export(m, a.id, longEdge: a.originalSize.longEdge, to: out.appendingPathComponent("found-export-\(tag)-full-plain.png"))
            s.setLayerOn(id, true)
            guard let plain, let plainExport else { r.check(false, "found canvas is export (\(tag)): the plain pictures"); continue }
            let d = MacMasksCheck.difference(layered, exported), moved = MacMasksCheck.difference(layered, plain)
            r.check(d.mean <= 3 && moved.mean > 3 * d.mean + 0.3, "found canvas is export (\(tag)): 主体 at +1.5, the canvas against the export at its size",
                    String(format: "mean %.2f, worst %.2f codes (bar 3); the layer moves the canvas %.2f; %dx%d", d.mean, d.worst, moved.mean, exported.width, exported.height))
            if let c = region(layered, plain, long: edge), let e = region(exported, plainExport, long: edge) {
                let g = edgeAgreement(c, e)
                r.check(g.far == 0 && g.edge > 0, "found canvas is export (\(tag)): the subject's edge in the same place to a pixel of the smaller picture",
                        "\(g.differ) pixels differ, \(g.far) of them more than a pixel from agreement; the edge \(g.edge) px long, at \(c.w)x\(c.h)")
            } else {
                r.check(false, "found canvas is export (\(tag)): the effect's region")
            }
            // At Full the film is developed at the original's size, and a found mask's soft edge comes out with another
            // profile (the ½ crossing moved by more than a pixel at 121 of 8,463 edge pixels in 场景, 1 of 9,611 in 成片,
            // 2026-11-13; the brush's hard edge, M1b's case, agrees to a pixel). What is held is where the effect sits:
            // the best-fitting shift of the Full export's effect onto the canvas's, within half a pixel of the smaller.
            if let full, let plainFull, let c = region(layered, plain, long: edge), let e = region(full, plainFull, long: edge),
               let cm = effectMap(layered, plain, long: edge), let em = effectMap(full, plainFull, long: edge), let shift = bestShift(cm, em) {
                let g = edgeAgreement(c, e)
                let apart = hypot(shift.dx, shift.dy)
                // The measure can fail: the canvas's own map moved one pixel right is found one pixel away.
                var moved = cm
                for y in 0..<cm.h { for x in 0..<cm.w { moved.v[y * cm.w + x] = x > 0 ? cm.v[y * cm.w + x - 1] : cm.v[y * cm.w] } }
                let probe = bestShift(cm, moved)
                r.check(probe.map { abs($0.dx - 1) <= 0.25 && abs($0.dy) <= 0.25 } == true,
                        "found canvas is export (\(tag)) at Full: the placement measure finds a one-pixel move of the canvas's own map",
                        probe.map { String(format: "(%+.2f, %+.2f)", $0.dx, $0.dy) } ?? "nil")
                r.check(apart <= 0.5, "found canvas is export (\(tag)) at Full: the subject's effect sits where the canvas's does, within half a pixel of the smaller picture",
                        String(format: "best shift (%+.2f, %+.2f) px; the ½ crossing: %d pixels differ, %d more than a pixel from agreement (the edge's profile at Full); the export %dx%d read at %dx%d",
                               shift.dx, shift.dy, g.differ, g.far, full.width, full.height, c.w, c.h))
            } else {
                r.check(false, "found canvas is export (\(tag)) at Full: the exports")
            }
            s.change { $0.layers = nil }
            await MacMasksCheck.settle(m)
        }
        m.openSession(a.id)?.show(.develop)
    }

    // MARK: 人

    static func people(_ m: AppServices, _ r: R, a: LibraryFrame) async {
        guard let s = m.openSession(a.id) else { return }
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await MacMasksCheck.settle(m)
        finding.openPeople(s)
        let looked = finding.finding == .people
        await landed()
        _ = await MacMasksCheck.until(10) { finding.peopleOpen }
        let count = finding.people?.count ?? -1
        r.check(looked && finding.peopleOpen && count >= 1 && finding.people?.all != nil,
                "人: the first click looks, then opens the menu: 全部人物 and \(count) person(s)")
        _ = await MacMasksCheck.until(5) { !finding.thumbnails.isEmpty }
        finding.hovered = 1
        _ = await MacMasksCheck.until(10) { MaskOverlay.shared.made?.layer == MaskFinding.previewID }
        r.check(MaskOverlay.shared.made?.layer == MaskFinding.previewID && MaskOverlay.shared.made?.mode == .overlay,
                "人: the row under the pointer lights that person in the overlay on the picture")
        await MacMasksCheck.captured("10-people")
        finding.choosePerson(1, session: s)
        await MacMasksCheck.pause(0.4)
        let p1 = s.pickedMaskLayer
        finding.peopleOpen = false
        s.pick(row: .film)
        // The second time it opens at once, from what was found.
        finding.openPeople(s)
        let atOnce = finding.peopleOpen && finding.finding == nil
        finding.choosePerson(0, session: s)
        await MacMasksCheck.pause(0.4)
        let all = s.pickedMaskLayer
        r.check(p1?.name == MaskRules.personName(1, among: nil) && p1?.parts.first?.found?.what == .person && atOnce
                && all?.name == L("All People") && all?.parts.first?.found?.what == .people,
                "人: a row makes 人物 1, the second click opens at once, 全部人物 makes 全部人物", "\(p1?.name ?? "nil"), \(all?.name ?? "nil")")
        s.change { $0.layers = nil }
    }

    // MARK: 组合蒙版

    static func combine(_ m: AppServices, _ r: R, s: OpenFrameSession, a: LibraryFrame, capture: Bool) async {
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await MacMasksCheck.settle(m)
        finding.find(.background, session: s)
        await landed()
        guard let id = s.layerPick.maskID, let background = await plane(s, id) else { return r.check(false, "组合蒙版: 背景 1") }
        if capture {
            tools.combineOpen = true
            await MacMasksCheck.captured("08-combine-masks")
            tools.combineOpen = false
            await MacMasksCheck.pause(0.5)
        }
        var results: [(String, Bool, String)] = []
        for (join, name) in [(MaskPart.Join.add, "加"), (.subtract, "减去"), (.intersect, "相交")] {
            let count = s.edit.layers?.items.count ?? 0
            finding.find(.subject, session: s, join: join)
            await landed()
            let parts = s.edit.layers?[id]?.parts ?? []
            guard (s.edit.layers?.items.count ?? 0) == count, parts.count == 2, parts[1].join == join, let p = await plane(s, id) else {
                results.append((name, false, "parts \(parts.map { MaskRules.title($0) }), layers \(s.edit.layers?.items.count ?? 0)")); _ = s.undo(); continue
            }
            // What the fold makes of the two (RFC-052 §4.2, the products: `mask_fold`): 背景's plane a, 主体's k alone.
            var alone = LocalLayer(name: "k", stage: .scene, parts: [parts[1]])
            alone.parts[0].join = .add
            guard let k = await MacMasksCheck.plane(alone, a.originalSize), k.count == p.count else {
                results.append((name, false, "主体's plane")); _ = s.undo(); continue
            }
            var worst = 0
            for i in 0..<p.count {
                let x = Double(background[i]) / 65535, y = Double(k[i]) / 65535
                let e = join == .add ? x + y - x * y : join == .subtract ? x * (1 - y) : x * y
                worst = max(worst, abs(Int(p[i]) - Int((e * 65535).rounded())))
            }
            let mean = Double(p.reduce(0) { $0 + Int($1) }) / Double(p.count) / 65535
            let ok = worst <= 2
            results.append((name, ok, String(format: "the plane against 背景 %@ 主体 by the products, worst %d counts; mean %.4f", name, worst, mean)))
            _ = s.undo(); await MacMasksCheck.pause(0.3)
        }
        for (name, ok, detail) in results {
            r.check(ok, "组合蒙版 \(name) with 主体 onto 背景 1: one part joined with \(name), no new layer, the plane the fold of the two (加 ≈ the whole frame, 减去 ≈ 背景, 相交 ≈ nothing)", detail)
        }
        // A drawn tool lit with a join: the pill says it, the part joins with it, until it is put down.
        tools.light(.linear)
        tools.join = .subtract
        let pill = MaskRules.pillLines(.linear, join: tools.join ?? .add, sizePixels: nil).first ?? ""
        MacMaskToolsCheck.gradient(s, a.id, .linear, from: MaskPoint(0.5, 0.2), to: MaskPoint(0.5, 0.5))
        let last = s.edit.layers?[id]?.parts.last
        tools.putDown()
        r.check(pill.hasPrefix(MaskRules.word(.subtract)) && last?.kind == .linear && last?.join == .subtract && tools.join == nil,
                "组合蒙版 then 线性渐变: the pill says \"\(pill)\", the drag joins with 减去, put down the join goes")
        s.change { $0.layers = nil }
    }

    // MARK: 完善蒙版…

    static func refine(_ m: AppServices, _ r: R, a: LibraryFrame) async {
        guard let s = m.openSession(a.id) else { return }
        s.pick(row: .film)
        finding.find(.subject, session: s)
        await landed()
        guard let id = s.layerPick.maskID, let before = await plane(s, id) else { return r.check(false, "完善蒙版…: 主体 1") }
        tools.alone = false
        tools.refineOpen = .panel
        let shown = await MacMasksCheck.until(10) { tools.alone && tools.aloneShown(s) }
        await MacMasksCheck.captured("09-refine-mask")
        // The drag with the popover open and the mask alone on the picture: what crashed (`MaskOverlay.render`'s copy).
        let steps0 = await MacMaskToolsCheck.steps(m, a.id)
        s.beganLayer()
        for v in stride(from: 0.002, through: 0.012, by: 0.002) { s.moveLayer(id) { $0.feather = v } }
        s.endedLayer()
        await MacMasksCheck.pause(0.5)
        let steps1 = await MacMaskToolsCheck.steps(m, a.id)
        let after = await plane(s, id)
        tools.refineOpen = nil
        let back = await MacMasksCheck.until(10) { !tools.alone }
        r.check(shown && back, "完善蒙版…: the mask alone while it is open, the view as it was when it closes")
        r.check(steps1 == steps0 + 1 && s.edit.layers?[id]?.feather == 0.012 && after != nil && after! != before
                && MaskRules.featherText(0.012) == "12",
                "完善蒙版…: a 羽化 drag is one step and changes the plane; the pill says 12", "steps \(steps0) → \(steps1)")
        s.change { $0.layers = nil }
    }

    // MARK: the geometry mark

    static func geometryMark(_ m: AppServices, _ r: R, a: LibraryFrame, capture: Bool) async {
        guard let s = m.openSession(a.id) else { return }
        s.show(.develop)
        setLens(m, false)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await MacMasksCheck.settle(m)
        finding.find(.subject, session: s)
        await landed()
        guard let id = s.layerPick.maskID, let old = s.edit.layers?[id]?.parts.first?.asset else { return r.check(false, "the geometry mark: 主体 1") }
        func marked() -> Bool { MacMasksCheck.rows(s).first { $0.pick == .mask(id) }?.marked ?? false }
        let clean = !marked()
        setLens(m, true)
        await MacMasksCheck.settle(m)
        let set = marked()
        if capture { await MacMasksCheck.captured("14-geometry-changed") }
        // 重新查找 on the decode as it is now (lens correction on): another rendition, another file.
        finding.findAgain(id, session: s)
        await MacMasksCheck.pause(0.2)
        await landed()
        let new = s.edit.layers?[id]?.parts.first?.asset
        let cleared = !marked()
        _ = s.undo(); await MacMasksCheck.pause(0.4)
        let undone = s.edit.layers?[id]?.parts.first?.asset
        let markedAgain = marked()
        r.check(clean && set && cleared && new != nil && new != old && undone == old && markedAgain,
                "the geometry mark: 镜头校正 switched after 主体 marks the row; 重新查找 — a new file, the mark cleared; Undo the old file and the mark back",
                "before \(!clean), after the switch \(set); old \(old.prefix(8)), new \(new?.prefix(8) ?? "nil"), after Undo \(undone?.prefix(8) ?? "nil")")
        finding.keepAsIs(id, session: s)
        await MacMasksCheck.pause(0.3)
        r.check(!marked() && s.edit.layers?[id]?.parts.first?.asset == old,
                "the geometry mark: 保持现状 clears it, the mask as it was")
        s.change { $0.layers = nil }
        setLens(m, false)
    }

    // MARK: a RAW with lens correction on

    static func lensCorrectionOn(_ m: AppServices, _ r: R, a: LibraryFrame, out: URL) async {
        guard let s = m.openSession(a.id) else { return }
        guard a.isRAW else { return r.unreached("lens correction: A is not a RAW") }
        var planes: [Bool: [UInt16]] = [:]
        for lens in [false, true] {
            let stamp = s.developed?.stamp
            s.change { $0.layers = nil }
            setLens(m, lens)
            if s.developed?.stamp == stamp, lens { _ = await MacMasksCheck.until(90, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp } }
            await MacMasksCheck.settle(m)
            s.pick(row: .film)
            finding.find(.subject, session: s)
            await landed()
            planes[lens] = await plane(s, s.layerPick.maskID)
        }
        // Vision's subject of the canvas as developed with lens correction on: where the subject is in the picture.
        guard let canvas = s.developedCGImage, let on = planes[true], let off = planes[false], let layer = s.pickedMaskLayer,
              let found = try? await VisionDetector().subject(canvas) else {
            return r.check(false, "lens correction on: the planes and the canvas's subject")
        }
        let size = MaskBaker.planeSize(source: a.originalSize, maxLongEdge: MaskBaker.maxLongEdge)
        // The canvas's subject resampled to the plane's size (nearest): A's canvas is the uncut frame.
        var seen = [UInt16](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height { for x in 0..<size.width {
            let fx = min(found.width - 1, x * found.width / size.width), fy = min(found.height - 1, y * found.height / size.height)
            seen[y * size.width + x] = UInt16(found.bytes[fy * found.width + fx]) * 257
        } }
        let withLens = iou(on, seen), without = iou(off, seen)
        r.check(withLens >= 0.9 && layer.madeOn.lensCorrection, "a RAW with lens correction on: 主体 found in S sits on the subject of the canvas",
                String(format: "IoU at ½ %.3f with the canvas's own subject (bar 0.9); the same frame found with lens correction off %.3f; plane %dx%d",
                       withLens, without, size.width, size.height))
        s.change { $0.layers = nil }
        setLens(m, false)
        await MacMasksCheck.settle(m)
    }

    // MARK: the files

    static func files(_ m: AppServices, _ r: R, a: LibraryFrame, picture: URL?, out: URL) async {
        guard let s = m.openSession(a.id) else { return }
        s.change { $0.layers = nil }
        s.pick(row: .film)
        finding.find(.subject, session: s)
        await landed()
        guard let id = s.layerPick.maskID, let asset = s.edit.layers?[id]?.parts.first?.asset,
              let url = await FoundMaskFiles.shared.url(asset, in: a.id) else { return r.check(false, "files: 主体 1 and its file") }
        // Missing: the row and the page say so; back, and the mark goes.
        let aside = url.deletingLastPathComponent().appendingPathComponent("aside.tmp")
        try? FileManager.default.moveItem(at: url, to: aside)
        finding.layersChanged(s)
        let marked = await MacMasksCheck.until(5) { finding.missing[id] != nil }
        try? FileManager.default.moveItem(at: aside, to: url)
        finding.layersChanged(s)
        let cleared = await MacMasksCheck.until(5) { finding.missing[id] == nil }
        r.check(marked && cleared, "a found mask whose file is missing marks its row and its page, and clears when the file is back")
        // Clear Working Copies and the launch's tidy.
        m.clearWorkingCopies()
        m.tidyStorage()
        await MacMasksCheck.pause(2)
        let gone = await FoundMaskFiles.shared.missing(assets(s))
        r.check(gone.isEmpty, "Clear Working Copies and the launch's tidy lose no found mask", "\(assets(s).count) named, \(gone.count) missing")
        // Clone Variant from the Image menu: its page adopts A's file into the clone's own folder.
        await m.history.drained()
        // Clone Variant, through the Image menu on a catalog's cell (`cloneThroughMenu`).
        await cloneThroughMenu(m, r, picture: picture, out: out)
        guard let back = await MacMasksCheck.develop(m, a.id) else { return }
        back.change { $0.layers = nil }
    }

    // MARK: Clone Variant through the Image menu

    /// A catalog made as `variant_check` makes one (`newCatalog`, `addFolder`) of a copy of B's picture; its cell's frame
    /// opened in 冲洗, 主体 found; then the Image menu's Clone Variant pressed as a person presses it, on the open frame's
    /// cell (`MacVariantActions.menuCells` → `store.newVariant`): the clone names the file, and its page adopts it into
    /// the clone's own folder; the clone removed takes its folder and leaves the original's file.
    static func cloneThroughMenu(_ m: AppServices, _ r: R, picture: URL?, out: URL) async {
        let store = m.macLibrary, fm = FileManager.default
        guard let picture else { return r.check(false, "Clone Variant: B's picture to put in a catalog") }
        await store.start()
        let work = out.appending(path: "catalog-work")
        try? fm.removeItem(at: work)
        let card = work.appending(path: "Card")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: picture, to: card.appending(path: "V1.jpg"))
        do {
            let cat = try await store.newCatalog(named: "Masks", in: work)
            try await store.addFolder(card, to: cat.id)
        } catch { return r.check(false, "Clone Variant: a catalog", "\(error)") }
        _ = await MacMasksCheck.until(30) { store.images.contains { $0.fileName == "V1.jpg" } }
        await store.select(collection: store.tree.defaultSelection)
        _ = await MacMasksCheck.until(20) { store.images.contains { $0.fileName == "V1.jpg" } }
        guard let cell = store.images.first(where: { $0.fileName == "V1.jpg" }),
              let made = try? await store.frames(for: [cell.id], focus: nil).frames, let frame = made[cell.id] else {
            return r.check(false, "Clone Variant: the catalog's picture has a frame")
        }
        guard let s = await MacMasksCheck.develop(m, frame) else { return r.check(false, "Clone Variant: the catalog's frame opens") }
        s.pick(row: .film)
        finding.find(.subject, session: s)
        await landed()
        guard let asset = s.edit.layers?.items.first?.parts.first?.asset else { return r.check(false, "Clone Variant: 主体 on the catalog's frame") }
        await m.history.drained()
        let before = Set(m.library.frames.map(\.id))
        let cells = MacVariantActions.menuCells(m)
        let pressed = await MacVariantActsCheck.press(L("Clone Variant"))
        _ = await MacMasksCheck.until(20) { Set(m.library.frames.map(\.id)).subtracting(before).count == 1 && !MacVariantActions.shared.busy }
        guard let clone = Set(m.library.frames.map(\.id)).subtracting(before).first else {
            return r.check(false, "Clone Variant from the Image menu makes a frame",
                           "pressed \(pressed), the menu's cells \(cells.count), refusal \(MacVariantActions.refusal(.clone, cells, model: m) ?? "none")")
        }
        let carried = FoundMaskKeeping.assets(m.library.frame(clone)?.edit ?? .default)
        _ = await MacMasksCheck.develop(m, clone)
        await MacMasksCheck.pause(1)
        let adopted = await fileExists(asset, in: clone)
        r.check(pressed && carried.contains(asset) && adopted,
                "Clone Variant (the Image menu, a catalog's cell): the clone's 主体 names the file, and its page adopts it into the clone's own folder",
                "the menu's cells \(cells.count); carried \(carried.contains(asset)), in the clone's folder \(adopted)")
        m.router.toLibrary()
        await MacMasksCheck.pause(1.5)
        m.remove([clone])
        await MacMasksCheck.pause(2)
        guard let folder = await FoundMaskFiles.shared.folder else { return }
        let gone = !fm.fileExists(atPath: folder.appendingPathComponent(clone.uuidString).path)
        let stays = await fileExists(asset, in: frame)
        r.check(gone && stays, "a frame removed takes its found masks' folder and leaves another frame's file",
                "the clone's folder gone \(gone), the original's file there \(stays)")
    }

    // MARK: kept

    static func keptRun1(_ m: AppServices, _ r: R, b: LibraryFrame, out: URL) async {
        guard let s = await MacMasksCheck.develop(m, b.id) else { return r.check(false, "found kept: B opens") }
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await MacMasksCheck.settle(m)
        finding.find(.background, session: s)
        await landed()
        if let x = s.layerPick.maskID { s.switchStage(x, to: .finished); s.changeLayer(x) { $0.opacity = 0.7; $0.finished?.exposure = 0.5 } }
        s.pick(row: .film)
        let beforeLast = MacMasksCheck.keptRows(s.edit.layers)
        finding.find(.subject, session: s)
        await landed()
        await MacMasksCheck.settle(m)
        await m.history.drained()
        var planes: [String: String] = [:]
        for l in s.edit.layers?.items ?? [] { if let p = await MacMasksCheck.plane(l, b.originalSize) { planes[l.name] = hash(p) } }
        let k = FoundKept(frame: b.id, rows: MacMasksCheck.keptRows(s.edit.layers), planes: planes, assets: Array(assets(s)).sorted(), beforeLast: beforeLast)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(k).write(to: out.appendingPathComponent("found-kept.json"))
        r.check(planes.count == 2 && k.rows.count == 2, "found kept: written", k.rows.map(\.name).joined(separator: ", "))
        // The library and layers.json written as the page leaves, before the run ends.
        m.router.toLibrary()
        await MacMasksCheck.pause(1.5)
        m.library.flush()
        await m.history.drained()
    }

    // MARK: run 2

    static func kept(_ m: AppServices, _ r: R, run1: URL) async {
        guard let data = try? Data(contentsOf: run1.appendingPathComponent("found-kept.json")),
              let k = try? JSONDecoder().decode(FoundKept.self, from: data) else { return r.check(false, "found kept: run 1's found-kept.json") }
        guard let frame = m.library.frame(k.frame) else { return r.check(false, "found kept: B is in the library") }
        let rows = MacMasksCheck.keptRows(frame.edit.layers)
        var planes: [String: String] = [:]
        for l in frame.edit.layers?.items ?? [] { if let p = await MacMasksCheck.plane(l, frame.originalSize) { planes[l.name] = hash(p) } }
        let missing = await FoundMaskFiles.shared.missing(Set(k.assets))
        r.check(rows == k.rows && planes == k.planes && missing.isEmpty,
                "found kept: after a relaunch the rows, names, opacity, stage and each found mask's picture byte-equal",
                "\(rows.map(\.name)); planes equal \(planes == k.planes); files missing \(missing.count)")
        guard let s = await MacMasksCheck.develop(m, k.frame) else { return r.check(false, "found kept: B opens") }
        _ = s.undo()
        await MacMasksCheck.pause(0.5)
        let undone = MacMasksCheck.keptRows(s.edit.layers) == k.beforeLast
        _ = s.redo()
        await MacMasksCheck.pause(0.5)
        var redone: [String: String] = [:]
        for l in s.edit.layers?.items ?? [] { if let p = await MacMasksCheck.plane(l, frame.originalSize) { redone[l.name] = hash(p) } }
        r.check(undone && MacMasksCheck.keptRows(s.edit.layers) == k.rows && redone == k.planes,
                "found kept: an Undo of 主体 after the relaunch takes it away; Redo brings it and its picture back")
    }
}
#endif
