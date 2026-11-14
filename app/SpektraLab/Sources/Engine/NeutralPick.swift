//  NeutralPick.swift — the neutral-grey eyedroppers (吸管, the owner, 2026-11-11): a click on something that
//  should be grey sets a white balance that makes it grey. Two of them, each calibrating its own stage:
//
//  - **Decode › White Balance** (`decodeBalance`): the RAW's own white balance, before the film — the place a
//    grey card is meant for. The point is taken back through the canvas's crops to the original's pixels
//    (`Geometry.originalPoint`), and the temperature and tint are **solved on the decode itself**: the patch is
//    rendered through the very `CIRAWFilter` recipe a develop uses (`RawExposure.prepare`) and moved by Newton's
//    method until its linear R = G = B. Nothing is assumed about how `CIRAWFilter.neutralLocation` counts its
//    coordinates; what is set is what was measured neutral.
//  - **Edit › Temperature** (`printBalance`): Layer 2's on the finished print. Its white balance is the kernel's
//    first step, gains on the print's encoded values (`Layer2Uniforms.tone`: R × (1 + 0.18 t), G × (1 − 0.12 g),
//    B × (1 − 0.18 t)), so the temperature and tint that make the sampled print grey have a closed form. A grey
//    is a grey in any RGB with a D65 white, and the same curve on every channel keeps it so: the develop is
//    sampled in its own encoding.
//
//  No UIKit: `tools/layer2_selftest.swift`-style checks compile this alone.

import CoreGraphics
import CoreImage
import Foundation

enum NeutralPick {
    /// Which white balance the eyedropper calibrates.
    enum Target: String, Sendable {
        case decode, print
    }

    // MARK: the print (Layer 2)

    /// Temperature and tint, each −100…100, whose gains make the print's (r, g, b) grey; `clamped` where the
    /// slider's range could not reach it (the nearest is given).
    struct PrintBalance: Equatable, Sendable {
        var temperature: Double
        var tint: Double
        var clamped: Bool
    }

    static func printBalance(r: Double, g: Double, b: Double) -> PrintBalance? {
        guard r > 1e-4, g > 1e-4, b > 1e-4 else { return nil }
        // R (1 + a) = B (1 − a), a = 0.18 t; then G (1 − c) = that level, c = 0.12 g.
        let a = (b - r) / (b + r)
        let level = r * (1 + a)
        let c = 1 - level / g
        let t = 100 * a / 0.18, tint = 100 * c / 0.12
        let ct = min(max(t, -100), 100), cg = min(max(tint, -100), 100)
        return PrintBalance(temperature: ct, tint: cg, clamped: ct != t || cg != tint)
    }

    /// The mean of a square of `radius` pixels about the normalised point `n` (top-left origin) of `image`, in
    /// its own colour space's encoded values, 0…1. Nil off the picture.
    static func sample(_ image: CGImage, at n: CGPoint, radius: Int = 3) -> SIMD3<Double>? {
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        let w = image.width, h = image.height
        let cx = min(max(Int(n.x * CGFloat(w)), 0), w - 1), cy = min(max(Int(n.y * CGFloat(h)), 0), h - 1)
        let x0 = max(cx - radius, 0), y0 = max(cy - radius, 0)
        let x1 = min(cx + radius, w - 1), y1 = min(cy + radius, h - 1)
        guard let patch = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) else { return nil }
        let pw = patch.width, ph = patch.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.displayP3)!
        var px = [UInt16](repeating: 0, count: pw * ph * 4)
        guard let ctx = CGContext(data: &px, width: pw, height: ph, bitsPerComponent: 16, bytesPerRow: pw * 8, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        ctx.draw(patch, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        var sum = SIMD3<Double>(0, 0, 0)
        for i in 0..<(pw * ph) {
            sum += SIMD3(Double(px[4 * i]), Double(px[4 * i + 1]), Double(px[4 * i + 2]))
        }
        return sum / Double(pw * ph) / 65535
    }

    // MARK: the decode (the RAW's white balance)

    /// The decode's white balance that makes the point grey, and how far from grey it left it (the largest of
    /// |log R/G| and |log B/G|; under 0.01 is a grey to the eye).
    struct DecodeBalance: Equatable, Sendable {
        var temperature: Double
        var tint: Double
        var residual: Double
        var steps: Int
    }

    /// The decode's own ranges (Decode › White Balance's rulers).
    static let temperatureRange = 2000.0...50000.0
    static let tintRange = -150.0...150.0
    /// The long edge the patch is rendered at: a grey card a few pixels across in a 45 MP frame is still one.
    static let measureEdge = 1600

    /// The white balance that makes the original's point `p` (normalised, top-left) grey in the decode of
    /// `url` under `settings`, from `start` (the decode's temperature and tint now). Nil when the file cannot
    /// be read or the point is too dark to have a colour.
    static func decodeBalance(url: URL, settings: DecodeSettings, at p: CGPoint,
                              start: (temperature: Double, tint: Double)) -> DecodeBalance? {
        func measure(_ temperature: Double, _ tint: Double) -> SIMD2<Double>? {
            var s = settings
            s.whiteBalance = .custom
            s.temperature = temperature
            s.tint = tint
            guard let image = RawExposure.prepare(url, settings: s, longEdge: measureEdge)?.image else { return nil }
            let e = image.extent
            // Core Image counts from the bottom.
            let x = e.minX + p.x * e.width, y = e.minY + (1 - p.y) * e.height
            let patch = CGRect(x: (x - 3).rounded(.down), y: (y - 3).rounded(.down), width: 7, height: 7).intersection(e)
            guard !patch.isEmpty else { return nil }
            var px = [Float](repeating: 0, count: Int(patch.width) * Int(patch.height) * 4)
            context.render(image, toBitmap: &px, rowBytes: Int(patch.width) * 16, bounds: patch, format: .RGBAf,
                           colorSpace: linear)
            var r = 0.0, g = 0.0, b = 0.0
            for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]) }
            // Too dark to have a colour: the noise would be balanced.
            guard g / Double(px.count / 4) > 0.002, r > 0, b > 0 else { return nil }
            return SIMD2(log(r / g), log(b / g))
        }
        var t = start.temperature.clamped(to: temperatureRange), k = start.tint.clamped(to: tintRange)
        guard var f = measure(t, k) else { return nil }
        var steps = 0
        while max(abs(f.x), abs(f.y)) > 0.004, steps < 8 {
            steps += 1
            // The Jacobian by small steps: a temperature in proportion, a tint in its own units.
            let dt = max(t * 0.03, 50), dk = 2.0
            guard let ft = measure(t + dt, k), let fk = measure(t, k + dk) else { break }
            let j11 = (ft.x - f.x) / dt, j21 = (ft.y - f.y) / dt
            let j12 = (fk.x - f.x) / dk, j22 = (fk.y - f.y) / dk
            let det = j11 * j22 - j12 * j21
            guard abs(det) > 1e-12 else { break }
            let st = (j22 * f.x - j12 * f.y) / det, sk = (j11 * f.y - j21 * f.x) / det
            // A step no further than a third of the scale at once: the decode is not linear in either.
            let nt = (t - max(min(st, t / 3), -t / 3)).clamped(to: temperatureRange)
            let nk = (k - max(min(sk, 50), -50)).clamped(to: tintRange)
            guard let nf = measure(nt, nk) else { break }
            t = nt; k = nk; f = nf
        }
        return DecodeBalance(temperature: t, tint: k, residual: max(abs(f.x), abs(f.y)), steps: steps)
    }

    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                     .cacheIntermediates: false])
}
