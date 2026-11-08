//  stock_previews_selftest.swift — Develop's strips: which cards, what each is rendered from, and its key.
//
//      tools/selftest.sh                # the checks
//      tools/selftest.sh --self-test    # each broken rule below must be caught
//
//  Compiled with the model and `Services/StockPreviewRules.swift`, over the bundle's own catalogue
//  (Resources/StockCatalog.json). What it holds:
//
//  - the film strip is every film, shelf by shelf (negative, positive, cine, B&W), each on the paper it was made for, a slide
//    scanned, the four black-and-white films on the silver paper;
//  - the paper strip: none under a slide, the silver paper alone under a black-and-white film, every
//    colour paper under a colour one — so no card is ever rendered on a paper that cannot print its film;
//    the row under a black-and-white film shows every paper, the strip's alone live;
//  - a card's settings are the frame's own with the card's pair, held to the film: a slide is never
//    printed, a colour film never printed on silver, whatever the card says;
//  - the key moves with every input that changes the picture, and with nothing else;
//  - the size a card keeps covers the card at 3× without enlarging;
//  - under a finger (0.2, a tester: "选中一个胶片，再次点击这个胶片，会跳到其他胶片"):
//    a second tap at the point of the first lands on the card the first chose, the chosen card
//    tapped again changes nothing, and a card chosen off screen is brought wholly on. Held on a
//    model of the row as `StockPreviewPanel` lays it out (16 pt margins, 100 pt cards 8 pt apart)
//    at four reference device widths, every scroll offset and every point a finger can land on.
//
//  It renders nothing: the renders are `StockPreviews`'s, seen in the simulator (`--strip-check`).

import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
}

struct Checker {
    var passed = 0
    var failed: [String] = []
    let quiet: Bool
    mutating func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if !quiet { print("  FAIL  \(what)") } }
    }
}

/// One rule broken at a time: the check that should catch it.
enum Broken: String, CaseIterable {
    case none
    /// Every paper under every film: a slide printed, silver under colour.
    case everyPaper = "every-paper"
    /// A film card on the frame's own paper, not the one it was made for.
    case keptPaper = "kept-paper"
    /// A card's settings taken as the card says, not held to the film.
    case notHeld = "not-held"
    /// The key made without the wire's values.
    case keyWithoutExposure = "key-without-exposure"
    /// The kept picture the card's size, whatever the picture's shape.
    case cardShaped = "card-shaped"
    /// The row re-centred on every change of the chosen card, a tapped one too (0.2 as shipped).
    case recentred
    /// A tap on the chosen card chooses it again (and puts its film's own paper back).
    case reselects
    /// The film shelves without the black-and-white films' own: a silver film on Negative too.
    case shelvesOverlap = "shelves-overlap"
    /// The film strip in the catalogue's order, the shelves mixed under All.
    case catalogueOrder = "catalogue-order"
}

func run(_ broken: Broken, catalog: StockCatalog, quiet: Bool) -> Checker {
    var c = Checker(quiet: quiet)

    func filmStrip() -> [StockPreviewCard] {
        let strip = StockPreviewRules.filmStrip(catalog)
        if broken == .catalogueOrder { return catalog.films.compactMap { f in strip.first { $0.film == f.id } } }
        guard broken == .keptPaper else { return strip }
        return strip.map { StockPreviewCard(strip: .film, film: $0.film, paper: $0.paper == nil ? nil : FilmParams.default.printStock) }
    }
    func paperStrip(_ film: String) -> [StockPreviewCard] {
        guard broken == .everyPaper else { return StockPreviewRules.paperStrip(under: film, catalog) }
        return catalog.papers.map { StockPreviewCard(strip: .paper, film: film, paper: $0.id) }
    }
    func params(_ card: StockPreviewCard, _ from: FilmParams) -> FilmParams {
        guard broken == .notHeld else { return StockPreviewRules.params(card, from: from, catalog) }
        var p = from
        p.filmStock = card.film
        if let paper = card.paper { p.printStock = paper; p.scanFilm = false } else { p.scanFilm = true }
        return p
    }
    func key(_ wire: [String: ParamValue], decode: String = "", cut: String? = nil,
             source: String = "Originals/a/IMG_1.DNG 4032x3024", engine: String = "halation=mobile.1|abc123") -> String {
        var w = wire
        if broken == .keyWithoutExposure { w["exposure_compensation_ev"] = nil }
        return StockPreviewKey.of(wire: w, decode: decode, cut: cut, source: source, engine: engine)
    }
    func cover(_ size: PixelSize) -> PixelSize {
        broken == .cardShaped ? StockPreviewSize.cardPixels : StockPreviewSize.cover(size)
    }
    func reveal(_ place: StripPlacement?) -> StripReveal {
        broken == .recentred ? .centre : StockPreviewRules.reveal(place)
    }
    func pick(_ card: StockPreviewCard, film: String, paper: String) -> StockPick? {
        guard broken == .reselects else { return StockPreviewRules.pick(card, film: film, paper: paper) }
        return card.strip == .film ? .film(card.film) : card.paper.map(StockPick.paper)
    }

    // Product recommendations are independent of the calibration profile's target_print.
    for film in catalog.films where !film.isPositive {
        let expected: String
        if film.isMonochrome { expected = "ilford_multigrade_iv_rc" }
        else if film.isCine { expected = "kodak_2383" }
        // CineStill 800T is a still film the catalogue declares printed on 2383, as the Mac has listed it.
        else if film.id == "cinestill_800t" { expected = "kodak_2383" }
        else if film.id.hasPrefix("fujifilm_") { expected = "fujifilm_crystal_archive_typeii" }
        else if film.id.hasPrefix("kodak_portra_") { expected = "kodak_portra_endura" }
        else if film.id == "kodak_ultramax_400" { expected = "kodak_ultra_endura" }
        else { expected = "kodak_supra_endura" }
        c.expect(catalog.ownPaper(of: film.id) == expected, "recommended paper: \(film.id)")
        c.expect(catalog.papers.filter { catalog.isRecommendedPairing(film: film.id, paper: $0.id) }.map(\.id) == [expected],
                 "one recommendation dot for \(film.id), on \(expected)")
        for previous in catalog.papers {
            var p = FilmParams.default
            p.printStock = previous.id
            p.digitalIntermediate = true
            p.load(film: film.id, catalog: catalog)
            c.expect(p.printStock == expected && !p.digitalIntermediate && !p.scanFilm,
                     "loading \(film.id) replaces \(previous.id) with its recommendation and exits DI")
            if catalog.canPrint(film: film.id, on: previous.id) {
                p.printStock = previous.id
                p.load(film: film.id, catalog: catalog, recommendingPaper: false)
                c.expect(p.printStock == previous.id, "copying an explicit pair preserves its manually chosen paper")
                c.expect(p.heldToItsFilm(catalog: catalog).printStock == previous.id,
                         "library validation preserves its manually chosen paper")
            }
            var pair = StockPair(film: "kodak_portra_400", paper: previous.id)
            pair.load(film: film.id, catalog: catalog)
            c.expect(pair.paper == expected, "new-frame selector: \(film.id) brings its recommended paper")
        }
    }

    // ---- the film strip ----
    let films = filmStrip()
    c.expect(Set(films.map(\.film)) == Set(catalog.films.map(\.id)) && films.count == catalog.films.count,
             "film strip: every film (\(films.count) of \(catalog.films.count))")
    // Shelf by shelf (2026-10-19): negative, positive, cine, black and white; the catalogue's order on each.
    let order = StockShelf.film.filter { $0 != .all }
    let byShelf = order.flatMap { shelf in catalog.films.filter(shelf.holds).map(\.id) }
    c.expect(films.map(\.film) == byShelf, "film strip: negative, positive, cine, then B&W, each in the catalogue's order")
    for card in films {
        guard let film = catalog.stock(card.film) else { continue }
        if film.isPositive {
            c.expect(card.paper == nil, "film strip: \(film.shortName) is a slide, scanned: no paper")
        } else {
            c.expect(card.paper == catalog.ownPaper(of: film.id), "film strip: \(film.shortName) is on the paper it was made for, got \(card.paper ?? "none")")
            c.expect(card.paper.map { catalog.canPrint(film: card.film, on: $0) } ?? false,
                     "film strip: \(film.shortName)'s paper prints it")
        }
        c.expect(card.strip == .film && card.stock == card.film && card.slot == "film:" + card.film, "film strip: \(film.shortName)'s card is the film's")
    }
    let silver = catalog.films.filter(\.isMonochrome)
    c.expect(silver.count == 4, "film strip: the four black-and-white films are in the catalogue")
    for film in silver {
        let card = films.first { $0.film == film.id }
        c.expect(card?.paper.map(catalog.isMonochrome) ?? false, "film strip: \(film.shortName) is on the silver paper")
    }
    c.expect(Set(films.map(\.id)).count == films.count, "film strip: no two cards the same")

    // ---- the paper strip ----
    let slide = catalog.films.first(where: \.isPositive)!.id
    let tri = silver.first!.id
    let porta = "kodak_portra_400"
    c.expect(paperStrip(slide).isEmpty, "paper strip: none under a slide")
    for film in catalog.films where film.isPositive { c.expect(paperStrip(film.id).isEmpty, "paper strip: none under \(film.shortName)") }
    let underTri = paperStrip(tri)
    c.expect(underTri.count == 1 && underTri.allSatisfy { catalog.isMonochrome($0.paper ?? "") },
             "paper strip: the silver paper alone under a black-and-white film, got \(underTri.compactMap(\.paper))")
    let underPorta = paperStrip(porta)
    c.expect(underPorta.map(\.paper) == catalog.papers.filter { !$0.isMonochrome }.map(\.id) + [StockPreviewCard.digitalIntermediate],
             "paper strip: every colour paper under a colour film, in the catalogue's order, then the Digital Intermediate")
    // What the row shows (2026-10-19): every paper under a silver film, only the silver one live.
    let shownUnderTri = StockPreviewRules.paperShelf(under: tri, catalog)
    c.expect(shownUnderTri.compactMap(\.paper) == catalog.papers.map(\.id) + [StockPreviewCard.digitalIntermediate],
             "paper row: every paper shown under a black-and-white film, in the catalogue's order, then the Digital Intermediate")
    c.expect(shownUnderTri.filter { underTri.contains($0) } == underTri,
             "paper row: under a black-and-white film the live cards are the strip's")
    // 2026-10-20: every paper under every film, a slide's included; under a slide none is live.
    c.expect(StockPreviewRules.paperShelf(under: porta, catalog).compactMap(\.paper) == catalog.papers.map(\.id) + [StockPreviewCard.digitalIntermediate]
             && StockPreviewRules.paperShelf(under: slide, catalog).compactMap(\.paper) == catalog.papers.map(\.id) + [StockPreviewCard.digitalIntermediate]
             && paperStrip(slide).isEmpty,
             "paper row: every paper under a colour film and under a slide, none live under a slide")
    // The Digital Intermediate (2.2.1): a colour negative's last paper card, never under a slide or a silver film;
    // its card sets the switch and keeps the paper; the chosen card follows the switch.
    c.expect(underPorta.last?.isDigitalIntermediate == true && !underTri.contains { $0.isDigitalIntermediate }
             && !paperStrip(slide).contains { $0.isDigitalIntermediate },
             "digital intermediate: the last card under a colour negative, none under a black-and-white film or a slide")
    var printed = FilmParams.default
    printed.load(film: porta, catalog: catalog)
    let paperBefore = printed.printStock
    let diParams = StockPreviewRules.params(underPorta.last!, from: printed, catalog)
    c.expect(diParams.digitalIntermediate && !diParams.scanFilm && diParams.printStock == paperBefore,
             "digital intermediate: its card sets the switch and keeps the paper (\(diParams.printStock))")
    c.expect(StockPreviewRules.chosenPaper(diParams, catalog) == StockPreviewCard.digitalIntermediate && StockPreviewRules.chosenPaper(printed, catalog) == paperBefore,
             "digital intermediate: the chosen paper card follows the switch")
    c.expect(StockPreviewRules.paperServes(StockPreviewCard.digitalIntermediate, filmShelf: .negative, catalog)
             && !StockPreviewRules.paperServes(StockPreviewCard.digitalIntermediate, filmShelf: .positive, catalog)
             && !StockPreviewRules.paperServes(StockPreviewCard.digitalIntermediate, filmShelf: .mono, catalog),
             "digital intermediate: served by the Negative shelf, not by Positive or B&W")
    // The film row's shelf greys the papers that print none of its films.
    let silverPapers = catalog.papers.filter(\.isMonochrome).map(\.id), colourPapers = catalog.papers.filter { !$0.isMonochrome }.map(\.id)
    c.expect(catalog.papers.allSatisfy { StockPreviewRules.paperServes($0.id, filmShelf: .all, catalog) }
             && !catalog.papers.contains { StockPreviewRules.paperServes($0.id, filmShelf: .positive, catalog) }
             && catalog.papers.filter { StockPreviewRules.paperServes($0.id, filmShelf: .mono, catalog) }.map(\.id) == silverPapers
             && catalog.papers.filter { StockPreviewRules.paperServes($0.id, filmShelf: .negative, catalog) }.map(\.id) == colourPapers,
             "paper row under a film shelf: All every paper, Positive none, B&W the silver paper, Negative the colour papers")
    for film in catalog.films {
        for card in paperStrip(film.id) {
            c.expect(card.film == film.id && (card.isDigitalIntermediate || card.paper.map { catalog.canPrint(film: film.id, on: $0) } == true),
                     "paper strip: \(film.shortName) on \(card.paper ?? "none") is a pair the model prints")
        }
    }
    c.expect(underPorta.allSatisfy { $0.slot.hasPrefix("paper:") && $0.stock == $0.paper },
             "paper strip: a card is the paper's, its slot the paper's")
    c.expect(Set(underPorta.map(\.slot)) == Set(StockPreviewRules.paperStrip(under: "kodak_gold_200", catalog).map(\.slot)),
             "paper strip: under another colour film the same slots, each asked again")
    c.expect(paperStrip("no_such_film").isEmpty, "paper strip: none under a film the catalogue does not have")

    // ---- a card's settings ----
    var frame = FilmParams.default
    frame.exposureCompensationEV = 0.7
    frame.yFilterShift = 0.2
    frame.effects.grain = 1.4
    let slideCard = films.first { $0.film == slide }!
    let slideParams = params(slideCard, frame)
    c.expect(slideParams.scanFilm && catalog.isScanned(slideParams), "settings: a slide's card is scanned")
    let forced = params(StockPreviewCard(strip: .paper, film: slide, paper: "kodak_portra_endura"), frame)
    c.expect(forced.scanFilm, "settings: a slide is scanned even on a card that names a paper")
    let triOnColour = params(StockPreviewCard(strip: .paper, film: tri, paper: "kodak_portra_endura"), frame)
    c.expect(catalog.isMonochrome(triOnColour.printStock), "settings: a black-and-white film is printed on silver whatever the card names")
    let portraOnSilver = params(StockPreviewCard(strip: .paper, film: porta, paper: underTri[0].paper), frame)
    c.expect(!catalog.isMonochrome(portraOnSilver.printStock), "settings: a colour film is never printed on silver")
    let portraCard = params(films.first { $0.film == porta }!, frame)
    c.expect(portraCard.exposureCompensationEV == 0.7 && portraCard.yFilterShift == 0.2 && portraCard.effects.grain == 1.4,
             "settings: Film Exposure, the enlarger and grain are the frame's own")
    c.expect(portraCard.filmStock == porta && portraCard.printStock == "kodak_portra_endura" && !portraCard.scanFilm,
             "settings: Porta 400's card is Porta 400 on Porta Enduro, printed")
    var scannedNegative = frame
    scannedNegative.scanFilm = true
    scannedNegative.digitalIntermediate = true
    let printedAgain = params(underPorta[1], scannedNegative)
    c.expect(!printedAgain.scanFilm && !printedAgain.digitalIntermediate && printedAgain.printStock == underPorta[1].paper,
             "settings: a paper's card prints, as a paper card's tap does (`print(on:)`)")

    // ---- the key ----
    let base = catalog.wire(for: portraCard)
    let k = key(base)
    c.expect(k.count == 16 && k == key(base), "key: 16 hex, the same for the same inputs")
    var preciseA = base, preciseB = base
    preciseA["exposure_compensation_ev"] = .double(1.000001)
    preciseB["exposure_compensation_ev"] = .double(1.000002)
    c.expect(key(preciseA) != key(preciseB), "key: distinct wire doubles never alias through display rounding")
    var exposed = portraCard; exposed.exposureCompensationEV = 1.0
    c.expect(key(catalog.wire(for: exposed)) != k, "key: Film Exposure moves it")
    var grainier = portraCard; grainier.effects.grain = 2
    c.expect(key(catalog.wire(for: grainier)) != k, "key: grain moves it (the card is rendered with the frame's grain)")
    let onSupra = params(underPorta.first { $0.paper == "kodak_supra_endura" }!, frame)
    c.expect(key(catalog.wire(for: onSupra)) != k, "key: another paper moves it")
    c.expect(key(base, decode: "Daylight|5500.0|0.0") != key(base, decode: "As Shot"), "key: a RAW's decode moves it")
    c.expect(key(base, cut: "geometry_crop_x=0.1") != k, "key: the film's framing, cut by the host, moves it")
    c.expect(key(base, source: "Originals/a/IMG_1.DNG 8064x6048") != k, "key: the file's size moves it")
    c.expect(key(base, engine: "halation=mobile.2|abc123") != k, "key: another engine moves it")
    var reordered: [String: ParamValue] = [:]
    for name in base.keys.sorted(by: >) { reordered[name] = base[name] }
    c.expect(key(reordered) == k, "key: the wire's order does not move it")

    // ---- the size a card keeps ----
    c.expect(cover(PixelSize(width: 4032, height: 3024)) == PixelSize(width: 336, height: 252), "size: a 4:3 frame on its side keeps 336 x 252")
    c.expect(cover(PixelSize(width: 3024, height: 4032)) == PixelSize(width: 300, height: 400), "size: upright, 300 x 400")
    c.expect(cover(PixelSize(width: 2000, height: 2000)) == PixelSize(width: 300, height: 300), "size: square, 300 x 300")
    let pano = cover(PixelSize(width: 6500, height: 2400))
    c.expect(pano.height == 252 && pano.width >= 682, "size: a 65:24 frame keeps 252 rows, \(pano.width) wide")
    c.expect(cover(PixelSize(width: 200, height: 150)) == PixelSize(width: 200, height: 150), "size: never enlarged")
    for size in [PixelSize(width: 4032, height: 3024), PixelSize(width: 3024, height: 4032), PixelSize(width: 1600, height: 900)] {
        let kept = cover(size)
        c.expect(kept.width >= 300 && kept.height >= 252, "size: \(size.width) x \(size.height) covers the card (\(kept.width) x \(kept.height))")
        c.expect(abs(kept.aspect - size.aspect) < 0.01, "size: \(size.width) x \(size.height) keeps its shape")
    }
    c.expect(StockPreviewSize.renderLongEdge == 800 && StockPreviewSize.openLongEdge == 1600,
             "size: rendered at the live tier's smallest (800), opened at the meter's (1,600)")

    // ---- under a finger ----
    // A tap on the chosen card changes nothing; on any other, it chooses that card's film or paper.
    let chosenFilm = films[1].film, papers = paperStrip(chosenFilm), chosenPaper = papers[0].paper!
    for card in films {
        let picked = pick(card, film: chosenFilm, paper: chosenPaper)
        c.expect(card.film == chosenFilm ? picked == nil : picked == .film(card.film),
                 "tap: film \(card.film), \(chosenFilm) chosen, picks \(String(describing: picked))")
    }
    for card in papers {
        let picked = pick(card, film: chosenFilm, paper: chosenPaper)
        c.expect(card.paper == chosenPaper ? picked == nil : picked == (card.isDigitalIntermediate ? .digitalIntermediate : .paper(card.paper!)),
                 "tap: paper \(card.paper!), \(chosenPaper) chosen, picks \(String(describing: picked))")
    }
    c.expect(StripPlacement.of(minX: 16, maxX: 116, width: 402) == .whole
             && StripPlacement.of(minX: 340, maxX: 440, width: 402) == .cut
             && StripPlacement.of(minX: -60, maxX: 40, width: 402) == .cut
             && StripPlacement.of(minX: 410, maxX: 510, width: 402) == .off
             && StripPlacement.of(minX: -100, maxX: 0, width: 402) == .off, "placement: whole, cut by either edge, off")
    for (place, move) in [(StripPlacement.whole, StripReveal.stay), (.cut, .nearest), (.off, .centre)] {
        c.expect(reveal(place) == move, "reveal: a chosen card \(place) -> \(move), not \(reveal(place))")
    }
    c.expect(reveal(nil) == .centre, "reveal: a chosen card never laid out -> centre")

    /// A row as the panel lays it out; `offset` is how far it is scrolled.
    struct Row {
        let count: Int, width: Double
        static let margin = 16.0, card = 100.0, gap = 8.0
        var maxOffset: Double { max(0, 2 * Row.margin + Double(count) * Row.card + Double(count - 1) * Row.gap - width) }
        func minX(_ i: Int, _ offset: Double) -> Double { Row.margin + Double(i) * (Row.card + Row.gap) - offset }
        func place(_ i: Int, _ offset: Double) -> StripPlacement {
            .of(minX: minX(i, offset), maxX: minX(i, offset) + Row.card, width: width)
        }
        func card(at x: Double, _ offset: Double) -> Int? {
            (0..<count).first { x >= minX($0, offset) && x < minX($0, offset) + Row.card }
        }
        /// Where the row rests after the move (`ScrollViewReader.scrollTo`, clamped as a scroll view is).
        func offset(after move: StripReveal, to i: Int, from offset: Double) -> Double {
            let lo = minX(i, offset), hi = lo + Row.card
            let to: Double
            switch move {
            case .stay: to = offset
            case .nearest: to = lo < 0 ? offset + lo : (hi > width ? offset + hi - width : offset)
            case .centre: to = offset + lo + Row.card / 2 - width / 2
            }
            return min(max(to, 0), maxOffset)
        }
    }
    var slid: [String] = [], unreached: [String] = []
    var taps = 0
    for (name, count) in [("film", films.count), ("paper", papers.count)] {
        for width in [375.0, 393.0, 402.0, 440.0] {
            let row = Row(count: count, width: width)
            for offset in stride(from: 0.0, through: row.maxOffset, by: 3) {
                // Two taps at one point: the second lands on the card the first chose, or between cards.
                for x in stride(from: 1.0, to: width, by: 2) {
                    guard let i = row.card(at: x, offset) else { continue }
                    taps += 1
                    let after = row.offset(after: reveal(row.place(i, offset)), to: i, from: offset)
                    if let j = row.card(at: x, after), j != i {
                        slid.append("\(name) row, \(Int(width)) pt, offset \(Int(offset)): a tap at x \(Int(x)) chose card \(i), a second tap there card \(j)")
                    }
                }
                // Every card, chosen from anywhere (an undo, the film's own paper), ends wholly on screen.
                for i in 0..<count {
                    for place in [row.place(i, offset), nil] as [StripPlacement?] {
                        let after = row.offset(after: reveal(place), to: i, from: offset)
                        if row.place(i, after) != .whole { unreached.append("\(name) row, \(Int(width)) pt: card \(i) from offset \(Int(offset))") }
                    }
                }
            }
        }
    }
    c.expect(taps > 10_000, "finger: \(taps) taps modelled")
    c.expect(slid.isEmpty, "finger: a second tap at the first's point lands on the card it chose -- \(slid.count) of \(taps) did not, e.g. \(slid.first ?? "")")
    c.expect(unreached.isEmpty, "finger: every chosen card ends wholly on screen -- \(unreached.count) did not, e.g. \(unreached.first ?? "")")
    // The strips' pills (2026-10-18): every film on exactly one shelf beside All, every paper too;
    // the cine prints on Standard; a shelf keeps the strip's order.
    func shelves(_ stock: Stock, _ list: [StockShelf]) -> [StockShelf] {
        list.filter { $0 != .all && (broken == .shelvesOverlap && $0 == .negative
            ? stock.isFilm && !stock.isPositive && !stock.isCine : $0.holds(stock)) }
    }
    for film in catalog.films {
        let on = shelves(film, StockShelf.film)
        c.expect(on.count == 1, "shelf: the film \(film.id) is on one film shelf -- \(on.map(\.rawValue))")
    }
    for paper in catalog.papers {
        let on = shelves(paper, StockShelf.paper)
        c.expect(on.count == 1, "shelf: the paper \(paper.id) is on one paper shelf -- \(on.map(\.rawValue))")
        if paper.isCine { c.expect(on == [.standard], "shelf: the cine print \(paper.id) is on Standard") }
    }
    let shelved = StockPreviewRules.filmStrip(catalog)
    c.expect(StockShelf.all.cards(shelved, catalog) == shelved, "shelf: All is the whole film strip")
    let mono = StockShelf.mono.cards(shelved, catalog)
    c.expect(!mono.isEmpty && mono == shelved.filter { catalog.stock($0.film)?.isMonochrome == true },
             "shelf: B&W is the strip's silver films, in its order")

    return c
}

@main
struct StockPreviewsSelfTest {
    static func main() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let catalog = StockCatalog(contentsOf: root.appendingPathComponent("Resources/StockCatalog.json")) else {
            print("stock preview checks: no catalogue at Resources/StockCatalog.json")
            exit(1)
        }
        let result = run(.none, catalog: catalog, quiet: false)
        print("stock preview checks: \(result.passed) passed, \(result.failed.count) failed")
        var status: Int32 = result.failed.isEmpty ? 0 : 1
        if CommandLine.arguments.contains("--self-test") {
            let broken = Broken.allCases.filter { $0 != .none }
            var caught = 0
            for b in broken {
                let r = run(b, catalog: catalog, quiet: true)
                if r.failed.isEmpty { print("  NOT CAUGHT  \(b.rawValue)") } else {
                    caught += 1
                    print("  caught  \(b.rawValue): \(r.failed.count) check(s) failed, e.g. \(r.failed[0])")
                }
            }
            print("stock preview self-test: \(caught) of \(broken.count) broken rules caught")
            if caught != broken.count { status = 1 }
        }
        exit(status)
    }
}
