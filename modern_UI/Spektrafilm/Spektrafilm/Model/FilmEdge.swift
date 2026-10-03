import Foundation

/// RFC-032's **Film Edge** (overscan) and RFC-031's **Date Back**, as the app
/// keeps them: the wire's twenty fields (API-SPEC §13) plus what the host
/// resolves for the engine. Both are shoot layer and not live: every mark is
/// exposure on the negative, so an edit re-develops it.

/// The film and its gate. The raw value is the wire's `overscan_format`.
enum FilmEdgeFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case f135 = "135"
    case f135Half = "135_half"
    case f645 = "120_645"
    case f6x6 = "120_6x6"
    case f6x7 = "120_6x7"
    case f6x8 = "120_6x8"
    case f6x9 = "120_6x9"
    /// The panoramic long formats (answer sheet C1, C9). **Not in the engine
    /// yet** — it refuses the names — so `isAvailable` is false and the menu
    /// draws them disabled. They become real when the long-format engine work
    /// lands in the mobile repo and is synced (answer A3).
    case xpan = "135_xpan"
    case f6x12 = "120_6x12"
    case f6x17 = "120_6x17"

    var id: String { rawValue }

    enum Group: String, CaseIterable, Sendable { case film135, film120, panoramic }

    var group: Group {
        switch self {
        case .f135, .f135Half: .film135
        case .f645, .f6x6, .f6x7, .f6x8, .f6x9: .film120
        case .xpan, .f6x12, .f6x17: .panoramic
        }
    }

    /// The gate, in millimetres: along the film by across it for the camera
    /// held level (RFC-032 §29; the engine's own table in `overscan.cpp`).
    var gateMM: (long: Double, short: Double) {
        switch self {
        case .f135: (36, 24)
        case .f135Half: (24, 18)
        case .f645: (56, 41.5)
        case .f6x6: (56, 56)
        case .f6x7: (69.5, 56)
        case .f6x8: (76, 56)
        case .f6x9: (84, 56)
        case .xpan: (65, 24)
        case .f6x12: (112, 56)
        case .f6x17: (168, 56)
        }
    }

    /// The film this format runs on, as the stock catalogue names gauges
    /// (`Stock.formats`): half frame and XPan are cameras for 135 film.
    var gauge: String { self == .f135 || self == .f135Half || self == .xpan ? "135" : "120" }

    /// The film's width across, mm (the engine's `kFormats`; D2: 35.00).
    var filmWidthMM: Double { gauge == "135" ? 35 : 61 }

    /// What the engine will take today.
    var isAvailable: Bool { group != .panoramic }
    var isPerforated: Bool { self == .f135 || self == .f135Half || self == .xpan }

    /// Which date faces the engine draws on this format (API-SPEC §13, "Where
    /// a face is drawn"). Anywhere else a date is silently not drawn, so the
    /// UI must not offer it. Nothing on the panoramic formats (answer C7).
    func draws(_ face: DateBackFace) -> Bool {
        switch self {
        case .f135, .f135Half: true
        case .f645: face == .data
        default: false
        }
    }
}

enum FilmEdgeView: String, CaseIterable, Identifiable, Codable, Sendable {
    case strip, filed
    var id: String { rawValue }
}

enum FilmEdgeGate: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, square, rounded, eared, shouldered, kicked
    var id: String { rawValue }
}

enum FilmEdgeHoles: String, CaseIterable, Identifiable, Codable, Sendable {
    case white, black
    var id: String { rawValue }
}

struct FilmEdgeSettings: Codable, Equatable, Sendable {
    var active = false
    var format = FilmEdgeFormat.f135
    var view = FilmEdgeView.strip
    var gate = FilmEdgeGate.auto
    var holes = FilmEdgeHoles.white
    /// **The body.** Per user, not per photo: the same camera shot the roll.
    /// A new frame takes `FilmEdgeSettings.bodySeed`.
    var cameraSeed = 1
    /// **The advance and the scan.** Per photo, stored with the edit.
    var frameSeed = 1
    /// **The frame's number** on the edge print (owner, 2026-10-03): 1…99;
    /// 0 is the frame seed's draw. A new frame takes its place in the session
    /// (`Session.seedFilmEdge`), so a roll reads 1, 2, 3… untouched.
    var frameNumber = 0
    var fog = 1.0                  // 0…4
    var leaks = 0.0                // 0…4
    /// The stock's edge print, resolved by the session from the stock in use.
    /// Desktop prints the real name (answer B16).
    var edgeText = ""
    /// From EXIF, resolved by the session; 0 = unknown (the engine takes f/5.6).
    var fNumber = 0.0
    /// The crop the engine's frame was cut with, as a key; resolved by the
    /// session from the frame's geometry. Not a wire field: with a film edge
    /// the engine is handed the picture already cut (it takes the frame it is
    /// given as the gate), so the crop is part of the negative and the print
    /// stamp carries it (`Session.printStamp`).
    var framing = ""
    /// Whether this frame has been given its seeds (`Session.seedFilmEdge`).
    /// A frame from before the film edge existed has none, and gets a frame
    /// seed of its own and the user's body the first time it is opened.
    var seeded = false

    static let fogRange = 0.0...4.0
    static let leaksRange = 0.0...4.0
    static let seedRange = 0...Int(Int32.max)
    static let frameNumberRange = 0...99

    static let `default` = FilmEdgeSettings()

    init() {}

    /// Every key optional, so a sidecar from before a field existed decodes.
    /// An unknown enum value (a newer build's format) falls back to the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilmEdgeSettings()
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? d.active
        format = (try? c.decodeIfPresent(FilmEdgeFormat.self, forKey: .format)) ?? d.format
        view = (try? c.decodeIfPresent(FilmEdgeView.self, forKey: .view)) ?? d.view
        gate = (try? c.decodeIfPresent(FilmEdgeGate.self, forKey: .gate)) ?? d.gate
        holes = (try? c.decodeIfPresent(FilmEdgeHoles.self, forKey: .holes)) ?? d.holes
        cameraSeed = try c.decodeIfPresent(Int.self, forKey: .cameraSeed) ?? d.cameraSeed
        frameSeed = try c.decodeIfPresent(Int.self, forKey: .frameSeed) ?? d.frameSeed
        frameNumber = try c.decodeIfPresent(Int.self, forKey: .frameNumber) ?? d.frameNumber
        fog = try c.decodeIfPresent(Double.self, forKey: .fog) ?? d.fog
        leaks = try c.decodeIfPresent(Double.self, forKey: .leaks) ?? d.leaks
        edgeText = try c.decodeIfPresent(String.self, forKey: .edgeText) ?? d.edgeText
        fNumber = try c.decodeIfPresent(Double.self, forKey: .fNumber) ?? d.fNumber
        framing = try c.decodeIfPresent(String.self, forKey: .framing) ?? d.framing
        // A record that carries a frame seed was seeded by whoever wrote it.
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? c.contains(.frameSeed)
    }

    /// The user's camera body: the camera seed a new frame takes. Kept per
    /// user (`bodySeedKey`), drawn once at random the first time it is asked
    /// for, and moved by *Another* (answer sheet §3, "one per user"). Short,
    /// so it reads as a serial plate.
    nonisolated static let bodySeedKey = "ui2.filmEdgeBodySeed"
    nonisolated static let bodySeedRange = 1...999
    nonisolated static func bodySeed(in defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: bodySeedKey)
        if seedRange.contains(stored), stored != 0 { return stored }
        let drawn = Int.random(in: bodySeedRange)
        defaults.set(drawn, forKey: bodySeedKey)
        return drawn
    }
    nonisolated static func setBodySeed(_ seed: Int, in defaults: UserDefaults) {
        defaults.set(seed.clamped(to: seedRange), forKey: bodySeedKey)
    }

    /// True when the engine draws the film: the switch, on a format it has.
    var effective: Bool { active && format.isAvailable }

    /// `overscan_active` always, so turning it off reaches the engine; the
    /// rest only while it is on, so a frame without a film edge keeps the
    /// stamp it had (off is structural: nothing is dispatched).
    var wire: [(name: String, value: ParamValue, layer: ParamLayer)] {
        var fields: [(name: String, value: ParamValue, layer: ParamLayer)] = [
            ("overscan_active", .bool(effective), .shoot),
        ]
        guard effective else { return fields }
        fields += [
            ("overscan_format", .string(format.rawValue), .shoot),
            ("overscan_mode", .string(view.rawValue), .shoot),
            ("overscan_gate", .string(gate.rawValue), .shoot),
            ("overscan_holes", .string(holes.rawValue), .shoot),
            ("overscan_camera_seed", .double(Double(cameraSeed.clamped(to: Self.seedRange))), .shoot),
            ("overscan_frame_seed", .double(Double(frameSeed.clamped(to: Self.seedRange))), .shoot),
            ("overscan_frame_number", .double(Double(frameNumber.clamped(to: Self.frameNumberRange))), .shoot),
            ("overscan_fog", .double(fog.clamped(to: Self.fogRange)), .shoot),
            ("overscan_leaks", .double(leaks.clamped(to: Self.leaksRange)), .shoot),
            ("overscan_edge_text", .string(edgeText), .shoot),
            ("overscan_f_number", .double(fNumber.clamped(to: 0...64)), .shoot),
        ]
        return fields
    }
}

/// The date back's three faces of one mechanism. Raw value: `date_imprint_style`.
enum DateBackFace: String, CaseIterable, Identifiable, Codable, Sendable {
    case lcd, dots, data
    var id: String { rawValue }
}

/// Raw value: `date_imprint_placement`. `between` is the wire's `rebate`.
enum DateBackPlacement: String, CaseIterable, Identifiable, Codable, Sendable {
    case frame, between = "rebate"
    var id: String { rawValue }
}

enum DateBackCorner: String, CaseIterable, Identifiable, Codable, Sendable {
    case br, bl, tr, tl
    var id: String { rawValue }
}

/// The order the date is written in (answer E1: US and Japan first). The
/// engine takes the text already formatted; `DateBackSettings.format` does it.
enum DateBackOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Month, day, year: `10 1 '26`.
    case us
    /// Year, month, day: `'26 10 1`.
    case japan
    var id: String { rawValue }
}

struct DateBackSettings: Codable, Equatable, Sendable {
    var active = false
    var face = DateBackFace.lcd
    var order = DateBackOrder.japan
    var placement = DateBackPlacement.frame
    var corner = DateBackCorner.br
    var insetXMM = 3.0             // 0…30
    var insetYMM = 2.4             // 0…30
    var size = 1.0                 // 0.4…3
    var brightnessEV = 3.5         // −2…8
    /// What the engine prints, already formatted. Resolved by the session: the
    /// date from EXIF in `order` for `lcd`/`dots`, the shooting data for
    /// `data` (RFC-033; answers E7–E9). Empty prints nothing.
    var text = ""
    /// The user's own text, which wins over the resolved one when set.
    var customText: String?
    /// The camera the date is printed by while there is no film edge,
    /// resolved by the session from the right rail's Film Format
    /// (`Session.dateBackCamera`); nil when Film Format describes no camera
    /// that had a date back, and then nothing is drawn. With a film edge the
    /// film edge's format is the camera, whatever this says.
    var camera: FilmEdgeFormat? = .f135
    /// The crop the engine's frame is cut with while the date is on without a
    /// film edge, as a key (`Session.framingKey`), or empty for the whole
    /// frame. Resolved by the session. The engine prints the date in the
    /// corner of the frame it is handed, so a cropped, turned or flipped
    /// picture has to be that frame; handed the whole decode, the date was
    /// cropped away, turned onto its side or mirrored with the picture.
    var framing = ""
    /// The cut frame's long edge over the photograph's, resolved with
    /// `framing`: what keeps the pixel pitch when the engine is handed less
    /// of the frame (`FilmParams.wireFilmFormatMM`). 1 for the whole frame.
    var frameScale = 1.0

    static let insetRange = 0.0...30.0
    static let sizeRange = 0.4...3.0
    static let brightnessRange = -2.0...8.0
    /// `data` between half frames has only the 1 mm gap (answer B19).
    static let halfFrameDataSizeMax = 1.0

    static let `default` = DateBackSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DateBackSettings()
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? d.active
        face = (try? c.decodeIfPresent(DateBackFace.self, forKey: .face)) ?? d.face
        order = (try? c.decodeIfPresent(DateBackOrder.self, forKey: .order)) ?? d.order
        placement = (try? c.decodeIfPresent(DateBackPlacement.self, forKey: .placement)) ?? d.placement
        corner = (try? c.decodeIfPresent(DateBackCorner.self, forKey: .corner)) ?? d.corner
        insetXMM = try c.decodeIfPresent(Double.self, forKey: .insetXMM) ?? d.insetXMM
        insetYMM = try c.decodeIfPresent(Double.self, forKey: .insetYMM) ?? d.insetYMM
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        brightnessEV = try c.decodeIfPresent(Double.self, forKey: .brightnessEV) ?? d.brightnessEV
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        customText = try c.decodeIfPresent(String.self, forKey: .customText)
        camera = (try? c.decodeIfPresent(FilmEdgeFormat.self, forKey: .camera)) ?? d.camera
        framing = try c.decodeIfPresent(String.self, forKey: .framing) ?? d.framing
        frameScale = try c.decodeIfPresent(Double.self, forKey: .frameScale) ?? d.frameScale
    }

    /// The date as a date back writes it: no leading zeros, a two-digit year
    /// behind an apostrophe.
    static func format(year: Int, month: Int, day: Int, order: DateBackOrder) -> String {
        let yy = String(format: "'%02d", ((year % 100) + 100) % 100)
        switch order {
        case .us: return "\(month) \(day) \(yy)"
        case .japan: return "\(yy) \(month) \(day)"
        }
    }

    var printedText: String { customText ?? text }

    /// The size the wire carries: capped where the face has no room.
    func wireSize(on format: FilmEdgeFormat) -> Double {
        let s = size.clamped(to: Self.sizeRange)
        return face == .data && format == .f135Half ? min(s, Self.halfFrameDataSizeMax) : s
    }

    /// Whether `face` has somewhere to print: a face the camera carries, and
    /// for the data face a film edge, because it goes between frames (135) or
    /// in the margin (645) and neither exists on the bare picture.
    func prints(_ face: DateBackFace, filmEdge: FilmEdgeSettings) -> Bool {
        guard let camera = cameraFormat(filmEdge: filmEdge), camera.draws(face) else { return false }
        return face == .data ? filmEdge.effective : true
    }

    /// True when the engine draws a date: the switch, a face with somewhere
    /// to print, and — between frames — a film edge to print it on.
    func effective(filmEdge: FilmEdgeSettings) -> Bool {
        guard active, prints(face, filmEdge: filmEdge) else { return false }
        return face == .data || placement == .frame || filmEdge.effective
    }

    /// The camera that prints: the film edge's format while it is on, the
    /// resolved Film Format camera otherwise.
    func cameraFormat(filmEdge: FilmEdgeSettings) -> FilmEdgeFormat? {
        filmEdge.effective ? filmEdge.format : camera
    }

    /// True when the date alone has the engine's frame cut by the crop.
    func cutsFrame(filmEdge: FilmEdgeSettings) -> Bool {
        !filmEdge.effective && effective(filmEdge: filmEdge) && !framing.isEmpty
    }

    /// `date_imprint_active` always; the rest only while it is on (see
    /// `FilmEdgeSettings.wire`). The camera's format rides on
    /// `overscan_format` even with the film edge off, because the engine
    /// reads the film's direction from it. `scale` is the cut picture against
    /// the camera's whole frame (`FilmParams.dateScale`): the date keeps its
    /// size and its insets in the picture, not on the negative.
    func wire(filmEdge: FilmEdgeSettings, scale: Double = 1) -> [(name: String, value: ParamValue, layer: ParamLayer)] {
        let on = effective(filmEdge: filmEdge)
        var fields: [(name: String, value: ParamValue, layer: ParamLayer)] = [
            ("date_imprint_active", .bool(on), .shoot),
        ]
        guard on else { return fields }
        let camera = cameraFormat(filmEdge: filmEdge) ?? filmEdge.format
        if !filmEdge.effective {
            fields.append(("overscan_format", .string(camera.rawValue), .shoot))
        }
        fields += [
            ("date_imprint_style", .string(face.rawValue), .shoot),
            ("date_imprint_text", .string(printedText), .shoot),
            ("date_imprint_placement", .string(placement.rawValue), .shoot),
            ("date_imprint_corner", .string(corner.rawValue), .shoot),
            ("date_imprint_inset_x", .double((insetXMM * scale).clamped(to: Self.insetRange)), .shoot),
            ("date_imprint_inset_y", .double((insetYMM * scale).clamped(to: Self.insetRange)), .shoot),
            ("date_imprint_size", .double((wireSize(on: camera) * scale).clamped(to: Self.sizeRange)), .shoot),
            ("date_imprint_ev", .double(brightnessEV.clamped(to: Self.brightnessRange)), .shoot),
        ]
        return fields
    }
}

extension FilmParams {
    /// True when the engine is handed the picture already cut by the crop
    /// rather than the whole decode: a film edge (the frame is the gate), or
    /// the date alone on a frame whose geometry is not the identity.
    var cutsFrame: Bool { filmEdge.effective || dateBack.cutsFrame(filmEdge: filmEdge) }

    /// The framing the engine's frame must have been cut with, or nil for the
    /// whole decode.
    var engineFramingKey: String? {
        if filmEdge.effective { return filmEdge.framing }
        return dateBack.cutsFrame(filmEdge: filmEdge) ? dateBack.framing : nil
    }

    /// `film_format_mm` as sent. The engine takes it as the long edge of the
    /// frame it is handed; when the date has that frame cut, the cut's own
    /// long edge keeps the pitch, so the grain does not move with the date.
    var wireFilmFormatMM: Double {
        dateBack.cutsFrame(filmEdge: filmEdge) ? filmFormatMM * dateBack.frameScale : filmFormatMM
    }

    /// The cut picture's long edge against the camera's own frame, which the
    /// date's size and insets follow. 1 for the whole frame, and 1 when the
    /// crop is itself the frame (`Session.recalculateEffectsAfterCrop`).
    var dateScale: Double {
        guard dateBack.cutsFrame(filmEdge: filmEdge), let camera = dateBack.camera else { return 1 }
        return (wireFilmFormatMM / camera.gateMM.long).clamped(to: 0.05...1)
    }
}
