//  FilmEdge.swift — Film Edge (overscan) and the Date Back, as the host keeps them.
//
//  RFC-032's film outside the frame and RFC-031's date back. Both are shoot
//  layer and never live: every mark is exposure on the negative, so an edit
//  develops again. The fields are the wire's own (the desktop's API-SPEC §13,
//  this repository's §15) and the types follow the desktop's `Model/FilmEdge.swift`
//  (SpektraLab `unpublished-revision`, the maintainer's), so an edit can move between the two.
//
//  **What is not here, on purpose.** The half-frame *pair* — two half frames
//  on one strip (`overscan_pair`) — is not a film edge of a frame's: it is its
//  own model (`HalfFramePair.swift`) with its own switch for the strip
//  (`onStrip`), and its wire is written in `Engine/PairDevelop.swift`. Nothing
//  in this file carries it. A single half frame is an ordinary format and is
//  here.

import CoreGraphics
import Foundation

/// The film and its gate. The raw value is the wire's `overscan_format`.
enum FilmEdgeFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case f135 = "135"
    case half = "135_half"
    case f645 = "120_645"
    case f6x6 = "120_6x6"
    case f6x7 = "120_6x7"
    case f6x8 = "120_6x8"
    case f6x9 = "120_6x9"
    /// The panoramic long formats: in the engine since 2026-10-03 (desktop
    /// `unpublished-revision`), square gates until real strips are measured, no date back.
    case xpan = "135_xpan"
    /// **135 全宽, 135 Full Width** (API-SPEC §21.4; PRD-D §3.1): a toy panorama's frame, 72 mm
    /// along and the whole 35 mm across, so the picture runs over the perforations and under the film's own
    /// edge print. The gate (36 mm) is wider than the film: the film's own edges bound the picture. Square gate
    /// only, holes start Black, no date back (the panoramic rule), no half-frame pair (the engine refuses it).
    /// Offered only on an engine that knows it (`EngineFeatures.fullWidth135`).
    case sprocket135 = "135_sprocket"
    case f6x12 = "120_6x12"
    case f6x17 = "120_6x17"

    var id: String { rawValue }

    enum Group: String, CaseIterable, Sendable {
        case film135 = "35 mm", film120 = "120", panoramic = "Panoramic"
    }

    /// **片幅 the format cards' filter** (PRD-D §3.1): 全部 · 135 · 120 · 宽幅, each a `Group` but All. Kept in the
    /// app's defaults (`DevelopPanelPrefs.filmEdgeFilter`), All until chosen.
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all = "all", film135 = "135", film120 = "120", panoramic = "wide"
        var id: String { rawValue }
        var group: Group? {
            switch self {
            case .all: nil
            case .film135: .film135
            case .film120: .film120
            case .panoramic: .panoramic
            }
        }
        var label: String {
            switch self {
            case .all: L("All", as: "formats")
            case .film135: "135"
            case .film120: "120"
            case .panoramic: L("Wide", as: "formats")
            }
        }
        /// The cards it shows, in the engine's order, of the formats `offered`. With a format chosen
        /// that it hides, the row still names it (`FilmStepPanel`): nothing chosen is ever unseen.
        func formats(of offered: [FilmEdgeFormat] = FilmEdgeFormat.offered) -> [FilmEdgeFormat] {
            guard let group else { return offered }
            return offered.filter { $0.group == group }
        }
    }

    /// The formats a card is drawn for: every one but those the engine does not know (135 Full Width before
    /// API-SPEC §21). A frame that already has one keeps it (the row names it).
    static var offered: [FilmEdgeFormat] {
        allCases.filter { $0 != .sprocket135 || EngineFeatures.offers(.fullWidth135) }
    }

    var group: Group {
        switch self {
        case .f135, .half: .film135
        case .f645, .f6x6, .f6x7, .f6x8, .f6x9: .film120
        case .xpan, .sprocket135, .f6x12, .f6x17: .panoramic
        }
    }

    /// The card's name (`gen_overscan.FMT`).
    var label: String {
        switch self {
        case .f135: "135"
        case .half: L("Half")
        case .f645: "645"
        case .f6x6: "6×6"
        case .f6x7: "6×7"
        case .f6x8: "6×8"
        case .f6x9: "6×9"
        case .xpan: "XPan"
        case .sprocket135: L("135 Full Width")
        case .f6x12: "6×12"
        case .f6x17: "6×17"
        }
    }

    /// A card's two lines: its name and the gate's shape — and for 135 Full Width, whose name does not fit a
    /// 72 pt card, "135" over "Full Width" (its shape is in its help and its line).
    var cardTitle: String { self == .sprocket135 ? "135" : label }
    var cardDetail: String { self == .sprocket135 ? L("Full Width") : aspectText }

    /// The card's second line: the gate's shape.
    var aspectText: String {
        switch self {
        case .f135: "3:2"
        case .half: "3:4"
        case .f645: "1.35"
        case .f6x6: "1:1"
        case .f6x7: "1.24"
        case .f6x8: "1.36"
        case .f6x9: "3:2"
        case .xpan: "2.7"
        case .sprocket135: "2:1"
        case .f6x12: "2:1"
        case .f6x17: "3:1"
        }
    }

    /// The engine's own table (`kFormats`, `overscan.cpp`): the film's width,
    /// the gate across the film and along it, in millimetres. 135's gate is a
    /// camera's, measured on seven strips (36.25 × 24.3), not ISO's 36 × 24.
    var filmWidthMM: Double { isPerforated ? 35.0 : 61.0 }
    var acrossMM: Double {
        switch self {
        case .f135: 24.3
        case .half, .xpan: 24.0
        // Wider than the 35 mm film: the film's own edges bound the picture (`kFormats`).
        case .sprocket135: 36.0
        default: 56.0
        }
    }
    var alongMM: Double {
        switch self {
        case .f135: 36.25
        case .half: 18.0
        case .f645: 41.5
        case .f6x6: 56.0
        case .f6x7: 69.5
        case .f6x8: 76.0
        case .f6x9: 84.0
        case .xpan: 65.0
        case .sprocket135: 72.0
        case .f6x12: 112.0
        case .f6x17: 168.0
        }
    }
    var isPerforated: Bool { self == .f135 || self == .half || self == .xpan || self == .sprocket135 }
    /// A 120 format: the only ones a leak's 120 window (`spot`) and the cine film's keyholes (`ks65`) are on.
    var is120: Bool { gauge == "120" }

    /// `overscan_falloff`: the engine's cos⁴ lens falloff inside the gate, × this (API-SPEC §21.4).
    /// **0 on every format** (the owner, 2026-11-11: "the default vignette is too much"): Edit › 镜头 › 暗角 is the
    /// only vignette, on 135 Full Width as on any other. Still sent, at 0, with every film edge to an engine that
    /// knows it (`FilmEdgeSettings.wire`), so an engine's own default never reaches the picture. **The one place to
    /// change it.**
    var falloff: Double { 0 }

    /// The view this format is drawn as whatever the frame keeps (`FilmEdgeSettings.view`); nil where the person
    /// chooses. **135 Full Width is a strip** (the owner, 2026-11-11: the View row greyed there, not hidden): its
    /// picture runs over the whole 35 mm, so the strip -- the film's whole width -- is the picture and its film
    /// edge, and a filed carrier's sliver of rebate round the gate has no rebate to show; the engine's filed canvas
    /// would be the gate and 1.1 mm past it, wider than the film itself.
    var fixedView: FilmEdgeView? { self == .sprocket135 ? .strip : nil }

    /// What the holes start as when this format is picked: 135 Full Width's reference strip is a darkroom print
    /// (black holes); every other format keeps the frame's own.
    var startingHoles: FilmEdgeHoles? { self == .sprocket135 ? .black : nil }
    /// The gate families its real cameras have, for `gate = auto`, in the
    /// engine's order (the camera seed picks one).
    var families: [FilmEdgeGate] {
        switch self {
        case .f645: [.eared, .rounded]
        case .f6x6: [.kicked, .square]
        case .f6x8: [.shouldered]
        default: [.square]
        }
    }

    /// The film this format runs on, as a stock's `gauges` names it: half
    /// frame and XPan are cameras for 135 film.
    var gauge: String { isPerforated ? "135" : "120" }

    /// The gate as the picture sees it at a turn: the film runs across at an
    /// even turn and down at an odd one, so the gate's width is its size
    /// along the film or across it.
    func gateSize(turn: Int) -> CGSize {
        turn % 2 == 0 ? CGSize(width: alongMM, height: acrossMM) : CGSize(width: acrossMM, height: alongMM)
    }

    /// Whether the engine runs the film **down** a frame of this shape: it
    /// reads the film's direction from the frame it is handed — along the
    /// image axis whose size is not the format's across-the-film size — and a
    /// square frame runs across (`overscan_layout`, and `FilmLayout`, which
    /// ports it). That is the engine's own quarter turn.
    func runsDown(frame: PixelSize) -> Bool {
        let w = Double(max(frame.width, 1)), h = Double(max(frame.height, 1))
        let px = max(alongMM, acrossMM) / max(w, h)                 // mm per pixel
        return abs(w * px - acrossMM) < abs(h * px - acrossMM) && abs(w - h) * px > 1e-6
    }

    /// The turn a picture of this shape is given first: the one whose gate
    /// lies the way the picture does. A landscape 135 frame runs across with
    /// its name on top (0°), an upright one runs down with the name on the
    /// right (90°); 645's gate is upright when the film runs across.
    func defaultTurn(pictureAspect: Double) -> Int {
        let across = gateSize(turn: 0)
        let gateIsWide = across.width > across.height
        let pictureIsWide = pictureAspect >= 1
        if abs(across.width - across.height) < 1e-6 { return 0 }
        return gateIsWide == pictureIsWide ? 0 : 1
    }

    /// Which date faces the engine draws on this format (`imprint_groups`):
    /// `lcd` and `dots` on 135 and half frame, `data` there and in 645's
    /// margin, nothing anywhere else — no back on those cameras printed one,
    /// and nothing on the panoramic formats (answer sheet C7). Anywhere else a
    /// date is silently not drawn, so the page must not offer it.
    func draws(_ face: DateBackFace) -> Bool {
        switch self {
        case .f135, .half: true
        case .f645: face == .data
        default: false
        }
    }
    var drawsAnyDate: Bool { DateBackFace.allCases.contains(where: draws) }

}

/// `overscan_mode`: the whole film width, or a filed-out carrier's sliver of rebate.
enum FilmEdgeView: String, CaseIterable, Identifiable, Codable, Sendable {
    case strip = "strip", filed = "filed"
    var id: String { rawValue }
    var label: String { self == .strip ? L("Strip") : L("Filed") }
}

/// `overscan_gate`: the gate's shape family. `auto` lets the camera seed pick
/// one this format's real cameras have.
enum FilmEdgeGate: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto", square = "square", rounded = "rounded", eared = "eared", shouldered = "shouldered",
        kicked = "kicked"
    var id: String { rawValue }
    var label: String { L(shown: rawValue.prefix(1).uppercased() + rawValue.dropFirst()) }
    /// The Edge step's chips, in the drawing's order.
    static let chips: [FilmEdgeGate] = [.auto, .square, .rounded, .eared, .kicked, .shouldered]
}

/// `overscan_holes`: what shows through the perforations — a scan's light, or
/// a black backing (a darkroom print of the strip).
enum FilmEdgeHoles: String, CaseIterable, Identifiable, Codable, Sendable {
    case white = "white", black = "black"
    var id: String { rawValue }
    var label: String { self == .white ? L("White") : L("Black") }
}

/// `overscan_perforation` (API-SPEC §21.3): the holes a 120 film carries. `ks65` is 120 cut from 65 mm
/// motion-picture film (the "65mm" film) whose KS perforations survive the slit and bite about 1.3 mm into the
/// picture on both long edges. With it the engine draws no 120 edge print on any stock (`FilmLayout` matches).
///
/// **The person's choice on any 120 film edge** (the owner, 2026-11-11, PRD-D §3.2 as rewritten): 齿孔 无 · 有,
/// None until chosen — but a Vision3 stock opens its 120 formats with it on (`starting(stockID:)`). On 135 and its
/// panoramic formats the engine refuses it, so the wire sends `none` there whatever is kept (`on(_:)`).
enum FilmEdgePerforation: String, CaseIterable, Codable, Identifiable, Sendable {
    case none = "none", ks65 = "ks65"
    var id: String { rawValue }

    var label: String { self == .none ? L("None", as: "perforations") : L("Keyhole", as: "perforations") }

    /// The motion-picture stocks known to be made in 65 mm and sold cut to 120 (the owner, 2026-11-09: "limit to
    /// 电影卷 first"): the ones `Stock.isMade` lets onto 120, and that open there with the keyholes on. Verita 200D
    /// is not known in 65 mm and stays 135-only; CineStill 800T is not a cine stock in the catalogue and keeps its
    /// own 120, unperforated.
    static var cine65Stocks: Set<String> { FilmFrame.cine65Stocks }

    /// What a 120 format starts with on this stock: the keyholes on a Vision3 film, none on any other.
    static func starting(stockID: String) -> FilmEdgePerforation { cine65Stocks.contains(stockID) ? .ks65 : .none }

    /// What the wire carries on `format`: the kept choice on 120, `none` elsewhere (the engine refuses `ks65` there).
    func on(_ format: FilmEdgeFormat) -> FilmEdgePerforation { format.is120 ? self : .none }

    /// **65mm**, the cine 120's name in the app, zh and en alike (the owner, 2026-11-11, PRD-D §6 q1: never the IMAX
    /// mark). The one place to change it: 格式's size card on a Vision3 stock and the Film step's line.
    static var filmName: String { FilmFrame.cine65Name }
}

/// **Film Edge** (overscan): the film outside the frame.
struct FilmEdgeSettings: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case active = "active", format = "format", mode = "mode", gate = "gate", holes = "holes", fog = "fog",
            leaks = "leaks", turn = "turn", cameraSeed = "cameraSeed", frameNumber = "frameNumber", framing = "framing",
            edgeBrightness = "edgeBrightness", perforation = "perforation"
    }
    var active = false
    var format = FilmEdgeFormat.f135
    /// The View the person chose; the page calls it View. Kept as chosen on every format, so it comes back when a
    /// format that draws one view (`FilmEdgeFormat.fixedView`) is left -- what is drawn is `view`.
    var mode = FilmEdgeView.strip
    var gate = FilmEdgeGate.auto
    var holes = FilmEdgeHoles.white
    var fog = 1.0                  // 0…4
    var leaks = 0.0                // 0…4
    /// Quarter turns of the film around the picture, clockwise (the Frame
    /// step's ↻): 0 across with the name on top, 1 down with it on the right,
    /// 2 across with it below, 3 down with it on the left.
    var turn = 0
    /// **The body**: gate, margins, where the frame sits on the perforations.
    /// 0 until this frame is given one — the host's own (`AppSettings.bodySeed`)
    /// the first time a film edge is put on it — and then kept with the edit,
    /// so the frame keeps its camera.
    var cameraSeed = 0
    /// The frame's number on the edge print: 1…99, or 0 for the frame seed's draw.
    var frameNumber = 0
    /// The picture in the gate: Film Edge's own framing, kept beside the
    /// photo's crop and never mixed with it (design/overscan §3). A crop at
    /// the gate's shape, straightened; nil is the largest cut about the middle.
    var framing: Geometry? = nil
    /// The edge print's brightness, kept in the edit's file so an edit that has it opens
    /// unchanged. The engine has no edge gain, so every film edge is printed at 1×, as the
    /// film was measured; the Edge Print ruler shows the value greyed (`FilmEdgeSteps`).
    var edgeBrightness = 1.0
    /// 齿孔 on a 120 film edge (`FilmEdgePerforation`): kept, and written only once it is not None, so an edit
    /// without it is the same JSON as before the field existed.
    var perforation = FilmEdgePerforation.none

    static let fogRange = 0.0...4.0
    static let leaksRange = 0.0...4.0
    /// The edge print's and the date's brightness: 1× (as it was) to 3×.
    static let brightnessRange = 1.0...3.0
    static let frameNumberRange = 0...99
    static let seedRange = 0...Int(Int32.max)
    /// A body's number reads as a serial plate: short.
    static let bodyRange = 1...999

    init() {}

    /// Every key optional, so an edit from before a field existed opens, and
    /// an unknown value (a newer build's format) falls back to the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilmEdgeSettings()
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? d.active
        format = (try? c.decodeIfPresent(FilmEdgeFormat.self, forKey: .format)) ?? d.format
        mode = (try? c.decodeIfPresent(FilmEdgeView.self, forKey: .mode)) ?? d.mode
        gate = (try? c.decodeIfPresent(FilmEdgeGate.self, forKey: .gate)) ?? d.gate
        holes = (try? c.decodeIfPresent(FilmEdgeHoles.self, forKey: .holes)) ?? d.holes
        fog = try c.decodeIfPresent(Double.self, forKey: .fog) ?? d.fog
        leaks = try c.decodeIfPresent(Double.self, forKey: .leaks) ?? d.leaks
        turn = try c.decodeIfPresent(Int.self, forKey: .turn) ?? d.turn
        cameraSeed = try c.decodeIfPresent(Int.self, forKey: .cameraSeed) ?? d.cameraSeed
        frameNumber = try c.decodeIfPresent(Int.self, forKey: .frameNumber) ?? d.frameNumber
        framing = try? c.decodeIfPresent(Geometry.self, forKey: .framing)
        edgeBrightness = try c.decodeIfPresent(Double.self, forKey: .edgeBrightness) ?? d.edgeBrightness
        perforation = (try? c.decodeIfPresent(FilmEdgePerforation.self, forKey: .perforation)) ?? d.perforation
    }

    /// As the synthesised encoding wrote it, and `perforation` only when it is not None.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(active, forKey: .active)
        try c.encode(format, forKey: .format)
        try c.encode(mode, forKey: .mode)
        try c.encode(gate, forKey: .gate)
        try c.encode(holes, forKey: .holes)
        try c.encode(fog, forKey: .fog)
        try c.encode(leaks, forKey: .leaks)
        try c.encode(turn, forKey: .turn)
        try c.encode(cameraSeed, forKey: .cameraSeed)
        try c.encode(frameNumber, forKey: .frameNumber)
        try c.encodeIfPresent(framing, forKey: .framing)
        try c.encode(edgeBrightness, forKey: .edgeBrightness)
        if perforation != .none { try c.encode(perforation, forKey: .perforation) }
    }

    /// A format card picked (the flow's and the column's `pick`): the format, and what it starts with — the
    /// holes 135 Full Width's strip has, and on coming onto 120 the keyholes a Vision3 stock opens with (between
    /// two 120 formats the choice is kept; off 120 it goes, the engine refusing it there).
    mutating func take(format new: FilmEdgeFormat, stockID: String) {
        let was120 = format.is120
        format = new
        if let h = new.startingHoles { holes = h }
        if !new.is120 { perforation = .none } else if !was120 { perforation = FilmEdgePerforation.starting(stockID: stockID) }
    }

    /// True when the engine draws the film.
    var effective: Bool { FeatureFlags.filmEdge && active }

    /// `overscan_mode`, the View drawn: the format's own where it has one (135 Full Width: Strip), else the kept
    /// `mode`. The wire, the layout, the price and the row's value read this, never `mode`.
    var view: FilmEdgeView { format.fixedView ?? mode }

    /// "135 · Strip · Square": the Frame tab's row. The gate is named as it
    /// was made — `Auto` says nothing about the picture.
    func rowValue(resolvedGate: FilmEdgeGate) -> String {
        "\(format.label) · \(view.label) · \(resolvedGate.label)"
    }

    /// "Film 90° · name on the right".
    var turnText: String { L("Film \(Self.turnDegrees(turn)) · \(Self.turnSays(turn))") }
    static func turnDegrees(_ turn: Int) -> String { "\(((turn % 4) + 4) % 4 * 90)°" }
    static func turnSays(_ turn: Int) -> String {
        [L("name on top"), L("name on the right"), L("name below"), L("name on the left")][((turn % 4) + 4) % 4]
    }

    /// About how large the film around a picture of this size is, without
    /// laying it out: the widest margins a body draws and the film's width,
    /// with nothing past it — a strip scan ends at the film's long edges (the
    /// engine's `overscan_carrier` = `none` since the desktop's 1.3.1). For
    /// pricing a develop before it runs (the desktop's `FilmCanvasEstimate`);
    /// the layout itself says the exact size. Held against `FilmLayout` on
    /// 2026-10-05 over 36,000 layouts (every format, both views, both ways
    /// up, 60 bodies, 5 frames, 3 sizes): never smaller than the layout's
    /// canvas on either side, and at most 6.1 % more pixels (645 as a strip;
    /// 1.1 % on 135).
    func canvasEstimate(picture: PixelSize) -> PixelSize {
        let w = Double(max(picture.width, 1)), h = Double(max(picture.height, 1))
        let px = max(format.alongMM, format.acrossMM) / max(w, h)             // mm per pixel
        let vertical = format.runsDown(frame: picture)
        let alongPx = vertical ? h : w
        let marginMM: Double, acrossMM: Double
        switch view {
        case .strip:
            marginMM = format == .half ? 0.5 : (format.isPerforated ? 0.95 : 2.35)
            // The film's width (120's is cut to ±0.15) and nothing past it.
            acrossMM = format.filmWidthMM + (format.isPerforated ? 0 : 0.15)
        case .filed:
            marginMM = 1.0
            acrossMM = (vertical ? w : h) * px + 2.2
        }
        let along = Int(alongPx + 2 * (marginMM / px).rounded())
        // Never under the picture across the film: 135 Full Width's gate (36 mm) is wider than its film (35), so
        // its canvas is narrower than the frame it is handed, and a develop priced at the canvas alone refused its
        // own decode ("decoded 1920x960 exceeds the priced open 1970x933", the integration build, 2026-11-11).
        let across = max(Int((acrossMM / px).rounded()), vertical ? picture.width : picture.height)
        return vertical ? PixelSize(width: across, height: along) : PixelSize(width: along, height: across)
    }

    /// The quarter turns, clockwise, the host gives the engine's canvas so the
    /// film stands at `turn` round a picture cut to this shape. The engine has
    /// two directions of its own, read from the frame — across (0) and down
    /// (1) — and the other two are the same film turned half round: the host
    /// hands the picture over turned back by this much and turns the canvas
    /// forward by it afterwards (design/overscan §8.1; there is no
    /// `overscan_turn` on the wire). `FilmLayout`'s `extraTurns` is this
    /// number, and the parity check holds the two together.
    func hostTurns(cut: PixelSize) -> Int {
        let own = format.runsDown(frame: cut) ? 1 : 0
        return (((turn - own) % 4) + 4) % 4
    }

    /// `overscan_active` always, so turning it off reaches the engine; the
    /// rest only while it is on (off is structural: nothing is dispatched).
    ///
    /// The engine takes the frame it is handed as the gate, so the host cuts
    /// the picture with `framing` first; and it reads the film's direction
    /// from the frame's shape, which gives it turns 0° and 90°. The other two
    /// are the same film turned half round: the host turns the picture before
    /// the call and the canvas back after it, until the wire has `overscan_turn`
    /// (design/overscan §8.1).
    ///
    /// **API-SPEC §21** (§21.3, §21.4): `overscan_falloff` (0 on every format, `FilmEdgeFormat.falloff`) and
    /// `overscan_perforation` (the kept choice on 120, `none` elsewhere) are sent every time the film edge is on —
    /// so going back to 0 and `none` reaches an open session — **on an engine that knows them**: one that does
    /// not refuses a whole open over a name it does not know, and has neither 135 Full Width nor keyholes to
    /// draw. When the film edge goes off they go back to their rest (`FilmParams.sometimesSent`).
    func wire(edgeText: String, frameSeed: Int, fNumber: Double) -> [(name: String, value: ParamValue, layer: ParamLayer)] {
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
            // Display names only: the host chooses what the edge prints.
            ("overscan_edge_text", .string(edgeText), .shoot),
            ("overscan_f_number", .double(fNumber.clamped(to: 0...64)), .shoot),
        ]
        if EngineFeatures.knows(.fullWidth135) {
            fields.append(("overscan_falloff", .double(format.falloff), .shoot))
        }
        if EngineFeatures.knows(.keyholes) {
            fields.append(("overscan_perforation", .string(perforation.on(format).rawValue), .shoot))
        }
        return fields
    }
}

// MARK: - the date back

/// The date back's three faces of one mechanism. Raw value: `date_imprint_style`.
enum DateBackFace: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Seven segments, slanted: the quartz date back.
    case lcd = "lcd"
    /// A dot-matrix date, upright.
    case dots = "dots"
    /// Shooting data in a 5 × 7 face, between frames (135) or in the margin (645).
    case data = "data"
    /// **孔间数据 Perforation Data** (API-SPEC §21.2; PRD-D §3.2b, 2026-11-11): the shooting data one field
    /// per gap between the perforations along the camera's top edge — mode, metering, shutter, aperture,
    /// compensation, from the file's EXIF (`PerforationLine`). On the wire it is the `data` style with
    /// `date_imprint_data_placement = perfs`. Needs a film edge on a perforated 135 format (135, Half); a date in
    /// the frame beside it is not offered, nor the roll's leader. Offered on an engine that has it
    /// (`EngineFeatures.ledGlow`, whose field is the placement). The raw value is the edit's word, not the wire's.
    case perfs = "perfs"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lcd: "LCD"
        case .dots: L("Dots")
        case .data: L("Data")
        case .perfs: L("Perforation Data")
        }
    }

    /// `date_imprint_style`: Perforation Data is the data style placed between the holes.
    var wireStyle: String { self == .perfs ? DateBackFace.data.rawValue : rawValue }

    /// The faces a date back has had since 1.x: what a half-frame pair's panels offer (Perforation Data is a single
    /// frame's).
    static let dateFaces: [DateBackFace] = [.lcd, .dots, .data]

    /// The faces a single frame's pages offer: Perforation Data only on an engine that draws it.
    static var offered: [DateBackFace] { allCases.filter { $0 != .perfs || EngineFeatures.offers(.ledGlow) } }
}

/// Raw value: `date_imprint_placement`. `between` is the wire's `rebate`.
enum DateBackPlacement: String, CaseIterable, Identifiable, Codable, Sendable {
    case frame = "frame", between = "rebate"
    var id: String { rawValue }
}

/// The corner of the *film's* frame, as the camera's back sees it held level:
/// turn the camera and the date turns with it.
enum DateBackCorner: String, CaseIterable, Identifiable, Codable, Sendable {
    case br = "br", bl = "bl", tr = "tr", tl = "tl"
    var id: String { rawValue }
    var isRight: Bool { self == .br || self == .tr }
    var isBottom: Bool { self == .br || self == .bl }
    var says: String {
        switch self {
        case .br: L("bottom right")
        case .bl: L("bottom left")
        case .tr: L("top right")
        case .tl: L("top left")
        }
    }
}

/// The order the date is written in (answer sheet E1: US and Japan first).
/// The engine takes the text already formatted.
enum DateBackOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Month, day, year: `10 1 '26`.
    case us = "us"
    /// Year, month, day: `'26 10 1`.
    case japan = "japan"
    var id: String { rawValue }
}

/// The **Date Back**: a date exposed onto the negative from behind, so it
/// develops, halates and grains with the picture.
struct DateBackSettings: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case active = "active", style = "style", order = "order", placement = "placement", corner = "corner",
            insetXMM = "insetXMM", insetYMM = "insetYMM", size = "size", brightnessEV = "brightnessEV",
            customText = "customText", alsoData = "alsoData", brightness = "brightness"
    }
    var active = false
    /// `date_imprint_style`; the page calls it the face.
    var style = DateBackFace.lcd
    var order = DateBackOrder.japan
    var placement = DateBackPlacement.frame
    var corner = DateBackCorner.br
    var insetXMM = 3.0             // 0…30
    var insetYMM = 2.4             // 0…30
    var size = 1.0                 // 0.4…3
    /// 5.5 since 2026-11-11 (PRD-D §6 q2, the owner: yes): the engine lights every date as an LED through the base,
    /// and its base is 5.5; an edit that kept 1.x's 3.5 reads it as 5.5 (`init(from:)`), so every old date looks
    /// like a new one.
    var brightnessEV = DateBackSettings.glowBaseEV   // −2…8
    /// The user's own text, which wins over the frame's date when set.
    var customText: String? = nil
    /// **The data line as well as the date** (the owner, 2026-10-20: "data and
    /// two date back dates should be able to be printed together"): with a
    /// date face (LCD or Dots) the frame's shutter and aperture print between
    /// frames too, as the engine has done since 1.3.1 (`date_imprint_data_text`).
    /// The *Data* face alone is `style` = `.data`, as before; this is never
    /// read under it. Off in every edit before it.
    var alsoData = false
    /// **The date's brightness**, 1× (its 3.5 EV, as every edit before it) to
    /// 3× the light: on the wire it is `log2` of it added to `brightnessEV`,
    /// and 1× adds exactly nothing. The data line is lit by the same lamp.
    var brightness = 1.0

    static let insetRange = 0.0...30.0
    static let sizeRange = 0.4...3.0
    static let brightnessRange = -2.0...8.0
    /// `data` between half frames has only the 1 mm gap (answer sheet B19).
    static let halfFrameDataSizeMax = 1.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DateBackSettings()
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? d.active
        style = (try? c.decodeIfPresent(DateBackFace.self, forKey: .style)) ?? d.style
        order = (try? c.decodeIfPresent(DateBackOrder.self, forKey: .order)) ?? d.order
        placement = (try? c.decodeIfPresent(DateBackPlacement.self, forKey: .placement)) ?? d.placement
        corner = (try? c.decodeIfPresent(DateBackCorner.self, forKey: .corner)) ?? d.corner
        insetXMM = try c.decodeIfPresent(Double.self, forKey: .insetXMM) ?? d.insetXMM
        insetYMM = try c.decodeIfPresent(Double.self, forKey: .insetYMM) ?? d.insetYMM
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        // The base every edit kept before the LED glow, 3.5, is the glow's 5.5 (PRD-D §6 q2): read so, never kept apart.
        let stored = try c.decodeIfPresent(Double.self, forKey: .brightnessEV) ?? d.brightnessEV
        brightnessEV = abs(stored - Self.storedBaseEV) < 1e-9 ? Self.glowBaseEV : stored
        customText = try c.decodeIfPresent(String.self, forKey: .customText)
        alsoData = try c.decodeIfPresent(Bool.self, forKey: .alsoData) ?? d.alsoData
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
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

    static func dateText(_ date: Date, order: DateBackOrder, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return format(year: p.year ?? 2026, month: p.month ?? 1, day: p.day ?? 1, order: order)
    }

    /// The camera that prints: the film edge's format while it is on;
    /// otherwise a 135 body, the only bare frame a date back printed on.
    func camera(filmEdge: FilmEdgeSettings) -> FilmEdgeFormat {
        filmEdge.effective ? filmEdge.format : .f135
    }

    /// Whether `face` has somewhere to print: a face the camera carries, and
    /// for the data face a film edge, because it goes between frames (135) or
    /// in the margin (645) and neither exists on the bare picture.
    func prints(_ face: DateBackFace, filmEdge: FilmEdgeSettings) -> Bool {
        guard camera(filmEdge: filmEdge).draws(face) else { return false }
        // Between frames and between the holes both need the film; the holes, an engine that draws the line there.
        if face == .perfs { return filmEdge.effective && EngineFeatures.knows(.ledGlow) }
        return face == .data ? filmEdge.effective : true
    }

    /// Why a face cannot be chosen, for the page to say; nil when it can.
    func reason(_ face: DateBackFace, filmEdge: FilmEdgeSettings) -> String? {
        let camera = camera(filmEdge: filmEdge)
        if !camera.draws(face) {
            return camera.drawsAnyDate ? L("No \(camera.label) back printed this face.")
                                       : L("No \(camera.label) camera's back printed a date.")
        }
        if face == .data && !filmEdge.effective { return L("Data prints between frames: it needs Film Edge.") }
        if face == .perfs && !filmEdge.effective { return L("Perforation Data prints between the holes: it needs Film Edge.") }
        return nil
    }

    /// True when the engine draws a date: the switch, a face with somewhere
    /// to print, and — between frames — a film edge to print it on.
    func effective(filmEdge: FilmEdgeSettings) -> Bool {
        guard FeatureFlags.dateBack, active, prints(style, filmEdge: filmEdge) else { return false }
        return style == .data || style == .perfs || placement == .frame || filmEdge.effective
    }

    /// Whether the data line prints beside a date face: asked for, a date face
    /// (under *Data* the data is the date's own text), and somewhere for it —
    /// between frames, so a film edge on a camera whose back printed data.
    func printsDataLine(filmEdge: FilmEdgeSettings) -> Bool {
        alsoData && style != .data && style != .perfs && prints(.data, filmEdge: filmEdge)
    }

    /// Whether a face's card is lit: the date faces one at a time, Data
    /// beside either of them or by itself.
    func shows(_ face: DateBackFace) -> Bool {
        switch face {
        case .data: style == .data || (alsoData && style != .perfs)
        default: style == face
        }
    }

    /// A face's card tapped ("Data an independent switch alongside the date
    /// face": date only, data only, or both). A date face takes the date's
    /// place and keeps the data line; tapped while the data is alone, it
    /// joins it. *Data* turns its line on or off beside a date face, and
    /// alone takes the date back to the face it can (it is never left with
    /// nothing: the switch above turns the whole back off).
    mutating func tap(_ face: DateBackFace) {
        switch face {
        case .perfs:
            // Its own line, alone: a date in the frame beside it is not offered.
            style = .perfs
            alsoData = false
        case .data:
            if style == .data { return }
            if style == .perfs { style = .data; return }
            alsoData.toggle()
        case .lcd, .dots:
            if style == .perfs { style = face }
            else if style == .data { style = face; alsoData = true }
            else if style == face, alsoData { style = .data; alsoData = false }
            else { style = face }
        }
    }

    /// The light on the wire: the date's own EV with its brightness's stops added.
    var wireEV: Double {
        (brightnessEV + log2(brightness.clamped(to: FilmEdgeSettings.brightnessRange))).clamped(to: Self.brightnessRange)
    }

    /// The date's base before the LED glow (1.x … 2.3.2), and the glow's (API-SPEC §21.2). The one place to change them.
    static let storedBaseEV = 3.5
    static let glowBaseEV = 5.5

    /// The size the wire carries: capped where the face has no room. The data
    /// line between half frames has only the 1 mm gap, and the engine sizes
    /// the date and the data line together, so the cap holds for both.
    func wireSize(on format: FilmEdgeFormat, dataLine: Bool = false) -> Double {
        let s = size.clamped(to: Self.sizeRange)
        return (style == .data || dataLine) && format == .half ? min(s, Self.halfFrameDataSizeMax) : s
    }

    /// "LCD · ’26 10 1": the Frame tab's row.
    /// "LCD + Data · ’26 10 1" when the data line prints beside the date.
    func rowValue(text: String) -> String {
        let face = alsoData && style != .data && style != .perfs ? style.label + " + " + DateBackFace.data.label : style.label
        return "\(face) · " + text.replacingOccurrences(of: "'", with: "’")
    }

    /// `date_imprint_active` always; the rest only while it is on. The
    /// camera's format rides on `overscan_format` even with the film edge
    /// off, because the engine reads the film's direction from it.
    /// `dataText` is the frame's data line (`ShootingLine.dataText`), sent
    /// only while it prints beside a date face; "" otherwise, and always
    /// sent while the back is on, so taking the line off reaches the engine.
    func wire(text: String, filmEdge: FilmEdgeSettings, dataText: String = "") -> [(name: String, value: ParamValue, layer: ParamLayer)] {
        let on = effective(filmEdge: filmEdge) && !(customText ?? text).isEmpty
        var fields: [(name: String, value: ParamValue, layer: ParamLayer)] = [
            ("date_imprint_active", .bool(on), .shoot),
        ]
        guard on else { return fields }
        let camera = camera(filmEdge: filmEdge)
        let dataLine = printsDataLine(filmEdge: filmEdge) && !dataText.isEmpty
        if !filmEdge.effective {
            fields.append(("overscan_format", .string(camera.rawValue), .shoot))
        }
        fields += [
            ("date_imprint_style", .string(style.wireStyle), .shoot),
            ("date_imprint_text", .string(customText ?? text), .shoot),
            ("date_imprint_placement", .string(placement.rawValue), .shoot),
            ("date_imprint_corner", .string(corner.rawValue), .shoot),
            ("date_imprint_inset_x", .double(insetXMM.clamped(to: Self.insetRange)), .shoot),
            ("date_imprint_inset_y", .double(insetYMM.clamped(to: Self.insetRange)), .shoot),
            ("date_imprint_size", .double(wireSize(on: camera, dataLine: dataLine)), .shoot),
            ("date_imprint_ev", .double(wireEV), .shoot),
            ("date_imprint_data_text", .string(dataLine ? dataText : ""), .shoot),
        ]
        // Perforation Data: the data line between the holes (API-SPEC §21.2). Sent only then; `gap` is the rest it goes
        // back to (`FilmParams.sometimesSent`), so no engine without the field is ever named it. No leader.
        if style == .perfs { fields.append(("date_imprint_data_placement", .string("perfs"), .shoot)) }
        return fields
    }
}
