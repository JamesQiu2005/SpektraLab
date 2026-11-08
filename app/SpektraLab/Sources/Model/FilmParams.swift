//  FilmParams.swift — Layer 1 parameters and their engine-wire names.
//
//  A saved edit retains every parameter, including controls the interface does not expose.
//  `delta(from:)` sends only changed wire fields. The film/print layer determines whether a change
//  develops the negative again or reprints its cached density. The current engine disables the
//  contrast mask at this boundary while retaining its saved settings for compatibility.
//  Scene Latitude requests and placement are implemented by the engine client.

import Foundation

enum ParamLayer: String, Codable, Sendable { case shoot, print }

/// A JSON scalar for `params_delta`.
enum ParamValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case double(Double), bool(Bool), string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }
    var description: String {
        switch self {
        case .double(let d): String(format: "%.4g", d)
        case .bool(let b): b ? "true" : "false"
        case .string(let s): s
        }
    }
    var doubleValue: Double? { if case .double(let d) = self { d } else { nil } }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// The physical frame a photograph is recorded on, as **both** of its sides.
///
/// The engine's `film_format_mm` is a single number and means the frame's
/// **long edge** (it derives pixel pitch as `film_format_mm * 1000 / max(w, h)`,
/// which is what sets the scale of grain, halation and DIR diffusion). One
/// number cannot say whether 56 mm is 645 or 6×6, which is the gap the PRD
/// closes: a Film Type, a **Side**, and the length of that side.
///
/// So a preset carries a short side and a long side, the user picks which one
/// the length refers to, and the wire's long edge is derived from the *photo's
/// own aspect* — `Session.filmFormatMM(for:)`. With Side = Short at 56 mm a
/// square frame derives 56 and a 6×7 derives 70, from the same preset, without
/// a menu of every medium-format back ever made.
///
/// `long` is the classic frame for the type, and it is what Side = Long shows.
/// It is **not** what gets sent: the derivation always goes through the photo.
struct FilmFrame: Identifiable, Hashable, Sendable {
    let id: String
    /// Millimetres.
    let short: Double
    let long: Double
    let isCine: Bool

    /// The custom entry. Its two sides are the user's `sideLengthMM`, so the
    /// numbers here are only the value a fresh Custom starts at.
    static let custom = FilmFrame(id: "Custom", short: 24, long: 36, isCine: false)

    /// Cine first, as the drawing lists them, each with the orange `CINE`
    /// pill. Camera-negative frames (what the film is exposed at), not
    /// projection apertures.
    static let cine: [FilmFrame] = [
        .init(id: "Super 8", short: 4.01, long: 5.79, isCine: true),
        .init(id: "16mm", short: 7.49, long: 10.26, isCine: true),
        .init(id: "Super 16", short: 7.41, long: 12.52, isCine: true),
        .init(id: "Super 35", short: 14.00, long: 24.89, isCine: true),
        .init(id: "65mm", short: 23.01, long: 52.63, isCine: true),
    ]

    /// The still formats the PRD names: "110, APS, 135, 120, custom".
    ///
    /// 120 is a film *width*, not a frame, which is exactly why the short side
    /// is the useful number: every 120 back exposes the same 56 mm across the
    /// film and differs only in how far along it. Side = Short at 56 therefore
    /// covers 645, 6×6, 6×7 and 6×9 with one entry, and gets each of them
    /// right from the photo's aspect.
    static let still: [FilmFrame] = [
        .init(id: "110", short: 13, long: 17, isCine: false),
        .init(id: "APS", short: 16.7, long: 30.2, isCine: false),
        .init(id: "135", short: 24, long: 36, isCine: false),
        .init(id: "120", short: 56, long: 56, isCine: false),
        custom,
    ]

    static var all: [FilmFrame] { cine + still }
    static func named(_ id: String) -> FilmFrame { all.first { $0.id == id } ?? custom }

    func side(_ s: FilmSide) -> Double { s == .short ? short : long }
}

/// Which side of the photograph the Side Length refers to.
enum FilmSide: String, CaseIterable, Identifiable, Sendable {
    case short = "short", long = "long"
    var id: String { rawValue }
    var title: String { self == .short ? L("Short") : L("Long") }
}

extension FilmParams {
    /// The frame's long edge in millimetres: the short side times the photo's
    /// aspect, or the long side itself. 135 on a 3:2 photo is 36; 120 is 84
    /// (6 × 9) on 3:2 and 56 on a square. The desktop's `Session.filmFormatMM`.
    static func longEdgeMM(side: FilmSide, length: Double, photo: PixelSize) -> Double {
        let long = Double(max(photo.width, photo.height)), short = Double(max(min(photo.width, photo.height), 1))
        return (side == .short ? length * long / short : length).clamped(to: 4...200)
    }

    /// Take a film's size, as a size card does. **Three fields move
    /// together**: the frame's name, its side as that frame measures it, and
    /// the wire's long edge (`film_format_mm`), derived from the photograph's
    /// own shape. The name alone changes a label and nothing the engine is
    /// sent, so nothing would develop.
    mutating func take(size frame: FilmFrame, photo: PixelSize) {
        let side = FilmSide(rawValue: filmSide) ?? .short
        filmFrame = frame.id
        sideLengthMM = frame.side(side)
        filmFormatMM = Self.longEdgeMM(side: side, length: sideLengthMM, photo: photo)
    }

    /// These settings with the film's long edge as *this* photograph makes it
    /// on the frame they name: what `take(size:photo:)` sets. The page's size
    /// cards say a 4:3 picture on 135 is 24 × 32 mm, so that is what has to be
    /// sent — not the 36 a new frame's defaults carry, and not the length
    /// another photograph's shape gave settings that were pasted from it. A
    /// frame the page does not offer (Custom, a cine frame: a desktop edit's)
    /// is left as it is.
    func heldToItsPhoto(_ photo: PixelSize) -> FilmParams {
        guard let frame = FilmFrame.still.first(where: { $0.id == filmFrame }), frame.id != FilmFrame.custom.id,
              photo.width > 0, photo.height > 0 else { return self }
        var p = self
        p.take(size: frame, photo: photo)
        return p
    }
}

/// The unit the Side Length is typed in. Display only — the wire is always
/// millimetres — so it is an app preference rather than part of a frame's
/// settings.
enum SideUnit: String, CaseIterable, Identifiable, Sendable {
    case mm, cm, inch
    var id: String { rawValue }
    /// "inch" in full since 2026-09-28; millimetres and centimetres keep
    /// their SI symbols, which are units, not abbreviations of a word.
    var title: String { self == .inch ? L("inch") : rawValue }
    /// Millimetres per unit.
    var perMM: Double {
        switch self {
        case .mm: 1
        case .cm: 10
        case .inch: 25.4
        }
    }
    func fromMM(_ mm: Double) -> Double { mm / perMM }
    func toMM(_ v: Double) -> Double { v * perMM }
    /// How many decimals the field shows. A millimetre reading wants one; an
    /// inch reading of the same frame wants three, or 135 reads as "0.9 in"
    /// and every still format looks like the same film.
    var decimals: Int {
        switch self {
        case .mm: 1
        case .cm: 2
        case .inch: 3
        }
    }
}

/// RFC-015 §2.3's four exposure intents, as the Camera section's Tone pill
/// offers them. The case names are the wire values.
enum ExposureMethod: String, CaseIterable, Identifiable, Sendable {
    case balanced = "balanced"
    case center = "center"
    case protectHighlights = "protect_highlights"
    case protectShadows = "protect_shadows"

    var id: String { rawValue }

    /// What the pill shows: lowercase, as the user's drawing has it.
    var title: String {
        switch self {
        case .balanced: L("balanced")
        case .center: L("center")
        case .protectHighlights: L("protect highlights")
        case .protectShadows: L("protect shadows")
        }
    }

    /// The pill's text for a wire value.
    ///
    /// `nil` is a sidecar written before this field existed. It still meters
    /// with the engine's `center_weighted`, so the pill says which meter is
    /// actually running rather than pretending to be one of the four — and
    /// that name is deliberately not in the menu, because choosing it is not a
    /// thing a user can do.
    static func title(forWire value: String?) -> String {
        guard let value else { return L("center-weighted (legacy)") }
        return ExposureMethod(rawValue: value)?.title ?? value
    }
}

/// What the **AE Method** pill offers, which is the four intents plus
/// `custom` — and `custom` is not a fifth meter. It is the meter switched
/// **off**.
///
/// The PRD: "take the linearized baseline as the +0.0 baseline (also `As
/// Shot`, clicking this automatically switches AE method to custom), and the
/// different AE methods just adjust the exposure based on it."
///
/// That is exactly the engine's existing `camera.auto_exposure` flag, which
/// has been in the schema all along and which nothing has ever set: with it
/// false the meter contributes nothing (`engine.cpp`: `camera.auto_exposure ?
/// meter.evs.of(method) : nullopt`) and `exposure_compensation_ev` is the
/// whole of the film exposure, measured from the linearized frame. So Custom
/// needs **no new wire field and no new value** — only the flag that was
/// already declared.
enum AEMethod: Hashable, Identifiable, Sendable {
    case custom
    case metered(ExposureMethod)
    /// A sidecar written before the field existed: the engine's own
    /// `center_weighted`, which is not a thing the menu offers.
    case legacy

    var id: String {
        switch self {
        case .custom: "custom"
        case .metered(let m): m.rawValue
        case .legacy: "legacy"
        }
    }

    var title: String {
        switch self {
        case .custom: L("Source exposure")
        case .metered(let m): m.title.capitalizedFirst
        case .legacy: L("center-weighted (legacy)")
        }
    }

    /// What the menu lists. `legacy` is not in it, because choosing it is not
    /// a thing a user can do.
    static var offered: [AEMethod] { [.custom] + ExposureMethod.allCases.map(AEMethod.metered) }

    /// Read the pair of fields a frame actually carries.
    static func of(_ p: FilmParams) -> AEMethod {
        guard p.autoExposure else { return .custom }
        guard let wire = p.autoExposureMethod else { return .legacy }
        return ExposureMethod(rawValue: wire).map(AEMethod.metered) ?? .legacy
    }

    /// Write it back. Custom leaves `autoExposureMethod` alone, so turning the
    /// meter off and on again comes back to the intent it had — which is what
    /// makes Custom usable as a comparison rather than a destination.
    func apply(to p: inout FilmParams) {
        switch self {
        case .custom:
            p.autoExposure = false
        case .metered(let m):
            p.autoExposure = true
            p.autoExposureMethod = m.rawValue
        case .legacy:
            p.autoExposure = true
            p.autoExposureMethod = nil
        }
    }
}

extension String {
    /// "protect highlights" → "Protect highlights". The drawing capitalises
    /// the pill's value ("Custom"), where the previous one lower-cased it.
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

/// RFC-024's virtual contrast mask: a regional gain on the enlarger's image
/// exposure, before pre-flash and paper (API-SPEC §11). Print layer, so an edit
/// reprints the cached negative. Every value is the user's; the defaults are
/// the engine's placeholders and do nothing while `active` is false or both
/// amounts are 0 (RFC-024 §12.5).
struct ContrastMaskSettings: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case active = "active", highlights = "highlights", shadows = "shadows", core = "core", scale = "scale",
            scheme = "scheme"
    }
    var active = false
    /// Stops by which the print's highlights (low paper exposure) are raised.
    var highlights = 0.0           // 0…3
    /// Stops by which the print's shadows (high paper exposure) are lowered.
    var shadows = 0.0              // 0…3
    /// Half-width of the untouched core about the negative's mid-grey, stops.
    var core = 1.0                 // 0…3
    /// The blur's sigma as a fraction of the frame's long edge.
    var scale = 0.03               // 0.002…0.12
    /// The base extractor by name; `gaussian` is the only product scheme.
    var scheme = "gaussian"

    static let scaleRange = 0.002...0.12

    init() {}

    /// Every key optional, so a sidecar from before a field existed decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ContrastMaskSettings()
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? d.active
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? d.highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? d.shadows
        core = try c.decodeIfPresent(Double.self, forKey: .core) ?? d.core
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? d.scheme
    }
}

/// RFC-023's Scene Latitude (API-SPEC §12). Two halves, and keeping them apart
/// is the RFC's §8.3:
///
/// - the **pull-backs** are UI state -- what the user dragged -- and never
///   reach the wire;
/// - the **resolved curve** (knees, rooms) is what `spk_scene_latitude` solved
///   from them and is the only thing the engine renders. A paper change must
///   not re-render an old edit, so nothing here is re-derived implicitly: the
///   resolved values change only when a fit is applied.
///
/// Shoot layer: the curve sits before the film, so an edit re-develops.
struct SceneLatitudeSettings: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case highlightPullBack = "highlightPullBack", shadowPullBack = "shadowPullBack",
            shadowPercentile = "shadowPercentile", highlightPercentile = "highlightPercentile", active = "active",
            norm = "norm", highlightKnee = "highlightKnee", highlightRoom = "highlightRoom", shadowKnee = "shadowKnee",
            shadowRoom = "shadowRoom", rolloff = "rolloff", maxLift = "maxLift"
    }
    // --- UI state, not on the wire ---
    /// Stops the scene's top is pulled back; 0 = the highlight side is off.
    var highlightPullBack = 0.0
    /// Stops the scene's bottom is pulled up (the bounded landing); 0 = off.
    var shadowPullBack = 0.0
    /// Which robust extreme each side is fitted to: 0.1 or 1, 99.9 or 99.
    var shadowPercentile = 0.1
    var highlightPercentile = 99.9
    // --- the resolved curve, on the wire ---
    var active = false
    var norm = "power"
    var highlightKnee = 2.0
    var highlightRoom = 0.0
    var shadowKnee = -2.0
    var shadowRoom = 0.0
    var rolloff = 2.0              // 1…4
    var maxLift = 4.0              // 0.25…12

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SceneLatitudeSettings()
        highlightPullBack = try c.decodeIfPresent(Double.self, forKey: .highlightPullBack) ?? d.highlightPullBack
        shadowPullBack = try c.decodeIfPresent(Double.self, forKey: .shadowPullBack) ?? d.shadowPullBack
        shadowPercentile = try c.decodeIfPresent(Double.self, forKey: .shadowPercentile) ?? d.shadowPercentile
        highlightPercentile = try c.decodeIfPresent(Double.self, forKey: .highlightPercentile) ?? d.highlightPercentile
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? d.active
        norm = try c.decodeIfPresent(String.self, forKey: .norm) ?? d.norm
        highlightKnee = try c.decodeIfPresent(Double.self, forKey: .highlightKnee) ?? d.highlightKnee
        highlightRoom = try c.decodeIfPresent(Double.self, forKey: .highlightRoom) ?? d.highlightRoom
        shadowKnee = try c.decodeIfPresent(Double.self, forKey: .shadowKnee) ?? d.shadowKnee
        shadowRoom = try c.decodeIfPresent(Double.self, forKey: .shadowRoom) ?? d.shadowRoom
        rolloff = try c.decodeIfPresent(Double.self, forKey: .rolloff) ?? d.rolloff
        maxLift = try c.decodeIfPresent(Double.self, forKey: .maxLift) ?? d.maxLift
    }
}

/// RFC-025: each film effect's strength, apart from the film that sets it.
///
/// The stock decides *how much* halation, grain and coupler cross-talk a
/// negative has -- its antihalation tag, its grain model, its DIR matrix -- and
/// until now the only thing the user could do about any of it was switch it
/// off. These are multipliers on the stock's own value, so 1 is always "this
/// film, as modelled", whichever film that is, and every default is the
/// engine's, so a frame that has never seen them renders as it did.
///
/// They belong to the frame (they are in the sidecar and on the wire whether
/// or not Settings shows them). The *Decouple effects* setting only decides
/// whether the Film section shows the sliders; hiding them must not change a
/// picture that was made with them.
///
/// **RFC-034: an area multiplier, not a radius.** For the two effects that are
/// a *glow around a highlight* — halation and glare — the number means how much
/// of the effect there is, and that is the same as saying how much of the frame
/// it covers: the light scales with the number and so does the area it covers,
/// so every sigma takes the square root. 2 is twice the area, not twice the
/// radius, which would be four times it. Halation's is a glow the film itself
/// draws (65 µm wide on the negative), glare's is the paper's veiling flare.
struct EffectStrengths: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case grain = "grain", grainLayered = "grainLayered", halation = "halation", scatter = "scatter",
            couplersActive = "couplersActive", couplers = "couplers", glare = "glare"
    }
    /// `grain_amount`: the grained density mixed over the clean one.
    var grain = 1.0                // 0…2
    /// `grain_sublayers_active`, which the Grain switch used to set too: the
    /// three-sub-layer model against the single-layer one.
    var grainLayered = true
    /// `halation_amount`: the back-reflection off the base, as an area
    /// multiplier (RFC-034). 1 is the film's own halo.
    var halation = 1.0             // 0…4
    /// `halation_scatter_amount`: the in-emulsion scatter, a mix weight.
    var scatter = 1.0              // 0…1
    /// `dir_couplers_active` / `dir_couplers_amount`: the inter-layer
    /// inhibition that gives a stock its colour separation.
    var couplersActive = true
    var couplers = 1.0             // 0…1.5
    /// `glare_amount`: the print's veil, as an area multiplier (RFC-034). 1 is
    /// the paper's own.
    var glare = 1.0                // 0…30

    static let grainRange = 0.0...2.0
    static let halationRange = 0.0...4.0
    static let scatterRange = 0.0...1.0
    /// Not the wire's 0…4. Above ≈1.736 the coupler inverse's exposure axis
    /// stops being monotonic (AGENTS.md trap 22) and the output is no longer
    /// the model's, so the slider stops short of it.
    static let couplersRange = 0.0...1.5
    /// **0…30, not 0…4** (RFC-034). The paper's own glare is 0.03 percent of
    /// the illuminant, so 4 times it is still a whisper — measured, 0.65 of a
    /// count out of 255 across the frame, which is nothing to look at. The
    /// reference's own calibration sweep (`glare_ramp`) only ever asks for
    /// 0.4 percent, 13 times the paper's own; 30 reaches 0.9 percent, a veil
    /// that lifts the frame by ~4 counts and moves a third of its pixels by
    /// more than 4. The slider is honest about what it multiplies, so its
    /// neutral tick sits near the left end.
    static let glareRange = 0.0...30.0

    static let `default` = EffectStrengths()
    var isDefault: Bool { self == .default }

    init() {}

    /// Every key optional, so a sidecar from before a field existed decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EffectStrengths()
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? d.grain
        grainLayered = try c.decodeIfPresent(Bool.self, forKey: .grainLayered) ?? d.grainLayered
        halation = try c.decodeIfPresent(Double.self, forKey: .halation) ?? d.halation
        scatter = try c.decodeIfPresent(Double.self, forKey: .scatter) ?? d.scatter
        couplersActive = try c.decodeIfPresent(Bool.self, forKey: .couplersActive) ?? d.couplersActive
        couplers = try c.decodeIfPresent(Double.self, forKey: .couplers) ?? d.couplers
        glare = try c.decodeIfPresent(Double.self, forKey: .glare) ?? d.glare
    }
}

struct FilmParams: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case filmStock = "filmStock", printStock = "printStock", exposureCompensationEV = "exposureCompensationEV",
            autoExposureMethod = "autoExposureMethod", autoExposure = "autoExposure"
        case filmFormatMM = "filmFormatMM", filmFrame = "filmFrame", filmSide = "filmSide",
            sideLengthMM = "sideLengthMM", grainActive = "grainActive", halationActive = "halationActive",
            antihalationRemoved = "antihalationRemoved"
        case printBrightnessStops = "printBrightnessStops", yFilterShift = "yFilterShift",
            mFilterShift = "mFilterShift", glareActive = "glareActive", scanFilm = "scanFilm"
        case extendedDynamicRange = "extendedDynamicRange", preflashExposure = "preflashExposure",
            contrastMask = "contrastMask", sceneLatitude = "sceneLatitude", effects = "effects",
            printEffects = "printEffects"
        case digitalIntermediate = "digitalIntermediate"
        case sceneLatitudeOther = "sceneLatitudeOther", placementIsRight = "placementIsRight", pairSplit = "pairSplit",
            sceneCurve = "sceneCurve"
    }

    // --- stock (shoot for film, print for paper) ---
    var filmStock: String = "kodak_portra_400"
    var printStock: String = "kodak_supra_endura"
    // --- shoot ---
    var exposureCompensationEV: Double = 0          // -8…8
    /// Which exposure intent the engine's meter follows (RFC-015 §2.3),
    /// as its wire name.
    ///
    /// **`nil` means "send nothing"**, and that is the whole legacy story: a
    /// sidecar written before this field existed decodes to `nil` (the
    /// synthesized `init(from:)` uses `decodeIfPresent`, which ignores the
    /// default below), the wire carries no `auto_exposure_method`, and the
    /// engine keeps its own default of `center_weighted`, so that edit renders
    /// byte for byte as it always did. The four names are the intents:
    /// `balanced`, `center`, `protect_highlights`, `protect_shadows`.
    ///
    /// The default is for *new* frames, which the user asked to start
    /// `balanced`.
    var autoExposureMethod: String? = "balanced"
    /// The engine's `camera.auto_exposure`, and the whole of what the AE
    /// Method pill's `Custom` means: with it false the meter contributes
    /// nothing and Film Exposure is measured from the linearized frame
    /// (`AEMethod`).
    ///
    /// New frames preserve source exposure. Decoding a saved edit still reads
    /// its stored Bool, so existing Balanced and Custom edits do not migrate.
    var autoExposure: Bool = false
    /// The frame's **long edge** in millimetres, which is what the engine
    /// means by `film_format_mm`. It is **derived** — from the three fields
    /// below and the photograph's own aspect — and stored because the
    /// derivation needs a decoded frame and this struct has never seen one.
    /// `Session.recomputeFilmFormat()` is the one place that writes it.
    var filmFormatMM: Double = 36                    // 4…200
    /// Film Type, Side and Side Length: the user's half of that derivation.
    /// Not wire fields — the engine takes one number — but they have to come
    /// back with the frame, so they live here beside the number they make.
    var filmFrame: String = "135"
    var filmSide: String = FilmSide.short.rawValue
    var sideLengthMM: Double = 24
    var grainActive: Bool = true
    var halationActive: Bool = true
    /// Independent backing-layer state, resolved by the engine's halation preset.
    var antihalationRemoved = false
    // --- print ---
    /// UI stops, brighter positive. Wire: `print_exposure = 2^(-stops)`,
    /// because less enlarger exposure prints brighter (API-SPEC §2).
    var printBrightnessStops: Double = 0            // -3…3
    var yFilterShift: Double = 0                     // -1…1  yellow ↔ blue
    var mFilterShift: Double = 0                     // -1…1  magenta ↔ green
    var glareActive: Bool = true
    /// "No print profile": scan the developed film instead of printing it, so
    /// a slide film reads as a positive and a negative film reads as the
    /// negative it is — orange mask and all.
    ///
    /// The engine drops the three `printing.*` nodes and runs the scan chain
    /// from `Tap.CMY_FILM`, under the film's own viewing illuminant. It is a
    /// print-layer parameter, so switching it costs a reprint (~60 ms) and
    /// not a re-render.
    ///
    /// It is deliberately **not** spelled as `print_stock: "none"`, which is
    /// what the frontend asked for first: `print_stock` names a paper, and a
    /// sentinel there would collapse "which paper" and "is there a paper"
    /// into one field. Keeping them apart is also what lets the user's paper
    /// choice survive toggling the Positive row on and off.
    var scanFilm: Bool = false
    /// RFC-028's **Digital Intermediate** (数字中间片): the negative read in
    /// printing density with its orange mask removed per wavelength, reversed
    /// on the film's own neutral curve, and written as Cineon-style log. It
    /// takes the paper's place the way `scanFilm` does, and like it is a
    /// switch beside `printStock` rather than a paper id, so the paper choice
    /// survives turning it on and off. `scanFilm` wins if both are set, and a
    /// slide film ignores it (it has no mask and no paper). Print layer.
    var digitalIntermediate: Bool = false
    /// True when the DI is what the engine renders: the switch, on a negative,
    /// with no film scan in front of it. The film's polarity lives in the
    /// catalogue, so the caller supplies it.
    func digitalIntermediateActive(filmIsPositive: Bool) -> Bool {
        digitalIntermediate && !scanFilm && !filmIsPositive
    }
    /// RFC-028 §10: the optional blue-sector correction of the DI's colour
    /// step. An app setting (Settings ▸ Rendering), off by default by the
    /// user's decision of 2026-09-29 -- read here so the wire, the print cache
    /// stamp and every export carry it without a second path.
    nonisolated static let diBlueCompensationKey = "ui2.diBlueCompensation"
    nonisolated static var diBlueCompensation: Bool {
        UserDefaults.standard.bool(forKey: diBlueCompensationKey)
    }
    /// Preserve the extended range while rendering a selected print profile.
    /// This is a print-layer choice, so it reprints the cached negative. The
    /// preference is retained when `scanFilm` is selected, but is made
    /// ineffective on the direct film-scan path.
    var extendedDynamicRange: Bool = false

    /// The backend only applies EDR to an actual print profile. Keep the
    /// user's preference in the sidecar while making the wire value false for
    /// the Positive / No Print Profile path, so a persisted preference cannot
    /// change direct film scanning.
    var effectiveExtendedDynamicRange: Bool { extendedDynamicRange && !scanFilm && !digitalIntermediate }

    /// The enlarger's pre-flash: a uniform paper exposure of this many times
    /// the light through the film's clear base, added before development
    /// (`printing.cpp`). **Not in EV** -- measured on `_DSC2663`, 0.01 is ~9 %
    /// of the mid-grey exposure and the useful range is 0…0.03 of the wire's
    /// 0…1 (`output/preflash_DSC2663/report.md`). Print layer, live.
    var preflashExposure: Double = 0
    /// RFC-024. Print layer.
    var contrastMask = ContrastMaskSettings()
    /// RFC-023. Shoot layer.
    var sceneLatitude = SceneLatitudeSettings()
    /// **A half-frame pair has a placement a frame** (the desktop's own three
    /// fields, `Model/Params.swift`). `sceneLatitude` is always the one the
    /// page shows — the frame Scene Placement and the Latitude card are about —
    /// and this is the other frame's; `placementIsRight` says which frame
    /// `sceneLatitude` belongs to. The two trade places with the flag when the
    /// other frame is picked, which changes nothing on the wire: picking a
    /// frame costs no develop.
    var sceneLatitudeOther = SceneLatitudeSettings()
    var placementIsRight = false
    /// Where the pair's second frame begins along the piece's long edge, as a
    /// fraction of it (`HalfFramePair.split`); 0 for a photograph, whose wire
    /// then carries none of the second frame's rows and whose stamp is as it was.
    var pairSplit = 0.0
    /// The first (left, or upper) frame's placement, and the second's.
    var firstPlacement: SceneLatitudeSettings { placementIsRight ? sceneLatitudeOther : sceneLatitude }
    var secondPlacement: SceneLatitudeSettings { placementIsRight ? sceneLatitude : sceneLatitudeOther }
    /// The second frame's rows, on a pair only (`scene_latitude.cpp`: the
    /// second curve takes over from the split along the piece's long edge).
    var pairPlacementWire: [(name: String, value: ParamValue, layer: ParamLayer)] {
        guard pairSplit > 0 else { return [] }
        let b = secondPlacement
        return [
            ("scene_latitude_split", .double(pairSplit.clamped(to: 0...1)), .shoot),
            ("scene_latitude_b_active", .bool(b.active && !(digitalIntermediate && !scanFilm)), .shoot),
            ("scene_latitude_b_highlight_knee", .double(b.highlightKnee), .shoot),
            ("scene_latitude_b_highlight_room", .double(b.highlightRoom), .shoot),
            ("scene_latitude_b_shadow_knee", .double(b.shadowKnee), .shoot),
            ("scene_latitude_b_shadow_room", .double(b.shadowRoom), .shoot),
        ]
    }
    /// **The Decode curve** (the owner, 2026-10-24: "a newly added curve, that works similarly as the
    /// current curve in edit … but it applies straight to the linear tiff. This is going to replace
    /// scene placements"). Edit's own `CurveSet` — RGB, Luma, R, G, B, as Edit's Curve keeps them —
    /// drawn on the scene before the film: its unit square is **±`sceneCurveStops` about the metered
    /// mid-grey** on both axes, the Latitude card's axis, so the centre is mid-grey and the diagonal
    /// is no change. The engine applies it as a gain on the linear signal (`scene_curve`, API-SPEC
    /// §17), after Scene Placement's node and before Film Exposure. Shoot layer: an edit re-develops.
    /// Absent from an edit before it, which reads as the identity.
    var sceneCurve = CurveSet()
    /// The curve's half range, in stops: the engine's `kSceneCurveStops`, and the Latitude card's.
    static let sceneCurveStops = 8.0
    /// Samples a row of the wire's table: an eighth of a stop apart.
    static let sceneCurveSamples = 129
    /// `scene_curve` on the wire: the five rows (rgb, luma, r, g, b) as `CurveSet.table` makes them
    /// for Edit's pass, at `sceneCurveSamples`; "" while the curve is the identity, which the engine
    /// skips (no node), and which a develop's stamp leaves out (`DevelopStamp.of`).
    var sceneCurveWire: String {
        guard !sceneCurve.isIdentity else { return "" }
        return CurveChannel.allCases.flatMap { sceneCurve.table($0, size: Self.sceneCurveSamples) }
            .map { String(format: "%.5f", $0) }.joined(separator: ",")
    }
    /// RFC-025. Shoot layer except glare, which is the print's.
    var effects = EffectStrengths()
    /// The Print section's **Print Effects** switch: off leaves the paper's
    /// colour transformation and nothing else -- no glare, no pre-flash, no
    /// Tone Mask -- without forgetting any of their settings. A gate on the
    /// wire, like `effectiveExtendedDynamicRange`, so turning it back on
    /// restores exactly what was there.
    var printEffects = true

    init() {
        filmStock = "kodak_portra_400"
        printStock = "kodak_supra_endura"
        exposureCompensationEV = 0
        autoExposureMethod = "balanced"
        autoExposure = false
        filmFormatMM = 36
        filmFrame = "135"
        filmSide = FilmSide.short.rawValue
        sideLengthMM = 24
        grainActive = true
        halationActive = true
        antihalationRemoved = false
        printBrightnessStops = 0
        yFilterShift = 0
        mFilterShift = 0
        glareActive = true
        scanFilm = false
        digitalIntermediate = false
        extendedDynamicRange = false
        preflashExposure = 0
        contrastMask = ContrastMaskSettings()
        sceneLatitude = SceneLatitudeSettings()
        effects = EffectStrengths()
        printEffects = true
    }

    /// Keep sidecars written before EDR readable. Stored properties with
    /// defaults still use `decode(_:forKey:)` in synthesized Codable, so an
    /// absent key would otherwise reject the whole `FilmParams` value. The
    /// older fields retain their synthesized Codable requirements; a missing
    /// exposure method deliberately remains nil because that is the legacy
    /// wire state. EDR, pre-flash, the contrast mask and Scene Latitude are
    /// newer and therefore default when absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filmStock = try c.decode(String.self, forKey: .filmStock)
        printStock = try c.decode(String.self, forKey: .printStock)
        exposureCompensationEV = try c.decode(Double.self, forKey: .exposureCompensationEV)
        autoExposureMethod = try c.decodeIfPresent(String.self, forKey: .autoExposureMethod)
        autoExposure = try c.decode(Bool.self, forKey: .autoExposure)
        filmFormatMM = try c.decode(Double.self, forKey: .filmFormatMM)
        filmFrame = try c.decode(String.self, forKey: .filmFrame)
        filmSide = try c.decode(String.self, forKey: .filmSide)
        sideLengthMM = try c.decode(Double.self, forKey: .sideLengthMM)
        grainActive = try c.decode(Bool.self, forKey: .grainActive)
        halationActive = try c.decode(Bool.self, forKey: .halationActive)
        antihalationRemoved = try c.decodeIfPresent(Bool.self, forKey: .antihalationRemoved) ?? false
        printBrightnessStops = try c.decode(Double.self, forKey: .printBrightnessStops)
        yFilterShift = try c.decode(Double.self, forKey: .yFilterShift)
        mFilterShift = try c.decode(Double.self, forKey: .mFilterShift)
        glareActive = try c.decode(Bool.self, forKey: .glareActive)
        scanFilm = try c.decode(Bool.self, forKey: .scanFilm)
        digitalIntermediate = try c.decodeIfPresent(Bool.self, forKey: .digitalIntermediate) ?? false
        extendedDynamicRange = try c.decodeIfPresent(Bool.self, forKey: .extendedDynamicRange) ?? false
        preflashExposure = try c.decodeIfPresent(Double.self, forKey: .preflashExposure) ?? 0
        contrastMask = try c.decodeIfPresent(ContrastMaskSettings.self, forKey: .contrastMask)
            ?? ContrastMaskSettings()
        sceneLatitude = try c.decodeIfPresent(SceneLatitudeSettings.self, forKey: .sceneLatitude)
            ?? SceneLatitudeSettings()
        effects = try c.decodeIfPresent(EffectStrengths.self, forKey: .effects) ?? EffectStrengths()
        printEffects = try c.decodeIfPresent(Bool.self, forKey: .printEffects) ?? true
        sceneLatitudeOther = try c.decodeIfPresent(SceneLatitudeSettings.self, forKey: .sceneLatitudeOther)
            ?? SceneLatitudeSettings()
        placementIsRight = try c.decodeIfPresent(Bool.self, forKey: .placementIsRight) ?? false
        pairSplit = try c.decodeIfPresent(Double.self, forKey: .pairSplit) ?? 0
        sceneCurve = try c.decodeIfPresent(CurveSet.self, forKey: .sceneCurve) ?? CurveSet()
    }

    static let `default` = FilmParams()

    /// Wire representation of every field. Order is stable for tests.
    var wire: [(name: String, value: ParamValue, layer: ParamLayer)] {
        var fields: [(name: String, value: ParamValue, layer: ParamLayer)] = [
            ("film_stock", .string(filmStock), .shoot),
            ("print_stock", .string(printStock), .print),
            ("exposure_compensation_ev", .double(exposureCompensationEV), .shoot),
        ]
        // Only when set. A legacy sidecar has no method, and sending one would
        // change how it meters — the engine's default is what it has always
        // rendered with (see `autoExposureMethod`).
        if let method = autoExposureMethod {
            fields.append(("auto_exposure_method", .string(method), .shoot))
        }
        fields += [
            // Sent always, unlike the method: it has a default here and the
            // default is the engine's, so a legacy frame is unchanged by it.
            ("auto_exposure", .bool(autoExposure), .shoot),
            ("film_format_mm", .double(filmFormatMM), .shoot),
            ("grain_active", .bool(grainActive), .shoot),
            // `&&`, not the setting alone: with grain off this is what it has
            // always been, so a legacy frame's stamp does not move.
            ("grain_sublayers_active", .bool(grainActive && effects.grainLayered), .shoot),
            ("halation_active", .bool(halationActive), .shoot),
            ("antihalation_removed", .bool(antihalationRemoved), .shoot),
            ("print_exposure", .double(FilmParams.printExposure(stops: printBrightnessStops)), .print),
            ("y_filter_shift", .double(yFilterShift), .print),
            ("m_filter_shift", .double(mFilterShift), .print),
            // What a unit of the two shifts is (API-SPEC §17). Sent always, as
            // the desktop sends it: the engine's own default is 1, the
            // reference's, at which the two rulers move nothing a person can see.
            ("filter_shift_scale", .double(FilmParams.filterShiftCC), .print),
            ("glare_active", .bool(glareActive && printEffects), .print),
            ("scan_film", .bool(scanFilm), .print),
            ("extended_dynamic_range", .bool(effectiveExtendedDynamicRange), .print),
            ("preflash_exposure", .double(printEffects ? preflashExposure : 0), .print),
            // RFC-024 (API-SPEC §11). Sent always: the defaults are the
            // engine's, and off is a structural bypass, so a legacy frame
            // renders byte for byte as before.
            // Never on the host: its print is colour and tone only (RFC-035 §4).
            ("contrast_mask_active", .bool(false), .print),
            ("contrast_mask_highlights", .double(contrastMask.highlights), .print),
            ("contrast_mask_shadows", .double(contrastMask.shadows), .print),
            ("contrast_mask_core", .double(contrastMask.core), .print),
            ("contrast_mask_scale", .double(contrastMask.scale.clamped(to: ContrastMaskSettings.scaleRange)), .print),
            ("contrast_mask_scheme", .string(contrastMask.scheme), .print),
            // RFC-023 (API-SPEC §12): the resolved curve only; the pull-backs
            // are UI state and stay in the sidecar.
            // Off under the Digital Intermediate (RFC-028): placement fits a
            // scene into a paper's range, and the DI keeps the film's whole
            // one. The pull-backs stay in the sidecar for when a paper returns.
            // A photograph's own placement; on a half-frame pair, its first
            // frame's (`firstPlacement` is `sceneLatitude` for anything else).
            ("scene_latitude_active", .bool(firstPlacement.active && !(digitalIntermediate && !scanFilm)), .shoot),
            ("scene_latitude_norm", .string(firstPlacement.norm), .shoot),
            ("scene_latitude_highlight_knee", .double(firstPlacement.highlightKnee), .shoot),
            ("scene_latitude_highlight_room", .double(firstPlacement.highlightRoom), .shoot),
            ("scene_latitude_shadow_knee", .double(firstPlacement.shadowKnee), .shoot),
            ("scene_latitude_shadow_room", .double(firstPlacement.shadowRoom), .shoot),
            ("scene_latitude_rolloff", .double(firstPlacement.rolloff), .shoot),
            ("scene_latitude_max_lift", .double(firstPlacement.maxLift), .shoot),
            // The Decode curve (API-SPEC §17): sent always, "" for none, so that taking a curve
            // off reaches an open session (`step` sends only what the wire still names).
            ("scene_curve", .string(sceneCurveWire), .shoot),
            // RFC-025, whose halation and glare rows RFC-034 turned into area
            // multipliers (`EffectStrengths`). Sent always, like RFC-024's:
            // every default is the engine's and 1 is a bypass, so the picture
            // of a legacy frame is unchanged (its stamp is not -- new fields
            // miss the cache once).
            ("halation_amount", .double(effects.halation.clamped(to: EffectStrengths.halationRange)), .shoot),
            ("halation_scatter_amount", .double(effects.scatter.clamped(to: EffectStrengths.scatterRange)), .shoot),
            ("grain_amount", .double(effects.grain.clamped(to: EffectStrengths.grainRange)), .shoot),
            ("dir_couplers_active", .bool(effects.couplersActive), .shoot),
            ("dir_couplers_amount", .double(effects.couplers.clamped(to: EffectStrengths.couplersRange)), .shoot),
            ("glare_amount", .double(effects.glare.clamped(to: EffectStrengths.glareRange)), .print),
            // RFC-028. The DI is sent always, like the rest (off is the
            // paper, exactly). The blue compensation only while the DI is on,
            // so the Settings switch cannot move any other frame's stamp.
            ("digital_intermediate", .bool(digitalIntermediate), .print),
            ("digital_intermediate_blue_compensation",
             .bool(digitalIntermediate && FilmParams.diBlueCompensation), .print),
        ]
        fields += pairPlacementWire
        return fields
    }

    static func printExposure(stops: Double) -> Double {
        (pow(2.0, -stops)).clamped(to: 0.05...20)
    }

    /// The `params_delta` that turns `other` into `self`, and the layers it
    /// touches. An empty delta means nothing to send.
    func delta(from other: FilmParams) -> (delta: [String: ParamValue], layers: Set<ParamLayer>) {
        var delta: [String: ParamValue] = [:]
        var layers = Set<ParamLayer>()
        let theirs = Dictionary(uniqueKeysWithValues: other.wire.map { ($0.name, $0.value) })
        for f in wire where theirs[f.name] != f.value {
            delta[f.name] = f.value
            layers.insert(f.layer)
        }
        // A film change also invalidates the print side (the service says so).
        if delta["film_stock"] != nil { layers.insert(.print) }
        return (delta, layers)
    }

    /// Everything, as sent with `open`.
    var fullDelta: [String: ParamValue] {
        Dictionary(uniqueKeysWithValues: wire.map { ($0.name, $0.value) })
    }

    /// What an open engine session is sent so that it holds the wire `now`,
    /// given what it was last told (`applied`, which this keeps): the fields
    /// whose value changed, and no others — naming a film-side field drops the
    /// session's negative whether or not its value moved (`SpkEngine`).
    ///
    /// **A stock change makes what the wire no longer carries the engine's
    /// again.** The engine rebuilds its pipeline when a delta names a stock and
    /// takes its own values for what depends on the pair — the enlarger's
    /// filter pack above all, from its table. A silver pair's pack is on the
    /// wire only for a silver pair (`StockCatalog.silver`), so after the next
    /// colour pair the engine holds that pair's own. Remembered as applied, the
    /// silver pack would be found unchanged at the next black-and-white film
    /// and never sent again: the print would keep the colour pair's filters
    /// (measured through a banded engine, 2026-10-09: a mean of 46,490 of 65,535
    /// where the pack gives 36,308). So at a stock change `applied` is cut back
    /// to the fields the wire has now.
    static func step(from applied: inout [String: ParamValue], to now: [String: ParamValue]) -> [String: ParamValue] {
        let delta = now.filter { applied[$0.key] != $0.value }
        applied.merge(delta) { _, new in new }
        if delta["film_stock"] != nil || delta["print_stock"] != nil {
            applied = applied.filter { now[$0.key] != nil }
        }
        return delta
    }

    /// Fields the service can write onto a live pipeline without a rebuild
    /// (`schema.LIVE_MUTABLE`). Informational — the client sends the same
    /// delta either way — but the scheduler uses it to pick the tighter
    /// debounce.
    static let liveMutable: Set<String> = ["print_exposure", "m_filter_shift", "y_filter_shift",
                                           "preflash_exposure", "filter_shift_scale"]

    /// What the ends of the Yellow and Magenta rulers are, in the enlarger
    /// head's CC units (`filter_shift_scale`). The wire's shifts are −1…1 and
    /// the engine adds them to a pack of about 55 / 65 CC, so sent bare a whole
    /// ruler was one CC: a twentieth of a stop end to end. 40 is the desktop's
    /// (`FilmParams.filterShiftCC` there, 2026-10-04): its ends are then about
    /// a third of a stop, blue against red.
    static let filterShiftCC: Double = 40
}
