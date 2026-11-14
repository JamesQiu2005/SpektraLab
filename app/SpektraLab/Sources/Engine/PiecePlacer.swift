//  PiecePlacer.swift — one picture, as it lies under its hole on a piece of film.
//
//  A half-frame pair's pictures are moved under their holes by the host
//  (`PieceComposer.swift`, `FrameDecoder.decode(_:meter:)`): the picture as its
//  frame's owner cut it, turned by the placement's quarter turns, and the
//  placement's window of that scaled into the hole. The desktop's
//  `PairComposer.place`.
//
//  **A double exposure's picture is placed the same way, over the whole frame**
//  (RFC-048 §2), with two steps a pair never asks for, both exact maps and
//  neither resampling a pixel:
//
//  - a **horizontal flip** after the quarter turns and before the window, so
//    the window's fractions mean the same with or without it, and a flipped
//    window selects the mirrored region (`DoubleExposure.Placement.flipped`);
//  - a **turn of the placed picture** (`turnedAfter`) for a frame whose film
//    edge is turned half round: the frame goes to the engine turned back and
//    its canvas is turned forward after, as a photograph's is
//    (`FrameEdit.hostCut`, `EngineHost.Request.turnsAfter`).
//
//  With both at their defaults this is the pair's placing, unchanged.
//
//  No engine in here and no Metal — Core Image, `Geometry` and `HostCut`: on a
//  Mac `tools/selftest.sh` puts a picture whose every pixel says where it came
//  from under holes of every placement, and holds each pixel of the hole
//  against the pair's own answer for it (`HalfFramePair.sourceRect`,
//  `tools/piece_selftest.swift`), flipped and turned after too.

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
    ///
    /// `flipped` mirrors the turned picture across before the window is taken
    /// (a double exposure's flip). `turnedAfter` turns the placed picture that
    /// many quarter turns clockwise, and `size` is then the hole as it lies
    /// after that turn. Both default to the pair's way.
    static func place(_ image: CIImage, cut: Geometry, quarterTurns: Int, window: CGRect, size: CGSize,
                      flipped: Bool = false, turnedAfter: Int = 0) -> CIImage {
        var picture = turn(HostCut.image(image, by: cut), quarterTurns)
        if flipped {
            // Across, about the turned picture's own middle: x to W - x, exactly.
            let e = picture.extent
            picture = picture.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.minX + e.maxX, ty: 0))
        }
        let turned = picture.extent.size
        let shown = self.shown(window, of: turned)
        // The window with a bottom-left origin, as Core Image has it.
        let x = shown.minX, y = turned.height - shown.maxY
        // The hole before the turn after: an odd turn swaps its sides.
        let after = ((turnedAfter % 4) + 4) % 4
        let hole = after % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
        let placed = picture.clampedToExtent()
            .transformed(by: .init(translationX: -x, y: -y))
            .transformed(by: .init(scaleX: hole.width / shown.width, y: hole.height / shown.height))
            .cropped(to: CGRect(origin: .zero, size: hole))
        return after == 0 ? placed : turn(placed, after)
    }

    /// Whole quarter turns, clockwise as seen, as exact maps: no pixel is
    /// resampled by a turn. The picture's extent is at the origin, as
    /// `HostCut.image` and a placed hole both make it. Core Image's y runs
    /// upward, so clockwise as seen is (x, y) to (y, W - x).
    static func turn(_ picture: CIImage, _ quarterTurns: Int) -> CIImage {
        let framed = picture.extent.size
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return picture.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: framed.width))
        case 2: return picture.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: framed.width, ty: framed.height))
        case 3: return picture.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: framed.height, ty: 0))
        default: return picture
        }
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
