//  FrameEdit.swift — one frame's settings, in the app's own store.
//
//  The host's sidecar. Like the desktop's, it never writes the source: the
//  app never writes into the user's folders or their Photos library
//  (design/flow, "Never written to"). `DecodeSettings` and `CropRect` (the
//  latter in `Geometry.swift`, beside what uses it) are the desktop's own
//  (`Model/Sidecar.swift`, SpektraLab `unpublished-revision`, the maintainer's) so an edit
//  can move between the two.
//
//  `filmEdge` and `dateBack` (`Model/FilmEdge.swift`) are carried in every edit.
//
//  `adjustments` is Layer 2 (`Model/Adjustments.swift`): Edit's Light, Curve
//  and Colour, the desktop's field of the same name. Schema 4 (2026-10-15).
//  It is not part of a develop: no wire field, no stamp, no layer of
//  `ChangeDescriber.layers` — so moving one of its controls never develops.
//  An edit written before it reads with it neutral.

import CoreGraphics
import Foundation

struct DecodeSettings: Codable, Equatable, Hashable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case whiteBalance = "whiteBalance", temperature = "temperature", tint = "tint",
            lensCorrection = "lensCorrection", rawExposureTreatment = "rawExposureTreatment"
    }
    enum RawExposureTreatment: String, Codable, Sendable {
        case legacy = "legacy.1"
        case sourceReference = "source-reference.1"
        /// `source-reference.1` one stop brighter: the owner, 2026-10-23 — "the default auto
        /// exposure has a systematic -1 EV underexposure; the default 0 EV becomes what today's
        /// calculation gives at +1 EV". Measured on the Mac and the window alike (the same NEF
        /// with the same edit develops to the same picture on both, mean linear Y 0.188 against
        /// 0.193), so it is the source reference's, not the Mac's: a RAW's linear decode puts a
        /// camera's mid-grey about a stop under the film's 18.4 %. The stop is the decoder's
        /// own exposure (`CIRAWFilter.exposure` = +1, a linear x2 before the film), so Film
        /// Exposure still reads 0 and the print brightens as Film Exposure +1 did (the product's
        /// defaults leave the enlarger un-retimed). **New sources only**: an edit that carries
        /// `.1` keeps its picture — nothing stored is rewritten.
        case sourceReferencePlusOne = "source-reference.2"

        /// The decoder's exposure, in stops, above the file's own reference.
        var sourceOffsetEV: Double { self == .sourceReferencePlusOne ? 1 : 0 }
        /// The decoder keeps the file's reference (no shadow bias, no EXIF gain).
        var keepsSourceReference: Bool { self != .legacy }
    }
    enum WhiteBalance: String, Codable, CaseIterable, Sendable {
        case asShot = "As Shot", daylight = "Daylight", cloudy = "Cloudy", shade = "Shade",
             tungsten = "Tungsten", fluorescent = "Fluorescent", custom = "Custom"
        var kelvin: Double? {
            switch self {
            case .daylight: 5500
            case .cloudy: 6500
            case .shade: 7500
            case .tungsten: 3200
            case .fluorescent: 4000
            case .asShot, .custom: nil
            }
        }
    }
    var whiteBalance: WhiteBalance = .asShot
    /// Kelvin and tint actually applied at decode. For `.asShot` these are the
    /// camera's, filled in after the first decode; for presets the preset's.
    var temperature: Double = 5500
    var tint: Double = 0
    /// Apply the lens's own distortion and vignetting correction at decode: a
    /// RAW-only decode setting (`CIRAWFilter.isLensCorrectionEnabled`), and
    /// deliberately not an engine parameter. Off by default: it changes the
    /// frame's geometry.
    var lensCorrection: Bool = false
    /// New sources keep the decoder's exposure reference without shadow subtraction.
    /// Absent in an old sidecar means the exact old decode, not today's default.
    var rawExposureTreatment: RawExposureTreatment = .sourceReferencePlusOne

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whiteBalance = try c.decode(WhiteBalance.self, forKey: .whiteBalance)
        temperature = try c.decode(Double.self, forKey: .temperature)
        tint = try c.decode(Double.self, forKey: .tint)
        lensCorrection = try c.decode(Bool.self, forKey: .lensCorrection)
        rawExposureTreatment = try c.decodeIfPresent(RawExposureTreatment.self, forKey: .rawExposureTreatment) ?? .legacy
    }

    /// Shared by canvas, export, stock cards and pair source identity. Legacy
    /// keys stay byte-for-byte unchanged so existing developed copies survive.
    var pixelsKey: String {
        whiteBalance.rawValue + (whiteBalance != .asShot ? "|\(temperature)|\(tint)" : "")
            + (lensCorrection ? "|lens" : "") + exposureKey
    }

    var exposureKey: String {
        rawExposureTreatment == .legacy ? "" : "|raw=\(rawExposureTreatment.rawValue)"
    }
}

/// Read from the same RAW filter that supplies pixels. A report, never an
/// additional exposure adjustment or an input to another frame's decode.
struct RawExposureFacts: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case sourcePath = "sourcePath", treatment = "treatment", decoderVersion = "decoderVersion",
            baselineExposureEV = "baselineExposureEV", initialExposureEV = "initialExposureEV",
            initialShadowBias = "initialShadowBias", appliedExposureEV = "appliedExposureEV",
            appliedShadowBias = "appliedShadowBias", captureBiasEV = "captureBiasEV", captureISO = "captureISO",
            captureSeconds = "captureSeconds", captureFNumber = "captureFNumber"
    }
    var sourcePath: String
    var treatment: DecodeSettings.RawExposureTreatment
    var decoderVersion: String
    var baselineExposureEV: Double
    var initialExposureEV: Double
    var initialShadowBias: Double
    var appliedExposureEV: Double
    var appliedShadowBias: Double
    var captureBiasEV: Double?
    var captureISO: Double?
    var captureSeconds: Double?
    var captureFNumber: Double?
}

struct FrameEdit: Codable, Equatable, Sendable {
    /// 5 versions the RAW source-exposure treatment; old decodes remain legacy.
    static let currentSchema = 5
    var schemaVersion = FrameEdit.currentSchema
    var decoder = "coreimage"
    var decode = DecodeSettings()
    var params = FilmParams.default
    var geometry = Geometry.default
    var filmEdge = FilmEdgeSettings()
    var dateBack = DateBackSettings()
    /// The exposure the engine's meter solved, for the page to show. A report,
    /// refilled by the frame's own develop; never copied.
    var solvedEV: Double? = nil
    /// A pasted Scene Placement waits for this frame's own Fit (RFC-027 §4.1).
    var placementNeedsFit = false
    /// The advance and the scan: one per photograph (RFC-032 §26.1).
    var frameSeed = 1
    /// Layer 2: the scan of the print, adjusted afterwards (Edit's Light, Curve, Colour).
    var adjustments = Adjustments()
    var rawExposureFacts: RawExposureFacts? = nil
    /// **Edit's crop** (2026-10-20): a cut of the **finished** picture — the
    /// develop as it prints, in its film edge if it has one, with Edit's layer
    /// on it — where `geometry` is Develop's cut of the source before the film.
    /// The same arithmetic (`Geometry`), normalised to the finished picture,
    /// never with a perspective (`vertical`/`horizontal` stay 0). Nothing is
    /// developed for it: the pages draw the picture through it and an export
    /// cuts the file by it (`ExportPlan`, `FinishedCut`). Not part of any wire,
    /// stamp or develop.
    ///
    /// Absent from an edit written before it, which opens with none; written
    /// only when there is one, so an edit without it is the same JSON as before.
    var printCrop = Geometry.default
    /// **Apply Film Emulation** off (the owner, 2026-10-21: "just a on / off switch under film exposure
    /// called 'apply film emulation', and if that's toggled off, we simply grey out any film-related
    /// features in both develop and edit and the photos goes back to apple stock decode"): the frame
    /// is Apple's own decode of its file, cut by its crop, with Edit on top — no film, no paper, no
    /// engine (`EngineHost.digital`). What the film edge and the date back were is kept here while it
    /// is off, and given back when it is on again (`setAppliesFilm`): every other film setting stays
    /// where it was, unused. Nil — the film applies — for every edit before the switch existed.
    var filmOff: FilmOff? = nil

    struct FilmOff: Codable, Equatable, Sendable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case filmEdgeActive = "filmEdgeActive", dateBackActive = "dateBackActive" }
        var filmEdgeActive: Bool
        var dateBackActive: Bool
    }

    /// Whether the film is applied: the switch's state.
    var appliesFilm: Bool { filmOff == nil }

    /// The switch moved: off keeps the film edge's and the date back's own switches and turns both off
    /// (the engine draws them, and no engine runs); on puts them back as they were.
    mutating func setAppliesFilm(_ on: Bool) {
        if on, let off = filmOff {
            filmEdge.active = off.filmEdgeActive
            dateBack.active = off.dateBackActive
            filmOff = nil
        } else if !on, filmOff == nil {
            filmOff = FilmOff(filmEdgeActive: filmEdge.active, dateBackActive: dateBack.active)
            filmEdge.active = false
            dateBack.active = false
        }
    }

    static let `default` = FrameEdit()

    init() {}

    /// Every field's key, as the synthesised encoding named them.
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion", decoder = "decoder", decode = "decode", params = "params",
            geometry = "geometry", filmEdge = "filmEdge", dateBack = "dateBack", solvedEV = "solvedEV",
            placementNeedsFit = "placementNeedsFit", frameSeed = "frameSeed", adjustments = "adjustments",
            rawExposureFacts = "rawExposureFacts", printCrop = "printCrop", filmOff = "filmOff"
    }

    /// Every field as schema 3 read it — those it required, still required —
    /// and `adjustments`, which an edit before schema 4 does not have: neutral.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.decoder = try c.decode(String.self, forKey: .decoder)
        decode = try c.decode(DecodeSettings.self, forKey: .decode)
        params = try c.decode(FilmParams.self, forKey: .params)
        geometry = try c.decode(Geometry.self, forKey: .geometry)
        filmEdge = try c.decode(FilmEdgeSettings.self, forKey: .filmEdge)
        dateBack = try c.decode(DateBackSettings.self, forKey: .dateBack)
        solvedEV = try c.decodeIfPresent(Double.self, forKey: .solvedEV)
        placementNeedsFit = try c.decode(Bool.self, forKey: .placementNeedsFit)
        frameSeed = try c.decode(Int.self, forKey: .frameSeed)
        adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments) ?? Adjustments()
        rawExposureFacts = try c.decodeIfPresent(RawExposureFacts.self, forKey: .rawExposureFacts)
        printCrop = try c.decodeIfPresent(Geometry.self, forKey: .printCrop) ?? .default
        filmOff = try c.decodeIfPresent(FilmOff.self, forKey: .filmOff)
        schemaVersion = max(schemaVersion, Self.currentSchema)
    }

    /// As the synthesised encoding wrote it, field for field, and `printCrop`
    /// only when Edit has cut the picture: an edit with no Edit crop is
    /// byte-identical to one written before the field existed (the schema
    /// stays 5 — a preset of schema 5 still loads, `PresetStore`).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(decoder, forKey: .decoder)
        try c.encode(decode, forKey: .decode)
        try c.encode(params, forKey: .params)
        try c.encode(geometry, forKey: .geometry)
        try c.encode(filmEdge, forKey: .filmEdge)
        try c.encode(dateBack, forKey: .dateBack)
        try c.encodeIfPresent(solvedEV, forKey: .solvedEV)
        try c.encode(placementNeedsFit, forKey: .placementNeedsFit)
        try c.encode(frameSeed, forKey: .frameSeed)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encodeIfPresent(rawExposureFacts, forKey: .rawExposureFacts)
        if !printCrop.isIdentity { try c.encode(printCrop, forKey: .printCrop) }
        // Only while the film is off: an edit with the film applied is the same JSON as before.
        try c.encodeIfPresent(filmOff, forKey: .filmOff)
    }

    /// What changed against the defaults a new frame starts with, as the Info
    /// sheet's *Changed* row says it: "Film Exp. +0.3 · Yellow +0.10".
    var changedText: String {
        let d = FilmParams.default
        var parts: [String] = []
        if params.exposureCompensationEV != d.exposureCompensationEV {
            parts.append(L("Film Exp. ") + Fmt.signed(params.exposureCompensationEV))
        }
        if params.printBrightnessStops != d.printBrightnessStops {
            parts.append(L("Brightness ") + Fmt.signed(params.printBrightnessStops))
        }
        if params.yFilterShift != d.yFilterShift { parts.append(L("Yellow ") + Fmt.signed(params.yFilterShift, decimals: 2)) }
        if params.mFilterShift != d.mFilterShift { parts.append(L("Magenta ") + Fmt.signed(params.mFilterShift, decimals: 2)) }
        if params.preflashExposure != d.preflashExposure { parts.append(String(format: L("Pre-flash %.3f"), params.preflashExposure)) }
        if params.sceneLatitude.highlightPullBack > 0 {
            parts.append(String(format: L("Highlight %.2f"), params.sceneLatitude.highlightPullBack))
        }
        if params.sceneLatitude.shadowPullBack > 0 {
            parts.append(String(format: L("Shadow %.2f"), params.sceneLatitude.shadowPullBack))
        }
        if !params.sceneCurve.isIdentity { parts.append(L("Decode Curve")) }
        if params.effects.grain != d.effects.grain { parts.append(L("Grain ") + Fmt.times(params.effects.grain)) }
        if params.effects.halation != d.effects.halation { parts.append(L("Halation ") + Fmt.times(params.effects.halation)) }
        if !geometry.isIdentity || !printCrop.isIdentity { parts.append(L("Crop")) }
        if adjustments.isActive { parts.append(contentsOf: adjustments.changedTools.map(\.title)) }
        return parts.isEmpty ? L("Nothing yet") : parts.joined(separator: " · ")
    }
}

/// RFC-039: a page owns explicit leaves, never an entire surface or effects struct.
enum PageResetScope: String, CaseIterable, Sendable, Identifiable {
    case filmExposure, format, light, curve, colour, enlarger, placement, decode, sceneCurve, couplers, effects, preflash, crop, filmEdge, dateBack
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filmExposure: L("Film Exposure")
        case .format: L("Format", as: "the develop tab")
        case .light: L("Light")
        case .curve: L("Curve")
        case .colour: L("Colour")
        case .enlarger: L("Enlarger")
        case .placement: L("Scene Placement")
        case .decode: L("White Balance")
        case .sceneCurve: L("Decode Curve")
        case .couplers: L("Couplers")
        case .effects: L("Effects")
        case .preflash: L("Pre-flash")
        case .crop: L("Crop")
        case .filmEdge: L("Film Edge")
        case .dateBack: L("Date Back")
        }
    }
}

extension FrameEdit {
    func resetting(_ scope: PageResetScope, asShot: DecodeSettings? = nil) -> FrameEdit {
        var e = self
        let d = FilmParams.default
        switch scope {
        case .filmExposure: e.params.exposureCompensationEV = 0
        case .format:
            // An active edge owns the physical format; reset cannot remove it.
            if !e.filmEdge.active {
                e.params.filmFrame = d.filmFrame; e.params.filmSide = d.filmSide
                e.params.sideLengthMM = d.sideLengthMM; e.params.filmFormatMM = d.filmFormatMM
            }
            e.params.effects.grain = d.effects.grain
            e.params.effects.halation = d.effects.halation
            e.params.antihalationRemoved = d.antihalationRemoved
        case .light: e.adjustments.reset(.light)
        case .curve: e.adjustments.reset(.curve)
        case .colour: e.adjustments.reset(.colour)
        case .enlarger:
            e.params.printBrightnessStops = d.printBrightnessStops
            e.params.yFilterShift = d.yFilterShift; e.params.mFilterShift = d.mFilterShift
        case .placement:
            e.params.sceneLatitude = SceneLatitudeSettings(); e.placementNeedsFit = false
        case .decode:
            // Lens correction is Settings' for the whole library (2026-10-21), not this page's to reset.
            let lens = e.decode.lensCorrection
            e.decode = asShot ?? e.decode
            e.decode.whiteBalance = .asShot
            e.decode.lensCorrection = lens
        case .sceneCurve: e.params.sceneCurve = CurveSet()
        case .couplers:
            e.params.effects.couplers = d.effects.couplers
            e.params.effects.couplersActive = d.effects.couplersActive
        // Edit › EngineRouter's Effects tile (2026-10-22): the leaves its four pills
        // show — Grain and its sub-layers, Halation and its scatter, Glare, the
        // couplers — which are every leaf of the effects, named one by one.
        case .effects:
            e.params.effects.grain = d.effects.grain
            e.params.effects.grainLayered = d.effects.grainLayered
            e.params.effects.halation = d.effects.halation
            e.params.effects.scatter = d.effects.scatter
            e.params.effects.glare = d.effects.glare
            e.params.effects.couplers = d.effects.couplers
            e.params.effects.couplersActive = d.effects.couplersActive
        case .preflash: e.params.preflashExposure = d.preflashExposure
        // The page's ↺ on Edit's Crop tool: Edit's own cut of the finished
        // picture (2026-10-20). Develop's cut of the source is reset on the
        // crop page (Reset), and with the whole develop (`resetDevelop`).
        case .crop: e.printCrop = .default
        case .filmEdge:
            let body = e.filmEdge.cameraSeed
            e.filmEdge = FilmEdgeSettings()
            e.filmEdge.cameraSeed = body
        case .dateBack: e.dateBack = DateBackSettings()
        }
        return e
    }
}

extension FrameEdit {
    /// Back to what a new frame starts with — the stocks kept, the picture's
    /// own decode, its film edge, its date and its seed kept (`OpenFrameSession.reset`,
    /// and a pair's ↺).
    mutating func resetDevelop() {
        let stocks = (params.filmStock, params.printStock)
        // A pair: the frame its placement is shown of stays the picked one.
        let right = params.placementIsRight
        params = .default
        (params.filmStock, params.printStock) = stocks
        params.placementIsRight = right
        geometry = .default
        placementNeedsFit = false
    }
}

extension FrameEdit {
    /// `film_format_mm` as the engine is sent it for a photograph of `photo`'s
    /// size: the edit's own number, or — with Settings' **Crop re-maps the
    /// frame** on (`AppSettings.cropRemapsFrame`, v1.3.3's "Crop re-maps the
    /// frame", unpublished-revision in the 1.x repository) — the frame the Film Format
    /// describes laid on the **crop**: however tight the crop, it has the grain
    /// and halation of a whole frame of that size, as though the whole negative
    /// had been the crop. (Off, a crop is a piece of the bigger negative, and
    /// filling the picture enlarges its grain with it. v1.3.3's caption said a
    /// smaller crop got *coarser* grain when on; its formula, kept here, does the
    /// opposite, and a live capture at 100 % agrees with the formula.)
    ///
    /// The engine never sees the crop as a frame: it develops the whole source
    /// and lays the film's millimetres across the source's long edge
    /// (`film_prefix`: "the pitch is the pre-crop long edge's"). So "the crop is
    /// a 36 mm frame" is said as "the source is 36 mm × source ÷ crop": the
    /// crop's own pixels at the crop's own pitch. The Side Length is measured
    /// on the crop's shape (Side Short on a 1:1 is the square's side), so a
    /// full-height 1:1 out of a 3:2 135 frame — a 24 × 24 mm square of the same
    /// negative — keeps the grain it had, and a crop to half the frame at the
    /// same 3:2 is sent twice the millimetres. Capped by the engine's 200 mm,
    /// which a crop to about a fifth of a 135 frame's long edge reaches.
    ///
    /// Off (the default, as in v1.3.3), and under a film edge — where the crop
    /// is the picture's placement in the gate and the gate's own millimetres
    /// size the film (`overscan_gate_long_mm`) — the edit's number goes as it
    /// is. A quarter turn or a straighten does not change the crop's size.
    func wireFilmFormatMM(photo: PixelSize, cropIsFrame: Bool) -> Double {
        guard cropIsFrame, !filmEdge.effective, !geometry.crop.isFull,
              photo.width > 0, photo.height > 0 else { return params.filmFormatMM }
        let w = geometry.crop.width.clamped(to: 1e-4...1) * Double(photo.width)
        let h = geometry.crop.height.clamped(to: 1e-4...1) * Double(photo.height)
        let cropLong = max(w, h), cropShort = min(w, h)
        let side = FilmSide(rawValue: params.filmSide) ?? .short
        let cropLongMM = side == .short ? params.sideLengthMM * cropLong / cropShort : params.sideLengthMM
        return (cropLongMM * Double(photo.longEdge) / cropLong).clamped(to: 4...200)
    }
}
