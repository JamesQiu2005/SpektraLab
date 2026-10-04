//  PairComposer.swift — a half-frame pair as one decode.
//
//  Two frames laid on 37 mm of film: each picture under its 18 × 24 hole, the
//  gap between them black (no light reached it). The result is an ordinary
//  `DecodedImage`, so everything after the decode — the engine, the canvas,
//  the thumbnail, the export — handles a pair as it handles a frame.
//
//  **Each frame is the frame as its owner left it**: its own white balance
//  and lens correction, and its own crop, turn and flips (`Hole.geometry`).
//  A frame turned by itself is turned in the pair.
//
//  **Each hole is rendered once.** A RAW through Core Image costs about a
//  second at this size, and a pair is edited by small steps — the spacing,
//  the other hole, an exposure, the film edge — none of which changes this
//  hole's pixels. So a hole's picture is rendered to a bitmap at the hole's
//  own size and kept (`rendered`), keyed on everything that makes it; a step
//  that leaves the key alone composes from the bitmap. The canvas's preview
//  is the files' embedded previews, which need no demosaic at all.
//
//  An empty hole is black too: unexposed film, which the engine develops to
//  the stock's own base. It is never painted.

import CoreImage
import Foundation
import ImageIO

enum PairComposer {
    /// The pair at `url` as a decode. A hole whose file is gone, or will not
    /// decode, is an empty hole rather than a failed pair.
    static func decode(_ url: URL, checkpoint: () throws -> Void = {}) throws -> DecodedImage {
        guard let pair = HalfFramePair.load(url) else { throw ImageDecoder.Failure.unsupported(url) }
        struct Source { let hole: HalfFramePair.Hole; let decoded: DecodedImage; let framed: CGSize }
        var sources: [HalfFramePair.Side: Source] = [:]
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], hole.exists else { continue }
            try checkpoint()
            // A recipe, not pixels: the RAW is not demosaiced until something renders it.
            guard let d = try? ImageDecoder.decode(hole.url, settings: hole.decode, checkpoint: checkpoint)
            else { continue }
            sources[side] = Source(hole: hole, decoded: d, framed: hole.geometry.outputSize(for: d.pixelSize))
            shots.set(Shot(isRAW: d.isRAW, lensCorrectionSupported: d.lensCorrectionSupported,
                           asShotTemperature: d.asShotTemperature, asShotTint: d.asShotTint), for: hole.path)
        }
        let layout = layout(for: pair, sizes: sources.mapValues(\.framed))
        let full = CGRect(origin: .zero, size: layout.size)
        var linear = CIImage(color: .black).cropped(to: full)
        var display = CIImage(color: .black).cropped(to: full)
        for side in HalfFramePair.Side.allCases {
            guard let s = sources[side] else { continue }
            try checkpoint()
            let rect = layout.rect(side)
            let rectCI = CGRect(x: rect.minX, y: layout.size.height - rect.maxY, width: rect.width, height: rect.height)
            let key = renderKey(s.hole, size: s.decoded.pixelSize, hole: layout.hole, aspect: pair.holeAspect)
            let picture: CIImage
            if let kept = rendered.image(for: key) {
                picture = kept
            } else {
                let framed = Session.engineImage(s.decoded.linear, size: s.decoded.pixelSize, cut: s.hole.geometry)
                let placed = place(framed, size: s.framed, placement: s.hole.placement,
                                   into: CGRect(origin: .zero, size: layout.hole),
                                   pieceHeight: layout.hole.height, aspect: pair.holeAspect)
                picture = render(placed, size: layout.hole) ?? placed
                rendered.keep(picture, for: key)
            }
            linear = picture.transformed(by: .init(translationX: rectCI.minX, y: rectCI.minY)).composited(over: linear)
            // The preview: the file's own embedded picture, framed and placed
            // the same way. The decode's display rendering is the fallback.
            let shown = embeddedPreview(s.hole.url, maxPixel: 2560)
            let shownSize = shown?.extent.size ?? s.decoded.pixelSize
            let shownFramed = Session.engineImage(shown ?? s.decoded.display, size: shownSize, cut: s.hole.geometry)
            display = place(shownFramed, size: s.hole.geometry.outputSize(for: shownSize), placement: s.hole.placement,
                            into: rect, pieceHeight: layout.size.height, aspect: pair.holeAspect)
                .composited(over: display)
        }
        return DecodedImage(linear: linear.cropped(to: full), display: display.cropped(to: full),
                            pixelSize: layout.size, isRAW: false, sourceURL: url,
                            sourceEXIF: (sources[.left] ?? sources[.right])?.decoded.sourceEXIF,
                            asShotTemperature: nil, asShotTint: nil)
    }

    /// The piece's pixel layout. The holes are as large as the smaller of the
    /// two pictures is across its hole, so neither is enlarged -- and the
    /// piece is never longer than the longer picture: two half frames are
    /// one frame's worth of film, and a pair of 45 MP frames laid out at
    /// their own size was an 83 MP piece (127 MP with its film edge). An
    /// empty pair takes a nominal size. `sizes` are the frames as framed
    /// (after their own crop and turn).
    static func layout(for pair: HalfFramePair, sizes: [HalfFramePair.Side: CGSize]) -> HalfFramePair.Layout {
        var across: [CGFloat] = [], longest: CGFloat = 0
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], let size = sizes[side] else { continue }
            // At the picture's own fit, whatever it is zoomed to: a zoom must
            // not resize the piece (the canvas would refit on every notch and
            // the other frame would be rendered again at the new size).
            let turned = HalfFramePair.turned(size, by: hole.placement)
            var fit = hole.placement
            fit.scale = 1
            let cut = HalfFramePair.sourceRect(for: fit, source: turned, aspect: pair.holeAspect)
            across.append(pair.turned ? cut.width : cut.height)
            longest = max(longest, size.width, size.height)
        }
        var a = across.min() ?? 2400
        if longest > 0 {
            // At the camera's own 1 mm, whatever the spacing: a hole's size
            // must not move with the gap, or widening it renders both again.
            let pieceLong = (HalfFramePair.holeMM.along * 2 + 1) / HalfFramePair.holeMM.across
            a = min(a, longest / pieceLong)
        }
        return HalfFramePair.layout(holeHeight: Int(a.rounded(.down)), spacingMM: pair.effectiveSpacingMM,
                                    turned: pair.turned)
    }

    /// `image` (its extent `size`, wherever its origin) turned, cut to the
    /// placement's rectangle and scaled into `hole` — a top-left rectangle on
    /// a piece `pieceHeight` tall, placed in Core Image's bottom-left space.
    static func place(_ image: CIImage, size: CGSize, placement: HalfFramePair.Placement,
                      into hole: CGRect, pieceHeight: CGFloat,
                      aspect: Double = HalfFramePair.holeMM.along / HalfFramePair.holeMM.across) -> CIImage {
        var img = image.transformed(by: .init(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        var turnedSize = size
        let turns = ((placement.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            // Clockwise as seen (Core Image's y runs up, so the angle is negative).
            img = img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(turns)))
            img = img.transformed(by: .init(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
            turnedSize = HalfFramePair.turned(size, by: placement)
        }
        let cut = HalfFramePair.sourceRect(for: placement, source: turnedSize, aspect: aspect)       // y down
        let cutCI = CGRect(x: cut.minX, y: turnedSize.height - cut.maxY, width: cut.width, height: cut.height)
        let scale = hole.height / max(cut.height, 1)
        let holeCI = CGRect(x: hole.minX, y: pieceHeight - hole.maxY, width: hole.width, height: hole.height)
        return img.clampedToExtent()
            .cropped(to: cutCI)
            .transformed(by: .init(translationX: -cutCI.minX, y: -cutCI.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
            .transformed(by: .init(translationX: holeCI.minX, y: holeCI.minY))
            .cropped(to: holeCI)
    }

    // MARK: - the shot behind a hole

    /// What a frame's own file is, as its decode found it. The piece is not a
    /// RAW and has no camera white balance; each of its frames may be and
    /// does, and the rail's white balance and lens correction are about the
    /// picked frame — so they ask here.
    struct Shot: Sendable {
        let isRAW: Bool
        let lensCorrectionSupported: Bool
        let asShotTemperature: Double?
        let asShotTint: Double?
    }

    final class Shots: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Shot] = [:]
        func set(_ shot: Shot, for path: String) { lock.withLock { known[path] = shot } }
        func shot(for path: String) -> Shot? { lock.withLock { known[path] } }
    }
    static let shots = Shots()

    // MARK: - a hole, rendered once

    /// Everything a hole's pixels are made of. Not where the hole sits, how
    /// the other one is filled, or how either is exposed: those compose.
    static func renderKey(_ hole: HalfFramePair.Hole, size: CGSize, hole target: CGSize, aspect: Double) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: hole.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let d = hole.decode, g = hole.geometry, p = hole.placement
        return [hole.path, String(stamp), String((attributes?[.size] as? Int) ?? 0),
                d.whiteBalance.rawValue, String(d.temperature), String(d.tint), String(d.lensCorrection),
                "\(g.crop.x),\(g.crop.y),\(g.crop.width),\(g.crop.height),\(g.angle),\(g.quarterTurns),\(g.flipH),\(g.flipV)",
                "\(p.scale),\(p.x),\(p.y),\(p.quarterTurns)",
                "\(Int(size.width))x\(Int(size.height))", "\(Int(target.width))x\(Int(target.height))",
                String(aspect)].joined(separator: "|")
    }

    /// `image` (extent at the origin, `size` large) as pixels: half-float,
    /// linear ProPhoto — the engine's own space, so handing it on later is a
    /// copy. Nil when it cannot be made, and the caller keeps the recipe.
    static func render(_ image: CIImage, size: CGSize) -> CIImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let space = ImageDecoder.linearProPhoto else { return nil }
        let rowBytes = w * 8
        guard let bytes = malloc(rowBytes * h) else { return nil }
        autoreleasepool {
            ImageDecoder.context.render(image, toBitmap: bytes, rowBytes: rowBytes,
                                        bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                        format: .RGBAh, colorSpace: space)
        }
        let data = Data(bytesNoCopy: bytes, count: rowBytes * h, deallocator: .free)
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: w, height: h),
                       format: .RGBAh, colorSpace: space)
    }

    /// The rendered holes: a few, most recent first. Two for the pair on the
    /// canvas and one spare, so swapping a frame back in is free.
    final class Rendered: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: String, image: CIImage)] = []
        var capacity = 3

        func image(for key: String) -> CIImage? {
            lock.withLock {
                guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
                let hit = entries.remove(at: i)
                entries.insert(hit, at: 0)
                return hit.image
            }
        }

        func keep(_ image: CIImage, for key: String) {
            lock.withLock {
                entries.removeAll { $0.key == key }
                entries.insert((key, image), at: 0)
                if entries.count > capacity { entries.removeLast(entries.count - capacity) }
            }
        }

        func removeAll() { lock.withLock { entries.removeAll() } }
        var count: Int { lock.withLock { entries.count } }
    }
    static let rendered = Rendered()

    /// The file's embedded preview, turned as the file says. A RAW carries a
    /// full-size JPEG; a flat file is scaled down by ImageIO.
    static func embeddedPreview(_ url: URL, maxPixel: Int) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        return CIImage(cgImage: image)
    }

    // MARK: - exposure

    /// `piece` with each hole's exposure applied: its picture multiplied by
    /// 2^EV. The engine's own meter is exactly this gain on the frame it is
    /// handed (measured: the two renders are equal to the last code), so a
    /// strip developed with the meter off and these gains exposes each hole
    /// as the meter would have exposed it alone.
    static func exposed(_ piece: CIImage, layout: HalfFramePair.Layout,
                        stops: [HalfFramePair.Side: Double]) -> CIImage {
        guard stops.values.contains(where: { $0 != 0 }) else { return piece }
        let origin = piece.extent.origin
        var out = piece
        for (side, ev) in stops where ev != 0 {
            let r = layout.rect(side)
            let rectCI = CGRect(x: origin.x + r.minX, y: origin.y + layout.size.height - r.maxY,
                                width: r.width, height: r.height)
            let g = CGFloat(pow(2.0, ev))
            let gained = piece.cropped(to: rectCI).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            ]).cropped(to: rectCI)
            out = gained.composited(over: out)
        }
        return out.cropped(to: piece.extent)
    }

    /// One hole of the piece, alone and small: what the meter is shown.
    static func meterImage(_ piece: CIImage, layout: HalfFramePair.Layout, side: HalfFramePair.Side,
                           maxEdge: CGFloat = 1024) -> CIImage {
        let origin = piece.extent.origin
        let r = layout.rect(side)
        let rectCI = CGRect(x: origin.x + r.minX, y: origin.y + layout.size.height - r.maxY,
                            width: r.width, height: r.height)
        let scale = min(1, maxEdge / max(r.width, r.height))
        return piece.cropped(to: rectCI)
            .transformed(by: .init(translationX: -rectCI.minX, y: -rectCI.minY))
            .transformed(by: .init(scaleX: scale, y: scale))
    }

    /// A frame as the hole's crop sees it — its embedded preview, framed by
    /// its own geometry and turned by its placement — for the picture a crop
    /// gesture shows while it is in flight. Kept: a gesture asks for it again
    /// on every start.
    static func framedPreview(_ hole: HalfFramePair.Hole, maxPixel: Int = 2048) -> CGImage? {
        let g = hole.geometry
        let key = "\(hole.path)|\(g.crop.x),\(g.crop.y),\(g.crop.width),\(g.crop.height),\(g.angle),"
            + "\(g.quarterTurns),\(g.flipH),\(g.flipV)|\(hole.placement.quarterTurns)|\(maxPixel)" as NSString
        if let kept = previews.object(forKey: key) { return kept.image }
        guard let ci = embeddedPreview(hole.url, maxPixel: maxPixel) else { return nil }
        var img = Session.engineImage(ci, size: ci.extent.size, cut: hole.geometry)
        let turns = ((hole.placement.quarterTurns % 4) + 4) % 4
        if turns != 0 { img = img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(turns))) }
        guard let cg = ImageDecoder.context.createCGImage(img, from: img.extent.integral) else { return nil }
        previews.setObject(Preview(cg), forKey: key)
        return cg
    }

    private final class Preview { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    nonisolated(unsafe) private static let previews: NSCache<NSString, Preview> = {
        let c = NSCache<NSString, Preview>(); c.countLimit = 4; return c
    }()

    /// The pair's filmstrip thumbnail before anything is rendered: the two
    /// frames' own previews, framed and placed, the gap and an empty hole dark.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let pair = HalfFramePair.load(url) else { return nil }
        let layout = HalfFramePair.layout(holeHeight: max(maxPixel * 24 / 37, 24), spacingMM: pair.effectiveSpacingMM,
                                          turned: pair.turned)
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], let ci = embeddedPreview(hole.url, maxPixel: maxPixel * 2) else { continue }
            let size = ci.extent.size
            let framed = Session.engineImage(ci, size: size, cut: hole.geometry)
            let placed = place(framed, size: hole.geometry.outputSize(for: size), placement: hole.placement,
                               into: layout.rect(side), pieceHeight: layout.size.height, aspect: pair.holeAspect)
            let r = layout.rect(side)
            let rectCI = CGRect(x: r.minX, y: layout.size.height - r.maxY, width: r.width, height: r.height)
            guard let cg = ImageDecoder.context.createCGImage(placed, from: rectCI) else { continue }
            ctx.draw(cg, in: rectCI)
        }
        return ctx.makeImage()
    }
}
