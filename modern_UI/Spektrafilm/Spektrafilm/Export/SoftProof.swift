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
    /// The proof's own pixel size, which is not the export's: a proof is
    /// rendered small enough to be fast. The export's size travels separately
    /// so the page can state both without implying they are the same number.
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

        // The size the file keeps. The export page's output size is applied on
        // the export path, and reaches this one when stream B's
        // `ExportRecipe.outputSize` is wired through `Exporter.export`; until
        // then the file's size is the geometry's own, which is what this
        // reports.
        let exportSize = CGSize(width: framed.width, height: framed.height)

        // The proof is a sample of that — the same chain, the same kernel,
        // fewer pixels.
        let scale = min(1, (Double(maxPixels) / (exportSize.width * exportSize.height)).squareRoot())
        let width = max(1, Int((exportSize.width * scale).rounded()))
        let height = max(1, Int((exportSize.height * scale).rounded()))
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
}
