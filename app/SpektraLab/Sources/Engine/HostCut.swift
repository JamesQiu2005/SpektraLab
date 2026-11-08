//  HostCut.swift — the host's own cut of a decode, for a film edge.
//
//  The engine takes the frame it is handed as the gate: it lays the film out
//  from that frame's shape, and sets the film's millimetres from its long
//  edge **before** any cut of its own (`film_prefix`: "the pitch is the
//  pre-crop long edge's"). So with a film edge the picture is cut here, in the
//  decode, and the wire carries no cut at all (`EngineWire`): "the host crops
//  first" (API-SPEC §15), as the desktop does (`Session+FilmEdge`).
//
//  **The cut is the model's own map** from the cut's pixels to the picture's
//  (`Geometry.outputToSourceTransform`, which is `sourcePoint(forOutput:)` as
//  one affine map): what the page's guide draws the picture through, so the
//  engine is handed what the guide showed — the crop, the straighten, the
//  photo's own turns and flips, and the film's half turn carried back
//  (`FrameEdit.hostCut`).
//
//  - **With no straighten nothing is resampled.** The map is then a move, a
//    quarter turn or a flip, so it is held to whole pixels and kept inside
//    the picture: every pixel of the cut is a pixel of the decode.
//  - **With a straighten the picture is resampled once**, by Core Image.
//  - **The picture's edge is repeated past it**, so a cut a rounding wider
//    than the picture has no dark sliver.
//  - **A perspective (Vertical, Horizontal: 2026-10-20) is re-projected
//    first**, by Core Image, at the picture's own size (`corrected`); the cut
//    above is then made in that corrected frame, as the crop page made it.
//    Without a film edge this is all the host does — the engine cuts the rest
//    (`FrameEdit.hostCut`); for an export it is the whole cut (`ExportPlan`).
//
//  No engine in here, and no Metal: `tools/selftest.sh` runs it on a Mac
//  against a picture whose every pixel says where it came from
//  (`tools/host_cut_selftest.swift`).

import CoreGraphics
import CoreImage

enum HostCut {
    /// The cut of a picture `size` pixels large: how large it comes out — a
    /// gate's size (`Geometry.gateSize`) — and where each of its pixels is in
    /// the picture. Both with a top-left origin, in pixels.
    static func map(_ g: Geometry, imageSize size: CGSize) -> (size: CGSize, toSource: CGAffineTransform) {
        let out = g.gateSize(for: size)
        var toSource = g.outputToSourceTransform(imageSize: size)
        guard g.angle == 0 else { return (out, toSource) }
        // A move, a quarter turn, a flip: whole pixels, and none past the picture's edge.
        toSource.a = toSource.a.rounded(); toSource.b = toSource.b.rounded()
        toSource.c = toSource.c.rounded(); toSource.d = toSource.d.rounded()
        toSource.tx = toSource.tx.rounded(); toSource.ty = toSource.ty.rounded()
        let box = CGRect(origin: .zero, size: out).applying(toSource)
        if box.width <= size.width { toSource.tx -= min(box.minX, 0) + max(box.maxX - size.width, 0) }
        if box.height <= size.height { toSource.ty -= min(box.minY, 0) + max(box.maxY - size.height, 0) }
        return (out, toSource)
    }

    /// The picture through the cut. Core Image's y runs upward and the map's
    /// downward, so the map is turned over on both sides of itself.
    static func image(_ image: CIImage, by g: Geometry) -> CIImage {
        let whole = image.extent.integral
        let size = CGSize(width: whole.width, height: whole.height)
        var picture = image.transformed(by: .init(translationX: -whole.origin.x, y: -whole.origin.y))
        // Vertical and Horizontal first: the crop below is made in the
        // corrected frame, which has the picture's own size (`Keystone`).
        if g.hasPerspective { picture = corrected(picture, by: g, size: size) }
        // The perspective alone (`FrameEdit.hostCut` with no film edge): the engine cuts the rest.
        if g.hasPerspective, g.perspectiveOnly == g { return picture.cropped(to: CGRect(origin: .zero, size: size)) }
        let (out, toSource) = map(g, imageSize: size)
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)
        let toCut = flipSource.concatenating(toSource.inverted()).concatenating(flipOut)
        return picture.clampedToExtent()
            .transformed(by: toCut).cropped(to: CGRect(origin: .zero, size: out))
    }

    /// The picture re-projected by its perspective (`Geometry.keystone`), at
    /// its own size: one resample, by Core Image, the source's four corners
    /// taken to where the keystone puts them. A homography is fixed by four
    /// points, so this is the keystone exactly. The corrected frame lies
    /// inside the re-projected picture (`Keystone.fill`), so nothing of it is
    /// empty; its edge is repeated past it for the cut's rounding.
    static func corrected(_ image: CIImage, by g: Geometry, size: CGSize) -> CIImage {
        let ks = g.keystone(in: size)
        guard !ks.isIdentity else { return image }
        // Core Image's y runs upward.
        func up(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: size.height - p.y) }
        let filter = CIFilter(name: "CIPerspectiveTransform")
        filter?.setValue(image.cropped(to: CGRect(origin: .zero, size: size)), forKey: kCIInputImageKey)
        filter?.setValue(up(ks.corrected(CGPoint(x: 0, y: 0))), forKey: "inputTopLeft")
        filter?.setValue(up(ks.corrected(CGPoint(x: size.width, y: 0))), forKey: "inputTopRight")
        filter?.setValue(up(ks.corrected(CGPoint(x: size.width, y: size.height))), forKey: "inputBottomRight")
        filter?.setValue(up(ks.corrected(CGPoint(x: 0, y: size.height))), forKey: "inputBottomLeft")
        guard let made = filter?.outputImage else { return image }
        return made.cropped(to: CGRect(origin: .zero, size: size)).clampedToExtent()
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}
