//  SectionReset.swift — what a section's reset arrow resets, by name.
//
//  **The rule (V5, 2026-10-18): a reset belongs to the page it is on.** A
//  section's arrow resets that section's own fields and nothing else, its
//  name says which ("Reset Enlarger"), and it is **silent when nothing has
//  changed** — the arrow greys and a press asks for no render. No ordinary
//  reset reaches past its page: the broad resets (`Session.resetParams`,
//  `resetAdjustments`) stay in the Frame menu, named as what they are.
//
//  Before this, the arrows had grown one at a time and each meant something
//  different: Camera's reset the film exposure and nothing else of the
//  section it sat on, Film's reset the stock, Film Format's the frame and
//  every effect, Scene Placement's turned the placement off. Each scope is
//  now written down here once, as fields, so the arrow, the menu item and
//  the test that checks the scope leaves its neighbours alone all read the
//  same list.
//
//  **Recovery is the editor's own undo.** Every scope writes through the
//  session's setters, which take one undo snapshot (coalesced), so ⌘Z puts a
//  reset back. There is no confirmation dialog: on the desktop an undoable
//  edit is not asked about twice.
//
//  The scopes compose: the left/right rails' Input / Camera is Film Exposure
//  and Decode, Film Format is Format, Grain & Halation and Couplers. The
//  Develop | Edit shell (`FeatureFlags.surfaces`) shows the parts as pages
//  of their own, and their arrows reset the parts.

import Foundation

enum SectionReset: Hashable, CaseIterable, Sendable {
    /// The film stock, back to the catalogue's default film.
    case film
    /// Metering and Film Exposure.
    case filmExposure
    /// The decode: white balance back to As Shot, lens correction and the
    /// lens fall-off (Vignetting) off.
    case decode
    /// Input / Camera, as the Parameters rail shows it: `filmExposure` and
    /// `decode` together.
    case camera
    /// The physical frame: Size and Side. Not while Film Edge holds the
    /// frame — a reset must not quietly change what an active edge decides.
    case format
    /// Grain, halation, scatter, the highlight boost and glare: the switches
    /// on and the strengths at the film's own.
    case grainAndHalation
    /// The DIR couplers: on, at the film's own strength.
    case couplers
    /// Film Format, as the Parameters rail shows it: `format`,
    /// `grainAndHalation` and `couplers`.
    case filmFormat
    /// Scene Placement: off.
    case scenePlacement
    /// The enlarger: brightness, both filter axes and pre-flash.
    case enlarger
    /// The enlarger's head alone — brightness and the two filters — for a
    /// page that shows pre-flash on its own.
    case enlargerHead
    /// Pre-flash alone.
    case preflash
    /// The crop: the whole frame, unturned, level. Not while Film Edge holds
    /// the frame.
    case crop

    /// The parts a composite scope is made of; a part is its own only part.
    var parts: [SectionReset] {
        switch self {
        case .camera: [.filmExposure, .decode]
        case .filmFormat: [.format, .grainAndHalation, .couplers]
        case .enlarger: [.enlargerHead, .preflash]
        default: [self]
        }
    }

    /// The arrow's tooltip and VoiceOver name: "Reset" and the section's own
    /// title, in the interface's language.
    @MainActor var title: String {
        let section: String = switch self {
        case .film: L(.sectionFilm)
        case .filmExposure: L(.cameraFilmExposure)
        case .decode: L(.sectionDecode)
        case .camera: L(.sectionCamera)
        case .format: L(.sectionFormat)
        case .grainAndHalation: L(.sectionGrainHalation)
        case .couplers: L(.filmCouplers)
        case .filmFormat: L(.filmFormat)
        case .scenePlacement: L(.sectionScenePlacement)
        case .enlarger, .enlargerHead: L(.sectionEnlarger)
        case .preflash: L(.enlargerPreflash)
        case .crop: L(.sectionCrop)
        }
        return L("Reset \(section)", zh: "重置\(section)")
    }

    /// Whether the reset would change anything. False greys the arrow, and
    /// `perform` does nothing — the "silent when nothing changed" half.
    @MainActor func hasChanges(in s: Session) -> Bool {
        guard parts.count == 1 else { return parts.contains { $0.hasChanges(in: s) } }
        let p = s.params, e = p.effects, d = EffectStrengths.default
        switch self {
        case .film:
            return p.filmStock != FilmParams.default.filmStock
        case .filmExposure:
            return s.aeMethod != Self.defaultMetering || s.filmExposure != 0
        case .decode:
            return s.decode.whiteBalance != .asShot
                || s.decode.lensCorrection != DecodeSettings().lensCorrection
                || s.adjustments.vignette.amount != 0
        case .format:
            return !s.filmEdgeHoldsFrame && (s.filmFrame.id != Self.defaultFrame || s.filmSide != .short)
        case .grainAndHalation:
            return !p.grainActive || !p.halationActive || !p.glareActive
                || e.grain != d.grain || e.grainLayered != d.grainLayered
                || e.halation != d.halation || e.antihalationRemoved != d.antihalationRemoved
                || e.highlightBoost != d.highlightBoost || e.scatter != d.scatter || e.glare != d.glare
        case .couplers:
            return e.couplersActive != d.couplersActive || e.couplers != d.couplers
        case .scenePlacement:
            return p.sceneLatitude.active
        case .enlargerHead:
            return [EnlargerField.brightness, .yellow, .magenta].contains { s.enlargerValue($0) != 0 }
        case .preflash:
            return s.enlargerValue(.preflash) != 0
        case .crop:
            return !s.filmEdgeHoldsFrame && s.geometry != .default
        case .camera, .filmFormat, .enlarger:
            return false   // composites, answered above
        }
    }

    /// Reset the scope's fields, through the session's own setters (one undo
    /// step, the renders each field asks for). Silent when nothing changed.
    @MainActor func perform(in s: Session) {
        guard !s.batchExporting, hasChanges(in: s) else { return }
        // The enlarger as one: the session's own reset, which knows a pair's
        // frame and film prints, rather than four setters each moving them.
        if self == .enlarger { s.resetEnlarger(); return }
        guard parts.count == 1 else {
            for part in parts { part.perform(in: s) }
            return
        }
        switch self {
        case .film:
            var p = s.params
            p.filmStock = FilmParams.default.filmStock
            // Coming back from a black-and-white film, its paper cannot stay.
            if !s.catalog.canPrint(film: p.filmStock, on: p.printStock) {
                p.printStock = FilmParams.default.printStock
            }
            s.params = p
            s.applyFilmStageRule()
        case .filmExposure:
            if s.aeMethod != Self.defaultMetering { s.aeMethod = Self.defaultMetering }
            if s.filmExposure != 0 { s.filmExposure = 0 }
        case .decode:
            if s.decode.whiteBalance != .asShot { s.setWhiteBalance(.asShot) }
            let lens = DecodeSettings().lensCorrection
            if s.decode.lensCorrection != lens { s.setLensCorrection(lens) }
            if s.adjustments.vignette.amount != 0 {
                var a = s.adjustments; a.vignette.amount = 0; s.adjustments = a
            }
        case .format:
            if s.filmFrame.id != Self.defaultFrame,
               let frame = FilmFrame.all.first(where: { $0.id == Self.defaultFrame }) {
                s.setFilmFrame(frame)
            }
            if s.filmSide != .short { s.setFilmSide(.short) }
        case .grainAndHalation:
            var p = s.params
            let d = EffectStrengths.default
            p.grainActive = true; p.halationActive = true; p.glareActive = true
            p.effects.grain = d.grain; p.effects.grainLayered = d.grainLayered
            p.effects.halation = d.halation; p.effects.antihalationRemoved = d.antihalationRemoved
            p.effects.highlightBoost = d.highlightBoost; p.effects.scatter = d.scatter
            p.effects.glare = d.glare
            s.params = p
        case .couplers:
            var p = s.params
            p.effects.couplersActive = EffectStrengths.default.couplersActive
            p.effects.couplers = EffectStrengths.default.couplers
            s.params = p
        case .scenePlacement:
            s.resetScenePlacement()
        case .enlargerHead:
            for f in [EnlargerField.brightness, .yellow, .magenta] where s.enlargerValue(f) != 0 {
                s.setEnlarger(f, 0)
            }
        case .preflash:
            s.setEnlarger(.preflash, 0)
        case .crop:
            s.geometry = .default
        case .camera, .filmFormat, .enlarger:
            break
        }
    }

    /// The meter a new frame starts with.
    static var defaultMetering: AEMethod { AEMethod.of(FilmParams.default) }
    /// The frame a new photograph is described as.
    static let defaultFrame = "135"
}
