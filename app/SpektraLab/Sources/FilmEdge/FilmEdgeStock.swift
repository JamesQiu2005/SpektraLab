//  FilmEdgeStock.swift — what a stock's own film edge carries.
//
//  The engine prints each stock's edge from its own table (`kEdgeLooks`,
//  `dx_extract_for`; `engine/src/pipeline/overscan.cpp`, measured on the
//  owner's strips 2026-10-03): which layout, whether there is a DX code and
//  which number it carries. The table below is that table, by profile id, so
//  the page can say what a film's edge has before it is developed — and say
//  the same thing the develop then shows. A stock not listed takes Kodak's
//  layout and prints no bars, as it does in the engine.
//
//  **Names.** The engine is handed the edge's words by the host
//  (`overscan_edge_text`): the film's own words where it prints something
//  other than its name (`EdgeWords`: `KODAK GB 200-7`, `FUJI RDPIII`,
//  `EASTMAN 5219`…, 135 and 120 apart), else its name in capitals. The engine
//  draws no maker's name of its own: the maker's mark that Fujifilm's 120
//  layout prints apart, before every even frame number, is the first word of
//  the host's text. Two things on a film edge are not the host's: the DX bars,
//  which encode the stock's DX number, and the code `EFCDCD` that the engine
//  prints after the name on Pro 400H's 120 edge. Both are shown here as the
//  engine renders them.

import SwiftUI

/// What the manufacturer printed on the rebate of 135 film.
enum Edge135: Sendable {
    /// DX bars, Helvetica, the name on the top band, `N` / `NA` and an arrow below.
    case kodak
    /// No bars; Fujifilm's dot faces, bold numbers on both bands, `36 ⇨ 12A`.
    case fujiSlide
    /// 14.1 mm DX bars, numbers in Fujifilm's dots on both bands.
    case fujiNeg
    /// One line beside the bottom perforations, dashes, no bars, no numbers.
    case cine
    /// Kodak's two bands turned half a turn: 13.06 mm DX bars and the numbers
    /// along the top band, the name in a square 5 × 7 face reading upside down
    /// along the bottom one (HP5 Plus).
    case ilford
}

/// What the manufacturer printed on the rebate of 120 film.
enum Edge120: Sendable {
    /// Numbers and the name on one edge, triangles and digits on the other.
    case kodak
    /// One edge only, in 5 × 7 dots: the maker's mark (the host's first word),
    /// the number, a tack, the name.
    case fuji
}

struct EdgeLook: Sendable {
    let k135: Edge135
    let k120: Edge120
    /// Kodak layout: regular-weight numbers and name tail (C200).
    var lightNumbers = false
    /// Fujifilm 120: the code after the stock name (`EFCDCD` on Pro 400H).
    var code = ""
    /// The DX number (part 1 × 16 + part 2), or nil: no bars.
    var dx: Int? = nil
    /// The marks' colour as a print shows them, 135 and 120: the references'
    /// (R, G, B) against their own rebate, normalised to the largest. Hue
    /// only — the engine exposes the marks through the film, it does not paint
    /// them, so this is for the picture a build without the engine draws.
    var ink135: (Double, Double, Double) = (1, 0.80, 0.50)
    var ink120: (Double, Double, Double) = (1, 0.80, 0.55)

    static let fallback = EdgeLook(k135: .kodak, k120: .kodak)

    static let table: [String: EdgeLook] = [
        "kodak_gold_200": EdgeLook(k135: .kodak, k120: .kodak, dx: 1548, ink120: (1, 0.83, 0.68)),
        "kodak_portra_160": EdgeLook(k135: .kodak, k120: .kodak, dx: 1534, ink135: (1, 0.82, 0.43)),
        "kodak_portra_400": EdgeLook(k135: .kodak, k120: .kodak, dx: 1277, ink120: (1, 0.83, 0.60)),
        "kodak_portra_800": EdgeLook(k135: .kodak, k120: .kodak, dx: 1278, ink135: (1, 0.74, 0.35)),
        "kodak_portra_800_push1": EdgeLook(k135: .kodak, k120: .kodak, dx: 1278, ink135: (1, 0.74, 0.35)),
        "kodak_portra_800_push2": EdgeLook(k135: .kodak, k120: .kodak, dx: 1278, ink135: (1, 0.74, 0.35)),
        "kodak_ultramax_400": EdgeLook(k135: .kodak, k120: .kodak, dx: 1313, ink135: (1, 0.80, 0.57)),
        "kodak_ektar_100": EdgeLook(k135: .kodak, k120: .kodak, dx: 1307, ink120: (1, 0.77, 0.46)),
        "kodak_ektachrome_100": EdgeLook(k135: .kodak, k120: .kodak, dx: 382,
                                         ink135: (1, 0.95, 0.92), ink120: (1, 0.95, 0.92)),
        "fujifilm_c200": EdgeLook(k135: .kodak, k120: .kodak, lightNumbers: true, dx: 1550, ink135: (1, 0.77, 0.51)),
        "fujifilm_xtra_400": EdgeLook(k135: .fujiNeg, k120: .fuji, dx: 628,
                                      ink135: (1, 0.95, 0.57), ink120: (1, 0.95, 0.57)),
        "fujifilm_pro_400h": EdgeLook(k135: .fujiNeg, k120: .fuji, code: "EFCDCD", dx: 584,
                                      ink135: (1, 0.78, 0.21), ink120: (1, 0.78, 0.21)),
        // The slides carry a DX number in the table and print no bars: the
        // slide layout has none (`dx` is read only for Kodak's and X-Tra's).
        "fujifilm_provia_100f": EdgeLook(k135: .fujiSlide, k120: .fuji, dx: 557,
                                         ink135: (1, 0.80, 0.32), ink120: (1, 0.65, 0.25)),
        "fujifilm_velvia_100": EdgeLook(k135: .fujiSlide, k120: .fuji, dx: 523,
                                        ink135: (1, 0.89, 0.41), ink120: (1, 0.62, 0.18)),
        // The black-and-white films (the engine's rows of 2026-10-09). One
        // emulsion, so the printer's light is the same in every layer and the
        // marks are grey. Tri-X prints in the regular weight, as C200 does;
        // neither Kodak film carries bars on 135 (none on the strips, and no
        // row in the engine's DX table). Acros II takes the slides' 135 layout
        // and Fujifilm's 120; HP5 Plus has a layout of its own on 135, with
        // the bars, and Kodak's on 120.
        "kodak_tri_x_400": EdgeLook(k135: .kodak, k120: .kodak, lightNumbers: true, ink135: (1, 1, 1), ink120: (1, 1, 1)),
        "kodak_tmax_100": EdgeLook(k135: .kodak, k120: .kodak, ink135: (1, 1, 1), ink120: (1, 1, 1)),
        "fujifilm_neopan_acros_100_ii": EdgeLook(k135: .fujiSlide, k120: .fuji, ink135: (1, 1, 1), ink120: (1, 1, 1)),
        "ilford_hp5_plus_400": EdgeLook(k135: .ilford, k120: .kodak, dx: 1753, ink135: (1, 1, 1), ink120: (1, 1, 1)),
        "kodak_vision3_250d": EdgeLook(k135: .cine, k120: .kodak, ink135: (0.86, 0.86, 1), ink120: (0.86, 0.86, 1)),
        "kodak_vision3_50d": EdgeLook(k135: .cine, k120: .kodak, ink135: (0.86, 0.86, 1), ink120: (0.86, 0.86, 1)),
        "kodak_vision3_200t": EdgeLook(k135: .cine, k120: .kodak, ink135: (0.86, 0.86, 1), ink120: (0.86, 0.86, 1)),
        "kodak_vision3_500t": EdgeLook(k135: .cine, k120: .kodak, ink135: (0.86, 0.86, 1), ink120: (0.86, 0.86, 1)),
        // CineStill 800T: the engine draws its own
        // layout (`Edge135::CineStill`, `Edge120::CineStill`: the name alone, no bars); the page's
        // nearest is Kodak's without a DX number, in the engine's orange (1, .45, 0).
        "cinestill_800t": EdgeLook(k135: .kodak, k120: .kodak, ink135: (1, 0.45, 0), ink120: (1, 0.45, 0)),
    ]

    static func of(_ stockID: String) -> EdgeLook { table[stockID] ?? fallback }

    /// Whether this stock's edge carries DX bars on a format: 135 film only,
    /// on Kodak's layout, Fujifilm's negative one and Ilford's, for a stock
    /// with a number.
    func hasDX(on format: FilmEdgeFormat) -> Bool {
        format.isPerforated && dx != nil && (k135 == .kodak || k135 == .fujiNeg || k135 == .ilford)
    }

    /// The code's length, its 31 modules, in millimetres: 12.64–12.78 on
    /// Kodak-made film, 14.1 on X-Tra 400, 13.06 on HP5 Plus.
    var dxLengthMM: Double { k135 == .fujiNeg ? 14.1 : (k135 == .ilford ? 13.06 : 12.7) }

    /// Ilford's bars lie along the top band and read with the film turned half
    /// a turn; everyone else's lie along the bottom one.
    var dxTurned: Bool { k135 == .ilford }

    /// The DX number the bars carry on a format, or nil: no bars.
    func dxNumber(on format: FilmEdgeFormat) -> Int? { hasDX(on: format) ? dx : nil }

    /// Whether the name lies along the far band of a format's film — the one
    /// the layout's `t` runs toward — and not the near one, where Kodak and
    /// Fujifilm print it: Ilford's 135 print, turned half a turn, and the cine
    /// line beside the bottom perforations. Never on 120.
    func nameOnFarBand(on format: FilmEdgeFormat) -> Bool {
        format.isPerforated && (k135 == .ilford || k135 == .cine)
    }

    func ink(on format: FilmEdgeFormat) -> Color {
        let c = format.isPerforated ? ink135 : ink120
        // The print's white is about 200 of 255 on the references.
        return Color(.sRGB, red: c.0 * 0.86, green: c.1 * 0.86, blue: c.2 * 0.86, opacity: 1)
    }
}

/// The gauges the manufacturer made a stock in, ever (the desktop's sourced
/// table, `Tools/gen-catalog.py`). A stock with no record is not ruled out of
/// anything: an unknown is not a no.
enum StockGauges {
    static let table: [String: [String]] = [
        "fujifilm_c200": ["135"],
        "fujifilm_pro_400h": ["135", "120"],
        "fujifilm_provia_100f": ["135", "120"],
        "fujifilm_velvia_100": ["135", "120"],
        "fujifilm_xtra_400": ["135", "120"],
        "kodak_ektachrome_100": ["135", "120"],
        "kodak_ektar_100": ["135", "120"],
        "kodak_gold_200": ["135", "120"],
        "kodak_kodachrome_64": ["135", "120"],
        "kodak_portra_160": ["135", "120"],
        "kodak_portra_400": ["135", "120"],
        "kodak_portra_800": ["135", "120"],
        "kodak_portra_800_push1": ["135", "120"],
        "kodak_portra_800_push2": ["135", "120"],
        "kodak_ultramax_400": ["135"],
        // The black-and-white films: the engine's rows name a 135 and a 120
        // strip of Tri-X and of T-Max 100; Acros II and HP5 Plus are made in
        // both, and their 120 edge has no reference there (unverified).
        "kodak_tri_x_400": ["135", "120"],
        "kodak_tmax_100": ["135", "120"],
        "fujifilm_neopan_acros_100_ii": ["135", "120"],
        "ilford_hp5_plus_400": ["135", "120"],
        "cinestill_800t": ["135", "120"],
    ]
}

/// The film's own words for the edge print where it prints something other
/// than its name: (135, 120). The desktop's (`filmify` 1.3.3,
/// `Session+FilmEdge.swift`), read off real strips. On the Fujifilm layouts the
/// first word is the maker's mark, and a closing `II` standing as a word is one
/// cell of the names' face. A stock not listed prints its name in capitals.
enum EdgeWords {
    static let table: [String: (k135: String, k120: String)] = [
        "kodak_gold_200": ("KODAK GB 200-7", "KODAK 200"),
        "kodak_portra_800": ("KODAK PORTRA 800-3", "KODAK PORTRA 800"),
        "kodak_portra_800_push1": ("KODAK PORTRA 800-3", "KODAK PORTRA 800"),
        "kodak_portra_800_push2": ("KODAK PORTRA 800-3", "KODAK PORTRA 800"),
        "kodak_ultramax_400": ("KODAK GC 400", "KODAK GC 400"),
        "kodak_ektachrome_100": ("KODAK E100", "KODAK E100"),
        "fujifilm_c200": ("FUJI 200", "FUJI 200"),
        "fujifilm_xtra_400": ("S-400", "FUJI S-400"),
        "fujifilm_pro_400h": ("PRO400H", "FUJI PRO400H"),
        "fujifilm_provia_100f": ("FUJI RDPIII", "FUJI RDPIII"),
        "fujifilm_velvia_100": ("RVP100", "FUJI RVP100"),
        "kodak_vision3_50d": ("EASTMAN 5203", "EASTMAN 5203"),
        "kodak_vision3_250d": ("EASTMAN 5207", "EASTMAN 5207"),
        "kodak_vision3_200t": ("EASTMAN 5213", "EASTMAN 5213"),
        "kodak_vision3_500t": ("EASTMAN 5219", "EASTMAN 5219"),
        "kodak_tri_x_400": ("KODAK 400TX", "KODAK 400TX"),
        "kodak_tmax_100": ("KODAK 100TMX", "KODAK 100TMX"),
        "fujifilm_neopan_acros_100_ii": ("FUJI 100 ACROS II", "FUJI 100 ACROS II"),
        "ilford_hp5_plus_400": ("ILFORD HP5 PLUS", "ILFORD HP5 PLUS"),
    ]
}

extension FilmEdgeSettings {
    /// "Film 90° · name on the right", for the film that is loaded: where the
    /// turn puts the band its name is printed on. `turnText` says it for a
    /// name on the near band; a film that prints it on the far one (HB5 Plus
    /// on 135, cine) has it on the other side of the picture.
    func turnText(stockID: String) -> String {
        let far = EdgeLook.of(stockID).nameOnFarBand(on: format)
        return L("Film \(Self.turnDegrees(turn)) · \(Self.turnSays(turn + (far ? 2 : 0)))")
    }
}

extension Stock {
    /// The words the film's edge prints: the film's own (`EdgeWords`), or else
    /// its name in capitals, the way a film carries its name. A push is a
    /// processing choice, not another film, so `(Push 1)` is not printed.
    var edgeText: String { edgeText(gauge: "135") }

    /// The same, for a film of this gauge: Gold 200 is "KODAK GB 200-7" on 135
    /// and "KODAK 200" on 120.
    func edgeText(gauge: String) -> String {
        if let own = EdgeWords.table[id] { return gauge == "120" ? own.k120 : own.k135 }
        var words = name
        if let open = words.firstIndex(of: "(") { words = String(words[..<open]) }
        return words.trimmingCharacters(in: .whitespaces).uppercased()
    }

    var edgeLook: EdgeLook { EdgeLook.of(id) }

    /// Whether this stock was ever made on the film a format runs on. Cine
    /// negative is the same film as 135, loaded into cassettes by hand, so it
    /// is not ruled out of the 135 formats; it carries no DX code.
    func isMade(in format: FilmEdgeFormat) -> Bool {
        if isCine { return format.gauge == "135" }
        guard let gauges = StockGauges.table[id] else { return true }
        return gauges.contains(format.gauge)
    }

    /// "Gold 200: 135 and 120" — the Film step's line beside *Format*.
    var madeInText: String {
        let gauges = isCine ? ["135"] : (StockGauges.table[id] ?? ["135", "120"])
        return "\(shortName): " + gauges.joined(separator: L(" and "))
    }
}
