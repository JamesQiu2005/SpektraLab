//  EngineMessage.swift — an engine failure, said to the person who is looking
//  at it.
//
//  `spk_last_error` is written for whoever is changing the engine, and it
//  should be: "run engine/build.sh bundle" is the fastest possible answer for
//  a developer and completely useless to a photographer, who has no checkout,
//  no build script and nothing to do with either. That was the last item on
//  HANDOFF-DISTRIBUTION §2.6, and it is a shipping problem rather than a
//  cosmetic one — a message a user cannot act on turns a fixable install into
//  an app that "just doesn't work".
//
//  Two rules here, and the second is the one that keeps this honest:
//
//  1. **Only the classes that actually reach a user are rewritten.** A
//     mistranslated error is worse than a technical one, so anything not
//     recognised is passed through rather than replaced with a shrug.
//  2. **The technical text is never destroyed.** `technical(_:)` is what a
//     log line and a bug report carry, and the rewritten message keeps the
//     original in parentheses wherever it might narrow the problem down.
//     Hiding it would trade one unusable report for another.

import Foundation

enum EngineMessage {

    /// What kind of failure this is, as far as the app can tell.
    ///
    /// It exists so that the *user-facing* sentence and the *log record* cannot
    /// drift: both are chosen from one classification rather than each deciding
    /// for itself what "too large" looks like. RFC-016 §11.5 is the other
    /// reader — a refusal is a visible event, and this is what says it is one.
    enum Kind: String, Sendable {
        case cancelled
        /// An incomplete install: the resources or the metallib are missing.
        case install
        /// The engine's fast-math guard, which refuses to start rather than
        /// render slightly wrong.
        case fastMath = "fast_math"
        /// No Metal device, or one the engine could not use.
        case metal
        /// The frame is past a limit: more pixels than the engine's cap, or a
        /// long edge the GPU cannot make a texture of.
        case size
        /// A print stock with no baked preview LUT.
        case printLUT = "print_lut"
        /// Out of memory, most likely at the full tier.
        case memory
        /// Not recognised; the raw text is passed through.
        case unknown

        /// A **refusal**: the app declined to render this frame, and the user
        /// is owed the reason (§11.5). A cancellation and a missing install are
        /// not refusals — one is not a failure and the other is not about the
        /// frame — and neither gets a badge.
        var isRefusal: Bool {
            switch self {
            case .size, .memory, .metal: true
            case .cancelled, .install, .fastMath, .printLUT, .unknown: false
            }
        }

        /// The canvas badge for a refusal, or nil when there is nothing to
        /// refuse. Short: it shares a corner with "full resolution…".
        var badge: String? {
            switch self {
            case .size, .metal: "refused · too large"
            case .memory: "refused · out of memory"
            default: nil
            }
        }
    }

    /// The engine's own words, unabridged. For a log, a bug report, and the
    /// canvas trace — never the only thing a user is shown.
    static func technical(_ error: Error) -> String { "\(error)" }

    static func kind(_ error: Error) -> Kind {
        let lower = "\(error)".lowercased()
        // A cancelled render is not a failure and must not read like one.
        if lower.contains("cancelled") { return .cancelled }
        if lower.contains("resources are missing") || lower.contains("build.sh")
            || lower.contains("bake_resources") || lower.contains("metallib") { return .install }
        if lower.contains("fast math") { return .fastMath }
        if lower.contains("no metal") || lower.contains("mtldevice")
            || lower.contains("metal device") { return .metal }
        if lower.contains("too large") || lower.contains("max_mp")
            || lower.contains("megapixel") { return .size }
        if lower.contains("print-preview lut") || lower.contains("print_luts.json") { return .printLUT }
        if lower.contains("out of memory") || lower.contains("allocation") { return .memory }
        return .unknown
    }

    /// The same failure, for someone who did not build this.
    static func userFacing(_ error: Error) -> String {
        let raw = "\(error)"
        switch kind(error) {
        case .cancelled:
            return "The render was cancelled."

        // An incomplete install. This is the case the handoff named: the
        // engine says "the engine's resources are missing at … ; run
        // engine/build.sh bundle", which is right for a checkout and
        // meaningless for a download.
        case .install:
            return "This copy of Filmify is missing part of itself and cannot render. "
                 + "Download it again, or move it out of the disk image into Applications "
                 + "if it is still running from there. (\(raw))"

        // The fast-math guard fired. The engine refused to start rather than
        // render inaccurately, which is the right call and needs saying as
        // one — the app is not broken, this build of it is.
        case .fastMath:
            return "This build of Filmify was compiled with a maths setting that would "
                 + "render colours slightly wrong, so it refused to start rather than lie to "
                 + "you. Please report the build you downloaded. (\(raw))"

        case .metal:
            return "Filmify needs a Metal-capable GPU and could not find one on this Mac."

        // The frame is bigger than the engine will accept — either more pixels
        // than the cap (a Phase One IQ4 150's 14204 x 10652) or a long edge the
        // GPU cannot make a texture of. Both say so in the raw text, which is
        // the half that tells the user how far over they are.
        case .size:
            return "This frame is larger than Filmify can render. The biggest it takes is a "
                 + "150 MP camera's frame, and a very wide panorama can be refused for the GPU's "
                 + "texture limit even when it is under that. (\(raw))"

        // A print stock with no baked preview LUT. The engine's message
        // already lists what is available, which is the useful half; what it
        // does not say is that the *print itself* is unaffected.
        case .printLUT:
            return "There is no baked preview for that paper, so the fast flip is unavailable "
                 + "for it — printing on it still works normally. (\(raw))"

        // Out of memory, most likely at the full tier.
        case .memory:
            return "Filmify ran out of memory rendering this frame at full resolution. "
                 + "Closing other applications, or zooming out so a smaller tier is used, "
                 + "usually gets past it. (\(raw))"

        // Not recognised: pass it through. A wrong guess about what a user
        // should do is worse than an unfamiliar sentence.
        case .unknown:
            return raw
        }
    }
}
