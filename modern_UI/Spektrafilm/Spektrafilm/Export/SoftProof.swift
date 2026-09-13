//  SoftProof.swift — the picture an export recipe will actually write.
//
//  RFC-018 §5.5. This file is *the seam* between the two halves of RFC-018:
//  the render path, which learns to convert per destination, and the export
//  page, which shows the result. Both were built against this API at the same
//  time, on separate branches, which is only possible because the API landed
//  before either of them did.
//
//  **The body below is the placeholder** — today's export behaviour, which is
//  a Display P3 render converted by Core Graphics into the recipe's space.
//  Core Graphics clips out-of-gamut colour rather than compressing it, which
//  is RFC-018 §4.4 and the reason this file exists. `isPlaceholder` says so,
//  the page is expected to show that it does, and the pixels stream replaces
//  the body without the page noticing.

import CoreGraphics
import Foundation

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
    let compressedFraction: Double
    /// Pixels sitting on the container's limits after encoding, 0…1. These
    /// are the ones that lost detail rather than saturation.
    let clippedFraction: Double
    /// True while the conversion is still Core Graphics' clip rather than the
    /// output transform. The page must not present a placeholder as a proof.
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
    @MainActor
    func softProof(recipe: ExportRecipe, maxPixels: Int = 2_000_000) async -> SoftProof? {
        guard recipe.format.takesColorSpace else { return nil }
        guard let source = renderer.base else { return nil }
        guard let adjusted = renderer.applyLayer2(to: source, uniforms: adjustments.uniforms)
            else { return nil }
        let framed = renderer.applyGeometry(geometry, to: adjusted) ?? adjusted
        guard let canvas = framed.makeCGImage() else { return nil }

        let (space, fellBack) = recipe.resolvedColorSpace()
        let target = space ?? ImageDecoder.displayP3
        let name = fellBack
            ? "Display P3 (the recipe's profile is not on this machine)"
            : (ColorSpaceCatalog.name(for: recipe.colorSpace) ?? "an unnamed profile")

        // The export's size is the full render's; the proof's is bounded. The
        // ratio is applied to both axes so the proof is the same picture and
        // not a differently cropped one.
        let full = CGSize(width: framed.width, height: framed.height)
        let scale = min(1, (Double(maxPixels) / (full.width * full.height)).squareRoot())
        let w = max(1, Int((full.width * scale).rounded())), h = max(1, Int((full.height * scale).rounded()))

        guard let proof = Self.redraw(canvas, in: target, width: w, height: h) else { return nil }
        return SoftProof(image: proof, target: target, targetName: name, exportPixelSize: full,
                         compressedFraction: 0, clippedFraction: 0, isPlaceholder: true)
    }

    /// Resize and convert in one draw. 16-bit needs the little-endian flag or
    /// the channels come back byte-swapped, which looks like a colour bug and
    /// is not one — the same trap `Exporter.redraw` documents.
    private static func redraw(_ cg: CGImage, in space: CGColorSpace, width: Int, height: Int) -> CGImage? {
        var info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16,
                                  bytesPerRow: 0, space: space, bitmapInfo: info) else {
            info = CGImageAlphaInfo.noneSkipLast.rawValue
            guard let fallback = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
            fallback.interpolationQuality = .high
            fallback.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return fallback.makeImage()
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
