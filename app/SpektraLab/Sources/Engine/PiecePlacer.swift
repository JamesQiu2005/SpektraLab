//  PiecePlacer.swift — one picture, as it lies under its hole on a piece of film.
//
//  A half-frame pair's pictures are moved under their holes by the host
//  (`PieceComposer.swift`, `FrameDecoder.decode(_:meter:)`): the picture as its
//  frame's owner cut it, turned by the placement's quarter turns, and the
//  placement's window of that scaled into the hole. The desktop's
//  `PairComposer.place`.
//
//  No engine in here and no Metal — Core Image, `Geometry` and `HostCut`: on a
//  Mac `tools/selftest.sh` puts a picture whose every pixel says where it came
//  from under holes of every placement, and holds each pixel of the hole
//  against the pair's own answer for it (`HalfFramePair.sourceRect`,
//  `tools/piece_selftest.swift`).

import CoreGraphics
import CoreImage

enum PiecePlacer {
    /// A picture — a decode, whole — as it lies under a hole `size` pixels
    /// large: cut as its frame is cut (`HostCut`), turned by `quarterTurns`
    /// clockwise, and `window` of that scaled to the hole. The result's
    /// extent is the hole's, at the origin.
    ///
    /// The scale is taken before the last crop, from a picture whose edge is
    /// repeated past it: cropped first, the hole's outer pixels would be mixed
    /// with nothing and come out dark.
    static func place(_ image: CIImage, cut: Geometry, quarterTurns: Int, window: CGRect, size: CGSize) -> CIImage {
        var picture = HostCut.image(image, by: cut)
        let framed = picture.extent.size
        // Whole quarter turns as exact maps: no pixel is resampled by a turn.
        // Core Image's y runs upward, so clockwise as seen is (x, y) → (y, W − x).
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: picture = picture.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: framed.width))
        case 2: picture = picture.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: framed.width, ty: framed.height))
        case 3: picture = picture.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: framed.height, ty: 0))
        default: break
        }
        let turned = picture.extent.size
        let shown = self.shown(window, of: turned)
        // The window with a bottom-left origin, as Core Image has it.
        let x = shown.minX, y = turned.height - shown.maxY
        return picture.clampedToExtent()
            .transformed(by: .init(translationX: -x, y: -y))
            .transformed(by: .init(scaleX: size.width / shown.width, y: size.height / shown.height))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// `window` of a picture `turned` pixels large, in its pixels with a
    /// top-left origin: inside the picture, and never thinner than a pixel.
    static func shown(_ window: CGRect, of turned: CGSize) -> CGRect {
        let w = max(min(window.width, 1) * turned.width, 1), h = max(min(window.height, 1) * turned.height, 1)
        let x = min(max(window.minX * turned.width, 0), max(turned.width - w, 0))
        let y = min(max(window.minY * turned.height, 0), max(turned.height - h, 0))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
