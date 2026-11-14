//  MacMaskToolsCheck.swift — the mask tools on the picture in the running app (design/masks/MASKS-SPEC.md §6, §8, §12's
//  table rows 5, 6, 7; PRD-E §7 items 5, 6, 9, 10; traps 26, 27, 33, 34): `--masks-check`'s M1b cases, run from
//  `MacMasksCheck.walk` (run 1) and `MacMasksCheck.kept` (run 2).
//
//  **How far it reaches.** Strokes and gradient drags go through the tools' own code (`MaskTools.beginStroke` /
//  `continueStroke` / `beginGradient` / `continueGradient` / `endDrag`, what `MaskStage`'s drag calls with the points
//  it has mapped), so the one-step drag, the layer made by the first event, the join and the overlay are the app's;
//  the pointer's mapping is held by comparing the stage's own placement (`MaskStageProbe.placed`: the rect and the
//  matrix the canvas handed it) against the picture the engine and the pass made. The keys are pressed for real by
//  the shell (`tools/post_keys.swift`, to this process: "KEYS READY"). A real pointer drag is posted by the shell too
//  (`tools/post_pointer.swift`, "POINTER READY"); whether it lands is reported as it is, not assumed.
//
//    - **5 canvas is export**: a hard brush stroke and a linear gradient in each stage; the canvas (the 场景 develop, or
//      Edit's pass on it) against the exported file at the canvas's size, 16 × 16 block means (bar 3, the 图层
//      check's), the layer's own move beside it; and the stroke's edge, row by row, within a pixel of the smaller
//      picture's — at the live tier (an export at the canvas's size) and at Full (an export at the original's size).
//    - **6 geometry**: a stroke on a 成片 layer, then 冲洗's crop, 编辑's crop, a straighten, a quarter turn, a flip, a
//      film edge: the overlay's centroid (as drawn, in the view) on the developed effect's centroid (as the canvas
//      shows it); paint → crop → reopen leaves the stroke's points where they were. `--masks-check-break geometry-<term>`
//      drops one term of the stage's matrix (`MaskStageProbe.broken`): red.
//    - **7 every surface**: with the overlay held and with the mask alone, the kept develop, Edit's pass, the histogram
//      and an export are byte-same as with neither; one stroke and one handle drag are one step each; Undo and Redo
//      through them; run 2 undoes the last stroke after the relaunch.
//    - **cost**: a stroke's turnaround to the overlay, and a 场景 stroke's time to the developed picture at the live
//      tier, on a 45 MP and a 24 MP frame, interleaved, the load beside them.
//    - **captures** of drawings 04, 05, 06, 07 in English and 简体中文.

#if DEBUG && SPK_ENGINE
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import UIKit

@MainActor
enum MacMaskToolsCheck {
    typealias R = MacMasksCheck.Report
    static var tools: MaskTools { .shared }

    // MARK: the tools, as the stage's drag calls them

    static func stroke(_ s: OpenFrameSession, _ frame: UUID, _ points: [MaskPoint], tool: MaskTool = .brush) {
        guard let src = s.frame?.originalSize else { return }
        tools.light(tool); tools.optionHeld = false
        guard tools.beginStroke(s, at: points[0], frame: frame, straight: false) else { return }
        for p in points.dropFirst() { tools.continueStroke(s, to: p, metric: MaskMetric(source: src)) }
        tools.endDrag(s, frame: frame)
    }

    static func gradient(_ s: OpenFrameSession, _ frame: UUID, _ tool: MaskTool, from: MaskPoint, to: MaskPoint) {
        guard let src = s.frame?.originalSize else { return }
        let m = MaskMetric(source: src)
        tools.light(tool)
        tools.beginGradient(s, grip: nil, at: m.metric(from))
        tools.continueGradient(s, to: m.metric(MaskPoint((from.x + to.x) / 2, (from.y + to.y) / 2)), shift: false, option: false, metric: m, minimum: 1e-4)
        tools.continueGradient(s, to: m.metric(to), shift: false, option: false, metric: m, minimum: 1e-4)
        tools.endDrag(s, frame: frame)
    }

    static func dragHandle(_ s: OpenFrameSession, _ frame: UUID, _ grip: GradientGrip, from: MaskPoint, to: MaskPoint) {
        guard let src = s.frame?.originalSize else { return }
        let m = MaskMetric(source: src)
        tools.beginGradient(s, grip: grip, at: m.metric(from))
        tools.continueGradient(s, to: m.metric(to), shift: false, option: false, metric: m, minimum: 1e-4)
        tools.endDrag(s, frame: frame)
    }

    static func steps(_ m: AppServices, _ id: UUID) async -> Int {
        await m.history.drained()
        // A frame with no step yet has no listing: none.
        return await MacHistoryCheck.listing(m, id)?.steps.count ?? 0
    }

    // MARK: pictures

    /// A picture's pixels as 8-bit sRGB RGBA, at most `long` on its long edge.
    static func pixels(_ image: CGImage, long: Int? = nil) -> (w: Int, h: Int, px: [UInt8])? {
        let scale = long.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, px)
    }

    /// The alpha-weighted centroid of a picture, normalised (the overlay as drawn).
    static func alphaCentroid(_ image: CGImage) -> CGPoint? {
        guard let p = pixels(image, long: 512) else { return nil }
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<p.h { for x in 0..<p.w {
            let a = Double(p.px[(y * p.w + x) * 4 + 3])
            guard a > 2 else { continue }
            sx += a * (Double(x) + 0.5); sy += a * (Double(y) + 0.5); sw += a
        } }
        return sw > 0 ? CGPoint(x: sx / sw / Double(p.w), y: sy / sw / Double(p.h)) : nil
    }

    /// Where two pictures of one frame differ, as a luma difference per pixel at `long` (and its size).
    static func difference(_ a: CGImage, _ b: CGImage, long: Int) -> (w: Int, h: Int, d: [Double])? {
        guard let x = pixels(a, long: long), let y = pixels(b, long: long), x.w == y.w, x.h == y.h else { return nil }
        var d = [Double](repeating: 0, count: x.w * x.h)
        for i in 0..<(x.w * x.h) {
            func l(_ p: [UInt8]) -> Double { 0.2126 * Double(p[4 * i]) + 0.7152 * Double(p[4 * i + 1]) + 0.0722 * Double(p[4 * i + 2]) }
            d[i] = abs(l(x.px) - l(y.px))
        }
        return (x.w, x.h, d)
    }

    /// The centroid of where two pictures differ by more than 3 codes, normalised.
    static func effectCentroid(_ layered: CGImage, _ plain: CGImage) -> CGPoint? {
        guard let f = difference(layered, plain, long: 512) else { return nil }
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in 0..<f.h { for x in 0..<f.w {
            let v = f.d[y * f.w + x]
            guard v > 3 else { continue }
            sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5); sw += v
        } }
        return sw > 0 ? CGPoint(x: sx / sw / Double(f.w), y: sy / sw / Double(f.h)) : nil
    }

    /// The left edge of the effect on each row of a band (normalised rows `rows`), in pixels of a picture `long` on
    /// its long edge: within 12 px of where it should be (`expected`, normalised x), the first x where the difference
    /// reaches half of the plateau inside the stroke (its median 15–30 px further in), linearly between pixels. Looked
    /// for near its place, not from the picture's edge: a full render's glare is unseeded (trap 1), so two of them
    /// differ a little everywhere, and a scan from the edge found that first (122 px off on one row).
    static func edges(_ layered: CGImage, _ plain: CGImage, long: Int, rows: ClosedRange<Double>, expected: Double) -> [Double?]? {
        guard let f = difference(layered, plain, long: long) else { return nil }
        var out: [Double?] = []
        let y0 = Int((rows.lowerBound * Double(f.h)).rounded()), y1 = Int((rows.upperBound * Double(f.h)).rounded())
        let ex = Int(expected * Double(f.w))
        for y in max(0, y0)...min(f.h - 1, y1) {
            let row = Array(f.d[(y * f.w)..<(y * f.w + f.w)])
            let inside = (ex + 15)...(min(ex + 30, f.w - 1))
            let plateau = inside.map { row[$0] }.sorted()[inside.count / 2]
            guard plateau > 6, ex - 12 > 0 else { out.append(nil); continue }
            let half = plateau / 2
            var x = ex - 12
            while x < ex + 12, row[x] < half { x += 1 }
            guard x > ex - 12, x < ex + 12 else { out.append(nil); continue }
            let a = row[x - 1], b = row[x]
            out.append(Double(x - 1) + (half - a) / max(b - a, 1e-6) + 0.5)
        }
        return out
    }

    static func export(_ m: AppServices, _ id: UUID, longEdge: Int, to url: URL) async -> CGImage? {
        var recipe = ExportRecipe()
        recipe.format = .png
        recipe.size = .longEdge(longEdge)
        m.exporter.start([id], recipe: recipe)
        for _ in 0..<2400 {
            if let b = m.exporter.batch, b.finished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let file = m.exporter.batch?.files.first else { return nil }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: file, to: url)
        // Decoded now, from the copy: the next export's start deletes the batch's folder, and a picture decoded lazily
        // from it afterwards is not this one (found: a mean of 64 codes against its own file, 0.05 read back).
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return image
    }

    /// The canvas's picture of the edit as it stands: the 场景 develop, or Edit's pass on it where a 成片 layer acts.
    static func canvas(_ s: OpenFrameSession, _ m: AppServices, stage: LayerStage) async -> CGImage? {
        if stage == .scene { return s.developedCGImage }
        guard let f = s.frame else { return nil }
        return await MacMasksCheck.shown(s, layers: m.finishedLayers(f, edit: s.edit)?.key)
    }

    /// The overlay as drawn for the picked layer, held on, once it is of the layer as it stands and of the stage's
    /// placement now.
    static func overlay(_ s: OpenFrameSession) async -> (made: MaskOverlay.Made, placed: (frame: UUID, shown: CGRect, area: CGSize, toS: MaskMatrix))? {
        tools.alone = false
        tools.held = true
        guard let layer = s.pickedMaskLayer, let src = s.frame?.originalSize else { return nil }
        let key = MaskBaker.planeKey(layer, source: src)
        var got: (MaskOverlay.Made, (UUID, CGRect, CGSize, MaskMatrix))?
        _ = await MacMasksCheck.until(20, every: 50) {
            guard let made = MaskOverlay.shared.made, let placed = MaskStageProbe.placed, made.planeKey == key, made.mode == .overlay,
                  made.key.contains(placed.toS.key) else { return false }
            got = (made, placed)
            return true
        }
        return got.map { ($0.0, (frame: $0.1.0, shown: $0.1.1, area: $0.1.2, toS: $0.1.3)) }
    }

    // MARK: run 1

    static func run(_ m: AppServices, _ r: R, a: LibraryFrame, b24: LibraryFrame?, out: URL, broken: String?) async {
        let geometryBreak = broken?.hasPrefix("geometry-") == true ? String(broken!.dropFirst("geometry-".count)) : nil
        guard let s = await MacMasksCheck.develop(m, a.id) else { return r.check(false, "tools: A opens in Develop") }
        s.change { $0.layers = nil }
        s.pick(row: .film)
        tools.putDown(); tools.held = false; tools.alone = false
        tools.setSettings(.brush, BrushSettings(radius: 0.03, hardness: 1, flow: 1))
        await MacMasksCheck.settle(m)

        await geometry(m, r, s, a: a, out: out, broken: geometryBreak)
        if geometryBreak != nil { return }
        await canvasIsExport(m, r, s, a: a, out: out)
        await everySurface(m, r, s, a: a, out: out)
        // The keys are run first in the walk (`MacMasksCheck.walk`), before M1a's drawings: see `keys`.
        await pointer(m, r, s, a: a)
        if let b24 { await cost(m, r, a: a, b: b24) }
        await liveMatches(m, r, a: a)
        if broken == nil { await drawings(m, r, a: a) }
        // Leave A as the kept walk expects it.
        if let s = m.openSession(a.id) { s.change { $0.layers = nil; $0.geometry = .default; $0.printCrop = .default; $0.filmEdge.active = false } }
        tools.putDown(); tools.held = false; tools.alone = false
    }

    // MARK: 6 geometry

    static func geometry(_ m: AppServices, _ r: R, _ s: OpenFrameSession, a: LibraryFrame, out: URL, broken: String?) async {
        MaskStageProbe.broken = broken
        defer { MaskStageProbe.broken = nil }
        s.show(.edit)
        await MacMasksCheck.pause(0.5)
        let before = await steps(m, a.id)
        // A stroke across a place off every axis of the picture, so a turn or a flip moves it.
        stroke(s, a.id, [MaskPoint(0.28, 0.33), MaskPoint(0.33, 0.35), MaskPoint(0.37, 0.38)])
        guard let id = s.layerPick.maskID, let layer = s.edit.layers?[id] else { return r.check(false, "geometry: the first stroke with 胶片 picked makes a layer") }
        let after = await steps(m, a.id)
        r.check(layer.stage == .finished && layer.name == MaskRules.name(.brush, among: LocalLayers()) && layer.parts.count == 1
                && layer.parts[0].brush?.strokes.count == 1 && after == before + 1,
                "the first stroke with 胶片 picked makes \(layer.name), 成片 in 编辑, one stroke, and is one step of Undo")
        let points = layer.parts[0].brush?.strokes.first?.unpacked ?? []
        s.changeLayer(id) { $0.finished?.exposure = -3 }
        await MacMasksCheck.settle(m)

        let framings: [(String, (inout FrameEdit) -> Void)] = [
            ("as it is", { _ in }),
            ("冲洗's crop", { $0.geometry.crop = CropRect(x: 0.25, y: 0.15, width: 0.6, height: 0.7) }),
            ("编辑's crop", { $0.geometry = .default; $0.printCrop.crop = CropRect(x: 0.1, y: 0.15, width: 0.65, height: 0.7) }),
            ("a straighten", { $0.printCrop = .default; $0.geometry.angle = 10 }),
            ("a quarter turn", { $0.geometry = .default; $0.geometry.quarterTurns = 1 }),
            ("a flip", { $0.geometry = .default; $0.geometry.flipH = true }),
            ("a film edge", { $0.geometry = .default; $0.filmEdge.active = true }),
        ]
        for (name, mutate) in framings {
            if broken != nil, name == "as it is" { continue }
            let stamp = s.developed?.stamp
            s.change(mutate)
            _ = await MacMasksCheck.until(90, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp }
            await MacMasksCheck.settle(m)
            guard let f = s.frame, let base = s.developedCGImage,
                  let layered = await MacMasksCheck.shown(s, layers: m.finishedLayers(f, edit: s.edit)?.key) else {
                r.check(false, "geometry: \(name): the pass landed"); continue
            }
            guard let ov = await overlay(s), let oc = alphaCentroid(ov.made.image.cgImage!), let ec = effectCentroid(layered, base) else {
                r.check(false, "geometry: \(name): the overlay and the effect", "overlay \(MaskOverlay.shared.made != nil), placed \(MaskStageProbe.placed != nil)"); continue
            }
            // The effect as the canvas shows it: Edit's crop of the finished canvas, laid on the picture's rect.
            let size = DevelopedFrameView.finishedSize(frame: f, edit: s.edit, model: m, developed: s.developed)
            let crop = s.edit.printCrop.onFinished(size)
            let o = crop.isIdentity ? ec : MaskMatrix.through { crop.sourcePoint(forOutput: $0, imageSize: size) }.inverted.apply(ec)
            let shown = ov.placed.shown
            let effect = CGPoint(x: shown.minX + o.x * shown.width, y: shown.minY + o.y * shown.height)
            let drawn = CGPoint(x: ov.made.rect.minX + oc.x * ov.made.rect.width, y: ov.made.rect.minY + oc.y * ov.made.rect.height)
            let apart = hypot(effect.x - drawn.x, effect.y - drawn.y), bar = 0.02 * max(shown.width, shown.height)
            r.check(apart <= bar, "geometry: \(name): the overlay's centroid on the developed effect's",
                    String(format: "%.1f pt apart (bar %.1f, 2 %% of the picture's %.0f pt); overlay (%.1f, %.1f), effect (%.1f, %.1f)",
                           apart, bar, max(shown.width, shown.height), drawn.x, drawn.y, effect.x, effect.y))
            if broken == nil, let cg = ov.made.image.cgImage { MacMasksCheck.write(cg, out.appendingPathComponent("geometry-\(name.filter { $0.isLetter || $0.isNumber }).png")) }
        }
        tools.held = false
        if broken != nil { return }
        // Paint → crop → reopen: the stroke where it was, in S.
        s.change { $0.geometry = .default; $0.filmEdge.active = false; $0.geometry.crop = CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8) }
        await MacMasksCheck.settle(m)
        m.router.toLibrary()
        await MacMasksCheck.pause(1.5)
        guard let again = await MacMasksCheck.develop(m, a.id) else { return r.check(false, "geometry: A reopens") }
        let kept = again.edit.layers?[id]?.parts.first?.brush?.strokes.first?.unpacked ?? []
        r.check(!points.isEmpty && kept == points, "geometry: paint → crop → reopen leaves the stroke's points where they were in S (\(kept.count) points)")
        again.change { $0.layers = nil; $0.geometry = .default }
        again.show(.develop)
        await MacMasksCheck.settle(m)
    }

    // MARK: 5 canvas is export

    static func canvasIsExport(_ m: AppServices, _ r: R, _ s0: OpenFrameSession, a: LibraryFrame, out: URL) async {
        for stage in [LayerStage.scene, .finished] {
            var opened = m.openSession(a.id)
            if opened == nil { opened = await MacMasksCheck.develop(m, a.id) }
            guard let s = opened else { return r.check(false, "canvas is export: A") }
            s.show(stage == .scene ? .develop : .edit)
            s.change { $0.layers = nil }
            s.pick(row: .film)
            await MacMasksCheck.settle(m)
            // A hard stroke along the middle row from x 0.30 to 0.45, then a linear gradient joined to it, full at the
            // right edge and none from x 0.75 in (a linear part is full on the whole side of its 100 % line).
            stroke(s, a.id, [MaskPoint(0.30, 0.5), MaskPoint(0.37, 0.5), MaskPoint(0.45, 0.5)])
            guard let id = s.layerPick.maskID else { r.check(false, "canvas is export (\(stage.rawValue)): the stroke made a layer"); continue }
            if stage == .scene { await brushSize(r, s) }
            gradient(s, a.id, .linear, from: MaskPoint(0.95, 0.2), to: MaskPoint(0.75, 0.2))
            let stamp = s.developed?.stamp
            s.changeLayer(id) { l in if stage == .scene { l.scene?.exposure = -2.5 } else { l.finished?.exposure = -2.5 } }
            if stage == .scene { _ = await MacMasksCheck.until(90, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp } }
            await MacMasksCheck.settle(m)
            let plainStamp = s.developed?.stamp
            guard let layered = await canvas(s, m, stage: stage) else { r.check(false, "canvas is export (\(stage.rawValue)): the canvas"); continue }
            let edge = max(layered.width, layered.height)
            let tag = stage.rawValue
            guard let exported = await export(m, a.id, longEdge: edge, to: out.appendingPathComponent("export-\(tag)-live.png")),
                  let full = await export(m, a.id, longEdge: a.originalSize.longEdge, to: out.appendingPathComponent("export-\(tag)-full.png")) else {
                r.check(false, "canvas is export (\(stage.rawValue)): the exports landed"); continue
            }
            // The same without the layer: the canvas and both exports.
            s.setLayerOn(id, false)
            if stage == .scene { _ = await MacMasksCheck.until(90, every: 100) { s.developed?.stamp != plainStamp && !s.isCatchingUp } }
            await MacMasksCheck.settle(m)
            let plain = s.developedCGImage
            let plainLive = await export(m, a.id, longEdge: edge, to: out.appendingPathComponent("export-\(tag)-live-plain.png"))
            let plainFull = await export(m, a.id, longEdge: a.originalSize.longEdge, to: out.appendingPathComponent("export-\(tag)-full-plain.png"))
            s.setLayerOn(id, true)
            MacMasksCheck.write(layered, out.appendingPathComponent("canvas-\(tag).png"))
            guard let plain, let plainLive, let plainFull else { r.check(false, "canvas is export (\(tag)): the plain pictures"); continue }
            let d = MacMasksCheck.difference(layered, exported), moved = MacMasksCheck.difference(layered, plain)
            r.check(d.mean <= 3 && moved.mean > 3 * d.mean + 0.3,
                    "canvas is export (\(tag)): a stroke and a gradient, the canvas against the export at its size",
                    String(format: "mean %.2f, worst %.2f sRGB codes (bar 3); the layer moves the canvas %.2f; %dx%d", d.mean, d.worst, moved.mean, exported.width, exported.height))
            // The stroke's left end, row by row, against the smaller picture's pixels.
            let r0 = 0.5 - 0.4 * 0.03 * Double(a.originalSize.longEdge) / Double(a.originalSize.height)
            let r1 = 0.5 + 0.4 * 0.03 * Double(a.originalSize.longEdge) / Double(a.originalSize.height)
            // The stroke's left end: x 0.30 less its radius (metric → S x), the middle third of its height.
            let expectedX = 0.30 - 0.03 / MaskMetric(source: a.originalSize).ax
            let canvasEdges = edges(layered, plain, long: edge, rows: r0...r1, expected: expectedX)
            for (what, big, bigPlain) in [("the live tier", exported, plainLive), ("Full", full, plainFull)] {
                guard let c = canvasEdges, let e = edges(big, bigPlain, long: edge, rows: r0...r1, expected: expectedX), c.count == e.count else {
                    r.check(false, "canvas is export (\(tag)): the stroke's edge at \(what)"); continue
                }
                let gaps = zip(c, e).compactMap { p -> Double? in guard let x = p.0, let y = p.1 else { return nil }; return abs(x - y) }.sorted()
                guard !gaps.isEmpty else { r.check(false, "canvas is export (\(tag)): the stroke's edge at \(what)", "no row had it"); continue }
                let mean = gaps.reduce(0, +) / Double(gaps.count), p95 = gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
                r.check(p95 <= 1, "canvas is export (\(tag)): the mask's edge within a pixel of the smaller picture at \(what)",
                        String(format: "%d of %d rows, mean %.2f px, 95th percentile %.2f, worst %.2f px (the export %dx%d, read at %d)",
                               gaps.count, c.count, mean, p95, gaps.last ?? 0, big.width, big.height, edge))
            }
            s.change { $0.layers = nil }
            await MacMasksCheck.settle(m)
        }
    }

    /// The cursor is the brush it paints with (§6.2): the overlay's band across the stroke's middle, in view points,
    /// against the cursor's diameter there (`MaskStage`'s r × the view's points per metric unit). A hard stroke
    /// (hardness 1) along y = 0.5 from x 0.30 to 0.45.
    static func brushSize(_ r: R, _ s: OpenFrameSession) async {
        guard let ov = await overlay(s), let cg = ov.made.image.cgImage, let p = pixels(cg), let src = s.frame?.originalSize else {
            return r.check(false, "the brush's cursor is its size: the overlay")
        }
        let placed = ov.placed
        let inv = placed.toS.inverted
        func view(_ x: Double, _ y: Double) -> CGPoint {
            let n = inv.apply(CGPoint(x: x, y: y))
            return CGPoint(x: placed.shown.minX + n.x * placed.shown.width, y: placed.shown.minY + n.y * placed.shown.height)
        }
        let mid = view(0.375, 0.5)
        let col = Int((mid.x - ov.made.rect.minX) / ov.made.rect.width * Double(p.w))
        var rows: [Int] = []
        for y in 0..<p.h where col >= 0 && col < p.w && p.px[(y * p.w + col) * 4 + 3] >= 64 { rows.append(y) }
        let band = Double((rows.last ?? 0) - (rows.first ?? 0) + 1) / Double(p.h) * ov.made.rect.height
        let metric = MaskMetric(source: src)
        let m0 = metric.metric(MaskPoint(0.375, 0.5)), up = view(0.375, 0.5 + 0.01 / metric.ay)
        let perMetric = hypot(up.x - mid.x, up.y - mid.y) / 0.01
        let diameter = 2 * tools.settings(.brush).radius * perMetric
        _ = m0
        r.check(!rows.isEmpty && abs(band - diameter) <= max(2, 0.05 * diameter), "the brush's cursor is the size it paints (§6.2)",
                String(format: "the overlay's band %.1f pt across (alpha ≥ 25 %%), the cursor %.1f pt", band, diameter))
    }

    // MARK: 7 every surface; Undo and Redo

    static func everySurface(_ m: AppServices, _ r: R, _ s0: OpenFrameSession, a: LibraryFrame, out: URL) async {
        guard let s = m.openSession(a.id) else { return r.check(false, "every surface: A") }
        s.show(.edit)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await MacMasksCheck.settle(m)
        let live = s.layer2
        live.holdHistogram("masks-check")
        defer { live.releaseHistogram("masks-check") }
        stroke(s, a.id, [MaskPoint(0.5, 0.5), MaskPoint(0.6, 0.55)])
        guard let id = s.layerPick.maskID else { return r.check(false, "every surface: a layer") }
        s.changeLayer(id) { $0.finished?.exposure = -1.5 }
        await MacMasksCheck.settle(m)
        func state() async -> (Data?, Data?, [Double]?, Data?) {
            guard let f = s.frame else { return (nil, nil, nil, nil) }
            let shown = await MacMasksCheck.shown(s, layers: m.finishedLayers(f, edit: s.edit)?.key)
            for _ in 0..<40 where live.histogram == nil { try? await Task.sleep(for: .milliseconds(100)) }
            let h = live.histogram.map { $0.counts.map(Double.init) }
            let e = await export(m, a.id, longEdge: 1024, to: out.appendingPathComponent("surface-export.png"))
            return (s.developedCGImage.flatMap(MacMasksCheck.bytes), shown.flatMap(MacMasksCheck.bytes), h, e.flatMap(MacMasksCheck.bytes))
        }
        tools.held = false; tools.alone = false
        await MacMasksCheck.pause(0.8)
        let without = await state()
        for (what, set) in [("the overlay held", { tools.held = true; tools.alone = false }), ("the mask alone", { tools.held = false; tools.alone = true })] {
            set()
            await MacMasksCheck.pause(1.2)
            let with = await state()
            let shownOnPage = what == "the overlay held" ? MaskOverlay.shared.made?.mode == .overlay : MaskOverlay.shared.made?.mode == .alone
            r.check(shownOnPage && without.0 != nil && with.0 == without.0 && with.1 == without.1 && with.2 == without.2 && with.3 == without.3 && with.3 != nil,
                    "every surface: with \(what) on the page, the kept develop, Edit's pass, the histogram and an export are byte-same",
                    "on the page \(shownOnPage); develop \(with.0 == without.0), pass \(with.1 == without.1), histogram \(with.2 == without.2), export \(with.3 == without.3)")
        }
        tools.held = false; tools.alone = false

        // One stroke, one step; a handle's drag, one step; Undo and Redo through them.
        let n0 = await steps(m, a.id)
        stroke(s, a.id, [MaskPoint(0.2, 0.7), MaskPoint(0.3, 0.72)])
        let n1 = await steps(m, a.id)
        let strokes1 = s.edit.layers?[id]?.parts.first?.brush?.strokes.count
        gradient(s, a.id, .radial, from: MaskPoint(0.7, 0.3), to: MaskPoint(0.8, 0.4))
        let n2 = await steps(m, a.id)
        guard let radial = s.edit.layers?[id]?.parts.last, radial.kind == .radial, let g = radial.radial else { return r.check(false, "every surface: the radial part") }
        r.check(tools.chosenPart == radial.id, "a gradient's drag chooses its part: the handles are for it")
        dragHandle(s, a.id, .radialCentre, from: g.centre, to: MaskPoint(g.centre.x - 0.1, g.centre.y))
        let n3 = await steps(m, a.id)
        let moved = s.edit.layers?[id]?.parts.last?.radial?.centre
        r.check(n1 == n0 + 1 && n2 == n1 + 1 && n3 == n2 + 1 && strokes1 == 2 && moved.map { abs($0.x - (g.centre.x - 0.1)) < 1e-9 } == true,
                "a stroke, a gradient's drag and a handle's drag are one step each (\(n0) → \(n1) → \(n2) → \(n3))")
        _ = s.undo(); await MacMasksCheck.pause(0.4)
        let u1 = s.edit.layers?[id]?.parts.last?.radial?.centre == g.centre
        _ = s.undo(); await MacMasksCheck.pause(0.4)
        let u2 = s.edit.layers?[id]?.parts.last?.kind == .brush
        _ = s.undo(); await MacMasksCheck.pause(0.4)
        let u3 = s.edit.layers?[id]?.parts.first?.brush?.strokes.count == 1
        _ = s.redo(); _ = s.redo(); _ = s.redo(); await MacMasksCheck.pause(0.6)
        let back = s.edit.layers?[id]?.parts.last?.radial?.centre == moved && s.edit.layers?[id]?.parts.first?.brush?.strokes.count == 2
        r.check(u1 && u2 && u3 && back, "Undo takes the handle's drag, the gradient and the stroke back one at a time; Redo brings all three",
                "\(u1) \(u2) \(u3) \(back)")
        // ⌫ removes the chosen part, then (none chosen) the layer.
        tools.chosenPart = radial.id
        tools.delete(s)
        let partGone = s.edit.layers?[id]?.parts.contains { $0.id == radial.id } == false && s.edit.layers?[id] != nil
        tools.delete(s)
        r.check(partGone && s.edit.layers?[id] == nil, "⌫'s act: the chosen part, then with none chosen the layer")
        _ = s.undo(); await MacMasksCheck.pause(0.4)
        // The stroke Undo of run 2: two strokes kept.
        await MacMasksCheck.settle(m)
    }

    // MARK: the keys, pressed for real

    struct KeyState: Equatable { var lit: MaskTool?; var radius: Double; var hardness: Double; var held: Bool; var alone: Bool; var layers: Int }

    static func keys(_ m: AppServices, _ r: R, _ s0: OpenFrameSession, a: LibraryFrame) async {
        guard let s = m.openSession(a.id) else { return r.check(false, "keys: A") }
        s.show(.develop)
        s.change { $0.layers = nil }
        s.makeLayer(.gradient, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0.2), b: MaskPoint(0.5, 0.6)))], stage: .scene)
        tools.putDown(); tools.held = false; tools.alone = false; tools.chosenPart = nil
        tools.setSettings(.brush, BrushSettings(radius: 0.02, hardness: 0.5, flow: 1))
        MacHistoryPageCheck.layoutWindows()
        await MacMasksCheck.pause(1.0)
        func now() -> KeyState {
            KeyState(lit: tools.lit, radius: (tools.settings(.brush).radius * 1e6).rounded(), hardness: (tools.settings(.brush).hardness * 100).rounded(),
                     held: tools.held, alone: tools.alone, layers: s.edit.layers?.items.count ?? 0)
        }
        let s0 = now()
        // What gates the page's plain keys and the layer acts, as the case starts (`macPhotoKeysFree`, trap 34's hold).
        // **Where this case runs, and why** (the M1c review's item 2, 2026-11-13). Run after M1a's drawings — a row's
        // menu opened through `_presentMenuAtLocation:`, the language switched to 简体中文 and back, the window laid out
        // again — none of the plain keys posted to this process landed (B, E, M, [ ]) while a key command (⌫) did, in
        // 8513434c, M1b's own tip, as in this tree; run alone, or after M1b's own cases, all twelve landed. What this
        // case can read of the app was the same in both (this app active, its window key and frontmost; B registered once
        // and enabled, offered as a key command; no field typing; the anchor first after a click; the input mode
        // zh-Hans in both). So it runs first in the walk, and keys after a menu and a language switch are a person's to
        // try (the hand-check list). It starts as a person's keys do, after a click on the page
        // (`MacKeyFocus.takeKeys`).
        let first = UIResponder.spkFirstResponder.map { String(describing: type(of: $0)) } ?? "none"
        MacKeyFocus.shared.takeKeys()
        await MacMasksCheck.pause(0.5)
        let after = UIResponder.spkFirstResponder.map { String(describing: type(of: $0)) } ?? "none"
        let reg = MacShortcutRegistry.shared
        let bRegs = reg.registrations(of: "b").joined(separator: " | ")
        let mode = MacKeyAnchor.shared?.textInputMode?.primaryLanguage ?? "nil"
        let modes = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage).joined(separator: ",")
        let gates = "input mode \(mode) (active \(modes)); B registered as [\(bRegs)], offered \(reg.offered("b")), typing-for-registry \(reg.typing); typing \(MacLibraryBrowser.shared.typing), modal \(MacLibraryBrowser.shared.modal), cover \(m.router.cover.map { "\($0)" } ?? "none"), exporting \(m.exporter.isExporting), layers made \(s0.layers), first responder \(first), after a click on the page \(after)"
        r.unreached("keys: as the case starts — \(gates)")
        // The shell brings this process to the front and presses B until it lands ("KEYS GO": a key posted before the
        // window is the key one is lost, and how long that takes varies), then ] [ ⇧] ⇧[ E Esc M M ⌥M ⌥M ⌫
        // (tools/masks_check.sh). B pressed again is no change: the tool stays lit.
        print("masks-check: KEYS READY \(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        let landed = await MacMasksCheck.until(30, every: 20) { tools.lit == .brush }
        let state = deliveryState()
        print("masks-check: KEYS GO")
        fflush(stdout)
        // B never landed: was the app in a state to be given keys? Not active, or no key window, is this machine's state
        // (another app in front, the window not key), not the product: said so, and the twelve are not counted. Active with
        // a key window and still nothing is a real failure.
        if !landed, !state.receives {
            r.unreached("keys could not be delivered: \(state.why) — the keys are on the hand-check list")
            s.change { $0.layers = nil }
            return
        }
        var seen = [s0]
        if landed { seen.append(now()) }
        let start = Date()
        while Date().timeIntervalSince(start) < 40 {
            let n = now()
            if n != seen.last { seen.append(n) }
            if seen.count >= 13 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        var e = s0
        var expected = [s0]
        func next(_ f: (inout KeyState) -> Void) { f(&e); expected.append(e) }
        next { $0.lit = .brush }                                                          // B
        next { $0.radius = (0.022 * 1e6).rounded() }                                      // ]
        next { $0.radius = ((0.022 / 1.1) * 1e6).rounded() }                              // [
        next { $0.hardness = 60 }                                                         // ⇧]
        next { $0.hardness = 50 }                                                         // ⇧[
        next { $0.lit = .eraser }                                                         // E
        next { $0.lit = nil }                                                             // Esc
        next { $0.held = true }                                                           // M
        next { $0.held = false }                                                          // M
        next { $0.alone = true }                                                          // ⌥M
        next { $0.alone = false }                                                         // ⌥M
        next { $0.layers = 0 }                                                            // ⌫
        let names = ["(start)", "B", "]", "[", "⇧]", "⇧[", "E", "Esc", "M", "M", "⌥M", "⌥M", "⌫"]
        for i in 1..<expected.count {
            let ok = seen.count > i && seen[i] == expected[i]
            r.check(ok, "keys: \(names[i]) pressed for real", ok ? "" : "seen \(seen.count > i ? "\(seen[i])" : "nothing"), expected \(expected[i])")
        }
        s.change { $0.layers = nil }
    }

    /// Whether this app can be handed keys now, read from AppKit (through the Objective-C runtime): active, with a key
    /// window; and if not, why, with the frontmost application's name (M1c review item 2: 8513434c, M1b's own tip,
    /// failed all twelve in the same session, so it is the machine's state).
    static func deliveryState() -> (receives: Bool, why: String) {
        let app = MacVariantActsCheck.app
        let active = (app?.value(forKey: "isActive") as? Bool) ?? false
        let key = app?.value(forKey: "keyWindow") != nil
        let workspace = (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(forKey: "sharedWorkspace") as? NSObject
        let front = (workspace?.value(forKey: "frontmostApplication") as? NSObject)?.value(forKey: "localizedName") as? String ?? "?"
        let pid = ((workspace?.value(forKey: "frontmostApplication") as? NSObject)?.value(forKey: "processIdentifier") as? Int) ?? -1
        let ours = pid == Int(ProcessInfo.processInfo.processIdentifier)
        if active && key && ours { return (true, "") }
        return (false, "this app active \(active), a key window \(key); the frontmost application is \"\(front)\" (pid \(pid), this app's \(ProcessInfo.processInfo.processIdentifier))")
    }

    // MARK: a pointer drag, posted for real

    static func pointer(_ m: AppServices, _ r: R, _ s0: OpenFrameSession, a: LibraryFrame) async {
        guard let s = m.openSession(a.id) else { return }
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        tools.light(.brush)
        MacHistoryPageCheck.layoutWindows()
        await MacMasksCheck.pause(1.0)
        guard let placed = MaskStageProbe.placed, let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
              let stage = stageView(in: window) else { return r.unreached("pointer: no stage to post to") }
        let from = stage.convert(CGPoint(x: placed.shown.midX - 60, y: placed.shown.midY), to: window)
        let to = stage.convert(CGPoint(x: placed.shown.midX + 60, y: placed.shown.midY + 20), to: window)
        let before = await steps(m, a.id)
        print(String(format: "masks-check: POINTER READY %d %.1f %.1f %.1f %.1f %.1f %.1f", ProcessInfo.processInfo.processIdentifier,
                     from.x, from.y, to.x, to.y, window.bounds.width, window.bounds.height))
        fflush(stdout)
        _ = await MacMasksCheck.until(25, every: 100) { s.edit.layers?.items.isEmpty == false }
        await MacMasksCheck.pause(1)
        let after = await steps(m, a.id)
        let strokes = s.edit.layers?.items.first?.parts.first?.brush?.strokes
        if let strokes, strokes.count == 1 {
            let pts = strokes[0].unpacked
            let p0 = placedSource(placed, from: stage.convert(from, from: window)), p1 = placedSource(placed, from: stage.convert(to, from: window))
            let near = pts.first.map { hypot($0.x - p0.x, $0.y - p0.y) < 0.02 } == true && pts.last.map { hypot($0.x - p1.x, $0.y - p1.y) < 0.02 } == true
            r.check(near && after == before + 1, "pointer: a real drag on the canvas paints one stroke from where it pressed to where it let go, one step",
                    "\(pts.count) points, \(String(format: "(%.3f, %.3f) → (%.3f, %.3f)", pts.first?.x ?? 0, pts.first?.y ?? 0, pts.last?.x ?? 0, pts.last?.y ?? 0)), expected (\(String(format: "%.3f, %.3f", p0.x, p0.y))) → (\(String(format: "%.3f, %.3f", p1.x, p1.y)))")
        } else {
            r.unreached("pointer: the posted drag did not reach the canvas (\(s.edit.layers?.items.count ?? 0) layers): the pointer path is on the hand-check list")
        }
        tools.putDown()
        s.change { $0.layers = nil }
    }

    static func placedSource(_ placed: (frame: UUID, shown: CGRect, area: CGSize, toS: MaskMatrix), from q: CGPoint) -> MaskPoint {
        let n = CGPoint(x: (q.x - placed.shown.minX) / placed.shown.width, y: (q.y - placed.shown.minY) / placed.shown.height)
        let s = placed.toS.apply(n)
        return MaskPoint(Double(s.x), Double(s.y))
    }

    /// The hosting view the stage's coordinates are in: the largest view under the canvas whose bounds are the area.
    static func stageView(in window: UIWindow) -> UIView? {
        guard let area = MaskStageProbe.placed?.area else { return nil }
        func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
        return all(window).first { abs($0.bounds.width - area.width) < 1 && abs($0.bounds.height - area.height) < 1 && $0.accessibilityIdentifier == "mask.stage" }
            ?? all(window).first { abs($0.bounds.width - area.width) < 1 && abs($0.bounds.height - area.height) < 1 }
    }

    // MARK: cost

    /// The bar a stroke's move is held to (2.4.0 A1): the change handed to the screen within one display frame —
    /// median 8 ms, worst 16 ms (a 160 Hz frame is 6.25 ms).
    static let handedMedianBar = 8.0, handedWorstBar = 16.0

    /// The layer as the stroke in hand leaves it, all its points so far: what the exact overlay is caught up to once
    /// its picture is of this.
    static func strokeLayer(_ s: OpenFrameSession) -> LocalLayer? {
        guard var l = s.pickedMaskLayer, let d = tools.drag, d.tool.isBrush else { return s.pickedMaskLayer }
        guard let i = l.parts.firstIndex(where: { $0.id == d.part }), var b = l.parts[i].brush, b.strokes.indices.contains(d.stroke) else { return l }
        b.strokes[d.stroke] = tools.settings(d.tool).stroke(d.points)
        l.parts[i].brush = b
        return l
    }

    static func cost(_ m: AppServices, _ r: R, a: LibraryFrame, b: LibraryFrame) async {
        // In front, as a person paints: the shell brings this process forward (`masks_check.sh`, FRONT).
        print("masks-check: FRONT \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
        let front = await MacMasksCheck.until(15, every: 100) { UIApplication.shared.applicationState == .active }
        r.unreached("cost: the app \(front ? "in front" : "NOT in front (the strokes ran behind another app)")")
        // A move → the change handed to the screen: with the live stroke (`MaskLive`) the composite committed with its
        // drawable; without it (`MASKS_LIVE_OFF=1`, the path before A1) the overlay made of the move handed to the view.
        var handed: [String: [Double]] = [:], presented: [String: [Double]] = [:], gpu: [String: [Double]] = [:]
        var turn: [String: [Double]] = [:], develop: [String: [Double]] = [:], actor: [String: [Double]] = [:]
        // Where a turnaround to the exact overlay goes (M1c step 0c): the move to the overlay's ask, then the ask to the
        // task, the bake, the render, the hop back.
        var parts: [String: [[Double]]] = [:]
        var gaps: [String: [Double]] = [:]
        var late: [String] = []
        var pressHeld: [String: [Double]] = [:]
        tools.paid = []
        let live = MaskLive.enabled
        for round in 0..<3 {
            for f in [a, b] {
                guard let s = await MacMasksCheck.develop(m, f.id) else { continue }
                s.show(.develop)
                s.change { $0.layers = nil }
                s.pick(row: .film)
                tools.held = true
                let tag = "\(f.originalSize.width * f.originalSize.height / 1_000_000) MP"
                let metric = MaskMetric(source: f.originalSize)
                // 1. Each move waited for: its time to the screen, and to the exact overlay made of it.
                tools.light(.brush)
                guard tools.beginStroke(s, at: MaskPoint(0.3, 0.5), frame: f.id, straight: false) else { continue }
                for i in 1...12 {
                    let t0 = Date(), n = MaskLive.shared.presents
                    tools.continueStroke(s, to: MaskPoint(0.3 + 0.02 * Double(i), 0.5 + 0.01 * Double(i % 3)), metric: metric)
                    if live, MaskLive.shared.presents > n, let t = MaskLive.shared.timings[MaskLive.shared.presents] {
                        handed[tag, default: []].append(t.handed)
                    }
                    guard let l = strokeLayer(s) else { break }
                    let key = MaskBaker.planeKey(l, source: f.originalSize)
                    if await MacMasksCheck.until(5, every: 2, { MaskOverlay.shared.made?.planeKey == key }) {
                        let total = Date().timeIntervalSince(t0) * 1000
                        turn[tag, default: []].append(total)
                        if !live { handed[tag, default: []].append(total) }
                        if let t = MaskOverlay.shared.lastTiming {
                            let toAsk = total - t.landed
                            parts[tag, default: []].append([toAsk, t.start, t.baked - t.start, t.rendered - t.baked, t.landed - t.rendered])
                        }
                    }
                }
                tools.endDrag(s, frame: f.id)
                // 2. A pointer's stream: 24 moves a display frame apart (UIKit hands a drag's events once a frame, the
                // samples between coalesced: 6.25 ms at 160 Hz), none waited for — the bakes behind them.
                if live {
                    await MacMasksCheck.pause(0.3)
                    let from = MaskLive.shared.presents
                    guard tools.beginStroke(s, at: MaskPoint(0.3, 0.6), frame: f.id, straight: false) else { continue }
                    // Every present of the stroke: one that carries moves held for a drawable is timed from the earliest.
                    var last = CACurrentMediaTime()
                    // Each move timed from when it was due, as a pointer's event is from its oldest sample's own time
                    // (`MaskPress`): a main actor still busy when the move came counts against it.
                    let streamStart = CACurrentMediaTime()
                    // MASKS_COST_SAMPLE=1: a long stream to sample the process under (`sample <pid>`), said by its pid.
                    let long = ProcessInfo.processInfo.environment["MASKS_COST_SAMPLE"] != nil && round == 0 && f.id == a.id
                    if long { print("masks-check: SAMPLE \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout) }
                    // MASKS_COST_SAMPLE=press: many short strokes, to sample what a press costs.
                    if long, ProcessInfo.processInfo.environment["MASKS_COST_SAMPLE"] == "press" {
                        tools.endDrag(s, frame: f.id)
                        for k in 0..<150 {
                            guard tools.beginStroke(s, at: MaskPoint(0.2 + 0.004 * Double(k), 0.3), frame: f.id, straight: false) else { break }
                            for j in 1...3 {
                                tools.continueStroke(s, to: MaskPoint(0.2 + 0.004 * Double(k), 0.3 + 0.01 * Double(j)), metric: metric)
                                await Task.yield()
                            }
                            tools.endDrag(s, frame: f.id)
                            try? await Task.sleep(nanoseconds: 20_000_000)
                        }
                        _ = tools.beginStroke(s, at: MaskPoint(0.3, 0.6), frame: f.id, straight: false)
                    }
                    // The press's own turn (the page's update for the drag's step: Undo greyed, the overlay asked) holds
                    // the moves due during it; they are counted apart, until the stream has caught up with its frames.
                    var caughtUp: Int?
                    for i in 1...(long ? 1200 : 24) {
                        let t0 = CACurrentMediaTime()
                        if caughtUp == nil, i > 1, t0 - (streamStart + Double(i - 1) * MaskLive.shared.frameSeconds) < MaskLive.shared.frameSeconds {
                            caughtUp = MaskLive.shared.presents
                        }
                        // The oldest sample this move carries: its own frame, or just after the move before was
                        // handled where the main actor fell behind (UIKit hands the samples since in one event).
                        let due = i == 1 ? t0 : max(streamStart + Double(i - 1) * MaskLive.shared.frameSeconds, last)
                        gaps[tag, default: []].append((t0 - last) * 1000)
                        if (t0 - last) * 1000 > 15 { late.append(String(format: "%d: %.0f", i, (t0 - last) * 1000)) }
                        last = t0
                        tools.continueStroke(s, to: [MaskPoint(0.3 + 0.012 * Double(i % 40), 0.6 + 0.004 * Double(i % 5) + 0.001 * Double(i / 40))], metric: metric, at: due)
                        actor[tag, default: []].append((CACurrentMediaTime() - t0) * 1000)
                        let next = streamStart + Double(i) * MaskLive.shared.frameSeconds - CACurrentMediaTime()
                        if next > 0 { try? await Task.sleep(nanoseconds: UInt64(next * 1e9)) } else { await Task.yield() }
                    }
                    tools.endDrag(s, frame: f.id)
                    await MacMasksCheck.pause(0.3)
                    for n in (from + 1)...max(from + 1, MaskLive.shared.presents) { if let t = MaskLive.shared.timings[n] {
                        // The press's own present is drawn in its event; a move the press's turn held is apart.
                        if n > from + 1, n <= caughtUp ?? .max { pressHeld[tag, default: []].append(t.handed); continue }
                        handed[tag, default: []].append(t.handed)
                        if t.gpu > 0 { gpu[tag, default: []].append(t.gpu) }
                        if t.presented > 0 { presented[tag, default: []].append(t.presented) }
                    } }
                }
                // A 场景 stroke's time to the developed picture at the live tier: the layer acts once it has an exposure.
                guard let id = s.layerPick.maskID else { continue }
                await MacMasksCheck.settle(m)
                let stamp = s.developed?.stamp
                let t0 = Date()
                s.changeLayer(id) { $0.scene?.exposure = 1 + 0.1 * Double(round) }
                if await MacMasksCheck.until(60, every: 10, { s.developed?.stamp != stamp && !s.isCatchingUp }) {
                    develop[tag, default: []].append(Date().timeIntervalSince(t0) * 1000)
                }
                tools.held = false
                s.change { $0.layers = nil }
                await MacMasksCheck.settle(m)
            }
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
        func spread(_ v: [Double]) -> String { String(format: "median %.1f ms, worst %.1f ms over %d", median(v), v.max() ?? 0, v.count) }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let loadWords = String(format: "load %.2f %.2f %.2f", load[0], load[1], load[2])
        for (tag, v) in handed.sorted(by: { $0.key < $1.key }) {
            r.check(!v.isEmpty && median(v) <= handedMedianBar && (v.max() ?? .infinity) <= handedWorstBar,
                    "cost: a stroke's move → the change handed to the screen on \(tag), within a display frame (median ≤ \(Int(handedMedianBar)) ms, worst ≤ \(Int(handedWorstBar)) ms; the press's turn apart)",
                    "\(live ? "live" : "the overlay (MASKS_LIVE_OFF)"): \(spread(v)) moves (interleaved with the other frame; \(loadWords))")
        }
        r.unreached("cost: display frame \(String(format: "%.2f", MaskLive.shared.frameSeconds * 1000)) ms, a present to its presented handler \(spread(MaskLive.shared.handedBack)), moves held for the GPU \(MaskLive.shared.heldByGPU), the GPU done \(spread(MaskLive.shared.timings.values.map(\.gpu).filter { $0 > 0 })), presents \(MaskLive.shared.presents); drawables never shown: \(MaskLive.shared.unshown); the slowest moves: " + MaskLive.shared.timings.values.sorted { $0.handed > $1.handed }.prefix(5)
            .map { String(format: "%.1f ms (the drawable at %.1f%@)", $0.handed, $0.drawable, $0.first ? ", the press's" : "") }.joined(separator: ", "))
        for (tag, v) in pressHeld.sorted(by: { $0.key < $1.key }) {
            r.unreached("cost: NOT within the bar — the moves the press's own turn held back on \(tag) (the page's update for the drag's step, before the stream caught up): \(spread(v)) moves")
        }
        for (tag, v) in presented.sorted(by: { $0.key < $1.key }) {
            r.unreached("cost: a move → its drawable on the screen on \(tag) (presentedTime; the display's own frame included): \(spread(v)); the GPU done: \(spread(gpu[tag] ?? []))")
        }
        r.unreached("cost: a move's model (the session, the overlay's ask) when the overlay is ready: \(spread(tools.paid)); the stream's moves came \(gaps.map { "\($0.key): " + spread($0.value) }.joined(separator: "; ")) apart; late moves (index: ms) \(late.joined(separator: ", "))")
        for (tag, v) in actor.sorted(by: { $0.key < $1.key }) {
            r.unreached("cost: the main actor's time in a move of the display-rate stream on \(tag): \(spread(v))")
        }
        for (tag, v) in turn.sorted(by: { $0.key < $1.key }) {
            r.check(!v.isEmpty, "cost: a stroke's turnaround to the exact overlay on \(tag) (the catch-up behind the live stroke)",
                    "\(spread(v)) moves (interleaved with the other frame; \(loadWords))")
        }
        for (tag, v) in parts.sorted(by: { $0.key < $1.key }) {
            let names = ["the move to the ask (the view's update; includes the poll's 2 ms)", "the hop to the task", "the bake", "the overlay's render", "the hop back"]
            let medians = (0..<5).map { i in median(v.map { $0[i] }) }
            r.unreached("cost: a turnaround on \(tag), medians: " + zip(names, medians).map { String(format: "%@ %.1f ms", $0, $1) }.joined(separator: ", "))
        }
        for (tag, v) in develop.sorted(by: { $0.key < $1.key }) {
            r.check(!v.isEmpty, "cost: a 场景 stroke's develop at the live tier on \(tag)",
                    String(format: "median %.0f ms over %d (%@ ms; load %.2f)", median(v), v.count, v.map { String(Int($0)) }.joined(separator: ", "), load[0]))
        }
        tools.putDown()
    }

    // MARK: the live stroke against the exact overlay

    /// A picture's bytes as they are (RGBA8, premultiplied, Display P3: the overlay's own format, so no conversion).
    static func rawBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// **No jump at the lift** (2.4.0 A1): the live drawing of a stroke (`MaskLive.snapshot`, the composite as it is
    /// presented) against the exact overlay that replaces it, pixel for pixel on the overlay's grid — a hard brush on a
    /// new layer, a soft one with half flow over it, the eraser across both, the mask alone, and a feathered layer
    /// (whose live edge is the stroke's coverage blurred by the plane's σ, not the folded plane blurred).
    static func liveMatches(_ m: AppServices, _ r: R, a: LibraryFrame) async {
        guard MaskLive.enabled, let s = await MacMasksCheck.develop(m, a.id) else { return }
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        tools.putDown(); tools.held = true; tools.alone = false
        await MacMasksCheck.settle(m)
        let metric = MaskMetric(source: a.originalSize)
        // The brush's circle: moved in the pointer's own handler, so it is where the pointer is before this turn ends
        // (no SwiftUI update, no frame between), at the brush's size there; gone with the brush put down.
        tools.setSettings(.brush, BrushSettings(radius: 0.03, hardness: 0.5, flow: 1))
        tools.light(.brush)
        await MacMasksCheck.pause(0.3)
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
           let view = { () -> MaskPointerView? in
               func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
               return all(window).compactMap { $0 as? MaskPointerView }.first
           }(), let placed = MaskStageProbe.placed {
            let p = CGPoint(x: placed.shown.midX + 13, y: placed.shown.midY - 7)
            view.place(p)
            let now = view.ringNow
            let stage = MaskStage(session: s, frameID: a.id, source: a.originalSize, shown: placed.shown, area: placed.area, toS: placed.toS)
            let want = CGFloat(0.03) * stage.viewPerMetric(at: stage.toSource(p))
            tools.putDown()
            view.place(p)
            let gone = view.ringNow == nil
            r.check(now.map { hypot($0.at.x - p.x, $0.at.y - p.y) < 0.01 && abs($0.r - want) <= max(1, want * 0.02) } == true && gone,
                    "live: the brush's circle is under the pointer in the pointer's own event, at the brush's size; gone with the brush put down",
                    "circle \(now.map { String(format: "(%.1f, %.1f) r %.1f", $0.at.x, $0.at.y, $0.r) } ?? "hidden") for (\(p.x), \(p.y)) r \(String(format: "%.1f", want)); put down: \(gone ? "gone" : "still shown")")
        } else {
            r.check(false, "live: the pointer's view is on the stage")
        }
        func compare(_ name: String, tool: MaskTool, brush: BrushSettings, points: [MaskPoint], bar: (mean: Double, over: Double)) async {
            tools.setSettings(tool, brush)
            tools.light(tool); tools.optionHeld = false
            guard tools.beginStroke(s, at: points[0], frame: a.id, straight: false) else { return r.check(false, "live: \(name): the stroke began") }
            tools.continueStroke(s, to: Array(points.dropFirst()), metric: metric)
            _ = await MacMasksCheck.until(5, every: 10) { MaskLive.shared.hasPlane || s.maskLayers?.items.isEmpty != false }
            await MacMasksCheck.pause(0.05)
            let live = await MaskLive.shared.snapshot()
            tools.endDrag(s, frame: a.id)
            guard let l = s.pickedMaskLayer else { return r.check(false, "live: \(name): a layer") }
            let key = MaskBaker.planeKey(l, source: a.originalSize)
            _ = await MacMasksCheck.until(10, every: 10) { MaskOverlay.shared.made?.planeKey == key }
            guard let live, let made = MaskOverlay.shared.made, made.planeKey == key, let cg = made.image.cgImage, let exact = rawBytes(cg),
                  cg.width == live.w, cg.height == live.h else {
                return r.check(false, "live: \(name): the live drawing and the exact overlay on one grid",
                               "live \(live.map { "\($0.w)x\($0.h)" } ?? "none"), exact \(MaskOverlay.shared.made.flatMap { $0.image.cgImage.map { "\($0.width)x\($0.height)" } } ?? "none")")
            }
            var sum = 0.0, over = 0, worst = 0, marked = 0
            for i in 0..<(live.w * live.h) {
                var d = 0
                for c in 0..<4 { d = max(d, abs(Int(live.bytes[i * 4 + c]) - Int(exact[i * 4 + c]))) }
                sum += Double(d); worst = max(worst, d)
                if d > 8 { over += 1 }
                if exact[i * 4 + 3] > 0 || live.bytes[i * 4 + 3] > 0 { marked += 1 }
            }
            let n = Double(live.w * live.h), share = Double(over) / Double(max(marked, 1)) * 100
            r.check(sum / n <= bar.mean && share <= bar.over,
                    "live: \(name): the live drawing is the exact overlay that replaces it at the lift (mean ≤ \(bar.mean) of 255, ≤ \(bar.over) % of the marked pixels off by more than 8)",
                    String(format: "mean %.3f, worst %d, %.3f %% of %d marked pixels off by more than 8, %dx%d", sum / n, worst, share, marked, live.w, live.h))
        }
        let line = (0...10).map { MaskPoint(0.25 + 0.04 * Double($0), 0.45 + 0.03 * sin(Double($0))) }
        await compare("a hard brush, a new layer", tool: .brush, brush: BrushSettings(radius: 0.03, hardness: 1, flow: 1), points: line, bar: (0.5, 0.5))
        await compare("a soft brush at half flow over it", tool: .brush, brush: BrushSettings(radius: 0.04, hardness: 0.3, flow: 0.5),
                      points: line.map { MaskPoint($0.x, $0.y + 0.03) }, bar: (0.5, 0.5))
        await compare("the eraser across both", tool: .eraser, brush: BrushSettings(radius: 0.02, hardness: 0.6, flow: 1),
                      points: (0...8).map { MaskPoint(0.45 + 0.005 * Double($0), 0.3 + 0.04 * Double($0)) }, bar: (0.5, 0.5))
        tools.held = false; tools.alone = true
        await MacMasksCheck.settle(m)
        await compare("a stroke on the mask alone", tool: .brush, brush: BrushSettings(radius: 0.02, hardness: 0.8, flow: 1),
                      points: line.map { MaskPoint($0.x, $0.y - 0.1) }, bar: (0.5, 0.5))
        tools.alone = false; tools.held = true
        if let id = s.layerPick.maskID { s.changeLayer(id) { $0.feather = 0.01 } }
        await MacMasksCheck.settle(m)
        await compare("a stroke on a feathered layer (羽化 0.01)", tool: .brush, brush: BrushSettings(radius: 0.02, hardness: 1, flow: 1),
                      points: line.map { MaskPoint($0.x, $0.y + 0.15) }, bar: (0.5, 0.5))
        tools.putDown(); tools.held = false
        s.change { $0.layers = nil }
        await MacMasksCheck.settle(m)
    }

    // MARK: the drawings

    static func drawings(_ m: AppServices, _ r: R, a: LibraryFrame) async {
        guard let s = await MacMasksCheck.develop(m, a.id) else { return r.check(false, "drawings 04–07: A") }
        s.show(.develop)
        s.change { $0.layers = nil }
        s.pick(row: .film)
        await MacMasksCheck.settle(m)
        // 04: 画笔 lit, a stroke painted, the overlay on, the cursor on the picture, the pill's popover open.
        tools.setSettings(.brush, BrushSettings(radius: 0.02, hardness: 0.6, flow: 1))
        stroke(s, a.id, [MaskPoint(0.30, 0.35), MaskPoint(0.38, 0.42), MaskPoint(0.46, 0.45), MaskPoint(0.52, 0.52)])
        tools.light(.brush)
        tools.held = true
        if let p = MaskStageProbe.placed { MaskStageProbe.hover = CGPoint(x: p.shown.minX + 0.62 * p.shown.width, y: p.shown.minY + 0.55 * p.shown.height) }
        tools.popover = true
        await MacMasksCheck.settle(m)
        await MacMasksCheck.captured("04-brush")
        tools.popover = false
        MaskStageProbe.hover = nil
        // 05: a linear gradient's lines and handles, the end tags shown as while the pointer is down.
        s.change { $0.layers = nil }
        gradient(s, a.id, .linear, from: MaskPoint(0.5, 0.15), to: MaskPoint(0.55, 0.55))
        MaskStageProbe.pressed = true
        await MacMasksCheck.settle(m)
        await MacMasksCheck.captured("05-linear-gradient")
        MaskStageProbe.pressed = false
        // 06: a radial gradient: the ellipse, the feather ring, the handles.
        s.change { $0.layers = nil }
        gradient(s, a.id, .radial, from: MaskPoint(0.5, 0.45), to: MaskPoint(0.7, 0.75))
        await MacMasksCheck.settle(m)
        await MacMasksCheck.captured("06-radial-gradient")
        // 07: the mask alone, with its tag and the strip's line.
        tools.putDown()
        tools.held = false
        tools.alone = true
        await MacMasksCheck.settle(m)
        await MacMasksCheck.captured("07-mask-alone")
        // The page hands the strip the line; whether it is drawn is the strip's own fit (`MacInfoStrip.Fit`: the name and
        // the rating first, a part left off whole). This check's file is called "a-00_extreme-EV__DSC6506.NEF" in a
        // 1,100-point window, which leaves no room: held at the same width with a camera's own name (drawing 07's).
        let strip = MacInfoStrip.drawn
        let fit = MacInfoStrip.Fit(image: MacInfoStrip.Item(name: "DSC_0412.NEF"), status: (L("Show Mask Alone"), false),
                                   room: (strip?.width ?? 0) - 2 * MacMetric.pt(10), gap: MacMetric.pt(14))
        r.check(strip?.asked == L("Show Mask Alone") && fit.status == L("Show Mask Alone"), "the mask alone: the strip's line says 仅显示蒙版",
                "handed \(strip?.asked ?? "nil"); drawn here \(strip?.shown ?? "nil") (this file's long name), with DSC_0412.NEF at \(Int(strip?.width ?? 0)) pt: \(fit.status ?? "nil")")
        tools.alone = false
        s.change { $0.layers = nil }
    }

    // MARK: run 2

    /// After the relaunch: the kept strokes undone one at a time.
    static func kept(_ m: AppServices, _ r: R, frame: UUID, strokes: Int) async {
        guard let s = await MacMasksCheck.develop(m, frame) else { return r.check(false, "kept strokes: the frame opens") }
        let count = { s.edit.layers?.items.compactMap { $0.parts.first?.brush?.strokes.count }.first ?? 0 }
        let read = count()
        _ = s.undo()
        await MacMasksCheck.pause(0.5)
        let after = count()
        _ = s.redo()
        await MacMasksCheck.pause(0.4)
        r.check(read == strokes && after == strokes - 1 && count() == strokes,
                "kept: after a relaunch the strokes read back (\(read) of \(strokes)); Undo takes the last stroke (\(after)), Redo brings it")
    }
}
#endif
