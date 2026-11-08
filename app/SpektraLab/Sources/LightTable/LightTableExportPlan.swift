//  LightTableExportPlan.swift — what an export of the light table is, in pixels, before anything is drawn.
//
//  The table's Share offers two pictures (the owner, 2026-10-17: "allow the user to choose different
//  exports"):
//
//  - **Poster** (海报): today's share picture, the website's `share.js` layout — the table on the white
//    desk, the mark and a code to spektralab.app under it — at 2,400 px on its long side, a JPG.
//    Fixed: nothing on it is chosen. A landscape table has a poster of its own, wide, with the mark
//    and the code in a column at its right (`Poster`); A5 and A6 are composed as A4 is.
//  - **Contact Sheet** (印样): the table itself at a size a person chooses, for work:
//      - *With Light Table* (含观片台): the table with its aluminium rim and lit pad, nothing round it
//        but a soft shadow, the way macOS draws a window's (falling to fully transparent at the
//        file's edges). Always PNG: a JPG has no transparency.
//      - *Layout Only* (仅版面): the sheet alone (A4, A5 or A6, either way up), flat and sharp
//        edged, with the printed scale and the films, no rim, no lamp, no gloss, nothing round it.
//        JPG or PNG, opaque.
//    The size is the short edge **of the table or the sheet** (not of the file): 2,000 px unless
//    changed, 1,000 to 5,000 in steps of 100, the same for every size and either way up. The long
//    edge follows the table's shape (the paper and its rim); the shadow's margin is added round
//    the table, so a With Light Table file is larger than the number chosen.
//
//  **Drawn in bands, written as drawn** (`LightTableExport`): a 5,000 px sheet with its shadow is
//  about 6,200 × 8,300 pixels, 200 MB as one RGBA buffer. It is never held whole: the file's rows
//  are handed to ImageIO a band at a time (1,024 rows), each band drawn as tiles at most 2,048 px
//  wide; a film's picture is read when the first band it touches is drawn and let go of after its
//  last. This file is the arithmetic of all that — sizes, the shadow's margin, the tiles, which
//  film each band needs and the textures' budget — with no UIKit and no GPU, so
//  `tools/lighttable_export_selftest.swift` holds it on a Mac.

import CoreGraphics
import Foundation

enum LightTableExportKind: String, CaseIterable, Sendable {
    case poster = "poster"
    case contactSheet = "contactSheet"
}

enum LightTableExportStyle: String, CaseIterable, Sendable {
    /// The table with its rim, on nothing, with a window's shadow.
    case withTable = "withTable"
    /// The sheet alone, flat.
    case layoutOnly = "layoutOnly"
}

enum LightTableExportFormat: String, CaseIterable, Sendable {
    case png = "png"
    case jpg = "jpg"

    var fileExtension: String { rawValue }
    var title: String { rawValue.uppercased() }
}

/// What the Share sheet asks for.
struct LightTableExportChoice: Equatable, Sendable {
    var kind = LightTableExportKind.poster
    var style = LightTableExportStyle.withTable
    /// The format chosen for Layout Only; With Light Table is PNG whatever this says.
    var format = LightTableExportFormat.jpg
    /// The table's (or the sheet's) short edge, pixels.
    var shortEdge = LightTableExportPlan.defaultShortEdge

    /// The format the file is written in: Poster's JPG; With Light Table's PNG; Layout Only's choice.
    var fileFormat: LightTableExportFormat {
        switch kind {
        case .poster: .jpg
        case .contactSheet: style == .withTable ? .png : format
        }
    }
}

enum LightTableExportPlan {
    // MARK: the size

    static let defaultShortEdge = 2000
    static let shortEdges = 1000...5000
    static let shortEdgeStep = 100

    /// A short edge as the sheet can take it: inside the range, on a step.
    static func clampShortEdge(_ v: Int) -> Int {
        let stepped = Int((Double(v) / Double(shortEdgeStep)).rounded()) * shortEdgeStep
        return min(max(stepped, shortEdges.lowerBound), shortEdges.upperBound)
    }

    // MARK: the poster (`LightTableShare`, the website's `share.js`)

    /// The poster's millimetres round the table's frame at A4: `MARGIN`, `GAP`, `ROW`, `FOOT`; and
    /// the width of the landscape poster's column, which holds what the portrait poster's row does.
    static let posterMargin = 14.0, posterGap = 12.0, posterRow = 30.0, posterFoot = 14.0, posterColumn = 40.0
    /// Pixels along the poster's long side (`LONG`).
    static let posterLong = 2400.0

    /// The poster laid out in millimetres, before it is drawn (`LightTableShare.poster`).
    ///
    /// - **A portrait table** is `share.js`' poster: the table, and under it a row with the mark at
    ///   the left (the logo, *SpektraLab*, the line) and the code at the right (the address and
    ///   *Scan to visit* beside a QR code). A tall picture.
    /// - **A landscape table** (the host's own, 2026-10-19: "poster for horizontal lighttable should
    ///   also be redesigned") is its counterpart turned, not the portrait poster with a wide table in
    ///   it: a wide picture, the table at its left and, where the row was, a column at its right --
    ///   the mark at the column's top, level with the table's top edge, and the code at its foot,
    ///   level with the table's bottom edge, all on the column's left line, as a gallery's label
    ///   hangs beside a print. The margins are the same, and the picture is about 3 : 2 where the
    ///   portrait one is about 2 : 3.
    /// - **A smaller table** (A5, A6) is the same poster: every millimetre of its furniture scales
    ///   with the table (`unit`), so the poster is composed alike at every size and only the films,
    ///   which keep their own millimetres, lie larger on it.
    struct Poster: Equatable, Sendable {
        var landscape: Bool
        /// The furniture's millimetres a millimetre at A4: 1, 1/√2 at A5, 1/2 at A6.
        var unit: Double
        /// The table's frame's half size (the lit pad and its rim), mm.
        var frame: CGSize
        /// The table points the poster covers, mm, y up (`picture`'s rect).
        var x0: Double, y0: Double, x1: Double, y1: Double
        /// From here on, millimetres from the poster's top left, y down, as `share.js` draws.
        /// The logo: its top left and its side.
        var logo: CGPoint
        var logoSide: Double
        /// The words' baselines: *SpektraLab* and the line under it, at their left; the address and
        /// *Scan to visit*, from the code card's left edge (x is added to it): their right end
        /// (portrait, `codeWordsRight`) or their left (landscape, y then from the card's top).
        var name: CGPoint
        var line: CGPoint
        var site: CGPoint
        var scan: CGPoint
        var codeWordsRight: Bool
        /// The code's card: the most its side may be, and the point it hangs from -- its right edge
        /// and its middle (portrait) or its left edge and its bottom (landscape).
        var codeSide: Double
        var codeAnchor: CGPoint
        /// The widest a line of words may be before it is set smaller (the landscape column), mm.
        var wordsWidth: Double?
        /// The words' sizes, mm: the name, the address, the lines under them.
        var nameSize: Double
        var siteSize: Double
        var smallSize: Double

        var width: Double { x1 - x0 }
        var height: Double { y1 - y0 }
    }

    /// The poster for a table whose lit pad has half size `half`, mm.
    static func poster(half: CGSize) -> Poster {
        let hw = half.width + LightTable.rim, hh = half.height + LightTable.rim
        let u = max(half.width, half.height) / (LightTable.a4.width / 2)
        let m = posterMargin * u, gap = posterGap * u, row = posterRow * u, foot = posterFoot * u, logo = 15 * u
        if hw <= hh {
            // share.js: the table, then the row under it
            let x0 = -hw - m, x1 = hw + m, y1 = hh + m, y0 = -hh - gap - row - foot
            let mid = m + 2 * hh + gap + row / 2, tx = m + logo + 4.2 * u
            return Poster(landscape: false, unit: u, frame: CGSize(width: hw, height: hh), x0: x0, y0: y0, x1: x1, y1: y1,
                          logo: CGPoint(x: m, y: mid - logo / 2), logoSide: logo,
                          name: CGPoint(x: tx, y: mid - 0.3 * u), line: CGPoint(x: tx, y: mid + 5 * u),
                          site: CGPoint(x: -5 * u, y: mid - 0.3 * u), scan: CGPoint(x: -5 * u, y: mid + 5 * u), codeWordsRight: true,
                          codeSide: row, codeAnchor: CGPoint(x: x1 - x0 - m, y: mid), wordsWidth: nil,
                          nameSize: 6 * u, siteSize: 4.2 * u, smallSize: 3.5 * u)
        }
        // landscape: the table, then the column at its right
        let col = posterColumn * u
        let x0 = -hw - m, x1 = hw + gap + col + foot, y0 = -hh - m, y1 = hh + m
        let cx = m + 2 * hw + gap, top = m, bottom = m + 2 * hh
        return Poster(landscape: true, unit: u, frame: CGSize(width: hw, height: hh), x0: x0, y0: y0, x1: x1, y1: y1,
                      logo: CGPoint(x: cx, y: top), logoSide: logo,
                      name: CGPoint(x: cx, y: top + logo + 8.5 * u), line: CGPoint(x: cx, y: top + logo + 13.8 * u),
                      site: CGPoint(x: 0, y: -8.6 * u), scan: CGPoint(x: 0, y: -3.3 * u), codeWordsRight: false,
                      codeSide: row, codeAnchor: CGPoint(x: cx, y: bottom), wordsWidth: col,
                      nameSize: 6 * u, siteSize: 4.2 * u, smallSize: 3.5 * u)
    }

    /// The poster's pixels for a table of this lit half size: the width as `LightTableShare.poster`
    /// asks the renderer for it, the height as the renderer rounds it (`LightTableRenderer.picture`).
    static func posterPixels(half: CGSize) -> (width: Int, height: Int) {
        let p = poster(half: half)
        let px = posterLong * p.width / max(p.width, p.height)
        return (Int(px.rounded()), Int((px * p.height / p.width).rounded()))
    }

    // MARK: the shadow (With Light Table)

    /// One layer of a window's shadow, millimetres of the table: its blur (a Gaussian's sigma), how
    /// far it falls below the table, and its strength.
    struct ShadowLayer: Equatable, Sendable {
        var sigma: Double
        var drop: Double
        var alpha: Double
    }

    /// macOS's window shadow, scaled to the table: a broad soft shadow a little below it, and a
    /// tight one at its edge (the shader's second layer, `lt_pad`'s `look`). The broad one's sigma
    /// is 2.8 % of the table's short side; a macOS window of 800 pt casts about 20 pt.
    static let ambient = ShadowLayer(sigma: 6.0, drop: 2.7, alpha: 0.40)
    static let contact = ShadowLayer(sigma: 0.6, drop: 0.3, alpha: 0.22)
    /// How many sigmas the margin reaches past the shadow's edge: at 3.4 the broad layer is under
    /// 0.04 % of its strength, which an 8-bit alpha writes as 0.
    static let reach = 3.4

    /// The margins round the table, pixels: the sides, the top (less: the shadow falls down) and the bottom.
    static func shadowMargins(k: Double) -> (side: Int, top: Int, bottom: Int) {
        let r = reach * ambient.sigma
        return (Int((k * r).rounded(.up)), Int((k * (r - ambient.drop)).rounded(.up)), Int((k * (r + ambient.drop)).rounded(.up)))
    }

    // MARK: the sheet

    /// A contact sheet's file: its pixels, where the table lies in it, and the table millimetres it covers.
    struct Sheet: Equatable, Sendable {
        var width: Int
        var height: Int
        /// The table (With Light Table: its frame; Layout Only: the sheet) in the file, pixels, y down.
        var table: CGRect
        /// Pixels a millimetre.
        var k: Double
        /// The table millimetres the file covers, y up: left, bottom, right, top.
        var x0: Double, y0: Double, x1: Double, y1: Double

        var megapixels: Double { Double(width) * Double(height) / 1e6 }
        /// One RGBA buffer of the whole file: what is never held.
        var bytes: Int { width * height * 4 }
        /// A pixel row's top edge in table millimetres (y up).
        func worldY(row: Double) -> Double { y1 - row / k }
        func worldX(column: Double) -> Double { x0 + column / k }
    }

    /// The file for a table whose lit pad has half size `half`, mm.
    static func sheet(half: CGSize, style: LightTableExportStyle, shortEdge: Int) -> Sheet {
        let rim = style == .withTable ? LightTable.rim : 0
        let hw = half.width + rim, hh = half.height + rim
        let s = Double(clampShortEdge(shortEdge))
        let k = s / (2 * min(hw, hh))
        // the short side exactly the number chosen; the long side as the table's shape has it
        let tw = hw <= hh ? Int(s) : Int((2 * hw * k).rounded())
        let th = hw <= hh ? Int((2 * hh * k).rounded()) : Int(s)
        let m = style == .withTable ? shadowMargins(k: k) : (side: 0, top: 0, bottom: 0)
        let width = tw + 2 * m.side, height = th + m.top + m.bottom
        let x0 = -hw - Double(m.side) / k, y1 = hh + Double(m.top) / k
        return Sheet(width: width, height: height, table: CGRect(x: m.side, y: m.top, width: tw, height: th), k: k,
                     x0: x0, y0: y1 - Double(height) / k, x1: x0 + Double(width) / k, y1: y1)
    }

    // MARK: bands and tiles

    /// Rows a band, and a tile's widest: under the simulator's 256 MiB a buffer and well inside
    /// every GPU's 8,192 px a texture.
    static let bandRows = 1024
    static let tileSide = 2048

    struct Tile: Equatable, Sendable {
        var x: Int, y: Int, width: Int, height: Int
    }

    /// The file's rows, a band at a time, top first.
    static func bands(height: Int, rows: Int = bandRows) -> [Range<Int>] {
        stride(from: 0, to: max(height, 0), by: max(rows, 1)).map { $0..<min($0 + max(rows, 1), height) }
    }

    /// Each band's tiles, left to right: every pixel of the file in exactly one.
    static func tiles(width: Int, height: Int, side: Int = tileSide, rows: Int = bandRows) -> [[Tile]] {
        bands(height: height, rows: rows).map { band in
            stride(from: 0, to: max(width, 0), by: max(side, 1)).map { x in
                Tile(x: x, y: band.lowerBound, width: min(side, width - x), height: band.count)
            }
        }
    }

    // MARK: the films' pictures

    /// Long edges a film's picture is read at, pixels: the table's own steps to 2,048; above that the size
    /// the file shows it, rounded up to 256, to the table's ceiling (`LightTableSizing.sourceCeiling`: the
    /// largest film any format makes, pixel for pixel on A6 at 5,000 px). Until 2026-10-24 the top was 4,096,
    /// which read a 6 × 17 strip there at half its pixels. A file is read once, so a step there saves no
    /// second read, and the screen's next step past 4,096 (the ceiling) would read a 6 × 9 on A6 at four
    /// times the pixels it needs.
    static let filmSteps = [256, 512, 1024, 2048]
    static let fineStep = 256

    static func filmStep(for px: Double) -> Int {
        if let step = filmSteps.first(where: { Double($0) >= px }) { return step }
        let fine = Int((px / Double(fineStep)).rounded(.up)) * fineStep
        return min(fine, LightTableSteps.ceiling)
    }

    /// What one film needs of the export: its long edge in the file, its shape, and the file's rows
    /// it touches (its shadow included).
    struct FilmNeed: Equatable, Sendable {
        var id: UUID
        var pixels: Double
        var aspect: Double
        var rows: ClosedRange<Int>
    }

    /// A film lying at `centre`, turned `angle`, `size` mm, its shadow reaching `reach` mm past it:
    /// what it needs of `sheet`. Nil when it lies wholly outside the file.
    static func need(id: UUID, centre: CGPoint, angle: Double, size: CGSize, reach: Double, sheet: Sheet) -> FilmNeed? {
        let c = abs(cos(angle)), s = abs(sin(angle))
        let halfH = (s * size.width + c * size.height) / 2 + reach
        let top = Int(((sheet.y1 - (centre.y + halfH)) * sheet.k).rounded(.down))
        let bottom = Int(((sheet.y1 - (centre.y - halfH)) * sheet.k).rounded(.up))
        let lo = max(top, 0), hi = min(bottom, sheet.height - 1)
        guard lo <= hi else { return nil }
        return FilmNeed(id: id, pixels: Double(max(size.width, size.height)) * sheet.k, aspect: size.width / max(size.height, 1e-6),
                        rows: lo...hi)
    }

    /// How far a film's shadow reaches past it, mm (`LightTableRenderer.encode`'s quad margin).
    static func shadowReach(_ sh: LightTable.Shadow) -> Double { 2 * sh.blur + 2 + hypot(sh.x, sh.y) }

    /// The bands a film is needed in: the first and the last it touches.
    static func bandSpan(_ rows: ClosedRange<Int>, bands: [Range<Int>]) -> ClosedRange<Int>? {
        guard let first = bands.firstIndex(where: { $0.overlaps(rows.lowerBound..<rows.upperBound + 1) }),
              let last = bands.lastIndex(where: { $0.overlaps(rows.lowerBound..<rows.upperBound + 1) }) else { return nil }
        return first...last
    }

    /// The bytes held while each band is drawn: every film it touches, at its step, with its mips.
    static func bandBytes(_ needs: [FilmNeed], steps: [UUID: Int], bands: [Range<Int>]) -> [Int] {
        var out = [Int](repeating: 0, count: bands.count)
        for n in needs {
            guard let span = bandSpan(n.rows, bands: bands), let edge = steps[n.id] else { continue }
            let b = LightTableSteps.bytes(edge: edge, aspect: n.aspect)
            for i in span { out[i] += b }
        }
        return out
    }

    /// Every film's step under the budget: each at the step its size in the file needs, then —
    /// while the band that holds the most is over — the largest film in that band halved, never
    /// under the smallest step.
    static func planFilms(_ needs: [FilmNeed], bands: [Range<Int>], budget: Int) -> [UUID: Int] {
        var steps: [UUID: Int] = [:]
        for n in needs { steps[n.id] = filmStep(for: n.pixels) }
        while true {
            let held = bandBytes(needs, steps: steps, bands: bands)
            guard let worst = held.indices.max(by: { held[$0] < held[$1] }), held[worst] > budget else { break }
            let inBand = needs.filter { n in
                bandSpan(n.rows, bands: bands).map { $0.contains(worst) } ?? false && (steps[n.id] ?? 0) > filmSteps[0]
            }
            guard let big = inBand.max(by: { LightTableSteps.bytes(edge: steps[$0.id]!, aspect: $0.aspect)
                                             < LightTableSteps.bytes(edge: steps[$1.id]!, aspect: $1.aspect) }) else { break }
            steps[big.id] = steps[big.id]! / 2
        }
        return steps
    }

    // MARK: memory

    /// What the drawing holds besides the films: one band's buffer (the file's width × the band's
    /// rows), the tiles' targets (at most two sizes a band: full tiles and the last, narrower one)
    /// and ImageIO's own working rows, about four more bands' worth at the most measured.
    static func fixedBytes(_ sheet: Sheet) -> Int {
        let rows = min(bandRows, sheet.height)
        let band = sheet.width * rows * 4
        let tiles = 2 * min(tileSide, sheet.width) * rows * 4
        return band + tiles + 4 * band
    }
}
