//  CineonLUT.swift — the one transform between the Digital Intermediate and
//  everything else in the app (RFC-028 §13, 2026-09-29).
//
//  The engine writes a DI as **Cineon log** with ProPhoto RGB primaries: the
//  file a colourist gets (`spk_render_digital_intermediate`). Inside the app
//  the picture lives in ProPhoto RGB like every other frame, so the canvas
//  reads the DI through the **DI view**: one Cineon → ProPhoto 3D LUT, which is
//  also one of the two `.cube` files shipped beside every DI export. The
//  canvas samples that very file (`Resources/DI/`), so "the DI through our LUT
//  is the canvas" is a property of the data, not of two implementations.
//
//  The view, in four steps (RFC-029's findings, placed in the LUT rather than
//  the engine, by the user's decision of 2026-09-29):
//
//   1. **Decode** — Kodak's Cineon, as the standard implementations apply it
//      (colour-science `log_decoding_Cineon`, Nuke's Log2Lin): white 685 →
//      1.0, black 95 → 0 (the film base), 300 codes per decade. The engine
//      encodes with the same four constants (`digital_intermediate.hpp`).
//   2. **Tone, on luminance** — identity up to a knee, then RFC-023's m = 2
//      smooth-min shoulder to display white. The knee is *solved*, not set: the
//      softest one that lands the DI's top code (+6.2 stops over grey) 1/16
//      stop under white, so every highlight the file holds is on screen. Mid
//      grey and everything below the knee are untouched: the view adds no
//      contrast of its own, so what shows is the film's, which the DI keeps
//      (RFC-030 §2). Applied as `x · T(Y)/Y`, so a colour
//      keeps its hue and saturation — per-channel curves turn bright skin
//      +13.6° toward yellow (RFC-029 §6.2).
//   3. **Path to white** — a colour the destination cannot hold at that
//      brightness loses chroma at constant Oklab hue and lightness until it
//      fits, rather than clipping channel by channel.
//   4. **Encode** — ROMM (ProPhoto) or Rec.709 γ2.4.
//
//  No parameters: the view is the same for every frame, so the file and the
//  canvas can never disagree, and nothing new is copyable.

import Foundation
import Metal
import simd

enum CineonLUT {
    static let referenceWhite = 685.0
    static let referenceBlack = 95.0
    static let codesPerDecade = 300.0
    static let maxCode = 1023.0
    static let blackOffset = pow(10.0, (referenceBlack - referenceWhite) / codesPerDecade)
    /// The 3D grid of both files and the canvas.
    static let size = 65

    /// Code value 0…1 → linear, 1.0 at reference white, 0 at the film base.
    static func decode(_ code: Double) -> Double {
        (pow(10.0, (code * maxCode - referenceWhite) / codesPerDecade) - blackOffset) / (1 - blackOffset)
    }

    /// ProPhoto (ROMM) RGB's transfer function: linear below 1/512, then 1/1.8.
    static func rommEncode(_ l: Double) -> Double {
        let x = min(max(l, 0), 1)
        return x < 1.0 / 512 ? 16 * x : pow(x, 1 / 1.8)
    }

    // MARK: - the tone scale

    /// Mid grey, the Cineon convention's 0.18 (code 467.8), held fixed.
    static let grey = 0.18
    /// Display white in stops over grey, and the DI's top code in the same.
    static let whiteStops = log2(1 / grey)
    static let ceilingStops = log2(decode(1) / grey)
    /// How far under white the top code lands.
    static let ceilingMargin = 1.0 / 16

    /// RFC-023's m = 2 branch: `ΔH/√(H² + Δ²)`.
    private static func shoulder(_ delta: Double, _ room: Double) -> Double {
        delta * room / (room * room + delta * delta).squareRoot()
    }

    /// The knee, in stops over grey: the softest (lowest) one, never below
    /// grey, that puts the ceiling `ceilingMargin` under white. Bisection;
    /// the landing rises monotonically with the knee.
    static let knee: Double = {
        func landing(_ k: Double) -> Double { k + shoulder(ceilingStops - k, whiteStops - k) }
        let target = whiteStops - ceilingMargin
        if landing(0) >= target { return 0 }
        var lo = 0.0, hi = whiteStops - 1e-9
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            if landing(mid) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }()

    /// Luminance in → luminance out, linear.
    static func tone(_ y: Double) -> Double {
        guard y > 0 else { return 0 }
        let u = log2(y / grey)
        guard u > knee else { return y }
        return grey * pow(2, knee + shoulder(u - knee, whiteStops - knee))
    }

    // MARK: - colour

    /// ProPhoto RGB's luminance row (ROMM, D50), the Y the tone scale reads.
    static let proPhotoY = SIMD3(0.2880, 0.7119, 0.0001)

    /// ProPhoto RGB (D50) → ITU-R BT.709 (D65), Bradford. From colour-science
    /// 0.4.7 `matrix_RGB_to_RGB(..., chromatic_adaptation_transform="Bradford")`,
    /// each row then divided by its sum: the published whitepoints leave the
    /// rows 2e-4 off 1, and a grey must come out of a technical LUT grey.
    static let proPhotoToRec709: simd_double3x3 = {
        let rows = [SIMD3(2.0342930024, -0.7276819247, -0.3068105500),
                    SIMD3(-0.2289038910, 1.2318483428, -0.0028576467),
                    SIMD3(-0.0085464902, -0.1532801862, 1.1615322465)]
        return simd_double3x3(rows: rows.map { $0 / ($0.x + $0.y + $0.z) })
    }()

    /// Each destination's linear RGB → Oklab's LMS (M1 · RGB→XYZ D65).
    /// ProPhoto → XYZ is Bradford-adapted to D65 (colour-science 0.4.7).
    private static let oklabM1 = simd_double3x3(rows: [
        SIMD3(0.8189330101, 0.3618667424, -0.1288597137),
        SIMD3(0.0329845436, 0.9293118715, 0.0361456387),
        SIMD3(0.0482003018, 0.2643662691, 0.6338517070)])
    private static let oklabM2 = simd_double3x3(rows: [
        SIMD3(0.2104542553, 0.7936177850, -0.0040720468),
        SIMD3(1.9779984951, -2.4285922050, 0.4505937099),
        SIMD3(0.0259040371, 0.7827717662, -0.8086757660)])
    private static let proPhotoToXYZ65 = simd_double3x3(rows: [
        SIMD3(0.7555287933, 0.1127362165, 0.0820865580),
        SIMD3(0.2682481575, 0.7151801392, 0.0165701125),
        SIMD3(0.0039166867, -0.0129345407, 1.0978022305)])
    private static let rec709ToXYZ65 = simd_double3x3(rows: [
        SIMD3(0.4123907993, 0.3575843394, 0.1804807884),
        SIMD3(0.2126390059, 0.7151686788, 0.0721923154),
        SIMD3(0.0193308187, 0.1191947798, 0.9505321522)])

    /// Fit `rgb` into [0, 1] by lowering Oklab chroma at constant lightness
    /// and hue — the largest chroma that fits, found by bisection.
    static func pathToWhite(_ rgb: SIMD3<Double>, toLMS: simd_double3x3) -> SIMD3<Double> {
        let inside = { (v: SIMD3<Double>) in v.min() >= -1e-9 && v.max() <= 1 + 1e-9 }
        if inside(rgb) { return rgb }
        let fromLMS = toLMS.inverse
        let lms = toLMS * rgb
        let lab = oklabM2 * SIMD3(cbrt(max(lms.x, 0)), cbrt(max(lms.y, 0)), cbrt(max(lms.z, 0)))
        let m2inv = oklabM2.inverse
        func back(_ s: Double) -> SIMD3<Double> {
            let l_ = m2inv * SIMD3(lab.x, lab.y * s, lab.z * s)
            return fromLMS * (l_ * l_ * l_)
        }
        if !inside(back(0)) { return simd_clamp(back(0), .zero, SIMD3(repeating: 1)) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if inside(back(mid)) { lo = mid } else { hi = mid }
        }
        return simd_clamp(back(lo), .zero, SIMD3(repeating: 1))
    }

    enum Target: CaseIterable {
        case proPhoto, rec709

        var fileName: String {
            switch self {
            case .proPhoto: "SpektraLab DI view, Cineon to ProPhoto RGB.cube"
            case .rec709: "SpektraLab DI view, Cineon to Rec709.cube"
            }
        }
        var title: String {
            switch self {
            case .proPhoto: "SpektraLab DI view: Cineon log (ProPhoto primaries) to ProPhoto RGB"
            case .rec709: "SpektraLab DI view: Cineon log (ProPhoto primaries) to Rec.709 gamma 2.4"
            }
        }
    }

    /// The DI view: one Cineon code triple → one encoded triple.
    static func view(_ code: SIMD3<Double>, to target: Target) -> SIMD3<Double> {
        let lin = SIMD3(max(decode(code.x), 0), max(decode(code.y), 0), max(decode(code.z), 0))
        let y = simd_dot(proPhotoY, lin)
        let toned = y > 0 ? lin * (tone(y) / y) : .zero
        switch target {
        case .proPhoto:
            let v = pathToWhite(toned, toLMS: oklabM1 * proPhotoToXYZ65)
            return SIMD3(rommEncode(v.x), rommEncode(v.y), rommEncode(v.z))
        case .rec709:
            let v = pathToWhite(proPhotoToRec709 * toned, toLMS: oklabM1 * rec709ToXYZ65)
            return SIMD3(pow(v.x, 1 / 2.4), pow(v.y, 1 / 2.4), pow(v.z, 1 / 2.4))
        }
    }

    // MARK: - the files

    /// A 3D `.cube` (Adobe/Resolve format: red fastest, domain 0…1).
    static func cube(_ target: Target) -> String {
        var out = "TITLE \"\(target.title)\"\n"
        out += "# Decode: Kodak Cineon, white 685, black 95, 0.002 D/code, negative gamma 0.6.\n"
        out += String(format: "# Tone on luminance: identity to %.4f stops over grey 0.18, then a smooth-min shoulder; top code lands 1/16 stop under white.\n", knee)
        out += "# Colours past white lose chroma at constant Oklab hue. Generated by CineonLUT.swift.\n"
        out += "LUT_3D_SIZE \(size)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let v = view(SIMD3(Double(r) / n, Double(g) / n, Double(b) / n), to: target)
                    out += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z)
                }
            }
        }
        return out
    }

    /// The shipped file for `target`, in the app bundle.
    static func bundled(_ target: Target) -> URL? {
        Bundle.main.url(forResource: target.fileName, withExtension: nil, subdirectory: "Resources/DI")
            ?? Bundle(for: BundleToken.self).url(forResource: target.fileName, withExtension: nil,
                                                 subdirectory: "Resources/DI")
    }
    private final class BundleToken {}

    /// Copy both shipped files into `directory` unless they are already there,
    /// so a batch of DIs into one folder carries one pair.
    @discardableResult
    static func copyBeside(directory: URL) throws -> [URL] {
        var written: [URL] = []
        for target in Target.allCases {
            let url = directory.appending(path: target.fileName)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let source = bundled(target) else { continue }
            try FileManager.default.copyItem(at: source, to: url)
            written.append(url)
        }
        return written
    }

    /// Parse a 3D `.cube` into RGBA floats, red fastest. Only what `cube`
    /// writes: a size line, optional domain lines, comments, triples.
    static func parse(_ text: String) -> (size: Int, rgba: [Float])? {
        var size = 0
        var rgba: [Float] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            if first.isNumber || first == "-" || first == "." {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]),
                      let b = Float(parts[2]) else { return nil }
                rgba += [r, g, b, 1]
            } else if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
            }
        }
        guard size > 1, rgba.count == size * size * size * 4 else { return nil }
        return (size, rgba)
    }

    /// The canvas's table: the shipped ProPhoto file as a 3D texture, sampled
    /// with the hardware's trilinear filter exactly as a LUT host would.
    static func makeTexture(device: MTLDevice) -> MTLTexture? {
        guard let url = bundled(.proPhoto), let text = try? String(contentsOf: url, encoding: .utf8),
              let (n, rgba) = parse(text) else { return nil }
        let half = rgba.map { Float16($0) }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba16Float
        d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        half.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: n * 8, bytesPerImage: n * n * 8)
        }
        return t
    }
}
