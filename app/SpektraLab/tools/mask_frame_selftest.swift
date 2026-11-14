//  mask_frame_selftest.swift — `MaskFrame` (RFC-052 §3) against the pictures and drawings it must agree with, each
//  term broken on purpose and expected red.
//
//      tools/selftest.sh       # with the other checks
//
//  1. **The engine's node** (`engineNode`): a decode whose every pixel says where it is in S (R = s, G = t) is cut by
//     the app's own `HostCut.image` — a film edge's framing, a straighten, turns and flips, a perspective — and at
//     every handed pixel's centre the matrix's S is held to the S the pixel carries. In source pixels.
//  2. **The finished canvas** with a film edge (`finished` with a `FilmBox`): held to the guide's own drawing of the
//     picture in its box (`FilmCanvasView`: translate to the centre, rotate by the tilt, back, into the box), and
//     without one to the cut's map (`Geometry.originalPoint(forOutput:)`).
//  3. **A view** through Edit's crop: `view` against the crop's own map then `finished`.
//  4. **Each term broken** — the crop's x, y, width and height, the straighten, a turn, each flip, the perspective, the
//     tilt's sign, the box — and the matrix's own nine entries + 0.01: red, by how much.
//
//  The engine's half of the geometry (its own cut composed on top, on a render) is `tools/scene_layers_drive.swift`
//  gate 4.

import CoreGraphics
import CoreImage
import Foundation

@main struct MaskFrameSelftest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("ok    \(what)") } else { failed += 1; print("FAIL  \(what)") }
    }

    static let D = CGSize(width: 900, height: 600)

    /// The decode: R = s, G = t at each pixel's centre, float, no colour management.
    static func encoded() -> CIImage {
        let w = Int(D.width), h = Int(D.height)
        var px = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = 4 * (y * w + x)
            px[i] = Float((Double(x) + 0.5) / Double(w)); px[i + 1] = Float((Double(y) + 0.5) / Double(h)); px[i + 3] = 1
        } }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        // Core Image's y runs upward: row 0 of the bitmap is its top.
        return CIImage(bitmapData: data, bytesPerRow: w * 16, size: D, format: .RGBAf, colorSpace: nil)
    }

    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// The handed frame as HostCut makes it, read back: (s, t) a pixel, top row first.
    static func handed(_ g: Geometry) -> (w: Int, h: Int, st: [SIMD2<Double>]) {
        let cut = HostCut.image(encoded(), by: g)
        let box = cut.extent.integral
        let w = Int(box.width), h = Int(box.height)
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { p in
            context.render(cut, toBitmap: p.baseAddress!, rowBytes: w * 16, bounds: box, format: .RGBAf, colorSpace: nil)
        }
        let st = (0..<(w * h)).map { SIMD2(Double(out[4 * $0]), Double(out[4 * $0 + 1])) }
        return (w, h, st)
    }

    /// The largest distance, in source pixels, between the matrix's S and the pixel's own, over the handed frame's
    /// pixels away from its edge (a resample's edge repeats the picture) and inside S.
    static func nodeError(_ g: Geometry, _ m: MaskMatrix, _ h: (w: Int, h: Int, st: [SIMD2<Double>])) -> (max: Double, mean: Double) {
        var worst = 0.0, sum = 0.0, n = 0
        for y in stride(from: 2, to: h.h - 2, by: 3) { for x in stride(from: 2, to: h.w - 2, by: 3) {
            let truth = h.st[y * h.w + x]
            // Where the decode's own edge was repeated, the pixel carries the edge's S, not its own.
            guard truth.x > 2 / D.width, truth.x < 1 - 2 / D.width, truth.y > 2 / D.height, truth.y < 1 - 2 / D.height else { continue }
            let p = m.apply(CGPoint(x: (Double(x) + 0.5) / Double(h.w), y: (Double(y) + 0.5) / Double(h.h)))
            let e = (((Double(p.x) - truth.x) * D.width) * ((Double(p.x) - truth.x) * D.width)
                     + ((Double(p.y) - truth.y) * D.height) * ((Double(p.y) - truth.y) * D.height)).squareRoot()
            worst = max(worst, e); sum += e; n += 1
        } }
        return (worst, n > 0 ? sum / Double(n) : .infinity)
    }

    static func geometry(crop: CropRect = .full, angle: Double = 0, turns: Int = 0, flipH: Bool = false, flipV: Bool = false,
                         vertical: Double = 0, horizontal: Double = 0) -> Geometry {
        var g = Geometry()
        g.crop = crop; g.angle = angle; g.quarterTurns = turns; g.flipH = flipH; g.flipV = flipV
        g.vertical = vertical; g.horizontal = horizontal
        return g
    }

    static func main() {
        let crop = CropRect(x: 0.12, y: 0.08, width: 0.7, height: 0.75)
        let cases: [(String, Geometry, Double)] = [
            ("a film edge's crop", geometry(crop: crop), 0.01),
            ("crop + straighten 6 deg", geometry(crop: CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.55), angle: 6), 0.05),
            ("crop + turn 1 + flip h (a film's half turn carried back)", geometry(crop: crop, turns: 1, flipH: true), 0.01),
            ("crop + turns 2 + flip v", geometry(crop: crop, turns: 2, flipV: true), 0.01),
            ("mirrored crop (flip h)", geometry(crop: crop, flipH: true), 0.01),
            ("Vertical 8 deg alone (the host's perspective, no film edge)", geometry(vertical: 8), 0.05),
            ("Horizontal -6, crop, straighten -4, turns 3", geometry(crop: CropRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6), angle: -4, turns: 3, horizontal: -6), 0.05),
        ]
        print("== the engine's node: handed frame -> S, against HostCut's own pixels (source px) ==")
        for (name, g, bar) in cases {
            let h = handed(g)
            let m = MaskFrame.engineNode(hostCut: g, decode: D)
            let e = nodeError(g, m, h)
            expect(e.max <= bar, String(format: "%@ (%dx%d): max %.4f px, mean %.4f px (bar %.2f)", name, h.w, h.h, e.max, e.mean, bar))
        }
        expect(MaskFrame.engineNode(hostCut: nil, decode: D).isIdentity && MaskFrame.engineNode(hostCut: .default, decode: D).isIdentity,
               "no host cut is the identity")

        print("== each term broken: red ==")
        let full = cases[6].1, turned = cases[2].1, straight = cases[1].1
        let breaks: [(String, Geometry, Geometry)] = [
            ("crop x + 0.01", turned, { var g = turned; g.crop.x += 0.01; return g }()),
            ("crop y + 0.01", turned, { var g = turned; g.crop.y += 0.01; return g }()),
            ("crop width x 1.01", turned, { var g = turned; g.crop.width *= 1.01; return g }()),
            ("crop height x 1.01", turned, { var g = turned; g.crop.height *= 1.01; return g }()),
            ("straighten + 0.5 deg", straight, { var g = straight; g.angle += 0.5; return g }()),
            ("a turn more", turned, { var g = turned; g.quarterTurns += 1; return g }()),
            ("flip h", turned, { var g = turned; g.flipH.toggle(); return g }()),
            ("flip v", turned, { var g = turned; g.flipV.toggle(); return g }()),
            ("perspective + 1 deg", full, { var g = full; g.horizontal += 1; return g }()),
            ("the perspective left out", full, { var g = full; g.horizontal = 0; return g }()),
        ]
        for (name, truth, broken) in breaks {
            let e = nodeError(truth, MaskFrame.engineNode(hostCut: broken, decode: D), handed(truth))
            expect(e.max > 1, String(format: "%@: red (max %.1f px)", name, e.max))
        }
        let truthM = MaskFrame.engineNode(hostCut: turned, decode: D)
        let h = handed(turned)
        for k in 0..<9 {
            var m = truthM
            m.m[k] += 0.01
            let e = nodeError(turned, m, h)
            expect(e.max > 1, String(format: "frame_to_source[%d] + 0.01: red (max %.1f px)", k, e.max))
        }
        // A decode size other than the decode: the whole-pixel holding of a cut is the decode's.
        let other = MaskFrame.engineNode(hostCut: turned, decode: CGSize(width: 1800, height: 1200))
        let eo = nodeError(turned, other, h)
        print(String(format: "      (the same cut matrixed at twice the decode's size: max %.3f px of the decode — what a decode-size guess costs)", eo.max))

        print("== the finished canvas ==")
        // Without a film edge: the cut's own map, then the perspective.
        for (name, g, _) in cases {
            let m = MaskFrame.finished(picture: g, source: D)
            var worst = 0.0
            for i in 0..<50 {
                let p = CGPoint(x: Double(i % 7) / 6, y: Double(i / 7) / 7)
                let q = m.apply(p), r = g.originalPoint(forOutput: p, imageSize: D)
                worst = max(worst, hypot(Double(q.x - r.x) * D.width, Double(q.y - r.y) * D.height))
            }
            expect(worst < 1e-6, String(format: "%@: finished -> S is the cut's own map (max %.1e px)", name, worst))
        }
        // With a film edge: the guide draws the picture's cut into `box`, rotated by `tilt` about `centre`.
        let box = MaskFrame.FilmBox(canvasMM: CGSize(width: 44, height: 30), box: CGRect(x: 4, y: 3.2, width: 36, height: 24),
                                    tilt: 0.8, centre: CGPoint(x: 22, y: 15.2))
        let g = cases[2].1
        let m = MaskFrame.finished(picture: g, source: D, film: box)
        func drawn(_ q: CGPoint, _ b: MaskFrame.FilmBox) -> CGPoint {
            // The picture's point q (normalised) on the canvas (normalised), as FilmCanvasView draws it.
            let p = CGPoint(x: b.box.minX + q.x * b.box.width, y: b.box.minY + q.y * b.box.height)
            let a = b.tilt * .pi / 180
            let dx = p.x - b.centre.x, dy = p.y - b.centre.y
            let r = CGPoint(x: b.centre.x + dx * cos(a) - dy * sin(a), y: b.centre.y + dx * sin(a) + dy * cos(a))
            return CGPoint(x: r.x / b.canvasMM.width, y: r.y / b.canvasMM.height)
        }
        func filmError(_ m: MaskMatrix, _ b: MaskFrame.FilmBox) -> Double {
            var worst = 0.0
            for i in 0..<49 {
                let q = CGPoint(x: 0.05 + 0.9 * Double(i % 7) / 6, y: 0.05 + 0.9 * Double(i / 7) / 6)
                let s = m.apply(drawn(q, b)), truth = g.originalPoint(forOutput: q, imageSize: D)
                worst = max(worst, hypot(Double(s.x - truth.x) * D.width, Double(s.y - truth.y) * D.height))
            }
            return worst
        }
        let ef = filmError(m, box)
        expect(ef < 1e-6, String(format: "a film edge: the guide's picture point -> S (max %.1e px)", ef))
        var flipped = box; flipped.tilt = -box.tilt
        expect(filmError(MaskFrame.finished(picture: g, source: D, film: flipped), box) > 1, "the tilt's sign broken: red")
        var moved = box; moved.box.origin.x += 0.2
        expect(filmError(MaskFrame.finished(picture: g, source: D, film: moved), box) > 1, "the box 0.2 mm off: red")

        print("== a view through Edit's crop ==")
        var printCrop = Geometry()
        printCrop.crop = CropRect(x: 0.1, y: 0.15, width: 0.6, height: 0.7)
        printCrop.quarterTurns = 1
        let size = CGSize(width: 1200, height: 800)
        let v = MaskFrame.view(finished: m, printCrop: printCrop, finishedSize: size)
        var worst = 0.0
        for i in 0..<25 {
            let p = CGPoint(x: Double(i % 5) / 4, y: Double(i / 5) / 4)
            let truth = m.apply(printCrop.onFinished(size).sourcePoint(forOutput: p, imageSize: size))
            let got = v.apply(p)
            worst = max(worst, hypot(Double(got.x - truth.x) * D.width, Double(got.y - truth.y) * D.height))
        }
        expect(worst < 1e-6, String(format: "view -> Edit's crop -> finished -> S (max %.1e px)", worst))
        expect(MaskFrame.view(finished: m, printCrop: .default, finishedSize: size) == m, "no Edit crop: the view is the finished canvas")
        print("mask frame: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
