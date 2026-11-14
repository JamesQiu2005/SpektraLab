//  LensEdge.swift — 漏光 light leaks, 镜头 Lens (柔光镜, 像差), and what the engine knows of them.
//
//  PRD-D §3.3–§3.4 (2026-11-11): light leaks, the diffusion filter and lens aberrations, against the wire of
//  API-SPEC §21. The rules the model keeps:
//
//  - **Off is structural.** Every new setting at its rest sends nothing, so a frame without them develops to the
//    same picture under the same stamp as before; and an edit written without them is the same JSON (each is
//    written only once it is not at rest). Every key `decodeIfPresent`; an unknown value falls back.
//  - **Sent only while on.** Their switches go back to their rest when they leave the wire
//    (`FilmParams.sometimesSent`, the desktop's `leavesToDefault`): `leak_kind` "off", `diffusion_filter_active`
//    and `lens_aberrations_active` false, `overscan_falloff` 0, `overscan_perforation` "none".
//  - **Only to an engine that knows them** (`EngineFeatures`): an unknown name fails a whole open, so a field the
//    engine's `spk_params_schema()` does not list is never sent, and the control that would set it is hidden.
//    `main`'s engine (af5173b9) knows none of them.
//
//  A leak is light on the film (冲洗 › 格式 › 效果); the filter and the aberrations are in front of the lens (编辑 ›
//  镜头), and both re-develop. The vignette beside them in 镜头 is Layer 2's, unchanged (`Adjustments.vignette`).
//
//  No UIKit: the self-tests compile this.

import Foundation

// MARK: - what the engine knows

/// The fields this app's engine has, read from its own schema once per engine (`SpkEngine.init`), and the features
/// they make. Before an engine is read — and with no engine at all — it knows none of them.
enum EngineFeatures {
    /// A feature the app offers only where the engine has its fields. The field named is the one checked: each
    /// came in with the rest of its section (API-SPEC §21), so one stands for all.
    enum Feature: String, CaseIterable, Sendable {
        /// `overscan_format = 135_sprocket` and `overscan_falloff` (API-SPEC §21.4).
        case fullWidth135 = "overscan_falloff"
        /// `overscan_perforation = ks65` (API-SPEC §21.3).
        case keyholes = "overscan_perforation"
        /// `leak_*` (API-SPEC §21.1).
        case leaks = "leak_kind"
        /// `diffusion_filter_*` on the camera (API-SPEC §21.5).
        case softFilter = "diffusion_filter_active"
        /// `lens_aberrations_active` and the twelve `lens_*` (API-SPEC §21.6).
        case lensCharacter = "lens_aberrations_active"
        /// The LED glow on every date imprint (API-SPEC §21.2): no field of its own; it came with the MZ-S line's
        /// `date_imprint_data_placement`, which stands for the engine that has it.
        case ledGlow = "date_imprint_data_placement"
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fields: Set<String>? = nil

    /// The engine's schema, read: every field's name (`SpkEngine`).
    static func publish(_ names: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        fields = names
    }

    /// Whether the engine has the field: what the **wire** holds to. False before an engine is read.
    static func knows(_ field: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fields?.contains(field) ?? false
    }
    static func knows(_ feature: Feature) -> Bool { knows(feature.rawValue) }

    /// **Debug only: show every control whatever the engine has** (`SPK_SHOW_UNWIRED=1` in the environment), to see
    /// the controls before an engine with their fields is linked. Pages only: the wire still holds to `knows`, so a
    /// control shown this way changes the edit and nothing the engine is sent — except the formats themselves, which
    /// such an engine refuses (the develop says so). Never in a release build.
    static var showsAll: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SPK_SHOW_UNWIRED"] == "1"
        #else
        return false
        #endif
    }

    /// Whether a page offers the feature: the engine has it (or the debug override). The 像差 page is phase 2 on
    /// top of that (`FeatureFlags.lensCharacter`).
    static func offers(_ feature: Feature) -> Bool {
        if feature == .lensCharacter && !FeatureFlags.lensCharacter { return false }
        return knows(feature) || showsAll
    }
}

// MARK: - 漏光 light leaks

/// `leak_kind` (API-SPEC §21.1): light that reached the film without passing the lens. Its colour is the film's own
/// sensitivity to it; no colour is painted.
enum LeakKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case off = "off"
    /// The camera's own: the body's seed picks band, wash or (on 120) spot.
    case auto = "auto"
    /// 光带: across the whole film width, 5–14 mm along, brighter at one long edge (a worn seal).
    case band = "band"
    /// 漫光: a graded flood along the film from one end (the back opened, the roll's ends).
    case wash = "wash"
    /// 光斑: a round leak, 3–8 mm (the 120 red window): 120 formats only, the engine refuses it elsewhere.
    case spot = "spot"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: L("Off")
        case .auto: L("Auto")
        case .band: L("Band", as: "a light leak")
        case .wash: L("Wash", as: "a light leak")
        case .spot: L("Spot", as: "a light leak")
        }
    }

    /// Whether a camera of this format can have it: a spot needs a 120 back's window.
    func isMade(on camera: FilmEdgeFormat) -> Bool { self != .spot || camera.is120 }
}

/// **漏光**, the frame's light leak (PRD-D §3.3): a kind and a strength. Where along the film, which edge and how
/// wide are the camera's and the frame's seeds (`overscan_camera_seed`, `overscan_frame_seed`), as for the film edge.
struct LeakSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case kind = "kind", amount = "amount" }
    var kind = LeakKind.off
    /// `leak_amount`: the peak's light, on the fog's scale — 1 reaches orange, 4 clips to white.
    var amount = 1.0

    static let amountRange = 0.0...4.0
    /// `leak_rate` for one picture edited alone: the frame always shows its camera's leak.
    static let rateAlone = 1.0
    /// `leak_rate` for a batch export, roll-like: a quarter of the frames, the engine weighting
    /// the roll's ends (frames 1–2 ×4, 33 on ×3).
    static let rateBatch = 0.25
    /// `leak_front`: −1 takes the camera's share of front light (band 0.3–0.7, wash and spot 0).
    static let front = -1.0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LeakSettings()
        kind = (try? c.decodeIfPresent(LeakKind.self, forKey: .kind)) ?? d.kind
        amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? d.amount
    }

    var isAtRest: Bool { self == LeakSettings() }
}

// MARK: - 镜头 Lens

/// `diffusion_filter_family` (API-SPEC §21.5): the 柔光镜's four families, as the oracle's `diffusion.py` names them.
/// The names shown are generic words, never the makers' marks.
enum SoftFilter: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 黑柔: lifts the highlights' glow and keeps the blacks.
    case blackMist = "black_pro_mist"
    /// 白柔: a softer, milkier glow that lifts the shadows a little.
    case whiteMist = "pro_mist"
    /// 闪柔: a fine sparkle on small lights, little haze.
    case glimmer = "glimmerglass"
    /// 晕柔: the widest, dreamiest halo.
    case bloom = "cinebloom"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blackMist: L("Black Mist")
        case .whiteMist: L("White Mist")
        case .glimmer: L("Glimmer")
        case .bloom: L("Bloom")
        }
    }

    /// 强度's detents: the filter's grade, 1/8 … 2 (`diffusion_filter_strength`, log-interpolated as upstream).
    static let strengths: [Double] = [0.125, 0.25, 0.5, 1, 2]
    static let defaultStrength = 0.5
    static func strengthText(_ s: Double) -> String {
        switch s {
        case 0.125: "1/8"
        case 0.25: "1/4"
        case 0.5: "1/2"
        default: s == s.rounded() ? String(Int(s)) : String(format: "%.2g", s)
        }
    }
}

/// **像差 Character** (API-SPEC §21.6): a named lens, a table of the twelve `lens_*` numbers at 程度 100 %.
/// The tables are the app's (API-SPEC: the wire carries numbers only). Phase 2 (PRD-D §6 q3): built, and held back
/// behind `FeatureFlags.lensCharacter` until the engine's speed-up lands. The names shown are generic.
enum LensCharacter: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 旋焦: a sharp middle, the edges smeared round the centre (the Helios 44 look).
    case swirl = "helios44"
    /// 佩兹伐: a very sharp middle, a strong swirl from a third out.
    case petzval = "petzval"
    /// 老镜: soft glow all over, mild edges, night lights with comet tails.
    case vintage = "vintage_soft"
    /// 玩具镜: a plastic lens — colour fringes, soft corners, glow.
    case toy = "plastic"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .swirl: L("Swirl", as: "a lens")
        case .petzval: L("Petzval")
        case .vintage: L("Vintage", as: "a lens")
        case .toy: L("Toy", as: "a lens")
        }
    }

    var preset: LensPreset {
        switch self {
        case .swirl: LensPreset(fieldCurvatureUM: 45, astigmatismUM: 70, fieldExponent: 2, comaUM: 25,
                                sphericalAmount: 0.08, sphericalUM: 60)
        case .petzval: LensPreset(fieldCurvatureUM: 70, astigmatismUM: 100, fieldExponent: 3, sharpRadius: 0.3)
        case .vintage: LensPreset(fieldCurvatureUM: 25, comaUM: 60, sphericalAmount: 0.2, sphericalUM: 80)
        case .toy: LensPreset(fieldCurvatureUM: 35, sphericalAmount: 0.25, sphericalUM: 120, lateralCAR: 1.5,
                              lateralCAB: -1.5, locaUM: 10, locaSign: "purple")
        }
    }
}

/// One named lens's numbers at 程度 100 %, each at the engine's own rest when the table names
/// none. Sizes are micrometres on the film at the frame's corner.
struct LensPreset: Equatable, Sendable {
    var fieldCurvatureUM = 0.0
    var astigmatismUM = 0.0
    var fieldExponent = 2.0
    var sharpRadius = 0.0
    var comaUM = 0.0
    var sphericalAmount = 0.0
    var sphericalUM = 60.0
    var lateralCAR = 0.0
    var lateralCAB = 0.0
    var locaUM = 0.0
    var locaSign = "purple"
    var locaHighlightGate = 1.0

    /// The wire at 程度 `amount` (0…1): the blurs, the fringes and the glow's share scale with it; the shape of the
    /// field (its exponent, the sharp middle, the glow's radius, the fringe's side) is the lens's own.
    func wire(amount: Double) -> [(name: String, value: ParamValue)] {
        let a = amount.clamped(to: 0...1)
        return [
            ("lens_aberrations_active", .bool(true)),
            ("lens_field_curvature_um", .double((fieldCurvatureUM * a).clamped(to: 0...120))),
            ("lens_astigmatism_um", .double((astigmatismUM * a).clamped(to: -120...120))),
            ("lens_field_exponent", .double(fieldExponent.clamped(to: 1...4))),
            ("lens_sharp_radius", .double(sharpRadius.clamped(to: 0...0.8))),
            ("lens_coma_um", .double((comaUM * a).clamped(to: -150...150))),
            ("lens_spherical_amount", .double((sphericalAmount * a).clamped(to: 0...0.6))),
            ("lens_spherical_um", .double(sphericalUM.clamped(to: 10...400))),
            ("lens_lateral_ca_r", .double((lateralCAR * a).clamped(to: -3...3))),
            ("lens_lateral_ca_b", .double((lateralCAB * a).clamped(to: -3...3))),
            ("lens_loca_um", .double((locaUM * a).clamped(to: 0...30))),
            ("lens_loca_sign", .string(locaSign)),
            ("lens_loca_highlight_gate", .double(locaHighlightGate.clamped(to: 0...1))),
        ]
    }
}

/// **镜头**'s settings on the negative: the 柔光镜 and the 像差. The vignette shown beside them is Layer 2's
/// (`Adjustments.vignette`) and is not here.
struct LensSettings: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case filter = "filter", strength = "strength", character = "character", amount = "amount"
    }
    /// The filter in front of the lens; nil is 关.
    var filter: SoftFilter? = nil
    var strength = SoftFilter.defaultStrength
    /// The lens's character; nil is 关.
    var character: LensCharacter? = nil
    /// 程度, 0…1.
    var amount = 1.0

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LensSettings()
        filter = try? c.decodeIfPresent(SoftFilter.self, forKey: .filter)
        strength = (try? c.decodeIfPresent(Double.self, forKey: .strength)) ?? d.strength
        character = try? c.decodeIfPresent(LensCharacter.self, forKey: .character)
        amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? d.amount
    }

    var isAtRest: Bool { self == LensSettings() }
    /// Whether anything of it is on (what the section's dot says).
    var isOn: Bool { filter != nil || character != nil }

    /// What it sends: the filter while it is on, the character while it is on (and offered), each only to an
    /// engine that has its fields. Nothing at all while both are off.
    var wire: [(name: String, value: ParamValue)] {
        var out: [(name: String, value: ParamValue)] = []
        if let filter, EngineFeatures.knows(.softFilter) {
            out += [("diffusion_filter_active", .bool(true)),
                    ("diffusion_filter_family", .string(filter.rawValue)),
                    ("diffusion_filter_strength", .double(strength.clamped(to: 0...2)))]
        }
        if FeatureFlags.lensCharacter, let character, EngineFeatures.knows(.lensCharacter) {
            out += character.preset.wire(amount: amount)
        }
        return out
    }
}

/// A value kept on the heap (`LensSettings` is boxed, so `FrameEdit` does not grow inline on a thin
/// main-thread stack). Immutable storage: a write makes a new box, so a copy of the edit never sees it.
struct Boxed<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    private final class Storage: Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
    private var storage: Storage
    init(_ value: Value) { storage = Storage(value) }
    var value: Value {
        get { storage.value }
        set { storage = Storage(newValue) }
    }
    init(from decoder: Decoder) throws { storage = Storage(try Value(from: decoder)) }
    func encode(to encoder: Encoder) throws { try storage.value.encode(to: encoder) }
    static func == (a: Boxed, b: Boxed) -> Bool { a.storage === b.storage || a.storage.value == b.storage.value }
}

// MARK: - the frame's wire for them

extension FrameEdit {
    /// The camera a leak is laid on: the film edge's format while it is on; otherwise a 135 body, as the date
    /// back's is (`DateBackSettings.camera`), so the two agree on `overscan_format`.
    var leakCamera: FilmEdgeFormat { filmEdge.effective ? filmEdge.format : .f135 }

    /// Whether the frame's leak is drawn: on, of a kind its camera can have, and an engine that has leaks.
    var leakIsDrawn: Bool {
        leak.kind != .off && leak.kind.isMade(on: leakCamera) && EngineFeatures.knows(.leaks)
    }

    /// `leak_*`, and — with the film edge off — the overscan seeds the leak reads (API-SPEC §21.1's
    /// seeds), from the same body and frame seed the film edge sends, so the leak does not move when the film
    /// edge goes on. `bodySeed` is the host's body for a frame with none of its own; `rate` is `LeakSettings.rateAlone`
    /// for one picture and `rateBatch` for a batch export.
    func leakWire(bodySeed: Int, rate: Double = LeakSettings.rateAlone) -> [(name: String, value: ParamValue)] {
        guard leakIsDrawn else { return [] }
        var out: [(name: String, value: ParamValue)] = [
            ("leak_kind", .string(leak.kind.rawValue)),
            ("leak_amount", .double(leak.amount.clamped(to: LeakSettings.amountRange))),
            ("leak_rate", .double(rate.clamped(to: 0...1))),
            ("leak_front", .double(LeakSettings.front)),
        ]
        if !filmEdge.effective {
            let body = filmEdge.cameraSeed == 0 ? bodySeed : filmEdge.cameraSeed
            out += [
                ("overscan_format", .string(leakCamera.rawValue)),
                ("overscan_camera_seed", .double(Double(body.clamped(to: FilmEdgeSettings.seedRange)))),
                ("overscan_frame_seed", .double(Double(frameSeed.clamped(to: FilmEdgeSettings.seedRange)))),
                ("overscan_frame_number", .double(Double(filmEdge.frameNumber.clamped(to: FilmEdgeSettings.frameNumberRange)))),
            ]
        }
        return out
    }
}

// MARK: - 孔间数据 Perforation Data's line

/// **The Perforation Data line** (PRD-D §3.2b; API-SPEC §21.2): the shooting data a camera prints one field
/// per gap between the perforations, from the file's own EXIF, joined by `|` — mode, metering, shutter, aperture,
/// compensation: `P|{meter:multi}|180|F8|±0.0`. A field the file does not have is left out, never invented.
///
/// - mode: `P` `Av` `Tv` `M`, from ExposureProgram 2, 3, 4, 1;
/// - metering: `{meter:multi}` `{meter:center}` `{meter:spot}`, from MeteringMode 5, 2, 3 (the engine's own marks);
/// - shutter: `180` for 1/180 s, `2"` for 2 s;
/// - aperture: `F8`, `F5.6`;
/// - compensation: `±0.0`, `+0.7`, `-1.0` — with the ASCII hyphen-minus, which the engine's 5 × 7 set draws (it has
///   no U+2212; `±` and `"` it has, for this line).
struct PerforationLine: Equatable, Sendable {
    var exposureProgram: Int? = nil
    var meteringMode: Int? = nil
    var seconds: Double? = nil
    var fNumber: Double? = nil
    var biasEV: Double? = nil

    var text: String {
        var fields: [String] = []
        switch exposureProgram {
        case 1: fields.append("M")
        case 2: fields.append("P")
        case 3: fields.append("Av")
        case 4: fields.append("Tv")
        default: break
        }
        switch meteringMode {
        case 5: fields.append("{meter:multi}")
        case 2: fields.append("{meter:center}")
        case 3: fields.append("{meter:spot}")
        default: break
        }
        if let t = seconds, t > 0, t.isFinite {
            if t < 1 { fields.append(String(Int((1 / t).rounded()))) }
            else { fields.append(Self.number(t) + "\"") }
        }
        if let f = fNumber, f > 0, f.isFinite { fields.append("F" + Self.number(f)) }
        if let b = biasEV, b.isFinite {
            let tenth = (b * 10).rounded() / 10
            fields.append(tenth == 0 ? "±0.0" : (tenth > 0 ? "+" : "-") + String(format: "%.1f", abs(tenth)))
        }
        return fields.joined(separator: "|")
    }

    /// 8, 5.6, 2.5, 30: a tenth at most, no trailing zero.
    private static func number(_ x: Double) -> String {
        let r = (x * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// The line as a card's sample draws it: the metering marks left out and the fields spaced.
    static func shown(_ line: String) -> String {
        var s = line
        for token in ["{meter:multi}", "{meter:center}", "{meter:spot}"] { s = s.replacingOccurrences(of: token, with: "") }
        return s.split(separator: "|").joined(separator: " ")
    }
}
