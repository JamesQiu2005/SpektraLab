// layer2_selftest.swift -- Layer 2, Edit's Light, Curve and Colour: the model, its curves and its kernels.
//
//     tools/selftest.sh                # the checks
//     tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
// Compiled by tools/selftest.sh with Model/Adjustments.swift, Model/CurveMath.swift, the edit's model and
// Engine/Layer2Kernel.swift + Layer2Renderer.swift, and run on this Mac. **The kernels run on this Mac's
// GPU**, compiled from the app's own string with safe math; nothing here measures a host.
//
//   - the maths against the desktop's numbers: its CurveMath tests and its renderer's Layer 2 tests, ported
//     (SpektrafilmTests/CurveMathTests.swift, RendererTests.swift; desktop df355fa), the uniform block's
//     layout, and every step of the pass held to a reference written here in Swift on a card of colours;
//   - the parametric curve: neutral is the identity, every setting is monotone and inside the square;
//   - neutral is the identity to the bit, and a neutral layer is never run;
//   - the pass at a preview's size and at an export's size, on the same picture, agree;
//   - an edit of schema 3 still loads, with Layer 2 neutral and every other field byte for byte;
//   - Copy Settings' Light, Curve and Colour carry their own fields and nothing else;
//   - the log's names for Edit's controls, and the time a visit spends on each surface;
//   - Adjust (2026-10-19): vibrance, HSL and the channel mixer against a Swift reference and at rest to the bit;
//     a record from before them (52f3eec) read and written back byte for byte with its key; every field a
//     tile's; the colour pad's dots and snapping; the curve's touch; the band's navigation.
import CoreGraphics
import Foundation
import Metal
import simd
import SwiftUI

extension Color { init(hexString: String) { self = .gray } }

/// One broken rule at a time, for `--self-test`: each must make a check fail.
struct Mutation: Equatable {
    var name: String
    /// What it does to the kernels' source (nil: nothing).
    var kernel: ((String) -> String)? = nil
    static func == (a: Mutation, b: Mutation) -> Bool { a.name == b.name }
    static let none = Mutation(name: "none")
    static let all: [Mutation] = [
        Mutation(name: "pivot on 0.5, not mid-grey") { $0.replacingOccurrences(of: "c = (c - u.midGrey) * k + u.midGrey;", with: "c = (c - 0.5f) * k + 0.5f;") },
        Mutation(name: "saturation run at 1") { $0.replacingOccurrences(of: "if (u.saturation != 1.0f) {", with: "if (true) {") },
        Mutation(name: "curves before the tone") { s in
            s.replacingOccurrences(of: "if (u.enabled == 0u) return c;\n    c = l2Tone(c, u);", with: "if (u.enabled == 0u) return c;")
             .replacingOccurrences(of: "c = float3(l2Curve(curves, c.r, 2u), l2Curve(curves, c.g, 3u), l2Curve(curves, c.b, 4u));\n    }",
                                   with: "c = float3(l2Curve(curves, c.r, 2u), l2Curve(curves, c.g, 3u), l2Curve(curves, c.b, 4u));\n    }\n    c = l2Tone(c, u);")
        },
        Mutation(name: "a curve read half an entry off") { $0.replacingOccurrences(of: "float v = clamp(x, 0.0f, 1.0f) * 255.0f;", with: "float v = clamp(x, 0.0f, 1.0f) * 256.0f - 0.5f; v = max(v, 0.0f);") },
        Mutation(name: "the vignette in pixels") { $0.replacingOccurrences(of: "float2 uv = (float2(gid) + 0.5f) / float2(size.width, size.height);\n    c = l2Apply", with: "float2 uv = (float2(gid) + 0.5f) / 1024.0f;\n    c = l2Apply") },
        Mutation(name: "clamped on the way out") { $0.replacingOccurrences(of: "dst[p] = float4(l2Apply(c, uv, u, curves), 1.0f);", with: "dst[p] = float4(saturate(l2Apply(c, uv, u, curves)), 1.0f);") },
        Mutation(name: "the histogram before the pass") { $0.replacingOccurrences(of: "if (size.applies != 0u) {", with: "if (false) {") },
        Mutation(name: "exposure in encoded values") { $0.replacingOccurrences(of: "c = pow(max(c, 0.0f), 2.2f) * u.exposureGain;\n        c = pow(c, 1.0f / 2.2f);", with: "c = c * u.exposureGain;") },
        Mutation(name: "HSL does not give the luma back") { $0.replacingOccurrences(of: "float s = -2.0f * 0.2126f * p.x - (0.7152f - 0.0722f) * q;", with: "float s = -p.x;") },
        Mutation(name: "vibrance as plain saturation") { $0.replacingOccurrences(of: "max(1.0f + v * (1.0f - sat), 0.0f)", with: "max(1.0f + v, 0.0f)") },
        Mutation(name: "HSL run at rest") { $0.replacingOccurrences(of: "if (u.hslActive != 0u) {", with: "if (true) {") },
        Mutation(name: "the colour balance splits on the luma before HSL") { $0.replacingOccurrences(of: "if (moved) l = l2Luma(c);", with: "") },
        Mutation(name: "the channel mixer's rows read as columns") { $0.replacingOccurrences(of: "c = float3(dot(u.mixR, c), dot(u.mixG, c), dot(u.mixB, c));", with: "c = u.mixR * c.r + u.mixG * c.g + u.mixB * c.b;") },
    ]
}

final class Checks {
    let mutation: Mutation
    private(set) var passed = 0
    private(set) var failed: [String] = []
    init(_ mutation: Mutation) { self.mutation = mutation }
    func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if mutation == .none { print("  FAIL  \(what)") } }
    }
    func near(_ a: Double, _ b: Double, _ tolerance: Double, _ what: String) {
        expect(abs(a - b) <= tolerance, "\(what): \(a) against \(b)")
    }
}

// MARK: - the pass, written again in Swift: the reference the kernels are held to

enum Reference {
    static func luma(_ c: SIMD3<Float>) -> Float { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
    static func position(_ l: Float, _ midGrey: Float) -> Float {
        var m = min(max(midGrey, 0), 1)
        if m <= 0 || m >= 1 { m = 0.5 }
        return l <= m ? 0.5 * l / m : 0.5 + 0.5 * (l - m) / (1 - m)
    }
    static func pw(_ c: SIMD3<Float>, _ p: Float) -> SIMD3<Float> { SIMD3(powf(c.x, p), powf(c.y, p), powf(c.z, p)) }
    static func vibrance(_ c: SIMD3<Float>, _ v: Float) -> SIMD3<Float> {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        let sat: Float = mx > 1e-4 ? min(max((mx - mn) / mx, 0), 1) : 0
        let l = luma(c)
        return l + (c - l) * max(1 + v * (1 - sat), 0)
    }
    static func hsl(_ c: SIMD3<Float>, _ u: Layer2Uniforms) -> SIMD3<Float> {
        let l = luma(c)
        let d = c - l
        let p = SIMD2<Float>(d.x - 0.5 * (d.y + d.z), 0.8660254 * (d.y - d.z))
        let chroma = simd_length(p)
        if chroma < 1e-6 { return c }
        var h = atan2f(p.y, p.x) * 57.29577951
        if h < 0 { h += 360 }
        let centres: [Float] = [0, 30, 60, 120, 180, 240, 270, 300, 360]
        let hue = [u.hslHue0.x, u.hslHue0.y, u.hslHue0.z, u.hslHue0.w, u.hslHue1.x, u.hslHue1.y, u.hslHue1.z, u.hslHue1.w]
        let sat = [u.hslSat0.x, u.hslSat0.y, u.hslSat0.z, u.hslSat0.w, u.hslSat1.x, u.hslSat1.y, u.hslSat1.z, u.hslSat1.w]
        let lum = [u.hslLum0.x, u.hslLum0.y, u.hslLum0.z, u.hslLum0.w, u.hslLum1.x, u.hslLum1.y, u.hslLum1.z, u.hslLum1.w]
        var i = 0
        while i < 7 && h >= centres[i + 1] { i += 1 }
        let j = (i + 1) % 8
        var t = min(max((h - centres[i]) / (centres[i + 1] - centres[i]), 0), 1)
        t = t * t * (3 - 2 * t)
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        let turn = mix(hue[i], hue[j]), scale = max(1 + mix(sat[i], sat[j]), 0), lift = mix(lum[i], lum[j])
        let q = SIMD2<Float>(p.x * cosf(turn) - p.y * sinf(turn), p.x * sinf(turn) + p.y * cosf(turn)) * scale
        let g = q.y / 0.8660254
        let s = -2 * 0.2126 * q.x - (0.7152 - 0.0722) * g
        let back = l + SIMD3<Float>(q.x + 0.5 * s, 0.5 * (s + g), 0.5 * (s - g))
        let e = min(max(chroma / 0.2, 0), 1)
        return back * (1 + 0.5 * lift * (e * e * (3 - 2 * e)))
    }
    static func tone(_ c0: SIMD3<Float>, _ u: Layer2Uniforms) -> SIMD3<Float> {
        var c = c0 * u.wbGain
        if u.exposureGain != 1 { c = pw(pw(simd_max(c, .zero), 2.2) * u.exposureGain, 1 / 2.2) }
        if u.contrast != 0 { let k = 1 + u.contrast * 1.2; c = (c - u.midGrey) * k + u.midGrey }
        if u.brightness != 0 { c = pw(simd_max(c, .zero), 1 / (1 + u.brightness * 0.8)) }
        var l = position(luma(c), u.midGrey)
        if u.shadows != 0 { var w = 1 - l; w = w * w; c += u.shadows * 0.25 * w * (1 - c) }
        if u.highlights != 0 { let w = l * l; c += u.highlights * 0.25 * w * (u.highlights > 0 ? (1 - c) : c) }
        c = (c - u.blackPoint) / max(1 - u.blackPoint - u.whitePoint, 0.05)
        l = luma(c)
        if u.saturation != 1 { c = l + (c - l) * u.saturation }
        var moved = false
        if u.vibrance != 0 { c = vibrance(c, u.vibrance); moved = true }
        if u.hslActive != 0 { c = hsl(c, u); moved = true }
        if u.mixerActive != 0 { c = SIMD3(simd_dot(u.mixR, c), simd_dot(u.mixG, c), simd_dot(u.mixB, c)); moved = true }
        if moved { l = luma(c) }
        let ls = min(max(position(l, u.midGrey), 0), 1)
        let wS = (1 - ls) * (1 - ls), wH = ls * ls, wM = max(1 - wS - wH, 0)
        c += u.cbMaster + u.cbShadows * wS + u.cbMidtones * wM + u.cbHighlights * wH
        c *= 1 + u.cbLum.x + u.cbLum.y * wS + u.cbLum.z * wM + u.cbLum.w * wH
        return c
    }
    static func curve(_ t: [Float], _ x: Float, _ row: Int) -> Float {
        let v = min(max(x, 0), 1) * 255
        let i = min(Int(v), 254)
        let f = v - Float(i)
        return t[row * 256 + i] + (t[row * 256 + i + 1] - t[row * 256 + i]) * f
    }
    static func apply(_ c0: SIMD3<Float>, uv: SIMD2<Float>, _ a: Adjustments) -> SIMD3<Float> {
        let u = a.uniforms()
        guard u.enabled != 0 else { return c0 }
        var c = tone(c0, u)
        if u.curvesActive != 0 {
            let t = a.curves.tables()
            c = simd_clamp(c, .zero, .one)
            let ly = luma(c), ly2 = curve(t, ly, 1)
            c *= ly > 1e-4 ? ly2 / ly : 1
            c = simd_clamp(c, .zero, .one)
            c = SIMD3(curve(t, c.x, 0), curve(t, c.y, 0), curve(t, c.z, 0))
            c = SIMD3(curve(t, c.x, 2), curve(t, c.y, 3), curve(t, c.z, 4))
        }
        if u.vignetteAmount != 0 {
            let p: SIMD2<Float> = (uv - 0.5) * 2
            let d: Float = simd_length(p)
            let e0: Float = u.vignetteMidpoint * 1.2
            let t: Float = min(max((d - e0) / (1.5 - e0), 0), 1)
            let fall: Float = t * t * (3 - 2 * t)
            let k: Float = 1 + u.vignetteAmount * fall * 0.9
            c *= k
        }
        return c
    }
}

// MARK: - test pictures

/// A card of colours: every combination of eleven levels per channel, 1,331 pixels, 37 x 36.
func card() -> (pixels: [UInt16], width: Int, height: Int) {
    var px: [UInt16] = []
    for r in 0...10 { for g in 0...10 { for b in 0...10 {
        px += [UInt16(r * 6553 + (r == 10 ? 5 : 0)), UInt16(g * 6553 + (g == 10 ? 5 : 0)), UInt16(b * 6553 + (b == 10 ? 5 : 0)), 65535]
    } } }
    let w = 37, h = 36
    while px.count < w * h * 4 { px += [32768, 16384, 49152, 65535] }
    return (px, w, h)
}

/// A smooth picture, the same at any size: what a preview and an export are of one frame.
func smooth(width: Int, height: Int) -> [UInt16] {
    var px = [UInt16](repeating: 65535, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
        let r = 0.5 + 0.45 * sin(u * 3.1 + v * 1.3), g = 0.45 + 0.4 * cos(u * 2.2 - v * 2.7), b = 0.15 + 0.8 * u * v
        let i = (y * width + x) * 4
        px[i] = UInt16((r * 65535).rounded()); px[i + 1] = UInt16((g * 65535).rounded()); px[i + 2] = UInt16((b * 65535).rounded())
    } }
    return px
}

/// A layer that moves everything: every control of all three tools.
func everything() -> Adjustments {
    var a = Adjustments()
    a.exposure = 0.4; a.contrast = 18; a.brightness = -7; a.highlights = -40; a.shadows = 30
    a.blacks = -6; a.whites = 3; a.temperature = -14; a.tint = 9; a.saturation = 22
    a.colorBalance.shadows = ColorZone(hue: 200, saturation: 0.3, luminance: 0.1)
    a.colorBalance.highlights = ColorZone(hue: 40, saturation: 0.2, luminance: -0.05)
    a.colorBalance.master = ColorZone(hue: 120, saturation: 0.05, luminance: 0)
    a.curves.rgb.insert(CGPoint(x: 0.25, y: 0.2)); a.curves.rgb.insert(CGPoint(x: 0.75, y: 0.82))
    a.curves.luma.insert(CGPoint(x: 0.5, y: 0.55))
    a.curves.blue.insert(CGPoint(x: 0.5, y: 0.45))
    a.curves.parametric.rgb.shadows = 25; a.curves.parametric.rgb.highlights = -15
    a.vignette = Vignette(amount: -35, midpoint: 40)
    a.vibrance = 18
    a.hsl.blue = HSLBand(hue: -20, saturation: 30, luminance: -40); a.hsl.orange = HSLBand(hue: 10, saturation: -15, luminance: 25)
    a.channelMixer.red = MixerRow(red: -10, green: 8, blue: 0); a.channelMixer.blue = MixerRow(red: 0, green: 5, blue: 12)
    return a
}

// MARK: - the checks

func run(_ m: Mutation) -> Checks {
    let c = Checks(m)
    model(c)
    curves(c)
    parametric(c)
    codable(c)
    clipboard(c)
    logNames(c)
    pageNavigation(c)
    oldRecords(c)
    adjustTools(c)
    pad(c)
    gpu(c)
    gpuNewSteps(c)
    return c
}

/// An edit's Layer 2 as the build before vibrance, HSL and the channel mixer wrote it: printed by
/// Model/Adjustments.swift and CurveMath.swift at 52f3eec (a program built from those two files,
/// sorted keys as LibraryPersistence writes), with its `key` as that build named its edited copies.
let before20261019 = #"{"blackPoint":4,"brightness":0,"colorBalance":{"highlights":{"hue":0,"luminance":0,"saturation":0},"master":{"hue":40,"luminance":0,"saturation":0.05},"midtones":{"hue":0,"luminance":0,"saturation":0},"shadows":{"hue":210,"luminance":0.1,"saturation":0.3}},"contrast":12,"curves":{"blue":{"points":[[0,0],[1,1]]},"green":{"points":[[0,0],[1,1]]},"luma":{"points":[[0,0],[1,1]]},"parametric":{"blue":{"darks":0,"highlightSplit":0.75,"highlights":0,"lights":0,"midtoneSplit":0.5,"shadowSplit":0.25,"shadows":0},"green":{"darks":0,"highlightSplit":0.75,"highlights":0,"lights":0,"midtoneSplit":0.5,"shadowSplit":0.25,"shadows":0},"luma":{"darks":0,"highlightSplit":0.75,"highlights":0,"lights":0,"midtoneSplit":0.5,"shadowSplit":0.25,"shadows":0},"red":{"darks":0,"highlightSplit":0.75,"highlights":0,"lights":0,"midtoneSplit":0.5,"shadowSplit":0.25,"shadows":0},"rgb":{"darks":15,"highlightSplit":0.75,"highlights":0,"lights":0,"midtoneSplit":0.5,"shadowSplit":0.25,"shadows":0}},"red":{"points":[[0,0],[1,1]]},"rgb":{"points":[[0,0],[0.25,0.2],[1,1]]}},"enabled":true,"exposure":0.25,"highlights":-30,"saturation":10,"shadows":20,"temperature":8,"tint":-3,"vignette":{"amount":-20,"midpoint":40},"whitePoint":0}"#
let before20261019Key = "369e4d4aff215fdf"

func oldRecords(_ c: Checks) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let old = try? JSONDecoder().decode(Adjustments.self, from: Data(before20261019.utf8)) else {
        c.expect(false, "an edit from before 2026-10-19 loads"); return
    }
    c.expect(old.vibrance == 0 && old.hsl.isNeutral && old.channelMixer.isNeutral,
             "an edit from before 2026-10-19 loads, with vibrance, HSL and the channel mixer at rest")
    c.expect(old.exposure == 0.25 && old.colorBalance.master.hue == 40 && old.colorBalance.shadows.saturation == 0.3
             && old.curves.parametric.rgb.darks == 15 && old.vignette.midpoint == 40, "and with everything it held")
    let again = (try? encoder.encode(old)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    c.expect(again == before20261019, "written again, it is the same bytes: no key of the new tools is added")
    c.expect(old.key == before20261019Key, "and its key is the one its edited copies were named by (\(old.key))")
    // Its picture: the uniforms of the old steps are as they were, the new ones off.
    let u = old.uniforms()
    c.expect(u.vibrance == 0 && u.hslActive == 0 && u.mixerActive == 0, "an old edit runs none of the new steps")
    // A field that is moved is written, and read back.
    var moved = old
    moved.vibrance = 12; moved.hsl.aqua.luminance = -20; moved.channelMixer.green.blue = 7
    let text = (try? encoder.encode(moved)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    c.expect(text.contains("\"vibrance\":12") && text.contains("\"hsl\":{") && text.contains("\"channelMixer\":{"),
             "a moved new tool is written")
    let back = (try? encoder.encode(moved)).flatMap { try? JSONDecoder().decode(Adjustments.self, from: $0) }
    c.expect(back == moved, "and read back as it was")
    // A record with only part of a new group (a later build's, say) reads the rest at rest.
    let partial = #"{"hsl":{"blue":{"hue":-12}},"channelMixer":{"red":{"green":5}}}"#
    let p = try? JSONDecoder().decode(Adjustments.self, from: Data(partial.utf8))
    c.expect(p?.hsl.blue.hue == -12 && p?.hsl.blue.saturation == 0 && p?.hsl.red.isNeutral == true
             && p?.channelMixer.red.green == 5 && p?.channelMixer.red.red == 0 && p?.exposure == 0,
             "a record with part of a group reads the rest at rest")
    // The whole edit: an old FrameEdit's adjustments, through FrameEdit.
    if var e = try? JSONDecoder().decode(FrameEdit.self, from: Data(schema3.utf8)) {
        e.adjustments = old
        let eBack = (try? encoder.encode(e)).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
        c.expect(eBack?.adjustments == old, "an edit that holds an old layer round-trips unchanged")
    }
}

func adjustTools(_ c: Checks) {
    c.expect(AdjustTool.allCases.map(\.rawValue) == ["brightness", "contrast", "tone", "hsl", "channel", "wheels",
                                                      "vibrance", "saturation", "temperature", "curve", "vignette"],
             "the strip is Litti's list without Fade, then Vignette")
    // Every field of the layer is some tile's: all the 🗑s together are the whole layer.
    var a = everything()
    for tool in AdjustTool.allCases { tool.reset(&a) }
    c.expect(a == Adjustments(), "every setting of the layer belongs to a tile (\(a == Adjustments() ? "" : "something is left"))")
    // A tile's 🗑 is its own, and the group it belongs to says so.
    for tool in AdjustTool.allCases {
        var b = everything()
        tool.reset(&b)
        c.expect(tool.isNeutral(in: b) && tool.isAtRest(in: b), "\(tool.rawValue)'s 🗑 leaves it at rest")
        let others = AdjustTool.allCases.filter { $0 != tool }
        let kept = others.allSatisfy { other in
            var x = b, y = everything()
            other.reset(&x); other.reset(&y)
            tool.reset(&y)
            return x == y
        }
        c.expect(kept, "\(tool.rawValue)'s 🗑 leaves every other tile as it was")
        c.expect(!tool.isNeutral(in: everything()), "\(tool.rawValue) is moved in a layer that moves everything")
        var only = Adjustments()
        only = everything()
        for o in others { o.reset(&only) }
        c.expect(only.changedTools == [tool.group], "\(tool.rawValue) alone makes \(tool.group.rawValue) edited, and nothing else")
    }
    var mid = Adjustments(); mid.vignette.midpoint = 30
    c.expect(AdjustTool.vignette.isNeutral(in: mid) && !AdjustTool.vignette.isAtRest(in: mid),
             "a midpoint alone draws nothing, and is still Vignette's to put back")
    c.expect(AdjustTool.brightness.controls == [.brightness, .exposure], "Exposure is under Brightness")
    c.expect(AdjustTool.tone.controls == [.highlights, .shadows, .whites, .blacks], "Tone is Litti's highlights and shadows, and the two points")
    // Copy Settings' Colour carries the new tools, and Light and Curve do not.
    var source = FrameEdit.default
    source.adjustments = everything()
    let colour = SettingsClip(groups: [.colour], settings: source, sourceName: "x").applied(to: FrameEdit.default, picture: PixelSize(width: 3, height: 2))
    c.expect(colour.adjustments.hsl == source.adjustments.hsl && colour.adjustments.channelMixer == source.adjustments.channelMixer
             && colour.adjustments.vibrance == 18, "Colour carries vibrance, HSL and the channel mixer")
    let light = SettingsClip(groups: [.light, .curve], settings: source, sourceName: "x").applied(to: FrameEdit.default, picture: PixelSize(width: 3, height: 2))
    c.expect(light.adjustments.hsl.isNeutral && light.adjustments.vibrance == 0, "and Light and Curve do not")
    c.expect(ClipboardGroup.colour.summary(of: source).contains("HSL") && ClipboardGroup.colour.summary(of: source).contains("Vibrance +18"),
             "Colour's line names them: \(ClipboardGroup.colour.summary(of: source))")
    // The log.
    let want: [(String, String)] = [("vibrance", "edit.colour.vibrance"), ("hsl.blue.luminance", "edit.colour.hsl.blue.luminance"),
                                    ("hsl", "edit.colour.hsl"), ("channelMixer.red.green", "edit.colour.channel.red.green")]
    for (path, name) in want { c.expect(Adjustments.logName(path) == name, "\(path) is logged as \(name), not \(Adjustments.logName(path))") }
}

func pad(_ c: Checks) {
    c.expect(ColourPad.zone(x: 0, y: 0).isNeutral, "the pad's centre is no change")
    let right = ColourPad.zone(x: 5, y: 0), up = ColourPad.zone(x: 0, y: 5), corner = ColourPad.zone(x: -5, y: -5)
    c.expect(right.hue == 0 && right.saturation == 1, "the right edge is red at full strength")
    c.expect(up.hue == 90 && up.saturation == 1, "straight up is 90°, between yellow and green")
    c.expect(corner.hue == 225 && corner.saturation == 1, "the lower left corner is 225°, towards blue, and full: a square's ring")
    let steps = (1...5).map { ColourPad.zone(x: $0, y: 0).saturation }
    c.expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 } && abs(steps[0] - 0.04) < 1e-12,
             "each ring out is stronger, the first a fine step (\(steps))")
    c.expect(ColourPad.zone(x: 3, y: 2, keeping: 0.4).luminance == 0.4, "a dot keeps the zone's luminance")
    // Every dot comes back to itself through the knob's position, and every position snaps to a dot.
    var roundTrip = true
    for x in -5...5 { for y in -5...5 {
        let p = ColourPad.position(of: ColourPad.zone(x: x, y: y))
        let s = ColourPad.snap(p.x, p.y)
        if s.x != x || s.y != y || abs(p.x - Double(x)) > 1e-9 || abs(p.y - Double(y)) > 1e-9 { roundTrip = false }
    } }
    c.expect(roundTrip, "every one of the 121 dots is where its zone puts the knob")
    let wheel = ColourPad.position(of: ColorZone(hue: 200, saturation: 0.3, luminance: 0))
    c.expect(abs(wheel.x) <= 5 && abs(wheel.y) <= 5 && (wheel.x != wheel.x.rounded() || wheel.y != wheel.y.rounded()),
             "an old wheel's zone shows where it is, off the dots, and is not moved by being shown")
    let held = ColourPad.snap(9, -12)
    c.expect(held.x == 5 && held.y == -5, "a finger past the edge holds the knob on it")
}

/// Vibrance, HSL and the channel mixer on the GPU: neutral to the bit, the reference's numbers, and what each is for.
func gpuNewSteps(_ c: Checks) {
    let source = c.mutation.kernel.map { $0(Layer2Kernel.source) } ?? Layer2Kernel.source
    guard let device = MTLCreateSystemDefaultDevice(), let renderer = try? Layer2Renderer(device: device, source: source) else { return }
    let (px, w, h) = card()
    guard let src = try? renderer.source(rgba16: px, width: w, height: h),
          let out = device.makeBuffer(length: src.bytes, options: .storageModeShared) else { return }
    func sixteen(_ a: Adjustments) -> [UInt16] {
        _ = try? renderer.apply(src, a, into: out)
        return Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt16.self, capacity: px.count), count: px.count))
    }
    // At rest after being moved, each new tool gives every pixel back to the bit; so does a pad at its centre.
    var rest = Adjustments()
    rest.vibrance = 40; rest.vibrance = 0
    rest.hsl.blue.hue = 50; rest.hsl.blue.hue = 0
    rest.channelMixer.red.green = 30; rest.channelMixer.red.green = 0
    rest.colorBalance.highlights = ColourPad.zone(x: 0, y: 0)
    c.expect(sixteen(rest) == px, "HSL, vibrance, the channel mixer and a pad at rest give the picture back to the bit")
    // Each new tool against the reference, alone and with the rest of the layer.
    var cases: [(String, Adjustments)] = []
    var v = Adjustments(); v.vibrance = 70; cases.append(("vibrance", v))
    var vn = Adjustments(); vn.vibrance = -100; cases.append(("vibrance −100", vn))
    var hs = Adjustments()
    for hue in HSLHue.allCases {
        hs.hsl[hue] = HSLBand(hue: Double(hue.index * 27 % 200) - 100, saturation: Double(hue.index * 41 % 200) - 100,
                              luminance: Double(hue.index * 59 % 200) - 100)
    }
    cases.append(("HSL, every colour", hs))
    var mx = Adjustments(); mx.channelMixer.red = MixerRow(red: -30, green: 40, blue: 10); mx.channelMixer.green.blue = -25
    cases.append(("the channel mixer", mx))
    var pads = Adjustments()
    pads.colorBalance.shadows = ColourPad.zone(x: -3, y: -2); pads.colorBalance.highlights = ColourPad.zone(x: 4, y: 4, keeping: 0.2)
    pads.colorBalance.midtones = ColourPad.zone(x: 1, y: -5)
    cases.append(("the three pads", pads))
    cases.append(("everything, with the new tools", everything()))
    for (name, a) in cases {
        let got = (try? renderer.floats(src, a)) ?? []
        guard got.count == w * h * 4 else { c.expect(false, "\(name): the pass ran"); continue }
        var worst: Float = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let input = SIMD3<Float>(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 65535
            let uv = SIMD2<Float>((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h))
            let want = Reference.apply(input, uv: uv, a)
            worst = max(worst, abs(got[i] - want.x), abs(got[i + 1] - want.y), abs(got[i + 2] - want.z))
        } }
        c.expect(worst < 5e-5, "\(name): the GPU's pass is the reference's to \(worst)")
    }
    // What each is for, on single colours.
    func one(_ rgb: SIMD3<Float>, _ a: Adjustments) -> SIMD3<Float> {
        let p16 = [UInt16(rgb.x * 65535), UInt16(rgb.y * 65535), UInt16(rgb.z * 65535), 65535]
        guard let s = try? renderer.source(rgba16: p16, width: 1, height: 1), let f = try? renderer.floats(s, a), f.count == 4 else { return .zero }
        return SIMD3(f[0], f[1], f[2])
    }
    func chroma(_ x: SIMD3<Float>) -> Float { max(x.x, x.y, x.z) - min(x.x, x.y, x.z) }
    func luma(_ x: SIMD3<Float>) -> Float { Reference.luma(x) }
    let grey = SIMD3<Float>(0.5, 0.5, 0.5), dull = SIMD3<Float>(0.55, 0.5, 0.45), vivid = SIMD3<Float>(0.9, 0.2, 0.1)
    var all = Adjustments()
    for hue in HSLHue.allCases { all.hsl[hue] = HSLBand(hue: 80, saturation: 60, luminance: 50) }
    c.expect(simd_length(one(grey, all) - grey) < 1e-4, "HSL leaves a grey alone, whatever it is set to")
    let dullUp = chroma(one(dull, v)) / chroma(dull), vividUp = chroma(one(vivid, v)) / chroma(vivid)
    c.expect(dullUp > vividUp + 0.2 && vividUp >= 1, "vibrance raises a dull colour more than a vivid one (\(dullUp) against \(vividUp))")
    c.expect(abs(luma(one(dull, v)) - luma(dull)) < 1e-4, "and leaves its luma")
    var redHue = Adjustments(); redHue.hsl.red.hue = 100
    let red = SIMD3<Float>(0.8, 0.1, 0.1), turned = one(red, redHue)
    c.expect(turned.y > red.y + 0.05 && abs(luma(turned) - luma(red)) < 1e-3, "red's hue +100 turns red towards orange, at its luma")
    let blueish = SIMD3<Float>(0.1, 0.2, 0.8)
    c.expect(simd_length(one(blueish, redHue) - blueish) < 1e-4, "and leaves a blue alone")
    var blueDark = Adjustments(); blueDark.hsl.blue.luminance = -100
    c.expect(luma(one(blueish, blueDark)) < luma(blueish) * 0.6, "blue's luminance −100 darkens a blue")
    var blueGrey = Adjustments(); blueGrey.hsl.blue.saturation = -100
    let blue = SIMD3<Float>(0.2, 0.2, 0.8)
    c.expect(chroma(one(blue, blueGrey)) < 1e-3, "blue's saturation −100 takes a blue (240°) to grey")
    var swap = Adjustments(); swap.channelMixer.red = MixerRow(red: -100, green: 0, blue: 100)
    let swapped = one(SIMD3<Float>(0.2, 0.4, 0.6), swap)
    c.expect(abs(swapped.x - 0.6) < 1e-3 && abs(swapped.y - 0.4) < 1e-3, "the channel mixer's red out can be all of blue in")
}

func model(_ c: Checks) {
    // The block the shader reads, field by field (a float3 is 16 bytes in both languages).
    typealias U = Layer2Uniforms
    let offsets: [(PartialKeyPath<U>, Int, String)] = [
        (\U.wbGain, 0, "wbGain"), (\U.exposureGain, 16, "exposureGain"), (\U.cbMaster, 32, "cbMaster"), (\U.contrast, 48, "contrast"),
        (\U.cbShadows, 64, "cbShadows"), (\U.brightness, 80, "brightness"), (\U.cbMidtones, 96, "cbMidtones"),
        (\U.saturation, 112, "saturation"), (\U.cbHighlights, 128, "cbHighlights"), (\U.highlights, 144, "highlights"),
        (\U.cbLum, 160, "cbLum"), (\U.shadows, 176, "shadows"), (\U.blackPoint, 180, "blackPoint"), (\U.whitePoint, 184, "whitePoint"),
        (\U.vignetteAmount, 188, "vignetteAmount"), (\U.vignetteMidpoint, 192, "vignetteMidpoint"), (\U.midGrey, 196, "midGrey"),
        (\U.curvesActive, 200, "curvesActive"), (\U.enabled, 204, "enabled"),
        (\U.vibrance, 208, "vibrance"), (\U.hslActive, 212, "hslActive"), (\U.mixerActive, 216, "mixerActive"),
        (\U.hslHue0, 224, "hslHue0"), (\U.hslHue1, 240, "hslHue1"), (\U.hslSat0, 256, "hslSat0"), (\U.hslSat1, 272, "hslSat1"),
        (\U.hslLum0, 288, "hslLum0"), (\U.hslLum1, 304, "hslLum1"), (\U.mixR, 320, "mixR"), (\U.mixG, 336, "mixG"), (\U.mixB, 352, "mixB"),
    ]
    for (path, want, name) in offsets {
        c.expect(MemoryLayout<U>.offset(of: path) == want, "the block's \(name) is at byte \(want), not \(MemoryLayout<U>.offset(of: path) ?? -1)")
    }
    c.expect(MemoryLayout<U>.stride == 368, "the block is 368 bytes, as the kernel's struct is (\(MemoryLayout<U>.stride))")

    // The desktop's tone block, number for number (its Model/Mask.swift `tone`), and the host's pivot.
    var a = Adjustments()
    a.exposure = 1.25; a.contrast = 18; a.brightness = -7; a.saturation = 22; a.highlights = -40; a.shadows = 30
    a.blackPoint = 6; a.whitePoint = 3; a.temperature = -14; a.tint = 9
    let u = a.uniforms()
    c.expect(u.exposureGain == Float(pow(2.0, 1.25)) && u.contrast == 0.18 && u.brightness == -0.07 && u.saturation == 1.22
             && u.highlights == -0.4 && u.shadows == 0.3 && u.blackPoint == 0.06 && u.whitePoint == 0.03,
             "the sliders become the desktop's uniforms")
    c.expect(u.wbGain == SIMD3<Float>(1 + 0.18 * -0.14, 1 - 0.12 * 0.09, 1 - 0.18 * -0.14), "temperature and tint are the desktop's gains")
    c.expect(u.midGrey == 0.4614 && Layer2Uniforms.displayMidGrey == Layer2Uniforms.srgbMidGrey,
             "the pivot is Display P3's mid-grey: the phone adjusts the P3 picture, not the ProPhoto working space")
    c.near(Double(Layer2Uniforms.srgbMidGrey), 1.055 * pow(0.18, 1 / 2.4) - 0.055, 1e-4, "0.4614 is linear 0.18 through the sRGB curve")
    c.near(Double(Layer2Uniforms.proPhotoMidGrey), pow(0.18, 1 / 1.8), 1e-4, "0.3857 is linear 0.18 through ROMM's")

    // Zero is nothing applied; what moves nothing makes nothing "edited".
    var n = Adjustments()
    c.expect(n.isNeutral && !n.isActive && n.changedTools.isEmpty && n.key == "neutral", "a fresh layer is neutral")
    n.vignette.midpoint = 20
    n.colorBalance.shadows.hue = 200
    n.curves.parametric.rgb.setSplit(.midtone, to: 0.4)
    c.expect(n.isNeutral && n.key == "neutral", "a midpoint with no vignette, a hue with no saturation, a split with no amount: still neutral")
    n.exposure = 0.1
    c.expect(n.isActive && n.changedTools == [.light], "Exposure makes Light edited, and nothing else")
    n.enabled = false
    c.expect(!n.isActive && !n.isNeutral, "switched off, it is not drawn, and it still holds what it holds")
    var all = everything()
    c.expect(all.changedTools == [.light, .curve, .colour], "every tool, in the row's order")
    all.reset(.curve)
    c.expect(all.changedTools == [.light, .colour] && all.curves == CurveSet() && all.exposure == 0.4, "a tool's reset is that tool's")
    all.reset(.light); all.reset(.colour)
    c.expect(all.isNeutral && all == Adjustments(), "the three resets are the whole of Edit")

    // Blacks and Whites are the desktop's points, read Lightroom's way.
    var b = Adjustments()
    b.blacks = -8
    c.expect(b.blackPoint == 8, "Blacks −8 takes 8 % to black (the desktop's blackPoint 8)")
    b.whites = 12
    c.expect(b.whitePoint == 12, "Whites +12 is the desktop's whitePoint 12")
    b[.blacks] = -90
    c.expect(b.blacks == -50, "a control holds its range (\(b.blacks))")
    b[.exposure] = 9
    c.expect(b.exposure == 3, "Exposure stops at 3")
    c.expect(Layer2Control.allCases.allSatisfy { $0.range.contains($0.rest) }, "every control rests inside its range")
    c.expect(Layer2Control.exposure.text(0.25) == "+0.25" && Layer2Control.contrast.text(-12) == "−12"
             && Layer2Control.vignetteMidpoint.text(50) == "50", "a control's number as its row says it")
    var k = everything(), k2 = everything()
    c.expect(k.key == k2.key && k.key.count == 16, "two layers that draw the same have one key")
    k2.tint += 1
    c.expect(k.key != k2.key, "and two that draw differently have two")
    k.enabled = false
    c.expect(k.key == "neutral", "a layer switched off draws nothing")
}

func curves(_ c: Checks) {
    // SpektrafilmTests/CurveMathTests.swift, ported.
    let id = Curve.identity
    c.expect((0...10).allSatisfy { abs(id.evaluate(CGFloat($0) / 10) - CGFloat($0) / 10) < 1e-9 } && id.isIdentity, "identity is identity")
    var v = Curve.identity
    v.insert(CGPoint(x: 0.25, y: 0.1))
    v.insert(CGPoint(x: 0.3, y: 0.9))
    var last: CGFloat = -1, monotone = true, inside = true
    for i in 0...200 {
        let y = v.evaluate(CGFloat(i) / 200)
        if y < last - 1e-9 { monotone = false }
        if !(0...1).contains(y) { inside = false }
        last = y
    }
    c.expect(monotone && inside, "a violent step stays monotone, and inside the square")
    var s = Curve.identity
    let i = s.insert(CGPoint(x: 0.7, y: 0.6)), j = s.insert(CGPoint(x: 0.3, y: 0.2))
    c.expect(j == 1 && i == 1 && s.points.map(\.x) == [0, 0.3, 0.7, 1], "insert keeps the points sorted")
    s.move(1, to: CGPoint(x: 0.95, y: 0.5))
    c.expect(s.points[1].x < s.points[2].x, "a point cannot cross its neighbour")
    s.move(0, to: CGPoint(x: 0.5, y: 0.5))
    c.expect(s.points[0].x == 0.5, "an end moves in x as well (RFC-035 §3.5), short of its neighbour")
    s.remove(0)
    c.expect(s.points.count == 4, "an end is not removable")
    s.remove(1)
    c.expect(s.points.count == 3, "an interior point is")
    let size = CGSize(width: 200, height: 200)
    c.near(Double(Curve.hitTolerance(in: size)), 0.05, 1e-9, "the hit tolerance is ten points of plot")
    var h = Curve.identity
    h.insert(CGPoint(x: 0.5, y: 0.5))
    c.expect(h.index(near: CGPoint(x: 0.545, y: 0.5), in: size) == 1, "nine points from a point is a hit")
    c.expect(h.index(near: CGPoint(x: 0.556, y: 0.5), in: size) == nil, "eleven points from it is not")
    h.insert(CGPoint(x: 0.563, y: 0.5))
    c.expect(h.index(near: CGPoint(x: 0.566, y: 0.5), in: size) == 2, "the nearest of two wins")
    c.expect(Curve.hitTolerance(in: .zero) == 0 && Curve.identity.index(near: CGPoint(x: 0.5, y: 0.5), in: .zero) == nil,
             "a plot with no area has no tolerance")
    var set = CurveSet()
    set.red.insert(CGPoint(x: 0.5, y: 0.25))
    let t = set.tables()
    c.expect(t.count == Curve.tableSize * 5, "five rows of 256")
    c.near(Double(t[Curve.tableSize * 2 + 128]), 0.25, 0.02, "row 2 is red")
    c.near(Double(t[128]), 128.0 / 255.0, 0.01, "row 0 is rgb, the identity")

    // The editor's gestures, as rules.
    var g = Curve.identity
    let grabbed = g.grab(at: CGPoint(x: 0.4, y: 0.6), in: size)
    c.expect(grabbed == 1 && g.points.count == 3, "a touch off the curve's points adds one there")
    c.expect(g.grab(at: CGPoint(x: 0.41, y: 0.6), in: size) == 1 && g.points.count == 3, "a touch on a point takes it")
    c.expect(g.drag(1, to: CGPoint(x: 0.45, y: 1.15)) == 1 && g.points[1].y == 1, "dragged a little out, it stays, held to the square")
    c.expect(g.drag(1, to: CGPoint(x: 0.45, y: 1.25)) == nil && g.points.count == 2, "dragged a fifth of the plot out, it is gone")
    c.expect(g.drag(0, to: CGPoint(x: -0.5, y: -0.5)) == 0 && g.points.count == 2, "an end dragged out stays")

    // Litti's touch: a point on the curve where the finger is, taken by the same touch.
    let plot = CGSize(width: 360, height: 200)
    var tc = Curve.identity
    tc.insert(CGPoint(x: 0.25, y: 0.35))
    let before = tc
    let far = tc.touch(at: CGPoint(x: 0.6, y: 0.2), in: plot)
    let put: CGPoint = tc.points[far.index]
    let onCurve: CGFloat = before.evaluate(0.6)
    c.expect(far.added && tc.points.count == 4 && abs(put.y - onCurve) < 1e-12 && put.x == 0.6,
             "a touch off the points puts one on the curve at the finger's input, not at the finger")
    var worst: CGFloat = 0
    for i in 0...40 { let x = CGFloat(i) / 40; worst = max(worst, abs(tc.evaluate(x) - before.evaluate(x))) }
    c.expect(worst < 0.02, "and the curve is (nearly) as it was until the finger moves (\(worst))")
    c.near(Double(far.offset.y), Double(onCurve - 0.2), 1e-12, "the drag carries it from where it is, by the finger's travel")
    let on = tc.touch(at: CGPoint(x: 0.26, y: 0.4), in: plot)
    c.expect(!on.added && on.index == 1 && tc.points.count == 4, "a touch within a fingertip of a point takes that point")
    let sameInput = tc.touch(at: CGPoint(x: 0.61, y: 0.95), in: plot)
    c.expect(!sameInput.added && sameInput.index == far.index, "a touch at a point's input, far above it, takes it rather than stacking a second")
    endsInX(c)
    var cleared = Adjustments(); cleared.curves.rgb = tc; cleared.curves.red.insert(CGPoint(x: 0.5, y: 0.4))
    cleared.curves.parametric.luma.darks = 20; cleared.exposure = 0.3
    AdjustTool.curve.reset(&cleared)
    c.expect(cleared.curves.isIdentity && cleared.exposure == 0.3, "🗑 on the curve takes every point off every channel, and the parametric curve, and nothing else")
}

/// RFC-035 §3.5 (the owner, 2026-10-25: the black and the white point "should be also draggable to left
/// and right"): the ends move in x within their neighbours, the curve is flat beyond them, an end is
/// still never removed. Red on the old `move`, which pinned point 0 to x = 0 and the last to x = 1.
func endsInX(_ c: Checks) {
    var e = Curve.identity
    e.move(0, to: CGPoint(x: 0.3, y: 0.1))
    e.move(1, to: CGPoint(x: 0.7, y: 0.9))
    c.expect(e.points == [CGPoint(x: 0.3, y: 0.1), CGPoint(x: 0.7, y: 0.9)], "the black point moves right and the white point left")
    c.expect(e.evaluate(0) == 0.1 && e.evaluate(0.29) == 0.1 && e.evaluate(0.71) == 0.9 && e.evaluate(1) == 0.9,
             "and the curve is flat beyond each end: what is past the black point is the black point's output")
    let t = e.table()
    c.expect(t[0] == Float(CGFloat(0.1)) && t[76] == Float(CGFloat(0.1)) && t[255] == Float(CGFloat(0.9)) && t[128] > 0.1 && t[128] < 0.9,
             "so is its table, and between the ends it is the curve")
    c.expect(!e.isIdentity, "an end moved in x is not the identity")
    var two = Curve.identity
    two.move(1, to: CGPoint(x: 0.4, y: 1))
    two.move(0, to: CGPoint(x: 0.9, y: 0))
    c.near(Double(two.points[0].x), 0.39, 1e-9, "with only the two ends, the black point stops short of the white")
    var n = Curve.identity
    n.insert(CGPoint(x: 0.5, y: 0.5))
    n.move(0, to: CGPoint(x: 0.8, y: 0))
    n.move(2, to: CGPoint(x: 0.1, y: 1))
    c.expect(abs(n.points[0].x - 0.49) < 1e-9 && abs(n.points[2].x - 0.51) < 1e-9 && n.points.map(\.x) == n.points.map(\.x).sorted(),
             "no end crosses its neighbour, and the points stay sorted")
    n.remove(0); n.remove(2)
    c.expect(n.points.count == 3, "a chosen end is still not removable")
    c.expect(n.drag(0, to: CGPoint(x: -0.6, y: 0.5)) == 0 && n.points.count == 3 && n.points[0].x == 0,
             "an end dragged far out stays, at the edge")
    // The host's Litti curve keeps its rule: an end moves up and down, at the x it has.
    var phone = e
    phone.move(0, to: CGPoint(x: 0.05, y: 0.3), endsInX: false)
    c.expect(phone.points[0] == CGPoint(x: 0.3, y: 0.3), "on the phone an end keeps its x")
    c.expect(Curve.identity.points[0].x == 0 && { var q = Curve.identity; _ = q.drag(0, to: CGPoint(x: 0.4, y: 0.2), endsInX: false); return q.points[0] == CGPoint(x: 0, y: 0.2) }(),
             "and a phone's drag of the black point is the old one exactly")
    // The Mac's press: a point, the curve, or nothing.
    let plot = CGSize(width: 345, height: 300)
    var pr = Curve.identity
    pr.insert(CGPoint(x: 0.5, y: 0.6))
    let onPoint = pr.press(at: CGPoint(x: 0.51, y: 0.61), in: plot)
    c.expect(onPoint?.index == 1 && onPoint?.added == false && pr.points.count == 3, "a press on a point takes it")
    let onCurve = pr.press(at: CGPoint(x: 0.25, y: pr.evaluate(0.25) + 0.05), in: plot)
    c.expect(onCurve?.added == true && pr.points.count == 4 && abs(pr.points[1].y - Curve.identity.evaluate(0.25)) < 0.2 && pr.points[1].x == 0.25,
             "a press within 22 pt of the curve puts a point on it")
    let before = pr
    c.expect(pr.press(at: CGPoint(x: 0.75, y: 0.1), in: plot) == nil && pr == before, "a press on empty plot takes nothing and adds nothing")
    var inward = e
    c.expect(inward.press(at: CGPoint(x: 0.15, y: 0.1), in: plot) == nil && inward == e, "nor does a press past a moved-in end, where the curve is flat")
    var moved = CurveSet(); moved.red = e
    let back = try? JSONDecoder().decode(CurveSet.self, from: JSONEncoder().encode(moved))
    c.expect(back == moved, "a curve with its ends moved in is kept as it is (no format change)")
    let tables = moved.tables()
    c.expect(tables[Curve.tableSize * 2] == Float(CGFloat(0.1)) && tables[0] == 0, "the red row is the moved curve's, the rgb row the identity's")
}

func parametric(_ c: Checks) {
    let p = ParametricCurve()
    c.expect(p.isNeutral && (0...20).allSatisfy { p.evaluate(CGFloat($0) / 20) == CGFloat($0) / 20 }, "a neutral parametric curve is the identity, exactly")
    var lift = ParametricCurve()
    lift.shadows = 100
    c.near(Double(lift.evaluate(0.125)), 0.25, 1e-9, "Shadows +100 doubles the middle of the shadows")
    c.expect(lift.evaluate(0) == 0 && lift.evaluate(1) == 1, "and leaves black and white where they are")
    c.near(Double(lift.evaluate(0.75)), 0.75, 1e-3, "and the highlights alone")
    var hl = ParametricCurve()
    hl.highlights = -100
    c.near(Double(hl.evaluate(0.875)), 0.75, 1e-9, "Highlights −100 at the middle of its region")
    // Every setting is monotone and inside the square, wherever the splits are.
    var rng = SystemRandomNumberGenerator()
    var worst = 0.0, outside = false
    for _ in 0..<400 {
        var q = ParametricCurve()
        for r in ParametricCurve.Region.allCases { q[r] = Double.random(in: -100...100, using: &rng) }
        q.setSplit(.midtone, to: Double.random(in: 0.1...0.9, using: &rng))
        q.setSplit(.shadow, to: Double.random(in: 0...1, using: &rng))
        q.setSplit(.highlight, to: Double.random(in: 0...1, using: &rng))
        var last: CGFloat = 0
        for i in 0...256 {
            let y = q.evaluate(CGFloat(i) / 256)
            worst = max(worst, Double(last - y))
            if !(0...1).contains(y) { outside = true }
            last = y
        }
    }
    c.expect(worst <= 1e-12 && !outside, "400 random parametric curves: never falling (worst \(worst)), never outside the square")
    var order = ParametricCurve()
    order.setSplit(.shadow, to: 0.9)
    order.setSplit(.highlight, to: 0.1)
    c.expect(order.shadowSplit < order.midtoneSplit && order.midtoneSplit < order.highlightSplit
             && order.highlightSplit <= 0.95 && order.shadowSplit >= 0.05, "the splits keep their order and their gap")
    // Composed with the point curve: the parametric first, as Lightroom applies it.
    var set = CurveSet()
    set.parametric.rgb.shadows = 100
    set.rgb.insert(CGPoint(x: 0.25, y: 0.1))
    let x: CGFloat = 0.125
    c.near(Double(set.evaluate(.rgb, x)), Double(set.rgb.evaluate(set.parametric.rgb.evaluate(x))), 1e-12, "the point curve reads what the parametric made")
    c.expect(abs(set.evaluate(.rgb, x) - set.parametric.rgb.evaluate(set.rgb.evaluate(x))) > 0.01, "which is not the other order")
    c.expect(!set.isIdentity && set.changedChannels == [.rgb], "a parametric amount makes its channel edited")
    let t = set.table(.rgb)
    c.near(Double(t[32]), Double(set.evaluate(.rgb, 32.0 / 255)), 1e-6, "the table is the composition")
    var plain = CurveSet()
    plain.green.insert(CGPoint(x: 0.3, y: 0.5))
    c.expect(plain.table(.green) == plain.green.table(), "a channel with no parametric curve is the desktop's table exactly")
    set.reset(.rgb)
    c.expect(set.isIdentity, "a channel's reset is both views")
}

let schema3 = #"{"dateBack":{"active":false,"brightnessEV":3.5,"corner":"br","insetXMM":3,"insetYMM":2.4,"order":"japan","placement":"frame","size":1,"style":"lcd"},"decode":{"lensCorrection":false,"temperature":5500,"tint":0,"whiteBalance":"Daylight"},"decoder":"coreimage","filmEdge":{"active":true,"cameraSeed":0,"fog":1,"format":"135","frameNumber":0,"gate":"auto","holes":"white","leaks":0,"mode":"strip","turn":0},"frameSeed":7,"geometry":{"angle":0,"aspect":"free","crop":{"height":0.9,"width":0.8,"x":0.1,"y":0.05},"flipH":false,"flipV":false,"quarterTurns":0},"params":{"autoExposure":true,"autoExposureMethod":"balanced","contrastMask":{"active":false,"core":1,"highlights":0,"scale":0.03,"scheme":"gaussian","shadows":0},"digitalIntermediate":false,"effects":{"couplers":1,"couplersActive":true,"glare":1,"grain":1,"grainLayered":true,"halation":1,"scatter":1},"exposureCompensationEV":0.3,"extendedDynamicRange":false,"filmFormatMM":36,"filmFrame":"135","filmSide":"short","filmStock":"kodak_portra_400","glareActive":true,"grainActive":true,"halationActive":true,"mFilterShift":0,"pairSplit":0,"placementIsRight":false,"preflashExposure":0,"printBrightnessStops":0,"printEffects":true,"printStock":"kodak_supra_endura","scanFilm":false,"sceneLatitude":{"active":false,"highlightKnee":2,"highlightPercentile":99.9,"highlightPullBack":0,"highlightRoom":0,"maxLift":4,"norm":"power","rolloff":2,"shadowKnee":-2,"shadowPercentile":0.1,"shadowPullBack":0,"shadowRoom":0},"sceneLatitudeOther":{"active":false,"highlightKnee":2,"highlightPercentile":99.9,"highlightPullBack":0,"highlightRoom":0,"maxLift":4,"norm":"power","rolloff":2,"shadowKnee":-2,"shadowPercentile":0.1,"shadowPullBack":0,"shadowRoom":0},"sideLengthMM":24,"yFilterShift":0.1},"placementNeedsFit":false,"schemaVersion":3,"solvedEV":1.25}"#

func codable(_ c: Checks) {
    // An edit as the build before Layer 2 wrote it (tools/layer2_selftest.swift's fixture: encoded by
    // FrameEdit.swift at 846c3cd, sorted keys as LibraryPersistence writes them).
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let read = try? JSONDecoder().decode(FrameEdit.self, from: Data(schema3.utf8)) else {
        c.expect(false, "an edit of schema 3 loads"); return
    }
    c.expect(read.adjustments == Adjustments() && read.adjustments.isNeutral, "an edit of schema 3 loads, with Layer 2 neutral")
    c.expect(read.schemaVersion == FrameEdit.currentSchema && FrameEdit.currentSchema == 5, "and is held as schema 5")
    c.expect(read.decode.rawExposureTreatment == .legacy && read.params.autoExposure,
             "old decode and Balanced remain legacy; schema migration does not change exposure")
    c.expect(read.params.exposureCompensationEV == 0.3 && read.frameSeed == 7 && read.solvedEV == 1.25 && read.filmEdge.active,
             "with what it held")
    func stripped(_ data: Data) -> Data? {
        guard var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        o["adjustments"] = nil; o["schemaVersion"] = nil
        // The additive experimental flag was absent in schema 3. Compare
        // all existing values exactly, allowing only its default migration.
        if var params = o["params"] as? [String: Any], params["antihalationRemoved"] == nil {
            params["antihalationRemoved"] = false; o["params"] = params
        }
        // unpublished-revision (2026-10-24): Decode's curve on the linear scene, written at its default (the identity)
        // and read as it when absent — this check went red from that commit until 2026-11-05.
        if var params = o["params"] as? [String: Any], params["sceneCurve"] == nil,
           let identity = (try? encoder.encode(CurveSet())).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) {
            params["sceneCurve"] = identity; o["params"] = params
        }
        // Schema 5 makes the formerly implicit old RAW recipe explicit.
        if var decode = o["decode"] as? [String: Any], decode["rawExposureTreatment"] == nil {
            decode["rawExposureTreatment"] = "legacy.1"; o["decode"] = decode
        }
        // 2026-10-20: the edge print's and the date's brightness (1×) and the
        // data line beside a date (off), each written at its default.
        if var edge = o["filmEdge"] as? [String: Any], edge["edgeBrightness"] == nil {
            edge["edgeBrightness"] = 1.0; o["filmEdge"] = edge
        }
        if var back = o["dateBack"] as? [String: Any] {
            if back["brightness"] == nil { back["brightness"] = 1.0 }
            if back["alsoData"] == nil { back["alsoData"] = false }
            o["dateBack"] = back
        }
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }
    c.expect(!read.params.antihalationRemoved, "schema 3 retains its backing layer by default")
    let again = (try? encoder.encode(read)) ?? Data()
    let before = stripped(Data(schema3.utf8)), after = stripped(again)
    c.expect(before != nil && before == after, "written again, existing fields are byte-identical after default-false backing-layer migration")
    let text = String(decoding: again, as: UTF8.self)
    c.expect(text.contains("\"adjustments\":{") && text.contains("\"schemaVersion\":5")
             && text.contains("\"rawExposureTreatment\":\"legacy.1\""), "the edit carries Layer 2 and explicit legacy decode in schema 5")
    // A desktop sidecar's `adjustments` (no `parametric`, no curves key at all) reads; and round trips.
    let desktop = #"{"enabled":true,"temperature":-12,"tint":0,"exposure":0.5,"contrast":10,"brightness":0,"saturation":0,"highlights":0,"shadows":0,"blackPoint":4,"whitePoint":0,"colorBalance":{"master":{"hue":0,"saturation":0,"luminance":0},"shadows":{"hue":210,"saturation":0.2,"luminance":0},"midtones":{"hue":0,"saturation":0,"luminance":0},"highlights":{"hue":0,"saturation":0,"luminance":0}},"vignette":{"amount":-20,"midpoint":50},"curves":{"rgb":{"points":[[0,0],[0.5,0.6],[1,1]]},"luma":{"points":[[0,0],[1,1]]},"red":{"points":[[0,0],[1,1]]},"green":{"points":[[0,0],[1,1]]},"blue":{"points":[[0,0],[1,1]]}}}"#
    let d = try? JSONDecoder().decode(Adjustments.self, from: Data(desktop.utf8))
    c.expect(d?.exposure == 0.5 && d?.blackPoint == 4 && d?.colorBalance.shadows.hue == 210 && d?.curves.rgb.points.count == 3
             && d?.curves.parametric.isNeutral == true, "a desktop edit's Layer 2 reads, its curves with no parametric")
    let a = everything()
    let back = (try? encoder.encode(a)).flatMap { try? JSONDecoder().decode(Adjustments.self, from: $0) }
    c.expect(back == a, "a layer that moves everything round-trips")
    var e = FrameEdit.default
    e.adjustments = a
    let eBack = (try? encoder.encode(e)).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
    c.expect(eBack == e, "and so does the edit that holds it")
    // Not part of a develop: the engine's settings are what they were. (That no job is asked for is the
    // app's own check, on the page's session: tools/layer2_check.sh.)
    var moved = FrameEdit.default
    moved.adjustments = a
    c.expect(moved.params == FrameEdit.default.params && moved.params.delta(from: FrameEdit.default.params).layers.isEmpty,
             "moving Layer 2 moves none of the engine's settings")
    c.expect(moved.changedText == "Light · Curve · Colour", "Info's Changed row names the tools (\(moved.changedText))")
}

func clipboard(_ c: Checks) {
    c.expect(ClipboardGroup.offered.suffix(3) == [.light, .curve, .colour], "Copy Settings offers Light, Curve and Colour, last")
    c.expect(ClipboardGroup.defaultSelection.isSuperset(of: [.light, .curve, .colour]), "ticked when the sheet opens")
    var source = FrameEdit.default
    source.adjustments = everything()
    var target = FrameEdit.default
    target.adjustments.exposure = -1
    target.adjustments.curves.green.insert(CGPoint(x: 0.5, y: 0.7))
    target.params.yFilterShift = 0.2
    func paste(_ groups: Set<ClipboardGroup>) -> FrameEdit { SettingsClip(groups: groups, settings: source, sourceName: "x").applied(to: target, picture: PixelSize(width: 3, height: 2)) }
    let light = paste([.light])
    c.expect(light.adjustments.exposure == 0.4 && light.adjustments.blackPoint == 6 && light.adjustments.vignette.amount == -35,
             "Light carries Light")
    c.expect(light.adjustments.curves.green.points.count == 3 && light.adjustments.temperature == 0 && light.params.yFilterShift == 0.2,
             "and leaves the curves, the colour and the darkroom as they were")
    let curve = paste([.curve])
    c.expect(curve.adjustments.curves == source.adjustments.curves && curve.adjustments.exposure == -1, "Curve carries every channel, both views, and nothing else")
    let colour = paste([.colour])
    c.expect(colour.adjustments.temperature == -14 && colour.adjustments.colorBalance == source.adjustments.colorBalance
             && colour.adjustments.saturation == 22 && colour.adjustments.exposure == -1, "Colour carries the scan's balance, saturation and the wheels")
    let all = paste([.light, .curve, .colour])
    c.expect(all.adjustments == source.adjustments && all.params == target.params, "the three are the whole layer, and no darkroom setting")
    let none = paste([.filmAndPaper, .exposure])
    c.expect(none.adjustments == target.adjustments, "the darkroom's groups leave Layer 2 alone")
    c.expect(ClipboardGroup.light.summary(of: source) == "Exposure +0.40 · Contrast +18 · Brightness −7 · Highlights −40 · Shadows +30 · Whites +3 · Blacks −6 · Vignette −35",
             "Light's line: \(ClipboardGroup.light.summary(of: source))")
    c.expect(ClipboardGroup.curve.summary(of: source) == "RGB · Luma · B", "Curve's line: \(ClipboardGroup.curve.summary(of: source))")
    c.expect(ClipboardGroup.colour.summary(of: FrameEdit.default) == "None", "a group with nothing in it says so")
    filmEdgeTurn(c)
    rememberedGroups(c)
}

/// What the Mac's ⌘C copies with: the sheet's last ticks, kept (a suite of the check's own, trap 24).
func rememberedGroups(_ c: Checks) {
    let name = "spk.layer2-selftest.\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: name) else { c.expect(false, "a defaults suite of the check's own"); return }
    defer { d.removePersistentDomain(forName: name) }
    c.expect(ClipboardGroup.remembered(in: d) == ClipboardGroup.defaultSelection, "never copied: the sheet's own first ticks")
    ClipboardGroup.remember([.filmAndPaper, .light], in: d)
    c.expect(ClipboardGroup.remembered(in: d) == [.filmAndPaper, .light], "the ticks last copied with are kept")
    ClipboardGroup.remember([], in: d)
    c.expect(ClipboardGroup.remembered(in: d) == [.filmAndPaper, .light], "an empty tick (Copy is greyed) keeps the last")
    d.set(["scenePlacement", "nonsense"], forKey: ClipboardGroup.rememberedKey)
    c.expect(ClipboardGroup.remembered(in: d) == ClipboardGroup.defaultSelection, "groups no longer offered fall back to the first ticks")
}

/// A film edge pasted from an upright picture onto a wide one (the owner, 2026-11-05: "if we try to
/// apply copy (film edge mostly) from a vertical image to a horizontal image, the film edge would
/// automatically be vertical"). The film lies the way the *target* does; the source's half turn — the
/// name below or on the left — is a choice and travels.
func filmEdgeTurn(_ c: Checks) {
    let upright = PixelSize(width: 4000, height: 6000), wide = PixelSize(width: 6000, height: 4000)
    var source = FrameEdit.default
    source.filmEdge.active = true
    source.filmEdge.format = .f135
    source.filmEdge.turn = FilmEdgeFormat.f135.defaultTurn(pictureAspect: upright.aspect)   // 1: down the picture
    source.filmEdge.framing = Geometry.default
    source.filmEdge.cameraSeed = 7
    let clip = SettingsClip(groups: [.filmEdgeAndDateBack], settings: source, sourceName: "upright.dng", sourceAspect: upright.aspect)
    var target = FrameEdit.default
    target.filmEdge.cameraSeed = 3
    let onto = clip.applied(to: target, picture: wide)
    c.expect(source.filmEdge.turn == 1 && onto.filmEdge.active && onto.filmEdge.turn == 0,
             "an upright picture's film edge on a wide picture runs across it (turn \(onto.filmEdge.turn))")
    c.expect(onto.filmEdge.cameraSeed == 3 && onto.filmEdge.framing == nil, "the target keeps its body, and its gate's cut starts again")
    var halfTurned = source
    halfTurned.filmEdge.turn = 3
    let flipped = SettingsClip(groups: [.filmEdgeAndDateBack], settings: halfTurned, sourceName: "", sourceAspect: upright.aspect).applied(to: target, picture: wide)
    c.expect(flipped.filmEdge.turn == 2, "a half turn (the name below) travels: 3 on the upright is 2 on the wide (\(flipped.filmEdge.turn))")
    var turned = target
    turned.geometry.quarterTurns = 1
    let onTurned = SettingsClip(groups: [.filmEdgeAndDateBack], settings: halfTurned, sourceName: "", sourceAspect: upright.aspect).applied(to: turned, picture: wide)
    c.expect(onTurned.filmEdge.turn == 3, "a wide file turned upright by its crop takes the upright's film (\(onTurned.filmEdge.turn))")
    var square = source
    square.filmEdge.format = .f6x6; square.filmEdge.turn = 2
    let sq = SettingsClip(groups: [.filmEdgeAndDateBack], settings: square, sourceName: "", sourceAspect: upright.aspect).applied(to: target, picture: wide)
    c.expect(sq.filmEdge.turn == 2, "a square gate has no lie of its own: only the half turn (\(sq.filmEdge.turn))")
    var same = FrameEdit.default
    same.filmEdge = source.filmEdge
    same.filmEdge.cameraSeed = 9
    let kept = clip.applied(to: same, picture: upright)
    c.expect(kept.filmEdge.turn == 1 && kept.filmEdge.framing == Geometry.default,
             "onto a picture of the source's shape and format the turn and the target's own framing stay")
    // A clip whose source shape is unknown (a preset saved before the shape was kept): only its half
    // turn is known to be a choice.
    let shapeless = SettingsClip(groups: [.filmEdgeAndDateBack], settings: halfTurned, sourceName: "")
    c.expect(shapeless.applied(to: target, picture: wide).filmEdge.turn == 2 && shapeless.applied(to: target, picture: upright).filmEdge.turn == 3,
             "with the source's shape unknown the film lies the target's way and keeps its half turn")
    // A turn chosen against the source's own lie is a choice too, and travels as one (the review,
    // 2026-11-05): a film laid across an upright picture (0 where the upright's default is 1) pasted onto
    // another upright picture stays across it; onto a wide one it runs down it (3: across turned, kept).
    var across = source
    across.filmEdge.turn = 0
    let acrossClip = SettingsClip(groups: [.filmEdgeAndDateBack], settings: across, sourceName: "upright.dng", sourceAspect: upright.aspect)
    let acrossUpright = acrossClip.applied(to: target, picture: upright)
    c.expect(acrossUpright.filmEdge.turn == 0, "a film across an upright picture stays across another upright one (turn \(acrossUpright.filmEdge.turn))")
    let acrossWide = acrossClip.applied(to: target, picture: wide)
    c.expect(acrossWide.filmEdge.turn == 3, "a film across an upright picture runs down a wide one, its half turn kept (turn \(acrossWide.filmEdge.turn))")
    // A preset is no paste: it keeps the source's turn and its shape, and its own paste places the film.
    let preset = acrossClip.transferable
    c.expect(preset.sourceAspect == upright.aspect && preset.settings.filmEdge.turn == 0
             && preset.applied(to: target, picture: upright).filmEdge.turn == 0,
             "a preset of a film across an upright picture lays it across the next upright one")
    let other = SettingsClip(groups: [.light], settings: source, sourceName: "").applied(to: turned, picture: wide)
    c.expect(other.filmEdge == turned.filmEdge, "a paste without the group leaves the film edge alone")
}

func logNames(_ c: Checks) {
    let want: [(String, String)] = [
        ("exposure", "edit.light.exposure"), ("blackPoint", "edit.light.blacks"), ("whitePoint", "edit.light.whites"),
        ("vignette.amount", "edit.light.vignette"), ("vignette.midpoint", "edit.light.vignette.midpoint"),
        ("temperature", "edit.colour.temperature"), ("colorBalance.shadows.hue", "edit.colour.shadows.hue"),
        ("curves.rgb.points", "edit.curve.rgb.points"), ("curves.parametric.luma.shadowSplit", "edit.curve.luma.shadowSplit"),
        ("enabled", "edit.enabled"),
    ]
    for (path, name) in want { c.expect(Adjustments.logName(path) == name, "\(path) is logged as \(name), not \(Adjustments.logName(path))") }
    c.expect(Layer2Control.allCases.allSatisfy { $0.logName.hasPrefix("edit." + $0.tool.rawValue + ".") }, "every control's name is under its tool")
    // A visit's time on each surface.
    let t0 = Date(timeIntervalSince1970: 1000)
    var clock = SurfaceClock(on: .develop, at: t0)
    clock.show(.edit, at: t0.addingTimeInterval(12))
    clock.show(.edit, at: t0.addingTimeInterval(15))
    clock.show(.develop, at: t0.addingTimeInterval(40))
    let seconds = clock.seconds(at: t0.addingTimeInterval(45))
    c.expect(seconds[.develop] == 17 && seconds[.edit] == 28 && clock.surface == .develop, "a visit's time on each surface: 17 s on Develop, 28 on Edit")
    c.expect(clock.logged(at: t0.addingTimeInterval(45)) == ["develop": 17.0, "edit": 28.0], "as the log writes it")
}

// Page switches must preserve the current tool/step and never select an empty panel.
func pageNavigation(_ c: Checks) {
    var n = DevelopPageNavigation()
    c.expect(n.surface == .develop && n.step == .filmAndPaper, "new page opens on Develop / Film & Paper")
    n.select(.format)
    n.show(.edit)
    n.darkroom = .enlarger
    n.select(.crop)
    n.show(.develop)
    c.expect(n.step == .format, "Edit does not discard Develop's step")
    n.show(.edit)
    c.expect(n.tool == .crop && n.darkroom == .enlarger, "surface switch retains Edit tool and nested destination")
    n.select(.adjust)
    c.expect(n.tool == .adjust && n.adjust == nil, "Adjust opens on its strip")
    n.open(.hsl)
    n.show(.develop); n.show(.edit)
    c.expect(n.tool == .adjust && n.adjust == .hsl, "a tile's control stays open through a surface switch")
    n.closeAdjust()
    c.expect(n.adjust == nil && n.tool == .adjust, "✓ goes back to the strip")
    n.select(.crop); n.panelFolded = true
    n.open(.curve)
    c.expect(n.tool == .adjust && n.adjust == .curve && !n.panelFolded, "a tile opens its control unfolded, from any tool")
    n.select(.adjust)
    c.expect(n.adjust == nil && !n.panelFolded, "Adjust tapped again with a tile open goes back to the strip, as a tab does")
    n.select(.adjust)
    c.expect(n.panelFolded, "and on the strip it folds the panel, as every tool does")
    n.select(.adjust)
    n.select(.crop)
    n.select(.crop)
    c.expect(n.panelFolded, "reselecting the current tool folds its panel")
    n.select(.darkroom)
    c.expect(!n.panelFolded && n.darkroom == .enlarger, "another tool unfolds and restores its nested page")
    // EngineRouter arranged as Adjust (the owner, 2026-10-22): its tiles, a tile's controls in the strip's
    // place, ✓ and the tool tapped again back to the strip; each reset leaf one tile's.
    n.select(.darkroom)
    c.expect(n.tool == .darkroom && n.darkroom == nil && !n.panelFolded, "EngineRouter tapped again with a tile open goes back to its strip, as Adjust does")
    n.select(.crop); n.panelFolded = true
    n.open(.effects)
    c.expect(n.tool == .darkroom && n.darkroom == .effects && !n.panelFolded, "a EngineRouter tile opens its controls unfolded, from any tool")
    n.closeDarkroom()
    c.expect(n.tool == .darkroom && n.darkroom == nil, "the EngineRouter tile's ✓ goes back to its strip")
    // Decode left EngineRouter for Develop › Film & Paper on 2026-10-24 (DecodeSection.swift).
    c.expect(DarkroomPage.allCases == [.enlarger, .effects], "EngineRouter's tiles: Enlarger, Effects")
    let leaves = DarkroomPage.allCases.flatMap(\.scopes)
    c.expect(Set(leaves).count == leaves.count && Set(leaves) == [.enlarger, .preflash, .effects],
             "Pre-flash is the Enlarger's, the effects Effects', each one tile's")
    n.open(.effects)
    n.show(.develop)
    n.select(.format)
    c.expect(n.panelFolded, "reselecting the current Develop step folds its panel")
    let fresh = DevelopPageNavigation()
    c.expect(fresh.step == .filmAndPaper && fresh.darkroom == nil && !fresh.panelFolded,
             "another frame does not inherit page navigation")
}

// MARK: - on the GPU

func gpu(_ c: Checks) {
    let source = c.mutation.kernel.map { $0(Layer2Kernel.source) } ?? Layer2Kernel.source
    guard let device = MTLCreateSystemDefaultDevice() else { c.expect(false, "this Mac has a Metal device"); return }
    let renderer: Layer2Renderer
    do { renderer = try Layer2Renderer(device: device, source: source) } catch {
        c.expect(false, "the kernels compile with safe math: \(error)"); return
    }
    c.expect(true, "the kernels compile from their string, with safe math")
    let (px, w, h) = card()
    guard let src = try? renderer.source(rgba16: px, width: w, height: h) else { c.expect(false, "a card in a buffer"); return }

    // Neutral is the identity to the bit: the 16-bit pass gives every value back.
    if let out = device.makeBuffer(length: src.bytes, options: .storageModeShared) {
        _ = try? renderer.apply(src, Adjustments(), into: out)
        let got = Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt16.self, capacity: px.count), count: px.count))
        c.expect(got == px, "a neutral layer gives the picture back to the bit (\(zip(got, px).filter { $0 != $1 }.count) values moved)")
        var off = everything(); off.enabled = false
        _ = try? renderer.apply(src, off, into: out)
        let got2 = Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt16.self, capacity: px.count), count: px.count))
        c.expect(got2 == px, "and so does a layer switched off, whatever it holds")
    }
    let neutralFloats = (try? renderer.floats(src, Adjustments())) ?? []
    var exact = neutralFloats.count == px.count
    for i in 0..<min(neutralFloats.count, px.count) where i % 4 != 3 { if neutralFloats[i] != Float(px[i]) / 65535 { exact = false } }
    c.expect(exact, "and in float, each value is its 16 bits over 65535, unmoved")

    // The desktop's renderer tests, on its 4 x 2 card.
    let M: UInt16 = 65535, H: UInt16 = 32768
    let desk: [UInt16] = [M, 0, 0, M, 0, M, 0, M, 0, 0, M, M, M, M, M, M, 0, 0, 0, M, H, H, H, M, 0, 0, 0, M, H, H, H, M]
    if let d = try? renderer.source(rgba16: desk, width: 4, height: 2) {
        func at(_ f: [Float], _ x: Int, _ y: Int) -> Float { f.count == 32 ? f[(y * 4 + x) * 4] : -1 }
        let neutral = (try? renderer.floats(d, Adjustments())) ?? []
        c.expect(at(neutral, 0, 0) == 1 && abs(at(neutral, 1, 1) - 0.5) < 1e-3, "the desktop's neutral passthrough")
        var bypass = Adjustments(); bypass.enabled = false; bypass.exposure = 2
        c.expect(abs(at((try? renderer.floats(d, bypass)) ?? [], 1, 1) - 0.5) < 1e-3, "the desktop's bypass")
        var exposure = Adjustments(); exposure.exposure = 1
        let g = at((try? renderer.floats(d, exposure)) ?? [], 1, 1)
        c.expect(g > 0.6 && g < 0.75, "the desktop's exposure +1 brightens mid-grey to \(g) (0.5^2.2·2 → ^(1/2.2) ≈ 0.685)")
        c.near(Double(g), pow(pow(Double(H) / 65535, 2.2) * 2, 1 / 2.2), 2e-5, "exactly that")
        var invert = Adjustments(); invert.curves.rgb.points = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)]
        let inv = (try? renderer.floats(d, invert)) ?? []
        c.expect(abs(at(inv, 3, 0)) < 0.01 && abs(at(inv, 0, 1) - 1) < 0.01, "the desktop's curves invert: white to black, black to white")
    }

    // Every step held to the reference, on the card, one tool at a time and all together.
    var cases: [(String, Adjustments)] = []
    var l = Adjustments(); l.exposure = -0.7; l.contrast = 25; l.highlights = 60; l.shadows = -45; cases.append(("Light's tone", l))
    var l2 = Adjustments(); l2.brightness = 30; l2.blacks = 10; l2.whites = -12; cases.append(("brightness and the two points, both ways", l2))
    var co = Adjustments(); co.temperature = 40; co.tint = -30; co.saturation = -60
    co.colorBalance.midtones = ColorZone(hue: 300, saturation: 0.6, luminance: 0.3); cases.append(("Colour", co))
    var cu = Adjustments(); cu.curves.luma.insert(CGPoint(x: 0.3, y: 0.45)); cu.curves.red.insert(CGPoint(x: 0.6, y: 0.5))
    cu.curves.parametric.green.darks = 60; cases.append(("Curve", cu))
    var vi = Adjustments(); vi.vignette = Vignette(amount: 70, midpoint: 10); cases.append(("the vignette", vi))
    cases.append(("everything", everything()))
    for (name, a) in cases {
        let got = (try? renderer.floats(src, a)) ?? []
        guard got.count == w * h * 4 else { c.expect(false, "\(name): the pass ran"); continue }
        var worst: Float = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let input = SIMD3<Float>(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) / 65535
            let uv = SIMD2<Float>((Float(x) + 0.5) / Float(w), (Float(y) + 0.5) / Float(h))
            let want = Reference.apply(input, uv: uv, a)
            worst = max(worst, abs(got[i] - want.x), abs(got[i + 1] - want.y), abs(got[i + 2] - want.z))
        } }
        c.expect(worst < 2e-5, "\(name): the GPU's pass is the reference's to \(worst)")
    }
    // The page's kernel (16 bits out) is the float kernel's numbers in 16 bits: one pass, two containers.
    if let out = device.makeBuffer(length: src.bytes, options: .storageModeShared) {
        let a = everything()
        _ = try? renderer.apply(src, a, into: out)
        let got = Array(UnsafeBufferPointer(start: out.contents().bindMemory(to: UInt16.self, capacity: px.count), count: px.count))
        let f = (try? renderer.floats(src, a)) ?? []
        var worst = 0
        for i in 0..<min(f.count, got.count) where i % 4 != 3 {
            let want = Int((min(max(f[i], 0), 1) * 65535 + 0.5).rounded(.down))
            worst = max(worst, abs(Int(got[i]) - want))
        }
        c.expect(f.count == got.count && worst <= 1, "the page's 16-bit pass is the float pass held to 16 bits (at most \(worst) of 65,535 apart)")
    }

    // Unclamped: what is pushed past white stays past it until a container holds it.
    var hot = Adjustments(); hot.exposure = 2
    let hotFloats = (try? renderer.floats(src, hot)) ?? []
    c.expect((hotFloats.max() ?? 0) > 1.5, "nothing is clamped through the pass (\(hotFloats.max() ?? 0) past white)")

    // The pass at a preview's size and at an export's, on the same picture: what the page shows is what the file holds.
    let small = (600, 400), large = (2400, 1600)
    if let s = try? renderer.source(rgba16: smooth(width: small.0, height: small.1), width: small.0, height: small.1),
       let b = try? renderer.source(rgba16: smooth(width: large.0, height: large.1), width: large.0, height: large.1) {
        let a = everything()
        let fs = (try? renderer.floats(s, a)) ?? [], fb = (try? renderer.floats(b, a)) ?? []
        if fs.count == small.0 * small.1 * 4, fb.count == large.0 * large.1 * 4 {
            // The large one at the small one's pixels: each small pixel is the mean of the 4 x 4 it covers.
            var worst: Float = 0, sum: Double = 0
            for y in 0..<small.1 { for x in 0..<small.0 {
                for ch in 0..<3 {
                    var m: Float = 0
                    for dy in 0..<4 { for dx in 0..<4 { m += fb[((y * 4 + dy) * large.0 + x * 4 + dx) * 4 + ch] } }
                    let d = abs(m / 16 - fs[(y * small.0 + x) * 4 + ch])
                    worst = max(worst, d); sum += Double(d)
                }
            } }
            let mean = sum / Double(small.0 * small.1 * 3)
            c.expect(worst < 2e-3 && mean < 2e-4, "a preview's pass and an export's agree: at most \(worst), on average \(String(format: "%.2g", mean)) of full scale")
        } else { c.expect(false, "both sizes ran") }
        // Timing on this Mac, at the page's size: a Mac's number, not a host's.
        if let page = try? renderer.source(rgba16: smooth(width: 1216, height: 912), width: 1216, height: 912) {
            var times: [Double] = []
            for _ in 0..<12 { if let (_, t) = try? renderer.image(page, a) { times.append(t.gpuMilliseconds) } }
            times.sort()
            if c.mutation == .none, !times.isEmpty {
                print("  a pass at 1216 x 912 on this Mac's GPU: \(String(format: "%.2f", times[times.count / 2])) ms (median of \(times.count))")
            }
        }
    }

    // The histogram: of the picture as shown, after the pass.
    if let hs = try? renderer.source(rgba16: smooth(width: 640, height: 480), width: 640, height: 480) {
        let plain = try? renderer.histogram(hs, Adjustments())
        var dark = Adjustments(); dark.exposure = -2
        let darker = try? renderer.histogram(hs, dark)
        let expected = ((640 + 1) / Layer2Renderer.stride(width: 640, height: 480)) * ((480 + 1) / Layer2Renderer.stride(width: 640, height: 480))
        c.expect(plain.map { $0.0.samples } ?? 0 >= expected / 2, "a histogram counts its samples (\(plain.map { $0.0.samples } ?? 0))")
        func meanBin(_ hgram: Layer2Histogram?) -> Double {
            guard let hgram else { return -1 }
            let luma = hgram.counts[768..<1024]
            let total = luma.reduce(0) { $0 + Double($1) }
            return luma.enumerated().reduce(0) { $0 + Double($1.offset) * Double($1.element) } / max(total, 1)
        }
        c.expect(meanBin(darker?.0) < meanBin(plain?.0) - 20, "and moves with the edit: Exposure −2 moves its luma from bin \(Int(meanBin(plain?.0))) to \(Int(meanBin(darker?.0)))")
        c.expect(plain?.0.bins.allSatisfy { (0...1).contains($0) } ?? false && plain?.0.bins.count == 1024, "1,024 bins, each 0…1")
        if c.mutation == .none, let t = plain?.1 { print("  a histogram of 640 x 480 on this Mac's GPU: \(String(format: "%.2f", t)) ms") }
    }
}

@main
struct Layer2SelfTest {
    static func main() {
        let selfTest = CommandLine.arguments.contains("--self-test")
        let result = run(.none)
        print("layer 2 checks: \(result.passed) passed, \(result.failed.count) failed")
        var code: Int32 = result.failed.isEmpty ? 0 : 1
        if selfTest {
            var caught = 0
            for m in Mutation.all {
                // A broken rule that does not reach the source breaks nothing: it is not caught.
                if let k = m.kernel, k(Layer2Kernel.source) == Layer2Kernel.source {
                    print("  NOT APPLIED  \(m.name): the kernels' source has no such line"); continue
                }
                let r = run(m)
                if r.failed.isEmpty { print("  NOT CAUGHT  \(m.name): every check still passed") } else {
                    caught += 1
                    print("  caught  \(m.name): \(r.failed.count) check(s) failed, e.g. \(r.failed[0])")
                }
            }
            print("layer 2 self-test: \(caught) of \(Mutation.all.count) broken rules caught")
            if caught != Mutation.all.count { code = 1 }
        }
        exit(code)
    }
}
