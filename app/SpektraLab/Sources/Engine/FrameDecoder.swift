//  FrameDecoder.swift — a picture file, as the engine's frame.
//
//  The engine takes scene-linear float32 in ProPhoto RGB, top row first, in a
//  buffer of its own device (`spk_open_device`). This turns a file into that,
//  holding to what the handoffs measured:
//
//  - **A job below the full tier is decoded no larger than its canvas**
//    (`FrameSource.decode`). Opened whole, a 48 MP photo's 2,400 px preview
//    took 1.1 GB where 0.5 was priced (EngineBench, 2026-10-03).
//  - **A HEIF or a JPEG is reduced by ImageIO** (`CGImageSourceCreateThumbnail`
//    at the size asked): 140-195 MB to open from 12 or from 48 MP, where Core
//    Image's own scale holds the original while it works (428-588 MB from
//    48 MP). The picture's means are within 0.22 % of the original's develop
//    (the same runs). RAM first: this is the cheaper one.
//  - **A RAW is decoded with a linear look**, as the desktop's probe decoder
//    decodes (`probes/decode/dec.swift`): boost, shadow boost, gamut mapping,
//    local tone mapping and extended range off; Apple's own noise reduction
//    and sharpening left as the file has them (the owner: "keep everything
//    as-is"); lens correction only when the frame asks for it.
//  - **A RAW is made smaller by a scale after its decode, never by
//    `scaleFactor`**: under RAW 9 a `scaleFactor` below 1 returned the top-left
//    quarter of an Apple ProRAW at twice the size, and a fractional extent
//    left a bright band at two edges (the handoff of 2026-10-02, §7). The scale
//    is clamped first and cropped to whole pixels after.
//  - **The context's working space has sRGB's primaries** (extended, linear):
//    RAW 9 decoded Bayer files in the wrong colour with any other (the same
//    handoff; measured on Sony and Ricoh files — the reference device's own shots are
//    Bayer DNGs). Half floats in an extended space lose no colour.
//  - **Rendered in bands into the one buffer**, which is what kept Core
//    Image's own peak down (751 MB against 1,334 for a 48 MP ProRAW at
//    2,400 px, on the Mac), each band in its own autorelease pool, and the
//    context's caches cleared when the decode ends: Core Image keeps what it
//    peaked at until then.
//
//  - **A film edge's framing is cut here** (`DecodeAsk.cut`, `HostCut`),
//    after the scale: the engine takes the frame it is handed as the gate,
//    and the host crops first (API-SPEC §15). The decode is no larger for it:
//    the whole picture at the long edge asked, and the cut out of that, which
//    is what the job's canvas was priced from (`FrameEdit.canvas`).
//
//  - **A half-frame pair's piece is composed here** (`decode(_:meter:)`,
//    `PieceAsk`): the one buffer is the piece — new, so black, which is
//    unexposed film — and each picture is decoded and rendered straight into
//    its own hole of it, one picture at a time, Core Image's caches cleared
//    between the two. Nothing holds both decodes at once and nothing is
//    composed twice: the piece costs its buffer and one picture's decode
//    beside it. A picture whose meter has not read yet is read there too —
//    its hole made small (1,024 px at most, as the desktop shows its meter)
//    and handed to the engine's meter alone — and is then exposed by a gain
//    on its own pixels.
//
//  **Not measured on a host yet**: a RAW's small decode (the bench ran HEIF
//  only), and a piece. What these cost is the first thing to read off the job log.
//
//  Every call is on the engine's queue, inside the job's autorelease pool.

#if SPK_ENGINE
import Accelerate
import CoreImage
import Foundation
import ImageIO
import Metal

struct DecodeAsk: Sendable {
    var url: URL
    var isRAW: Bool
    var settings: DecodeSettings
    /// The frame's long edge at most; nil is the file's own size.
    var longEdge: Int?
    /// The host's cut of the picture at that size (a film edge's framing);
    /// nil is the whole picture.
    var cut: Geometry? = nil
    /// A RAW's proxy (`RawProxy`): read where it is, made where it is not, by
    /// any decode no larger than it.
    var proxy: RawProxy.Ask? = nil
}

/// What a decode found out about its file.
struct DecodeReport: Sendable {
    /// The camera's own white balance, read from a RAW's decoder.
    var asShot: (temperature: Double, tint: Double)?
    /// "ImageIO", "Core Image", "RAW 9.dng": how the pixels were made.
    var how: String
    var rawExposure: RawExposureFacts? = nil
    /// The proxy this decode read or wrote.
    var proxy: RawProxy.Event? = nil
}

final class FrameDecoder {
    private let device: MTLDevice
    private var context: CIContext?
    /// Calibrated D50, gamma 1, ProPhoto's primaries: the engine's input space
    /// with no transfer function to undo.
    private let linearProPhoto: CGColorSpace = {
        let d50: [CGFloat] = [0.9642, 1.0, 0.8249], black: [CGFloat] = [0, 0, 0], gamma: [CGFloat] = [1, 1, 1]
        let m: [CGFloat] = [0.7976749, 0.2880402, 0.0, 0.1351917, 0.7118741, 0.0, 0.0313534, 0.0000857, 0.8252100]
        return CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black, gamma: gamma, matrix: m)!
    }()

    init(device: MTLDevice) { self.device = device }

    /// The frame, and what the decode learned. `cancelled` is asked between
    /// bands: a decode of a large file is most of a second.
    func decode(_ ask: DecodeAsk, cancelled: () -> Bool = { false }) throws -> (frame: DecodedFrame, report: DecodeReport) {
        let context = try readied()
        // Core Image keeps what it peaked at until its caches are cleared.
        defer { context.clearCaches() }

        var report = DecodeReport(asShot: nil, how: "")
        var made: CIImage?
        if ask.isRAW, let proxy = ask.proxy, let edge = ask.longEdge, edge <= proxy.longEdge {
            made = try proxied(ask, proxy, with: context, report: &report, cancelled: cancelled)
                .map { RawExposure.scaled($0, toLongEdge: edge) }
        } else {
            made = picture(ask.url, isRAW: ask.isRAW, settings: ask.settings, longEdge: ask.longEdge, report: &report)
        }
        guard var image = made else { throw EngineError.failed("the picture could not be decoded") }
        if let cut = ask.cut { image = HostCut.image(image, by: cut) }

        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw EngineError.failed("the picture is empty") }
        let bytes = w * h * 16
        guard bytes <= device.maxBufferLength, let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw EngineError.resource("no \(bytes >> 20) MB buffer for the decode")
        }
        let placed = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        try render(placed, width: w, height: h, to: buffer.contents(), rowBytes: w * 16, with: context, cancelled: cancelled)
        return (DecodedFrame(buffer: buffer, size: PixelSize(width: w, height: h), channels: 4), report)
    }

    /// A RAW's picture at its proxy's size, from the proxy (`RawProxy`): read
    /// where it is whole; otherwise the RAW decoded at that size, uncut,
    /// rendered once in Core Image's working space, written, and the picture
    /// made of what was written — so the job that makes a proxy sees the same
    /// pixels as every job that reads it. Nil where the RAW cannot be read.
    /// A proxy that cannot be written costs the job nothing: its picture is
    /// still the one rendered.
    private func proxied(_ ask: DecodeAsk, _ proxy: RawProxy.Ask, with context: CIContext,
                         report: inout DecodeReport, cancelled: () -> Bool) throws -> CIImage? {
        if let kept = RawProxy.read(proxy.url) {
            let h = kept.header
            report.how = "proxy " + h.how
            if let t = h.asShotTemperature, let n = h.asShotTint { report.asShot = (t, n) }
            report.rawExposure = h.facts
            report.proxy = RawProxy.Event(url: proxy.url, bytes: Int64(kept.pixels.count), made: false)
            return RawProxy.image(h, pixels: kept.pixels)
        }
        guard let raw = picture(ask.url, isRAW: true, settings: ask.settings, longEdge: proxy.longEdge, report: &report) else {
            return nil
        }
        let extent = raw.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { return nil }
        let rowBytes = w * RawProxy.bytesPerPixel
        var pixels = Data(count: rowBytes * h)
        let placed = raw.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        try pixels.withUnsafeMutableBytes { bytes in
            try render(placed, width: w, height: h, to: bytes.baseAddress!, rowBytes: rowBytes, with: context,
                       format: .RGBAh, colorSpace: RawProxy.workingSpace, cancelled: cancelled)
        }
        // Core Image is done with the RAW: what it held for it goes before the picture is made again.
        context.clearCaches()
        let header = RawProxy.Header(width: w, height: h, how: report.how, asShotTemperature: report.asShot?.temperature,
                                     asShotTint: report.asShot?.tint, facts: report.rawExposure)
        if let bytes = try? pixels.withUnsafeBytes({ try RawProxy.write(header, pixels: $0.baseAddress!, to: proxy.url) }) {
            report.proxy = RawProxy.Event(url: proxy.url, bytes: bytes, made: true)
        }
        return RawProxy.image(header, pixels: pixels)
    }

    /// A piece of film, composed: each picture decoded and rendered into its
    /// own hole of the one buffer, the rest of which is black — unexposed
    /// film. `meter` is the engine's own meter on one picture alone, made
    /// small (`SpkEngine.meterOnQueue`); it is asked only for a picture whose
    /// reading is not kept yet.
    ///
    /// A picture that cannot be decoded fails the piece: a hole that came out
    /// empty without a word would be developed, and exported, as film nobody
    /// exposed.
    func decode(_ piece: PieceAsk, meter: (DecodedFrame, PieceAsk.Picture) throws -> Double,
                cancelled: () -> Bool = { false }) throws -> (frame: DecodedFrame, report: PieceReport) {
        let context = try readied()
        defer { context.clearCaches() }

        let w = piece.size.width, h = piece.size.height
        guard w > 0, h > 0 else { throw EngineError.failed("the piece of film is empty") }
        let bytes = w * h * 16
        // A new buffer is zeros: the film between the holes, and a hole nobody filled.
        guard bytes <= device.maxBufferLength, let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw EngineError.resource("no \(bytes >> 20) MB buffer for the piece of film")
        }
        var report = PieceReport()
        for p in piece.pictures {
            if cancelled() { throw EngineError.cancelled }
            let hole = p.hole.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            let hw = Int(hole.width), hh = Int(hole.height), x0 = Int(hole.minX), y0 = Int(hole.minY)
            guard hw > 0, hh > 0 else { continue }
            var read = DecodeReport(asShot: nil, how: "")
            guard let image = picture(p.url, isRAW: p.isRAW, settings: p.settings, longEdge: p.longEdge, report: &read) else {
                throw EngineError.failed("the \(p.index == 0 ? "first" : "second") frame's picture could not be decoded")
            }
            report.how.append(read.how)
            let placed = PiecePlacer.place(image, cut: p.cut, quarterTurns: p.quarterTurns, window: p.window,
                                           size: CGSize(width: hw, height: hh))
            let origin = buffer.contents() + (y0 * w + x0) * 16
            try render(placed, width: hw, height: hh, to: origin, rowBytes: w * 16, with: context, cancelled: cancelled)
            // One picture's decode at a time: this one's is given back before the next is made.
            context.clearCaches()

            let stops: Double
            switch p.exposure {
            case .own(let own):
                stops = own
            case .metered(let reading, let plus, let key):
                var ev = reading
                if ev == nil {
                    let chosen = try meter(try small(origin, width: hw, height: hh, rowBytes: w * 16), p)
                    report.readings.append((p.index, chosen, key))
                    ev = chosen
                }
                stops = (ev ?? 0) + plus
            }
            report.stops[p.index] = stops
            if stops != 0 {
                // A plain gain on the picture's own pixels, as the engine's meter is (2^EV).
                var gain = Float(pow(2.0, stops))
                for row in 0..<hh {
                    let pixels = (origin + row * w * 16).assumingMemoryBound(to: Float.self)
                    vDSP_vsmul(pixels, 1, &gain, pixels, 1, vDSP_Length(hw * 4))
                }
            }
        }
        return (DecodedFrame(buffer: buffer, size: PixelSize(width: w, height: h), channels: 4), report)
    }

    private func readied() throws -> CIContext {
        if context == nil {
            context = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .highQualityDownsample: true])
        }
        guard let context else { throw EngineError.failed("no Core Image context") }
        return context
    }

    /// A file as a picture no larger than `longEdge`: the recipe, with nothing
    /// rendered yet. Nil when the file cannot be read as a picture.
    private func picture(_ url: URL, isRAW: Bool, settings: DecodeSettings, longEdge: Int?, report: inout DecodeReport) -> CIImage? {
        if isRAW {
            guard let prepared = RawExposure.prepare(url, settings: settings, longEdge: longEdge) else { return nil }
            report.asShot = prepared.asShot
            report.rawExposure = prepared.facts
            report.how = prepared.how
            return prepared.image
        }
        if let edge = longEdge, !isRAW {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: edge,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            report.how = "ImageIO"
            return CIImage(cgImage: small)
        }
        report.how = "Core Image"
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// `image` — its extent at the origin, `w` by `h` — into pixels whose rows
    /// are `rowBytes` apart and whose first row is the picture's top: the
    /// whole of a buffer, or one hole of a piece's. About four megapixels a
    /// band, each in its own autorelease pool. Core Image's y runs upward, so
    /// band b (rows r0..<r1) is the image's rows h-r1..<h-r0.
    private func render(_ image: CIImage, width w: Int, height h: Int, to base: UnsafeMutableRawPointer, rowBytes: Int,
                        with context: CIContext, format: CIFormat = .RGBAf, colorSpace: CGColorSpace? = nil,
                        cancelled: () -> Bool) throws {
        let bands = max(1, Int((Double(w) * Double(h) / 4_000_000).rounded(.up)))
        for b in 0..<bands {
            if cancelled() { throw EngineError.cancelled }
            autoreleasepool {
                let r0 = h * b / bands, r1 = h * (b + 1) / bands
                context.render(image, toBitmap: base + r0 * rowBytes, rowBytes: rowBytes,
                               bounds: CGRect(x: 0, y: h - r1, width: w, height: r1 - r0),
                               format: format, colorSpace: colorSpace ?? linearProPhoto)
            }
        }
    }

    /// One hole of a piece as a frame of its own, 1,024 px at most on its long
    /// edge: what the engine's meter is shown (the desktop's
    /// `PairComposer.meterImage`). Scaled from the pixels already rendered —
    /// the picture is not decoded a second time for its meter.
    private func small(_ pixels: UnsafeMutableRawPointer, width w: Int, height h: Int, rowBytes: Int) throws -> DecodedFrame {
        let k = min(1, 1024 / Double(max(w, h)))
        let sw = max(Int((Double(w) * k).rounded()), 1), sh = max(Int((Double(h) * k).rounded()), 1)
        guard let buffer = device.makeBuffer(length: sw * sh * 16, options: .storageModeShared) else {
            throw EngineError.resource("no buffer for the meter's picture")
        }
        var source = vImage_Buffer(data: pixels, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        var target = vImage_Buffer(data: buffer.contents(), height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: sw * 16)
        let rc = vImageScale_ARGBFFFF(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
        guard rc == kvImageNoError else { throw EngineError.failed("the meter's picture could not be made (\(rc))") }
        return DecodedFrame(buffer: buffer, size: PixelSize(width: sw, height: sh), channels: 4)
    }

}
#endif
