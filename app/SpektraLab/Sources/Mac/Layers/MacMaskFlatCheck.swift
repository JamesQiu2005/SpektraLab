//  MacMaskFlatCheck.swift — is the overlay drawn on the mask? `--masks-check`'s geometry on a flat frame (M1c step 0b;
//  MASKS-SPEC §6.1, §12's row 6; PRD-E §7 item 6).
//
//  M1b's geometry case held the overlay's centroid to the developed effect's centroid within 2 % of the picture and
//  found them a steady ~2.5 pt apart along the photograph's y in every framing — on a photograph, where the effect's
//  centroid is weighted by what the picture holds (a −3 EV layer takes more codes from a bright sky than from a dark
//  road). This case asks the question with nothing to weigh: **a flat grey frame** (`tools/flat_frame.py`, sRGB 118,
//  3000 × 2000, written by the shell into the scratch import) with grain, halation and glare off, and it compares
//  **edges**, not centroids: across a hard brush stroke (one horizontal and one vertical in S) and across a linear
//  gradient's middle, where the overlay's mask (its alpha ÷ the overlay's 0.5) crosses ½ against where the developed
//  effect's mask crosses ½, along the edge's normal in the view, in canvas pixels. The effect's mask is the difference
//  over its plateau in 冲洗 (a 场景 layer: the film's response is not linear, so only the hard stroke is held there) and
//  log₂ of the linear ratio over the layer's stops in 编辑 (Edit's 曝光 is a gain in linear light), so the gradient's
//  middle is held in 编辑. Each framing: as it is, 冲洗's crop, 编辑's crop, a straighten, a quarter turn, a flip, a film
//  edge.
//
//  Each edge is also held against **where it should be**: the stroke's line and radius in S taken to the view through
//  the stage's own matrix. So the overlay is held to the stroke, and the developed effect to it apart (the engine's own
//  placement, which the overlay must not be bent to follow): the bars and what they were measured at are `bar`'s note.
//
//  `--masks-check-break geometry-halftexel` moves the overlay half a canvas pixel down (`MaskStageProbe`): red.

#if DEBUG && SPK_ENGINE
import CoreGraphics
import Foundation
import UIKit

@MainActor
enum MacMaskFlatCheck {
    typealias R = MacMasksCheck.Report
    static var tools: MaskTools { .shared }
    /// **The bars, against where the stroke is in S** (the stroke's line and radius taken through the stage's own matrix
    /// to the view): how far each of its two edges' mean is moved, in canvas pixels. Measured 2026-11-13 on this Mac
    /// (M1c review item 3), after the overlay was drawn at its exact pixel size (`MaskOverlay.drawnRect`, which took the
    /// −0.20 px every framing had): the overlay 0.00–0.06 as it is, with a flip and both crops, ±0.25 with a quarter turn
    /// and −0.25 across S's y-stroke with a film edge (a term of the view's still not found); the developed effect itself
    /// 0.00–0.06, but −0.28 / +0.19 with a film edge in 冲洗 — the engine's own sub-pixel placement of the gate (the
    /// effect against the stroke, the overlay not in it). Each bar just above its worst; ½ canvas pixel, the self-test's
    /// broken mapping, is above the overlay's. Every single edge, overlay against effect, within 1 canvas pixel.
    static let bar = 0.35
    static let effectBar = 0.35

    /// A picture's pixels as linear-light luma and as sRGB codes' luma, at its own size.
    struct Plane { var w: Int; var h: Int; var codes: [Double]; var linear: [Double] }

    static func plane(_ image: CGImage) -> Plane? {
        guard let p = MacMaskToolsCheck.pixels(image) else { return nil }
        var codes = [Double](repeating: 0, count: p.w * p.h), lin = codes
        func l(_ c: UInt8) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        for i in 0..<(p.w * p.h) {
            let r = p.px[4 * i], g = p.px[4 * i + 1], b = p.px[4 * i + 2]
            codes[i] = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            lin[i] = 0.2126 * l(r) + 0.7152 * l(g) + 0.0722 * l(b)
        }
        return Plane(w: p.w, h: p.h, codes: codes, linear: lin)
    }

    /// Bilinear at a point in pixels (centres at +½).
    static func sample(_ v: [Double], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Double? {
        let fx = x - 0.5, fy = y - 0.5
        guard fx >= 0, fy >= 0, fx < Double(w - 1), fy < Double(h - 1) else { return nil }
        let x0 = Int(fx), y0 = Int(fy), tx = fx - Double(x0), ty = fy - Double(y0)
        let a = v[y0 * w + x0], b = v[y0 * w + x0 + 1], c = v[(y0 + 1) * w + x0], d = v[(y0 + 1) * w + x0 + 1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// Where `f` (sampled along t) crosses ½ going from `from` toward `to`, linearly between samples.
    static func crossing(_ f: (Double) -> Double?, from: Double, to: Double, step: Double) -> Double? {
        var t = from, last: (Double, Double)?
        let dir = to > from ? 1.0 : -1.0
        while (to - t) * dir >= 0 {
            guard let v = f(t) else { return nil }
            if let (lt, lv) = last, (lv - 0.5) * (v - 0.5) <= 0, lv != v { return lt + (0.5 - lv) / (v - lv) * (t - lt) }
            last = (t, v)
            t += step * dir
        }
        return nil
    }

    static func run(_ m: AppServices, _ r: R, flat: LibraryFrame, broken: String?) async {
        MaskStageProbe.broken = broken == "geometry-halftexel" ? "halftexel" : nil
        defer { MaskStageProbe.broken = nil }
        guard let s = await MacMasksCheck.develop(m, flat.id) else { return r.check(false, "flat: the flat frame opens") }
        s.change { e in
            e.layers = nil; e.geometry = .default; e.printCrop = .default; e.filmEdge.active = false
            e.params.effects.grain = 0; e.params.effects.halation = 0; e.params.effects.glare = 0
        }
        tools.putDown(); tools.held = false; tools.alone = false
        tools.setSettings(.brush, BrushSettings(radius: 0.02, hardness: 1, flow: 1))
        var worst = 0.0, worstShift = 0.0, worstEffect = 0.0
        for stage in [LayerStage.scene, .finished] {
            s.show(stage == .scene ? .develop : .edit)
            s.change { $0.layers = nil }
            s.pick(row: .film)
            await MacMasksCheck.settle(m)
            // Two hard strokes in one layer: across S's y and across its x.
            MacMaskToolsCheck.stroke(s, flat.id, [MaskPoint(0.25, 0.40), MaskPoint(0.40, 0.40), MaskPoint(0.55, 0.40)])
            guard let id = s.layerPick.maskID else { r.check(false, "flat (\(stage.rawValue)): a stroke makes a layer"); continue }
            MacMaskToolsCheck.stroke(s, flat.id, [MaskPoint(0.75, 0.25), MaskPoint(0.75, 0.45), MaskPoint(0.75, 0.65)])
            tools.putDown()
            let stops = -2.0
            s.changeLayer(id) { l in if stage == .scene { l.scene?.exposure = stops } else { l.finished?.exposure = stops } }
            // 编辑: a linear gradient as a layer of its own, its middle across S's x at 0.4 … 0.6 down the frame.
            var gid: UUID?
            if stage == .finished {
                s.pick(row: .film)
                MacMaskToolsCheck.gradient(s, flat.id, .linear, from: MaskPoint(0.45, 0.60), to: MaskPoint(0.45, 0.80))
                gid = s.layerPick.maskID
                tools.putDown()
                if let gid { s.changeLayer(gid) { $0.finished?.exposure = stops } }
            }
            let framings: [(String, (inout FrameEdit) -> Void)] = [
                ("as it is", { _ in }),
                ("冲洗's crop", { $0.geometry.crop = CropRect(x: 0.15, y: 0.1, width: 0.75, height: 0.8) }),
                ("编辑's crop", { $0.geometry = .default; $0.printCrop.crop = CropRect(x: 0.1, y: 0.12, width: 0.8, height: 0.75) }),
                ("a straighten", { $0.printCrop = .default; $0.geometry.angle = 7 }),
                ("a quarter turn", { $0.geometry = .default; $0.geometry.quarterTurns = 1 }),
                ("a flip", { $0.geometry = .default; $0.geometry.flipH = true }),
                ("a film edge", { $0.geometry = .default; $0.filmEdge.active = true }),
            ]
            for (name, mutate) in framings {
                let stamp = s.developed?.stamp
                s.change(mutate)
                _ = await MacMasksCheck.until(60, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp }
                await MacMasksCheck.settle(m)
                // Each layer alone against none: the stroke's, then the gradient's.
                for (what, layer) in [("strokes", id), ("gradient", gid)] {
                    guard let layer else { continue }
                    let others = (s.edit.layers?.items ?? []).map(\.id).filter { $0 != layer }
                    for o in others { s.setLayerOn(o, false) }
                    s.setLayerOn(layer, false)
                    await settled(s, m, stage: stage)
                    guard let plainImage = await picture(s, m, stage: stage) else { r.check(false, "flat: \(name): the plain picture"); continue }
                    s.setLayerOn(layer, true)
                    s.pick(row: .mask(layer))
                    await settled(s, m, stage: stage)
                    var overlay = await MacMaskToolsCheck.overlay(s)
                    if overlay == nil { await MacMasksCheck.settle(m); overlay = await MacMaskToolsCheck.overlay(s) }     // a mode just switched
                    guard let layeredImage = await picture(s, m, stage: stage), let ov = overlay,
                          let oc = ov.made.image.cgImage, let o = MacMaskToolsCheck.pixels(oc),
                          let base = plane(plainImage), let lay = plane(layeredImage), base.w == lay.w, base.h == lay.h else {
                        r.check(false, "flat (\(stage.rawValue)): \(name), \(what): the pictures and the overlay"); continue
                    }
                    for o in others { s.setLayerOn(o, true) }
                    guard let f = s.frame else { continue }
                    let size = DevelopedFrameView.finishedSize(frame: f, edit: s.edit, model: m, developed: s.developed)
                    let crop = s.edit.printCrop.onFinished(size)
                    let toEffect = crop.isIdentity ? MaskMatrix.identity : MaskMatrix.through { crop.sourcePoint(forOutput: $0, imageSize: size) }
                    let shown = ov.placed.shown, rect = ov.made.rect
                    let ppt = Double(o.w) / Double(rect.width)                     // canvas pixels a point
                    let alpha = (0..<(o.w * o.h)).map { Double(o.px[4 * $0 + 3]) / 255 / MaskOverlay.alpha }
                    func overlayMask(_ q: CGPoint) -> Double? {
                        sample(alpha, o.w, o.h, Double(q.x - rect.minX) * ppt, Double(q.y - rect.minY) * Double(o.h) / Double(rect.height))
                    }
                    // The effect as a mask: the difference over its plateau (冲洗), or log₂ of the linear ratio over the stops.
                    let diff = zip(lay.codes, base.codes).map { abs($0 - $1) }
                    let ratio = zip(lay.linear, base.linear).map { log2(max($0, 1e-6) / max($1, 1e-6)) / stops }
                    let byRatio = stage == .finished
                    let plateau: Double = {
                        let p = MaskPoint(0.40, 0.40)
                        let n = ov.placed.toS.inverted.apply(CGPoint(x: p.x, y: p.y))
                        let e = toEffect.apply(n)
                        return sample(diff, lay.w, lay.h, e.x * Double(lay.w), e.y * Double(lay.h)) ?? 1
                    }()
                    func effectMask(_ q: CGPoint) -> Double? {
                        let n = CGPoint(x: (q.x - shown.minX) / shown.width, y: (q.y - shown.minY) / shown.height)
                        let e = toEffect.apply(n)
                        let x = Double(e.x) * Double(lay.w), y = Double(e.y) * Double(lay.h)
                        return byRatio ? sample(ratio, lay.w, lay.h, x, y) : sample(diff, lay.w, lay.h, x, y).map { $0 / max(plateau, 1e-6) }
                    }
                    func view(_ p: MaskPoint) -> CGPoint {
                        let n = ov.placed.toS.inverted.apply(CGPoint(x: p.x, y: p.y))
                        return CGPoint(x: shown.minX + n.x * shown.width, y: shown.minY + n.y * shown.height)
                    }
                    // The scans: across each stroke at five places, both its edges; across the gradient's middle.
                    var gaps: [Double] = []
                    // Signed along each scan's own axis, by the stroke it crosses: their mean is how far the overlay is
                    // moved across that stroke (a width error cancels between its two edges).
                    var signed: [Int: [Double]] = [:]
                    var scanIndex = 0
                    // Each edge against where it should be (overlay, effect), in canvas pixels, by stroke.
                    var fromTruth: [Int: [(Double, Double)]] = [:]
                    let scans: [(MaskPoint, MaskPoint, Bool)] = what == "strokes"
                        ? (0..<5).map { k in let t = 0.3 + 0.2 * Double(k) / 4
                            return (MaskPoint(0.25 + 0.3 * t, 0.40), MaskPoint(0.25 + 0.3 * t, 0.41), true) }
                          + (0..<5).map { k in let t = 0.3 + 0.2 * Double(k) / 4
                            return (MaskPoint(0.75, 0.25 + 0.4 * t), MaskPoint(0.76, 0.25 + 0.4 * t), true) }
                        : (0..<5).map { k in let x = 0.3 + 0.1 * Double(k)
                            return (MaskPoint(x, 0.70), MaskPoint(x, 0.71), false) }
                    for (c, toward, both) in scans {
                        let group = scanIndex < 5 ? 0 : 1
                        scanIndex += 1
                        let a = view(c), b = view(toward)
                        let len = max(hypot(b.x - a.x, b.y - a.y), 1e-6)
                        let nrm = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
                        // Three of the stroke's radii (0.02 of S's long edge) in view points, either side.
                        let long = Double(max(flat.originalSize.width, flat.originalSize.height))
                        let rx = view(MaskPoint(c.x + 0.02 * long / Double(flat.originalSize.width), c.y))
                        let span = 3 * Double(hypot(rx.x - a.x, rx.y - a.y))
                        func along(_ f: @escaping (CGPoint) -> Double?) -> (Double) -> Double? {
                            { t in f(CGPoint(x: a.x + nrm.x * CGFloat(t), y: a.y + nrm.y * CGFloat(t))) }
                        }
                        let step = 0.25 / ppt
                        let sides: [(Double, Double)] = both ? [(0, span), (0, -span)] : [(-span, span)]
                        for (from, to) in sides {
                            guard let co = crossing(along(overlayMask), from: from, to: to, step: step),
                                  let ce = crossing(along(effectMask), from: from, to: to, step: step) else { continue }
                            let g = (co - ce) * ppt
                            gaps.append(abs(g))
                            signed[what == "strokes" ? group : 2, default: []].append(g)
                            // Where the edge should be: the stroke's radius from its line, along the scan, in S → view.
                            if what == "strokes" {
                                let w = Double(flat.originalSize.width), h = Double(flat.originalSize.height)
                                let edgeS = group == 0 ? MaskPoint(c.x, c.y + 0.02 * long / h) : MaskPoint(c.x + 0.02 * long / w, c.y)
                                let e = view(edgeS)
                                let d = Double(hypot(e.x - a.x, e.y - a.y)) * (to > from ? 1 : -1)
                                // Along the scan's own axis: their mean over both edges is how far each is moved from
                                // where the stroke is (a width error cancels between its two edges).
                                fromTruth[group, default: []].append(((co - d) * ppt, (ce - d) * ppt))
                            }
                        }
                    }
                    let expected = what == "strokes" ? 20 : 5
                    let most = gaps.max() ?? .infinity
                    func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count) }
                    // The 成片 layer's effect read back as a mask inside the stroke (1 where Edit's 曝光 is a gain in linear light).
                    let inside: Double = {
                        let p = MaskPoint(0.40, 0.40), n = ov.placed.toS.inverted.apply(CGPoint(x: p.x, y: p.y)), e = toEffect.apply(n)
                        return sample(ratio, lay.w, lay.h, e.x * Double(lay.w), e.y * Double(lay.h)) ?? .nan
                    }()
                    if what == "strokes" {
                        let across = [mean(signed[0] ?? []), mean(signed[1] ?? [])]
                        func truth(_ g: Int, _ k: Int) -> Double { mean((fromTruth[g] ?? []).map { k == 0 ? $0.0 : $0.1 }) }
                        let overlayMoved = [truth(0, 0), truth(1, 0)].map(abs).max() ?? .infinity
                        let effectMoved = [truth(0, 1), truth(1, 1)].map(abs).max() ?? .infinity
                        worst = max(worst, gaps.count == expected ? most : .infinity)
                        worstShift = max(worstShift, overlayMoved)
                        worstEffect = max(worstEffect, effectMoved)
                        let line = String(format: "%@ (%@): %d of %d edges, worst overlay against effect %.2f canvas px (bar 1); moved from where the stroke is in S — overlay %+.2f / %+.2f (bar %.2f), developed effect %+.2f / %+.2f (bar %.2f); overlay against effect across S's x-stroke %+.2f, its y-stroke %+.2f; %.2f px a point; the 成片 effect read as a mask inside %.3f",
                                          name, stage.rawValue, gaps.count, expected, most, truth(0, 0), truth(1, 0), bar,
                                          truth(0, 1), truth(1, 1), effectBar, across[0], across[1], ppt, inside)
                        r.check(gaps.count == expected && most <= 1 && overlayMoved <= bar && effectMoved <= effectBar,
                                "flat geometry: \(name) in \(stage == .scene ? "冲洗" : "编辑"): the overlay where the stroke is, and on the developed effect", line)
                    } else {
                        // The gradient's middle: told, not held — Edit's 曝光 is not a pure gain in linear light (the value
                        // inside the stroke above), so the effect's ½ is not the mask's ½; the strokes hold the mapping.
                        r.unreached(String(format: "flat geometry: %@ (编辑), the gradient's middle: the overlay's ½ %+.2f canvas px from the effect's ½ read through a pure gain (5 of %d scans)",
                                           name, mean(signed[2] ?? []), gaps.count))
                    }
                }
            }
            s.change { $0.layers = nil; $0.geometry = .default; $0.printCrop = .default; $0.filmEdge.active = false }
            tools.held = false
        }
        r.unreached(String(format: "flat geometry: over every framing and both modes, the worst edge overlay against effect %.2f canvas px (bar 1); the overlay moved from where the stroke is at most %.2f (bar %.2f); the developed effect at most %.2f (bar %.2f, the engine's)", worst, worstShift, bar, worstEffect, effectBar))
    }

    /// A 场景 layer's change develops; a 成片 layer's is the pass's.
    static func settled(_ s: OpenFrameSession, _ m: AppServices, stage: LayerStage) async {
        if stage == .scene {
            let stamp = s.developed?.stamp
            _ = await MacMasksCheck.until(30, every: 100) { s.developed?.stamp != stamp && !s.isCatchingUp }
        }
        await MacMasksCheck.settle(m)
    }

    static func picture(_ s: OpenFrameSession, _ m: AppServices, stage: LayerStage) async -> CGImage? {
        if stage == .scene { return s.developedCGImage }
        guard let f = s.frame else { return nil }
        // With no 成片 layer on, the pass draws nothing: the canvas is the develop.
        guard let key = m.finishedLayers(f, edit: s.edit)?.key else { return s.developedCGImage }
        return await MacMasksCheck.shown(s, layers: key)
    }
}
#endif
