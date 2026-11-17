//  WatermarkBase.swift — 水印's 底片 pass: a photograph's base marks laid into the source **before the engine** (PRD-8
//  §4.3, RFC-067 §4.2), so the film develops them: its grain, halation and colour, the paper's contrast. Two hazards
//  of such a pass are measured and avoided (below): a white that develops short of paper white, and a move that
//  re-decodes the frame. No engine change: the engine is handed a frame with the mark in its pixels.
//
//  **Where** (`EngineHost.decode`, the one seam every single photograph's source passes on its way to the engine — the
//  page's develop, a frame's own develop, the zoom's and the Light Table's full render, an export, a strip's card): after
//  the decode, its lens correction and the host's cut (`FrameDecoder`, `HostCut`), so the mark is never lens-warped and
//  its canvas is the picture the engine is handed; before `spk_open_device` copies it. A pair and a double carry none
//  (W5). `tools/watermark_base_selftest.swift` enumerates the paths.
//
//  **Values.** The source is scene-linear ProPhoto (D50), float RGBA. Each 8-bit premultiplied sRGB texel of the mark is
//  linearised (a 256 KB table), taken to ProPhoto (Bradford), scaled so its white is `white`, and composited with its
//  alpha and the placement's opacity: `out = white · mark + scene · (1 − α · opacity)`. Resampled once, to its size on
//  this decode (`WatermarkComposite.resolve` at the decode's own scale): a preview decode and a 45 MP one place the same
//  mark at the same place and relative size.
//
//  **The white (W7, measured; `tools/watermark_base_level.sh mac`, 2026-11-16, the engine at 936426ad).** At +2.5 EV a
//  white develops to about 0.82, not 1.0: that is the paper, not the level: on the default pair (Portra 400 / Portra Endura)
//  the brightest the print can be — a square at +8 EV — develops to **0.843** on the page's scale (middle grey 0.460), so
//  nothing laid in the scene can develop past it. +2.5 EV reaches 0.819 (97.1 % of paper white); +3.0 EV 0.834 (98.9 %).
//  The others at +2.5 / +3.0 EV, as a share of their own white: Supra Endura 97.0 / 98.8 % (white 0.860); Ektachrome 100
//  scanned 96.2 / 98.3 % (0.849); Tri-X on Multigrade 97.5 / 98.9 % (0.870); the Digital Intermediate 88.8 / 92.6 %
//  (0.981: the DI view's long shoulder lands its top code 1/16 stop under white) — 95.0 % at +3.5, 97.9 % at +4.5.
//  So **+3.0 EV** (`baseWhiteEV`), within 2 % of paper white on every printed and scanned pair where +2.5 missed the
//  slide by 4 %, and **+4.5 EV under the Digital Intermediate** (`baseWhiteEVUnderDI`), the least step within 3 % of
//  its white. Neither is a control (W7): each is the chain's, fixed.
//
//  **The white follows the frame's exposure, so the mark does not** (`exposureEV`): Film Exposure (`exposure_compensation_ev`,
//  which under the product's defaults moves the print as well as the negative — trap 30's cancellation is off) and,
//  where the meter is on, its reading. Measured: Film Exposure −2 … +2 with the scene at 2^−E develops the mark to the
//  same 0.834 at every step. The decode's own exposure (a RAW's) is before the mark and moves the photograph alone.
//  **The meter**: the engine's own meter sees the source it is handed, and a mark at +2.5 EV over a tenth of the frame
//  moved its reading by −0.21 EV (+3.5 EV: −0.30): the photograph went darker for a logo. So a frame with the meter on is
//  metered **before** the mark — by the engine's own meter, on a ≤ 1,024 px copy of the clean decode, as a pair's picture
//  is (`SpkEngine.meterOnQueue`) — and developed with the meter off at Film Exposure plus that reading (`EngineHost`'s
//  `params`): the photograph exposed as it would be without the mark, the mark laid by the same number.
//
//  **With the film's own layers.** The mark is in the source's pixels, so everything the engine does to the scene acts
//  on it as on the photograph under it: a 场景 mask layer (`LocalLayers`, the scene stage: `spk_set_scene_layers`, or
//  `SceneLayerHost` with the film off) that lifts or warms a region lifts or warms the part of a mark inside its mask —
//  the mark is light in the scene, and a layer is light on the scene. Its white is laid by the frame's exposure alone,
//  never by a layer's. A 成片 layer is Edit's pass on the finished picture and acts on the developed mark the same way;
//  a 成片 mark is over both. The order on the finished picture: 底片 marks under the film edge, the date and every
//  成片 mark (RFC-067 §4.3). The histogram counts a 底片 mark: it is in the developed picture (`Layer2Live`).
//
//  **Moving a 底片 mark does not re-decode the frame.** A move re-develops (the engine keeps
//  the source it was opened with, and the mark is in it: `Base.sourceWord` is in the job's source word) but does not
//  decode: the page's clean decode is kept while its develop carries base marks (`EngineHost.BaseSource`), and each job
//  lays its marks into its own copy of it. A strip's cards lay theirs into a copy of the strip's decode. A full-size job
//  (an export, the zoom's render) lays them into its own decode, in place: no second full-size source.

import CoreGraphics
import Foundation
import simd

extension WatermarkComposite {
    /// A develop's 底片 pass as the job carries it: the marks (`WatermarkRules.base`) and their word. Nil for an edit
    /// with none — so every other develop's stamp and source word are what they were.
    struct Base: Equatable, Sendable {
        var marks: Marks
        /// What the marks draw (each placement, each file's hash): the develop's stamp carries it.
        var key: String

        init?(_ edit: FrameEdit, isComposite: Bool, pixels: WatermarkPixels? = WatermarkComposite.library) {
            guard let m = Marks(WatermarkRules.base(edit, isComposite: isComposite)) else { return nil }
            marks = m
            key = m.key(pixels)
        }

        /// The word a develop's stamp carries (`DevelopStamp.of(base:)`): "" for an edit with none.
        static func word(_ edit: FrameEdit, isComposite: Bool, pixels: WatermarkPixels? = WatermarkComposite.library) -> String {
            Base(edit, isComposite: isComposite, pixels: pixels)?.key ?? ""
        }

        /// What the source the engine is handed is made of, beyond the decode: the marks and the numbers their white is
        /// laid by (`exposureEV`, `whiteEV`). Added to the job's source word (`EngineHost.Request.sourceKey`): a move,
        /// or an exposure under a mark, opens the frame again — from the kept decode, not the file.
        func sourceWord(wire: [String: ParamValue]) -> String {
            let film = wire["exposure_compensation_ev"]?.doubleValue ?? 0
            let meter = WatermarkComposite.meters(wire) ? "meter " + (wire["auto_exposure_method"]?.stringValue ?? "-") : "source"
            return "|wmb " + key + String(format: ";ev %.4f;white %.2f;", film, WatermarkComposite.whiteEV(wire: wire)) + meter
        }
    }

    // MARK: the white (W7; the measurements are in the header)

    /// The engine's middle grey on the scene's axis.
    static let middleGrey = 0.184
    /// Stops over the frame's middle grey a 底片 mark's white is laid at, for a print or a scan.
    static let baseWhiteEV = 3.0
    /// The same under the Digital Intermediate, whose view's shoulder is longer than any paper's.
    static let baseWhiteEVUnderDI = 4.5

    /// The level for this develop's chain: the Digital Intermediate's where the engine renders one (`digital_intermediate`
    /// on, not scanned), the paper's otherwise.
    static func whiteEV(wire: [String: ParamValue]) -> Double {
        let di = wire["digital_intermediate"]?.boolValue == true && wire["scan_film"]?.boolValue != true
        return di ? baseWhiteEVUnderDI : baseWhiteEV
    }

    /// The scene value of the mark's white for a develop that exposes the frame by `exposureEV` stops (the engine
    /// multiplies the scene by 2^E): developed, it lands `whiteEV` over middle grey whatever E is.
    static func baseWhite(exposureEV: Double, whiteEV: Double = baseWhiteEV) -> Double { middleGrey * pow(2, whiteEV - exposureEV) }

    /// The stops a develop of this wire exposes the scene by: Film Exposure, and the meter's reading of the frame where
    /// the meter is on (nil reading: none could be had, taken as 0).
    static func exposureEV(wire: [String: ParamValue], meter: Double?) -> Double {
        let film = wire["exposure_compensation_ev"]?.doubleValue ?? 0
        return film + (meters(wire) ? (meter ?? 0) : 0)
    }

    /// Whether a develop of this wire meters the frame.
    static func meters(_ wire: [String: ParamValue]) -> Bool { wire["auto_exposure"]?.boolValue == true }

    /// **The wire a base-marked develop is opened with** where its meter is on: the meter off, Film Exposure plus the
    /// reading of the frame before the mark — so the engine's meter, which would read the mark, does not move the
    /// photograph. As it is otherwise.
    static func metered(_ wire: [String: ParamValue], reading: Double?) -> [String: ParamValue] {
        guard meters(wire), let reading, reading.isFinite else { return wire }
        var out = wire
        out["auto_exposure"] = .bool(false)
        out["exposure_compensation_ev"] = .double(((wire["exposure_compensation_ev"]?.doubleValue ?? 0) + reading).clamped(to: -8...8))
        return out
    }

    /// The wire the meter reads the clean frame with: the job's, its own exposure, film edge and date off, no tier size.
    static func meterWire(_ wire: [String: ParamValue]) -> [String: ParamValue] {
        var alone = wire
        alone["exposure_compensation_ev"] = .double(0)
        alone["overscan_active"] = .bool(false)
        alone["date_imprint_active"] = .bool(false)
        alone["preview_long_edge"] = nil
        return alone
    }

    /// The long edge of the copy of the frame the meter reads (as a pair's picture is metered).
    static let meterSide = 1024

    // MARK: the canvas

    /// The cut the engine makes of the frame it is handed, as its wire says it; none (identity) where the host cut it.
    static func engineCut(wire: [String: ParamValue]) -> Geometry {
        var g = Geometry.default
        if let x = wire["geometry_crop_x"]?.doubleValue, let y = wire["geometry_crop_y"]?.doubleValue,
           let w = wire["geometry_crop_w"]?.doubleValue, let h = wire["geometry_crop_h"]?.doubleValue {
            g.crop = CropRect(x: x, y: y, width: w, height: h)
        }
        g.angle = wire["geometry_rotation_deg"]?.doubleValue ?? 0
        g.quarterTurns = Int((wire["geometry_quarter_turns"]?.doubleValue ?? 0).rounded())
        g.flipH = wire["geometry_flip_h"]?.boolValue ?? false
        g.flipV = wire["geometry_flip_v"]?.boolValue ?? false
        return g
    }

    /// **The 底片 canvas on the frame the engine is handed** (`decoded` pixels): the picture the engine makes of it — its
    /// own cut (`engineCut`: none where the host cut it, as under a film edge or in an export) — turned forward by the
    /// host's quarter turns after (`EngineHost.Request.turnsAfter`, a film turned half round). So the canvas is the
    /// finished picture without its film edge, Format's crop made; the map takes it back onto the decode.
    static func basePlacing(decoded: CGSize, engineCut: Geometry, turnsAfter: Int) -> Placing {
        let picture = engineCut.isIdentity ? decoded : engineCut.outputSize(for: decoded)
        let toDecode = engineCut.isIdentity ? CGAffineTransform.identity : engineCut.outputToSourceTransform(imageSize: decoded)
        let k = ((turnsAfter % 4) + 4) % 4
        guard k != 0 else { return Placing(canvas: picture, toPicture: toDecode) }
        // `Geometry`'s quarter turns are clockwise, as the host's are: its map from the turned picture back.
        var turn = Geometry.default
        turn.quarterTurns = k
        return Placing(canvas: turn.outputSize(for: picture),
                       toPicture: turn.outputToSourceTransform(imageSize: picture).concatenating(toDecode))
    }

    // MARK: the colour

    /// Linear sRGB (D65) → linear ProPhoto (D50), Bradford-adapted (Lindbloom's matrices): sRGB white is ProPhoto white.
    static let sRGBToProPhoto: simd_double3x3 = {
        let srgbToXYZ = simd_double3x3(rows: [SIMD3(0.4360747, 0.3850649, 0.1430804), SIMD3(0.2225045, 0.7168786, 0.0606169),
                                              SIMD3(0.0139322, 0.0971045, 0.7141733)])
        let proToXYZ = simd_double3x3(rows: [SIMD3(0.7976749, 0.1351917, 0.0313534), SIMD3(0.2880402, 0.7118741, 0.0000857),
                                             SIMD3(0.0, 0.0, 0.8252100)])
        return proToXYZ.inverse * srgbToXYZ
    }()

    /// An 8-bit premultiplied sRGB texel's colour, linear and premultiplied, by (alpha, channel): α · lin(c / α). 256 KB.
    static let linearPremultiplied: [Float] = {
        var t = [Float](repeating: 0, count: 65536)
        for a in 1..<256 {
            for c in 0..<256 {
                let v = min(1, Double(c) / Double(a))
                let lin = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                t[a << 8 | c] = Float(Double(a) / 255 * lin)
            }
        }
        return t
    }()

    /// A mark's 8-bit premultiplied sRGB pixels as the library made them (`WatermarkStore.bitmap`), read where they lie:
    /// each tap taken to linear by the table, then interpolated. Another layout is drawn into this one once.
    private struct SceneTexels {
        let data: CFData
        let px: UnsafePointer<UInt8>
        let w: Int, h: Int, row: Int

        init?(_ mark: CGImage) {
            var image = mark
            let alpha = CGImageAlphaInfo(rawValue: mark.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            let order = mark.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
            let srgb = mark.colorSpace?.name == CGColorSpace.sRGB
            if !(mark.bitsPerComponent == 8 && mark.bitsPerPixel == 32 && alpha == .premultipliedLast && srgb
                 && (order == 0 || order == CGBitmapInfo.byteOrder32Big.rawValue)) {
                guard let ctx = CGContext(data: nil, width: mark.width, height: mark.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return nil }
                ctx.setBlendMode(.copy)
                ctx.draw(mark, in: CGRect(x: 0, y: 0, width: mark.width, height: mark.height))
                guard let made = ctx.makeImage() else { return nil }
                image = made
            }
            guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
            self.data = data
            px = bytes
            w = image.width; h = image.height; row = image.bytesPerRow
        }

        /// Bilinear at (`x`, `y`) in the mark's pixels (a pixel's centre at +0.5), clear outside: linear sRGB,
        /// premultiplied, and alpha, 0…1.
        @inline(__always) func sample(_ x: Double, _ y: Double, _ lut: UnsafePointer<Float>) -> SIMD4<Float> {
            let fx = x - 0.5, fy = y - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            guard x0 >= -1, y0 >= -1, x0 < w, y0 < h else { return .zero }
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            @inline(__always) func at(_ i: Int, _ j: Int) -> SIMD4<Float> {
                guard i >= 0, j >= 0, i < w, j < h else { return .zero }
                let p = px + j * row + i * 4
                let a = Int(p[3])
                guard a > 0 else { return .zero }
                let k = a << 8
                return SIMD4(lut[k | Int(p[0])], lut[k | Int(p[1])], lut[k | Int(p[2])], Float(a) / 255)
            }
            let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            return top * (1 - ty) + bottom * ty
        }
    }

    // MARK: the pass

    /// **The 底片 pass**: each mark in order over the scene — float, `channels` (3 or 4) a pixel, `width` a row, linear
    /// ProPhoto — where it lies: each scene pixel's centre taken back onto the mark, the mark sampled there (linear,
    /// premultiplied), taken into ProPhoto and scaled so its white is `white`, then `out = white · mark + scene · (1 −
    /// α · opacity)`. A fourth channel is left as it is. Only the pixels under a mark's box are touched.
    static func blendScene(_ drawn: [Drawn], into scene: UnsafeMutablePointer<Float>, width: Int, height: Int, channels: Int,
                           white: Double) {
        guard width > 0, height > 0, channels >= 3, !drawn.isEmpty else { return }
        let size = CGSize(width: width, height: height)
        let m = sRGBToProPhoto
        let k = Float(white)
        // The matrix's columns, scaled by the white: ProPhoto = r · c0 + g · c1 + b · c2.
        let c0 = SIMD3<Float>(Float(m[0, 0]), Float(m[0, 1]), Float(m[0, 2])) * k
        let c1 = SIMD3<Float>(Float(m[1, 0]), Float(m[1, 1]), Float(m[1, 2])) * k
        let c2 = SIMD3<Float>(Float(m[2, 0]), Float(m[2, 1]), Float(m[2, 2])) * k
        linearPremultiplied.withUnsafeBufferPointer { table in
            let lut = table.baseAddress!
            for d in drawn {
                guard let box = d.box(in: size), let tex = SceneTexels(d.image) else { continue }
                withExtendedLifetime(tex.data) {
                    let inv = d.toPicture.inverted()
                    let op = Float(d.opacity)
                    let x0 = Int(box.minX), x1 = Int(box.maxX), y0 = Int(box.minY), y1 = Int(box.maxY)
                    for y in y0..<y1 {
                        let cy = Double(y) + 0.5, cx = Double(x0) + 0.5
                        var mx = Double(inv.a) * cx + Double(inv.c) * cy + Double(inv.tx)
                        var my = Double(inv.b) * cx + Double(inv.d) * cy + Double(inv.ty)
                        let row = scene + y * width * channels
                        for x in x0..<x1 {
                            let s = tex.sample(mx, my, lut) * op
                            mx += Double(inv.a); my += Double(inv.b)
                            guard s.w > 0 else { continue }
                            let keep = 1 - s.w
                            let p = row + x * channels
                            let pro = c0 * s.x + c1 * s.y + c2 * s.z
                            p[0] = pro.x + p[0] * keep
                            p[1] = pro.y + p[1] * keep
                            p[2] = pro.z + p[2] * keep
                        }
                    }
                }
            }
        }
    }

    /// **A frame's 底片 marks into its decode**, in place: `scene` is the decode the engine is about to be handed
    /// (`width` × `height`, `channels` floats a pixel), `placing` the 底片 canvas on it (`basePlacing`), `white` the
    /// scene value of the mark's white (`baseWhite`). Returns how many marks were laid (a deleted one is not).
    @discardableResult
    static func base(_ marks: Marks, into scene: UnsafeMutablePointer<Float>, width: Int, height: Int, channels: Int,
                     placing: Placing, white: Double, pixels: WatermarkPixels? = library) -> Int {
        let drawn = resolve(marks, on: placing, pixels: pixels)
        blendScene(drawn, into: scene, width: width, height: height, channels: channels, white: white)
        return drawn.count
    }

    // MARK: what the pass holds (the scheduler's price)

    /// **What a job's 底片 pass holds beside the source**, for `edit`'s base marks on a picture of `canvas` pixels, and
    /// whether it lays them into a copy of a kept decode (`copies`: the page's develop, a card; `source` is that
    /// decode's size) — bytes, for the scheduler (`RenderJob.watermarkBytes`).
    ///
    /// - Each mark's pixels at the size drawn, 4 B a pixel (the library keeps them), and read where they lie (4 more
    ///   where the data provider copies them); while the first such size is made, the PNG decoded whole and ImageIO's
    ///   own (3 × 4 B a pixel of the largest PNG).
    /// - The 256 KB table; where the meter is on, the 1,024 px copy it reads (16 MB at most).
    /// - `copies`: the job's own copy of the kept decode, 16 B a pixel of it. Otherwise none: the decode is the job's
    ///   own and is written in place, **not a second source** (measured: the commit that made this).
    ///
    /// Zero for an edit with no base mark the library has.
    static func held(_ edit: FrameEdit, isComposite: Bool, canvas: PixelSize, copies source: PixelSize? = nil,
                     pixels: WatermarkPixels? = library) -> UInt64 {
        held(WatermarkRules.base(edit, isComposite: isComposite), meters: edit.appliesFilm && edit.params.autoExposure,
             canvas: canvas, copies: source, pixels: pixels)
    }

    /// The same for a job's own marks (`Base.marks`) and whether its develop meters.
    static func held(_ placements: [WatermarkPlacement], meters: Bool, canvas: PixelSize, copies source: PixelSize? = nil,
                     pixels: WatermarkPixels? = library) -> UInt64 {
        guard let pixels, canvas.width > 0, canvas.height > 0 else { return 0 }
        let size = CGSize(width: canvas.width, height: canvas.height)
        var bytes = 0.0, largestPNG = 0.0
        for p in placements where p.on && p.opacity > 0 {
            guard let info = pixels.info(p.mark), info.w > 0, info.h > 0 else { continue }
            let f = WatermarkGeometry.frame(of: p, canvas: size, aspect: Double(info.w) / Double(info.h))
            bytes += Double(max(1, f.size.width.rounded()) * max(1, f.size.height.rounded())) * 8
            largestPNG = max(largestPNG, Double(info.w) * Double(info.h))
        }
        guard bytes > 0 else { return 0 }
        bytes += 3 * 4 * largestPNG + Double(linearPremultiplied.count * 4)
        if meters { bytes += Double(meterSide * meterSide * 16) }
        if let source { bytes += Double(source.width) * Double(source.height) * 16 }
        return UInt64(bytes.rounded(.up))
    }
}
