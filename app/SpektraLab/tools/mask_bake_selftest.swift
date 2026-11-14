//  mask_bake_selftest.swift — `MaskBaker` on this Mac's GPU against the arithmetic of RFC-052 §4 written again here in
//  double, part by part, and the fold, the feather, the invert, the brush's incremental drawing (RFC-052 §4.1).
//
//      tools/selftest.sh       # with the other checks
//
//  Each case states its bar in 16-bit counts. Each can fail: `--self-test` hands the reference a broken term
//  (smoothstep for a straight ramp, a radius off by 1 %, the max/min family for the products, no feather) and
//  expects red.

import Foundation
import Metal

@main struct MaskBakeSelftest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("ok    \(what)") } else { failed += 1; print("FAIL  \(what)") }
    }

    static let source = PixelSize(width: 3000, height: 2000)
    /// Small planes keep the double reference quick; the arithmetic does not depend on the size (metric units).
    static let small = 600

    static func s01(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        e0 == e1 ? (x < e0 ? 0 : 1) : s01(min(max((x - e0) / (e1 - e0), 0), 1))
    }

    struct Ref { var broken: String? = nil }

    /// A part's coverage at S = (s, t) in double (RFC-052 §4.1).
    static func coverage(_ p: MaskPart, s: Double, t: Double, ax: Double, ay: Double, ref: Ref) -> Double {
        let x = s * ax, y = t * ay
        switch p.kind {
        case .linear:
            let g = p.linear!
            let a = (g.a.x * ax, g.a.y * ay), d = (g.b.x * ax - g.a.x * ax, g.b.y * ay - g.a.y * ay)
            let l2 = d.0 * d.0 + d.1 * d.1
            guard l2 > 0 else { return 0 }
            let u = min(max(((x - a.0) * d.0 + (y - a.1) * d.1) / l2, 0), 1)
            return 1 - (ref.broken == "ramp" ? u : s01(u))
        case .radial:
            let g = p.radial!
            let th = g.angle * .pi / 180
            let qx = x - g.centre.x * ax, qy = y - g.centre.y * ay
            let u = qx * cos(th) + qy * sin(th), v = -qx * sin(th) + qy * cos(th)
            let rx = g.rx * (ref.broken == "radius" ? 1.01 : 1)
            let d = ((u / rx) * (u / rx) + (v / g.ry) * (v / g.ry)).squareRoot()
            return 1 - smooth(1 - g.feather, 1, d)
        default: return 0
        }
    }

    static func fold(_ m: Double, _ c: Double, _ j: MaskPart.Join, maxMin: Bool) -> Double {
        if !maxMin {
            switch j { case .add: return m + c - m * c; case .subtract: return m * (1 - c); case .intersect: return m * c }
        }
        switch j { case .add: return max(m, c); case .subtract: return max(m - c, 0); case .intersect: return min(m, c) }
    }

    /// The layer's plane in double: parts, fold, feather (separable, clamped), invert.
    static func reference(_ l: LocalLayer, w: Int, h: Int, ref: Ref, family: JoinFamily) -> [Double] {
        let long = Double(source.longEdge), ax = Double(source.width) / long, ay = Double(source.height) / long
        var m = [Double](repeating: 0, count: w * h)
        for p in l.foldOrder {
            for j in 0..<h { for i in 0..<w {
                let c = coverage(p, s: (Double(i) + 0.5) / Double(w), t: (Double(j) + 0.5) / Double(h), ax: ax, ay: ay, ref: ref)
                m[j * w + i] = fold(m[j * w + i], c, p.join, maxMin: (family == .maxMin) != (ref.broken == "family"))
            } }
        }
        let sigma = ref.broken == "feather" ? 0 : l.feather * Double(max(w, h))
        if sigma > 0 {
            let r = Int((3 * sigma).rounded(.up))
            let k = (-r...r).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
            let ks = k.reduce(0, +)
            var tmp = m
            for j in 0..<h { for i in 0..<w { tmp[j * w + i] = (-r...r).reduce(0.0) { $0 + k[$1 + r] * m[j * w + min(max(i + $1, 0), w - 1)] } / ks } }
            for j in 0..<h { for i in 0..<w { m[j * w + i] = (-r...r).reduce(0.0) { $0 + k[$1 + r] * tmp[min(max(j + $1, 0), h - 1) * w + i] } / ks } }
        }
        return m.map { v in let c = min(max(v, 0), 1); return l.invert ? 1 - c : c }
    }

    static func worst(_ plane: MaskPlane, _ ref: [Double]) -> Double {
        zip(plane.values, ref).map { abs(Double($0) - $1 * 65535) }.max() ?? .infinity
    }

    static func layer(_ parts: [MaskPart], feather: Double = 0, invert: Bool = false) -> LocalLayer {
        var l = LocalLayer(name: "t", stage: .scene, parts: parts)
        l.feather = feather; l.invert = invert
        l.scene = SceneDeltas(exposure: 1)
        return l
    }

    static func main() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { print("no Metal device"); exit(1) }
        let selfTest = CommandLine.arguments.contains("--self-test")
        let baker = try MaskBaker(device: device)
        let cases: [(String, LocalLayer, Double)] = [
            ("linear gradient", layer([.linear(MaskLinear(a: MaskPoint(0.2, 0.3), b: MaskPoint(0.7, 0.6)))]), 1.0),
            ("radial, feather 0.6, 25 deg", layer([.radial(MaskRadial(centre: MaskPoint(0.45, 0.55), rx: 0.2, ry: 0.1, angle: 25, feather: 0.6))]), 1.0),
            ("crossed gradients (add)", layer([.linear(MaskLinear(a: MaskPoint(0, 0.5), b: MaskPoint(0.6, 0.5))),
                                               .linear(MaskLinear(a: MaskPoint(0.5, 0), b: MaskPoint(0.5, 0.7)))]), 1.0),
            ("a gradient less a soft radial, intersect, feather, invert",
             layer([.linear(MaskLinear(a: MaskPoint(0, 0), b: MaskPoint(1, 1))),
                    .radial(MaskRadial(centre: MaskPoint(0.5, 0.5), rx: 0.15, ry: 0.15, feather: 0.8), join: .subtract),
                    .linear(MaskLinear(a: MaskPoint(1, 0.5), b: MaskPoint(0.2, 0.5)), join: .intersect)],
                   feather: 0.01, invert: true), 1.0),
        ]
        let limit = small
        for (name, l, bar) in cases {
            for family in JoinFamily.allCases {
                let plane = try await baker.bake(l, source: source, family: family, maxLongEdge: limit)
                let r = reference(l, w: plane.width, h: plane.height, ref: Ref(), family: family)
                let e = worst(plane, r)
                expect(e <= bar, String(format: "%@ (%@), %dx%d: worst %.2f counts (bar %.0f)", name, family.rawValue, plane.width, plane.height, e, bar))
            }
            if selfTest {
                for broken in ["ramp", "radius", "family", "feather"] {
                    let plane = try await baker.bake(l, source: source, maxLongEdge: limit)
                    let e = worst(plane, reference(l, w: plane.width, h: plane.height, ref: Ref(broken: broken), family: .products))
                    if e > bar { print("ok    self-test: \(name) with \(broken) broken: red (\(Int(e)) counts)"); passed += 1 }
                    else if (broken == "ramp" && !l.parts.contains { $0.kind == .linear }) || (broken == "radius" && !l.parts.contains { $0.kind == .radial })
                              || (broken == "family" && l.parts.count < 2) || (broken == "feather" && l.feather == 0) {
                        continue    // the term is not in this case
                    } else { print("FAIL  self-test: \(name) with \(broken) broken stayed green"); failed += 1 }
                }
            }
        }
        // The equal-edges step: a radial of feather 0 is 1 inside and 0 outside, nothing between.
        let hardRadial = layer([.radial(MaskRadial(centre: MaskPoint(0.5, 0.5), rx: 0.2, ry: 0.2, feather: 0))])
        let hard = try await baker.bake(hardRadial, source: source, maxLongEdge: limit)
        expect(hard.values.allSatisfy { $0 == 0 || $0 == 65535 } && worst(hard, reference(hardRadial, w: hard.width, h: hard.height, ref: Ref(), family: .products)) == 0,
               "a radial of feather 0 is a step: only 0 and 65535, where the reference says")
        // A layer with no part, inverted: the whole picture, 65535 everywhere (the full-mask identity's plane).
        let full = try await baker.bake(layer([], invert: true), source: source)
        expect(full.width == 3000 && full.height == 2000 && full.values.allSatisfy { $0 == 65535 }, "an inverted empty mask is 65535 everywhere, at L_c = min(4096, 3000) = \(full.width) x \(full.height)")
        let big = MaskBaker.planeSize(source: PixelSize(width: 8256, height: 5504))
        expect(big.width == 4096 && big.height == 2731, "a 45 MP source's plane is \(big.width) x \(big.height)")
        // Found: an 8-bit picture sampled bilinear; 背景 is its inverse, and the two sum to one at every texel.
        let pic = FoundPicture(width: 64, height: 40, bytes: (0..<(64 * 40)).map { UInt8(($0 % 64) * 4 % 256) })
        let fm = FoundMask(what: .subject, width: 64, height: 40)
        var bg = fm; bg.invert = true
        let subject = try await baker.bake(layer([.found(fm, asset: "a")]), source: source, found: ["a": pic], maxLongEdge: limit)
        let background = try await baker.bake(layer([.found(bg, asset: "a")]), source: source, found: ["a": pic], maxLongEdge: limit)
        let sum = zip(subject.values, background.values).map { Int($0) + Int($1) }
        expect(sum.allSatisfy { abs($0 - 65535) <= 1 }, "背景 + 主体 = 1 at every texel (within a count: two roundings), \(sum.min()!)…\(sum.max()!)")
        // The brush: one hard straight pass of flow F leaves F on its centre line (RFC-052 §4.1: 20 dabs cover it).
        for flow in [0.3, 0.7, 1.0] {
            let stroke = BrushStroke(radius: 0.05, hardness: 1, flow: flow, points: [MaskPoint(0.1, 0.5), MaskPoint(0.9, 0.5)])
            let p = try await baker.bake(layer([.brush(BrushStrokes(strokes: [stroke]))]), source: source, maxLongEdge: limit)
            let row = p.height / 2, v = p.values
            let mid = (p.width / 4...3 * p.width / 4).map { Double(v[row * p.width + $0]) / 65535 }
            let off = mid.map { abs($0 - flow) }.max()!
            expect(off <= 0.02, String(format: "a hard pass of flow %.1f leaves %.4f…%.4f on its centre line (bar ±0.02: a dab's 20-fold cover is exact on the line between whole dabs only)", flow, mid.min()!, mid.max()!))
        }
        // Erasing: a paint then an erase of flow 1 along the same line leaves nothing on it.
        let line = [MaskPoint(0.1, 0.5), MaskPoint(0.9, 0.5)]
        let pe = try await baker.bake(layer([.brush(BrushStrokes(strokes: [BrushStroke(radius: 0.05, hardness: 1, flow: 1, points: line),
                                                                        BrushStroke(radius: 0.06, hardness: 1, flow: 1, erase: true, points: line)]))]),
                                       source: source, maxLongEdge: limit)
        expect(pe.values.max()! == 0, "an erase of flow 1 over a paint leaves 0 (max \(pe.values.max()!))")
        // Incremental: 70 strokes drawn, then a 71st drawn onto that plane, is the 71 drawn at once, to the bit.
        func strokes(_ n: Int) -> [BrushStroke] {
            (0..<n).map { i in
                let y = 0.1 + 0.8 * Double(i) / Double(n)
                return BrushStroke(radius: 0.02 + 0.01 * Double(i % 3), hardness: 0.5, flow: 0.4, erase: i % 7 == 6,
                                   points: [MaskPoint(0.1, y), MaskPoint(0.5, y + 0.05), MaskPoint(0.9, y)])
            }
        }
        let fresh = try MaskBaker(device: device)
        _ = try await fresh.bake(layer([.brush(BrushStrokes(strokes: strokes(71).prefix(70).map { $0 }))]), source: source, maxLongEdge: limit)
        let onto = try await fresh.bake(layer([.brush(BrushStrokes(strokes: strokes(71)))]), source: source, maxLongEdge: limit)
        let scratch = try await MaskBaker(device: device).bake(layer([.brush(BrushStrokes(strokes: strokes(71)))]), source: source, maxLongEdge: limit)
        expect(onto.values == scratch.values, "a stroke drawn onto the plane already made is the whole list drawn again, to the bit")
        // Undo from a checkpoint: 65 strokes after 70 were drawn redraws from stroke 64's checkpoint.
        let undone = try await fresh.bake(layer([.brush(BrushStrokes(strokes: Array(strokes(71).prefix(65))))]), source: source, maxLongEdge: limit)
        let undoneScratch = try await MaskBaker(device: device).bake(layer([.brush(BrushStrokes(strokes: Array(strokes(71).prefix(65))))]), source: source, maxLongEdge: limit)
        expect(undone.values == undoneScratch.values, "Undo to 65 strokes, from the checkpoint at 64, is the 65 drawn from nothing, to the bit")
        // The cache: the same layer is the same plane, not baked again; another feather is another key.
        let l = cases[0].1
        let a = try await baker.bake(l, source: source, maxLongEdge: limit), b = try await baker.bake(l, source: source, maxLongEdge: limit)
        var l2 = l; l2.feather = 0.001
        expect(a.buffer === b.buffer && MaskBaker.planeKey(l, source: source) != MaskBaker.planeKey(l2, source: source),
               "a plane is cached under what it was made of")
        var l3 = l; l3.scene = SceneDeltas(exposure: -2); l3.opacity = 0.3; l3.name = "other"
        expect(MaskBaker.planeKey(l, source: source) == MaskBaker.planeKey(l3, source: source), "the deltas, opacity and name do not change the plane's key")
        print("mask bake: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
