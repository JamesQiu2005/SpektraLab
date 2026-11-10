//  HDRHistogram.swift — the histogram of the HDR rendition: one plot that goes on past SDR white.
//
//  The owner, 2026-11-03, rejecting a separate bar chart: "I thought with HDR, we would have the pixels connected
//  instead of separated" -- Lightroom Classic's HDR histogram is the reference. One continuous plot: the x axis
//  runs from black through SDR white and on, with no gap, into the HDR range; the same R, G, B and luminance
//  curves go across the white line in the same style; a thin line marks SDR white, the HDR side is shaded a
//  little darker with a faint line at each stop, and a bar under the plot says SDR and HDR.
//
//  - **Which pixels**: the histogram's own picture (the 640 px copy after Layer 2), 8-bit Display P3. Each
//    pixel's linear channel c becomes `c · 2^(w · log2 gain)`, with the gain of the app's one HDR structure:
//    the local tone's, the grain carried at the paper's slope (`HDRGrainGain.log2Gains`, its σ from this
//    picture's own grain). In HDR mode the whole histogram is of the HDR picture: pixels the gain lifts but
//    that stay under white move within the SDR part too.
//  - **Which bins**: a value up to 1 goes in the SDR span exactly as `Layer2Histogram` bins it (the encoded
//    value × 255, rounded; luminance is the linear luminance's); a value past 1 goes in the HDR span by its
//    stop, log2 of the value, `binsPerStop` a stop up to log2 H, the curve's headroom.
//  - **Which weight**: the canvas's (`HDRLook.weight(headroom:)` for the screen's headroom now), so the plot is
//    what the screen shows; on an SDR screen the canvas shows none, and the plot is made at w = 1 so it still
//    shows what the file holds (what the export's map gives a screen with the full headroom).
//
//  No UIKit: the macOS checks compile this (tools/hdr_histogram_selftest.sh).
//
//  HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D7 (no separate amber zone). On the Mac:
//  - **No `Float16`**: the GPU's half floats are read through a table of `HDRMath.half` (all 65,536 bit
//    patterns, made once), since the x86_64 slice of a Release build has no `Float16` (the critic, 2026-11-06:
//    Debug builds the active arch only, so only Release would fail).
//  - **A value that is not finite is never an index**: past white, the stop is held to the top bin before it
//    becomes an `Int` (an infinite half, which no kernel should make, would trap there).
//  - The curve (and its tables) is the session's, from the engine (`HDRLook`, `HDRSessionCurve`), not a file's.

import CoreGraphics
import Foundation

struct HDRZone: Equatable, Sendable {
    static let binsPerStop = 32
    /// `Layer2Histogram`'s layout: red, green, blue, then luminance, 256 bins each.
    static let channels = 4
    static let luma = 3

    /// log2 H: the HDR span's width in stops.
    var stops: Double
    /// The SDR span: 4 × 256 counts, the HDR picture's values up to SDR white.
    var sdr: [UInt32]
    /// The HDR span: 4 × n counts by stop above SDR white, `binsPerStop` a stop, 0 … `stops`.
    var hdr: [UInt32]
    /// Pixels read.
    var samples: Int
    /// The weight they were taken at.
    var weight: Double

    var hdrBins: Int { hdr.count / Self.channels }

    /// Pixels past SDR white in a channel (0 red … 3 luminance).
    func inHDR(_ channel: Int) -> Int { hdr[(channel * hdrBins)..<((channel + 1) * hdrBins)].reduce(0) { $0 + Int($1) } }
    /// Pixels whose luminance is past SDR white.
    var inZone: Int { inHDR(Self.luma) }
    /// Their share of the picture.
    var share: Double { samples > 0 ? Double(inZone) / Double(samples) : 0 }

    /// The HDR span's share of the plot's width: 15 % a stop, 40 % at most.
    static func fraction(_ stops: Double) -> CGFloat { min(0.4, CGFloat(stops) * 0.15) }

    /// How many display bins the HDR span takes beside the SDR span's 256, at the same width a bin.
    static func displayBins(stops: Double) -> Int {
        let f = Double(fraction(stops))
        return max(1, Int((256 * f / (1 - f)).rounded()))
    }

    /// The four channels as one row of counts each (red, green, blue, luminance): the SDR span's 256 bins and
    /// after them the HDR span's, each as wide on screen as an SDR bin. The HDR counts are shared out by the
    /// part of a bin each display bin covers, so the total of a row is the pixels read.
    func combined() -> [[Float]] {
        let n = hdrBins, m = Self.displayBins(stops: stops)
        return (0..<Self.channels).map { c in
            var row = sdr[(c * 256)..<((c + 1) * 256)].map { Float($0) }
            var tail = [Float](repeating: 0, count: m)
            for i in 0..<n {
                let count = Float(hdr[c * n + i])
                guard count > 0 else { continue }
                let lo = Double(i) / Double(n), hi = Double(i + 1) / Double(n)
                let first = Int(lo * Double(m)), last = min(m - 1, Int(hi * Double(m) - 1e-9))
                guard first <= last else { continue }
                for j in first...last {
                    let overlap = min(hi, Double(j + 1) / Double(m)) - max(lo, Double(j) / Double(m))
                    tail[j] += count * Float(max(0, overlap) * Double(n))
                }
            }
            row += tail
            return row
        }
    }
}

enum HDRHistogram {
    /// Counts the HDR rendition's values: linear Display P3 channels already lifted.
    private struct Counter {
        let top: Double
        let n: Int
        var sdr = [UInt32](repeating: 0, count: HDRZone.channels * 256)
        var hdr: [UInt32]
        init(headroom: Double) {
            top = log2(max(headroom, 1))
            n = max(1, Int((top * Double(HDRZone.binsPerStop)).rounded()))
            hdr = [UInt32](repeating: 0, count: HDRZone.channels * n)
        }

        mutating func put(_ v: Double, channel: Int) {
            if v > 1 + 1e-4 {
                hdr[channel * n + min(n - 1, Int(log2(v) / top * Double(n)))] += 1
            } else {
                let e = HDRMath.encode(min(1, max(0, v)))
                sdr[channel * 256 + min(255, Int(e * 255 + 0.5))] += 1
            }
        }

        mutating func add(_ r: Double, _ g: Double, _ b: Double) {
            put(r, channel: 0); put(g, channel: 1); put(b, channel: 2)
            put(HDRMath.luminance(r, g, b), channel: HDRZone.luma)
        }

        func zone(samples: Int, weight: Double) -> HDRZone {
            HDRZone(stops: top, sdr: sdr, hdr: hdr, samples: samples, weight: weight)
        }
    }

    /// The histogram of a flat field's pixels: 8-bit RGBA Display P3 (`pixels` pixels, 4 bytes each; alpha is not
    /// read), each its own local tone (no grain term).
    static func zone(rgba: UnsafePointer<UInt8>, pixels: Int, look: HDRLook, weight: Double) -> HDRZone {
        var counter = Counter(headroom: look.curve.headroom)
        let w = min(1, max(0, weight))
        let lin = (0..<256).map { HDRMath.decode(Double($0) / 255) }
        let tables = look.tables
        for i in 0..<pixels {
            let r = lin[Int(rgba[i * 4])], g = lin[Int(rgba[i * 4 + 1])], b = lin[Int(rgba[i * 4 + 2])]
            let y = HDRMath.luminance(r, g, b)
            var gain = 1.0
            if y > 0 {
                let ly = HDRGrainGain.l2y(y)
                gain = exp2(w * HDRGrainGain.log2Gain(l2y: ly, local: ly, tables: tables))
            }
            counter.add(r * gain, g * gain, b * gain)
        }
        return counter.zone(samples: pixels, weight: w)
    }

    /// The histogram of a picture, read as Display P3, 8 bits (the rendition's own measure). Any thread.
    static func zone(of image: CGImage, look: HDRLook, weight: Double) -> HDRZone? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return data.withUnsafeBufferPointer { zone(rgba: $0.baseAddress!, width: w, height: h, look: look, weight: weight) }
    }

    /// The histogram of an 8-bit RGBA Display P3 picture of `width` × `height`, through the grain-aware gain.
    static func zone(rgba: UnsafePointer<UInt8>, width w: Int, height h: Int, look: HDRLook, weight: Double) -> HDRZone {
        var counter = Counter(headroom: look.curve.headroom)
        let wt = min(1, max(0, weight))
        let lin = (0..<256).map { HDRMath.decode(Double($0) / 255) }
        var l2y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            l2y[i] = Float(HDRGrainGain.l2y(HDRMath.luminance(lin[Int(rgba[i * 4])], lin[Int(rgba[i * 4 + 1])], lin[Int(rgba[i * 4 + 2])])))
        }
        let sigma = HDRGrainGain.sigma(forWidth: HDRGrainGain.grainWidth(l2y: l2y, width: w, height: h))
        let lg = HDRGrainGain.log2Gains(l2y: l2y, width: w, height: h, tables: look.tables, sigma: sigma)
        for i in 0..<(w * h) {
            // Black (no luminance) has no gain to carry; it is counted where it is.
            let gain = l2y[i] > -29 ? exp2(wt * Double(lg[i])) : 1
            counter.add(lin[Int(rgba[i * 4])] * gain, lin[Int(rgba[i * 4 + 1])] * gain, lin[Int(rgba[i * 4 + 2])] * gain)
        }
        return counter.zone(samples: w * h, weight: wt)
    }

    /// Every half float's value, by its bits (`HDRMath.half`): the GPU's picture read with no `Float16` (header).
    nonisolated(unsafe) private static let halves: UnsafeMutablePointer<Float> = {
        let t = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
        for bits in 0..<65536 { t[bits] = HDRMath.half(UInt16(bits)) }
        return t
    }()

    /// The histogram of the page's own HDR picture (`HDRRendition.make`'s half-float linear P3, what the canvas
    /// shows): its values binned as they are — no second gain in Swift. The app's way (2026-11-03: the Swift
    /// pass took 3 s a toggle on a debug build, and its answer was dropped for a newer ask, so the
    /// histogram never followed Enable HDR).
    @_optimize(speed)
    static func zone(edr image: CGImage, headroom: Double, weight: Double) -> HDRZone? {
        guard image.bitsPerComponent == 16, image.bitsPerPixel == 64, let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.width * image.height * 8, let base = CFDataGetBytePtr(data) else { return nil }
        let n = image.width * image.height, stride = image.bytesPerRow / 2
        let half = UnsafeRawPointer(base).assumingMemoryBound(to: UInt16.self)
        let float = halves
        let top = log2(max(headroom, 1))
        let bins = max(1, Int((top * Double(HDRZone.binsPerStop)).rounded()))
        var sdr = [UInt32](repeating: 0, count: HDRZone.channels * 256)
        var hdr = [UInt32](repeating: 0, count: HDRZone.channels * bins)
        // Linear 0 … 1 to the SDR bin, through the sRGB curve, in 4096 steps (finer than a bin everywhere).
        let steps = 4096
        let code = UnsafeMutablePointer<Int>.allocate(capacity: steps + 1)
        defer { code.deallocate() }
        var k = 0
        while k <= steps { code[k] = min(255, Int(HDRMath.encode(Double(k) / Double(steps)) * 255 + 0.5)); k += 1 }
        let scale = Double(bins) / max(top, 1e-6), top1 = Double(bins - 1)
        sdr.withUnsafeMutableBufferPointer { s in hdr.withUnsafeMutableBufferPointer { h in
            var y = 0
            while y < image.height {
                var x = 0
                while x < image.width {
                    let o = y * stride + x * 4
                    let r = Double(float[Int(half[o])]), g = Double(float[Int(half[o + 1])]), b = Double(float[Int(half[o + 2])])
                    let l = 0.2289746 * r + 0.6917385 * g + 0.0792869 * b
                    // Unrolled: an array of the four a pixel was 307,200 allocations a histogram in a debug build.
                    if r > 1 + 1e-4 { h[Int(min(top1, log2(r) * scale))] += 1 } else { s[code[Int(min(1, max(0, r)) * Double(steps) + 0.5)]] += 1 }
                    if g > 1 + 1e-4 { h[bins + Int(min(top1, log2(g) * scale))] += 1 } else { s[256 + code[Int(min(1, max(0, g)) * Double(steps) + 0.5)]] += 1 }
                    if b > 1 + 1e-4 { h[2 * bins + Int(min(top1, log2(b) * scale))] += 1 } else { s[512 + code[Int(min(1, max(0, b)) * Double(steps) + 0.5)]] += 1 }
                    if l > 1 + 1e-4 { h[3 * bins + Int(min(top1, log2(l) * scale))] += 1 } else { s[768 + code[Int(min(1, max(0, l)) * Double(steps) + 0.5)]] += 1 }
                    x += 1
                }
                y += 1
            }
        } }
        return HDRZone(stops: top, sdr: sdr, hdr: hdr, samples: n, weight: min(1, max(0, weight)))
    }
}

