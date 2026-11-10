//  HDRLook.swift — a frame's HDR (its curve) and the page's picture of it (`HDRRendition.make`).
//
//  The look is the frame's Enable HDR and its session's curve (`HDRSessionCurve`, the engine's, carried with
//  the develop); the picture is the SDR picture through `HDRRendition`'s kernels at the screen's share. Apart
//  from HDRRendition.swift so the kernels' checks compile without the edit's model. No UIKit.
//
//  2026-11-06, D6. On the Mac: the curve is handed in (`of(_:_:)`, the page's answer), never read from the bundle by name; the
//  look needs a screen that can show HDR (`FeatureFlags.screenShowsHDR`, any of the Mac's) besides the system's
//  gate (`HDRGainMap.supported`), the two held apart; and the colour space a page's HDR picture is
//  drawn in is taken from a 4 × 4 gain-mapped HEIF written here with `HDRGainMap.attach` (`hdrSpace`), not
//  through `ExportWriter`, whose map writing is the export round's.

import CoreGraphics
import Foundation
import ImageIO
import Metal

/// What a picture's HDR is made of: its gain curve and the kernels' tables, the session's (`HDRSessionCurve`).
/// One per frame on a page (`FrameEdit.hdr` and its develop's answer).
struct HDRLook: Hashable, Sendable {
    let curve: HDRGainCurve
    /// The kernels' tables for this look: the engine's, of the session.
    let tables: HDRGrainGain.Tables

    init(_ session: HDRSessionCurve) {
        curve = session.curve
        tables = session.tables
    }
    init(curve: HDRGainCurve, tables: HDRGrainGain.Tables) {
        self.curve = curve
        self.tables = tables
    }
    static func == (a: HDRLook, b: HDRLook) -> Bool { a.curve.name == b.curve.name && a.curve.headroom == b.curve.headroom }
    func hash(into h: inout Hasher) { h.combine(curve.name); h.combine(curve.headroom) }

    /// Whether a page keeps showing the rendition it made with `shown` while the one of `look` is made: whenever
    /// there is a look (`HDRImage`, `HDRPlacedImage`). Held to `shown == look` it would suit a curve that is a file per film
    /// and paper; the Mac's is the session's and moves with the edit — a Couplers step moved its tables 0.01–0.03
    /// stop, a film format 0.001 (the 2026-11-06 review, the engine's own curve) — so equality dropped the canvas
    /// to SDR, and a zoomed tile to nothing, on every such step until the new rendition came. A held rendition is
    /// always replaced: by the next one made, or by the SDR picture where it fails or the look goes.
    static func keeps(_ shown: HDRLook?, for look: HDRLook?) -> Bool { shown != nil && look != nil }

    /// The frame's look on a page: Enable HDR on, its film applied, a system that writes maps and a screen of
    /// the Mac's that shows HDR, and a curve the engine gave for its session (`answer`); nil otherwise — the
    /// page's pictures are SDR, as they always were.
    static func of(_ edit: FrameEdit, _ answer: HDRSessionCurve.Answer?) -> HDRLook? {
        guard edit.hdr, edit.appliesFilm, HDRGainMap.supported, FeatureFlags.screenShowsHDR, let c = answer?.curve else { return nil }
        return HDRLook(c)
    }

    /// The screen's share of the curve (ISO 21496-1's weight, `w`), for a screen `headroom` over SDR white.
    func weight(headroom: Double) -> Double {
        let top = log2(max(curve.headroom, 1.0001))
        return min(1, max(0, log2(max(headroom, 1)) / top))
    }


    /// Where SDR white falls on the picture's own axis: the encoded value (0 … 1, the histogram's) whose
    /// pixels this look at `weight` lifts to exactly SDR white. Pixels above it end in the HDR range; under
    /// it they are brightened, or not, but stay SDR. Taken at a smooth tone (grain's own term averages out);
    /// nil when nothing reaches white below 1 (no lift at this weight).
    func sdrWhiteCrossing(weight: Double) -> Double? {
        let t = tables, w = min(1, max(0, weight))
        guard w > 0 else { return nil }
        /// log2 of a tone's HDR value over SDR white: its own log2 Y plus the weighted gain.
        func over(_ l: Double) -> Double { l + w * HDRGrainGain.log2Gain(l2y: l, local: l, tables: t) }
        var lo = -12.0, hi = -0.0001
        guard over(hi) > 0, over(lo) < 0 else { return nil }
        for _ in 0..<40 { let m = (lo + hi) / 2; if over(m) > 0 { hi = m } else { lo = m } }
        let y = exp2((lo + hi) / 2)
        // The histogram's axis is the picture as encoded (Display P3, sRGB's transfer).
        return y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
    }
}

extension HDRRendition {
    /// `image` through `look` at the screen's share `weight` (0 … 1): half-float linear extended Display P3,
    /// the picture's own size, its grain measured for σ.
    /// - `display`: true (a page's) gives the picture in UIKit's own HDR form (`display(_:headroom:)`), which a
    ///   page draws as HDR; false gives the linear half floats (the histogram's counts, the checks).
    static func make(_ image: CGImage, look: HDRLook, weight: Double, display: Bool = false,
                     device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws -> CGImage {
        gate.lock(); defer { gate.unlock() }
        guard let device else { throw Failure.gpu("no Metal device") }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let out = device.makeBuffer(length: w * h * 8, options: .storageModeShared) else { throw Failure.gpu("no room for a \(w) × \(h) picture") }
        let peak = pow(max(look.curve.headroom, 1), min(1, max(0, weight)))
        if display { pageMakes &+= 1 }
        // A page's: UIKit's HDR form made on the GPU (`hg_apply_pq`), in the space ImageIO's own decode gives.
        if display, #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *), let space = hdrSpace {
            try run(image, tables: look.tables, sigma: pageSigma(image, look), into: .pq(out, weight: weight), device: device)
            let held = Unmanaged.passRetained(out as AnyObject)
            guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: w * h * 8,
                                                releaseData: { info, _, _ in Unmanaged<AnyObject>.fromOpaque(info!).release() })
            else { held.release(); throw Failure.gpu("no data provider") }
            guard let made = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw Failure.gpu("no image") }
            return CGImageCreateCopyWithContentHeadroom(Float(peak), made) ?? made
        }
        try run(image, tables: look.tables, sigma: pageSigma(image, look), into: .edr(out, weight: weight), device: device)
        // The image keeps the output buffer alive and gives it back when it goes: no second copy.
        let held = Unmanaged.passRetained(out as AnyObject)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: w * h * 8,
                                            releaseData: { info, _, _ in Unmanaged<AnyObject>.fromOpaque(info!).release() })
        else { held.release(); throw Failure.gpu("no data provider") }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let made = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                                 space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, bitmapInfo: info,
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw Failure.gpu("no image") }
        // Its headroom said (macOS 15): the picture's own peak, H^w. Without it a page may take the extended values
        // for an SDR picture's and hold them at white (2026-11-03: the canvas "still felt like the old fallback"
        // while its numbers were the export's to the stop).
        if display, let shown = displayed(made, headroom: peak) { return shown }
        return made
    }

    /// **UIKit's own HDR form.** 2026-11-03: the linear half-float picture, even marked with its headroom,
    /// is `isHighDynamicRange == false` to UIKit, so a page drew it as an SDR picture held at white — the
    /// canvas "felt like the old fallback" while its numbers were the export's. What UIKit does take for HDR is
    /// what ImageIO's own HDR decode of a gain-mapped file gives: BT.2020 primaries, PQ, Apple's adaptive gain
    /// curve, SDR white at 203 nits, with its content headroom. So the picture is drawn into that very colour
    /// space — taken once from a decode of a 4 × 4 gain-mapped HEIF made here, as ImageIO makes it — and marked
    /// with its peak. Nil before macOS 15 or where the space cannot be had (the linear picture is shown).
    static func displayed(_ linear: CGImage, headroom: Double) -> CGImage? {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *), let space = hdrSpace else { return nil }
        let w = linear.width, h = linear.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(linear, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let made = ctx.makeImage() else { return nil }
        return CGImageCreateCopyWithContentHeadroom(Float(headroom), made) ?? made
    }

    /// The colour space ImageIO's HDR decode gives a gain-mapped picture on this system (see `displayed`).
    static let hdrSpace: CGColorSpace? = {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) else { return nil }
        let n = 4
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        guard let base = ctx.makeImage() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spk-hdr-space-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }
        let map = HDRGainMap.Map(width: n, height: n, subsample: 1, codes: Data(repeating: 255, count: n * n))
        // Written as an export writes its map (`HDRGainMap.attach` after the image), with no `ExportWriter` of ours.
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        }
        CGImageDestinationAddImage(dest, base, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard (try? HDRGainMap.attach(.init(map: map, headroom: 4), to: dest)) != nil, CGImageDestinationFinalize(dest),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let hdr = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
              let space = hdr.colorSpace, CGColorSpaceUsesITUR_2100TF(space)
        else { return CGColorSpace(name: CGColorSpace.itur_2100_PQ) }
        return space
    }()

    /// The Swift reference of a flat field's pixel (its local tone its own, so the grain term is 0): linear P3
    /// out for 8-bit P3 in. The histogram's and the checks' on uniform patches.
    static func reference(_ px: SIMD3<UInt8>, look: HDRLook, weight: Double) -> SIMD3<Double> {
        let l = SIMD3(HDRMath.decode(Double(px.x) / 255), HDRMath.decode(Double(px.y) / 255), HDRMath.decode(Double(px.z) / 255))
        let ly = HDRGrainGain.l2y(HDRMath.luminance(l.x, l.y, l.z))
        let lg = HDRGrainGain.log2Gain(l2y: ly, local: ly, tables: look.tables)
        return l * exp2(min(1, max(0, weight)) * lg)
    }

    /// How many page renditions (`display`) this process has made, for the log's `hdr picture` line: one a picture
    /// and a curve, none thrown away (the 2026-11-06 review). Inside `gate`.
    nonisolated(unsafe) static var pageMakes = 0

    /// A page's σ, measured once for a look at a size: a slider's next picture is the same grain (2026-11-03: the
    /// measure was most of a debug build's second). Inside `gate`.
    nonisolated(unsafe) private static var sigmas: [String: Double] = [:]
    static func pageSigma(_ image: CGImage, _ look: HDRLook) -> Double {
        let key = "\(look.curve.name)/\(image.width)x\(image.height)"
        if let s = sigmas[key] { lastTimes["sigma_ms"] = 0; return s }
        let t0 = Date()
        let s = HDRGrainGain.sigma(for: image)
        lastTimes["sigma_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        if sigmas.count > 32 { sigmas.removeAll() }
        sigmas[key] = s
        return s
    }
}
