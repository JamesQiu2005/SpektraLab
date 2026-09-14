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
//
//  **And it is now the same *function*.** The chain used to be written twice,
//  once here and once in `Exporter.exportPrint`, and the two agreed only
//  because they were typed out to agree — plus a `min(exportSize, framed)`
//  ceiling that made the proof's size depend on the tier the *canvas* happened
//  to be showing, which is why §7.6's claim carried a caveat. `softProof` is
//  now `Exporter.filePixels` plus a wrapper: full-tier render, grade, frame,
//  size, transform. The file-sized wrapper keeps the file's pixels at the
//  file's size for parity; the page's wrapper downsamples those same pixels
//  once for the pane and does not retain the full-size image.

import CoreGraphics
import Foundation
import Metal

/// One rendered proof, in the destination's own colour space.
///
/// `displayImage` is tagged with `target` and carries the destination's pixels,
/// not the canvas's: that is the whole claim of the type. A proof that went
/// through the canvas path and was relabelled would prove nothing, and
/// `RFC-018 §7.6` is the check that it did not.
///
/// **The render is the file's pixels and the file's size.** `filePixelSize`
/// and all three statistics describe the full-size output of
/// `Exporter.filePixels`, never a display downsample. `displayImage` is that
/// same output resampled once for the page; the full-size `CGImage` is not
/// retained.
struct SoftProof: @unchecked Sendable {
    /// The pixels the page draws: the full-size destination-space render,
    /// resampled once at most. The unchanged version is file-sized.
    let displayImage: CGImage
    /// The file's real pixel dimensions. This is deliberately independent of
    /// `displayImage`, which may be smaller for the pane.
    let filePixelSize: CGSize
    let target: CGColorSpace
    /// What to call the space in front of a person — the catalogue's name for
    /// it, not `CGColorSpace`'s identifier.
    let targetName: String
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

    /// The old name, retained for the unmodified parity harness: the proof
    /// returned without a display bound is still the file's own pixels.
    var image: CGImage { displayImage }

    init(displayImage: CGImage, filePixelSize: CGSize, target: CGColorSpace,
         targetName: String, compressedFraction: Double, clippedFraction: Double,
         movedFraction: Double, isPlaceholder: Bool) {
        self.displayImage = displayImage
        self.filePixelSize = filePixelSize
        self.target = target
        self.targetName = targetName
        self.compressedFraction = compressedFraction
        self.clippedFraction = clippedFraction
        self.movedFraction = movedFraction
        self.isPlaceholder = isPlaceholder
    }

    /// Build the display image without reading the full-size texture back to
    /// the CPU first.
    @MainActor
    static func make(from rendered: Exporter.Rendered, renderer: Renderer,
                     targetName: String, displayMaxEdge: Int?) -> SoftProof? {
        let displayed: MTLTexture
        if let displayMaxEdge {
            let size = displayPixelSize(fileWidth: rendered.pixels.w,
                                        fileHeight: rendered.pixels.h,
                                        maxEdge: displayMaxEdge)
            if size.w == rendered.texture.width, size.h == rendered.texture.height {
                displayed = rendered.texture
            } else {
                guard let resized = renderer.applyResize(rendered.texture,
                                                          width: size.w, height: size.h)
                else { return nil }
                displayed = resized
            }
        } else {
            displayed = rendered.texture
        }
        guard let cg = displayed.makeCGImage(space: rendered.target) else { return nil }
        return SoftProof(displayImage: cg,
                         filePixelSize: CGSize(width: rendered.pixels.w, height: rendered.pixels.h),
                         target: rendered.target, targetName: targetName,
                         compressedFraction: rendered.stats.outsideFraction,
                         clippedFraction: rendered.stats.clippedFraction,
                         movedFraction: rendered.stats.movedFraction,
                         isPlaceholder: false)
    }

    /// The page targets two display pixels for each point on the pane's
    /// longest side. That is the 2× scale a Retina display draws, with the
    /// resulting image still no larger than the file when it is smaller.
    static func displayMaxEdge(for paneSize: CGSize) -> Int {
        let longest = max(paneSize.width, paneSize.height)
        guard longest > 0 else { return 1 }
        return max(1, Int((longest * 2).rounded(.up)))
    }

    /// Aspect-preserving target size. Never upscales.
    static func displayPixelSize(fileWidth: Int, fileHeight: Int,
                                 maxEdge: Int?) -> (w: Int, h: Int) {
        guard fileWidth > 0, fileHeight > 0 else { return (fileWidth, fileHeight) }
        guard let maxEdge, maxEdge > 0 else { return (fileWidth, fileHeight) }
        let long = max(fileWidth, fileHeight)
        guard long > maxEdge else { return (fileWidth, fileHeight) }
        let short = min(fileWidth, fileHeight)
        let scaledShort = max(1, Int((Double(short) * Double(maxEdge) / Double(long)).rounded()))
        return fileWidth >= fileHeight ? (maxEdge, scaledShort) : (scaledShort, maxEdge)
    }

    /// Compatibility initializer for callers that already have a file-sized
    /// image (the parity harness constructs an artificial one this way).
    init(image: CGImage, target: CGColorSpace, targetName: String,
         compressedFraction: Double, clippedFraction: Double,
         movedFraction: Double, isPlaceholder: Bool) {
        self.init(displayImage: image,
                  filePixelSize: CGSize(width: image.width, height: image.height),
                  target: target, targetName: targetName,
                  compressedFraction: compressedFraction, clippedFraction: clippedFraction,
                  movedFraction: movedFraction, isPlaceholder: isPlaceholder)
    }
}

extension Session {
    /// The file's own pixels at the file's own size, in the destination's
    /// space. Nil when there is nothing to prove — no frame, or a format that
    /// carries no colour.
    ///
    /// **Cancellation is the caller's `Task`**: a superseded call returns nil
    /// rather than a stale picture. Both await points are checked, because the
    /// engine render is the expensive half and a keystroke in the page's
    /// fields can supersede this several times over while one runs.
    ///
    /// The chain is `Exporter.filePixels` — the export's own, not a second
    /// one written to look like it. That is what makes §7.6's identity exact
    /// rather than approximate, and what the page's central claim rests on.
    @MainActor
    func softProof(recipe: ExportRecipe) async -> SoftProof? {
        await makeSoftProof(recipe: recipe, displayMaxEdge: nil)
    }

    /// The page's proof: the same full-size render and the same statistics,
    /// with one GPU downsample before the `CGImage` is materialised.
    @MainActor
    func softProofForDisplay(recipe: ExportRecipe, paneSize: CGSize) async -> SoftProof? {
        await makeSoftProof(recipe: recipe,
                            displayMaxEdge: SoftProof.displayMaxEdge(for: paneSize))
    }

    @MainActor
    private func makeSoftProof(recipe: ExportRecipe,
                               displayMaxEdge: Int?) async -> SoftProof? {
        guard recipe.format.takesColorSpace else { return nil }
        // Nothing developed yet (the page opened from Browse, say): ask for it
        // the way every other view that wants a picture does.
        if serviceSessionIDForExport == nil { _ = await ensureDeveloped() }
        guard let sessionID = serviceSessionIDForExport else { return nil }
        let (_, name, _, _) = Exporter.resolveTarget(recipe)

        let rendered: Exporter.Rendered
        do {
            rendered = try await Exporter.filePixels(session: self, recipe: recipe, sessionID: sessionID)
        } catch is CancellationError {
            return nil
        } catch {
            log.warn(.export, "soft_proof_failed", [
                .init("target", name),
                .init("error", EngineMessage.technical(error)),
            ])
            return nil
        }
        guard !Task.isCancelled else { return nil }

        return SoftProof.make(from: rendered, renderer: renderer,
                              targetName: name, displayMaxEdge: displayMaxEdge)
    }
}
