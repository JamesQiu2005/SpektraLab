//  SettingsClipboard.swift — RFC-027: what ⇧⌘C takes and what ⇧⌘V writes.
//
//  Capture One's adjustments clipboard, with the user's seven groups. The
//  groups are ticked **at copy time**: a clip is the source frame's settings
//  plus the groups it was taken with, and a paste writes exactly those.
//
//  A paste writes **settings, not solved numbers** (the user's decision,
//  2026-09-28). The target meters its own exposure, keeps its own camera
//  white balance under As Shot, and fits its own Scene Placement curve. The
//  source's fitted curve is never pasted: it is the source photograph's
//  histogram in absolute scene stops, and on a contrastier frame it was what
//  blew the print out.
//
//  `applied(to:)` is pure, Sidecar in and Sidecar out, so the whole meaning of
//  a paste is testable without a window, an engine or a file. `Session`
//  decides only how the result reaches a frame.

import Foundation

enum ClipboardGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The boxes the section shows. 遮罩 (the Tone Mask and local masks) is not
    /// offered while both are withdrawn (`FeatureFlags`): a box for settings
    /// that cannot be seen or changed would be a box that lies. The group stays
    /// in the model, so its fields keep their one owner.
    static var offered: [ClipboardGroup] {
        allCases.filter { $0 != .masks || FeatureFlags.masks || FeatureFlags.toneMask }
    }

    case filmAndPaper, exposure, whiteBalance, filmEffects, printEffects, scenePlacement, masks

    var id: String { rawValue }

    /// The stored fields this group owns, as prefixes of the encoded sidecar
    /// (`params.effects` owns every `params.effects.*`).
    ///
    /// **Every stored field has exactly one owner or a `notCopied` reason**,
    /// and `SettingsClipboardTests` enforces it by walking the model. A new
    /// field fails that test until someone decides which it is.
    var paths: [String] {
        switch self {
        case .filmAndPaper:
            ["params.filmStock", "params.printStock", "params.scanFilm", "params.digitalIntermediate",
             "params.extendedDynamicRange"]
        case .exposure:
            // The enlarger's brightness is the print's exposure (user, 2026-09-28).
            ["params.autoExposure", "params.autoExposureMethod", "params.exposureCompensationEV",
             "params.printBrightnessStops"]
        case .whiteBalance:
            // The enlarger's filters: in the darkroom, colour *is* the filter pack.
            ["decode.whiteBalance", "decode.temperature", "decode.tint",
             "params.yFilterShift", "params.mFilterShift"]
        case .filmEffects:
            // The film format sets the physical scale of grain and halation.
            ["params.filmFormatMM", "params.filmFrame", "params.filmSide", "params.sideLengthMM",
             "params.grainActive", "params.halationActive", "params.glareActive", "params.effects"]
        case .printEffects:
            // Pre-flash is gated by the Print Effects switch already.
            ["params.printEffects", "params.preflashExposure"]
        case .scenePlacement:
            ["params.sceneLatitude", "placementNeedsFit"]
        case .masks:
            ["params.contrastMask", "masks"]
        }
    }

    /// Stored fields no group owns, and why.
    static let notCopied: [String: String] = [
        "decode.lensCorrection": "a property of the lens, not of the look",
        "adjustments": "the Post-Dev grade, outside the 2026-09-23 positioning",
        "geometry": "crop and framing belong to the photograph (PRD §7)",
        "heldCrop": "the photograph's own crop, kept while Film Edge frames it",
        // Undecided (answer sheet F10 is open): whether Film Edge and Date Back
        // become a group of their own. Until then neither is copied, and the
        // seeds and the resolved text would be the source photograph's anyway.
        "params.filmEdge": "Film Edge: not copied until a group is decided (F10)",
        "params.dateBack": "Date Back: not copied until a group is decided (F10)",
        // A half-frame pair's second placement and which frame is which: they
        // belong to the piece's two frames, and a frame has neither.
        "params.sceneLatitudeOther": "a half-frame pair's other frame's placement",
        "params.placementIsRight": "which frame of a pair the placement is shown for",
        "params.pairSplit": "resolved from the pair's layout",
        "solvedEV": "a report of the meter, refilled by the target's own develop",
        "state": "whether the frame has been rendered",
        "source": "which file the sidecar belongs to",
        "schemaVersion": "the file format",
        "decoder": "the file format",
    ]

    @MainActor var title: String {
        switch self {
        case .filmAndPaper: L(.clipFilmAndPaper)
        case .exposure: L(.clipExposure)
        case .whiteBalance: L(.clipWhiteBalance)
        case .filmEffects: L(.clipFilmEffects)
        case .printEffects: L(.clipPrintEffects)
        case .scenePlacement: L(.clipScenePlacement)
        case .masks: L(.clipMasks)
        }
    }

    @MainActor var help: String {
        switch self {
        case .filmAndPaper: L(.clipFilmAndPaperHelp)
        case .exposure: L(.clipExposureHelp)
        case .whiteBalance: L(.clipWhiteBalanceHelp)
        case .filmEffects: L(.clipFilmEffectsHelp)
        case .printEffects: L(.clipPrintEffectsHelp)
        case .scenePlacement: L(.clipScenePlacementHelp)
        case .masks: L(.clipMasksHelp)
        }
    }
}

struct SettingsClip: Equatable, Sendable {
    var groups: Set<ClipboardGroup>
    /// The source frame's settings when it was copied.
    var settings: Sidecar
    /// The source frame's file name, for the section's "what is held" line.
    var sourceName: String

    /// `target` with this clip's groups written into it, and nothing else.
    func applied(to target: Sidecar) -> Sidecar {
        var out = target
        let s = settings
        if groups.contains(.filmAndPaper) {
            out.params.filmStock = s.params.filmStock
            out.params.printStock = s.params.printStock
            out.params.scanFilm = s.params.scanFilm
            out.params.digitalIntermediate = s.params.digitalIntermediate
            out.params.extendedDynamicRange = s.params.extendedDynamicRange
        }
        if groups.contains(.exposure) {
            let meterChanged = out.params.autoExposure != s.params.autoExposure
                || out.params.autoExposureMethod != s.params.autoExposureMethod
            out.params.autoExposure = s.params.autoExposure
            out.params.autoExposureMethod = s.params.autoExposureMethod
            out.params.exposureCompensationEV = s.params.exposureCompensationEV
            out.params.printBrightnessStops = s.params.printBrightnessStops
            // The target's report is of the target's old meter. Nil until its
            // develop, or `retargetSolvedEV`, measures the new one.
            if meterChanged { out.solvedEV = nil }
        }
        if groups.contains(.whiteBalance) {
            out.decode.whiteBalance = s.decode.whiteBalance
            // As Shot is the *target's* camera: its numbers are its own, and
            // the source's Kelvin must not come with the word.
            if s.decode.whiteBalance != .asShot {
                out.decode.temperature = s.decode.temperature
                out.decode.tint = s.decode.tint
            }
            out.params.yFilterShift = s.params.yFilterShift
            out.params.mFilterShift = s.params.mFilterShift
        }
        if groups.contains(.filmEffects) {
            // `filmFormatMM` is derived from these and the target's aspect;
            // the session re-derives it (`recomputeFilmFormat`), and so does
            // the next decode.
            out.params.filmFormatMM = s.params.filmFormatMM
            out.params.filmFrame = s.params.filmFrame
            out.params.filmSide = s.params.filmSide
            out.params.sideLengthMM = s.params.sideLengthMM
            out.params.grainActive = s.params.grainActive
            out.params.halationActive = s.params.halationActive
            out.params.glareActive = s.params.glareActive
            out.params.effects = s.params.effects
        }
        if groups.contains(.printEffects) {
            out.params.printEffects = s.params.printEffects
            out.params.preflashExposure = s.params.preflashExposure
        }
        if groups.contains(.scenePlacement) {
            // The intent and the Fit's inputs; the curve stays the identity
            // until the target's own Fit lands (`resolvePendingPlacement`).
            let from = s.params.sceneLatitude
            var to = SceneLatitudeSettings()
            to.highlightPullBack = from.highlightPullBack
            to.shadowPullBack = from.shadowPullBack
            to.highlightPercentile = from.highlightPercentile
            to.shadowPercentile = from.shadowPercentile
            to.rolloff = from.rolloff
            to.maxLift = from.maxLift
            to.norm = from.norm
            out.params.sceneLatitude = to
            out.placementNeedsFit = to.highlightPullBack > 0 || to.shadowPullBack > 0
        }
        if groups.contains(.masks) {
            out.params.contrastMask = s.params.contrastMask
            out.masks = s.masks
        }
        return out
    }
}
