//  DoubleGuideLight.swift — a double exposure's guide, as light is added (RFC-047 §5.1).
//
//  Until the engine has developed it, a double exposure's tile and darkroom show its **guide**: the two
//  photographs' own previews, each laid on the frame as its exposure lies (`DoubleExposure.guideLayers`:
//  its cut, its turns, its window, its flip), each multiplied by its exposure's light and the two **added
//  in linear light** — two exposures on one frame of film add, they do not cover each other. The pair's
//  `PairGuide` lays its frames side by side over dark film; this adds them over no light at all.
//
//  This file is the drawing alone, Core Image with `PiecePlacer` and `HostCut`, and no file: on a Mac
//  `tools/double_selftest.swift` adds two flat pictures and reads each pixel back against the arithmetic
//  (sRGB decoded, scaled, summed, encoded again). Reading the previews and writing the guide's file are
//  `DoubleGuide.write` (`DoubleKeeping.swift`).
//
//  **Linear light** is Core Image's own working space, held here rather than left to the default:
//  extended linear sRGB. A preview tagged sRGB is decoded into it when it is read, `CIColorMatrix` scales
//  it, the blend adds, and the context encodes the sum as sRGB once, as it is written. A sum past white is
//  clipped there, as an over-exposed print is; the guide is no measurement of the develop.
//
//  **The addition is `CILinearDodgeBlendMode`, not the `CIAdditionCompositing` RFC-047 §5.1 named.**
//  Measured on this Mac (macOS 27.0.1, 2026-11-07): `CIAdditionCompositing` adds the premultiplied
//  components, alpha too, so two opaque pictures make an alpha of 2 — sRGB 0.5 at half its light over
//  black read back as 131 of 255 where the arithmetic says 92. `CILinearDodgeBlendMode` is the same sum
//  of the colours, composited so that opaque over opaque stays opaque: 92 over black, 128 for two of them
//  (0.107 + 0.107 linear), and sRGB 0.5 and 0.8 at half each 172 where the arithmetic says 171.3. The
//  selftest holds those pixels, and goes red for the other filter.

import CoreGraphics
import CoreImage

/// A double exposure before the engine has developed it: its two photographs' own previews, added.
enum DoubleGuide {
    /// The filter that adds one exposure's light to the frame's (see the head of this file).
    static let addition = "CILinearDodgeBlendMode"

    /// The guide of `double` at `size`: `pictures` are each exposure's own preview, whole and uncut, by
    /// position (an exposure with none is left out, as an empty layer is). `framed` is each exposure's
    /// picture as its cut frames it at its own develop size — the frame's shape and each window are read
    /// from it, not from the previews. Nil with nothing to lay. `addition` is the selftest's, so that its
    /// broken rule can put `CIAdditionCompositing` back and see the pixels go wrong; the app never passes it.
    static func added(_ double: DoubleExposure, framed: DoubleExposure.Framed, pictures: [DoubleExposure.Position: CIImage],
                      size: CGSize, addition: String = DoubleGuide.addition) -> CIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let frame = CGRect(origin: .zero, size: size)
        // Unexposed film: no light, opaque.
        var sum = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: frame)
        var any = false
        for layer in double.guideLayers(framed) {
            guard let e = double[layer.position], let picture = pictures[layer.position] else { continue }
            var placed = PiecePlacer.place(picture, cut: e.cut, quarterTurns: layer.quarterTurns, window: layer.window, size: size)
            // The flip mirrors the window's content, not the window (`DoubleExposure.Placement`): the
            // window was mirrored, so the picture cut by it is mirrored back about the frame's middle.
            if layer.flipped { placed = placed.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
            let g = CGFloat(layer.gain)
            let lit = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            sum = lit.applyingFilter(addition, parameters: [kCIInputBackgroundImageKey: sum]).cropped(to: frame)
            any = true
        }
        return any ? sum : nil
    }

    /// The context a guide is drawn by: linear light, no cache kept between guides (the pair's own).
    static func context() -> CIContext {
        var options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) { options[.workingColorSpace] = linear }
        return CIContext(options: options)
    }
}
