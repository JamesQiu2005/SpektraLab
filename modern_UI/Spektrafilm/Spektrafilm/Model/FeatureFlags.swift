//  FeatureFlags.swift — the switches that decide what the interface offers.
//
//  There is exactly one rule for what belongs here: a feature whose *code* is
//  worth keeping but whose *design* is not settled. Deleting such a feature
//  loses the work; shipping it teaches the user a shape that is about to
//  change. A flag keeps both the code and the honesty.
//
//  Each flag says who owns the decision and what has to happen before it
//  flips. A flag with no such note is a flag nobody will ever dare remove.

import Foundation

enum FeatureFlags {

    /// The 蒙版 (mask) system: local adjustments with a region.
    ///
    /// **Off, deliberately, and not because the code is broken.** The model
    /// (`Model/Mask.swift`), the kernel (`maskCoverage` in `Shaders.metal`),
    /// the sublayer (`Panels/Sections/MasksSection.swift`), the canvas
    /// controls (`Canvas/MaskOverlay.swift`) and the tests (`MaskTests`) all
    /// work and all stay. What is not settled is the *interaction design* —
    /// the user is writing the PRD, the interaction data and the layout — and
    /// the version built from the Lightroom reference is not the one they
    /// want.
    ///
    /// What the flag actually gates, and why each one matters:
    ///
    /// - `Session.syncMasks` stops packing masks for the kernel. This is the
    ///   important one: it means a sidecar that *already* has masks in it
    ///   renders as though it did not. The masks are still read, still
    ///   written, and still round-trip (`Sidecar` is untouched), so nothing
    ///   is lost — but no saved mask silently affects a picture while the
    ///   feature is not on offer.
    /// - `RightPanel` drops the sublayer, `EditorWindow` drops the overlay,
    ///   `SpektrafilmApp` drops the Mask menu, and `Session.maskHandles`
    ///   returns nothing, so the canvas cannot be dragged by grips that are
    ///   not drawn.
    ///
    /// Flip it back on when the user's own mask PRD lands and the sublayer is
    /// rebuilt to it.
    static let masks = false

    /// The step 1 decode pipeline: when on, the single-flight pipeline owns
    /// the load path (decode, preview, and native-original stages).
    ///
    /// Flip it off if the pipeline has a bad interaction with the export
    /// harness. Remove the flag after the 30-click test has survived a week
    /// of real use. IMPL §9 says this can be turned off by a user without a
    /// build; this repository's FeatureFlags are compile-time `static let`s
    /// (as `masks` demonstrates), so changing it does require a build. That
    /// is a deliberate deviation from the document, called out rather than
    /// hidden.
    static let framePipeline = true

    /// The RFC-019 scratch texture pool.
    ///
    /// Off by default for one release. The pool reuses full-size export
    /// destinations and is the one memory change with a pixel-correctness
    /// surface: reuse is valid only when every kernel writes every texel and
    /// never reads its destination. Debug builds can turn it on with
    /// `SPEKTRAFILM_SCRATCH_POOL=1`; release builds never do.
    static let scratchPool: Bool = {
#if DEBUG
        ProcessInfo.processInfo.environment["SPEKTRAFILM_SCRATCH_POOL"] == "1"
#else
        false
#endif
    }()
}
