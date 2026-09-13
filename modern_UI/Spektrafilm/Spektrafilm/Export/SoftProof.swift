//  SoftProof.swift — the picture an export recipe will actually write.
//
//  RFC-018 §5.5. This file is *the seam* between the two halves of RFC-018:
//  the render path, which learns to convert per destination, and the export
//  page, which shows the result. Both were built against this API at the same
//  time, on separate branches, which is only possible because the API landed
//  before either of them did.
//
//  **The body is now the real transform.** It was the placeholder — a Display
//  P3 render converted by Core Graphics, which clips out-of-gamut colour
//  rather than compressing it, and which is RFC-018 §4.4. It now runs the
//  *same* chain the export runs, through the same kernel, with the same
//  uniforms and the same destination resolved by the same function: grade in
//  the working space, frame, size, then one output transform into the
//  recipe's space. That identity is the whole claim of the type — a proof that
//  went through the canvas path and was relabelled would prove nothing, and
//  RFC-018 §7.6 is the check that it did not.

import CoreGraphics
import Foundation
import Metal

/// One rendered proof, in the destination's own colour space.
///
/// `image` is tagged with `target` and carries the destination's pixels, not
/// the canvas's: that is the whole claim of the type. A proof that went
/// through the canvas path and was relabelled would prove nothing, and
/// `RFC-018 §7.6` is the check that it did not.
struct SoftProof: @unchecked Sendable {
    let image: CGImage
    let target: CGColorSpace
    /// What to call the space in front of a person — the catalogue's name for
    /// it, not `CGColorSpace`'s identifier.
    let targetName: String
    /// **The file's** pixel size — not the proof's, which is smaller by
    /// design. The two travel separately so the page can state both without
    /// implying they are the same number; `image.width` is the proof's.
    let exportPixelSize: CGSize
    /// Pixels the gamut mapping moved, 0…1. The destination could not hold
    /// them at their original chroma and they were rolled in.
    ///
    /// That sentence is the definition, and it is what this carries: the
    /// fraction of pixels whose chroma exceeded the destination's cube
    /// (`OutputTransformStats.outsideFraction`). RFC-018 §5.3 describes the
    /// kernel's counter as `d > threshold`, which at the session's default
    /// knee is a different and much larger number — "the knee acted", which is
    /// every pixel with any chroma, measured at 1.0 on a frame of pure
    /// mid-grey. See that field's comment; the kernel counts both, and this
    /// one takes the one that answers §6's question.
    let compressedFraction: Double
    /// Pixels sitting on the container's limits after encoding, 0…1. These
    /// are the ones that lost detail rather than saturation.
    let clippedFraction: Double
    /// The literal §5.3 counter — pixels the knee acted on, 0…1. Carried
    /// because §7's measurement and a future warning may want it, and because
    /// a number that is surprisingly large should be visible rather than
    /// absent.
    let movedFraction: Double
    /// True while the conversion is still Core Graphics' clip rather than the
    /// output transform. The page must not present a placeholder as a proof.
    ///
    /// Always false now. Kept because it is part of the API the export page
    /// was built against, and because a future approximation — a lower-
    /// resolution proof, a cached one — would want it back.
    let isPlaceholder: Bool
}

extension Session {
    /// Render the current frame as `recipe` will write it, at no more than
    /// `maxPixels` pixels.
    ///
    /// Returns nil when there is nothing to proof — no frame open, no render
    /// on the canvas yet, or a recipe whose format carries no colour at all
    /// (the DI package, whose channels are densities and whose proof would be
    /// a lie in any rendering space).
    ///
    /// Both fractions are measured on the **proof's** pixels, which is a
    /// sample of the file's rather than the file's own count: a 2 MP proof of
    /// a 45 MP frame has averaged 22 source pixels into each of its own, and
    /// averaging pulls chroma toward the mean, so a proof can report slightly
    /// fewer moved pixels than the export will have. That is the right trade
    /// for a warning — the alternative is a full-resolution transform on every
    /// keystroke in the export page — and it is exact whenever the proof is
    /// not downscaled.
    @MainActor
    func softProof(recipe: ExportRecipe, maxPixels: Int = 2_000_000) async -> SoftProof? {
        guard recipe.format.takesColorSpace else { return nil }
        guard let source = renderer.base else { return nil }
        guard let adjusted = renderer.applyLayer2(to: source, uniforms: adjustments.uniforms)
            else { return nil }
        let framed = renderer.applyGeometry(geometry, to: adjusted) ?? adjusted

        // Resolved by the *export's* own function, so the proof cannot be a
        // proof of a space the file will not be in — and so a fallback is
        // reported in the same words the export would use for it.
        let (target, name, _, _) = Exporter.resolveTarget(recipe)

        // The size the file keeps — which is **not** `framed`'s. `framed`
        // descends from `renderer.base`, the tier currently on the canvas, so
        // on a frame showing a preview it measures 2678 x 1785 where the
        // export writes 6000 x 4000. The export's own source is a full-tier
        // render at the frame's native pixels, so that is what this computes:
        // the geometry against the native size, scaled back up the way the
        // page's own naming context does, and then the recipe's output size if
        // it asks for one.
        let exportSize = Self.exportSize(recipe: recipe, geometry: geometry,
                                         sourceSize: sourceImageSize, longEdge: sourceLongEdge)

        // The proof is a sample of that — the same chain, the same kernel,
        // fewer pixels. It is bounded by the tier on the canvas as well as by
        // `maxPixels`: resampling a preview *up* to the export's size would
        // cost the full transform and prove nothing the smaller one does not.
        let ceiling = CGSize(width: min(exportSize.width, CGFloat(framed.width)),
                             height: min(exportSize.height, CGFloat(framed.height)))
        let scale = min(1, (Double(maxPixels) / (ceiling.width * ceiling.height)).squareRoot())
        let width = max(1, Int((ceiling.width * scale).rounded()))
        let height = max(1, Int((ceiling.height * scale).rounded()))
        guard let small = renderer.applyResize(framed, width: width, height: height) else { return nil }

        let (setup, problem) = await ColourManagement.setup(client: client, source: workingSpaceName,
                                                            target: target,
                                                            device: renderer.device)
        guard let setup else {
            log.warn(.export, "soft_proof_failed", [
                .init("target", name),
                .init("error", problem ?? "the engine refused it"),
            ])
            return nil
        }
        guard let converted = renderer.applyOutputTransform(to: small, setup: setup),
              let image = converted.texture.makeCGImage(space: target) else { return nil }

        return SoftProof(image: image, target: target, targetName: name,
                         exportPixelSize: exportSize,
                         compressedFraction: converted.stats.outsideFraction,
                         clippedFraction: converted.stats.clippedFraction,
                         movedFraction: converted.stats.movedFraction,
                         isPlaceholder: false)
    }

    /// What the export will measure: the geometry applied to the frame's
    /// **native** pixels, scaled the way the canvas's source size relates to
    /// them, and then overridden by the recipe's own size when it names one.
    ///
    /// Deliberately computed from the session rather than from a texture. Any
    /// texture to hand is whatever tier the canvas is showing, and the export
    /// does not render that tier.
    static func exportSize(recipe: ExportRecipe, geometry: Geometry,
                           sourceSize: CGSize, longEdge: CGFloat) -> CGSize {
        if let asked = recipe.pixelSize { return asked }
        guard sourceSize.width > 0, sourceSize.height > 0 else { return sourceSize }
        let out = geometry.outputSize(for: sourceSize)
        let native = max(sourceSize.width, sourceSize.height)
        let scale = longEdge > 0 && native > 0 ? longEdge / native : 1
        return CGSize(width: (out.width * scale).rounded(), height: (out.height * scale).rounded())
    }

}
