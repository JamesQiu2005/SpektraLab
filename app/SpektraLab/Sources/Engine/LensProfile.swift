//  LensProfile.swift — a lens's radial correction, held by the app, for a RAW Core Image cannot correct.
//
//  Core Image corrects a lens itself where it knows how (`CIRAWFilter.isLensCorrectionSupported`: Canon CR3, Fuji
//  RAF, Nikon NEF, Panasonic RW2, a DNG whose OpcodeList3 carries WarpRectilinear — measured 2026-11-13 on the
//  `RAW_decode_tests` samples). It does not for a Sony ARW, whose camera writes its lens's parameters into the raw
//  SubIFD all the same (`LensProfileReader`). So 2.3.2's Lens Correction did nothing on a Sony frame: that is what
//  this type and its reader are for.
//
//  **The model is radial and normalised**, so one profile corrects a decode of any size (proxy, live, full,
//  export): a radius `r` is the distance from the optical centre over the distance from it to the frame's farthest
//  corner (the half-diagonal for a centred lens), in the corrected picture.
//
//  - **distortion** `D(r)`: the radius the corrected picture's point at `r` is taken from, over `r` (green's);
//  - **lateral chromatic aberration** `CR(r)`, `CB(r)`: red's and blue's radius over green's at the same point;
//  - **vignetting** `G(ρ)`: the gain at the *source* radius `ρ = r·D(r)` — light falls off on the sensor, before
//    any warp, so a profile's gain is the sensor's and is looked up where the pixel came from.
//
//  Each is a `Radial`: knots and values, a monotone cubic between them (Fritsch–Carlson), the end slopes held beyond.
//  Adobe's LCPs (`LCP.profile`) fill the same type; nothing here knows where a profile came from but `source`.
//
//  **Applying** (`apply`) is one Core Image kernel, compiled at run time from the string below
//  (`CIKernel.kernels(withMetalString:)`, macOS 15 / Catalyst 18, the app's floor): no `.metal` file joins the
//  app's target (AGENTS.md), and no CI-kernel build rule is needed in `gen_project.py`'s project. The profile is
//  handed to the kernel as a 1024 × 1 table of offsets, scaled so a half-float working format keeps them to better
//  than 1e-5 of a radius. It is applied in linear light, inside the RAW filter (`CIRAWFilter.linearSpaceFilter`,
//  `LensCorrection.prepare`), so Apple's stock decode tones the corrected picture as it toned the uncorrected one,
//  and the engine's linear decode is corrected by the same step. Its output has the input's extent exactly.

import CoreImage
import Foundation

struct LensProfile: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case source = "source", centre = "centre", distortion = "distortion", vignetting = "vignetting",
            redScale = "redScale", blueScale = "blueScale"
    }

    /// Where a profile came from. Its raw value is part of every key a corrected picture is kept by
    /// (`LensCorrection.word`): a reader whose model changes moves its word.
    enum Source: String, Codable, Sendable {
        /// A Sony ARW's own parameters (`LensProfileReader.sony`).
        case sonyEmbedded = "sony-embedded.1"
        /// A DNG's WarpRectilinear and FixVignetteRadial opcodes (`LensProfileReader.dngOpcodes`).
        case dngOpcodes = "dng-opcodes.1"
        /// An Adobe lens profile from the app's lens database, made for one frame (`LCP.profile`, `LensDatabase`); its
        /// word also names the lens and its file's hash (`LensDatabase.Resolved.word`).
        case file = "file.1"
    }

    /// A function of radius, sampled: `values[i]` at `radii[i]`, `radii` increasing, at least two.
    struct Radial: Codable, Equatable, Sendable {
        enum CodingKeys: String, CodingKey { case radii = "radii", values = "values" }
        var radii: [Double]
        var values: [Double]

        /// A monotone cubic (Fritsch–Carlson) through the knots; beyond the ends, the end's tangent line.
        func at(_ r: Double) -> Double {
            let n = radii.count
            guard n >= 2 else { return values.first ?? 1 }
            let m = tangents
            if r <= radii[0] { return values[0] + m[0] * (r - radii[0]) }
            if r >= radii[n - 1] { return values[n - 1] + m[n - 1] * (r - radii[n - 1]) }
            var lo = 0, hi = n - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if radii[mid] <= r { lo = mid } else { hi = mid } }
            let h = radii[hi] - radii[lo], t = (r - radii[lo]) / h
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * values[lo] + (t3 - 2 * t2 + t) * h * m[lo]
                + (-2 * t3 + 3 * t2) * values[hi] + (t3 - t2) * h * m[hi]
        }

        private var tangents: [Double] {
            let n = radii.count
            var d = [Double](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) { d[i] = (values[i + 1] - values[i]) / (radii[i + 1] - radii[i]) }
            var m = [Double](repeating: 0, count: n)
            m[0] = d[0]; m[n - 1] = d[n - 2]
            for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
            for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
            for i in 0..<(n - 1) where d[i] != 0 {
                let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
                if s > 9 { let k = 3 / s.squareRoot(); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
            }
            return m
        }

        /// `f` sampled at `count` evenly spaced radii over `0...end`.
        static func sampled(count: Int = 65, to end: Double = 1.25, _ f: (Double) -> Double) -> Radial {
            let radii = (0..<count).map { end * Double($0) / Double(count - 1) }
            return Radial(radii: radii, values: radii.map(f))
        }
    }

    var source: Source
    /// The optical centre in the frame, as a share of its width and height from its top left (0.5, 0.5: centred), in
    /// the RAW's stored orientation (a DNG's opcodes' own).
    var centre: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Source radius over corrected radius, green's. Nil: no distortion correction.
    var distortion: Radial?
    /// Gain at the source radius. Nil: no vignetting correction.
    var vignetting: Radial?
    /// Red's and blue's source radius over green's. Nil: no chromatic aberration correction.
    var redScale: Radial?
    var blueScale: Radial?

    var corrects: Bool { distortion != nil || vignetting != nil || redScale != nil || blueScale != nil }

    /// What the four amounts give at a corrected radius: green's source-radius scale, red's and blue's over it, and
    /// the gain. `distortion` and `vignetting` are 0–1 shares (the gain is raised to its share: a share of the
    /// stops), `chromaticAberration` on or off.
    func evaluate(_ r: Double, distortion a: Double = 1, vignetting v: Double = 1,
                  chromaticAberration ca: Bool = true) -> (green: Double, red: Double, blue: Double, gain: Double) {
        let d = 1 + a * ((distortion?.at(r) ?? 1) - 1)
        let cr = ca ? (redScale?.at(r) ?? 1) : 1, cb = ca ? (blueScale?.at(r) ?? 1) : 1
        let g = vignetting.map { pow(max($0.at(r * d), 1e-3), v) } ?? 1
        return (d, cr, cb, g)
    }
}

// MARK: - applying it

extension LensProfile {
    /// The table's width, and how far in radius it reaches (a source radius past a corner, at the hide zoom's most).
    static let tableWidth = 1024
    static let tableEnd = 1.6
    /// Offsets are stored scaled so a half float keeps them: green's (D − 1)·8, red's and blue's (C − 1)·256,
    /// the gain as log2(G)/4.
    static let scaleDistortion = 8.0, scaleCA = 256.0, scaleGain = 0.25

    /// The zoom (≥ 1) that leaves no empty area: every edge pixel's centre, in every channel, taken from within the
    /// source's outermost pixel centres (so a bilinear sample never reaches outside). 1 where none would show.
    func hideZoom(width: Double, height: Double, distortion a: Double = 1, chromaticAberration ca: Bool = true) -> Double {
        let geo = Mapping(profile: self, width: width, height: height, zoom: 1, distortion: a, chromaticAberration: ca)
        func inside(_ z: Double) -> Bool {
            let steps = 256
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let x = 0.5 + t * (width - 1), y = 0.5 + t * (height - 1)
                for p in [CGPoint(x: x, y: 0.5), CGPoint(x: x, y: height - 0.5), CGPoint(x: 0.5, y: y), CGPoint(x: width - 0.5, y: y)] {
                    for s in geo.sources(of: p, zoom: z)
                        where s.x < 0.5 - 1e-6 || s.y < 0.5 - 1e-6 || s.x > width - 0.5 + 1e-6 || s.y > height - 0.5 + 1e-6 { return false }
                }
            }
            return true
        }
        if inside(1) { return 1 }
        var lo = 1.0, hi = 1.5
        while !inside(hi) && hi < 4 { hi *= 1.25 }
        for _ in 0..<40 { let mid = (lo + hi) / 2; if inside(mid) { hi = mid } else { lo = mid } }
        return hi
    }

    /// The frame's numbers the kernel and its region of interest share, and the profile's scales at the kernel
    /// table's radii (linear between them, as the GPU samples its table): what the CPU asks of the map — the hide
    /// zoom, every tile's region of interest — costs a lookup, not a spline.
    struct Mapping {
        var cx: Double, cy: Double, norm: Double, zoom: Double
        private var green: [Double], red: [Double], blue: [Double]

        init(profile: LensProfile, width: Double, height: Double, zoom: Double, distortion a: Double = 1,
             chromaticAberration ca: Bool = true) {
            let x = Double(profile.centre.x) * width, y = (1 - Double(profile.centre.y)) * height
            cx = x
            cy = y
            norm = [(0.0, 0.0), (width, 0), (0, height), (width, height)]
                .map { ((x - $0.0) * (x - $0.0) + (y - $0.1) * (y - $0.1)).squareRoot() }.max() ?? 1
            self.zoom = zoom
            let e = (0..<LensProfile.tableWidth).map {
                profile.evaluate(LensProfile.tableEnd * Double($0) / Double(LensProfile.tableWidth - 1), distortion: a,
                                 vignetting: 0, chromaticAberration: ca)
            }
            green = e.map(\.green); red = e.map(\.red); blue = e.map(\.blue)
        }

        /// Green's source-radius scale, and red's and blue's over it, at corrected radius `r`.
        func scales(at r: Double) -> (green: Double, red: Double, blue: Double) {
            let u = max(0, r) / LensProfile.tableEnd * Double(LensProfile.tableWidth - 1)
            let i = min(Int(u), LensProfile.tableWidth - 2), t = min(u - Double(i), 1)
            func at(_ v: [Double]) -> Double { v[i] + (v[i + 1] - v[i]) * t }
            return (at(green), at(red), at(blue))
        }

        /// Where green, red and blue of the corrected picture's point `p` are taken from (the frame's own
        /// coordinates; y as Core Image's, which a radial model does not mind).
        func sources(of p: CGPoint, zoom z: Double? = nil) -> [CGPoint] {
            let zz = z ?? zoom
            let qx = (Double(p.x) - cx) / zz, qy = (Double(p.y) - cy) / zz
            let s = scales(at: (qx * qx + qy * qy).squareRoot() / norm)
            return [s.green, s.green * s.red, s.green * s.blue].map { CGPoint(x: cx + qx * $0, y: cy + qy * $0) }
        }
    }

    /// The profile applied to `image`, a frame whose extent is the whole picture (a RAW filter's decode, upright
    /// or not: a radial model turns with it). Same extent out. `hideDistortedAreas` zooms just enough that no empty
    /// area shows; off, what lies outside the source is black.
    func apply(to image: CIImage, distortion a: Double = 1, vignetting v: Double = 1,
               chromaticAberration ca: Bool = true, hideDistortedAreas hide: Bool = true) -> CIImage {
        guard corrects, let kernel = Self.kernel else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 1, extent.height > 1 else { return image }
        let w = Double(extent.width), h = Double(extent.height)
        let zoom = hide && distortion != nil ? hideZoom(width: w, height: h, distortion: a, chromaticAberration: ca) : 1
        let geo = Mapping(profile: self, width: w, height: h, zoom: zoom, distortion: a, chromaticAberration: ca)
        guard let table = table(distortion: a, vignetting: v, chromaticAberration: ca) else { return image }
        let origin = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let out = kernel.apply(extent: bounds, roiCallback: { index, rect in
            guard index == 0 else { return CGRect(x: 0, y: 0, width: Self.tableWidth, height: 1) }
            // The sources of a grid over the rect (a radial map is smooth: its box is the grid's, padded).
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            let n = 16
            for i in 0...n {
                for j in 0...n {
                    let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(n),
                                    y: rect.minY + rect.height * CGFloat(j) / CGFloat(n))
                    for s in geo.sources(of: p) {
                        minX = min(minX, s.x); maxX = max(maxX, s.x); minY = min(minY, s.y); maxY = max(maxY, s.y)
                    }
                }
            }
            let pad = 4 + 0.01 * Double(max(rect.width, rect.height))
            return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad)
                .intersection(bounds.insetBy(dx: -2, dy: -2))
        }, arguments: [origin, table,
                       CIVector(x: geo.cx, y: geo.cy, z: 1 / geo.norm, w: zoom),
                       CIVector(x: CGFloat(Self.tableWidth - 1) / Self.tableEnd, y: 0, z: 0, w: 0),
                       CIVector(x: 0, y: 0, z: w, w: h)])
        guard let out else { return image }
        return out.cropped(to: bounds).transformed(by: .init(translationX: extent.origin.x, y: extent.origin.y))
    }

    /// The kernel's table: green's, red's, blue's offsets and the gain, at `tableWidth` radii over `0...tableEnd`.
    /// Green's, red's and blue's are at the corrected radius; the gain at the source radius (`G(ρ)`, ρ the
    /// table's radius), so the kernel looks it up a second time where the pixel came from.
    func table(distortion a: Double, vignetting v: Double, chromaticAberration ca: Bool) -> CIImage? {
        var px = [Float](repeating: 0, count: Self.tableWidth * 4)
        for i in 0..<Self.tableWidth {
            let r = Self.tableEnd * Double(i) / Double(Self.tableWidth - 1)
            let e = evaluate(r, distortion: a, vignetting: 0, chromaticAberration: ca)
            let g = vignetting.map { pow(max($0.at(r), 1e-3), v) } ?? 1
            px[i * 4] = Float((e.green - 1) * Self.scaleDistortion)
            px[i * 4 + 1] = Float((e.red - 1) * Self.scaleCA)
            px[i * 4 + 2] = Float((e.blue - 1) * Self.scaleCA)
            px[i * 4 + 3] = Float(log2(g) * Self.scaleGain)
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        // No colour space: the table is numbers, never matched.
        return CIImage(bitmapData: data, bytesPerRow: Self.tableWidth * 16,
                       size: CGSize(width: Self.tableWidth, height: 1), format: .RGBAf, colorSpace: nil)
    }

    /// One pass: each channel taken from its own source point, the gain looked up at green's source radius.
    /// `geo` = (cx, cy, 1/norm, zoom); `tab` = (texels per radius); `box` = the source's (x0, y0, x1, y1).
    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    [[stitchable]] float4 spk_lens(coreimage::sampler src, coreimage::sampler lut, float4 geo, float4 tab, float4 box,
                                   coreimage::destination dest) {
        float2 c = geo.xy;
        float2 q = (dest.coord() - c) / geo.w;
        float r = length(q) * geo.z;
        float4 t = lut.sample(lut.transform(float2(r * tab.x + 0.5, 0.5)));
        float dg = 1.0 + t.r / 8.0;
        float2 sg = c + q * dg;
        float2 sr = c + q * dg * (1.0 + t.g / 256.0);
        float2 sb = c + q * dg * (1.0 + t.b / 256.0);
        float4 g4 = lut.sample(lut.transform(float2(r * dg * tab.x + 0.5, 0.5)));
        float gain = exp2(g4.a * 4.0);
        float4 pg = src.sample(src.transform(sg));
        float4 pr = src.sample(src.transform(sr));
        float4 pb = src.sample(src.transform(sb));
        float3 rgb = float3(pr.r, pg.g, pb.b) * gain;
        bool outside = any(sg < box.xy) || any(sg > box.zw) || any(sr < box.xy) || any(sr > box.zw)
            || any(sb < box.xy) || any(sb > box.zw);
        return outside ? float4(0.0, 0.0, 0.0, 1.0) : float4(rgb, pg.a);
    }
    """

    static let kernel: CIKernel? = {
        guard #available(iOS 18.0, macCatalyst 18.0, macOS 15.0, *) else { return nil }
        return (try? CIKernel.kernels(withMetalString: source))?.first { $0.name == "spk_lens" }
    }()
}

/// The profile as a filter, for `CIRAWFilter.linearSpaceFilter`: what the RAW filter hands it is its linear decode,
/// before its tone curve, cropped to the picture and not yet turned upright.
final class LensProfileFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    var profile: LensProfile?
    var distortionAmount = 1.0, vignettingAmount = 1.0, chromaticAberration = true, hideDistortedAreas = true

    override var outputImage: CIImage? {
        guard let inputImage else { return nil }
        guard let profile else { return inputImage }
        return profile.apply(to: inputImage, distortion: distortionAmount, vignetting: vignettingAmount,
                             chromaticAberration: chromaticAberration, hideDistortedAreas: hideDistortedAreas)
    }
}
