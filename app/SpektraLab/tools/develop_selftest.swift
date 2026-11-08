//  develop_selftest.swift — the develop page's arithmetic and the slide rule, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  Three things the develop page (design/edit_v2) gets wrong quietly, with no engine and no page needed
//  to show it:
//
//  - **every panel's parts** (`PanelState`, `Features/Develop/DevelopLayout.swift`): none over another, none outside the 220 pt
//    the panel has — at each note's tallest, since a note that took one line more than its place is how
//    two parts of this page met on 2026-10-09. And **every note's line** (`PanelNotes`), with every
//    stock's name in it, measured in the page's own type against the narrowest page: a line is set on
//    one line and never wrapped, so it has to fit one;
//  - **a slide film is scanned, never printed** (`Model/Stock.swift`): over the bundle's own catalogue,
//    every positive film, at the pick, at every edit that enters, and on the wire — whatever paper the
//    frame was carrying (the owner, 2026-10-09: "the positive profiles are still tied to a printing
//    paper which should not happen again");
//  - **silver on silver, colour on colour** (`Model/Stock.swift`, 2026-10-09): a black-and-white film is
//    printed on a silver paper and a colour film on a colour one, at the pick, at every edit that enters,
//    and on the wire — where a silver pair also sends what the engine does not do by itself (the grain as
//    one layer, at the film's own amount; no Extended Dynamic Range; the paper's filter pack) and **no
//    colour frame's wire moves**. With it the engine client's own bookkeeping (`FilmParams.step`): a pack
//    sent once is sent again when the session comes back from a colour pair. And the pair a new frame
//    takes (`StockCatalog.newFramePair`);
//  - **what the pages say of it** (2026-10-09): a paper's card or row waits exactly where the model refuses
//    the paper, with the desktop's own reason; the enlarger's two rulers are named for a colour on a colour
//    print and for the paper's grade on a silver one (`EnlargerScales`); Grain's Sub-layers stands down
//    exactly where the wire does not carry it; and the pair chosen for new frames (`StockPair`, the
//    picker's) is always one a frame could have.
//
//  Compiled with those sources and the models they stand on, with `-D DEBUG`. No engine, no UIKit;
//  AppKit only to measure a line of type in the system's font.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a rule
//  broken on purpose, one at a time, and requires each run to fail.

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

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

/// The rules the checks hold, each as the app has it. `broken` breaks one at a time.
struct Rules {
    var name = "the app's own"
    // The page.
    var tabs: (Bool) -> [DevelopTab] = { DevelopTab.shown(pro: $0) }
    var kept: (DevelopTab, Bool) -> DevelopTab = { $0.kept(pro: $1) }
    var blocks: (PanelState) -> [PanelBlock] = { $0.blocks }
    var notes: (String, String, String) -> [String] = { PanelNotes.all(film: $0, paper: $1, size: $2) }
    var takeSize: (inout FilmParams, FilmFrame, PixelSize) -> Void = { $0.take(size: $1, photo: $2) }
    var heldToPhoto: (FilmParams, PixelSize) -> FilmParams = { $0.heldToItsPhoto($1) }
    // The film decides whether there is a print.
    var load: (inout FilmParams, String, StockCatalog) -> Void = { $0.load(film: $1, catalog: $2) }
    var printOn: (inout FilmParams, String, StockCatalog) -> Bool = { $0.print(on: $1, catalog: $2) }
    var held: (FrameEdit, StockCatalog) -> FrameEdit = { $0.heldToItsFilm(catalog: $1) }
    var wire: (FilmParams, StockCatalog) -> [String: ParamValue] = { $1.wire(for: $0) }
    var pairText: (FilmParams, StockCatalog) -> String = { $1.pairText($0) }
    // What the engine's client sends of a wire, and the pair a new frame takes.
    var step: (inout [String: ParamValue], [String: ParamValue]) -> [String: ParamValue] = { FilmParams.step(from: &$0, to: $1) }
    var newFramePair: (StockCatalog, String, String) -> (film: String, paper: String) = {
        $0.newFramePair(film: $1, paper: $2)
    }
    // What the pages say of black and white.
    var scales: (FilmParams, StockCatalog) -> EnlargerScales = { EnlargerScales.of($0, catalog: $1) }
    var whyNot: (String, String, StockCatalog) -> String? = { $2.whyNotPrinted(film: $0, on: $1) }
    var layered: (String, StockCatalog) -> Bool = { $1.grainIsLayered(on: $0) }
    var pairLoad: (inout StockPair, String, StockCatalog) -> Void = { $0.load(film: $1, catalog: $2) }
    var pairPrint: (inout StockPair, String, StockCatalog) -> Bool = { $0.print(on: $1, catalog: $2) }

    static var broken: [Rules] {
        var out: [Rules] = []
        func rule(_ name: String, _ change: (inout Rules) -> Void) {
            var r = Rules()
            r.name = name
            change(&r)
            out.append(r)
        }
        // The page.
        rule("Scene among basic's tabs") { r in r.tabs = { _ in DevelopTab.allCases } }
        rule("a page left on Scene when pro-control goes") { r in r.kept = { tab, _ in tab } }
        rule("a note that takes a line more than its place (Frame, 2026-10-09)") { r in
            r.blocks = { state in
                state.blocks.map { b in
                    guard state == .frame, b.name == "the size's note" else { return b }
                    return PanelBlock.note(b.name, PanelY.Frame.note, lines: 2)
                }
            }
        }
        rule("pro's Magenta 4 pt lower: out of the panel") { r in
            r.blocks = { state in
                state.blocks.map { b in
                    guard b.name == "Magenta's ruler" else { return b }
                    return PanelBlock(name: b.name, top: b.top + 4, bottom: b.bottom + 4, lane: b.lane)
                }
            }
        }
        rule("Sub-layers on the line of Grain's note") { r in
            r.blocks = { state in
                state.blocks.map { b in
                    guard b.name == "Sub-layers" else { return b }
                    return PanelBlock.label(b.name, PanelY.Effects.noteAfterOne + PanelY.Part.noteLead)
                }
            }
        }
        rule("a note's line too long for an iPhone SE") { r in
            r.notes = { film, paper, size in
                PanelNotes.all(film: film, paper: paper, size: size)
                    + ["The film's size is Film Edge's own format, \(size): grain and halation scale with it, and so does the film around it."]
            }
        }
        rule("a size card that changes the name and not the size that is sent") { r in r.takeSize = { p, f, _ in p.filmFrame = f.id } }
        rule("a size card that takes the frame's own long side, whatever the photograph's shape") { r in
            r.takeSize = { p, f, _ in p.filmFrame = f.id; p.sideLengthMM = f.short; p.filmFormatMM = max(f.long, f.short) }
        }
        rule("a film's length kept as another photograph made it (a new frame's 36 mm, a paste)") { r in r.heldToPhoto = { p, _ in p } }
        rule("a Custom frame's own length overwritten") { r in
            r.heldToPhoto = { p, photo in
                var q = p
                q.take(size: FilmFrame.named(p.filmFrame), photo: photo)
                return q
            }
        }
        // The slide rule.
        rule("a film card that sets the film and nothing else (the app until 2026-10-09)") { r in
            r.load = { p, id, _ in p.filmStock = id }
            r.held = { e, _ in e }
            r.wire = { p, _ in p.fullDelta }
        }
        rule("a paper taken under a slide") { r in
            r.printOn = { p, paper, _ in p.printStock = paper; p.scanFilm = false; return true }
            r.held = { e, _ in e }
            r.wire = { p, _ in p.fullDelta }
        }
        rule("an edit that enters as it is: a kept library's slide still printed") { r in r.held = { e, _ in e } }
        rule("the wire as the frame has it, whatever the film is") { r in r.wire = { p, _ in p.fullDelta } }
        rule("a slide named with a paper") { r in
            r.pairText = { p, c in c.stock(p.filmStock).map { "\($0.shortName) · \(c.stock(p.printStock)?.shortName ?? "")" } ?? "" }
        }
        rule("a negative that leaves a slide still scanned") { r in
            r.load = { p, id, c in
                let was = p.scanFilm
                p.load(film: id, catalog: c)
                p.scanFilm = was || p.scanFilm
            }
        }
        // Silver on silver.
        rule("a film card that keeps the paper, whatever the film (the slide rule alone)") { r in
            r.load = { p, id, c in p.filmStock = id; p.scanFilm = c.isSlide(id) }
        }
        rule("a paper of the other kind taken") { r in
            r.printOn = { p, paper, c in
                guard !c.isSlide(p.filmStock) else { return false }
                p.printStock = paper; p.scanFilm = false; p.digitalIntermediate = false
                return true
            }
        }
        rule("an edit that enters with a film and a paper of two kinds") { r in
            r.held = { e, c in
                var out = e
                out.params.scanFilm = e.params.scanFilm || c.isSlide(e.params.filmStock)
                return out
            }
        }
        // The wire as the app builds it, less one of a silver pair's own lines.
        func wire(without change: @escaping (inout [String: ParamValue], FilmParams, StockCatalog) -> Void) -> (FilmParams, StockCatalog) -> [String: ParamValue] {
            { p, c in
                let held = p.heldToItsFilm(catalog: c)
                var w = c.wire(for: p)
                change(&w, held, c)
                return w
            }
        }
        rule("a black-and-white film's grain in three layers") { r in
            r.wire = wire { w, held, c in if c.isMonochrome(held.filmStock) { w["grain_sublayers_active"] = held.fullDelta["grain_sublayers_active"] } }
        }
        rule("a black-and-white film's own grain forgotten: the engine's 1 for all four") { r in
            r.wire = wire { w, held, c in if c.isMonochrome(held.filmStock) { w["grain_amount"] = held.fullDelta["grain_amount"] } }
        }
        rule("Extended Dynamic Range sent for a silver paper, which the engine refuses") { r in
            r.wire = wire { w, held, c in if c.isMonochrome(held.printStock) { w["extended_dynamic_range"] = held.fullDelta["extended_dynamic_range"] } }
        }
        rule("a silver pair sent with no filter pack: the pair before it prints it") { r in
            r.wire = wire { w, _, _ in for key in packKeys { w[key] = nil } }
        }
        rule("the silver paper's pack sent for every frame: every colour frame's wire moved") { r in
            r.wire = wire { w, _, c in
                guard let pack = c.papers.first(where: \.isMonochrome)?.neutralPack, pack.count == 3 else { return }
                for (key, value) in zip(packKeys, pack) { w[key] = .double(value) }
            }
        }
        rule("the enlarger's shifts dropped on a silver print: its grade out of reach") { r in
            r.wire = wire { w, held, c in
                guard c.isMonochrome(held.printStock) else { return }
                w["y_filter_shift"] = .double(0)
                w["m_filter_shift"] = .double(0)
            }
        }
        rule("the engine's client as it was: a field that is as it was last sent is not sent") { r in
            r.step = { applied, now in
                let delta = now.filter { applied[$0.key] != $0.value }
                applied.merge(delta) { _, new in new }
                return delta
            }
        }
        rule("a new frame on the pair as chosen: a film alone, with the paper of the last one") { r in r.newFramePair = { _, film, paper in (film, paper) } }
        // What the pages say of black and white.
        rule("a silver print's rulers still named for a colour (the page until 2026-10-09)") { r in r.scales = { _, _ in .colour } }
        rule("a colour print's rulers named for a grade") { r in r.scales = { _, _ in .grade } }
        rule("a scanned black-and-white negative's rulers named for a grade it has no paper for") { r in
            r.scales = { p, c in c.isMonochrome(p.filmStock) ? .grade : .colour }
        }
        rule("a paper of the other kind shown as one to choose (the page until 2026-10-09)") { r in r.whyNot = { _, _, _ in nil } }
        rule("the silver paper waiting under its own films") { r in
            r.whyNot = { film, paper, c in c.isMonochrome(paper) ? StockCatalog.silverPaperWaits : c.whyNotPrinted(film: film, on: paper) }
        }
        rule("a paper that waits for the other paper's reason") { r in
            r.whyNot = { film, paper, c in
                c.whyNotPrinted(film: film, on: paper).map { $0 == StockCatalog.colourPaperWaits ? StockCatalog.silverPaperWaits : StockCatalog.colourPaperWaits }
            }
        }
        rule("Sub-layers open on a black-and-white film, where it moves nothing") { r in r.layered = { _, _ in true } }
        rule("Sub-layers standing down on every film") { r in r.layered = { _, _ in false } }
        rule("the picker's film row that keeps a paper that cannot print the film") { r in
            r.pairLoad = { pair, id, _ in pair.film = id }
        }
        rule("the picker's paper row that takes any paper: the gate in the dimming alone") { r in
            r.pairPrint = { pair, id, _ in pair.paper = id; return true }
        }
        return out
    }
}

func tabChecks(_ c: inout Checker, _ rules: Rules) {
    c.expect(rules.tabs(false) == [.film, .frame, .print, .effects], "basic: Film, Frame, Print, Effects")
    c.expect(rules.tabs(true) == [.film, .frame, .print, .scene, .effects], "pro-control: Scene, between Print and Effects")
    for tab in DevelopTab.allCases {
        for pro in [false, true] {
            c.expect(rules.tabs(pro).contains(rules.kept(tab, pro)), "from \(tab.title), pro \(pro): the page stands on a tab that is shown")
        }
        c.expect(rules.kept(tab, true) == tab, "pro-control moves the page nowhere: \(tab.title)")
    }
    c.expect(rules.kept(.scene, false) == .print, "Scene goes with pro-control, and the page is on Print")
}

func panelChecks(_ c: inout Checker, _ rules: Rules) {
    let states = PanelState.all
    c.expect(Set(states.map(\.tab)) == Set(DevelopTab.allCases), "a state for every tab")
    c.expect(Set(states).count == states.count, "each state once")
    for page in EffectsPage.allCases { c.expect(states.contains(.effectsPro(page)), "pro's \(page.title) page is held") }
    for tool in EnlargerTool.allCases { c.expect(states.contains(.print(pro: true, tool: tool)), "pro's \(tool.title) is held") }
    for tool in SceneTool.allCases { c.expect(states.contains(.scene(tool)), "Scene's \(tool.title) is held") }
    for state in states {
        let parts = rules.blocks(state)
        c.expect(parts.count >= 3, "\(state.name): its parts are named")
        let faults = state.conflicts(blocks: parts)
        c.expect(faults.isEmpty, faults.first ?? "")
    }
}

/// A line's width as the page sets it: the system's font at the notes' size, medium (`Theme.Font.ui`).
func width(of line: String, size: CGFloat = PanelNotes.size) -> CGFloat {
    (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium)]).width
}

func noteChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    let margin: CGFloat = 16
    // The narrowest page a note is set on (375 pt), and the drawings' own (393 pt).
    let narrow: CGFloat = 375 - 2 * margin
    let drawn: CGFloat = 393 - 2 * margin
    // Every size's name a note can carry: the film's sizes, and a film edge's formats.
    let sizes = FilmFrame.all.map(\.id) + FilmEdgeFormat.allCases.map(\.label)
    let films = catalog.films.map(\.shortName), papers = catalog.papers.map(\.shortName)
    c.expect(!films.isEmpty && !papers.isEmpty, "the catalogue's names are read")
    var widest: (line: String, width: CGFloat) = ("", 0)
    var checked = Set<String>()
    for film in films {
        for paper in papers {
            for size in sizes {
                for line in rules.notes(film, paper, size) where checked.insert(line).inserted {
                    c.expect(!line.contains("\n") && !line.isEmpty, "one element is one line: \"\(line)\"")
                    let w = width(of: line)
                    if w > widest.width { widest = (line, w) }
                    // Set on one line and never wrapped: it has to fit one, at a size that still reads.
                    c.expect(w * PanelNotes.leastScale <= narrow,
                             "\"\(line)\" is \(Int(w)) pt: too long for an iPhone SE's \(Int(narrow)) even at \(PanelNotes.leastScale) of its size")
                }
            }
        }
    }
    // The drawings' own frame, at the drawings' own size: nothing set smaller than drawn.
    for line in rules.notes("Portra 400", "Portra Endura", "135") {
        c.expect(width(of: line) <= drawn, "\"\(line)\" is \(Int(width(of: line))) pt of the drawn page's \(Int(drawn))")
    }
    if !c.quiet { print("  the widest line, \(Int(widest.width)) pt of \(Int(drawn)): \"\(widest.line)\"") }
}

/// Frame's size cards: the name on the card is the size the engine is sent.
func sizeChecks(_ c: inout Checker, _ rules: Rules) {
    let landscape = PixelSize(width: 6000, height: 4000), upright = PixelSize(width: 4000, height: 6000)
    let phone = PixelSize(width: 4032, height: 3024), square = PixelSize(width: 4000, height: 4000)
    // The frame, the photograph, and the long edge the wire carries, in millimetres.
    let cases: [(String, PixelSize, Double, Double)] = [
        ("135", landscape, 24, 36), ("135", upright, 24, 36), ("135", phone, 24, 32), ("135", square, 24, 24),
        ("120", landscape, 56, 84), ("120", phone, 56, 56.0 * 4 / 3), ("120", square, 56, 56),
        ("110", landscape, 13, 19.5), ("APS", landscape, 16.7, 25.05),
    ]
    for (id, photo, side, long) in cases {
        var p = FilmParams()
        // From another size, so that taking this one is a change.
        rules.takeSize(&p, .named(id == "135" ? "120" : "135"), photo)
        let before = p
        rules.takeSize(&p, .named(id), photo)
        let what = "\(id) on a \(photo.width) × \(photo.height) photograph"
        c.expect(p.filmFrame == id, "\(what): the frame is named \(id)")
        c.expect(abs(p.sideLengthMM - side) < 0.001, "\(what): its short side is \(side) mm, got \(p.sideLengthMM)")
        c.expect(abs(p.filmFormatMM - long) < 0.001, "\(what): the long edge sent is \(long) mm, got \(p.filmFormatMM)")
        if case .double(let sent)? = p.fullDelta["film_format_mm"] {
            c.expect(abs(sent - long) < 0.001, "\(what): the wire carries \(long) mm, got \(sent)")
        } else {
            c.expect(false, "\(what): the wire carries the film's long edge")
        }
        // Grain and halation are the film's, so another size develops again.
        c.expect(p.delta(from: before).layers.contains(.shoot), "\(what): taking it asks for a develop")
    }
    // A frame measured by its long side keeps that side.
    var long = FilmParams()
    long.filmSide = FilmSide.long.rawValue
    rules.takeSize(&long, .named("120"), landscape)
    c.expect(long.sideLengthMM == FilmFrame.named("120").long && long.filmFormatMM == long.sideLengthMM,
             "measured by its long side, 120 is \(FilmFrame.named("120").long) mm long whatever the photograph")
    // An edit that enters a frame takes that frame's photograph: a new frame's defaults, a paste.
    let fresh = FilmParams()
    c.expect(rules.heldToPhoto(fresh, landscape) == fresh, "a new frame of a 3:2 photograph is 24 × 36 on 135, as its defaults say")
    c.expect(rules.heldToPhoto(fresh, phone).filmFormatMM == 32, "a new frame of a phone's 4:3 photograph is 32 mm long on 135, not the defaults' 36")
    var onLandscape = FilmParams()
    rules.takeSize(&onLandscape, .named("120"), landscape)
    let pasted = rules.heldToPhoto(onLandscape, square)
    c.expect(pasted.filmFrame == "120" && pasted.filmFormatMM == 56, "120 pasted from a 3:2 picture onto a square one is 56 mm long there, not 84")
    c.expect(rules.heldToPhoto(pasted, square) == pasted, "held once is held")
    var custom = FilmParams()
    custom.filmFrame = FilmFrame.custom.id
    custom.sideLengthMM = 40
    custom.filmFormatMM = 77
    c.expect(rules.heldToPhoto(custom, phone) == custom, "a Custom frame, which the page does not offer, keeps its own length")
    var cine = FilmParams()
    cine.filmFrame = "Super 35"
    cine.filmFormatMM = 24.89
    c.expect(rules.heldToPhoto(cine, phone) == cine, "a cine frame keeps its own length")
    c.expect(rules.heldToPhoto(fresh, PixelSize(width: 0, height: 0)) == fresh, "with no photograph to measure, nothing is changed")
    // Every size the page offers is one the catalogue of frames has.
    for id in ["110", "APS", "135", "120"] { c.expect(FilmFrame.named(id).id == id, "\(id) is a still frame the page can offer") }
}

// MARK: - a slide is scanned

func scanned(_ wire: [String: ParamValue]) -> Bool? {
    if case .bool(let on)? = wire["scan_film"] { return on }
    return nil
}

func slideChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    // Over the colour stocks, where any paper prints any negative. What a black-and-white film and a
    // silver paper change of this is `silverChecks`'.
    let slides = catalog.films.filter(\.isPositive), negatives = catalog.films.filter { !$0.isPositive && !$0.isMonochrome }
    let papers = catalog.papers.filter { !$0.isMonochrome }
    c.expect(slides.allSatisfy { !$0.isMonochrome }, "every slide film is a colour film: the checks below take it so")
    // Without these the checks below hold nothing.
    c.expect(slides.count >= 2 && negatives.count >= 10 && papers.count >= 4,
             "the catalogue has slide films (\(slides.count)), negatives (\(negatives.count)) and papers (\(papers.count))")
    guard let negative = negatives.first, let paper = papers.first, let other = papers.last, paper.id != other.id else { return }

    for slide in slides {
        // 1. The pick, from a frame printed on each paper in turn.
        for kept in papers {
            var p = FilmParams()
            rules.load(&p, negative.id, catalog)
            _ = rules.printOn(&p, kept.id, catalog)
            c.expect(!p.scanFilm && p.printStock == kept.id, "\(negative.shortName) prints on \(kept.shortName)")
            rules.load(&p, slide.id, catalog)
            c.expect(p.filmStock == slide.id && p.scanFilm, "\(slide.shortName), loaded over \(kept.shortName): scanned")
            c.expect(scanned(rules.wire(p, catalog)) == true, "\(slide.shortName) over \(kept.shortName): the engine is told to scan")
            c.expect(p.printStock == kept.id, "\(slide.shortName): the paper the frame had, \(kept.shortName), waits")
            // A paper card under a slide.
            let took = rules.printOn(&p, other.id, catalog)
            c.expect(!took && p.scanFilm && p.printStock == kept.id, "\(slide.shortName): \(other.shortName) is refused, and nothing changed")
            c.expect(scanned(rules.wire(p, catalog)) == true, "\(slide.shortName): still scanned after a paper was tapped")
            let line = rules.pairText(p, catalog)
            c.expect(line == "\(slide.shortName) · scanned", "\(slide.shortName) is named \"\(line)\"")
            c.expect(!papers.contains { line.contains($0.shortName) }, "\(slide.shortName)'s line names no paper: \"\(line)\"")
            // Selecting a negative again brings its recommended paper.
            rules.load(&p, negative.id, catalog)
            let recommended = catalog.ownPaper(of: negative.id) ?? kept.id
            c.expect(!p.scanFilm && p.printStock == recommended && scanned(rules.wire(p, catalog)) == false,
                     "\(negative.shortName) after \(slide.shortName): printed again, on its recommended paper")
            c.expect(rules.pairText(p, catalog) == catalog.pairText(film: negative.id, paper: recommended), "and named with its paper")
        }
        // 2. An edit that enters as an older build kept it: the film set, the print left on.
        var old = FrameEdit()
        old.params.filmStock = slide.id
        old.params.printStock = paper.id
        old.params.scanFilm = false
        let entered = rules.held(old, catalog)
        c.expect(entered.params.scanFilm, "\(slide.shortName), as an older build kept it: scanned when it enters")
        c.expect(entered.params.printStock == paper.id && entered.params.filmStock == slide.id, "and nothing else of it changed")
        c.expect(rules.held(entered, catalog) == entered, "held once is held")
        // 3. The wire, whatever the edit says.
        c.expect(scanned(rules.wire(old.params, catalog)) == true, "\(slide.shortName), still marked to print: the engine is told to scan")
    }
    // A negative keeps what it has: printed, or scanned by a desktop edit.
    for film in negatives {
        var e = FrameEdit()
        rules.load(&e.params, film.id, catalog)
        e.params.printStock = paper.id
        c.expect(rules.held(e, catalog) == e && scanned(rules.wire(e.params, catalog)) == false, "\(film.shortName) is printed, and stays so")
        e.params.scanFilm = true
        c.expect(rules.held(e, catalog) == e && scanned(rules.wire(e.params, catalog)) == true,
                 "\(film.shortName), scanned by a desktop edit: carried as it is")
        c.expect(rules.pairText(e.params, catalog) == "\(film.shortName) · scanned", "and named so")
        c.expect(rules.printOn(&e.params, other.id, catalog) && !e.params.scanFilm && e.params.printStock == other.id,
                 "\(film.shortName): a paper prints it again")
    }
    // A film the catalogue does not know is nobody's slide.
    var unknown = FilmParams()
    rules.load(&unknown, "not_a_film", catalog)
    c.expect(!unknown.scanFilm, "a film the catalogue does not have is not taken for a slide")
}

// MARK: - silver on silver, colour on colour

let packKeys = ["c_filter_neutral", "m_filter_neutral", "y_filter_neutral"]

func number(_ wire: [String: ParamValue], _ key: String) -> Double? {
    if case .double(let v)? = wire[key] { return v }
    return nil
}

func flag(_ wire: [String: ParamValue], _ key: String) -> Bool? {
    if case .bool(let v)? = wire[key] { return v }
    return nil
}

func text(_ wire: [String: ParamValue], _ key: String) -> String? {
    if case .string(let v)? = wire[key] { return v }
    return nil
}

/// The engine's session as it treats the enlarger's filter pack, **measured on the engine on 2026-10-09**
/// (`UPSTREAM.md`, the black-and-white sync): what is set stays set; a new film or paper takes the pair's
/// own pack where the engine's table has a row for it — every colour pair — and keeps the session's where
/// it has none, which is a silver paper; a pack that is sent is the pack.
struct EnlargerSession {
    var set: [String: ParamValue] = [:]
    /// Whose pack the enlarger holds.
    var pack = "none"
    mutating func apply(_ delta: [String: ParamValue], catalog: StockCatalog) {
        set.merge(delta) { _, new in new }
        if delta["film_stock"] != nil || delta["print_stock"] != nil, let paper = text(set, "print_stock"), !catalog.isMonochrome(paper) {
            pack = "the engine's own for \(text(set, "film_stock") ?? "?") on \(paper)"
        }
        if packKeys.contains(where: { delta[$0] != nil }) { pack = "sent: \(packKeys.map { number(set, $0) ?? -1 })" }
    }
}

func silverChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    let silverFilms = catalog.films.filter(\.isMonochrome), silverPapers = catalog.papers.filter(\.isMonochrome)
    let colourFilms = catalog.films.filter { !$0.isMonochrome }, colourPapers = catalog.papers.filter { !$0.isMonochrome }
    let negatives = colourFilms.filter { !$0.isPositive }, slides = colourFilms.filter(\.isPositive)
    // Without these the checks below hold nothing.
    c.expect(silverFilms.count >= 4 && silverPapers.count >= 1 && negatives.count >= 10 && colourPapers.count >= 4 && slides.count >= 2,
             "the catalogue has black-and-white films (\(silverFilms.count)) and a silver paper (\(silverPapers.count)), beside the colour stocks")
    guard let silver = silverPapers.first, let negative = negatives.first, let colour = colourPapers.first, silverFilms.count >= 3 else { return }
    let pack = silver.neutralPack ?? []
    c.expect(pack.count == 3, "\(silver.shortName) carries its filter pack: the enlarger's C, M and Y")
    for film in silverFilms {
        c.expect(!film.isPositive && !film.isCine, "\(film.shortName) is a still negative")
        c.expect(film.targetPrint == silver.id, "\(film.shortName) is made for \(silver.shortName)")
        c.expect(film.grain.map { $0 != 1 && EffectStrengths.grainRange.contains($0) } == true,
                 "\(film.shortName) has a grain of its own, inside the wire's range: \(film.grain.map { "\($0)" } ?? "none")")
    }
    for stock in colourFilms + colourPapers {
        c.expect(stock.monochrome == nil && stock.grain == nil && stock.neutralPack == nil,
                 "\(stock.shortName), a colour stock, carries nothing of black and white's")
    }

    // 1. The pick.
    for film in silverFilms {
        for kept in colourPapers {
            var p = FilmParams()
            rules.load(&p, negative.id, catalog)
            _ = rules.printOn(&p, kept.id, catalog)
            rules.load(&p, film.id, catalog)
            c.expect(p.filmStock == film.id && p.printStock == silver.id && !p.scanFilm,
                     "\(film.shortName), loaded over \(kept.shortName): printed, on \(silver.shortName)")
            c.expect(rules.pairText(p, catalog) == "\(film.shortName) · \(silver.shortName)", "and named with it")
            // A colour paper's card under a black-and-white film.
            let before = p
            c.expect(!rules.printOn(&p, kept.id, catalog) && p == before, "\(film.shortName): \(kept.shortName) is refused, and nothing changed")
        }
        var p = FilmParams()
        rules.load(&p, film.id, catalog)
        c.expect(rules.printOn(&p, silver.id, catalog) && p.printStock == silver.id && !p.scanFilm, "\(film.shortName): its own paper's card is taken")
        // Another black-and-white film keeps the paper, as any negative keeps its frame's.
        for next in silverFilms where next.id != film.id {
            var q = p
            rules.load(&q, next.id, catalog)
            c.expect(q.printStock == silver.id && !q.scanFilm, "\(next.shortName) after \(film.shortName): on the same paper")
        }
        // Back to colour: the silver paper cannot stay, and the film's own paper comes with it.
        for back in negatives {
            var q = p
            rules.load(&q, back.id, catalog)
            c.expect(catalog.stock(q.printStock)?.isPaper == true && !catalog.isMonochrome(q.printStock) && !q.scanFilm,
                     "\(back.shortName) after \(film.shortName): printed, on a colour paper")
            if let own = catalog.ownPaper(of: back.id).flatMap({ catalog.stock($0) }), !own.isMonochrome {
                c.expect(q.printStock == own.id, "\(back.shortName) after \(film.shortName): on the paper it was made for, \(own.shortName)")
            }
            // The silver paper's card under a colour negative.
            let before = q
            c.expect(!rules.printOn(&q, silver.id, catalog) && q == before, "\(back.shortName): \(silver.shortName) is refused, and nothing changed")
        }
        // A slide after it is scanned, and what waits under it is a paper a colour negative prints on.
        for slide in slides {
            var q = p
            rules.load(&q, slide.id, catalog)
            c.expect(q.scanFilm && !catalog.isMonochrome(q.printStock), "\(slide.shortName) after \(film.shortName): scanned, a colour paper waiting")
            rules.load(&q, film.id, catalog)
            c.expect(!q.scanFilm && q.printStock == silver.id, "and \(film.shortName) again: printed, on \(silver.shortName)")
        }
    }

    // 2. An edit that enters with a film and a paper of two kinds: the film stays, its paper comes.
    for film in silverFilms {
        for kept in colourPapers {
            var old = FrameEdit()
            old.params.filmStock = film.id
            old.params.printStock = kept.id
            let entered = rules.held(old, catalog)
            c.expect(entered.params.filmStock == film.id && entered.params.printStock == silver.id,
                     "\(film.shortName), carried with \(kept.shortName): enters on \(silver.shortName)")
            var back = entered
            back.params.printStock = kept.id
            c.expect(back == old, "and nothing else of it changed")
            c.expect(rules.held(entered, catalog) == entered, "held once is held")
        }
    }
    for film in colourFilms {
        var old = FrameEdit()
        old.params.filmStock = film.id
        old.params.printStock = silver.id
        let entered = rules.held(old, catalog)
        c.expect(entered.params.filmStock == film.id && catalog.stock(entered.params.printStock)?.isPaper == true
                 && !catalog.isMonochrome(entered.params.printStock), "\(film.shortName), carried with \(silver.shortName): enters on a colour paper")
        // A colour pair is nobody's to change.
        for kept in colourPapers {
            var e = FrameEdit()
            e.params.filmStock = film.id
            e.params.printStock = kept.id
            e.params.scanFilm = film.isPositive
            c.expect(rules.held(e, catalog) == e, "\(film.shortName) with \(kept.shortName) enters as it is")
        }
    }

    // 3. The wire.
    for film in silverFilms {
        var p = FilmParams()
        rules.load(&p, film.id, catalog)
        // Everything a silver pair overrides, set as a colour frame can have it.
        p.grainActive = true
        p.effects.grainLayered = true
        p.extendedDynamicRange = true
        p.yFilterShift = 0.25
        p.mFilterShift = -0.5
        let own = film.grain ?? 1
        for strength in [0, 0.5, 1, 1.5, 2] {
            p.effects.grain = strength
            let w = rules.wire(p, catalog)
            c.expect(flag(w, "grain_active") == true && flag(w, "grain_sublayers_active") == false, "\(film.shortName): its grain is one layer, whatever the setting")
            let want = min(max(strength * own, EffectStrengths.grainRange.lowerBound), EffectStrengths.grainRange.upperBound)
            c.expect(abs((number(w, "grain_amount") ?? -1) - want) < 1e-9,
                     "\(film.shortName), Grain \(strength): \(want) is sent, its own \(own) times the strength inside the wire's range; got \(number(w, "grain_amount") ?? -1)")
        }
        p.effects.grain = 1
        let w = rules.wire(p, catalog)
        c.expect(text(w, "film_stock") == film.id && text(w, "print_stock") == silver.id && flag(w, "scan_film") == false, "\(film.shortName) is sent to be printed on \(silver.shortName)")
        c.expect(flag(w, "extended_dynamic_range") == false, "\(film.shortName): no Extended Dynamic Range is asked of \(silver.shortName), whatever the frame says")
        c.expect(packKeys.map { number(w, $0) } == pack.map(Optional.some), "\(film.shortName): \(silver.shortName)'s filter pack is sent, \(pack)")
        c.expect(number(w, "y_filter_shift") == 0.25 && number(w, "m_filter_shift") == -0.5,
                 "\(film.shortName): the enlarger's two shifts are sent as the frame has them — on this paper they are its grade")
        // Everything else is the frame's own.
        var rest = w
        for key in packKeys + ["grain_sublayers_active", "grain_amount", "extended_dynamic_range"] { rest[key] = nil }
        var mine = p.fullDelta
        for key in ["grain_sublayers_active", "grain_amount", "extended_dynamic_range"] { mine[key] = nil }
        c.expect(rest == mine, "\(film.shortName): and every other field is the frame's own")
        // An edit still carrying a colour paper is sent as the pair it is held to.
        var carried = p
        carried.printStock = colour.id
        c.expect(rules.wire(carried, catalog) == w, "\(film.shortName), still marked for \(colour.shortName): sent as on its own paper")
        // A black-and-white negative a desktop edit scans keeps its film's grain.
        var scannedOnce = p
        scannedOnce.scanFilm = true
        let ws = rules.wire(scannedOnce, catalog)
        c.expect(flag(ws, "scan_film") == true && flag(ws, "grain_sublayers_active") == false && number(ws, "grain_amount") == number(w, "grain_amount"),
                 "\(film.shortName), scanned by a desktop edit: carried so, with its grain as one layer")
    }
    // No colour frame's wire moves: each is `fullDelta` of the frame, field for field, as before black and white.
    for film in colourFilms {
        for paper in colourPapers {
            var p = FilmParams()
            p.filmStock = film.id
            p.printStock = paper.id
            p.scanFilm = film.isPositive
            p.grainActive = true
            p.effects.grainLayered = true
            p.effects.grain = 1.5
            p.extendedDynamicRange = true
            p.yFilterShift = 0.25
            p.mFilterShift = -0.5
            c.expect(rules.wire(p, catalog) == p.fullDelta, "\(film.shortName) on \(paper.shortName): the wire is the frame's own, field for field")
        }
        var p = FilmParams()
        p.filmStock = film.id
        p.printStock = silver.id
        p.scanFilm = film.isPositive
        let w = rules.wire(p, catalog)
        c.expect(packKeys.allSatisfy { w[$0] == nil } && text(w, "print_stock").map { !catalog.isMonochrome($0) } == true,
                 "\(film.shortName), still marked for \(silver.shortName): sent on a colour paper, with no pack")
    }

    // 4. What the engine's client sends of it. The films and the wire here are the app's own, so that
    //    what is held is the step alone.
    var applied: [String: ParamValue] = [:]
    var live = EnlargerSession()
    var p = FilmParams()
    let walk = [negative.id, silverFilms[0].id, negatives[negatives.count - 1].id, silverFilms[1].id, silverFilms[0].id,
                slides[0].id, silverFilms[2].id, negative.id, silverFilms[2].id]
    for (i, id) in walk.enumerated() {
        p.load(film: id, catalog: catalog)
        let now = catalog.wire(for: p)
        let delta = rules.step(&applied, now)
        live.apply(delta, catalog: catalog)
        var fresh = EnlargerSession()
        fresh.apply(now, catalog: catalog)
        let name = catalog.stock(id)?.shortName ?? id
        c.expect(live.pack == fresh.pack, "step \(i + 1), \(name): the session's enlarger holds \(live.pack); opened fresh it would hold \(fresh.pack)")
        c.expect(now.allSatisfy { live.set[$0.key] == $0.value }, "step \(i + 1), \(name): every field of the frame is the session's")
        c.expect(delta.allSatisfy { now[$0.key] == $0.value } && (i == 0 || delta.count < now.count), "step \(i + 1), \(name): what is sent is the frame's, and only what changed")
        c.expect(rules.step(&applied, now).isEmpty, "step \(i + 1), \(name): asked again with nothing changed, nothing is sent")
    }

    // 5. The pair a new frame takes.
    for film in silverFilms {
        let held = rules.newFramePair(catalog, film.id, colour.id)
        c.expect(held.film == film.id && held.paper == silver.id, "\(film.shortName) chosen alone for new frames brings \(silver.shortName)")
    }
    for film in colourFilms {
        for paper in colourPapers {
            let pair = rules.newFramePair(catalog, film.id, paper.id)
            c.expect(pair.film == film.id && pair.paper == paper.id, "\(film.shortName) with \(paper.shortName): a new frame's pair as it was chosen")
        }
        let pair = rules.newFramePair(catalog, film.id, silver.id)
        c.expect(pair.film == film.id && !catalog.isMonochrome(pair.paper), "\(film.shortName) chosen after a black-and-white film: a new frame's paper is a colour one")
    }
    let unknown = rules.newFramePair(catalog, "not_a_film", "not_a_paper")
    c.expect(unknown.film == "not_a_film" && unknown.paper == "not_a_paper", "a pair the catalogue does not know is left as it is")
}

// MARK: - what the pages say of black and white

/// The Print tab's cards and rulers, Grain's Sub-layers and the picker for new frames: each asked what
/// the page asks (`whyNotPrinted`, `EnlargerScales`, `grainIsLayered`, `StockPair`), and held against
/// what the model does — `FilmParams.print(on:)`, `load(film:)` and the wire — so that a page can dim
/// nothing the model would take, and offer nothing it would refuse.
func pageChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    let films = catalog.films, papers = catalog.papers
    let silverFilms = films.filter(\.isMonochrome), silverPapers = papers.filter(\.isMonochrome)
    c.expect(silverFilms.count >= 4 && silverPapers.count >= 1 && films.count > silverFilms.count && papers.count > silverPapers.count,
             "the catalogue has stocks of both kinds for the pages to tell apart")

    // 1. A paper's card. It waits exactly where the model refuses the paper — under a slide every
    //    paper is refused, and the row says that as one — and says why in the desktop's words.
    var waiting = 0
    for film in films {
        for paper in papers {
            var p = FilmParams()
            p.load(film: film.id, catalog: catalog)
            let took = p.print(on: paper.id, catalog: catalog)
            let why = rules.whyNot(film.id, paper.id, catalog)
            if film.isPositive {
                c.expect(!took, "\(film.shortName), a slide: \(paper.shortName) is refused, as every paper is")
                continue
            }
            c.expect((why == nil) == took, "\(film.shortName): \(paper.shortName)'s card \(why == nil ? "is open" : "waits"), and the model \(took ? "takes" : "refuses") the paper")
            guard let why else { continue }
            waiting += 1
            c.expect(why == (film.isMonochrome ? "a colour paper: a black-and-white film prints on a black-and-white paper"
                                               : "a black-and-white paper: choose a black-and-white film to print on it"),
                     "\(film.shortName), \(paper.shortName): the card says why in the desktop's words, got \"\(why)\"")
            c.expect(film.isMonochrome != paper.isMonochrome, "\(film.shortName), \(paper.shortName): a card waits only for a film of the other kind")
        }
        // Its own paper never waits.
        if let own = catalog.ownPaper(of: film.id) { c.expect(rules.whyNot(film.id, own, catalog) == nil, "\(film.shortName): its own paper's card is open") }
    }
    c.expect(waiting > 0, "some card waits: the checks above held something")

    // 2. The enlarger's two rulers.
    for film in films {
        for paper in papers {
            var p = FilmParams()
            p.filmStock = film.id
            p.printStock = paper.id
            p = p.heldToItsFilm(catalog: catalog)
            let s = rules.scales(p, catalog)
            if film.isMonochrome && catalog.isMonochrome(p.printStock) && !p.scanFilm {
                c.expect(s.yellow == "→ softer" && s.magenta == "→ harder", "\(film.shortName) on its paper: Yellow is → softer and Magenta → harder, got \(s.yellow), \(s.magenta)")
                c.expect(!s.tinted, "\(film.shortName) on its paper: the scales carry no colour")
                c.expect(s.tool != EnlargerScales.colour.tool, "\(film.shortName) on its paper: pro's tool is not named Colour")
            } else {
                // Every colour frame's Print tab, exactly as the drawing has it.
                c.expect(s == EnlargerScales(yellow: "→ blue", magenta: "→ green", tinted: true, tool: "Colour"),
                         "\(film.shortName) on \(paper.shortName): the rulers are the drawing's, → blue and → green, tinted")
            }
        }
    }
    // A black-and-white negative a desktop edit scans has no paper, and no grade.
    for film in silverFilms {
        var p = FilmParams()
        p.load(film: film.id, catalog: catalog)
        p.scanFilm = true
        c.expect(rules.scales(p, catalog) == .colour, "\(film.shortName), scanned: no grade is named where nothing is printed")
    }
    for tool in EnlargerTool.allCases where tool != .colour {
        c.expect(tool.title(on: .grade) == tool.title && tool.title(on: .colour) == tool.title, "\(tool.title) is named the same on every paper")
    }
    c.expect(EnlargerTool.colour.title(on: .colour) == EnlargerTool.colour.title, "the drawing's Colour, on a colour print")
    // The words beside a ruler's name are short ones: none longer than the drawing's own.
    for word in [EnlargerScales.grade.yellow, EnlargerScales.grade.magenta, EnlargerScales.grade.tool] {
        c.expect(width(of: word) <= width(of: "→ green") + 8, "\"\(word)\" takes no more room than the drawing's word")
    }

    // 3. Grain's Sub-layers: open exactly where turning it over changes what the engine is sent.
    for film in films {
        var on = FilmParams()
        on.load(film: film.id, catalog: catalog)
        on.grainActive = true
        on.effects.grainLayered = true
        var off = on
        off.effects.grainLayered = false
        let moves = catalog.wire(for: on) != catalog.wire(for: off)
        c.expect(rules.layered(film.id, catalog) == moves, "\(film.shortName): Sub-layers is \(rules.layered(film.id, catalog) ? "open" : "standing down"), and the switch \(moves ? "changes" : "does not change") the wire")
        c.expect(PanelNotes.subLayers(layered: true, filmIsLayered: rules.layered(film.id, catalog)) == (moves ? "three, as the film has" : "one layer"),
                 "\(film.shortName): the line beside it says what is sent")
    }
    c.expect(PanelNotes.subLayers(layered: false, filmIsLayered: true) == "one layer", "one layer, where the frame says so")

    // 4. The pair chosen for new frames: the picker's rows.
    // From a colour negative and from a slide, on the first and the last paper that prints them.
    let colourPapers = papers.filter { !$0.isMonochrome }
    let starts = [films.first { !$0.isMonochrome && !$0.isPositive }, films.first(where: \.isPositive)].compactMap { $0 }
    c.expect(starts.count == 2 && colourPapers.count >= 2, "a negative, a slide and two colour papers to start the picker from")
    for start in starts {
        for kept in [colourPapers.first, colourPapers.last].compactMap({ $0 }) {
            let from = StockPair(film: start.id, paper: kept.id)
            for film in films {
                // Every film is taken, on the paper a frame would have.
                var held = from
                rules.pairLoad(&held, film.id, catalog)
                var frame = FilmParams()
                frame.filmStock = start.id
                frame.printStock = kept.id
                frame.load(film: film.id, catalog: catalog)
                c.expect(held.film == film.id && held.paper == frame.printStock && catalog.canPrint(film: held.film, on: held.paper),
                         "\(film.shortName) over \(kept.shortName): the pair is \(held.paper), as a frame's would be (\(frame.printStock))")
                // A paper's row, under that film: taken exactly where a frame takes it.
                for paper in papers {
                    var chosen = held
                    var onFrame = frame
                    let tookPaper = rules.pairPrint(&chosen, paper.id, catalog)
                    c.expect(tookPaper == onFrame.print(on: paper.id, catalog: catalog), "\(film.shortName): \(paper.shortName)'s row is \(tookPaper ? "taken" : "refused"), and a frame's card is not")
                    c.expect(chosen.film == film.id && chosen.paper == (tookPaper ? paper.id : held.paper), "and the pair is \(tookPaper ? "that paper's" : "as it was")")
                    c.expect(film.isPositive || catalog.canPrint(film: chosen.film, on: chosen.paper), "\(film.shortName) with \(chosen.paper): a pair a frame could have")
                }
            }
        }
    }
}

@main
struct DevelopSelfTest {
    @MainActor
    static func main() async {
        // The bundle's own catalogue, from the repository: tools/../Resources.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let catalog = StockCatalog(contentsOf: root.appendingPathComponent("Resources/StockCatalog.json")) else {
            print("develop checks: no catalogue at Resources/StockCatalog.json")
            exit(1)
        }
        func run(_ rules: Rules, quiet: Bool) async -> Checker {
            var c = Checker(quiet: quiet)
            tabChecks(&c, rules)
            panelChecks(&c, rules)
            noteChecks(&c, rules, catalog: catalog)
            sizeChecks(&c, rules)
            slideChecks(&c, rules, catalog: catalog)
            silverChecks(&c, rules, catalog: catalog)
            pageChecks(&c, rules, catalog: catalog)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let rules = Rules.broken
            for rule in rules {
                if await run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("develop self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        let c = await run(Rules(), quiet: false)
        print("develop checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
