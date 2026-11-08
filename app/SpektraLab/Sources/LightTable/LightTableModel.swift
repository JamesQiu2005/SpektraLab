//  LightTableModel.swift — the light table's films, where they lie, and the view onto them.
//
//  RFC-045. The website's light table (spektralab.app/lighttable, `src/lightpad/table.js` in the
//  website repository at `9875092`) ported to the host: an A4 light pad seen straight down,
//  measured in millimetres, with the library's frames lying on it at their true size. This file is
//  the part of `table.js` that is arithmetic — the pad's numbers, the pile, placing, turning and
//  settling, the portrait turn (and, the host's own, the table's three sizes and the glide between
//  them, `relayout`, `TableGlide`), hit testing, the view's zoom and clamp, and the easing of what is
//  shown towards where things are — **ported statement for statement**, so a film put down on the
//  host lies where the website would put it. Names follow the website's where it has one (`settle`,
//  `freeSpot`, `keepOn`, `extent`, `lying`, `toFront`, `orient`, `clampAxis`, `zoomAt`); a comment
//  says where a statement differs and why.
//
//  Units are the website's: millimetres on the table, x to the right and y **up**, (0, 0) the middle
//  of the lit area; points on the screen, y down, as a UIView has them (the website's CSS pixels).
//  Angles are radians, counter-clockwise on the table, any value — a film turned twice round is
//  turned twice round, and the shown angle takes the shortest way to it.
//
//  Pure Swift, `Codable`, no Metal and no UIKit: `tools/lighttable_selftest.swift` compiles it on a
//  Mac with the film layout and holds it against the website's own numbers.
//
//  **What is not here, on purpose.** The website's tray (the photos waiting off the table), its
//  "What was it shot on?" menu and `formats.js`' guessing of a size from a picture's shape: on the
//  host a frame is the library's and knows its own size (`LightTableSizing`). The website's Click
//  tool (pick a film up, click again to put it down) is a mouse's answer to a trackpad; on the host
//  a finger drags. Its corner-turning with the mouse is two fingers here, as the website does it on
//  a touch screen.

import CoreGraphics
import Foundation

// MARK: - the table's numbers

/// The website's constants, `table.js` lines 34–50 and `table-gl.js`' loupe, by the same names.
enum LightTable {
    /// The lit area, ISO 216 A4 landscape: 297 × 210 mm, √2 : 1.
    static let a4 = CGSize(width: 297, height: 210)
    /// The aluminium frame round it, mm.
    static let rim = 2.6
    /// The lit area's corner radius, mm.
    static let corner = 3.0
    /// Desk in view round the frame when the table fits the window, mm.
    static let desk = 5.0
    /// The scale's band along the top and left edges, which placing keeps clear of, mm.
    static let clear = 10.0
    /// Between films placed for the user, mm.
    static let gap = 3.0
    /// The quad beyond a film's cut edge, for its anti-aliasing, mm.
    static let pad = 0.8
    static let zoomMax = 8.0
    /// As many films as the table holds (the owner, 2026-10-17: "the maximum allowed images onto
    /// the table is simply 99"), and as many as the scale knows to hide under: the pad shader's
    /// uniform arrays, 3 + 2 × 99 float4s = 3,216 bytes, inside `setFragmentBytes`' 4 KB. A 100th
    /// film is refused.
    static let films = 99

    /// A film's shadow lying on the diffuser (`REST`), and held a few millimetres above it
    /// (`LIFT`): offset x, y, blur, alpha.
    struct Shadow: Equatable, Sendable { var x, y, blur, alpha: Double }
    static let rest = Shadow(x: 0.5, y: -1.1, blur: 2.4, alpha: 0.16)
    static let lift = Shadow(x: 2.4, y: -4.6, blur: 6.5, alpha: 0.2)

    static let quarter = Double.pi / 2
    static let deg = Double.pi / 180
    /// A free turn settles square within `snap` of a quarter turn — `snapTouch` under fingers — and
    /// goes in `step`s where the website's shift key asks for them.
    static let snap = 4 * deg
    static let snapTouch = 7 * deg
    static let step = 15 * deg

    /// The loupe's magnification (`MAG`), and the half-extent of what it is shown, in lens radii
    /// (`LENS_PAD`): a little past the lens, for the refraction at its rim.
    static let mag = 3.0
    static let lensPad = 1.5

    /// JavaScript's `Math.round`: halves go up, towards +∞. Swift's `rounded()` takes them away from
    /// zero, which differs on a negative half (−2.5 → −2 here, −3 there); a turn of −135° settles to
    /// a different quarter by it. Every rounding the website does goes through this.
    static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    /// An angle settled square when it comes near a quarter turn, or to 15° steps (`settle`).
    static func settle(_ a: Double, steps: Bool = false, snap: Double = LightTable.snap) -> Double {
        if steps { return jsRound(a / step) * step }
        let q = jsRound(a / quarter) * quarter
        return abs(a - q) < snap ? q : a
    }

    /// The website's `unwind`: an angle step brought into −π…π, so a turn that crosses atan2's seam
    /// keeps counting the same way.
    static func unwind(_ d: Double) -> Double { d - jsRound(d / (2 * .pi)) * 2 * .pi }

    /// Degrees as a person reads them: −180 to 180, a decimal only off the square (`degrees`).
    static func degrees(_ a: Double) -> String {
        var d = (((a / deg) + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180
        if abs(d + 180) < 1e-6 { d = 180 }
        let r = jsRound(d * 10) / 10
        return r == r.rounded() ? "\(Int(r))°" : String(format: "%.1f°", r)
    }

    /// Millimetres as the website writes a size: one decimal.
    static func mm(_ v: Double) -> String { String(format: "%.1f", jsRound(v * 10) / 10) }

    /// The lit area's half size, mm, at a paper size: landscape, or turned to portrait.
    static func half(_ paper: LightTablePaper = .a4, portrait: Bool) -> CGSize {
        let s = paper.size
        return portrait ? CGSize(width: s.height / 2, height: s.width / 2) : CGSize(width: s.width / 2, height: s.height / 2)
    }
}

/// The table's size (the owner, 2026-10-19: "not many people have that many images to be put onto a
/// lighttable, so we're adding A5 and A6"): ISO 216, each half the one before, √2 : 1. The website's
/// table is A4 only. A film keeps its own millimetres on every size, so on a smaller table it lies
/// larger in the view: the table is fitted to the view, the films are not.
enum LightTablePaper: String, Codable, CaseIterable, Identifiable, Sendable {
    case a4 = "a4", a5 = "a5", a6 = "a6"

    var id: String { rawValue }
    /// Its name, as printed on a box of paper: "A4".
    var name: String { rawValue.uppercased() }
    /// Landscape, mm: 297 × 210, 210 × 148, 148 × 105.
    var size: CGSize {
        switch self {
        case .a4: LightTable.a4
        case .a5: CGSize(width: 210, height: 148)
        case .a6: CGSize(width: 148, height: 105)
        }
    }
}

// MARK: - a film

/// One library frame on (or off) the table. `size` is the frame's own, in millimetres, as its
/// picture lies unturned (`LightTableSizing`): never stored as the truth — it is the library's, and
/// read again whenever the frame changes. `x, y, rot` are where the film **is to be**; what the
/// screen shows eases towards them (`LightTableShown`).
struct LightTableItem: Codable, Identifiable, Equatable, Sendable {
    /// The library frame's own id: a frame lies on the table once.
    var id: UUID
    var size: CGSize
    var x = 0.0
    var y = 0.0
    /// Radians, any angle.
    var rot = 0.0
    var on = false

    var w: Double { Double(size.width) }
    var h: Double { Double(size.height) }

    /// Its nearest quarter turn, 0–3 (`quarter`).
    var quarter: Int {
        let q = Int(LightTable.jsRound(rot / LightTable.quarter)) % 4
        return (q + 4) % 4
    }
    /// Its width and height as it lies, by that quarter (`lying`).
    var lying: CGSize { quarter & 1 == 1 ? CGSize(width: h, height: w) : CGSize(width: w, height: h) }
    /// The box it takes up on the table at its own angle (`extent`).
    var extent: CGSize {
        let c = abs(cos(rot)), n = abs(sin(rot))
        return CGSize(width: w * c + h * n, height: w * n + h * c)
    }
    var centre: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - the table

/// The films and their pile. `order` is the pile on the table, bottom to top: the film last put
/// down, moved or turned lies on top, takes a touch first, and casts its shadow on the ones below.
/// `items` holds every frame the table has been given, on it or taken off it (the website's tray,
/// without a tray: a film taken off waits to be put back, where it is found by its frame).
struct LightTableModel: Codable, Equatable, Sendable {
    private(set) var items: [LightTableItem] = []
    private(set) var order: [UUID] = []
    /// The table turned to portrait. On the host it is the person's choice, never the host's own
    /// way up (the owner, 2026-10-19: "does not read from the reference device's orientation but is
    /// selection-based only"); the website turns its table by its window's shape.
    private(set) var portrait = false
    private(set) var paper = LightTablePaper.a4
    /// The order Tidy Up last laid the films in, while they still lie as it laid them: a table
    /// turned or resized then is tidied again, in the same order, for its new shape. Anything that
    /// moves, turns, puts down or takes off a film forgets it.
    private(set) var tidied: [UUID]?

    init() {}

    var half: CGSize { LightTable.half(paper, portrait: portrait) }
    var isFull: Bool { order.count >= LightTable.films }
    /// The films on the table, bottom to top.
    var pile: [LightTableItem] { order.compactMap { item($0) } }

    func item(_ id: UUID) -> LightTableItem? { items.first { $0.id == id } }
    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    // MARK: placing

    /// The free spot nearest `at` where a `w × h` film lies clear of the scale and of `others` (the
    /// films on the table, unless told otherwise): `freeSpot`. The grid search walks 2.5 mm steps
    /// from the band's corner, by the same accumulation the website's loop makes.
    func freeSpot(_ w: Double, _ h: Double, _ at: CGPoint, others: [LightTableItem]? = nil) -> CGPoint {
        let half = self.half
        let x0 = -half.width + LightTable.clear + w / 2, x1 = half.width - LightTable.gap - w / 2
        let y0 = -half.height + LightTable.gap + h / 2, y1 = half.height - LightTable.clear - h / 2
        let fx = Self.clamp(at.x, min(x0, x1), max(x0, x1)), fy = Self.clamp(at.y, min(y0, y1), max(y0, y1))
        if x0 > x1 || y0 > y1 { return CGPoint(x: fx, y: fy) }
        let boxes = (others ?? pile).map { o -> (Double, Double, Double, Double) in
            let e = o.extent
            return (o.x, o.y, e.width / 2 + LightTable.gap, e.height / 2 + LightTable.gap)
        }
        func free(_ x: Double, _ y: Double) -> Bool {
            boxes.allSatisfy { b in abs(x - b.0) >= b.2 + w / 2 || abs(y - b.1) >= b.3 + h / 2 }
        }
        if free(fx, fy) { return CGPoint(x: fx, y: fy) }
        var best: CGPoint?
        var bd = Double.infinity
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let d = (x - at.x) * (x - at.x) + (y - at.y) * (y - at.y)
                if d < bd && free(x, y) { bd = d; best = CGPoint(x: x, y: y) }
                x += 2.5
            }
            y += 2.5
        }
        return best ?? CGPoint(x: fx, y: fy)
    }

    /// Where a film overlaps the films on the table least, on the light, in 5 mm steps; nearest `at`
    /// among equals. `place`'s way when `freeSpot` finds no free spot. Each overlap counts by its
    /// square, so a film overlaps several a little rather than one whole: on a full table, lying
    /// square on one film is less overlap than a corner of three, and would hide it.
    func leastCovered(_ it: LightTableItem, _ at: CGPoint, others: [LightTableItem]? = nil) -> CGPoint {
        let e = it.extent, half = self.half, others = others ?? pile
        let rx = max(0, half.width - e.width / 2), ry = max(0, half.height - e.height / 2)
        var best = CGPoint(x: Self.clamp(at.x, -rx, rx), y: Self.clamp(at.y, -ry, ry)), least = Double.infinity, near = Double.infinity
        var c = it
        var y = -ry
        while y <= ry + 1e-9 {
            var x = -rx
            while x <= rx + 1e-9 {
                c.x = x; c.y = y
                let o = others.reduce(0.0) { let a = Self.overlap(c, $1); return $0 + a * a }
                let d = (x - at.x) * (x - at.x) + (y - at.y) * (y - at.y)
                if o < least - 1e-6 || (abs(o - least) <= 1e-6 && d < near) { least = o; near = d; best = CGPoint(x: x, y: y) }
                x += 5
            }
            y += 5
        }
        return best
    }

    /// All of it on the light: off the box a film would read the frame through itself (`keepOn`).
    func keptOn(_ it: LightTableItem) -> LightTableItem {
        var it = it
        let e = it.extent, half = self.half
        it.x = Self.clamp(it.x, min(0, -half.width + e.width / 2), max(0, half.width - e.width / 2))
        it.y = Self.clamp(it.y, min(0, -half.height + e.height / 2), max(0, half.height - e.height / 2))
        return it
    }

    /// What the table remembered of a film: its centre, its angle, and the table it lay on then —
    /// which way it was turned (the website's `kept`) and its size.
    struct Kept: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var rot: Double
        var portrait: Bool
        var paper = LightTablePaper.a4
    }

    /// A film's centre carried from a table of half size `was` to one of half size `now`, each
    /// axis in proportion to the room it has there: from the middle to the furthest its centre can
    /// go with all of it on the light (`keepOn`'s limit). A film at an edge stays at that edge, one
    /// in the middle stays in the middle, and films keep their order along each axis; carried there
    /// and back, a film is where it was. (The website scales by the lit area alone, which can put a
    /// film near an edge partly off a smaller table.)
    static func carried(_ it: LightTableItem, from was: CGSize, to now: CGSize) -> CGPoint {
        // the same table: exactly where it lay, not where a division and a product round it to
        guard was != now else { return it.centre }
        let e = it.extent
        func axis(_ v: Double, _ a: Double, _ b: Double, _ size: Double) -> Double {
            let r0 = a - size / 2, r1 = b - size / 2
            guard r0 > 1e-9 else { return 0 }
            return clamp(v / r0, -1, 1) * max(0, r1)
        }
        return CGPoint(x: axis(it.x, was.width, now.width, e.width), y: axis(it.y, was.height, now.height, e.height))
    }

    /// The films on the table carried to a table of half size `now` **as one arrangement**: what
    /// the person laid out keeps its shape. Along each axis the arrangement — the box round all its
    /// films — is carried in proportion to the room it has, as `carried` carries one film, and
    /// keeps its own millimetres while it fits: a group in the middle of A4 is the same group in
    /// the middle of A6, not spread to the corners of a larger table or squeezed for nothing. Only
    /// along an axis it does not fit are the films' centres drawn together, all by the same share,
    /// until it does. Order along each axis is kept; carried there and back with room, a table is
    /// as it was.
    static func carried(_ films: [LightTableItem], from was: CGSize, to now: CGSize) -> [UUID: CGPoint] {
        guard was != now, !films.isEmpty else { return Dictionary(films.map { ($0.id, $0.centre) }, uniquingKeysWith: { a, _ in a }) }
        // one axis: the centres `c` and the films' extents `e` along it, the room's half then and now
        func axis(_ c: [Double], _ e: [Double], _ r0: Double, _ r1: Double) -> [Double] {
            let lo = zip(c, e).map { $0 - $1 / 2 }.min()!, hi = zip(c, e).map { $0 + $1 / 2 }.max()!
            let span = hi - lo, mid = (lo + hi) / 2
            let cs = c.max()! - c.min()!, beyond = span - cs
            let k = span <= 2 * r1 || cs < 1e-9 ? 1 : max(0, 2 * r1 - beyond) / cs
            let span1 = cs * k + beyond
            let f0 = r0 - span / 2, f1 = max(0, r1 - span1 / 2)
            let mid1 = f0 > 1e-9 ? clamp(mid / f0, -1, 1) * f1 : 0
            return c.map { mid1 + ($0 - mid) * k }
        }
        let e = films.map(\.extent)
        let xs = axis(films.map(\.x), e.map { Double($0.width) }, was.width, now.width)
        let ys = axis(films.map(\.y), e.map { Double($0.height) }, was.height, now.height)
        var out: [UUID: CGPoint] = [:]
        for (i, it) in films.enumerated() { out[it.id] = CGPoint(x: xs[i], y: ys[i]) }
        return out
    }

    /// Onto the table (`place`): at the free spot nearest `at`, square; or where it lay last time
    /// (`kept`), its place carried to the table as it is now (`carried`). A film already on the
    /// table comes to the top. False when the table already holds `LightTable.films` films.
    @discardableResult
    mutating func place(_ id: UUID, size: CGSize, at: CGPoint? = nil, kept: Kept? = nil) -> Bool {
        if order.contains(id) { setSize(id, size); toFront(id); return true }
        guard !isFull else { return false }
        tidied = nil
        var it = item(id) ?? LightTableItem(id: id, size: size)
        it.size = size
        if let kept {
            it.rot = kept.rot
            it.x = kept.x; it.y = kept.y
            let p = Self.carried(it, from: LightTable.half(kept.paper, portrait: kept.portrait), to: half)
            it.x = p.x; it.y = p.y
            it = keptOn(it)
        } else {
            it.rot = 0
            let l = it.lying
            var p = freeSpot(l.width, l.height, at ?? .zero)
            it.x = p.x; it.y = p.y
            // No free spot left (the table holds 99 since 2026-10-17; the website's 48 rarely ran out):
            // not on the middle, where every film after would land on the same place, but where it
            // overlaps the films already down least, nearest `at` among equals.
            if pile.contains(where: { Self.overlap(it, $0) > 0 }) {
                p = leastCovered(it, at ?? .zero)
                it.x = p.x; it.y = p.y
            }
        }
        it.on = true
        put(it)
        order.append(id)
        return true
    }

    /// Off the table (`takeOff`): it waits, with its place forgotten, to be put back.
    mutating func takeOff(_ id: UUID) {
        guard let i = index(id), items[i].on else { return }
        items[i].on = false
        order.removeAll { $0 == id }
        tidied = nil
    }

    /// Out of the table for good: the library let go of its frame.
    mutating func forget(_ id: UUID) {
        if index(id) != nil { tidied = nil }
        items.removeAll { $0.id == id }
        order.removeAll { $0 == id }
    }

    /// To the top of the pile: a film put down, moved, turned or resized (`toFront`).
    mutating func toFront(_ id: UUID) {
        guard order.last != id, order.contains(id) else { return }
        order.removeAll { $0 == id }
        order.append(id)
    }

    /// The frame's size, read again from the library (a format changed, Film Edge turned on):
    /// `setFormat`'s part of it. A film on the table is kept on the light.
    mutating func setSize(_ id: UUID, _ size: CGSize) {
        guard let i = index(id), items[i].size != size else { return }
        items[i].size = size
        tidied = nil
        if items[i].on { items[i] = keptOn(items[i]) }
    }

    /// A quarter turn from wherever it is — `dir` −1 to the right, 1 to the left — as Photoshop's
    /// Rotate 90° (`turn`). A turned film may now reach past the light: its centre comes back in.
    mutating func turnQuarter(_ id: UUID, dir: Int = -1) {
        guard let i = index(id), items[i].on else { return }
        tidied = nil
        items[i].rot += Double(dir) * LightTable.quarter
        items[i] = keptOn(items[i])
        toFront(id)
    }

    /// Its angle, already settled by whoever turns it (a gesture holds the turn it began from).
    mutating func setRotation(_ id: UUID, _ rot: Double) {
        guard let i = index(id), items[i].on else { return }
        if items[i].rot != rot { tidied = nil }
        items[i].rot = rot
    }

    /// Its centre, as a finger carries it: kept on the light (`g.it.x = …; keepOn`).
    mutating func moveTo(_ id: UUID, _ p: CGPoint, keepOn: Bool = true) {
        guard let i = index(id), items[i].on else { return }
        if items[i].x != p.x || items[i].y != p.y { tidied = nil }
        items[i].x = p.x
        items[i].y = p.y
        if keepOn { items[i] = keptOn(items[i]) }
    }

    /// Moved by so many millimetres (the website's arrow keys: `it.x += step; keepOn`).
    mutating func move(_ id: UUID, by d: CGVector) {
        guard let it = item(id), it.on else { return }
        moveTo(id, CGPoint(x: it.x + d.dx, y: it.y + d.dy))
    }

    /// Kept on the light after a turn let go of (`turned`).
    mutating func keepOn(_ id: UUID) {
        guard let i = index(id), items[i].on else { return }
        items[i] = keptOn(items[i])
    }

    /// The table turned to portrait or back (`orient`): `relayout` at the size it has.
    mutating func orient(portrait p: Bool) { relayout(paper: paper, portrait: p) }

    /// The table at another size, or turned the other way (the page's Size and Orientation
    /// buttons; the website only turns, by its window's shape). **No film is left out, taken off
    /// or lost off the light**, whatever the new table's size:
    ///
    /// - **A table Tidy Up laid out**, and not touched since (`tidied`), is tidied again in the same
    ///   order, for its new shape: its rows stay rows.
    /// - **Any other table:** the films are carried as one arrangement (`carried(_:from:to:)`): it
    ///   keeps its shape and its millimetres where it fits, is carried in proportion to its room so
    ///   what lay at the top left still does, and is drawn together only along an axis it no
    ///   longer fits. Then, bottom of the pile first, a film carried over a film it was clear of
    ///   before goes to the free spot nearest its carried place, clear of those films
    ///   (`freeSpot`); with no free spot left
    ///   (a small table, many films), where it overlaps them least (`leastCovered`). Films that lay
    ///   over each other before may still: an arrangement the person made is kept, not pulled
    ///   apart. A table with room turned and turned back is as it was. The pile keeps its order.
    ///
    /// Films off the table, waiting, are carried too, so one put back lies where it would have.
    mutating func relayout(paper newPaper: LightTablePaper, portrait p: Bool) {
        guard newPaper != paper || p != portrait else { return }
        let was = half, before = pile
        // which films lay over which before
        var over: [UUID: Set<UUID>] = [:]
        for (i, a) in before.enumerated() {
            for b in before[(i + 1)...] where Self.overlap(a, b) > 1e-6 {
                over[a.id, default: []].insert(b.id)
                over[b.id, default: []].insert(a.id)
            }
        }
        paper = newPaper
        portrait = p
        let now = half
        let to = Self.carried(before, from: was, to: now)
        for var it in items where !it.on {
            let c = Self.carried(it, from: was, to: now)
            it.x = c.x; it.y = c.y
            put(it)
        }
        if let ids = tidied { tidy(ids); return }
        var laid: [LightTableItem] = []
        for var it in before {
            let c = to[it.id] ?? it.centre
            it.x = c.x; it.y = c.y
            it = keptOn(it)
            let clear = laid.filter { !(over[it.id]?.contains($0.id) ?? false) }
            if clear.contains(where: { Self.overlap(it, $0) > 1e-6 }) {
                let e = it.extent
                let spot = freeSpot(e.width, e.height, c, others: clear)
                var q = it
                q.x = spot.x; q.y = spot.y
                if clear.contains(where: { Self.overlap(q, $0) > 1e-6 }) {
                    let least = leastCovered(it, c, others: clear)
                    q.x = least.x; q.y = least.y
                }
                it = keptOn(q)
            }
            put(it)
            laid.append(it)
        }
    }

    // MARK: tidying

    /// **Tidy Up** (design/lighttable, the designer's proposal 5, accepted 2026-10-17; the website has
    /// none): every film on the table laid square — each keeps its quarter turn, loses the rest — in
    /// rows in the order given (the frames' capture order), each row centred across the light and the
    /// rows together centred down it, clear of the scale's band, `LightTable.gap` × 2 between films.
    /// The pile becomes that order, the last on top.
    ///
    /// **When they do not all fit** (the owner, 2026-10-17: "both random and 整理 would have to accept
    /// overlaps when there has to be overlap") no film is refused or left out. The rows close up the
    /// way slides are fanned on a light box: each film's step along its row is shortened by a share
    /// `f`, and each row's step down the light by a share `g`, so every film's top left corner shows
    /// and the overlap is spread evenly over the table. `f` is the one (in 5 % steps) whose rows let
    /// the smaller of the two shares be largest; the rows then hang from their tops, so a short film
    /// in a tall row is not lost under the next row.
    mutating func tidy(_ ids: [UUID]) {
        let half = self.half, space = 2 * LightTable.gap
        let left = -half.width + LightTable.clear, right = half.width - LightTable.gap
        let top = half.height - LightTable.clear, bottom = -half.height + LightTable.gap
        let across = right - left, down = top - bottom
        var queue: [LightTableItem] = []
        for id in ids where order.contains(id) {
            guard var it = item(id), !queue.contains(where: { $0.id == id }) else { continue }
            it.rot = LightTable.jsRound(it.rot / LightTable.quarter) * LightTable.quarter
            queue.append(it)
        }
        for id in order where !queue.contains(where: { $0.id == id }) {
            if var it = item(id) { it.rot = LightTable.jsRound(it.rot / LightTable.quarter) * LightTable.quarter; queue.append(it) }
        }
        // The rows at a step share `f` along them: as many films as reach no further than the light.
        func pack(_ f: Double) -> [[LightTableItem]] {
            var rows: [[LightTableItem]] = []
            var row: [LightTableItem] = [], reach = 0.0
            for it in queue {
                if let prev = row.last {
                    let at = reach + f * (prev.lying.width + space)
                    if at + it.lying.width <= across + 1e-9 { row.append(it); reach = at; continue }
                    rows.append(row)
                }
                row = [it]
                reach = 0
            }
            if !row.isEmpty { rows.append(row) }
            return rows
        }
        func heights(_ rows: [[LightTableItem]]) -> [Double] { rows.map { $0.map(\.lying.height).max() ?? 0 } }
        // The share of each row's step down the light that lets the last row end on the light, 1 at most.
        func fit(_ rows: [[LightTableItem]]) -> Double {
            let h = heights(rows)
            let steps = h.dropLast().reduce(0) { $0 + $1 + space }
            guard let last = h.last, steps > 0 else { return 1 }
            return min(1, max(0, down - last) / steps)
        }
        var f = 1.0
        if fit(pack(1)) < 1 {
            var best = fit(pack(1)), t = 0.95
            while t >= 0.2 - 1e-9 {
                let score = min(t, fit(pack(t)))
                if score > best + 1e-9 { best = score; f = t }
                t -= 0.05
            }
        }
        let rows = pack(f), h = heights(rows), g = fit(rows), fanned = g < 1 || f < 1
        let used = h.dropLast().reduce(0) { $0 + g * ($1 + space) } + (h.last ?? 0)
        var rowTop = (top + bottom) / 2 + used / 2
        var laid: [LightTableItem] = []
        for (r, row) in rows.enumerated() {
            var steps: [Double] = []
            var reach = 0.0
            for (i, it) in row.enumerated() {
                if i > 0 { reach += f * (row[i - 1].lying.width + space) }
                steps.append(reach + it.lying.width / 2)
            }
            let x0 = (left + right) / 2 - (reach + (row.last?.lying.width ?? 0)) / 2
            for (i, var it) in row.enumerated() {
                it.x = x0 + steps[i]
                it.y = fanned ? rowTop - it.lying.height / 2 : rowTop - h[r] / 2
                laid.append(it)
            }
            rowTop -= g * (h[r] + space)
        }
        for it in laid { put(keptOn(it)) }
        order = laid.map(\.id)
        tidied = order
    }

    /// **Random** (随机; the owner, 2026-10-19: "the new 随机 is the more aligned version with no
    /// rotations and acts like how the first time the user puts images onto the light table, but
    /// have different random seeds everytime"): every film laid down again the way a film is first
    /// put on the table (`place`) — square (no turn at all), at the free spot nearest where it is
    /// aimed, clear of the scale's band and `LightTable.gap` from the films already down — but each
    /// aimed at a random point on the light, the films in a random order. Where no free spot is
    /// left, a film goes where it overlaps the others least (`leastCovered`), as `place` does; none
    /// is refused or left out, all of each lies on the light. `seed` decides it, so one seed always
    /// gives the same table; the page gives a new seed every time. The last laid lies on top.
    ///
    /// Aimed at random points, the films can leave no free spot for the last few where an
    /// arrangement with room for all exists (six 135 films on A6): up to twelve arrangements are
    /// tried, each from the same seed's sequence, and the first where every film found a free spot
    /// is kept — or, on a table too full for that, the one with the fewest that did not, then the
    /// least overlap.
    mutating func random(seed: UInt64) {
        var rng = LightTableRandom(seed: seed)
        let half = self.half
        var best: [LightTableItem] = [], least = (crowded: Int.max, over: Double.infinity)
        // A table the films cannot all lie apart on (their areas with their gaps past 60 % of the
        // light) is not tried again: every try would be crowded, and each costs a search per film.
        let room = pile.reduce(0.0) { $0 + ($1.w + LightTable.gap) * ($1.h + LightTable.gap) } <= 0.6 * 4 * half.width * half.height
        for _ in 0..<(room ? 12 : 1) {
            var ids = order
            for i in stride(from: ids.count - 1, to: 0, by: -1) { ids.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            var laid: [LightTableItem] = [], over = 0.0, crowded = 0
            for id in ids {
                guard var it = item(id) else { continue }
                it.rot = 0
                let at = CGPoint(x: (2 * rng.unit() - 1) * max(0, half.width - it.w / 2), y: (2 * rng.unit() - 1) * max(0, half.height - it.h / 2))
                var p = freeSpot(it.w, it.h, at, others: laid)
                it.x = p.x; it.y = p.y
                // no free spot: `freeSpot` gives back the point asked for, which may lie over a film
                // or within its 3 mm
                let free = laid.allSatisfy { o in
                    abs(it.x - o.x) >= (it.w + o.w) / 2 + LightTable.gap - 1e-9 || abs(it.y - o.y) >= (it.h + o.h) / 2 + LightTable.gap - 1e-9
                }
                if !free {
                    crowded += 1
                    if laid.contains(where: { Self.overlap(it, $0) > 0 }) {
                        p = leastCovered(it, at, others: laid)
                        it.x = p.x; it.y = p.y
                    }
                }
                it = keptOn(it)
                over += laid.reduce(0.0) { let a = Self.overlap(it, $1); return $0 + a * a }
                laid.append(it)
            }
            if crowded < least.crowded || (crowded == least.crowded && over < least.over) { least = (crowded, over); best = laid }
            if crowded == 0 { break }
        }
        for it in best { put(it) }
        order = best.map(\.id)
        tidied = nil
    }

    /// The small turn Scatter gives each film about its own quarter, either way.
    static let scatterTurn = 9 * LightTable.deg

    /// **Scatter** (打乱; the owner, 2026-10-17: "a '随机' feature … each time one different random
    /// seed is used", renamed 打乱 on 2026-10-19 when the aligned `random` took 随机): every film
    /// on the table scattered as if dropped on the light box — each to a
    /// random place on the light, turned a little (±9°) about the quarter it lies at, the pile in a
    /// random order. `seed` decides the scatter, so one seed always gives the same table; the page
    /// gives a new seed each time (never the body's). Each film tries eight random places and takes
    /// the one that overlaps the films dropped before it least (each overlap by its square, as in
    /// `leastCovered`), so the films spread out while there
    /// is room and overlap where there is not. None is refused or left out, and all of each lies on
    /// the light (`keepOn`).
    mutating func scatter(seed: UInt64) {
        var rng = LightTableRandom(seed: seed)
        var ids = order
        for i in stride(from: ids.count - 1, to: 0, by: -1) { ids.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
        let half = self.half
        var laid: [LightTableItem] = []
        for id in ids {
            guard var it = item(id) else { continue }
            it.rot = LightTable.jsRound(it.rot / LightTable.quarter) * LightTable.quarter + (2 * rng.unit() - 1) * Self.scatterTurn
            let e = it.extent
            let rx = max(0, half.width - e.width / 2), ry = max(0, half.height - e.height / 2)
            var best = it, least = Double.infinity
            for _ in 0..<8 {
                var c = it
                c.x = (2 * rng.unit() - 1) * rx
                c.y = (2 * rng.unit() - 1) * ry
                let o = laid.reduce(0.0) { let a = Self.overlap(c, $1); return $0 + a * a }
                if o < least { least = o; best = c }
            }
            laid.append(keptOn(best))
        }
        for it in laid { put(it) }
        order = laid.map(\.id)
        tidied = nil
    }

    /// The area two films' boxes on the table share, mm² (by their `extent`s).
    static func overlap(_ a: LightTableItem, _ b: LightTableItem) -> Double {
        let ea = a.extent, eb = b.extent
        let w = min(a.x + ea.width / 2, b.x + eb.width / 2) - max(a.x - ea.width / 2, b.x - eb.width / 2)
        let h = min(a.y + ea.height / 2, b.y + eb.height / 2) - max(a.y - ea.height / 2, b.y - eb.height / 2)
        return max(0, w) * max(0, h)
    }

    // MARK: touching

    /// The film under a table point, top first (`hit`): within its turned rectangle and half a
    /// millimetre round it. `shown` gives the film as it is drawn this moment, where a film is on its
    /// way somewhere (the website tests what is shown); nil tests where each one is to be.
    func hit(_ p: CGPoint, shown: ((UUID) -> (centre: CGPoint, angle: Double, size: CGSize)?)? = nil) -> UUID? {
        for id in order.reversed() {
            guard let it = item(id) else { continue }
            let s = shown?(id) ?? (it.centre, it.rot, it.size)
            let dx = p.x - s.centre.x, dy = p.y - s.centre.y, c = cos(s.angle), sn = sin(s.angle)
            if abs(dx * c + dy * sn) <= s.size.width / 2 + 0.5 && abs(-dx * sn + dy * c) <= s.size.height / 2 + 0.5 { return id }
        }
        return nil
    }

    /// The website's `onLight`: a table point on the lit area or its frame.
    func onLight(_ p: CGPoint) -> Bool {
        abs(p.x) <= half.width + LightTable.rim && abs(p.y) <= half.height + LightTable.rim
    }

    private mutating func put(_ it: LightTableItem) {
        if let i = index(it.id) { items[i] = it } else { items.append(it) }
    }

    static func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, v)) }
}

// MARK: - the view onto it

/// The orthographic view: the table's point `(cx, cy)` in the middle of the view, `s` points a
/// millimetre (`sFit × zoom`), and the room the page's own controls leave round it (`inset`). The
/// website's `measureStage`, `clampView`, `zoomAt`, `setZoom`, `toWorld` and `toScreen`.
struct LightTableViewport: Equatable, Sendable {
    struct Insets: Equatable, Sendable {
        var top = 48.0, left = 16.0, bottom = 16.0, right = 16.0
    }

    /// The view, points.
    private(set) var size = CGSize(width: 1, height: 1)
    private(set) var inset = Insets()
    private(set) var sFit = 1.0
    private(set) var zoom = 1.0
    var cx = 0.0
    var cy = 0.0
    /// The lit area's half size, mm (`LightTableModel.half`).
    var half = LightTable.half(portrait: false)
    private(set) var measured = false
    /// The zoom's limits: 1–8× (fit to eight times), widened only while the window's Actual Size
    /// (1:1) needs a zoom outside them — a small table fitted larger than life in a large window,
    /// or a large one in a small window (`LightTableController.actualSize`). The host never
    /// changes them.
    var zoomFloor = 1.0
    var zoomCeiling = LightTable.zoomMax

    var s: Double { sFit * zoom }
    var isZoomed: Bool { zoom > 1.01 }

    func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: cx + (p.x - size.width / 2) / s, y: cy - (p.y - size.height / 2) / s) }
    func toScreen(_ w: CGPoint) -> CGPoint { CGPoint(x: size.width / 2 + (w.x - cx) * s, y: size.height / 2 - (w.y - cy) * s) }

    /// The table with its frame and the desk round it, mm (`box`).
    var box: CGSize {
        CGSize(width: 2 * (half.width + LightTable.rim + LightTable.desk), height: 2 * (half.height + LightTable.rim + LightTable.desk))
    }

    /// Keep the table in the view: centred while it is smaller than the space the controls leave,
    /// and never pulled clear of that space once it is bigger (`clampAxis`).
    private func clampAxis(_ c: Double, _ h: Double, _ view: Double, _ lo: Double, _ hi: Double) -> Double {
        let r = axisRange(h, view, lo, hi)
        return LightTableModel.clamp(c, r.lo, r.hi)
    }

    /// Where the view's centre may lie on one axis at this zoom: one place while the table is smaller
    /// than the room, a range once it is bigger.
    private func axisRange(_ h: Double, _ view: Double, _ lo: Double, _ hi: Double) -> (lo: Double, hi: Double) {
        let mn = -h + (view / 2 - lo) / s, mx = h - (view / 2 - hi) / s
        return mn > mx ? ((hi - lo) / (2 * s), (hi - lo) / (2 * s)) : (mn, mx)
    }

    private var ranges: (x: (lo: Double, hi: Double), y: (lo: Double, hi: Double)) {
        let b = box
        return (axisRange(b.width / 2, size.width, inset.left, inset.right), axisRange(b.height / 2, size.height, inset.bottom, inset.top))
    }

    mutating func clampView() {
        let b = box
        cx = clampAxis(cx, b.width / 2, size.width, inset.left, inset.right)
        cy = clampAxis(cy, b.height / 2, size.height, inset.bottom, inset.top)
    }

    // MARK: under the fingers: the rubber band

    /// The most the zoom gives past 1× and 8× under the fingers, in its logarithm: e^0.35, about 1.4×.
    static let zoomGive = 0.35

    /// The give past a limit (UIScrollView's rubber band): `o` asked past it, `d` the most it ever
    /// gives; continuous, and the same way back.
    static func band(_ o: Double, _ d: Double) -> Double { (1 - 1 / (o * 0.55 / d + 1)) * d }
    static func unband(_ b: Double, _ d: Double) -> Double { let b = min(b, 0.999 * d); return b * d / ((d - b) * 0.55) }
    static func rubber(_ x: Double, _ lo: Double, _ hi: Double, _ d: Double) -> Double {
        x < lo ? lo - band(lo - x, d) : x > hi ? hi + band(x - hi, d) : x
    }
    static func unrubber(_ x: Double, _ lo: Double, _ hi: Double, _ d: Double) -> Double {
        x < lo ? lo - unband(lo - x, d) : x > hi ? hi + unband(x - hi, d) : x
    }

    /// The view as fingers hold it (`LightTableFingers`): the zoom they ask for, unclamped, with the
    /// table point `w` under the view point `p`. Past 1× and 8×, and past the table's edges, it gives
    /// less and less rather than stopping, so the fingers are never fought and never ignored; a
    /// pure function of what is asked, so the way back retraces the way out. `settled` brings it back.
    mutating func hold(zoom z: Double, world w: CGPoint, screen p: CGPoint) {
        zoom = exp(Self.rubber(log(max(z, 1e-6)), log(zoomFloor), log(zoomCeiling), Self.zoomGive))
        let r = ranges
        cx = Self.rubber(w.x - (p.x - size.width / 2) / s, r.x.lo, r.x.hi, size.width / s)
        cy = Self.rubber(w.y + (p.y - size.height / 2) / s, r.y.lo, r.y.hi, size.height / s)
    }

    /// What `hold` would be given, with the fingers' middle at `p`, to show the view as it is now:
    /// `hold`'s inverse, so fingers can take hold of the view wherever it is, given or not.
    func held(at p: CGPoint) -> (zoom: Double, world: CGPoint) {
        let z = exp(Self.unrubber(log(zoom), log(zoomFloor), log(zoomCeiling), Self.zoomGive))
        let r = ranges
        let x = Self.unrubber(cx, r.x.lo, r.x.hi, size.width / s), y = Self.unrubber(cy, r.y.lo, r.y.hi, size.height / s)
        return (z, CGPoint(x: x + (p.x - size.width / 2) / s, y: y - (p.y - size.height / 2) / s))
    }

    /// Within the table's limits: 1–8×, the table in the view.
    var isSettled: Bool {
        var v = self
        v.zoomAt(zoom, world: CGPoint(x: cx, y: cy), screen: CGPoint(x: size.width / 2, y: size.height / 2))
        return abs(v.zoom - zoom) < 1e-6 && abs(v.cx - cx) * s < 0.01 && abs(v.cy - cy) * s < 0.01
    }

    /// Where the view comes back to when the fingers let go of it past a limit: the zoom brought
    /// within 1–8× about the fingers' last middle `p`, and the table into the view.
    func settled(about p: CGPoint) -> LightTableViewport {
        var v = self
        v.zoomAt(LightTableModel.clamp(zoom, zoomFloor, zoomCeiling), world: toWorld(p), screen: p)
        return v
    }

    /// The zoom and the centre as given, unclamped: a step of the way back (`settled`).
    mutating func put(zoom z: Double, cx x: Double, cy y: Double) { zoom = z; cx = x; cy = y }

    /// Zoom so that the table point `w` sits under the view point `p` (`zoomAt`).
    mutating func zoomAt(_ z: Double, world w: CGPoint, screen p: CGPoint) {
        zoom = LightTableModel.clamp(z, zoomFloor, zoomCeiling)
        cx = w.x - (p.x - size.width / 2) / s
        cy = w.y + (p.y - size.height / 2) / s
        clampView()
    }

    /// The middle of the room the controls leave (`middle`).
    var middle: CGPoint {
        CGPoint(x: size.width / 2 + (inset.left - inset.right) / 2, y: size.height / 2 + (inset.top - inset.bottom) / 2)
    }

    /// Zoom about a view point, the middle when none is given (`setZoom`).
    mutating func setZoom(_ z: Double, at p: CGPoint? = nil) {
        let p = p ?? middle
        zoomAt(z, world: toWorld(p), screen: p)
    }

    /// Pan by a finger's travel in points (`cx = cx0 − dx / s`, `cy = cy0 + dy / s`), clamped.
    mutating func pan(from c0: CGPoint, by d: CGVector) {
        cx = c0.x - d.dx / s
        cy = c0.y + d.dy / s
        clampView()
    }

    /// The view laid out (`measureStage`, its arithmetic): the table fitted in the room the
    /// controls leave, the table point in the middle kept where it was. True when anything moved.
    @discardableResult
    mutating func measure(size new: CGSize, inset newInset: Insets, half newHalf: CGSize) -> Bool {
        guard new.width >= 1, new.height >= 1 else { return false }
        let sameHalf = newHalf == half
        half = newHalf
        inset = newInset
        let b = box
        let fit = max(0.2, min((new.width - inset.left - inset.right) / b.width, (new.height - inset.top - inset.bottom) / b.height))
        let sized = new != size
        // Nothing changed: the view stays as it is. The website clamps here too, but on the host a
        // layout pass comes in the middle of a pinch or a pan, and a clamp then snapped a view the
        // fingers held past the table's edge (the rubber band) back inside for one frame: a 195 pt
        // jump in the simulator's log, 2026-10-17. A view at rest is already within its limits.
        if !sized && fit == sFit && measured && sameHalf { return false }
        let keep = measured ? toWorld(CGPoint(x: size.width / 2, y: size.height / 2)) : nil
        size = new
        sFit = fit
        if let keep { cx = keep.x; cy = keep.y }
        clampView()
        measured = true
        return true
    }

    /// The loupe's lens radius and glass rim, points: the website's for a narrow window.
    var lensRadius: Double { size.width < 600 ? 72 : 102 }
    var lensRim: Double { size.width < 600 ? 5 : 7 }
}

// MARK: - what is shown

/// A film as it is drawn this moment, easing towards where it is to be (`animate`): the website's
/// `px, py, angle, sw, sh, presence, lift, pop`, and what it is doing — held by a finger, pressed,
/// turned, on its way off.
struct LightTableShown: Equatable, Sendable {
    var px = 0.0, py = 0.0, angle = 0.0, sw = 1.0, sh = 1.0
    var presence = 0.0, lift = 0.0, pop = 0.0
    /// Moved, or turned with two fingers: held high.
    var held = false
    /// A finger resting on it: risen towards the eye.
    var pressed = false
    /// Being turned.
    var turning = false
    /// The film chosen on the page: it lies lifted, at the held shadow (design/lighttable, L4).
    var chosen = false
    /// Taken off: fading, until it is gone.
    var leaving = false
    /// Its picture is on the GPU: it fades onto the light.
    var ready = false

    /// The film at rest where it is to be (the share picture's pile, `picture`).
    static func atRest(_ it: LightTableItem, ready: Bool) -> LightTableShown {
        LightTableShown(px: it.x, py: it.y, angle: it.rot, sw: it.w, sh: it.h, presence: ready ? 1 : 0, lift: 0, pop: 0, ready: ready)
    }

    /// A film just put down: not yet on the light, a little lifted, so it falls onto the table; one
    /// put back where it lay is not lifted (`place`).
    static func placed(_ it: LightTableItem, kept: Bool) -> LightTableShown {
        LightTableShown(px: it.x, py: it.y, angle: it.rot, sw: it.w, sh: it.h, presence: 0, lift: kept ? 0 : 0.6, pop: 0)
    }

    /// The website's `ease`: the share of the way to go in `dt` seconds for a time constant `tau`;
    /// all of it with Reduce Motion on.
    static func ease(_ dt: Double, _ tau: Double, reduce: Bool) -> Double { reduce ? 1 : 1 - exp(-dt / tau) }

    /// One step towards `it` (`animate`, one film). True while it is still on its way.
    mutating func step(towards it: LightTableItem, dt: Double, reduce: Bool) -> Bool {
        let tAngle = it.rot
        // the shortest way round to the new angle
        var da = tAngle - angle
        da -= LightTable.jsRound(da / (2 * .pi)) * 2 * .pi
        let want = leaving ? 0.0 : ready ? 1.0 : 0.0
        // held (moved, or turned with two fingers) high, turned a little, pressed by a finger in between
        let lift = held || chosen ? 1.0 : pressed ? 0.6 : turning ? 0.4 : 0
        let pop = pressed ? 1.0 : 0
        let k1 = Self.ease(dt, 0.07, reduce: reduce), k2 = Self.ease(dt, 0.1, reduce: reduce), k3 = Self.ease(dt, 0.13, reduce: reduce)
        px += (it.x - px) * k1; py += (it.y - py) * k1
        angle += da * k2
        sw += (it.w - sw) * k2; sh += (it.h - sh) * k2
        presence += (want - presence) * k3
        self.lift += (lift - self.lift) * k2
        // slow to rise, quick to settle
        self.pop += (pop - self.pop) * Self.ease(dt, pressed ? 0.16 : 0.09, reduce: reduce)
        let off = abs(it.x - px) + abs(it.y - py) + 40 * abs(da) + abs(it.w - sw) + abs(it.h - sh)
            + abs(want - presence) + abs(lift - self.lift) + abs(pop - self.pop)
        if off < 0.004 {
            px = it.x; py = it.y; angle = tAngle; sw = it.w; sh = it.h; presence = want; self.lift = lift; self.pop = pop
            return false
        }
        return true
    }

    /// Its size as drawn: a finger pressing on it lifts it towards the eye (`g = 1 + 0.045 pop`).
    var drawnSize: CGSize { let g = 1 + 0.045 * pop; return CGSize(width: sw * g, height: sh * g) }

    /// Its shadow, between lying and held by how far it is lifted (`sync`'s `lerp`).
    var shadow: LightTable.Shadow {
        let r = LightTable.rest, l = LightTable.lift, k = lift
        return LightTable.Shadow(x: r.x + (l.x - r.x) * k, y: r.y + (l.y - r.y) * k,
                                 blur: r.blur + (l.blur - r.blur) * k, alpha: r.alpha + (l.alpha - r.alpha) * k)
    }
}

// MARK: - the table changing size or turning

/// The table at another size or turned the other way, as it is shown on its way there
/// (`LightTableController.setTable`, and an Undo of it): the pad's half size and every film go from
/// where they were shown to where they now lie **together, on one curve**, and the view eases to fit
/// with them — so a film never lies off a pad that has not yet grown under it, and nothing jumps.
/// Each film goes the straight way to its place and the short way round to its angle, lifted a
/// little on the way as a hand would lift it (its shadow with it), and set down as it arrives.
///
/// The curve is a critically damped spring — quick away, slow into place, no overshoot (a light box
/// does not bounce) — over half a second, drawn at the display's rate, 120 Hz on a ProMotion screen.
/// Reduce Motion: no glide, the table is at once as it is to be. Pure arithmetic: the self-test holds it.
struct TableGlide: Sendable {
    struct Pose: Equatable, Sendable {
        var x: Double
        var y: Double
        var angle: Double
    }

    static let duration = 0.5
    /// The spring's rate, 1/s: e^(−ωt) is 0.06 % at the end, which `share` scales away.
    static let omega = 15.0
    /// How high a film is lifted half way (`LightTableShown.lift`: 1 is held by a finger).
    static let lift = 0.55

    /// The share of the way gone `t` seconds in: `1 − (1 + ωt) e^(−ωt)`, scaled to be exactly 1 at
    /// `duration`, so the last of it is not a step.
    static func share(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < duration else { return 1 }
        func x(_ t: Double) -> Double { 1 - (1 + omega * t) * exp(-omega * t) }
        return min(1, x(t) / x(duration))
    }

    /// The pad's half size it began from and goes to, mm.
    var from: CGSize
    var to: CGSize
    /// Each film as it was shown when the table changed.
    var films: [UUID: Pose]
    /// The view's zoom then, and the table point in the middle of its room: it eases to fit.
    var zoom: Double
    var centre: CGPoint
    var t0: Double

    func half(at f: Double) -> CGSize {
        CGSize(width: from.width + (to.width - from.width) * f, height: from.height + (to.height - from.height) * f)
    }

    /// A film `f` of the way from where it was shown to where it lies (`it`), and how high it is
    /// lifted: a film that does not move is not lifted. Nil for a film the table did not show then.
    func pose(_ it: LightTableItem, at f: Double) -> (pose: Pose, lift: Double)? {
        guard let p = films[it.id] else { return nil }
        let da = LightTable.unwind(it.rot - p.angle)
        let travel = hypot(it.x - p.x, it.y - p.y) + 20 * abs(da)
        return (Pose(x: p.x + (it.x - p.x) * f, y: p.y + (it.y - p.y) * f, angle: p.angle + da * f),
                Self.lift * min(1, travel / 8) * sin(.pi * f))
    }
}

// MARK: - the pictures' sizes

/// The steps a film's picture is read at, and how they are fitted under one budget
/// (`LightTableTextures`): pure arithmetic, so the self-test holds it.
enum LightTableSteps {
    /// Long edges, pixels: the website's own steps (to 2,048, its `maxEdge` on a host), then 4,096, then
    /// the table's ceiling (`LightTableSizing.sourceCeiling`, 8,224 since 2026-10-24: the largest film any
    /// format makes, a 6 × 17 strip, on A6 pixel for pixel in the largest export). A step above 2,048 is
    /// read only where the view or the loupe shows a film that large — a film on a fitted table is a few
    /// hundred pixels — and the budget still halves the largest first.
    static let steps = [256, 512, 1024, 2048, 4096].filter { $0 < ceiling } + [ceiling]
    static let ceiling = LightTableSizing.sourceCeiling

    /// The step for a long edge of `px` pixels: the first that covers it, never past the ceiling.
    static func step(for px: Double) -> Int { steps.first { Double($0) >= px } ?? ceiling }

    /// Where a film's picture is read from at a step (2026-10-24, the owner: a render "only … where we have
    /// the cache nowhere"), in this order:
    ///
    /// 1. **its kept develop**, where it is as large as the step, or there is no more to the picture than it
    ///    (`hasMore` false: a pair, a picture no larger than its preview): no job;
    /// 2. **its full-size render kept on disk** (`fullKept`): read at the step, no job;
    /// 3. **otherwise one job is asked for** (`asks`) — the full-size render, or for a frame with no more to
    ///    it than its preview and nothing kept, its develop — and meanwhile what there is is shown: the
    ///    kept develop, or for a frame with none the camera's own preview of the file.
    ///
    /// `keptEdge` is the kept develop's long edge, nil where there is none. Where nobody answers `asks`
    /// (the window, where every frame is developed as it arrives) the table reads what it has, as it did.
    static func choose(step: Int, keptEdge: Int?, hasMore: Bool, fullKept: Bool) -> (readsFull: Bool, asks: Bool) {
        if let keptEdge, keptEdge >= step || !hasMore { return (false, false) }
        if hasMore, fullKept { return (true, false) }
        return (false, true)
    }

    /// A texture's bytes with all its mips.
    static func bytes(width: Int, height: Int, mipmapped: Bool, bytesPerPixel: Int = 4) -> Int {
        var w = max(width, 1), h = max(height, 1), total = w * h * bytesPerPixel
        guard mipmapped else { return total }
        while w > 1 || h > 1 {
            w = max(1, w / 2); h = max(1, h / 2)
            total += w * h * bytesPerPixel
        }
        return total
    }

    /// A picture of this shape at a step: its long edge the step.
    static func pixelSize(edge: Int, aspect: Double) -> (width: Int, height: Int) {
        let a = max(aspect, 1e-3)
        return a >= 1 ? (edge, max(1, Int((Double(edge) / a).rounded()))) : (max(1, Int((Double(edge) * a).rounded())), edge)
    }

    /// The bytes a film's texture takes at a step, every mip included, RGBA 8 bits.
    static func bytes(edge: Int, aspect: Double) -> Int {
        let size = pixelSize(edge: edge, aspect: aspect)
        return bytes(width: size.width, height: size.height, mipmapped: true)
    }

    /// What one film needs: its long edge on the screen in pixels, whether it is seen, its shape.
    struct Need: Equatable, Sendable {
        var id: UUID
        var pixels: Double
        var visible: Bool
        var aspect: Double
    }

    /// Every film's step settled under the budget: each at the step it needs, then — while the
    /// total is over — the largest halved, films out of view first, never under the smallest step.
    static func plan(_ needs: [Need], budget: Int) -> [UUID: Int] {
        var edge: [UUID: Int] = [:]
        for n in needs { edge[n.id] = step(for: n.pixels) }
        var sum = needs.reduce(0) { $0 + bytes(edge: edge[$1.id] ?? steps[0], aspect: $1.aspect) }
        while sum > budget {
            let candidates = needs.filter { (edge[$0.id] ?? 0) > steps[0] }
            guard !candidates.isEmpty else { break }
            let hidden = candidates.filter { !$0.visible }
            let pool = hidden.isEmpty ? candidates : hidden
            guard let big = pool.max(by: { bytes(edge: edge[$0.id]!, aspect: $0.aspect) < bytes(edge: edge[$1.id]!, aspect: $1.aspect) })
            else { break }
            let was = edge[big.id]!
            edge[big.id] = was / 2
            sum += bytes(edge: was / 2, aspect: big.aspect) - bytes(edge: was, aspect: big.aspect)
        }
        return edge
    }
}
