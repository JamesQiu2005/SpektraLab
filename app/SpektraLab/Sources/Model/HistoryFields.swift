//  HistoryFields.swift — the table of named fields a develop step's label is made from (PRD-F §3.4).
//
//  A step of the develop page (冲洗 or 编辑), a reset, a card, a pair's or a double's piece changed from the grid is
//  named from the difference between the state it began from and the one it left: the control's name as the UI
//  shows it, and the new value where there is one (*Film Exposure +0.3*, *Film: Portra 400*, *Crop*). Several of one
//  group: the group's name (*Film Edge*). Several groups: the first one's name and *+2 more* (另 2 项), the first in
//  the develop column's order. A field no control sets reads *Adjustment* (调整), never a raw key.
//
//  **One vocabulary.** A name here is the key the UI looks its own word up with (`L("Film Exposure")`,
//  `L("Tint", as: "the colour shift")`, `Layer2Control.title`), kept as a key (`HistoryLabel`): the page looks it up
//  where it shows it, so a language switch relabels every step, and the two words cannot drift apart without
//  `tools/history_label_selftest.swift` (the Layer 2 names against `Layer2Control.title`) or
//  `tools/localization_check.py` (a key the catalog lacks) saying so.
//
//  **Every field is accounted for.** Each entry says which of a revision's fields it covers, as the revision's JSON
//  spells them (`DevelopRevision`'s `Codable`); a field that is no person's edit is in `observations`, one no
//  control sets in `unnamed`, each with its reason. `tools/history_label_selftest.swift` walks every field of a
//  revision whose every optional is set (a photograph's edit, a pair's piece, a double's, the members' decodes),
//  changes each one alone and holds the step's label to the one entry that covers it: a field added later (PRD-E's
//  layers) that no entry covers fails it, and cannot read *Adjustment* without someone writing so in `unnamed`.
//
//  **The cost.** It runs on the main actor at record time, inside PRD-F §5's 1 ms with the snapshot and the
//  hand-off: one comparison per entry over the two states, no encoding; a name and value are made only for the
//  entries that differ. Measured by the self-test and by `--history-check` (`OpenFrameSession.recordMillis`).

import Foundation

/// A group of controls as the develop column shows them, in its order: the first group a step moved names it.
enum HistoryGroup: Int, CaseIterable, Sendable {
    case filmEmulation, decode, film, paper, enlarger, placement, effects, hdr
    case size, filmEdge, dateBack, crop, leak, lens, pair, double
    case light, curve, colour, edit
    /// 图层's mask layers (PRD-E): last, so a step that moved a layer and a whole-picture control is named by the
    /// whole picture's (the column's order puts the panel's rows above, but a layer's step is its own gesture).
    case layers

    /// The group's own name, as its section header or tool says it.
    var label: HistoryLabel {
        switch self {
        case .filmEmulation: HistoryLabel("Apply Film Emulation")
        case .decode: HistoryLabel("Decode")
        case .film: HistoryLabel("Film")
        case .paper: HistoryLabel("Paper")
        case .enlarger: HistoryLabel("Enlarger")
        case .placement: HistoryLabel("Scene Placement")
        case .effects: HistoryLabel("Effects")
        case .hdr: HistoryLabel("High Dynamic Range")
        case .size: HistoryLabel("Size")
        case .filmEdge: HistoryLabel("Film Edge")
        case .dateBack: HistoryLabel("Date Back")
        case .crop: HistoryLabel("Crop")
        case .leak: HistoryLabel("Light Leak")
        case .lens: HistoryLabel("Lens", as: "the edit section")
        case .pair: HistoryLabel("Half-Frame Pair")
        case .double: HistoryLabel("Double Exposure")
        case .light: HistoryLabel("Light")
        case .curve: HistoryLabel("Curve")
        case .colour: HistoryLabel("Colour")
        case .edit: HistoryLabel("Edit")
        case .layers: HistoryLabel("Layers")
        }
    }
}

/// One named control of a frame's edit.
struct HistoryField {
    /// The fields it covers, as a revision's JSON spells them: `edit.params.filmStock`. A path that ends at an object
    /// covers what is under it; `[]` is any element of an array, `*` any key of a dictionary (a member's id).
    let paths: [String]
    let group: HistoryGroup
    /// Whether the two states differ in it.
    let differs: (DevelopRevision, DevelopRevision) -> Bool
    /// Its name, with the new value where it has one, from the state the step left. A mask layer's step is named
    /// for the layer it moved, which only the two states together tell (`layerField`); every other entry reads the
    /// state the step left alone.
    let named: (_ before: DevelopRevision, _ after: DevelopRevision) -> HistoryLabel
}

enum HistoryFields {
    // MARK: what is not a control

    /// Fields that are no person's edit: readings, provenance, the file's own bookkeeping. A step never moves them
    /// alone (`DevelopRevision.keepingReports`, `isSameEdit`), and they never name one.
    static let observations: [String: String] = [
        "edit.schemaVersion": "the edit's format, written by the build",
        "edit.decoder": "which decoder read the file: the build's, never a control",
        "edit.solvedEV": "the meter's reading, refilled by every develop (keepingReports)",
        "edit.rawExposureFacts": "the RAW decode's provenance, read back (isSameEdit)",
        "edit.placementNeedsFit": "a placement still owed its Fit, set by the page as it opens (isSameEdit)",
        "edit.decode.rawExposureTreatment": "how a RAW's exposure was read: a migration's, no control",
        "pair.schemaVersion": "the piece's format", "pair.folder": "where the piece's file is", "pair.origin": "the frame it was made from",
        "pair.left.meteredEV": "the meter's reading for this hole (keepingReports)", "pair.right.meteredEV": "the meter's reading for this hole",
        "pair.left.meteredFor": "what the reading was for", "pair.right.meteredFor": "what the reading was for",
        "pair.left.decode.rawExposureTreatment": "a migration's", "pair.right.decode.rawExposureTreatment": "a migration's",
        "double.schemaVersion": "the piece's format", "double.folder": "where the piece's recipe is", "double.origin": "the frame it was made from",
        "double.exposures[].meterReadings": "the meter's readings, by exposure (keepingReports)",
        "double.exposures[].decode.rawExposureTreatment": "a migration's",
        "sourceDecodes.*.rawExposureTreatment": "a migration's",
        "edit.layers.version": "the layers' format, written by the build (PRD-E)",
        "edit.layers.items[].madeOn": "the decode geometry a mask was made on: set when it is made, read by the row's mark (RFC-052 §8.1)",
    ]

    /// Fields a person's edit can change but no control of this build sets by itself: a step that moves only these
    /// reads *Adjustment*. A paste or a preset can carry them, and is named by its own label.
    static let unnamed: [String: String] = [
        "edit.params.contrastMask": "the Tone Mask, withdrawn (RFC-028): no control sets it",
        "edit.params.printEffects": "Print Effects: a group of Copy Settings, no switch on the Mac's page",
    ]

    // MARK: the table

    private static func on(_ b: Bool) -> String { b ? "On" : "Off" }

    private static func f<V: Equatable>(_ paths: [String], _ group: HistoryGroup, _ get: @escaping (DevelopRevision) -> V,
                                        _ named: @escaping (DevelopRevision) -> HistoryLabel) -> HistoryField {
        HistoryField(paths: paths, group: group, differs: { get($0) != get($1) }, named: { _, after in named(after) })
    }

    typealias Differs = (DevelopRevision, DevelopRevision) -> Bool
    /// Whether two states differ in what `get` reads.
    private static func by<V: Equatable>(_ get: @escaping (DevelopRevision) -> V) -> Differs { { get($0) != get($1) } }
    /// An entry over several fields: it differs where any of them does.
    private static func d(_ paths: [String], _ group: HistoryGroup, _ differs: [Differs],
                          _ named: @escaping (DevelopRevision) -> HistoryLabel) -> HistoryField {
        HistoryField(paths: paths, group: group, differs: { a, b in differs.contains { $0(a, b) } }, named: { _, after in named(after) })
    }

    private static func f<V: Equatable>(_ path: String, _ group: HistoryGroup, _ get: @escaping (DevelopRevision) -> V,
                                        _ named: @escaping (DevelopRevision) -> HistoryLabel) -> HistoryField {
        f([path], group, get, named)
    }

    /// A field of both holes of a pair.
    private static func holes(_ field: String) -> [String] { ["pair.left." + field, "pair.right." + field] }
    /// One of 镜头校正's fields of the decode, wherever a revision has a decode: the photograph's, a pair's holes', a
    /// double's exposures', the members'.
    private static func lensPaths(_ field: String) -> [String] {
        ["edit.decode." + field] + holes("decode." + field) + ["double.exposures[].decode." + field, "sourceDecodes.*." + field]
    }
    private static func lensDiffers<V: Equatable>(_ key: KeyPath<DecodeSettings, V>) -> [Differs] {
        [by { $0.edit.decode[keyPath: key] }, by { sides($0, { $0.decode[keyPath: key] }) },
         by { exposures($0, { $0.decode[keyPath: key] }) }, by { members($0, { $0[keyPath: key] }) }]
    }
    private static func sides<V: Equatable>(_ r: DevelopRevision, _ get: (HalfFramePair.Hole) -> V) -> [V?] {
        [r.pair?.left.map(get), r.pair?.right.map(get)]
    }
    private static func exposures<V: Equatable>(_ r: DevelopRevision, _ get: (DoubleExposure.Exposure) -> V) -> [V?] {
        r.double?.exposures.map { $0.map(get) } ?? []
    }
    private static func members<V: Equatable>(_ r: DevelopRevision, _ get: (DecodeSettings) -> V) -> [UUID: V] {
        r.sourceDecodes.mapValues(get)
    }

    private static func stock(_ id: String) -> String { StockCatalog.shared.stock(id)?.shortName ?? id }

    /// A film edge with its switch left out: what the Film Edge flow sets besides it.
    private static func edgeShape(_ r: DevelopRevision) -> FilmEdgeSettings {
        var e = r.edit.filmEdge
        e.active = false
        return e
    }
    private static func dateShape(_ r: DevelopRevision) -> DateBackSettings {
        var d = r.edit.dateBack
        d.active = false
        return d
    }

    /// Edit's Layer 2 controls (`Layer2Control`): their names and numbers as the sliders show them.
    private static func layer2(_ control: Layer2Control, _ path: String, _ key: HistoryLabel) -> HistoryField {
        f(path, control.tool == .colour ? .colour : .light, { $0.edit.adjustments[control] }) { r in
            var label = key
            label.value = control.text(r.edit.adjustments[control]) + (control == .exposure ? " EV" : "")
            return label
        }
    }

    /// The table, in the develop column's order (`HistoryGroup`).
    static let table: [HistoryField] = [
        // Film & Paper › Apply Film Emulation.
        f("edit.filmOff", .filmEmulation, { $0.edit.filmOff }) { r in HistoryLabel("Apply Film Emulation", valueKey: on(r.edit.appliesFilm)) },
        // Decode: Film Exposure and its meter, white balance, lens correction, the decode curve; a pair's holes' and a
        // double's exposures' own, and the members' decodes a piece moved.
        f("edit.params.exposureCompensationEV", .decode, { $0.edit.params.exposureCompensationEV }) { r in
            HistoryLabel("Film Exposure", value: Fmt.signed(r.edit.params.exposureCompensationEV))
        },
        d(["edit.params.autoExposure", "edit.params.autoExposureMethod"], .decode,
          [by { $0.edit.params.autoExposure }, by { $0.edit.params.autoExposureMethod }]) { r in
            HistoryLabel("Meter", valueKey: on(r.edit.params.autoExposure))
        },
        d(holes("exposureEV") + ["double.exposures[].exposureEV"], .decode,
          [by { sides($0, \.exposureEV) }, by { exposures($0, \.exposureEV) }]) { _ in HistoryLabel("Film Exposure") },
        d(holes("autoExposure") + holes("meterMethod") + ["double.exposures[].autoExposure", "double.exposures[].meterMethod"], .decode,
          [by { sides($0, \.autoExposure) }, by { sides($0, \.meterMethod) }, by { exposures($0, \.autoExposure) }, by { exposures($0, \.meterMethod) }]) { _ in
            HistoryLabel("Meter")
        },
        f("edit.decode.whiteBalance", .decode, { $0.edit.decode.whiteBalance }) { _ in HistoryLabel("White Balance") },
        f("edit.decode.temperature", .decode, { $0.edit.decode.temperature }) { r in
            HistoryLabel("Temperature", value: "\(Int(r.edit.decode.temperature.rounded())) K")
        },
        f("edit.decode.tint", .decode, { $0.edit.decode.tint }) { r in HistoryLabel("Tint", value: Fmt.signed(r.edit.decode.tint, decimals: 0)) },
        d(holes("decode.whiteBalance") + holes("decode.temperature") + holes("decode.tint")
            + ["double.exposures[].decode.whiteBalance", "double.exposures[].decode.temperature", "double.exposures[].decode.tint",
               "sourceDecodes.*.whiteBalance", "sourceDecodes.*.temperature", "sourceDecodes.*.tint"], .decode,
          [by { sides($0, \.decode.whiteBalance) }, by { sides($0, \.decode.temperature) }, by { sides($0, \.decode.tint) },
           by { exposures($0, \.decode.whiteBalance) }, by { exposures($0, \.decode.temperature) }, by { exposures($0, \.decode.tint) },
           by { members($0, \.whiteBalance) }, by { members($0, \.temperature) }, by { members($0, \.tint) }]) { _ in
            HistoryLabel("White Balance")
        },
        d(["edit.decode.lensCorrection"] + holes("decode.lensCorrection") + ["double.exposures[].decode.lensCorrection", "sourceDecodes.*.lensCorrection"],
          .decode, [by { $0.edit.decode.lensCorrection }, by { sides($0, \.decode.lensCorrection) }, by { exposures($0, \.decode.lensCorrection) },
                    by { members($0, \.lensCorrection) }]) { r in
            HistoryLabel("Lens correction", valueKey: on(r.edit.decode.lensCorrection))
        },
        // 镜头校正's others (2.4.0): 配置文件, 畸变, 光衰减, 隐藏畸变区域 — a photograph's, a pair's holes', a double's
        // exposures', the members' decodes.
        d(lensPaths("lensProfile"), .decode, lensDiffers(\.lensProfile)) { r in
            r.edit.decode.lensProfile.map { HistoryLabel("Lens Profile", value: $0.name) } ?? HistoryLabel("Lens Profile", valueKey: "Automatic")
        },
        d(lensPaths("lensDistortion"), .decode, lensDiffers(\.lensDistortion)) { r in
            HistoryLabel("Distortion", value: DecodeSettings.amountWord(r.edit.decode.lensDistortion.rounded()))
        },
        d(lensPaths("lensLightFalloff"), .decode, lensDiffers(\.lensLightFalloff)) { r in
            HistoryLabel("Light Falloff", value: DecodeSettings.amountWord(r.edit.decode.lensLightFalloff.rounded()))
        },
        d(lensPaths("lensHideDistortedAreas"), .decode, lensDiffers(\.lensHideDistortedAreas)) { r in
            HistoryLabel("Hide Distorted Areas", valueKey: on(r.edit.decode.lensHideDistortedAreas))
        },
        f("edit.params.sceneCurve", .decode, { $0.edit.params.sceneCurve }) { _ in HistoryLabel("Curve") },
        // Film, Paper.
        f("edit.params.filmStock", .film, { $0.edit.params.filmStock }) { r in HistoryLabel("Film", value: stock(r.edit.params.filmStock)) },
        f("edit.params.antihalationRemoved", .film, { $0.edit.params.antihalationRemoved }) { r in
            HistoryLabel("Remove anti-halation layer", valueKey: on(r.edit.params.antihalationRemoved))
        },
        f("edit.params.printStock", .paper, { $0.edit.params.printStock }) { r in HistoryLabel("Paper", value: stock(r.edit.params.printStock)) },
        f("edit.params.scanFilm", .paper, { $0.edit.params.scanFilm }) { r in HistoryLabel("Paper", valueKey: r.edit.params.scanFilm ? "Scanned" : "Printed") },
        f("edit.params.digitalIntermediate", .paper, { $0.edit.params.digitalIntermediate }) { r in
            HistoryLabel("Digital Intermediate", valueKey: on(r.edit.params.digitalIntermediate))
        },
        // Enlarger, and a pair's frames' own prints.
        f("edit.params.printBrightnessStops", .enlarger, { $0.edit.params.printBrightnessStops }) { r in
            HistoryLabel("Brightness", value: Fmt.signed(r.edit.params.printBrightnessStops))
        },
        f("edit.params.yFilterShift", .enlarger, { $0.edit.params.yFilterShift }) { r in HistoryLabel("Yellow", value: Fmt.signed(r.edit.params.yFilterShift, decimals: 2)) },
        f("edit.params.mFilterShift", .enlarger, { $0.edit.params.mFilterShift }) { r in HistoryLabel("Magenta", value: Fmt.signed(r.edit.params.mFilterShift, decimals: 2)) },
        f("edit.params.preflashExposure", .enlarger, { $0.edit.params.preflashExposure }) { r in
            HistoryLabel("Pre-flash", value: String(format: "%.2f", r.edit.params.preflashExposure / FilmParams.preflashMax))
        },
        f(holes("print"), .enlarger, { sides($0, \.print) }) { _ in HistoryLabel("Enlarger") },
        // Scene Placement: a frame's, and a pair's other frame's.
        d(["edit.params.sceneLatitude", "edit.params.sceneLatitudeOther", "edit.params.placementIsRight"], .placement,
          [by { $0.edit.params.sceneLatitude }, by { $0.edit.params.sceneLatitudeOther }, by { $0.edit.params.placementIsRight }]) { _ in
            HistoryLabel("Scene Placement")
        },
        // Effects.
        d(["edit.params.effects.grain", "edit.params.grainActive"], .effects, [by { $0.edit.params.effects.grain }, by { $0.edit.params.grainActive }]) { r in
            r.edit.params.grainActive ? HistoryLabel("Grain", value: Fmt.times(r.edit.params.effects.grain)) : HistoryLabel("Grain", valueKey: "Off")
        },
        f("edit.params.effects.grainLayered", .effects, { $0.edit.params.effects.grainLayered }) { r in
            HistoryLabel("Sub-layers", valueKey: on(r.edit.params.effects.grainLayered))
        },
        d(["edit.params.effects.halation", "edit.params.halationActive"], .effects,
          [by { $0.edit.params.effects.halation }, by { $0.edit.params.halationActive }]) { r in
            r.edit.params.halationActive ? HistoryLabel("Halation", value: Fmt.times(r.edit.params.effects.halation)) : HistoryLabel("Halation", valueKey: "Off")
        },
        f("edit.params.effects.scatter", .effects, { $0.edit.params.effects.scatter }) { r in
            HistoryLabel("Scatter", value: String(format: "%.2f", r.edit.params.effects.scatter))
        },
        d(["edit.params.effects.couplers", "edit.params.effects.couplersActive"], .effects,
          [by { $0.edit.params.effects.couplers }, by { $0.edit.params.effects.couplersActive }]) { r in
            r.edit.params.effects.couplersActive ? HistoryLabel("Couplers", value: Fmt.times(r.edit.params.effects.couplers)) : HistoryLabel("Couplers", valueKey: "Off")
        },
        d(["edit.params.effects.glare", "edit.params.glareActive"], .effects, [by { $0.edit.params.effects.glare }, by { $0.edit.params.glareActive }]) { r in
            r.edit.params.glareActive ? HistoryLabel("Glare", value: String(format: "%.1f×", r.edit.params.effects.glare)) : HistoryLabel("Glare", valueKey: "Off")
        },
        // High Dynamic Range. Enable HDR by the stored choice, never by `hdr` (`FrameEdit.hdr`).
        f("edit.params.extendedDynamicRange", .hdr, { $0.edit.params.extendedDynamicRange }) { r in
            HistoryLabel("Extended Dynamic Range (EDR)", valueKey: on(r.edit.params.extendedDynamicRange))
        },
        f("edit.hdr", .hdr, { $0.edit.hdrChoice }) { r in HistoryLabel("Enable HDR", valueKey: on(r.edit.hdr)) },
        f("edit.hdrPeak", .hdr, { $0.edit.hdrPeakStops }) { r in HistoryLabel("HDR Peak Brightness", value: String(format: "%.1f EV", r.edit.hdrPeak)) },
        // Format › Size (the film's long edge in mm is derived from the three, and moves with them).
        d(["edit.params.filmFrame", "edit.params.filmSide", "edit.params.sideLengthMM", "edit.params.filmFormatMM"], .size,
          [by { $0.edit.params.filmFrame }, by { $0.edit.params.filmSide }, by { $0.edit.params.sideLengthMM }, by { $0.edit.params.filmFormatMM }]) { r in
            HistoryLabel("Size", value: r.edit.params.filmFrame)
        },
        // Film Edge: its switch, what the flow sets besides it, the advance; a pair on its strip.
        f("edit.filmEdge.active", .filmEdge, { $0.edit.filmEdge.active }) { r in HistoryLabel("Film Edge", valueKey: on(r.edit.filmEdge.active)) },
        f(["edit.filmEdge.cameraSeed", "edit.filmEdge.edgeBrightness", "edit.filmEdge.fog", "edit.filmEdge.format", "edit.filmEdge.frameNumber",
           "edit.filmEdge.gate", "edit.filmEdge.holes", "edit.filmEdge.leaks", "edit.filmEdge.mode", "edit.filmEdge.turn",
           "edit.filmEdge.framing", "edit.filmEdge.perforation"], .filmEdge, edgeShape) { _ in
            HistoryLabel("Film Edge")
        },
        f("edit.frameSeed", .filmEdge, { $0.edit.frameSeed }) { _ in HistoryLabel("Another frame") },
        f("pair.onStrip", .filmEdge, { $0.pair?.onStrip }) { r in HistoryLabel("Film Edge", valueKey: on(r.pair?.onStrip ?? false)) },
        // Date Back.
        f("edit.dateBack.active", .dateBack, { $0.edit.dateBack.active }) { r in HistoryLabel("Date Back", valueKey: on(r.edit.dateBack.active)) },
        d(["edit.dateBack.alsoData", "edit.dateBack.brightness", "edit.dateBack.brightnessEV", "edit.dateBack.corner", "edit.dateBack.insetXMM",
           "edit.dateBack.insetYMM", "edit.dateBack.order", "edit.dateBack.placement", "edit.dateBack.size", "edit.dateBack.style",
           "edit.dateBack.customText"] + holes("dated"),
          .dateBack, [by(dateShape), by { sides($0, \.dated) }]) { _ in HistoryLabel("Date Back") },
        // Crop: the photograph's, a pair's frames' own, a double's exposures'.
        d(["edit.geometry"] + holes("geometry") + ["double.exposures[].cut"], .crop,
          [by { $0.edit.geometry }, by { sides($0, \.geometry) }, by { exposures($0, \.cut) }]) { _ in HistoryLabel("Crop") },
        // Light Leak, Lens.
        f("edit.leak", .leak, { $0.edit.leak }) { _ in HistoryLabel("Light Leak") },
        d(["edit.lens.filter", "edit.lens.strength"], .lens, [by { $0.edit.lens.filter }, by { $0.edit.lens.strength }]) { _ in HistoryLabel("Soft Filter") },
        d(["edit.lens.character", "edit.lens.amount"], .lens, [by { $0.edit.lens.character }, by { $0.edit.lens.amount }]) { _ in
            HistoryLabel("Character", as: "a lens")
        },
        // A half-frame pair's piece: its frames, where each sits under its hole, what an edit of one moves, its gap,
        // level or turned, where the second frame begins.
        d(holes("path") + holes("frame") + holes("placement") + holes("printScope") + holes("exposureScope")
            + ["pair.spacingMM", "pair.turned", "edit.params.pairSplit"], .pair,
          [by { sides($0, \.path) }, by { sides($0, \.frame) }, by { sides($0, \.placement) }, by { sides($0, \.printScope) },
           by { sides($0, \.exposureScope) }, by { $0.pair?.spacingMM }, by { $0.pair?.turned }, by { $0.edit.params.pairSplit }]) { _ in
            HistoryLabel("Half-Frame Pair")
        },
        // A double exposure's piece: its exposures, and where each is laid (摆放).
        f("double.exposures[].frame", .double, { exposures($0, \.frame) }) { _ in HistoryLabel("Double Exposure") },
        f("double.exposures[].placement", .double, { exposures($0, \.placement) }) { _ in HistoryLabel("Arrange") },
        // Edit (编辑): Light, Curve, Colour, the layer's switch, Edit's crop, a pair's frames' own grade.
        layer2(.exposure, "edit.adjustments.exposure", HistoryLabel("Exposure")),
        layer2(.contrast, "edit.adjustments.contrast", HistoryLabel("Contrast")),
        layer2(.brightness, "edit.adjustments.brightness", HistoryLabel("Brightness")),
        layer2(.highlights, "edit.adjustments.highlights", HistoryLabel("Highlights")),
        layer2(.shadows, "edit.adjustments.shadows", HistoryLabel("Shadows")),
        layer2(.whites, "edit.adjustments.whitePoint", HistoryLabel("Whites")),
        layer2(.blacks, "edit.adjustments.blackPoint", HistoryLabel("Blacks")),
        layer2(.vignette, "edit.adjustments.vignette.amount", HistoryLabel("Vignette")),
        layer2(.vignetteMidpoint, "edit.adjustments.vignette.midpoint", HistoryLabel("Midpoint")),
        f("edit.adjustments.curves", .curve, { $0.edit.adjustments.curves }) { _ in HistoryLabel("Curve") },
        layer2(.temperature, "edit.adjustments.temperature", HistoryLabel("Temperature")),
        // Beside 色温 the tint is 着色 (`Layer2Control.title(in:)`), where the RAW's is 色调.
        layer2(.tint, "edit.adjustments.tint", HistoryLabel("Tint", as: "the colour shift")),
        layer2(.saturation, "edit.adjustments.saturation", HistoryLabel("Saturation")),
        layer2(.vibrance, "edit.adjustments.vibrance", HistoryLabel("Vibrance")),
        f("edit.adjustments.colorBalance", .colour, { $0.edit.adjustments.colorBalance }) { _ in HistoryLabel("Colour Wheels") },
        f("edit.adjustments.hsl", .colour, { $0.edit.adjustments.hsl }) { _ in HistoryLabel(key: "HSL") },
        f("edit.adjustments.channelMixer", .colour, { $0.edit.adjustments.channelMixer }) { _ in HistoryLabel("Channels") },
        f("edit.adjustments.enabled", .edit, { $0.edit.adjustments.enabled }) { r in HistoryLabel("Edit", valueKey: on(r.edit.adjustments.enabled)) },
        f("edit.printCrop", .edit, { $0.edit.printCrop }) { _ in HistoryLabel("Crop") },
        f(holes("adjustments"), .edit, { sides($0, \.adjustments) }) { _ in HistoryLabel("Edit") },
    ] + layerTable

    // MARK: mask layers (PRD-E)

    /// The layers of a state, by id.
    private static func layersOf(_ r: DevelopRevision) -> [LocalLayer] { r.edit.layers?.items ?? [] }

    /// The layers both states hold, matched by id, in the after state's order.
    private static func matched(_ a: DevelopRevision, _ b: DevelopRevision) -> [(LocalLayer, LocalLayer)] {
        let before = Dictionary(layersOf(a).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        return layersOf(b).compactMap { l in before[l.id].map { ($0, l) } }
    }

    /// One aspect of a layer: it differs where a layer both states hold differs in it, and the step is named for the
    /// first such layer — its name and the control (*主体 1 · 曝光 +0.5*), as PRD-F §3.4 asks (what a person did).
    /// A layer made, removed or reordered is the set's entry (`Layers`), never one of these.
    private static func layerField<V: Equatable>(_ paths: [String], _ get: @escaping (LocalLayer) -> V,
                                                 _ named: @escaping (LocalLayer) -> HistoryLabel) -> HistoryField {
        HistoryField(paths: paths.map { "edit.layers.items[]." + $0 }, group: .layers,
                     differs: { a, b in matched(a, b).contains { get($0.0) != get($0.1) } },
                     named: { a, b in
                         guard let (_, l) = matched(a, b).first(where: { get($0.0) != get($0.1) }) else { return .adjustment }
                         return named(l)
                     })
    }

    /// A layer's name as a label shows it: as it was named, or the stage's word where it has none.
    private static func title(_ l: LocalLayer) -> String { l.name.isEmpty ? L("Layers") : l.name }

    private static func scene<V: Equatable>(_ path: String, _ get: @escaping (SceneDeltas) -> V,
                                           _ named: @escaping (LocalLayer, SceneDeltas) -> HistoryLabel) -> HistoryField {
        layerField(["scene." + path], { $0.scene.map(get) }) { l in named(l, l.scene ?? SceneDeltas()) }
    }

    private static func finished(_ path: String, _ get: @escaping (FinishedDeltas) -> Double,
                                 _ named: @escaping (String, String) -> HistoryLabel) -> HistoryField {
        layerField(["finished." + path], { $0.finished.map(get) }) { l in
            named(title(l), Fmt.signed(get(l.finished ?? FinishedDeltas()), decimals: path == "exposure" ? 2 : 0))
        }
    }

    /// Every field of a mask layer, named: the set (made, removed, reordered), each layer's own switches and amounts,
    /// its mask's parts, its stage's controls one by one.
    static let layerTable: [HistoryField] = [
        // The set: a layer made or removed (its id is there or not), the panel's order.
        HistoryField(paths: ["edit.layers.items[].id"], group: .layers,
                     differs: { a, b in layersOf(a).map(\.id) != layersOf(b).map(\.id) },
                     named: { _, _ in HistoryLabel("Layers") }),
        layerField(["name"], { $0.name }) { l in HistoryLabel("Rename \(title(l))") },
        layerField(["on"], { $0.on }) { l in HistoryLabel("\(title(l)) · Visible", valueKey: on(l.on)) },
        layerField(["opacity"], { $0.opacity }) { l in HistoryLabel("\(title(l)) · Opacity", value: "\(Int((l.opacity * 100).rounded()))") },
        layerField(["feather"], { $0.feather }) { l in HistoryLabel("\(title(l)) · Feather") },
        layerField(["invert"], { $0.invert }) { l in HistoryLabel("\(title(l)) · Invert", valueKey: on(l.invert)) },
        layerField(["stage"], { $0.stage }) { l in HistoryLabel("\(title(l)) · Stage", valueKey: l.stage == .finished ? "Finished" : "Scene") },
        // The mask: a stroke, a gradient's drag, a part's join, eye or removal (one step each, PRD-E §5.4).
        layerField(["parts"], { $0.parts }) { l in HistoryLabel("\(title(l)) · Mask") },
        // 场景: 曝光, 色温, 色调 (RFC-052 §6.1). The 色调 is the decoder's word (`Tint`), as PRD-E §5.1 names it.
        scene("exposure", { $0.exposure }) { l, d in HistoryLabel("\(title(l)) · Exposure", value: Fmt.signed(d.exposure, decimals: 2) + " EV") },
        scene("temperature", { $0.temperature }) { l, d in HistoryLabel("\(title(l)) · Temperature", value: Fmt.signed(d.temperature, decimals: 0)) },
        scene("tint", { $0.tint }) { l, d in HistoryLabel("\(title(l)) · Tint", value: Fmt.signed(d.tint, decimals: 0)) },
        // 成片: Edit's scalar controls (RFC-052 §7), by Edit's own names (`Layer2Control.title`).
        finished("exposure", { $0.exposure }) { n, v in HistoryLabel("\(n) · Exposure", value: v + " EV") },
        finished("contrast", { $0.contrast }) { n, v in HistoryLabel("\(n) · Contrast", value: v) },
        finished("brightness", { $0.brightness }) { n, v in HistoryLabel("\(n) · Brightness", value: v) },
        finished("highlights", { $0.highlights }) { n, v in HistoryLabel("\(n) · Highlights", value: v) },
        finished("shadows", { $0.shadows }) { n, v in HistoryLabel("\(n) · Shadows", value: v) },
        // Blacks as its slider says it: −blackPoint (`Adjustments.blacks`, `MaskRules.finished`).
        finished("blackPoint", { -$0.blackPoint }) { n, v in HistoryLabel("\(n) · Blacks", value: v) },
        finished("whitePoint", { $0.whitePoint }) { n, v in HistoryLabel("\(n) · Whites", value: v) },
        finished("saturation", { $0.saturation }) { n, v in HistoryLabel("\(n) · Saturation", value: v) },
        finished("vibrance", { $0.vibrance }) { n, v in HistoryLabel("\(n) · Vibrance", value: v) },
        finished("temperature", { $0.temperature }) { n, v in HistoryLabel("\(n) · Temperature", value: v) },
        finished("tint", { $0.tint }) { n, v in HistoryLabel("\(n) · Tint", as: "the colour shift", value: v) },
    ]

    // MARK: naming a step

    /// The entries two states differ in, in the table's order.
    static func changed(from before: DevelopRevision, to after: DevelopRevision) -> [HistoryField] {
        table.filter { $0.differs(before, after) }
    }

    /// The step's label: one entry, its name and value; several of one group, the group's name; several groups,
    /// the first one's (the column's order) and *+N more* for the rest; none, *Adjustment*.
    static func label(from before: DevelopRevision, to after: DevelopRevision) -> HistoryLabel {
        var first: HistoryField?
        var groups = Set<HistoryGroup>()
        var count = 0
        for field in table where field.differs(before, after) {
            count += 1
            groups.insert(field.group)
            if first == nil || field.group.rawValue < first!.group.rawValue { first = field }
        }
        guard let first else { return .adjustment }
        if count == 1 { return first.named(before, after) }
        let ownGroup = table.filter { $0.group == first.group && $0.differs(before, after) }
        let name = ownGroup.count == 1 ? first.named(before, after) : first.group.label
        return name.and(more: groups.count - 1)
    }
}

/// Where a step is named.
enum HistoryLabels {
    /// **The label of a develop-page step**, from the difference between the state it began from and the one it
    /// left (`HistoryFields`). Runs on the main actor at record time, inside the 1 ms budget (PRD-F §5).
    static func develop(from before: DevelopRevision, to after: DevelopRevision) -> HistoryLabel {
        HistoryFields.label(from: before, to: after)
    }
}
