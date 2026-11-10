//  hdr_histogram_selftest.swift — the HDR histogram (`HDRHistogram`) on a synthetic picture.
//
//  Patches of grey of known codes, each 1000 pixels, through a synthetic curve (no gain below Y 0.25,
//  rising to two stops at Y 1): the histogram is of the HDR rendition, one plot. Pixels the gain lifts past
//  1.0 are counted in the HDR span, per channel, and no others; pixels it lifts but that stay under white are
//  counted in the SDR span at their new place; total counts are conserved (every pixel in every channel, once);
//  white lands in the top HDR bin; weight 0 is the picture as it is, bin for bin; the display row the plot
//  draws keeps every count. With no look there is no HDR histogram to ask for (HDRLook.of is nil -- the
//  panel's guard): the plot is the SDR histogram, `Layer2Histogram`, as before.
//
//  HDR port, 2026-11-06, D7. On the Mac:
//  - **The look's tables are made here** from the synthetic curve (Ks the curve, ρ its slope, κ 1, ρmax 2, the
//    reference constants): the Mac's app never makes them (the engine does, `HDRSessionCurve`). The GPU check runs a second time on the curve this Mac's engine gave for Portra 400
//    on Portra Endura (tools/engine_replies/hdr_curve_reply.json), whose tables are the engine's own.
//  - **The GPU's half floats are read without `Float16`** (`HDRMath.half`, through `HDRHistogram`'s table): on
//    this arm64 Mac every one of the 65,536 bit patterns is held to `Float16`'s own value (x86_64 has no
//    `Float16`, which is why the app does not use it).
//  - **A non-finite value is no index**: an infinite or NaN half binned does not trap.
//
//      tools/hdr_histogram_selftest.sh     (also run by tools/selftest.sh)

import CoreGraphics
import Foundation
import SwiftUI

// The catalogue's swatches are the app's colours; none is drawn here.
extension Color { init(hexString: String) { self = .gray } }

@main
struct HDRHistogramSelftest {
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var passed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1; print("  FAILED: \(what)") }
    }

    /// The SDR bin a linear value up to 1 belongs in: the encoded value, as Layer2Histogram bins it.
    static func sdrBin(_ v: Double) -> Int { min(255, Int(HDRMath.encode(min(1, max(0, v))) * 255 + 0.5)) }

    /// A look of a synthetic curve, with the tables the engine would give it on flat fields: Ks the curve itself
    /// (no smoothing), ρ its slope in log2 gain a stop (≥ 0), the reference κ 1 and ρmax 2.
    static func look(_ name: String, _ ramp: [Double]) -> HDRLook {
        let curve = HDRGainCurve(name: name, headroom: 4, log2Gain: ramp)
        let step = 12.0 / Double(HDRGainCurve.count - 1)
        let slope = ramp.indices.map { i -> Float in
            let a = ramp[max(0, i - 1)], b = ramp[min(ramp.count - 1, i + 1)]
            return Float(max(0, (b - a) / (Double(min(ramp.count - 1, i + 1) - max(0, i - 1)) * step)))
        }
        let tables = HDRGrainGain.Tables(ks: ramp.map { Float($0) }, slope: slope, lo: -12, hi: 0, top: 2, kappa: 1, rhoMax: 2, tau: 0.1)
        return HDRLook(curve: curve, tables: tables)
    }

    /// A CGImage of 8-bit RGBA Display P3 pixels.
    static func image(_ px: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// A grained ramp, 320 × 240: what the GPU's picture is held to the Swift pass on.
    static func grainedRamp() -> CGImage {
        let gw = 320, gh = 240
        var g = [UInt8](repeating: 255, count: gw * gh * 4)
        for y in 0..<gh { for x in 0..<gw {
            var hash = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663); hash = (hash ^ (hash >> 13)) &* 0x5bd1e995
            let v = max(0, min(255, x * 255 / (gw - 1) + Int(hash % 9) - 4))
            for c in 0..<3 { g[4 * (y * gw + x) + c] = UInt8(v) }
        } }
        return image(g, width: gw, height: gh)
    }

    /// The page's own HDR picture (the GPU's) binned as it is agrees with the Swift pass — the same pixels past
    /// white, channel by channel, within half-float rounding (1 %).
    static func gpuAgrees(_ look: HDRLook, _ what: String) {
        let ramp = grainedRamp()
        let cpu = HDRHistogram.zone(of: ramp, look: look, weight: 1)
        let gpu = (try? HDRRendition.make(ramp, look: look, weight: 1)).flatMap { HDRHistogram.zone(edr: $0, headroom: look.curve.headroom, weight: 1) }
        guard let cpu, let gpu else { expect(false, "\(what): the GPU picture's histogram"); return }
        let a = (0..<HDRZone.channels).map { cpu.inHDR($0) }, b = (0..<HDRZone.channels).map { gpu.inHDR($0) }
        let worst = zip(a, b).map { abs(Double($0) - Double($1)) / Double(max($0, 1)) }.max() ?? 1
        expect(a[3] > 1000 && worst < 0.01 && gpu.samples == ramp.width * ramp.height,
               "\(what): the GPU picture's histogram is the Swift pass's: past white \(b) against \(a)")
        for c in 0..<HDRZone.channels {
            let sdr = gpu.sdr[(c * 256)..<(c * 256 + 256)].reduce(0) { $0 + Int($1) }
            expect(sdr + gpu.inHDR(c) == gpu.samples, "\(what): the GPU picture's channel \(c) counts are conserved")
        }
    }

    static func main() {
        let ramp = (0..<256).map { i -> Double in
            let l2y = -12 + 12 * Double(i) / 255
            return min(2, max(0, (l2y + 2) / 2 * 2))
        }
        let look = look("synthetic", ramp)
        let codes: [UInt8] = [0, 40, 128, 200, 230, 255]
        let per = 1000
        var px = [UInt8]()
        for c in codes { for _ in 0..<per { px += [c, c, c, 255] } }
        let total = codes.count * per

        for w in [1.0, 0.5, 0.0] {
            let zone = px.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, pixels: total, look: look, weight: w) }
            // Every pixel, once, in each of the four channels.
            for c in 0..<4 {
                let sdr = zone.sdr[(c * 256)..<(c * 256 + 256)].reduce(0) { $0 + Int($1) }
                expect(sdr + zone.inHDR(c) == total, "weight \(w), channel \(c): \(sdr) + \(zone.inHDR(c)) pixels, \(total) read")
            }
            expect(zone.samples == total, "samples \(zone.samples)")
            expect(zone.hdrBins == 64, "two stops are 64 bins, not \(zone.hdrBins)")

            // The reference rendition says which pixels are past white and where the others are.
            var past = 0
            var wantSDR = [Int](repeating: 0, count: 256)
            for c in codes {
                let out = HDRRendition.reference(SIMD3(c, c, c), look: look, weight: w)
                if HDRMath.luminance(out.x, out.y, out.z) > 1 + 1e-3 { past += per }
                else if HDRMath.luminance(out.x, out.y, out.z) < 1 - 1e-3 { wantSDR[sdrBin(HDRMath.luminance(out.x, out.y, out.z))] += per }
            }
            expect(zone.inZone == past, "weight \(w): \(zone.inZone) past SDR white, the rendition puts \(past)")
            for c in 0..<3 { expect(zone.inHDR(c) == past, "weight \(w): grey patches are past white in every channel (\(c): \(zone.inHDR(c)))") }
            // Lifted but under white: moved within the SDR span. The patches under white, by luminance bin.
            var gotSDR = [Int](repeating: 0, count: 256)
            for i in 0..<256 { gotSDR[i] = Int(zone.sdr[3 * 256 + i]) }
            for i in 0..<256 where wantSDR[i] > 0 {
                let near = (max(0, i - 1)...min(255, i + 1)).reduce(0) { $0 + gotSDR[$1] }
                expect(near >= wantSDR[i], "weight \(w): \(wantSDR[i]) pixels belong at bin \(i), \(near) near it")
            }

            // The display rows: every count kept, the HDR span after the SDR's 256.
            let rows = zone.combined()
            expect(rows.count == 4 && rows.allSatisfy { $0.count == 256 + HDRZone.displayBins(stops: zone.stops) }, "four rows of 256 + the HDR span")
            for c in 0..<4 { expect(abs(rows[c].reduce(0, +) - Float(total)) < 1, "weight \(w): row \(c) keeps its \(total) counts (\(rows[c].reduce(0, +)))") }

            if w == 1 {
                expect(past >= 3 * per, "the test picture has highlights to find (\(past))")
                // A patch of code 128 has Y 0.22: no gain under 0.25, so it stays where it is.
                let mid = Int(zone.sdr[3 * 256 + sdrBin(HDRMath.luminance(HDRMath.decode(128 / 255.0), HDRMath.decode(128 / 255.0), HDRMath.decode(128 / 255.0)))])
                expect(mid >= per, "a patch under the curve's knee does not move (\(mid))")
                let white = HDRRendition.reference(SIMD3(255, 255, 255), look: look, weight: 1)
                let bin = min(63, Int(log2(HDRMath.luminance(white.x, white.y, white.z)) / 2 * 64))
                expect(bin >= 60 && zone.hdr[3 * 64 + bin] == UInt32(per), "white lands in its bin near two stops (bin \(bin): \(zone.hdr[3 * 64 + bin]))")
                expect(zone.hdr[3 * 64..<(3 * 64 + 8)].allSatisfy { $0 == 0 }, "nothing within a quarter stop of white")
            }
            if w == 0 {
                expect(zone.inZone == 0, "weight 0 lifts nothing")
                // The picture as it is, bin for bin: a grey patch of code c is in bin c of each channel.
                for c in codes {
                    for ch in 0..<4 { expect(zone.sdr[ch * 256 + Int(c)] >= UInt32(per), "weight 0: code \(c) in channel \(ch)'s bin \(c) (\(zone.sdr[ch * 256 + Int(c)]))") }
                }
            }
        }

        // Lifted but under white: a dark-mid patch under a curve that lifts from Y 0.1 by up to a stop, so
        // that Y 0.1 -> 0.2 stays under white and moves up its SDR span.
        do {
            let gentle = (0..<256).map { i -> Double in
                let l2y = -12 + 12 * Double(i) / 255
                return min(1, max(0, (l2y + 4) / 4))
            }
            let soft = Self.look("gentle", gentle)
            let c: UInt8 = 100
            var flat = [UInt8]()
            for _ in 0..<per { flat += [c, c, c, 255] }
            let was = flat.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, pixels: per, look: soft, weight: 0) }
            let now = flat.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, pixels: per, look: soft, weight: 1) }
            func mean(_ z: HDRZone, _ ch: Int) -> Double {
                var s = 0.0, n = 0.0
                for i in 0..<256 { s += Double(i) * Double(z.sdr[ch * 256 + i]); n += Double(z.sdr[ch * 256 + i]) }
                return n > 0 ? s / n : 0
            }
            expect(was.inZone == 0 && now.inZone == 0, "the lifted patch stays under white")
            for ch in 0..<4 { expect(mean(now, ch) > mean(was, ch) + 5, "channel \(ch): lifted but under white moves up the SDR span (\(mean(was, ch)) -> \(mean(now, ch)))") }
            for ch in 0..<4 { expect(now.sdr[ch * 256..<(ch * 256 + 256)].reduce(0, +) == UInt32(per), "channel \(ch): its \(per) pixels kept in the SDR span") }
        }

        // The CGImage way in reads the same pixels.
        do {
            let picture = image(px, width: per, height: codes.count)
            let a = HDRHistogram.zone(of: picture, look: look, weight: 1)
            let b = px.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, width: per, height: codes.count, look: look, weight: 1) }
            expect(a == b, "a CGImage's histogram is its pixels'")
            for c in 0..<4 { expect(b.sdr[(c * 256)..<(c * 256 + 256)].reduce(0) { $0 + Int($1) } + b.inHDR(c) == per * codes.count, "a picture's channel \(c) counts are conserved") }
            // Bands one code each, 40 rows tall: away from their edges the local tone is the band's own.
            var tall = [UInt8]()
            for c in codes { for _ in 0..<(40 * 64) { tall += [c, c, c, 255] } }
            let t = tall.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, width: 64, height: 40 * codes.count, look: look, weight: 1) }
            let flat = tall.withUnsafeBufferPointer { HDRHistogram.zone(rgba: $0.baseAddress!, pixels: tall.count / 4, look: look, weight: 1) }
            expect(abs(t.inZone - flat.inZone) <= 64 * 12 * codes.count,
                   "a picture's HDR span is its flat fields' within the bands' edges (\(t.inZone) against \(flat.inZone))")
        }

        // The app's way: the page's own HDR picture (the GPU's) binned as it is, on the synthetic curve and on the
        // curve this Mac's engine gave a session (its own tables, ρ and all).
        gpuAgrees(look, "the synthetic curve")
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let reply = (try? String(contentsOf: here.appendingPathComponent("tools/engine_replies/hdr_curve_reply.json"), encoding: .utf8)) ?? ""
        let session = try? HDRSessionCurve.parse(reply)
        expect(session != nil, "the engine's reply is kept and parses (run from the app's folder)")
        if let session { gpuAgrees(HDRLook(session), "the engine's Portra 400 → Portra Endura curve") }

        // Half floats without `Float16`: the table the GPU's picture is read through is `Float16`'s own value for
        // every bit pattern (on this arm64 Mac; the x86_64 slice has no `Float16` to compare with).
        #if arch(arm64)
        var halfWrong = 0
        for bits in 0..<65536 {
            let want = Float(Float16(bitPattern: UInt16(bits))), got = HDRMath.half(UInt16(bits))
            if !(want == got || (want.isNaN && got.isNaN)) { halfWrong += 1 }
        }
        expect(halfWrong == 0, "every half float read as Float16 reads it (\(halfWrong) of 65,536 differ)")
        #endif

        // A picture with an infinite and a NaN half in it, binned: counted, never an index past the bins.
        do {
            let w = 4, h = 1
            // RGBA half floats: +inf, NaN, 2.0 (past white), 0.5.
            let values: [UInt16] = [0x7C00, 0x7C00, 0x7C00, 0x3C00, 0x7E00, 0x7E00, 0x7E00, 0x3C00,
                                    0x4000, 0x4000, 0x4000, 0x3C00, 0x3800, 0x3800, 0x3800, 0x3C00]
            let data = Data(bytes: values, count: values.count * 2) as CFData
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)
            if let odd = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                                 space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, bitmapInfo: info,
                                 provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
               let z = HDRHistogram.zone(edr: odd, headroom: 4, weight: 1) {
                expect(z.samples == 4 && (0..<4).allSatisfy { c in z.sdr[(c * 256)..<(c * 256 + 256)].reduce(0) { $0 + Int($1) } + z.inHDR(c) == 4 },
                       "infinite and NaN halves are counted once each, not trapped on")
                expect(z.hdr[z.hdrBins - 1] == 1, "an infinite value is in the top bin")
                expect(z.inHDR(0) == 2, "past white: the infinite and the 2.0 (\(z.inHDR(0)))")
            } else { expect(false, "the half-float test picture") }
        }

        // No look: Enable HDR off, or a frame with no curve from its session, gives none (the panel draws the SDR
        // histogram, as before).
        var off = FrameEdit()
        off.hdr = false
        var on = FrameEdit()
        on.hdr = true
        FeatureFlags.screenShowsHDR = true
        if let session {
            expect(HDRLook.of(off, .curve(session)) == nil, "Enable HDR off gives no look")
            expect(HDRLook.of(on, nil) == nil && HDRLook.of(on, .refused("x")) == nil, "no curve from the session gives no look")
            FeatureFlags.screenShowsHDR = false
            expect(HDRLook.of(on, .curve(session)) == nil, "no screen of this Mac shows HDR gives no look")
            FeatureFlags.screenShowsHDR = true
            if HDRGainMap.supported { expect(HDRLook.of(on, .curve(session)) != nil, "on, with a curve and a screen: a look") }
        }

        print(failed == 0 ? "HDR histogram: all \(passed) checks pass" : "HDR histogram: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
