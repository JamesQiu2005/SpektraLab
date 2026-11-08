//  film_edge_steps_selftest.swift — the Film Edge flow's steps and what greys its options, on this Mac.
//
//      tools/selftest.sh                # with the other checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  A tester (2026-10-18): Frame, Edge and Date opened only after *Next* had been pressed as far as
//  them. The owner (2026-10-19): one journey, but the user is not held to it; options a choice makes
//  meaningless are greyed instead. `Features/FilmEdge/FilmEdgeJourney.swift` holds both, and here:
//
//  - **the steps** — from a fresh open at any entry every step can be tapped; the date alone is one
//    step; Next and Back walk in order;
//  - **the film edge when jumping** — the page's moves made as the page makes them (`make`): a tap
//    from Film or Frame to Edge or Date puts the film edge on, with the host's body and the cut the
//    guide shows, exactly as Next × n would; back to the guide writes nothing; a format changed there
//    goes on with the next jump forward, the body kept; the date alone never puts a film edge on;
//  - **the frame number** — greyed where the edge print is not in the scan, held against the app's
//    port of the engine's own layout (`FilmLayout`): for every stock it has an edge look for, every
//    format and both views, the number is greyed exactly where 3 and 13 print the same marks on the
//    canvas;
//  - **the holes and the date** — holes on perforated film only; a date's faces, corner and size
//    while it is on and where the camera's back printed them.
//
//  Compiled with the model, the film edge's layout and the journey. No engine, no page.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a rule
//  broken on purpose, one at a time, and requires each run to fail.

import CoreGraphics
import Foundation
import SwiftUI

struct Checker {
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

/// The app's rules, or one broken on purpose.
struct Rules {
    var name = "the app's"
    var isOpen: (FilmEdgeJourney, FilmEdgeStep) -> Bool = { $0.isOpen($1) }
    var go: (FilmEdgeJourney, FilmEdgeStep) -> FilmEdgeJourney.Move = { $0.go(to: $1) }
    var written: (FrameEdit, Int, Geometry?) -> FrameEdit = { FilmEdgeJourney.written($0, bodySeed: $1, framing: $2) }
    var frameNumber: (FilmEdgeSettings, String) -> Bool = { FilmEdgeOptions.frameNumber($0, stockID: $1) }
    var face: (DateBackFace, DateBackSettings, FilmEdgeSettings) -> Bool = { FilmEdgeOptions.face($0, $1, $2) }

    static var broken: [Rules] {
        var gated = Rules(name: "a step waits for Next (the tester's report)")
        gated.isOpen = { j, s in s.rawValue <= j.step.rawValue }
        var silent = Rules(name: "a jump forward writes no film edge")
        silent.go = { j, s in
            if case .to(let t, _) = j.go(to: s) { return .to(t, writes: false) }
            return .stay
        }
        var bodiless = Rules(name: "the film edge goes on with no body")
        bodiless.written = { d, _, g in
            var e = d
            e.filmEdge.active = true
            if let g { e.filmEdge.framing = g }
            return e
        }
        var reseeded = Rules(name: "a second write gives the frame a new body")
        reseeded.written = { d, seed, g in
            var e = FilmEdgeJourney.written(d, bodySeed: seed, framing: g)
            e.filmEdge.cameraSeed = seed
            return e
        }
        var numbered = Rules(name: "the frame number is open everywhere")
        numbered.frameNumber = { _, _ in true }
        var unnumbered = Rules(name: "the frame number is greyed in Filed on 120 too")
        unnumbered.frameNumber = { e, s in FilmEdgeOptions.frameNumber(e, stockID: s) && e.mode == .strip }
        var faces = Rules(name: "a face is open while the date is off")
        faces.face = { f, b, e in var on = b; on.active = true; return FilmEdgeOptions.face(f, on, e) }
        return [gated, silent, bodiless, reseeded, numbered, unnumbered, faces]
    }
}

/// The page, as far as the film edge goes: its journey and its draft, and its `make`.
struct Page {
    var journey: FilmEdgeJourney
    var draft: FrameEdit
    /// The cut the guide shows for the draft as it is.
    var guide: Geometry
    var bodySeed: Int
    var writes = 0
    var ended = false
    let rules: Rules

    init(entry: FilmEdgeStep, draft: FrameEdit, guide: Geometry, bodySeed: Int, rules: Rules) {
        let alone = entry == .date && !draft.filmEdge.active
        journey = FilmEdgeJourney(entry: entry, dateAlone: alone)
        self.draft = draft
        self.guide = guide
        self.bodySeed = bodySeed
        self.rules = rules
    }

    mutating func make(_ move: FilmEdgeJourney.Move) {
        switch move {
        case .stay: return
        case .to(_, let w):
            if w { write() }
            journey.arrive(move)
        case .develop(let w):
            if w { write() }
            ended = true
        }
    }

    mutating func write() {
        guard !journey.dateAlone else { return }
        draft = rules.written(draft, bodySeed, guide)
        writes += 1
    }

    mutating func tap(_ s: FilmEdgeStep) { make(rules.go(journey, s)) }
    mutating func next() { make(journey.next(filmEdgeOn: draft.filmEdge.active)) }
    mutating func back() { make(journey.back()) }
}

func framing(_ x: Double) -> Geometry {
    var g = Geometry.default
    g.crop = CropRect(x: x, y: 0.1, width: 0.6, height: 0.4)
    return g
}

/// A frame whose film edge was never on: no body yet, no cut.
func fresh() -> FrameEdit {
    FrameEdit.default
}

// MARK: - the steps

func stepChecks(_ c: inout Checker, _ r: Rules) {
    for entry in FilmEdgeStep.allCases {
        let j = FilmEdgeJourney(entry: entry, dateAlone: false)
        c.expect(j.step == entry, "opened at \(entry), the journey is at \(j.step)")
        for s in FilmEdgeStep.allCases {
            c.expect(r.isOpen(j, s), "a fresh open at \(entry): \(s) cannot be tapped")
            let move = r.go(j, s)
            if s == entry {
                c.expect(move == .stay, "a tap on the step shown (\(s)) moves: \(move)")
            } else if case .to(let t, _) = move {
                c.expect(t == s, "a tap on \(s) from \(entry) goes to \(t)")
            } else {
                c.expect(false, "a tap on \(s) from a fresh open at \(entry) goes nowhere")
            }
        }
    }
    // The date alone: one step, and nowhere else to go.
    let alone = FilmEdgeJourney(entry: .date, dateAlone: true)
    c.expect(alone.step == .date, "the date alone is not at Date")
    for s in FilmEdgeStep.allCases where s != .date {
        c.expect(!r.isOpen(alone, s), "the date alone opens \(s)")
        c.expect(r.go(alone, s) == .stay, "the date alone goes to \(s)")
    }
    c.expect(alone.back() == .stay, "the date alone goes back")
    c.expect(alone.next(filmEdgeOn: false) == .develop(writes: false), "the date alone's Develop writes a film edge")

    // Next and Back walk in order, and only leaving the guide writes.
    var j = FilmEdgeJourney(entry: .film, dateAlone: false)
    let expected: [(FilmEdgeStep, Bool)] = [(.frame, false), (.edge, true), (.date, false)]
    for (s, w) in expected {
        let move = j.next(filmEdgeOn: j.step.rawValue >= FilmEdgeStep.edge.rawValue)
        c.expect(move == .to(s, writes: w), "Next from \(j.step) is \(move), not to \(s) writing \(w)")
        j.arrive(move)
    }
    c.expect(j.next(filmEdgeOn: true) == .develop(writes: false), "Develop with the film edge on writes it again")
    c.expect(j.next(filmEdgeOn: false) == .develop(writes: true), "Develop with the film edge outstanding does not write it")
    for s in [FilmEdgeStep.edge, .frame, .film] {
        let move = j.back()
        c.expect(move == .to(s, writes: false), "Back from \(j.step) is \(move)")
        j.arrive(move)
    }
    c.expect(j.back() == .stay, "Back from Film goes somewhere")

    // Every tap: written exactly when it leaves the guide for the developed film.
    for from in FilmEdgeStep.allCases {
        for to in FilmEdgeStep.allCases where to != from {
            let move = r.go(FilmEdgeJourney(entry: from, dateAlone: false), to)
            let want = from.showsGuide && !to.showsGuide
            c.expect(move == .to(to, writes: want), "a tap \(from) → \(to) is \(move), should write: \(want)")
        }
    }
}

// MARK: - the film edge when jumping

func jumpChecks(_ c: inout Checker, _ r: Rules) {
    let g1 = framing(0.2)
    // Straight to Edge or Date from a fresh open: on, the host's body, the guide's cut.
    for target in [FilmEdgeStep.edge, .date] {
        for entry in [FilmEdgeStep.film, .frame] {
            var p = Page(entry: entry, draft: fresh(), guide: g1, bodySeed: 42, rules: r)
            p.tap(target)
            c.expect(p.journey.step == target, "\(entry) → \(target): at \(p.journey.step)")
            c.expect(p.draft.filmEdge.active, "\(entry) → \(target): the film edge is not on")
            c.expect(p.draft.filmEdge.cameraSeed == 42, "\(entry) → \(target): body \(p.draft.filmEdge.cameraSeed), not the phone's 42")
            c.expect(p.draft.filmEdge.framing == g1, "\(entry) → \(target): the cut is not the guide's")
            c.expect(p.writes == 1, "\(entry) → \(target): written \(p.writes) times")
        }
    }
    // A jump is the walk: the same frame either way.
    var walked = Page(entry: .film, draft: fresh(), guide: g1, bodySeed: 42, rules: r)
    walked.next(); walked.next(); walked.next()
    var jumped = Page(entry: .film, draft: fresh(), guide: g1, bodySeed: 42, rules: r)
    jumped.tap(.date)
    c.expect(walked.journey.step == .date && jumped.journey.step == .date, "the walk or the jump is not at Date")
    c.expect(walked.draft == jumped.draft, "Film → Date by a tap is not the frame Next × 3 makes")

    // Back to the guide writes nothing; a format changed there goes on with the next jump, the body kept.
    var p = Page(entry: .film, draft: fresh(), guide: g1, bodySeed: 42, rules: r)
    p.tap(.date)
    let onFrame = p.draft
    p.tap(.film)
    c.expect(p.journey.step == .film && p.writes == 1 && p.draft == onFrame, "back to Film from Date wrote")
    p.draft.filmEdge.format = .f6x7
    p.draft.filmEdge.framing = nil
    let g2 = framing(0.3)
    p.guide = g2
    p.bodySeed = 77                       // another host's body: a frame keeps its own
    p.tap(.edge)
    c.expect(p.draft.filmEdge.format == .f6x7, "the format changed on Film did not go on")
    c.expect(p.draft.filmEdge.framing == g2, "the cut after the format changed is not the guide's")
    c.expect(p.draft.filmEdge.cameraSeed == 42, "the frame's body became \(p.draft.filmEdge.cameraSeed) on a second write")
    c.expect(p.writes == 2, "Film → Edge after Back wrote \(p.writes - 1) times")
    // Edge ↔ Date, and Frame → Film, write nothing.
    p.tap(.date); p.tap(.edge); p.tap(.frame); p.tap(.film)
    c.expect(p.writes == 2, "moves between Edge and Date, or within the guide, wrote")
    // A body given before is kept.
    var seeded = fresh()
    seeded.filmEdge.cameraSeed = 19
    var q = Page(entry: .film, draft: seeded, guide: g1, bodySeed: 42, rules: r)
    q.tap(.edge)
    c.expect(q.draft.filmEdge.cameraSeed == 19, "the frame's body 19 became \(q.draft.filmEdge.cameraSeed)")
    // A film edge already on, entered at Date: every step, and nothing written by the opening.
    var on = fresh()
    on.filmEdge.active = true
    on.filmEdge.cameraSeed = 19
    var d = Page(entry: .date, draft: on, guide: g1, bodySeed: 42, rules: r)
    c.expect(!d.journey.dateAlone, "a film edge on, entered at Date, is the date alone")
    d.tap(.film)
    c.expect(d.journey.step == .film && d.writes == 0, "Date → Film with the film edge on wrote, or did not go")
    // The date alone: Develop never puts a film edge on.
    var alone = Page(entry: .date, draft: fresh(), guide: g1, bodySeed: 42, rules: r)
    alone.tap(.edge)
    alone.next()
    c.expect(alone.ended && alone.writes == 0 && !alone.draft.filmEdge.active, "the date alone put a film edge on")
}

// MARK: - the frame number, against the layout

/// The edge print's marks on the canvas: those whose outline reaches inside it.
func shownEdge(_ g: FilmGeometry) -> [FilmMark] {
    let canvas = CGRect(x: g.sLo, y: g.tLo, width: g.sHi - g.sLo, height: g.tHi - g.tLo)
    return g.edge.filter {
        let box = FilmGeometry.outline([$0]).boundingRect
        return !box.isEmpty && box.intersects(canvas)
    }
}

func layout(_ format: FilmEdgeFormat, _ mode: FilmEdgeView, stock: String, number: Int) -> FilmGeometry? {
    var r = FilmEdgeRequest()
    r.format = format
    r.mode = mode
    r.cameraSeed = 19
    r.frameSeed = 5
    r.frameNumber = number
    r.stockID = stock
    r.edgeText = "KODAK GB 200-7"
    let long = 3600.0
    let w = Int(long), h = Int((long * format.acrossMM / format.alongMM).rounded())
    r.frame = PixelSize(width: w, height: h)
    guard let first = FilmLayout.layout(r) else { return nil }
    r.turn = first.vertical ? 1 : 0
    return FilmLayout.layout(r)
}

func frameNumberChecks(_ c: inout Checker, _ r: Rules) {
    var cases = 0
    for stock in EdgeLook.table.keys.sorted() {
        for format in FilmEdgeFormat.allCases {
            for mode in FilmEdgeView.allCases {
                // Two numbers of one parity: a motion-picture print has no numbers, but where its
                // dash and name fall follows the frame's parity, which is no number to choose.
                guard let a = layout(format, mode, stock: stock, number: 3),
                      let b = layout(format, mode, stock: stock, number: 13) else {
                    c.expect(false, "\(stock) \(format.label) \(mode): no layout")
                    continue
                }
                let seen = shownEdge(a) != shownEdge(b)
                var edge = FilmEdgeSettings()
                edge.active = true
                edge.format = format
                edge.mode = mode
                let open = r.frameNumber(edge, stock)
                c.expect(open == seen, "\(stock) \(format.label) \(mode.label): the frame number is "
                         + (open ? "open" : "greyed") + " but " + (seen ? "moves the edge print" : "moves nothing on the canvas"))
                let reason = FilmEdgeOptions.frameNumberReason(edge, stockID: stock)
                c.expect((reason == nil) == FilmEdgeOptions.frameNumber(edge, stockID: stock),
                         "\(stock) \(format.label) \(mode.label): a reason given where the number shows, or none where greyed")
                cases += 1
            }
        }
    }
    c.expect(cases >= 200, "only \(cases) layouts held the frame number")
}

// MARK: - the holes and the date

func optionChecks(_ c: inout Checker, _ r: Rules) {
    for format in FilmEdgeFormat.allCases {
        var e = FilmEdgeSettings()
        e.format = format
        c.expect(FilmEdgeOptions.holes(e) == (format == .f135 || format == .half || format == .xpan),
                 "holes on \(format.label) are " + (FilmEdgeOptions.holes(e) ? "open" : "greyed"))
    }

    var edge = FilmEdgeSettings()
    edge.active = true
    var back = DateBackSettings()
    // Off: every face, the corner and the size wait for the switch.
    for f in DateBackFace.allCases { c.expect(!r.face(f, back, edge), "\(f.label) is open with the date off") }
    c.expect(!FilmEdgeOptions.corner(back, edge), "the corner is open with the date off")
    c.expect(!FilmEdgeOptions.size(back, edge), "the size is open with the date off")
    // On, on 135 with a film edge: every face, the corner, the size.
    back.active = true
    for f in DateBackFace.allCases { c.expect(r.face(f, back, edge), "\(f.label) is greyed on 135 with the date on") }
    c.expect(FilmEdgeOptions.corner(back, edge) && FilmEdgeOptions.size(back, edge), "the corner or the size is greyed on 135")
    // The data face goes beside the frame: no corner, a size.
    back.style = .data
    c.expect(!FilmEdgeOptions.corner(back, edge), "the corner is open for the data face")
    c.expect(FilmEdgeOptions.size(back, edge), "the size is greyed for the data face")
    back.style = .lcd
    // The bare frame: no film edge to print data between frames.
    var bare = FilmEdgeSettings()
    bare.active = false
    c.expect(!r.face(.data, back, bare) && r.face(.lcd, back, bare) && r.face(.dots, back, bare), "the bare frame's faces")
    // 645 printed data in its margin only; 6×7 and the panoramic formats nothing at all.
    edge.format = .f645
    c.expect(r.face(.data, back, edge) && !r.face(.lcd, back, edge) && !r.face(.dots, back, edge), "645's faces")
    for format in [FilmEdgeFormat.f6x6, .f6x7, .f6x8, .f6x9, .xpan, .f6x12, .f6x17] {
        edge.format = format
        c.expect(FilmEdgeOptions.printsNothing(back, edge), "\(format.label) prints a date")
        for f in DateBackFace.allCases { c.expect(!r.face(f, back, edge), "\(f.label) is open on \(format.label)") }
        c.expect(!FilmEdgeOptions.corner(back, edge) && !FilmEdgeOptions.size(back, edge), "the corner or size is open on \(format.label)")
    }
}

@main
enum Main {
    static func main() {
        func run(_ rules: Rules, quiet: Bool) -> Checker {
            var c = Checker(quiet: quiet)
            stepChecks(&c, rules)
            jumpChecks(&c, rules)
            frameNumberChecks(&c, rules)
            optionChecks(&c, rules)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let rules = Rules.broken
            for rule in rules {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("film edge steps self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("film edge steps checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
