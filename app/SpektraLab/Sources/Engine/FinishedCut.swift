//  FinishedCut.swift — Edit's crop, made of an export's finished picture.
//
//  Edit's crop (`FrameEdit.printCrop`, 2026-10-20) is a cut of the picture as
//  it finishes: the develop, in its film edge if it has one, with Edit's layer
//  baked on, turned by the host. So it is made last, of the picture that would
//  otherwise be the file (`EngineHost.deliver`), with the same arithmetic as
//  every crop (`Geometry.outputToSourceTransform`). It never reaches the
//  engine: nothing is developed for it.
//
//  - **A plain cut is no copy**: with no straighten, turn or flip the file is
//    the picture's own pixels, `CGImage.cropping(to:)`.
//  - **Anything else is drawn once**, into a picture of the cut's size, at the
//    picture's own depth and in its own colour space — whole pixels where the
//    map is whole (a turn, a flip), a high-quality resample where it is
//    straightened. That is one more picture of at most the file's size, for as
//    long as the file takes to write. **Not measured on a host**, and not in
//    the scheduler's price of the job (the engine's buffers are given back by
//    then, but the delivered picture is still held).
//
//  Any thread. No engine and no UIKit: `tools/crop_selftest.swift` runs it on
//  a Mac against a picture whose every pixel says where it came from.

import CoreGraphics
import Foundation

enum FinishedCut {
    enum Failure: Error, Equatable { case notMade(String) }

    /// `image` through `g` — the cut is `g.outputSize(for:)` of the picture's
    /// own size, exactly.
    static func image(_ image: CGImage, by g: Geometry) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard !g.isIdentity else { return image }
        let out = g.outputSize(for: size)
        let ow = Int(out.width), oh = Int(out.height)
        let toSource = g.outputToSourceTransform(imageSize: size)
        if g.angle == 0, ((g.quarterTurns % 4) + 4) % 4 == 0, !g.flipH, !g.flipV {
            // The cut's top-left on the picture, held inside it.
            let x = min(max(Int(toSource.tx.rounded()), 0), max(image.width - ow, 0))
            let y = min(max(Int(toSource.ty.rounded()), 0), max(image.height - oh, 0))
            if let cut = image.cropping(to: CGRect(x: x, y: y, width: ow, height: oh)), cut.width == ow, cut.height == oh {
                return cut
            }
        }
        guard let ctx = context(like: image, width: ow, height: oh) else {
            throw Failure.notMade("no room to cut the picture (\(ow) x \(oh))")
        }
        ctx.interpolationQuality = g.angle == 0 ? .none : .high
        // Output pixels with a top-left origin, as the map has them.
        ctx.translateBy(x: 0, y: CGFloat(oh))
        ctx.scaleBy(x: 1, y: -1)
        // The picture's pixels → the cut's. A whole map is held to whole pixels.
        var toCut = toSource.inverted()
        if g.angle == 0 {
            toCut.a = toCut.a.rounded(); toCut.b = toCut.b.rounded(); toCut.c = toCut.c.rounded(); toCut.d = toCut.d.rounded()
            toCut.tx = toCut.tx.rounded(); toCut.ty = toCut.ty.rounded()
        }
        ctx.concatenate(toCut)
        // Core Graphics draws a picture upright in a y-up space: turned over once more.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        guard let made = ctx.makeImage() else { throw Failure.notMade("the cut picture could not be made") }
        return made
    }

    /// A drawing of the picture's own depth and space: its own pixel layout
    /// where Core Graphics draws into that, else the nearest it does.
    private static func context(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let bits = image.bitsPerComponent == 16 ? 16 : 8
        let layouts: [UInt32] = [
            image.bitmapInfo.rawValue,
            bits == 16 ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                       : CGImageAlphaInfo.noneSkipLast.rawValue,
            CGImageAlphaInfo.noneSkipLast.rawValue,
            CGImageAlphaInfo.premultipliedLast.rawValue,
        ]
        for layout in layouts {
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                   space: space, bitmapInfo: layout) { return ctx }
        }
        return nil
    }
}
