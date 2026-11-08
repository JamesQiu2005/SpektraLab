//  FrameView.swift — a frame as it is shown: its picture, through its crop.
//
//  Wherever a frame's picture is drawn — a library tile, the top frame, the
//  develop page's canvas, an export's thumbnail — it is drawn through the
//  frame's geometry, so the crop is the same everywhere and one arithmetic
//  decides it (`Geometry.outputToSourceTransform`, the desktop's). A frame
//  with no crop is just its picture.
//
//  A frame the engine has developed shows that develop (`LibraryFrame.developed`),
//  which comes back from the engine already cut; the cut below is for a frame
//  that has none yet — its camera's own preview — and for *Original*.
//
//  The decode is `ThumbnailStore`'s: at the size shown, never larger.

import SwiftUI
import UIKit

struct FrameView: View {
    let frame: LibraryFrame
    /// The long edge it is drawn at, in points.
    let pointSize: CGFloat
    var contentMode: ContentMode = .fill
    /// A geometry to draw through in place of the frame's own: the develop
    /// session's, which is ahead of the library while a control moves.
    var geometry: Geometry? = nil
    /// The frame as decoded, before the film (develop's *Original*). Falls back
    /// to the developed picture when there is no original to show.
    var showsOriginal = false

    var body: some View {
        let g = geometry ?? frame.pictureGeometry
        let picture = showsOriginal ? (frame.originalPicture ?? frame.picture) : frame.picture
        if !showsOriginal, let developed = frame.shownDevelop {
            // The engine's develop: already cut, so nothing cuts it again. With
            // Edit's layer on it, its edited copy (`Layer2Copies`). One whose
            // file is missing (`DevelopedPicture.isMissing`) is drawn as no
            // develop is, from the camera's preview, until it is made again.
            let shown = FramePicture(picture: Layer2Copies.shared.served(frame) ?? developed.picture, pointSize: pointSize, contentMode: contentMode)
            if frame.edit.printCrop.isIdentity || frame.isPair || developed.size.width <= 0 {
                shown
            } else {
                // Edit's crop, of the finished picture (2026-10-20).
                let base = CGSize(width: developed.size.width, height: developed.size.height)
                GeometryPicture(geometry: frame.edit.printCrop.onFinished(base), imageSize: base, contentMode: contentMode) { points in
                    FramePicture(picture: Layer2Copies.shared.served(frame) ?? developed.picture,
                                 pointSize: max(points, pointSize), contentMode: .fit)
                }
            }
        } else if g.isIdentity {
            FramePicture(picture: picture, pointSize: pointSize, contentMode: contentMode)
        } else {
            CroppedPicture(picture: picture, pointSize: pointSize, contentMode: contentMode, geometry: g,
                           sourceSize: CGSize(width: frame.originalSize.width, height: frame.originalSize.height))
        }
    }
}

/// A picture drawn through a crop, a straighten, quarter turns and flips.
struct CroppedPicture: View {
    let picture: PictureRef
    let pointSize: CGFloat
    var contentMode: ContentMode = .fill
    let geometry: Geometry
    /// The source's size, in the units the geometry was made in (pixels).
    let sourceSize: CGSize

    @Environment(\.displayScale) private var scale
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var image: UIImage?

    /// The decode has to cover the crop, not the whole source: a quarter of the
    /// frame shown at 393 pt needs the source at twice that.
    private var maxPixel: Int? {
        let zoom = 1 / max(min(geometry.crop.width, geometry.crop.height), 0.1)
        return PictureLoading.maxPixel(points: pointSize, scale: scale, zoom: min(zoom, 4))
    }

    var body: some View {
        // Read here and not inside the drawing. A Canvas is drawn again when its
        // view is made again, and the view is made again when something `body`
        // read has changed: read only in the closure, a decode that landed after
        // the first draw left the tile blank (the first frame in *Pair With*,
        // presented over a develop page as a cover left: the tour, 2026-10-10).
        let shown = image ?? ThumbnailStore.shared.cachedAny(picture) ?? (isSnapshot ? maxPixel.flatMap { ThumbnailStore.shared.load(picture, maxPixel: $0) } : nil)
        Group {
            if geometry.hasPerspective {
                // Vertical and Horizontal are no affine map: the picture is put in
                // place by a projection instead (`GeometryPicture`), the same one
                // the crop page draws with.
                GeometryPicture(geometry: geometry, imageSize: sourceSize, contentMode: contentMode) { _ in
                    if let shown { Image(uiImage: shown).resizable() } else { Theme.plot }
                }
            } else {
                flat(shown)
            }
        }
        .background(Theme.plot)
        .clipped()
        .task(id: "\(picture)-\(maxPixel ?? 0)") {
            guard !isSnapshot, let maxPixel else { return }
            // The picture shown stays until the one for this size lands.
            if let made = await PictureLoading.picture(picture, maxPixel: maxPixel) { image = made }
        }
    }

    private func flat(_ shown: UIImage?) -> some View {
        Canvas { ctx, size in
            guard let shown else { return }
            let out = geometry.outputSize(for: sourceSize)
            let sx = size.width / out.width, sy = size.height / out.height
            let s = contentMode == .fill ? max(sx, sy) : min(sx, sy)
            // output pixels -> the view, centred
            ctx.translateBy(x: (size.width - out.width * s) / 2, y: (size.height - out.height * s) / 2)
            ctx.scaleBy(x: s, y: s)
            if contentMode == .fit { ctx.clip(to: Path(CGRect(origin: .zero, size: out))) }
            // source pixels -> output pixels
            ctx.concatenate(geometry.outputToSourceTransform(imageSize: sourceSize).inverted())
            ctx.draw(Image(uiImage: shown), in: CGRect(origin: .zero, size: sourceSize))
        }
    }
}

/// How a page's picture is asked for and shown: `FramePicture`,
/// `CroppedPicture` and a film's canvas (`FilmCanvasView`) alike.
///
/// **A cold start's soft picture** (the tester, 2026-10-15: "冷启动会出现画面
/// 模糊"). At a cold launch the Library's top frame is laid out first at no
/// size and then at its own: the first asked for a 64 px decode, the second
/// for 1,088 (the simulator's log, 2026-10-15: "ask 64 pt 0.0", then "ask
/// 1088 pt 357.3"). Both decodes ran, and whichever landed last was put on the
/// page — the 64 px one too, although its asking had been replaced and its
/// task cancelled ("landed 64 cancelled true"). It stayed there until the
/// frame changed. In the simulator the small one landed first; on a host the
/// two are full decodes of the same HEIC side by side, and nothing kept the
/// small one from landing last. Not seen on a host. So: **nothing is decoded
/// for a size before there is one**, and **a decode for a size the page no
/// longer asks for never lands**.
@MainActor
enum PictureLoading {
    /// The pixels a long edge of `points` asks for at this scale and zoom,
    /// rounded up to a step of 64 so nearby sizes share one decode. Nil before
    /// anything is laid out: nothing is decoded for no size.
    static func maxPixel(points: CGFloat, scale: CGFloat, zoom: CGFloat = 1) -> Int? {
        let px = points * scale * zoom
        guard px >= 1 else { return nil }
        return max(64, Int((px / 64).rounded(.up)) * 64)
    }

    /// The picture at that size: the cache's at once, else decoded off the
    /// main thread. Nil when there is none — and when the page asked for
    /// another size, or another picture, while this one was decoded: the task
    /// that asked has been cancelled, and what it decoded is not put up.
    static func picture(_ picture: PictureRef, maxPixel: Int) async -> UIImage? {
        if let hit = ThumbnailStore.shared.cached(picture, maxPixel: maxPixel) { return hit }
        let made = await ThumbnailStore.shared.image(picture, maxPixel: maxPixel)
        guard !Task.isCancelled, let made else { return nil }
        return made
    }
}
