//  HDRGrainGain.swift — the gain of a grained picture: the local tone's, and the grain carried at the paper's slope
//  (2026-11-03, `rfc/audits/hdr-grain-2026-11-03`, the method the research calls R; the owner chose it on an HDR
//  screen over 1:1 and ¼).
//
//  Why: a gain read from each pixel's own luminance (1:1) puts the curve's fine shape — the knee's floor, the
//  table's slope wobble, the crease at the paper's white — inside one grain speck's amplitude, so bright specks
//  are lifted and dark ones not ("very unnatural cutoffs"); a ¼ map carries only the tone's gain, so the grain
//  keeps the shoulder's compressed contrast on a surface twice as bright ("added back afterwards"). The physics
//  in between (REPORT §2): the tone's gain from the **local tone** L (log2 Y under a Gaussian a few grain widths
//  wide), and each pixel's deviation from it carried at the restored paper's slope:
//
//      log2 gain = Ks(L) + κ · clamp(ρ(L), 0, ρmax) · (log2 Y − L),   clamped to [0, log2 H]
//
//  - **Ks**: the shipped curve smoothed by `sigmaStops` in log2 Y (ends held), ρ its slope. It rounds the crease
//    and the wobble; it moves the tone under 0.03 stop below Y 0.65.
//  - **ρmax 2**: the restored highlight grain never exceeds the mid-tones'. **κ 1**: the physics (the owner's R).
//  - **σ, the local tone's width, is the grain's, measured in the raster it runs on** (`grainWidth`): the engine
//    draws grain a pixel wide at most sizes, wider on small formats and at 48 MP (its dye clouds and
//    micro-structure are in µm on the film), and a page draws a resized copy. So each picture's own grain is
//    measured — the format, the pixel count and the resize at once — and σ = 2 × its width, 2 … 8 px.
//
//  The GPU producer is `HDRRendition`'s (one kernel set for the export's map and the pages' picture); this file
//  holds the rules and the Swift reference the checks hold it to. No UIKit: the macOS checks compile it.
//
//  For the Mac's Enable HDR (2026-11-06, D1). **The tables are the engine's, of the session**
//  (`spk_session_hdr_curve`'s `ks` and `rho`, `HDRSessionCurve`), not a bundled store's: no store is looked up,
//  and a curve made here with no tables draws with none (`Tables.none`, no gain).

import CoreGraphics
import Foundation

enum HDRGrainGain {
    /// The local tone's Gaussian, px, as the grain's width asks: 2 × the width, within these.
    static let sigmaRange: ClosedRange<Double> = 2...8

    /// The two tables a curve gives the kernels: Ks (log2 gain, smoothed) and ρ (its slope, log2 gain a stop),
    /// 256 each over the curve's own domain, with the two constants the kernels take beside them. Made by the
    /// engine for the session (`spk_session_hdr_curve`, `HDRSessionCurve`); the app holds no copy of how.
    struct Tables: Sendable, Equatable {
        var ks: [Float]
        var slope: [Float]
        var lo: Double
        var hi: Double
        var top: Double
        var kappa: Double
        var rhoMax: Double
        /// τ, stops: how far from the pixel's own tone its local tone is read (the clamped base;
        /// the engine's `detail_clamp`, API-SPEC §19.2). 0 reads the pixel's own tone alone.
        var tau: Double

        /// No gain anywhere: what a curve the store does not know is drawn with (SDR, never a guess).
        static func none(_ curve: HDRGainCurve) -> Tables {
            let n = HDRGainCurve.count
            return Tables(ks: Array(repeating: 0, count: n), slope: Array(repeating: 0, count: n),
                          lo: curve.domainLog2Y.first ?? -12, hi: curve.domainLog2Y.last ?? 0,
                          top: log2(max(curve.headroom, 1.0001)), kappa: 0, rhoMax: 0, tau: 0)
        }
    }

    /// One pixel's log2 gain from its own log2 Y and its local tone L (the kernels' arithmetic, in Double).
    static func log2Gain(l2y: Double, local gaussianL: Double, tables t: Tables) -> Double {
        let kappa = t.kappa, rhoMax = t.rhoMax
        // The clamped base (the owner's "C looks right", 2026-11-08): the local tone no further
        // than τ from the pixel's own, so a dark branch beside a sky no longer pulls the sky's gain down (the ring).
        let L = l2y - min(max(l2y - gaussianL, -t.tau), t.tau)
        let n = t.ks.count
        let u = min(max((L - t.lo) / (t.hi - t.lo), 0), 1) * Double(n - 1)
        let i0 = min(Int(u.rounded(.down)), n - 2), f = u - Double(i0)
        let g = Double(t.ks[i0]) + (Double(t.ks[i0 + 1]) - Double(t.ks[i0])) * f
        let rho = min(max(Double(t.slope[i0]) + (Double(t.slope[i0 + 1]) - Double(t.slope[i0])) * f, 0), rhoMax)
        return min(max(g + kappa * rho * (l2y - L), 0), t.top)
    }

    /// A linear-light P3 luminance's log2, as the kernels take it.
    static func l2y(_ y: Double) -> Double { log2(max(y, 1e-30)) }

    /// The Gaussian of a plane, separable, edges held (the kernels' own; the checks' and the histogram's).
    @_optimize(speed)
    static func blurred(_ p: [Float], width w: Int, height h: Int, sigma: Double) -> [Float] {
        let r = radius(sigma)
        let n = w * h
        // Raw pointers, no closures: a debug build's checked indexing (and closures `@_optimize` does not reach)
        // made a 320² measure take a second.
        let k = UnsafeMutablePointer<Float>.allocate(capacity: 2 * r + 1)
        let src = UnsafeMutablePointer<Float>.allocate(capacity: n), t = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let o = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { k.deallocate(); src.deallocate(); t.deallocate(); o.deallocate() }
        var ks: Float = 0
        var j = -r
        while j <= r { let v = Float(exp(-Double(j * j) / (2 * sigma * sigma))); k[j + r] = v; ks += v; j += 1 }
        var i = 0
        while i < n { src[i] = p[i]; i += 1 }
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                var a: Float = 0
                j = -r
                while j <= r { let xx = min(max(x + j, 0), w - 1); a += k[j + r] * src[y * w + xx]; j += 1 }
                t[y * w + x] = a / ks
                x += 1
            }
            y += 1
        }
        y = 0
        while y < h {
            var x = 0
            while x < w {
                var a: Float = 0
                j = -r
                while j <= r { let yy = min(max(y + j, 0), h - 1); a += k[j + r] * t[yy * w + x]; j += 1 }
                o[y * w + x] = a / ks
                x += 1
            }
            y += 1
        }
        return Array(UnsafeBufferPointer(start: o, count: n))
    }

    /// The Gaussian's reach, px: 3σ.
    static func radius(_ sigma: Double) -> Int { max(1, Int((3 * sigma).rounded(.up))) }

    /// A whole picture's log2 gains from its log2 Y plane: the Swift reference of the GPU's.
    @_optimize(speed)
    static func log2Gains(l2y: [Float], width w: Int, height h: Int, tables: Tables, sigma: Double) -> [Float] {
        let L = blurred(l2y, width: w, height: h, sigma: sigma)
        return (0..<(w * h)).map { Float(log2Gain(l2y: Double(l2y[$0]), local: Double(L[$0]), tables: tables)) }
    }

    // MARK: the grain's width, measured

    /// How many pixels wide the picture's grain is: in a centre crop (at most 256 × 256, `sigma(for:)`) the residual of log2 Y
    /// against a 2 px Gaussian (the research's grain band), its autocorrelation at lags 1 … 4 (rows and columns)
    /// in each 16 × 16 block whose tone is flat (its 2 px blur varies less than the residual: no edge), the
    /// median over those blocks; the width is the lags it keeps ≥ 0.2, at least 1. A pixel-wide grain (the
    /// engine's draw, blurred 0.65 px) reads 1 (the 777: 0.41 at 1 px, ≈ 0 at 2); a wider one, its width.
    @_optimize(speed)
    static func grainWidth(l2y p: [Float], width w: Int, height h: Int) -> Int {
        guard w >= 32, h >= 32 else { return 1 }
        let baseArray = blurred(p, width: w, height: h, sigma: 2)
        let n = w * h
        let r = UnsafeMutablePointer<Float>.allocate(capacity: n), base = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { r.deallocate(); base.deallocate() }
        var i = 0
        while i < n { base[i] = baseArray[i]; r[i] = p[i] - baseArray[i]; i += 1 }
        var perLag = [[Float]](repeating: [], count: 5)
        var by = 0
        while by + 16 <= h {
            var bx = 0
            while bx + 16 <= w {
                var m: Float = 0, bm: Float = 0
                for y in by..<by + 16 { for x in bx..<bx + 16 { m += r[y * w + x]; bm += base[y * w + x] } }
                m /= 256; bm /= 256
                var v: Float = 0, bv: Float = 0
                for y in by..<by + 16 { for x in bx..<bx + 16 {
                    let d = r[y * w + x] - m; v += d * d
                    let e = base[y * w + x] - bm; bv += e * e } }
                if v > 1e-9, bv < v {                     // an edge or a gradient in the block: not grain alone
                    for lag in 1...4 {
                        var c: Float = 0, cnt = 0
                        for y in by..<by + 16 { for x in bx..<bx + 16 - lag {
                            c += (r[y * w + x] - m) * (r[y * w + x + lag] - m); cnt += 1 } }
                        for y in by..<by + 16 - lag { for x in bx..<bx + 16 {
                            c += (r[y * w + x] - m) * (r[(y + lag) * w + x] - m); cnt += 1 } }
                        perLag[lag].append((c / Float(cnt)) / (v / 256))
                    }
                }
                bx += 16
            }
            by += 16
        }
        guard perLag[1].count >= 8 else { return 1 }          // too few flat blocks to say: the engine's usual
        var width = 0
        for lag in 1...4 {
            let s = perLag[lag].sorted()
            guard s[s.count / 2] >= 0.2 else { break }
            width = lag
        }
        return max(1, width)
    }

    /// The local tone's σ for a grain `width` px wide.
    static func sigma(forWidth width: Int) -> Double {
        min(max(2 * Double(width), sigmaRange.lowerBound), sigmaRange.upperBound)
    }

    /// The σ for a picture: its centre crop drawn at its own pixels, 16 bits, its grain measured.
    @_optimize(speed)
    static func sigma(for image: CGImage) -> Double {
        let cw = min(image.width, 256), ch = min(image.height, 256)
        guard cw >= 32, ch >= 32, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return sigmaRange.lowerBound }
        var px = [UInt16](repeating: 0, count: cw * ch * 4)
        let ok: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cw, height: ch, bitsPerComponent: 16, bytesPerRow: cw * 8, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            // The picture placed so its centre crop lands in the context, at its own pixels.
            let ox = (image.width - cw) / 2, oy = (image.height - ch) / 2
            ctx.draw(image, in: CGRect(x: -CGFloat(ox), y: -CGFloat(image.height - ch - oy), width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard ok else { return sigmaRange.lowerBound }
        var l = [Float](repeating: 0, count: cw * ch)
        for i in 0..<(cw * ch) {
            let r = HDRMath.decode(Double(px[4 * i]) / 65535), g = HDRMath.decode(Double(px[4 * i + 1]) / 65535)
            let b = HDRMath.decode(Double(px[4 * i + 2]) / 65535)
            l[i] = Float(l2y(HDRMath.luminance(r, g, b)))
        }
        return sigma(forWidth: grainWidth(l2y: l, width: cw, height: ch))
    }

    /// A picture drawn as linear extended Display P3 Float RGBA (the checks' reading of any form).
    static func floatsLinearP3(_ image: CGImage) -> [Float] {
        let w = image.width, h = image.height
        var d = [Float](repeating: 0, count: w * h * 4)
        d.withUnsafeMutableBytes { b in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                                      space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return d
    }
}

