//  HDRGain.swift — one HDR structure for the whole app (2026-11-03): an SDR picture, a per-pixel log2 gain
//  over it, and the headroom the gain is encoded against.
//
//  The owner, 2026-11-03: "one unified HDR structure throughout the app should be coherent and sufficient."
//  The export's ISO gain map, the develop page's canvas, the full-size view and (later) the Light Table all
//  take a frame's HDR in this one shape; what differs between films is only where the gain comes from:
//
//  - **A print, or a negative scanned** (`Source.curve`): the gain is a curve of the SDR picture's own
//    luminance (E3, `HDRCurves` / `HDRGainMap`): a paper's three layers shoulder together, so the luminance
//    is enough (RESEARCH, slides/REPORT.md).
//  - **A slide** (`Source.rendition`): its three dye layers shoulder apart, so the gain is the ratio of two
//    renditions of the same frame by the engine's `scan_hdr` (engine/src/core/scan_hdr.hpp, HANDOFF §6):
//      - the **SDR picture** is the slide's own develop with the stretch (`sdrWire`: the clear base at the
//        page's white, mid-grey untouched, the layers' cast reduced, byte for byte today's below the first
//        knee), so the canvas, the kept render and the file all carry it;
//      - the **HDR rendition** is a second render of the same session with `SlideRendition.delta` — each
//        layer's shoulder moved and lifted inside the scan to `headroom` × the clear base, scaled by
//        `outputScale` so it fits the 16-bit result, with the same grain (`grain_seed`);
//      - the **gain** is `log2(HDR / SDR)` of their luminance, per pixel at full size (the owner: never ¼),
//        8-bit, its top the picture's own largest gain (`ratioMap`, `ratioPlane`). One channel: the v1 of
//        HANDOFF §6.3; the screen lifts the SDR picture's own colour, which already carries the per-layer
//        colour. The slide's `__scan__` curve stays the fallback (a render that could not be made twice).
//
//  **The owner's open choices are assumed here, unconfirmed** (HANDOFF §6 "What the owner decides"):
//  the stretch on for slides (`slideStretch`, off for prints — prints have no stretch), H_content 4 for
//  the export and 2 for a lamp on a screen (`exportHeadroom`, `lampHeadroom`), and a clipped sky lifted
//  (the family-A curve the research recommends; nothing eases it).
//
//  No UIKit, no Metal: the macOS checks compile it.
//
//  **On the Mac** (HDR port, 2026-11-06, D4/D5): the slide's half — the stretched SDR develop (`sdrWire`, sent only when Enable HDR is on for a slide), the second
//  rendition's fields (`rendition`), and the ratio of the two (`ratioMap`, `ratioPlane`). How it is shaped:
//  - **A print's curve is not looked up here.** No bundled curve is chosen between it and a rendition: the
//    curve is the session's own, which the engine says with the
//    develop (`HDRSessionCurve`), so a slide's fallback is that same answer (its film's scan, §19.2). The
//    export's choice (`export(for:format:)`, D8): a map for a JPEG or HEIF of a frame with Enable HDR on and its
//    film applied; a slide's of its second rendition, a print's of its export render's own curve.
//  - **The system's gate, not the screen's** (`HDRGainMap.supported`): a slide's stretch is part of its develop's
//    stamp, and a stamp that followed which screen the window was on would develop the library again each time
//    a display came or went.
//  - The engine's side of the second rendition is `SpkEngine.hdrRendition`, asked by
//    `EngineHost.hdrRendition` only for an export whose request carries `slideHDR` (`EngineRouter.prepareExport`).

import Accelerate
import CoreGraphics
import Foundation

enum HDRGain {
    // MARK: the assumed decisions (unconfirmed; HANDOFF §6)

    /// A slide's SDR picture is stretched when its Enable HDR is on: the clear base at the page's white.
    static let slideStretch = true
    /// H_content of an export's slide rendition: two stops over the clear base.
    static let exportHeadroom = 4.0
    /// H_content for a lamp on a screen (the Light Table's, the canvas's when the lead takes it): one stop.
    static let lampHeadroom = 2.0

    // MARK: the shape

    /// A slide's HDR rendition: what a session holding the frame's SDR develop is sent to render it, and
    /// how its result is read back.
    struct SlideRendition: Equatable, Sendable {
        /// H_content: the rendition's clear base over today's, the map's design headroom over today's white.
        var headroom: Double
        /// The rendition's gain in the result (1/H): the 16-bit result × 1/scale is the rendition.
        var outputScale: Double
        /// The engine's fields: the SDR develop's own with these over them.
        var delta: [String: ParamValue]
        /// The fields the SDR develop had for these, to put the session back.
        var restore: [String: ParamValue]
    }

    // MARK: a frame's

    /// Whether `edit` is a slide whose HDR is its own renditions: Enable HDR on, its film applied and a
    /// slide (scanned, never printed).
    /// Never below macOS 15 (`HDRGainMap.supported`): there no map is written and the frame's switch is greyed, so a
    /// slide that follows Settings' default must not be developed stretched for an HDR it cannot have. Not the
    /// screen's gate (the header): the same edit is the same develop on every Mac.
    static func isSlide(_ edit: FrameEdit, catalog: StockCatalog = .shared) -> Bool {
        edit.hdr && HDRGainMap.supported && edit.appliesFilm && catalog.isSlide(edit.params.filmStock)
    }

    /// The fields a slide's **SDR develop** carries with Enable HDR on (`FrameEdit.engineWire`): the stretch,
    /// and one grain realisation (the frame's own seed) so the HDR rendition's grain is the picture's. Empty
    /// for anything else, so no other frame's wire, stamp or picture moves.
    static func sdrWire(for edit: FrameEdit, catalog: StockCatalog = .shared) -> [String: ParamValue] {
        guard isSlide(edit, catalog: catalog) else { return [:] }
        var wire: [String: ParamValue] = ["grain_seed": .double(Double(grainSeed(edit)))]
        if slideStretch { wire["scan_hdr_stretch"] = .bool(true) }
        return wire
    }

    /// The frame's grain realisation for its two renditions: its seed, never 0 (0 is "a fresh one").
    static func grainSeed(_ edit: FrameEdit) -> Int { max(1, abs(edit.frameSeed) % 2_147_483_647) }

    /// What an export of `edit` in `format` takes (with the session's curve, not a
    /// bundled one): a map, and for a slide the headroom of its second rendition; else none, and why (nil when
    /// HDR is simply off, so the log says nothing of frames that never asked). Not the screen's gate (D5): a
    /// frame with Enable HDR on exports its map wherever the window is. Whether the engine has a curve for it is
    /// known only once its export render has asked (`EngineHost`): a refusal is said there.
    static func export(for edit: FrameEdit, format: ExportRecipe.Format, catalog: StockCatalog = .shared)
        -> (map: Bool, slideHeadroom: Double?, why: String?) {
        guard edit.hdr else { return (false, nil, nil) }
        guard edit.appliesFilm else { return (false, nil, "the film is off") }
        guard format.carriesGainMap else { return (false, nil, "\(format.rawValue) cannot carry a gain map") }
        guard HDRGainMap.supported else { return (false, nil, "gain maps need macOS 15") }
        // A slide edited in Layer 2 takes its curve's map over the edited picture, as a print's and as its canvas
        // draws it (`Layer2Picture`: the session's curve over the edited picture). The ratio of its two renditions
        // is of the picture before Layer 2 (the engine's), so it lifted what the edit had put down: the 2026-11-06
        // review measured a Velvia frame at Layer 2 −2 EV whose mid-greys (Y 0.18–0.30) the file lifted 1.20 stops
        // on average, 89 % of them past a stop, where the canvas lifts none (and the same slide unedited 0.02).
        let slide = isSlide(edit, catalog: catalog) && !edit.adjustments.isActive
        return (true, slide ? edit.hdrHeadroom : nil, nil)
    }

    /// A slide's rendition at `headroom`: the stretch off, the headroom on, scaled to fit. The rest of the
    /// develop (and its grain seed) is the SDR one's.
    static func rendition(for edit: FrameEdit, headroom: Double) -> SlideRendition {
        let h = max(headroom, 1.0001), scale = 1 / h
        return SlideRendition(headroom: h, outputScale: scale,
                              delta: ["scan_hdr_stretch": .bool(false), "scan_hdr_headroom": .double(h),
                                      "scan_hdr_output_scale": .double(scale)],
                              restore: ["scan_hdr_stretch": .bool(slideStretch), "scan_hdr_headroom": .double(0),
                                        "scan_hdr_output_scale": .double(1)])
    }

    // MARK: the ratio of two renditions

    /// The engine's result as the map reads it: RGBA, 16 bits a channel, `stride` pixels a row, in the
    /// engine's working space (ProPhoto RGB, ROMM-encoded: `OutputTransform`'s source).
    struct Pixels {
        var rgba16: UnsafePointer<UInt16>
        var width: Int
        var height: Int
        var stride: Int
    }

    /// ROMM's decode, a 16-bit code to linear (engine/src/core/colour.cpp's `prophoto_decode`).
    static let decode16: [Float] = (0...65535).map { code in
        let v = Double(code) / 65535
        return Float(v < 16.0 / 512.0 ? v / 16.0 : pow(v, 1.8))
    }
    /// ProPhoto RGB's luminance row (D50).
    static let luminance: SIMD3<Float> = [0.2880402, 0.7118741, 0.0000857]
    /// Below this SDR luminance a pixel's ratio is noise in the HDR rendition's few codes: no gain.
    static let floorY: Float = 1e-4

    /// One pixel's gain, HDR over SDR, from the two results' codes; `t` is `decode16`.
    @inline(__always)
    static func gain(_ s: UnsafePointer<UInt16>, _ h: UnsafePointer<UInt16>, invScale: Float,
                     _ t: UnsafePointer<Float>) -> Float {
        let ys = luminance.x * t[Int(s[0])] + luminance.y * t[Int(s[1])] + luminance.z * t[Int(s[2])]
        guard ys > floorY else { return 1 }
        let yh = luminance.x * t[Int(h[0])] + luminance.y * t[Int(h[1])] + luminance.z * t[Int(h[2])]
        return max(1, yh * invScale / ys)
    }

    /// `body` with `decode16` as a pointer (the hot loops read it without bounds checks).
    private static func withTable<R>(_ body: (UnsafePointer<Float>) -> R) -> R {
        decode16.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    /// Rows `0 ..< height` in `chunks` concurrent runs.
    private static func rows(_ height: Int, _ body: (Range<Int>) -> Void) {
        let chunks = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 4))
        let per = (height + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { i in
            let r = min(height, i * per) ..< min(height, (i + 1) * per)
            if !r.isEmpty { body(r) }
        }
    }

    /// The largest gain in the picture, ≤ the rendition's design headroom over the base (a hair over, for
    /// the 16-bit codes). The map's top: its codes span the picture's own range and a screen with less
    /// headroom than that scales the lift down (ISO 21496-1's weight).
    static func peak(sdr: Pixels, hdr: Pixels, rendition: SlideRendition) -> Double {
        let inv = Float(1 / rendition.outputScale), cap = Float(rendition.headroom * 1.05)
        let lock = NSLock()
        var top: Float = 1
        withTable { t in
            rows(sdr.height) { range in
                var local: Float = 1
                for y in range {
                    let s = sdr.rgba16 + y * sdr.stride * 4, h = hdr.rgba16 + y * hdr.stride * 4
                    for x in 0..<sdr.width { local = max(local, gain(s + 4 * x, h + 4 * x, invScale: inv, t)) }
                }
                lock.lock(); top = max(top, local); lock.unlock()
            }
        }
        return Double(min(top, cap))
    }

    /// **The export's map of a slide**: log2(HDR / SDR) a pixel, full size, as the file's 8-bit codes against
    /// the picture's own top (`peak`). Nil when the picture has no gain anywhere (nothing past a knee): a
    /// map of zeros would only cost the file its streaming.
    static func ratioMap(sdr: Pixels, hdr: Pixels, rendition: SlideRendition) throws -> HDRGainMap.Attachment? {
        guard sdr.width == hdr.width, sdr.height == hdr.height else {
            throw HDRGainMap.Failure.gpu("the renditions are \(sdr.width) × \(sdr.height) and \(hdr.width) × \(hdr.height)")
        }
        let top = peak(sdr: sdr, hdr: hdr, rendition: rendition)
        guard top > 1.01 else { return nil }
        let w = sdr.width, inv = Float(1 / rendition.outputScale), scale = Float(255 / log2(top))
        var codes = Data(count: w * sdr.height)
        codes.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self).baseAddress!
            withTable { t in
                rows(sdr.height) { range in
                    for y in range {
                        let s = sdr.rgba16 + y * sdr.stride * 4, h = hdr.rgba16 + y * hdr.stride * 4, o = out + y * w
                        for x in 0..<w {
                            let v = log2(gain(s + 4 * x, h + 4 * x, invScale: inv, t)) * scale
                            o[x] = UInt8(min(255, max(0, v.rounded())))
                        }
                    }
                }
            }
        }
        return HDRGainMap.Attachment(map: HDRGainMap.Map(width: w, height: sdr.height, subsample: 1, codes: codes),
                                     headroom: top)
    }

    /// The same gain as Float log2 a pixel (the canvas's or a check's measure; 4 B a pixel — a screen's
    /// size, never an export's), with its top.
    static func ratioPlane(sdr: Pixels, hdr: Pixels, rendition: SlideRendition) -> HDRGainMap.Plane {
        let w = sdr.width, inv = Float(1 / rendition.outputScale), cap = Float(rendition.headroom * 1.05)
        var values = [Float](repeating: 0, count: w * sdr.height)
        values.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            withTable { t in
                rows(sdr.height) { range in
                    for y in range {
                        let s = sdr.rgba16 + y * sdr.stride * 4, h = hdr.rgba16 + y * hdr.stride * 4
                        for x in 0..<w { base[y * w + x] = log2(min(cap, gain(s + 4 * x, h + 4 * x, invScale: inv, t))) }
                    }
                }
            }
        }
        return HDRGainMap.Plane(width: w, height: sdr.height, subsample: 1, log2Gain: values)
    }

    // MARK: the map follows the picture

    /// A map turned by `quarterTurns` clockwise, by the same vImage turn `EngineHost.turned` gives the
    /// picture (vImage counts anticlockwise).
    static func turned(_ m: HDRGainMap.Map, quarterTurns: Int) throws -> HDRGainMap.Map {
        let k = ((quarterTurns % 4) + 4) % 4
        guard k != 0 else { return m }
        let w = m.width, h = m.height
        let ow = k % 2 == 0 ? w : h, oh = k % 2 == 0 ? h : w
        var out = Data(count: ow * oh)
        var source = m.codes
        let rc = source.withUnsafeMutableBytes { (src: UnsafeMutableRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> vImage_Error in
                var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: ow)
                return vImageRotate90_Planar8(&s, &d, UInt8((4 - k) % 4), 0, vImage_Flags(kvImageNoFlags))
            }
        }
        guard rc == kvImageNoError else { throw HDRGainMap.Failure.gpu("the map could not be turned (\(rc))") }
        return HDRGainMap.Map(width: ow, height: oh, subsample: m.subsample, codes: out)
    }

    /// A map as an 8-bit grey picture over its own codes (no copy), for the picture's own cut
    /// (`FinishedCut.image`), and back.
    static func image(of m: HDRGainMap.Map) -> CGImage? {
        guard let provider = CGDataProvider(data: m.codes as CFData) else { return nil }
        return CGImage(width: m.width, height: m.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: m.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The codes of an 8-bit grey picture (drawn once into a buffer of its size).
    static func map(of image: CGImage, subsample: Int = 1) -> HDRGainMap.Map? {
        let w = image.width, h = image.height
        var codes = Data(count: w * h)
        let drawn = codes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? HDRGainMap.Map(width: w, height: h, subsample: subsample, codes: codes) : nil
    }
}

// MARK: an export's map of a print (the export round, D8)

extension HDRGainMap {
    /// The map of `image` through the session's curve, at full size, as the file's 8-bit codes against its H
    /// (`HDRRendition.codes`: the grain-aware gain the canvas draws, in strips, the map held once at 1 B a pixel).
    static func map(of image: CGImage, curve: HDRSessionCurve) throws -> Map {
        Map(width: image.width, height: image.height, subsample: 1, codes: try HDRRendition.codes(of: image, tables: curve.tables))
    }

    /// An export's map (`EngineHost.deliver`): the curve of the session that developed the picture (`curve`, the
    /// export's own render's answer), for a format that holds one. Nil for PNG and TIFF (ImageIO keeps no map in
    /// either), with no curve, and below macOS 15.
    static func exportAttachment(for image: CGImage, format: ExportRecipe.Format, curve: HDRSessionCurve?) throws -> Attachment? {
        guard let curve, format.carriesGainMap, supported else { return nil }
        return Attachment(map: try map(of: image, curve: curve), headroom: curve.curve.headroom)
    }
}
