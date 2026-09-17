//  Params.swift — Layer 1: the engine's parameters, as the UI holds them.
//
//  Mirrors `src/spektrafilm/service/schema.py` field for field. Two rules:
//
//  1. Wire names are the schema's names. `delta(from:)` produces exactly the
//     `params_delta` object the service validates, nothing else.
//  2. Every field knows its layer (`shoot` / `print`) — the same table the
//     service uses to decide between a 190 ms reprint and a film-side
//     re-render. The scheduler routes on it, so a wrong layer here is a
//     correctness bug, not a metadata one.

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
    case short, long
    var id: String { rawValue }
    var title: String { self == .short ? "Short" : "Long" }
}

/// The unit the Side Length is typed in. Display only — the wire is always
/// millimetres — so it is an app preference rather than part of a frame's
/// settings.
enum SideUnit: String, CaseIterable, Identifiable, Sendable {
    case mm, cm, inch
    var id: String { rawValue }
    var title: String { self == .inch ? "in" : rawValue }
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
    case balanced
    case center
    case protectHighlights = "protect_highlights"
    case protectShadows = "protect_shadows"

    var id: String { rawValue }

    /// What the pill shows: lowercase, as the user's drawing has it.
    var title: String {
        switch self {
        case .balanced: "balanced"
        case .center: "center"
        case .protectHighlights: "protect highlights"
        case .protectShadows: "protect shadows"
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
        guard let value else { return "center-weighted (legacy)" }
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
        case .custom: "Custom"
        case .metered(let m): m.title.capitalizedFirst
        case .legacy: "center-weighted (legacy)"
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

struct FilmParams: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case filmStock, printStock, exposureCompensationEV, autoExposureMethod, autoExposure
        case filmFormatMM, filmFrame, filmSide, sideLengthMM, grainActive, halationActive
        case printBrightnessStops, yFilterShift, mFilterShift, glareActive, scanFilm
        case extendedDynamicRange
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
    /// It has always been in the schema and nothing has ever sent it, so the
    /// engine has always run with its own `true`. The default here is that,
    /// which is what keeps every sidecar written before this field rendering
    /// exactly as it did.
    var autoExposure: Bool = true
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
    /// Preserve the extended range while rendering a selected print profile.
    /// This is a print-layer choice, so it reprints the cached negative. The
    /// preference is retained when `scanFilm` is selected, but is made
    /// ineffective on the direct film-scan path.
    var extendedDynamicRange: Bool = false

    /// The backend only applies EDR to an actual print profile. Keep the
    /// user's preference in the sidecar while making the wire value false for
    /// the Positive / No Print Profile path, so a persisted preference cannot
    /// change direct film scanning.
    var effectiveExtendedDynamicRange: Bool { extendedDynamicRange && !scanFilm }

    init() {
        filmStock = "kodak_portra_400"
        printStock = "kodak_supra_endura"
        exposureCompensationEV = 0
        autoExposureMethod = "balanced"
        autoExposure = true
        filmFormatMM = 36
        filmFrame = "135"
        filmSide = FilmSide.short.rawValue
        sideLengthMM = 24
        grainActive = true
        halationActive = true
        printBrightnessStops = 0
        yFilterShift = 0
        mFilterShift = 0
        glareActive = true
        scanFilm = false
        extendedDynamicRange = false
    }

    /// Keep sidecars written before EDR readable. Stored properties with
    /// defaults still use `decode(_:forKey:)` in synthesized Codable, so an
    /// absent key would otherwise reject the whole `FilmParams` value. The
    /// older fields retain their synthesized Codable requirements; a missing
    /// exposure method deliberately remains nil because that is the legacy
    /// wire state. Only EDR is new and therefore defaults when absent.
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
        printBrightnessStops = try c.decode(Double.self, forKey: .printBrightnessStops)
        yFilterShift = try c.decode(Double.self, forKey: .yFilterShift)
        mFilterShift = try c.decode(Double.self, forKey: .mFilterShift)
        glareActive = try c.decode(Bool.self, forKey: .glareActive)
        scanFilm = try c.decode(Bool.self, forKey: .scanFilm)
        extendedDynamicRange = try c.decodeIfPresent(Bool.self, forKey: .extendedDynamicRange) ?? false
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
            ("grain_sublayers_active", .bool(grainActive), .shoot),
            ("halation_active", .bool(halationActive), .shoot),
            ("print_exposure", .double(FilmParams.printExposure(stops: printBrightnessStops)), .print),
            ("y_filter_shift", .double(yFilterShift), .print),
            ("m_filter_shift", .double(mFilterShift), .print),
            ("glare_active", .bool(glareActive), .print),
            ("scan_film", .bool(scanFilm), .print),
            ("extended_dynamic_range", .bool(effectiveExtendedDynamicRange), .print),
        ]
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

    /// Fields the service can write onto a live pipeline without a rebuild
    /// (`schema.LIVE_MUTABLE`). Informational — the client sends the same
    /// delta either way — but the scheduler uses it to pick the tighter
    /// debounce.
    static let liveMutable: Set<String> = ["print_exposure", "m_filter_shift", "y_filter_shift"]
}
