//  SettingsClipboard.swift — what Copy Settings takes and what Paste writes.
//
//  The desktop's RFC-027 clipboard (`Model/SettingsClipboard.swift`, SpektraLab
//  `unpublished-revision`, the maintainer's), on the host: the same groups, ticked **at copy
//  time** on the Copy Settings sheet (C7), pasted from Select (B4).
//
//  A paste writes **settings, not solved numbers** (the owner's decision,
//  2026-09-28). The target meters its own exposure, keeps its own camera white
//  balance under As Shot, and fits its own Scene Placement curve. Crop, framing
//  and each frame's seed never travel.
//
//  The desktop's seventh group is masks, which the host does not have. The
//  host's seventh is **Film Edge & Date Back**, unticked by default (and not
//  offered at all were those features held back: `FeatureFlags`). The film,
//  its view, its gate and the date travel; the picture's place in the gate and
//  the frame's body stay the target's own, as a crop and a seed do.
//
//  Edit's three tools are three more groups (2026-10-15, design/v5): **Light**,
//  **Curve** and **Colour**, ticked by default. They are Layer 2
//  (`Adjustments`): a paste of them develops nothing.

import Foundation

enum ClipboardGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case filmAndPaper = "filmAndPaper", exposure = "exposure", whiteBalance = "whiteBalance",
        filmEffects = "filmEffects", printEffects = "printEffects", scenePlacement = "scenePlacement",
        filmEdgeAndDateBack = "filmEdgeAndDateBack"
    case light = "light", curve = "curve", colour = "colour"
    // V2 canonical leaves; legacy groups below retain their old meaning.
    case filmExposure = "filmExposure", format = "format", decode = "decode", enlarger = "enlarger",
        couplers = "couplers", preflash = "preflash"

    var id: String { rawValue }

    /// The boxes the sheet shows. A box for settings that cannot be seen or
    /// changed would be a box that lies.
    static var offered: [ClipboardGroup] {
        // Scene Placement has no control since the Decode curve replaced it (2026-10-24): a box
        // for it would be a box for something that cannot be seen. Decode is the white balance
        // and the curve.
        [.filmAndPaper, .filmExposure, .format, .filmEdgeAndDateBack,
         .enlarger, .decode, .couplers, .preflash, .light, .curve, .colour]
            .filter { $0 != .filmEdgeAndDateBack || FeatureFlags.filmEdge || FeatureFlags.dateBack }
    }

    /// Ticked when the sheet opens: everything but the film edge.
    static var defaultSelection: Set<ClipboardGroup> {
        Set(offered.filter { $0 != .filmEdgeAndDateBack })
    }

    /// The groups last ticked on the Copy Settings sheet, kept: what the Mac's ⌘C copies without
    /// asking, and what the Mac's sheet opens with. (Capture One's ⇧⌘C copies at once too; which groups
    /// it takes is set beforehand in its Adjustments Clipboard tool, where this app has the sheet.) Never copied yet, or nothing left that is still offered: `defaultSelection`.
    static let rememberedKey = "clipboard.groups"
    static func remembered(in defaults: UserDefaults = .standard) -> Set<ClipboardGroup> {
        let kept = Set((defaults.stringArray(forKey: rememberedKey) ?? []).compactMap(ClipboardGroup.init(rawValue:)))
            .intersection(offered)
        return kept.isEmpty ? defaultSelection : kept
    }
    static func remember(_ groups: Set<ClipboardGroup>, in defaults: UserDefaults = .standard) {
        guard !groups.isEmpty else { return }
        defaults.set(groups.map(\.rawValue).sorted(), forKey: rememberedKey)
    }

    var title: String {
        switch self {
        case .filmExposure: L("Film Exposure")
        case .format: L("Format", as: "the develop tab")
        case .decode: L("Decode")
        case .enlarger: L("Enlarger")
        case .couplers: L("Couplers")
        case .preflash: L("Pre-flash")
        case .filmAndPaper: L("Film & Paper")
        case .exposure: L("Exposure")
        case .whiteBalance: L("White Balance")
        case .filmEffects: L("Film Effects")
        case .printEffects: L("Print Effects")
        case .scenePlacement: L("Scene Placement")
        case .filmEdgeAndDateBack: L("Film Edge & Date Back")
        case .light, .curve, .colour: layer2Tool?.title ?? ""
        }
    }

    /// The Layer 2 tool a group carries; nil for the darkroom's groups.
    var layer2Tool: Adjustments.Tool? {
        switch self {
        case .light: .light
        case .curve: .curve
        case .colour: .colour
        default: nil
        }
    }

    /// The group's contents for one frame, as the sheet says them under the
    /// title: "Porta 400 · Supera Enduro", "Film +0.3 EV · Brightness 0".
    func summary(of edit: FrameEdit, catalog: StockCatalog = .shared) -> String {
        let p = edit.params
        switch self {
        case .filmExposure: return Fmt.signed(p.exposureCompensationEV) + " EV"
        case .format: return p.filmFrame + Fmt.dot + L("Grain") + " " + Fmt.times(p.effects.grain) + Fmt.dot + L("Halation") + " " + Fmt.times(p.effects.halation)
        case .decode:
            let balance = L(shown: edit.decode.whiteBalance.rawValue)
            return p.sceneCurve.isIdentity ? balance : balance + Fmt.dot + L("Curve")
        case .enlarger: return Fmt.signed(p.printBrightnessStops) + " EV" + Fmt.dot + Fmt.signed(p.yFilterShift) + Fmt.dot + Fmt.signed(p.mFilterShift)
        case .couplers: return Fmt.times(p.effects.couplers)
        case .preflash: return String(format: "%.3f", p.preflashExposure)
        case .filmAndPaper:
            return catalog.pairText(p)
        case .exposure:
            return L("Film \(Fmt.signed(p.exposureCompensationEV)) EV · Brightness \(Fmt.signed(p.printBrightnessStops, decimals: 0))")
        case .whiteBalance:
            return [edit.decode.whiteBalance.rawValue,
                    L("Yellow ") + Fmt.signed(p.yFilterShift, decimals: 2),
                    L("Magenta ") + Fmt.signed(p.mFilterShift, decimals: 2)].joined(separator: " · ")
        case .filmEffects:
            return String(format: L("%@ · Grain %.1f · Halation %.1f · Glare %.1f"), p.filmFrame, p.effects.grain,
                          p.effects.halation, p.effects.glare)
        case .printEffects:
            return p.preflashExposure == 0 ? L("Pre-flash 0") : String(format: L("Pre-flash %.3f"), p.preflashExposure)
        case .scenePlacement:
            let h = p.sceneLatitude.highlightPullBack, s = p.sceneLatitude.shadowPullBack
            if h == 0 && s == 0 { return L("Off") }
            return [h > 0 ? String(format: L("Highlight %.2f"), h) : nil,
                    s > 0 ? String(format: L("Shadow %.2f"), s) : nil].compactMap { $0 }.joined(separator: " · ")
        case .filmEdgeAndDateBack:
            let e = edit.filmEdge.active ? "\(edit.filmEdge.format.label) · \(edit.filmEdge.mode.label)" : L("No film edge")
            let d = edit.dateBack.active ? L("\(edit.dateBack.style.label) date") : L("No date")
            return "\(e) · \(d)"
        case .light, .curve, .colour:
            return layer2Tool.map { edit.adjustments.summary($0) } ?? ""
        }
    }
}

struct SettingsClip: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case groups = "groups", settings = "settings", sourceName = "sourceName", sourceAspect = "sourceAspect"
    }
    var groups: Set<ClipboardGroup>
    /// The source frame's settings when it was copied.
    var settings: FrameEdit
    /// The source frame's file name, for the "what is held" line.
    var sourceName: String
    /// The source picture's shape as its person had it when it was copied — turned by its crop's
    /// quarter turns, not cut (`SettingsClip.shownAspect`): what its film edge's turn is a choice
    /// against. Nil for a clip made without a picture (a tour's, a preset saved before 2026-11-05), whose
    /// film keeps only its half turn. Display data, never a path: it may enter a preset.
    var sourceAspect: Double? = nil

    /// "Clipboard: Film & Paper, Exposure · 2 of 6": what Select says above Paste.
    var summary: String {
        let held = ClipboardGroup.offered.filter(groups.contains)
        return L("Clipboard: ") + held.map(\.title).joined(separator: ", ")
            + L("  ·  \(held.count) of \(ClipboardGroup.offered.count)")
    }

    /// `target` with this clip's groups written into it, and nothing else. Pure:
    /// the whole meaning of a paste, testable without a page or an engine.
    /// `picture`: the target's photograph (`LibraryFrame.originalSize`), which a
    /// pasted film edge lies along. Required, so that no paste forgets it (the
    /// owner's upright-onto-wide film edge, 2026-11-05, was a paste that had none).
    func applied(to target: FrameEdit, picture: PixelSize) -> FrameEdit {
        // A picture of no size yet (a frame not probed) has no shape to place the film on: the turn travels
        // as it was copied, as it did before the turn was placed (PixelSize.aspect reads 1 at 0 x 0).
        guard picture.width > 0, picture.height > 0 else { return written(to: target, shown: nil) }
        return written(to: target, shown: Self.shownAspect(picture, quarterTurns: target.geometry.quarterTurns))
    }

    /// The picture's shape as the user has it: turned, not cropped (`FilmEdgeFlow.pictureAspect`).
    static func shownAspect(_ picture: PixelSize, quarterTurns: Int) -> Double {
        let a = picture.aspect
        return quarterTurns % 2 == 0 ? a : 1 / max(a, 0.0001)
    }

    /// The paste itself. `shown`: the target picture's shape as turned, which a pasted film edge's turn
    /// is placed on; nil for `transferable`, which is no paste onto a picture and keeps the source's
    /// turn as it is (placed when the preset is applied), and for a picture of no size.
    private func written(to target: FrameEdit, shown: Double?) -> FrameEdit {
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
            // The target's report is of the target's old meter.
            if meterChanged { out.solvedEV = nil }
        }
        if groups.contains(.whiteBalance) {
            out.decode.whiteBalance = s.decode.whiteBalance
            // As Shot is the *target's* camera: its numbers are its own.
            if s.decode.whiteBalance != .asShot {
                out.decode.temperature = s.decode.temperature
                out.decode.tint = s.decode.tint
            }
            out.params.yFilterShift = s.params.yFilterShift
            out.params.mFilterShift = s.params.mFilterShift
        }
        if groups.contains(.filmEffects) {
            out.params.filmFormatMM = s.params.filmFormatMM
            out.params.filmFrame = s.params.filmFrame
            out.params.filmSide = s.params.filmSide
            out.params.sideLengthMM = s.params.sideLengthMM
            out.params.grainActive = s.params.grainActive
            out.params.halationActive = s.params.halationActive
            out.params.antihalationRemoved = s.params.antihalationRemoved
            out.params.glareActive = s.params.glareActive
            out.params.effects = s.params.effects
        }
        if groups.contains(.printEffects) {
            out.params.printEffects = s.params.printEffects
            out.params.preflashExposure = s.params.preflashExposure
        }
        if groups.contains(.scenePlacement) {
            // The intent and the Fit's inputs; the curve stays the identity
            // until the target's own Fit lands.
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
        if groups.contains(.filmEdgeAndDateBack) {
            // The film and its date travel; the picture's place in the gate
            // is this frame's own, as a crop is, and a frame keeps its body.
            let (framing, body) = (out.filmEdge.framing, out.filmEdge.cameraSeed)
            out.filmEdge = s.filmEdge
            // And the film lies the way *this* picture does (the owner, 2026-11-05: an upright
            // picture's film edge pasted onto a wide one came out upright). What travels is the
            // source's turn against its own picture's lie (`turn(of:from:onto:)`).
            if let shown { out.filmEdge.turn = Self.turn(of: s.filmEdge, from: sourceAspect, onto: shown) }
            out.filmEdge.framing = out.filmEdge.format == target.filmEdge.format && out.filmEdge.turn == target.filmEdge.turn ? framing : nil
            if body > 0 { out.filmEdge.cameraSeed = body }
            out.dateBack = s.dateBack
        }
        if groups.contains(.filmExposure) {
            let meterChanged = out.params.autoExposure != s.params.autoExposure || out.params.autoExposureMethod != s.params.autoExposureMethod
            out.params.autoExposure = s.params.autoExposure
            out.params.autoExposureMethod = s.params.autoExposureMethod
            out.params.exposureCompensationEV = s.params.exposureCompensationEV
            if meterChanged { out.solvedEV = nil }
        }
        if groups.contains(.format) {
            out.params.filmFrame = s.params.filmFrame; out.params.filmSide = s.params.filmSide
            out.params.sideLengthMM = s.params.sideLengthMM; out.params.filmFormatMM = s.params.filmFormatMM
            out.params.effects.grain = s.params.effects.grain
            out.params.effects.halation = s.params.effects.halation
            out.params.antihalationRemoved = s.params.antihalationRemoved
        }
        if groups.contains(.decode) {
            out.decode.whiteBalance = s.decode.whiteBalance
            if s.decode.whiteBalance != .asShot {
                out.decode.temperature = s.decode.temperature; out.decode.tint = s.decode.tint
            }
            out.params.sceneCurve = s.params.sceneCurve
        }
        if groups.contains(.enlarger) {
            out.params.printBrightnessStops = s.params.printBrightnessStops
            out.params.yFilterShift = s.params.yFilterShift; out.params.mFilterShift = s.params.mFilterShift
        }
        if groups.contains(.couplers) {
            out.params.effects.couplers = s.params.effects.couplers
            out.params.effects.couplersActive = s.params.effects.couplersActive
        }
        if groups.contains(.preflash) { out.params.preflashExposure = s.params.preflashExposure }
        // Edit's tools: each group its own fields of Layer 2, nothing else.
        for group in groups.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let tool = group.layer2Tool { out.adjustments.take(tool, from: s.adjustments) }
        }
        return out
    }

    /// The turn a pasted film edge takes on a picture shown at aspect `shown`: the format's own lie for
    /// it, and on top of that the source's turn against the source picture's own lie —
    /// `defaultTurn(target) + (source.turn − defaultTurn(source)) mod 4`. A film the person left lying
    /// the format's way lies this picture's way; one turned a half (the name below or on the left) or a
    /// quarter against it (a film across an upright picture) is turned the same against this one
    /// (the review, 2026-11-05). With the source's shape unknown (`sourceAspect` nil), only the half
    /// turn is known to be a choice, as a format card keeps it (`FilmEdgeColumn.pick`).
    static func turn(of edge: FilmEdgeSettings, from source: Double?, onto shown: Double) -> Int {
        let lie = edge.format.defaultTurn(pictureAspect: shown)
        guard let source else { return lie + (edge.turn >= 2 ? 2 : 0) }
        let chosen = ((edge.turn - edge.format.defaultTurn(pictureAspect: source)) % 4 + 4) % 4
        return (lie + chosen) % 4
    }
}


extension SettingsClip {
    /// Names are display metadata, never paths. Source-bound and solved state cannot enter a preset.
    var transferable: SettingsClip {
        // A preset is no paste onto a picture: the film keeps the source's turn, and the source's shape
        // goes with it (`sourceAspect`), so the preset's own paste places it.
        var clean = written(to: .default, shown: nil)
        clean.solvedEV = nil; clean.placementNeedsFit = false
        clean.geometry = .default; clean.frameSeed = FrameEdit.default.frameSeed
        clean.decode.lensCorrection = false
        if clean.decode.whiteBalance == .asShot {
            clean.decode.temperature = DecodeSettings().temperature; clean.decode.tint = DecodeSettings().tint
        }
        clean.filmEdge.framing = nil; clean.filmEdge.cameraSeed = 0
        return SettingsClip(groups: groups, settings: clean, sourceName: "", sourceAspect: sourceAspect)
    }

    /// What a paste or a preset says when this build lacks a film or paper the clip carries:
    /// "Unavailable materials: <ids>" (the preset sheet's line, and the Mac paste's); nil with none.
    var missingMaterialsLine: String? {
        let missing = missingMaterials
        return missing.isEmpty ? nil : L("Unavailable materials") + ": " + missing.joined(separator: ", ")
    }

    var missingMaterials: [String] {
        guard groups.contains(.filmAndPaper) else { return [] }
        let c = StockCatalog.shared, p = settings.params
        let filmMissing = !c.films.contains { $0.id == p.filmStock }
        let prints = !c.isSlide(p.filmStock) && !p.scanFilm && !p.digitalIntermediate
        let paperMissing = prints && (!c.papers.contains { $0.id == p.printStock } || !c.canPrint(film: p.filmStock, on: p.printStock))
        return [filmMissing ? p.filmStock : nil, paperMissing ? p.printStock : nil].compactMap { $0 }

    }
}
