//  CropMaskedThumbnail.swift — a frame's thumbnail the way Capture One draws
//  it: the whole photograph, with everything outside the crop under a dark,
//  nearly opaque mask, turned and flipped the way the canvas is.
//
//  The user's decision (2026-09-26), for the filmstrip and the export page's
//  cells: show the full picture but make the crop the thing you see. The
//  navigator is different on purpose — it is a map of the canvas, so it shows
//  the cropped frame only (`NavigatorSection.frame`).
//
//  The thumbnail itself stays the uncropped print (`ThumbnailCache`): the
//  mask is drawn over it here, per cell, from the frame's own geometry —
//  the live one for the open frame, the saved one for every other
//  (`Session.thumbnailGeometry(for:)`).

import SwiftUI

enum CropMask {
    /// How much of the outside the mask hides. "Very non-transparent": the
    /// cropped-away part is still legible as context, and no more.
    static let opacity: CGFloat = 0.82

    /// `image` with the outside of `geometry`'s crop masked, then turned and
    /// flipped as the canvas turns and flips it. An identity geometry returns
    /// the image itself.
    static func masked(_ image: CGImage, by geometry: Geometry) -> CGImage {
        guard !geometry.isIdentity else { return image }
        var composite = image
        if !(geometry.crop.isFull && geometry.angle == 0),
           let drawn = drawMask(over: image, geometry: geometry) {
            composite = drawn
        }
        // The turns and flips, through the navigator's drawing with a full,
        // level crop — so the orientation arithmetic exists once.
        var orient = Geometry()
        orient.quarterTurns = geometry.quarterTurns
        orient.flipH = geometry.flipH
        orient.flipV = geometry.flipV
        return NavigatorSection.frame(composite, by: orient) ?? composite
    }

    private static func drawMask(over image: CGImage, geometry: Geometry) -> CGImage? {
        let w = image.width, h = image.height
        let size = CGSize(width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? ImageDecoder.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: ImageDecoder.displayP3,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        // The crop's corners are normalised with a top-left origin; the
        // context's is bottom-left.
        let corners = geometry.corners(in: size).map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        path.addLines(between: corners)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: opacity))
        ctx.fillPath(using: .evenOdd)
        return ctx.makeImage()
    }
}

/// Loads a frame's thumbnail, keeps it current, and hands the cell the
/// crop-masked picture. The three cells that show a frame's thumbnail — the
/// filmstrip's and the export page's two — all go through this, so none of
/// them can show the frame differently from the others.
struct CropMaskedThumbnail<Content: View>: View {
    let url: URL
    let geometry: Geometry
    var maxPixel: Int = 320
    @ViewBuilder let content: (CGImage?) -> Content

    @State private var raw: CGImage?
    @State private var shown: CGImage?

    private struct Key: Equatable {
        let image: ObjectIdentifier?
        let geometry: Geometry
    }

    var body: some View {
        content(shown ?? raw)
            .task(id: url) { raw = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel) }
            .task(id: Key(image: raw.map(ObjectIdentifier.init), geometry: geometry)) {
                shown = raw.map { CropMask.masked($0, by: geometry) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
                guard (n.object as? URL) == url else { return }
                Task { raw = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel) }
            }
    }
}
