//  PairComposer.swift — a half-frame pair as one decode.
//
//  Two frames laid on 37 mm of film: each picture under its 18 × 24 hole, the
//  gap between them black (no light reached it). The result is an ordinary
//  `DecodedImage`, so everything after the decode — the engine, the canvas,
//  the thumbnail, the export — handles a pair as it handles a frame. Core
//  Image only, as the rest of the intake is: nothing is rendered here, the
//  images are recipes.
//
//  An empty hole is black too: unexposed film, which the engine develops to
//  the stock's own base. It is never painted.

import CoreImage
import Foundation
import ImageIO

enum PairComposer {
    /// One hole's picture, decoded: what `ImageDecoder` made of the frame.
    struct Part {
        let linear: CIImage
        let display: CIImage
        let size: CGSize
        let exif: [CFString: Any]?
    }

    /// The pair at `url` as a decode. Each frame is decoded with its own
    /// settings (the shot stays the frame's); a hole whose file is gone
    /// decodes as empty rather than failing the pair.
    static func decode(_ url: URL, checkpoint: () throws -> Void = {}) throws -> DecodedImage {
        guard let pair = HalfFramePair.load(url) else { throw ImageDecoder.Failure.unsupported(url) }
        var parts: [HalfFramePair.Side: Part] = [:]
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], hole.exists else { continue }
            try checkpoint()
            guard let d = try? ImageDecoder.decode(hole.url, settings: hole.decode, checkpoint: checkpoint)
            else { continue }
            parts[side] = Part(linear: d.linear, display: d.display, size: d.pixelSize, exif: d.sourceEXIF)
        }
        let layout = layout(for: pair, sizes: parts.mapValues(\.size))
        let linear = compose(pair, parts.mapValues { ($0.linear, $0.size) }, layout: layout)
        let display = compose(pair, parts.mapValues { ($0.display, $0.size) }, layout: layout)
        return DecodedImage(linear: linear, display: display, pixelSize: layout.size, isRAW: false,
                            sourceURL: url, sourceEXIF: (parts[.left] ?? parts[.right])?.exif,
                            asShotTemperature: nil, asShotTint: nil)
    }

    /// The piece's pixel layout: the holes are as tall as the smaller of the
    /// two pictures is across its hole, so neither is enlarged. An empty pair
    /// takes a nominal size.
    static func layout(for pair: HalfFramePair, sizes: [HalfFramePair.Side: CGSize]) -> HalfFramePair.Layout {
        let heights = HalfFramePair.Side.allCases.compactMap { side -> CGFloat? in
            guard let hole = pair[side], let size = sizes[side] else { return nil }
            let turned = HalfFramePair.turned(size, by: hole.placement)
            return HalfFramePair.sourceRect(for: hole.placement, source: turned).height
        }
        let h = Int((heights.min() ?? 2400).rounded(.down))
        return HalfFramePair.layout(holeHeight: h, spacingMM: pair.effectiveSpacingMM)
    }

    /// Both pictures under their holes, over black, `layout.size` large with
    /// its origin at zero.
    static func compose(_ pair: HalfFramePair, _ images: [HalfFramePair.Side: (CIImage, CGSize)],
                        layout: HalfFramePair.Layout) -> CIImage {
        let full = CGRect(origin: .zero, size: layout.size)
        var out = CIImage(color: .black).cropped(to: full)
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], let (image, size) = images[side] else { continue }
            let placed = place(image, size: size, placement: hole.placement, into: layout.rect(side),
                               pieceHeight: layout.size.height)
            out = placed.composited(over: out)
        }
        return out.cropped(to: full)
    }

    /// `image` (its extent `size`, wherever its origin) turned, cut to the
    /// placement's rectangle and scaled into `hole` — a top-left rectangle on
    /// a piece `pieceHeight` tall, placed in Core Image's bottom-left space.
    static func place(_ image: CIImage, size: CGSize, placement: HalfFramePair.Placement,
                      into hole: CGRect, pieceHeight: CGFloat) -> CIImage {
        var img = image.transformed(by: .init(translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        var turnedSize = size
        let turns = ((placement.quarterTurns % 4) + 4) % 4
        if turns != 0 {
            // Clockwise as seen (Core Image's y runs up, so the angle is negative).
            img = img.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2 * CGFloat(turns)))
            img = img.transformed(by: .init(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
            turnedSize = HalfFramePair.turned(size, by: placement)
        }
        let cut = HalfFramePair.sourceRect(for: placement, source: turnedSize)       // y down
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

    /// The pair's filmstrip thumbnail before anything is rendered: the two
    /// frames' own previews under their holes, the gap and an empty hole dark.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let pair = HalfFramePair.load(url) else { return nil }
        let layout = HalfFramePair.layout(holeHeight: max(maxPixel * 24 / 37, 24), spacingMM: pair.effectiveSpacingMM)
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side], let src = CGImageSourceCreateWithURL(hole.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel * 2,
                      kCGImageSourceShouldCache: false,
                  ] as CFDictionary) else { continue }
            let ci = CIImage(cgImage: image)
            let placed = place(ci, size: ci.extent.size, placement: hole.placement, into: layout.rect(side),
                               pieceHeight: layout.size.height)
            let r = layout.rect(side)
            let rectCI = CGRect(x: r.minX, y: layout.size.height - r.maxY, width: r.width, height: r.height)
            guard let cg = ImageDecoder.context.createCGImage(placed, from: rectCI) else { continue }
            ctx.draw(cg, in: rectCI)
        }
        return ctx.makeImage()
    }
}
