//  lighttable_export_selftest.swift — the light table's Share pictures in pixels, checked on this Mac.
//
//      tools/lighttable_selftest.sh                # runs these after the table's own checks
//      tools/lighttable_selftest.sh --self-test    # and each broken rule below must be caught
//
//  `LightTable/LightTableExportPlan.swift` sizes Poster and Contact Sheet and cuts a contact sheet
//  into the bands and tiles it is drawn in. What could go wrong quietly:
//
//  - **the size** — the short edge chosen kept between 1,000 and 5,000 on steps of 100, the table's
//    (or the sheet's) short edge exactly that, the long edge the table's shape, the shadow's margin
//    round With Light Table and none round Layout Only, the poster's 1,568 × 2,400;
//  - **the shadow** — at the file's edges what is left of it writes as 0 in 8 bits;
//  - **the tiles** — every pixel of the file in exactly one tile, none wider than 2,048 or taller
//    than a band;
//  - **the films** — the rows a film touches (its shadow included), the bands it is read for, the
//    textures held in the fullest band within the budget, never under 256 px;
//  - **the format** — Poster JPG, With Light Table PNG whatever was chosen, Layout Only as chosen;
//  - **every table** (2026-10-19: A4, A5, A6, either way up) — the poster 2,400 px on its long side,
//    tall for a portrait table and wide for a landscape one, whose mark and code stand in a column
//    at the table's right, clear of it and inside the picture; a smaller table's poster composed as
//    A4's; a contact sheet's short edge the number chosen and its millimetres the paper's, so it
//    prints at its size.

import CoreGraphics
import Foundation

struct ExportChecker {
    var passed = 0
    var failed = 0
    var quiet = false
    mutating func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else {
            failed += 1
            if !quiet { print("  FAILED: \(what())") }
        }
    }
}

typealias Plan = LightTableExportPlan

struct ExportRules {
    var name = "as written"
    var clamp: (Int) -> Int = { Plan.clampShortEdge($0) }
    var sheet: (CGSize, LightTableExportStyle, Int) -> Plan.Sheet = { Plan.sheet(half: $0, style: $1, shortEdge: $2) }
    var tiles: (Int, Int) -> [[Plan.Tile]] = { Plan.tiles(width: $0, height: $1) }
    var plan: ([Plan.FilmNeed], [Range<Int>], Int) -> [UUID: Int] = { Plan.planFilms($0, bands: $1, budget: $2) }
    var fileFormat: (LightTableExportChoice) -> LightTableExportFormat = { $0.fileFormat }
    var poster: (CGSize) -> (width: Int, height: Int) = { Plan.posterPixels(half: $0) }
    var posterLayout: (CGSize) -> Plan.Poster = { Plan.poster(half: $0) }

    static var broken: [ExportRules] {
        var out: [ExportRules] = []
        var r = ExportRules(); r.name = "the short edge not clamped"; r.clamp = { $0 }; out.append(r)
        r = ExportRules(); r.name = "the table without its shadow's margin"
        r.sheet = { h, _, s in Plan.sheet(half: CGSize(width: h.width + LightTable.rim, height: h.height + LightTable.rim), style: .layoutOnly, shortEdge: s) }
        out.append(r)
        r = ExportRules(); r.name = "the sheet with the rim"; r.sheet = { h, _, s in Plan.sheet(half: h, style: .withTable, shortEdge: s) }; out.append(r)
        r = ExportRules(); r.name = "tiles overlapping by a pixel"
        r.tiles = { w, h in Plan.tiles(width: w, height: h).map { $0.map { var t = $0; if t.x > 0 { t.x -= 1; t.width += 1 }; return t } } }
        out.append(r)
        r = ExportRules(); r.name = "the last narrow tile left out"
        r.tiles = { w, h in Plan.tiles(width: w, height: h).map { band in band.filter { $0.width == min(Plan.tileSide, w) } } }
        out.append(r)
        r = ExportRules(); r.name = "a film read at 4,096 at most (the rule until 2026-10-24)"
        r.plan = { n, b, budget in Plan.planFilms(n, bands: b, budget: budget).mapValues { min($0, 4096) } }
        out.append(r)
        r = ExportRules(); r.name = "the films' budget ignored"; r.plan = { n, b, _ in Plan.planFilms(n, bands: b, budget: .max) }; out.append(r)
        r = ExportRules(); r.name = "With Light Table as a JPG"; r.fileFormat = { $0.kind == .poster ? .jpg : $0.format }; out.append(r)
        r = ExportRules(); r.name = "the poster at 2,400 square"; r.poster = { _ in (2400, 2400) }; out.append(r)
        r = ExportRules(); r.name = "a landscape table on the portrait poster, the row under it"
        r.posterLayout = { h in
            // share.js' poster whatever the table's shape: as `poster` lays out a portrait table
            let tall = Plan.poster(half: CGSize(width: min(h.width, h.height), height: max(h.width, h.height)))
            let hw = h.width + LightTable.rim, hh = h.height + LightTable.rim, u = tall.unit
            var p = tall
            p.landscape = false
            p.frame = CGSize(width: hw, height: hh)
            p.x0 = -hw - 14 * u; p.x1 = hw + 14 * u; p.y1 = hh + 14 * u; p.y0 = -hh - 56 * u
            let mid = 14 * u + 2 * hh + 12 * u + 15 * u
            p.logo = CGPoint(x: 14 * u, y: mid - 7.5 * u)
            p.codeAnchor = CGPoint(x: p.x1 - p.x0 - 14 * u, y: mid)
            return p
        }
        out.append(r)
        r = ExportRules(); r.name = "a smaller table's poster with A4's furniture"
        r.posterLayout = { h in var p = Plan.poster(half: h); p.unit = 1; return p }
        out.append(r)
        r = ExportRules(); r.name = "an A6 contact sheet sized as A4"
        r.sheet = { h, style, s in Plan.sheet(half: h.width < 60 || h.height < 60 ? LightTable.half(.a4, portrait: h.width < h.height) : h, style: style, shortEdge: s) }
        out.append(r)
        return out
    }
}

func uid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

let a4 = CGSize(width: 105, height: 148.5)          // the portrait pad's half size (`LightTable.half`)

func exportSizeChecks(_ c: inout ExportChecker, _ r: ExportRules) {
    c.expect(r.clamp(999) == 1000 && r.clamp(7000) == 5000 && r.clamp(2049) == 2000 && r.clamp(2050) == 2100,
             "the short edge between 1,000 and 5,000 on steps of 100: \(r.clamp(999)), \(r.clamp(7000)), \(r.clamp(2049))")
    let p = r.poster(a4)
    c.expect(p.width == 1568 && p.height == 2400, "the poster is 1,568 × 2,400: \(p)")

    let l = r.sheet(a4, .layoutOnly, 2000)
    c.expect(l.width == 2000 && l.height == 2829, "Layout Only at 2,000: the A4 sheet, 2,000 × 2,829: \(l.width) × \(l.height)")
    c.expect(l.table == CGRect(x: 0, y: 0, width: 2000, height: 2829), "Layout Only has nothing round the sheet")
    c.expect(abs(l.x0 + 105) < 1e-9 && abs(l.x1 - 105) < 1e-9 && abs(l.y1 - 148.5) < 1e-9 && abs(l.y0 + 148.5) < 0.5 / l.k,
             "Layout Only covers the pad exactly: \(l.x0) \(l.x1) \(l.y0) \(l.y1)")
    let l5 = r.sheet(a4, .layoutOnly, 5000)
    c.expect(l5.width == 5000 && l5.height == 7071, "Layout Only at 5,000: 5,000 × 7,071 (√2): \(l5.width) × \(l5.height)")

    for s in [1000, 2000, 3700, 5000] {
        let t = r.sheet(a4, .withTable, s)
        let hw = a4.width + LightTable.rim, hh = a4.height + LightTable.rim
        c.expect(Int(t.table.width) == s && Int(t.table.height) == Int((Double(s) * hh / hw).rounded()),
                 "With Light Table at \(s): the table itself \(s) across, its long side the table's shape: \(t.table)")
        let m = Plan.shadowMargins(k: t.k)
        c.expect(m.side > 0 && m.bottom > m.top && t.width == s + 2 * m.side && t.height == Int(t.table.height) + m.top + m.bottom,
                 "With Light Table at \(s): the shadow's margin round it, more below than above: \(t.width) × \(t.height), \(m)")
        c.expect(abs((t.x0 + Double(m.side) / t.k) + hw) < 1e-9 && abs((t.y1 - Double(m.top) / t.k) - hh) < 1e-9,
                 "the table's frame lies at its rect in the file")
        // what is left of the shadow at the file's edges: the broad layer's tail at the nearest edge
        let dSide = Double(m.side) / t.k, dTop = Double(m.top) / t.k + Plan.ambient.drop, dBottom = Double(m.bottom) / t.k - Plan.ambient.drop
        let a = Plan.ambient
        let left = [dSide, dTop, dBottom].map { a.alpha * 0.5 * erfc($0 / (a.sigma * 2.0.squareRoot())) * 255 }.max() ?? 1
        c.expect(left < 0.5 && dSide >= 3 * a.sigma, "the shadow writes as 0 at the file's edges at \(s): \(left) of 255")
    }
}

func tileChecks(_ c: inout ExportChecker, _ r: ExportRules) {
    for (w, h) in [(2000, 2829), (2380, 3189), (5948, 7970), (5000, 7071), (2048, 1024), (1, 1), (4097, 2049)] {
        let bands = r.tiles(w, h)
        let all = bands.flatMap { $0 }
        let area = all.reduce(0) { $0 + $1.width * $1.height }
        let inside = all.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= w && $0.y + $0.height <= h && $0.width > 0 && $0.height > 0 }
        var overlap = false
        for i in all.indices { for j in all.indices where j > i {
            let a = all[i], b = all[j]
            if a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height { overlap = true }
        } }
        c.expect(inside && !overlap && area == w * h, "\(w) × \(h): every pixel in exactly one tile (area \(area), overlap \(overlap))")
        c.expect(all.allSatisfy { $0.width <= Plan.tileSide && $0.height <= Plan.bandRows },
                 "\(w) × \(h): no tile wider than 2,048 or taller than a band")
        c.expect(bands.enumerated().allSatisfy { i, band in band.allSatisfy { $0.y == i * Plan.bandRows } },
                 "\(w) × \(h): a band's tiles share its rows, top first")
    }
    c.expect(Plan.bands(height: 2829).map(\.count) == [1024, 1024, 781], "2,829 rows: two whole bands and 781")
}

func filmChecks(_ c: inout ExportChecker, _ r: ExportRules) {
    let s = r.sheet(a4, .withTable, 5000)
    let bands = Plan.bands(height: s.height)
    let reach = Plan.shadowReach(LightTable.rest)
    // a 6 × 9 at the middle, a 135 near the top, one off the table
    let big = Plan.need(id: uid(1), centre: .zero, angle: 0, size: CGSize(width: 84, height: 56), reach: reach, sheet: s)!
    let top = Plan.need(id: uid(2), centre: CGPoint(x: 0, y: 140), angle: 0.5, size: CGSize(width: 36, height: 24), reach: reach, sheet: s)!
    c.expect(Plan.need(id: uid(3), centre: CGPoint(x: 0, y: 900), angle: 0, size: CGSize(width: 36, height: 24), reach: reach, sheet: s) == nil,
             "a film wholly off the file needs nothing")
    let midRow = (s.y1 - 0) * s.k
    c.expect(Double(big.rows.lowerBound) <= midRow - (28 + reach) * s.k + 1 && Double(big.rows.upperBound) >= midRow + (28 + reach) * s.k - 1,
             "a film's rows hold it and its shadow: \(big.rows)")
    c.expect(abs(big.pixels - 84 * s.k) < 1e-9 && Plan.filmStep(for: big.pixels) == 2048, "the 6 × 9 at 5,000 px is read at 2,048: \(big.pixels)")
    c.expect(Plan.filmStep(for: 3000) == 3072 && Plan.filmStep(for: 99999) == LightTableSteps.ceiling && Plan.filmStep(for: 1) == 256,
             "steps 256…2,048, then the size shown to 256 px, to the ceiling: \(Plan.filmStep(for: 3000)), \(Plan.filmStep(for: 99999))")
    // A6 at 5,000 px (2026-10-24): every format pixel for pixel, the 6 × 17 strip included; past the ceiling, shrunk to it.
    let a6 = r.sheet(CGSize(width: 74, height: 52.5), .layoutOnly, 5000)
    c.expect(abs(a6.k - 5000.0 / 105) < 1e-9, "A6's short side at 5,000 px: \(a6.k) px a mm")
    let strip69 = Plan.need(id: uid(5), centre: .zero, angle: 0, size: CGSize(width: 88.7, height: 61.15), reach: reach, sheet: a6)!
    let strip617 = Plan.need(id: uid(6), centre: .zero, angle: 0, size: CGSize(width: 172.7, height: 61.15), reach: reach, sheet: a6)!
    let beyond = Plan.need(id: uid(7), centre: .zero, angle: 0, size: CGSize(width: 200, height: 61.15), reach: reach, sheet: a6)!
    let bands6 = Plan.bands(height: a6.height)
    let wide = r.plan([strip69], bands6, .max), widest = r.plan([strip617], bands6, .max), past = r.plan([beyond], bands6, .max)
    c.expect(Double(wide[strip69.id] ?? 0) >= strip69.pixels, "a 6 × 9 strip on A6 at 5,000 px is read pixel for pixel: \(wide[strip69.id] ?? 0) for \(strip69.pixels)")
    c.expect(Double(widest[strip617.id] ?? 0) >= strip617.pixels && widest[strip617.id] == LightTableSteps.ceiling,
             "a 6 × 17 strip there is read pixel for pixel, at the ceiling: \(widest[strip617.id] ?? 0) for \(strip617.pixels)")
    c.expect(past[beyond.id] == LightTableSteps.ceiling, "a film larger than any format is shrunk to the ceiling: \(past[beyond.id] ?? 0)")
    let span = Plan.bandSpan(top.rows, bands: bands)!
    c.expect(span.lowerBound == 0 && bands[span.upperBound].overlaps(top.rows.upperBound..<top.rows.upperBound + 1),
             "a film near the top is read for the first band and let go of after its last: \(span)")
    let needs = [big, top]
    let full = r.plan(needs, bands, .max)
    c.expect(full[big.id] == 2048 && full[top.id] == Plan.filmStep(for: top.pixels), "under a large budget each is read at the size it shows")
    let one = LightTableSteps.bytes(edge: 1024, aspect: 1.5)
    let tight = r.plan(needs, bands, one)
    let held = Plan.bandBytes(needs, steps: tight, bands: bands).max() ?? 0
    c.expect(held <= one, "the fullest band within the budget: \(held) of \(one)")
    let floor = r.plan(needs, bands, 1)
    c.expect(floor.values.allSatisfy { $0 == 256 }, "never under 256 px")
    // several films in one band: the largest halved first
    let small = Plan.need(id: uid(4), centre: CGPoint(x: 50, y: 0), angle: 0, size: CGSize(width: 36, height: 24), reach: reach, sheet: s)!
    let both = r.plan([big, small], bands, LightTableSteps.bytes(edge: 1024, aspect: 1.5) + LightTableSteps.bytes(edge: 1024, aspect: 1.5))
    c.expect(both[big.id] == 1024 && both[small.id] == 1024, "the largest in the fullest band is halved first: \(both[big.id] ?? 0), \(both[small.id] ?? 0)")
}

func formatChecks(_ c: inout ExportChecker, _ r: ExportRules) {
    var ch = LightTableExportChoice(kind: .poster, style: .layoutOnly, format: .png, shortEdge: 5000)
    c.expect(r.fileFormat(ch) == .jpg, "Poster is a JPG whatever is chosen")
    ch.kind = .contactSheet; ch.style = .withTable; ch.format = .jpg
    c.expect(r.fileFormat(ch) == .png, "With Light Table is a PNG even with JPG chosen")
    ch.style = .layoutOnly
    c.expect(r.fileFormat(ch) == .jpg, "Layout Only as chosen: JPG")
    ch.format = .png
    c.expect(r.fileFormat(ch) == .png, "Layout Only as chosen: PNG")
}

func tablesChecks(_ c: inout ExportChecker, _ r: ExportRules) {
    for paper in LightTablePaper.allCases {
        for portrait in [true, false] {
            let h = LightTable.half(paper, portrait: portrait), name = "\(paper.name) \(portrait ? "portrait" : "landscape")"
            let px = r.poster(h)
            c.expect(max(px.width, px.height) == 2400 && (portrait ? px.height > px.width : px.width > px.height),
                     "\(name): the poster 2,400 px on its long side, \(portrait ? "tall" : "wide"): \(px)")
            let p = r.posterLayout(h)
            let u = max(h.width, h.height) / 148.5
            c.expect(abs(p.unit - u) < 1e-9 && abs(p.logoSide - 15 * u) < 1e-9 && abs(p.codeSide - 30 * u) < 1e-9,
                     "\(name): the poster's furniture scaled with the table, \(p.unit) of A4's")
            let fx0 = 14 * u, fx1 = fx0 + 2 * p.frame.width, fy0 = 14 * u, fy1 = fy0 + 2 * p.frame.height   // the frame, from the top left
            if portrait {
                c.expect(!p.landscape && p.logo.y >= fy1 + 12 * u - 1e-9 && p.codeAnchor.y + p.codeSide / 2 <= p.height + 1e-9,
                         "\(name): the mark and the code in the row under the table")
                let ratio = p.height / p.width
                c.expect(ratio > 1.45 && ratio < 1.62, "\(name): about 2 : 3, as A4's (\(ratio))")
            } else {
                c.expect(p.landscape, "\(name): a poster of its own")
                c.expect(p.logo.x >= fx1 + 12 * u - 1e-9 && p.codeAnchor.x >= fx1 + 12 * u - 1e-9,
                         "\(name): the mark and the code in a column at the table's right, clear of it")
                c.expect(abs(p.logo.y - fy0) < 1e-9 && abs(p.codeAnchor.y - fy1) < 1e-9,
                         "\(name): the mark level with the table's top, the code's foot with its bottom")
                c.expect(p.codeAnchor.x + p.codeSide <= p.width - 14 * u + 1e-9 && (p.wordsWidth ?? .infinity) <= p.width - p.logo.x - 14 * u + 1e-9,
                         "\(name): the column inside the picture, its margin kept")
                c.expect(p.line.y + 4 * u < p.codeAnchor.y - p.codeSide + p.site.y - p.siteSize,
                         "\(name): the mark's words end above the address over the code")
                let ratio = p.width / p.height
                c.expect(ratio > 1.45 && ratio < 1.62, "\(name): about 3 : 2, the portrait poster's counterpart (\(ratio))")
                c.expect(abs(p.height - (2 * p.frame.height + 28 * u)) < 1e-9, "\(name): the same margin above and below the table")
            }
            // a contact sheet: the short edge the number chosen, the sheet's millimetres the paper's
            let size = paper.size
            for style in LightTableExportStyle.allCases {
                let sheet = r.sheet(h, style, 2000)
                c.expect(Int(min(sheet.table.width, sheet.table.height)) == 2000, "\(name) \(style.rawValue): the short edge 2,000: \(sheet.table)")
                if style == .layoutOnly {
                    let w = Double(sheet.width) / sheet.k, hh = Double(sheet.height) / sheet.k
                    let want = portrait ? CGSize(width: size.height, height: size.width) : size
                    c.expect(abs(w - want.width) < 0.5 && abs(hh - want.height) < 0.5 && (portrait ? sheet.height > sheet.width : sheet.width > sheet.height),
                             "\(name): Layout Only prints at \(Int(want.width)) × \(Int(want.height)) mm: \(w) × \(hh)")
                }
            }
        }
    }
    // the default short edge is the same whatever the table
    c.expect(LightTableExportChoice().shortEdge == 2000 && Plan.defaultShortEdge == 2000 && Plan.shortEdges == 1000...5000,
             "the contact sheet's short edge: 2,000 unless changed, 1,000 to 5,000")
}

/// The export's checks; with `selfTest`, each broken rule's run instead, every one to be caught.
func runExportChecks(selfTest: Bool) -> Bool {
    func run(_ rules: ExportRules, quiet: Bool) -> ExportChecker {
        var c = ExportChecker(quiet: quiet)
        exportSizeChecks(&c, rules)
        tileChecks(&c, rules)
        filmChecks(&c, rules)
        formatChecks(&c, rules)
        tablesChecks(&c, rules)
        return c
    }
    if selfTest {
        var caught = 0
        let rules = ExportRules.broken
        for rule in rules {
            if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
        }
        print("light table export self-test: \(caught) of \(rules.count) broken rules caught")
        return caught == rules.count
    }
    let c = run(ExportRules(), quiet: false)
    print("light table export checks: \(c.passed) passed, \(c.failed) failed")
    return c.failed == 0
}

@main
struct LightTableExportSelfTest {
    static func main() {
        exit(runExportChecks(selfTest: CommandLine.arguments.contains("--self-test")) ? 0 : 1)
    }
}
