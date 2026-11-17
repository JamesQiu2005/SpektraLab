//  stock_previews_selftest.swift — Develop's strips: which cards, what each is rendered from, and its key.
//
//      tools/selftest.sh                # the checks
//      tools/selftest.sh --self-test    # each broken rule below must be caught
//
//  Compiled with the model and `Services/StockPreviewRules.swift`, over the bundle's own catalogue
//  (Resources/StockCatalog.json). What it holds:
//
//  - the film strip is every film, by maker and then by name (2026-11-16, `StockPreviewGrid.swift`: the makers in
//    alphabetical order, a number in a name by its value, a push card straight after its film, a cine stock under
//    its maker wearing the CINE pill), each on the paper it was made for, a slide scanned, the four black-and-white
//    films on the silver paper;
//  - the paper strip leads with No Paper and the Digital Intermediate, under no maker; the papers follow by maker;
//  - the desktop's grid: its columns are its width's, and each strip's height is as dragged, held between a
//    header over one row and its cards and what the column shows at once; a strip nobody dragged fits the room
//    (`StockGridRule`, `StripSplit`); the two heights are written when a drag ends and never at rest
//    (`StockGridHeights`);
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
    /// The film strip in the catalogue's order: no maker's cards together.
    case catalogueOrder = "catalogue-order"
    /// The No Paper card taken for a paper by name: a negative printed on "no_paper", not scanned.
    case noPaperAsPaper = "no-paper-as-paper"
    /// The card shown only while the setting is on: a scanned negative's chosen state vanishes with it.
    case noPaperHidden = "no-paper-hidden"
    case noPaperLast = "no-paper-last"
    /// Every film by its name alone, the makers mixed.
    case namesAlone = "names-alone"
    /// A name's number read as letters: Vision3 200T before Vision3 50D, and a push card filed by its own name.
    case lettersOnly = "letters-only"
    /// The cine stocks taken out of their makers' groups into one of their own.
    case cineApart = "cine-apart"
    /// The CINE pill on the camera films alone: a cine print film unmarked.
    case cinePrintsUnmarked = "cine-prints-unmarked"
    /// The Digital Intermediate after the papers, where a maker's header would claim it.
    case intermediateLast = "intermediate-last"
    /// Three cards across whatever the grid's width.
    case threeAcross = "three-across"
    /// A strip as tall as it was dragged, whatever its cards and the column's window.
    case heightsAsDragged = "heights-as-dragged"
    /// A strip nobody dragged at its standard height whatever the room: Decode off screen at rest in a short window.
    case standardWhateverRoom = "standard-whatever-room"
    /// A grip drags its strip under a maker's header over one row.
    case gripUnderLeast = "grip-under-least"
    /// A strip taller than its cards: empty room under a short shelf.
    case tallerThanCards = "taller-than-cards"
    /// A card chosen off screen brought to the strip's middle, wherever that leaves the row above (as first built).
    case revealsToTheMiddle = "reveals-to-the-middle"
    /// A row drawn until the whole of it is under the held name: its names showing after its pictures have gone.
    case namesLinger = "names-linger"
    /// The strip stops where its cards end, mid-row under the held name.
    case footMidRow = "foot-mid-row"
    /// The heights written at every step of a drag, and a default written at rest.
    case heightsWrittenAtRest = "heights-written-at-rest"
    /// A favourite moves up the film strip: the star is a place and not a filter.
    case favouritesOrderTheStrip = "favourites-order-the-strip"
    /// Favourites on the film row greys the papers by what is starred.
    case favouritesGreyPapers = "favourites-grey-papers"
    /// The pill's Favourites row offered, and kept, on No Paper alone: the last star off never sends the row back.
    case favouritesCountNoPaper = "favourites-count-no-paper"
}

func run(_ broken: Broken, catalog: StockCatalog, quiet: Bool) -> Checker {
    var c = Checker(quiet: quiet)

    func filmStrip() -> [StockPreviewCard] {
        let strip = StockPreviewRules.filmStrip(catalog)
        if broken == .catalogueOrder { return catalog.films.compactMap { f in strip.first { $0.film == f.id } } }
        if broken == .namesAlone {
            return strip.sorted { StockPreviewRules.filed(catalog.stock($0.film)!.shortName, before: catalog.stock($1.film)!.shortName) }
        }
        if broken == .lettersOnly {
            return strip.sorted { a, b in
                let x = catalog.stock(a.film)!, y = catalog.stock(b.film)!
                return x.brand == y.brand ? x.shortName < y.shortName : x.brand.lowercased() < y.brand.lowercased()
            }
        }
        guard broken == .keptPaper else { return strip }
        return strip.map { StockPreviewCard(strip: .film, film: $0.film, paper: $0.paper == nil ? nil : FilmParams.default.printStock) }
    }
    /// The strip as the app shows it: No Paper's card first, always (2.4.1, "We use B").
    func fullStrip(_ film: String) -> [StockPreviewCard] {
        let strip = StockPreviewRules.paperStrip(under: film, catalog)
        if broken == .noPaperHidden { return strip.filter { !$0.isNoPaper } }
        if broken == .noPaperLast { return strip.filter { !$0.isNoPaper } + strip.filter(\.isNoPaper) }
        if broken == .intermediateLast { return strip.filter { !$0.isDigitalIntermediate } + strip.filter(\.isDigitalIntermediate) }
        return strip
    }
    /// The papers on it, No Paper's card left out: what the strip was before 2.4.1.
    func paperStrip(_ film: String) -> [StockPreviewCard] {
        guard broken == .everyPaper else { return fullStrip(film).filter { !$0.isNoPaper } }
        return catalog.papers.map { StockPreviewCard(strip: .paper, film: film, paper: $0.id) }
    }
    func shelfFor(_ film: String) -> [StockPreviewCard] {
        let shelf = StockPreviewRules.paperShelf(under: film, catalog)
        if broken == .intermediateLast { return shelf.filter { !$0.isDigitalIntermediate } + shelf.filter(\.isDigitalIntermediate) }
        return broken == .noPaperLast ? shelf.filter { !$0.isNoPaper } + shelf.filter(\.isNoPaper) : shelf
    }
    func groups(_ cards: [StockPreviewCard]) -> [StockBrandGroup] {
        let groups = StockPreviewRules.groups(cards, catalog)
        guard broken == .cineApart else { return groups }
        let cine = cards.filter { catalog.stock($0.stock)?.isCine == true }
        return groups.map { StockBrandGroup(brand: $0.brand, cards: $0.cards.filter { !cine.contains($0) }) }.filter { !$0.cards.isEmpty }
            + (cine.isEmpty ? [] : [StockBrandGroup(brand: "Cine", cards: cine)])
    }
    func wearsCinePill(_ card: StockPreviewCard) -> Bool {
        StockPreviewRules.wearsCinePill(card, catalog) && !(broken == .cinePrintsUnmarked && card.strip == .paper)
    }
    func columns(_ width: Double) -> Int { broken == .threeAcross ? 3 : StockGridRule.columns(width: width) }
    func resolve(_ room: StripSplit.Room) -> StripSplit {
        var r = room
        if broken == .heightsAsDragged {
            return StripSplit(film: r.film.open ? r.film.dragged ?? StripSplit.resolve(r).film : 0,
                              paper: r.paper.open ? r.paper.dragged ?? StripSplit.resolve(r).paper : 0)
        }
        if broken == .standardWhateverRoom { r.restMin = -.greatestFiniteMagnitude }
        if broken == .tallerThanCards { r.film.content = .greatestFiniteMagnitude; r.paper.content = .greatestFiniteMagnitude }
        return StripSplit.resolve(r)
    }
    func foot(_ l: StockGridLayout, _ window: Double) -> Double {
        broken == .footMidRow ? max(l.content - window, 0) : l.foot(window: window)
    }
    func reveal(_ l: StockGridLayout, row: Int, from offset: Double, window: Double, tapped: Bool = false) -> Double {
        guard broken == .revealsToTheMiddle else { return min(l.reveal(row: row, from: offset, window: window, tapped: tapped), foot(l, window)) }
        let top = l.rows[row].top - offset
        if top >= l.pinned(at: offset), top + l.rowHeight <= window { return offset }
        return min(max(l.rows[row].top + l.rowHeight / 2 - window / 2, 0), max(l.content - window, 0))
    }
    func gone(_ l: StockGridLayout, at offset: Double, window: Double) -> Int {
        guard broken == .namesLinger else { return l.shown(at: offset, window: window).gone }
        return l.rows.firstIndex { $0.top + l.rowHeight - offset > l.pinned(at: offset) } ?? l.rows.count
    }
    func drag(_ grip: StripSplit.Grip, _ room: StripSplit.Room, from start: Double, travel: Double) -> Double {
        if broken == .gripUnderLeast { return min(start + travel, room.most(grip == .film ? room.film : room.paper)) }
        return StripSplit.drag(grip, in: room, from: start, travel: travel)
    }

    func params(_ card: StockPreviewCard, _ from: FilmParams) -> FilmParams {
        if broken == .noPaperAsPaper, card.isNoPaper {
            var p = from
            p.filmStock = card.film; p.printStock = StockPreviewCard.noPaper; p.scanFilm = false
            return p
        }
        guard broken == .notHeld else { return StockPreviewRules.params(card, from: from, catalog) }
        var p = from
        p.filmStock = card.film
        if let paper = card.paper { p.printStock = paper; p.scanFilm = false } else { p.scanFilm = true }
        return p
    }
    func key(_ wire: [String: ParamValue], decode: String = "", cut: String? = nil,
             source: String = "Originals/a/IMG_1.DNG 4032x3024", engine: String = "halation=v1|abc123") -> String {
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
    // By maker, then by name (the owner, 2026-11-16: "Brand name -> film name"), in place of 2026-10-19's shelf by shelf.
    func names(_ cards: [StockPreviewCard]) -> [String] { cards.map { catalog.stock($0.stock)?.shortName ?? $0.stock } }
    let filmGroups = groups(films)
    c.expect(filmGroups.map(\.brand) == ["CineStill", "Fujifilm", "Ilford", "Kodak"],
             "film strip: the makers in alphabetical order, each once -- \(filmGroups.map(\.brand))")
    c.expect(filmGroups.flatMap(\.cards) == films, "film strip: the groups are the strip, in its order")
    c.expect(filmGroups.first { $0.brand == "Fujifilm" }.map { names($0.cards) } == ["Acros 100 II", "C200", "Pro 400H", "Provia 100F", "Velvia 100", "X-Tra 400"],
             "film strip: Fujifilm's films by name -- \(filmGroups.first { $0.brand == "Fujifilm" }.map { names($0.cards) } ?? [])")
    let kodak = filmGroups.first { $0.brand == "Kodak" }.map { names($0.cards) } ?? []
    c.expect(kodak == ["Ektachrome 100", "Ektar 100", "Gold 200", "Kodachrome 64", "Portra 160", "Portra 160NC", "Portra 160VC",
                       "Portra 400", "Portra 400NC", "Portra 400VC", "Portra 800", "Portra 800 +1", "Portra 800 +2", "T-Max 100",
                       "Tri-X 400", "Ultramax 400", "Verita 200D", "Vision3 50D", "Vision3 200T", "Vision3 250D", "Vision3 500T"],
             "film strip: Kodak's films by name, a number by its value, a push after its film -- \(kodak)")
    for film in catalog.films {
        let push = catalog.push(of: film.id)
        guard push.level > 0, let at = films.firstIndex(where: { $0.film == film.id }), let base = films.firstIndex(where: { $0.film == push.base }) else { continue }
        c.expect(at == base + push.level, "film strip: \(film.shortName) is \(push.level) after its film (\(at) and \(base))")
    }
    c.expect(catalog.films.filter { catalog.push(of: $0.id).level > 0 }.count == 2 && catalog.push(of: "kodak_portra_800").level == 0
             && catalog.push(of: "kodak_portra_800_push2") == ("kodak_portra_800", 2), "push: Portra 800's two push cards, and no other")
    for stock in catalog.stocks {
        c.expect(stock.id.hasPrefix(stock.brand.lowercased() + "_"), "brand: \(stock.id) is \(stock.brand)'s")
    }
    // A cine stock is filed under its maker and wears the CINE pill: no group of its own.
    let cineFilms = films.filter { catalog.stock($0.film)?.isCine == true }
    c.expect(cineFilms.count == 5 && cineFilms.allSatisfy(wearsCinePill) && films.filter(wearsCinePill) == cineFilms,
             "cine: the five cine negatives wear the CINE pill, and no other film")
    c.expect(cineFilms.allSatisfy { card in filmGroups.first { $0.cards.contains(card) }?.brand == catalog.stock(card.film)?.brand }
             && !filmGroups.contains { $0.brand.lowercased() == "cine" },
             "cine: each is filed under its maker, in no group of its own")
    c.expect(StockShelf.cine.cards(films, catalog) == cineFilms && groups(cineFilms).map(\.brand) == ["Kodak"],
             "cine: the Cine shelf holds them alone, under their maker")
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
    let filedPapers = StockPreviewRules.brandOrder(catalog.papers, catalog)
    c.expect(filedPapers.map(\.shortName) == ["Crystal Archive II", "Multigrade IV RC", "Ektacolor Edge", "Endura Premier", "Portra Endura",
                                              "Supra Endura", "Ultra Endura", "Vision 2383", "Vision Premier 2393"],
             "papers: by maker (Fujifilm, Ilford, Kodak), then by name -- \(filedPapers.map(\.shortName))")
    c.expect(underPorta.map(\.paper) == [StockPreviewCard.digitalIntermediate] + filedPapers.filter { !$0.isMonochrome }.map(\.id),
             "paper strip: the Digital Intermediate, then every colour paper under a colour film, by maker and name")
    // What the row shows (2026-10-19): every paper under a silver film, only the silver one live.
    let shownUnderTri = shelfFor(tri).filter { !$0.isNoPaper }
    let shownPapers = [StockPreviewCard.digitalIntermediate] + filedPapers.map(\.id)
    c.expect(shownUnderTri.compactMap(\.paper) == shownPapers,
             "paper row: the Digital Intermediate and every paper shown under a black-and-white film, by maker and name")
    c.expect(shownUnderTri.filter { underTri.contains($0) } == underTri,
             "paper row: under a black-and-white film the live cards are the strip's")
    // 2026-10-20: every paper under every film, a slide's included; under a slide none is live.
    c.expect(shelfFor(porta).filter { !$0.isNoPaper }.compactMap(\.paper) == shownPapers
             && shelfFor(slide).filter { !$0.isNoPaper }.compactMap(\.paper) == shownPapers
             && paperStrip(slide).isEmpty,
             "paper row: every paper under a colour film and under a slide, none live under a slide")
    // The Digital Intermediate (2.2.1): a colour negative's card, never under a slide or a silver film; its card sets
    // the switch and keeps the paper; the chosen card follows the switch. Since 2026-11-16 it stands beside No Paper,
    // before the papers: the two cards that are no paper's lead the grid under no maker's header.
    let diCard = StockPreviewRules.digitalIntermediateCard(under: porta)
    c.expect(fullStrip(porta).prefix(2).map(\.paper) == [StockPreviewCard.noPaper, StockPreviewCard.digitalIntermediate]
             && shelfFor(tri).prefix(2).map(\.paper) == [StockPreviewCard.noPaper, StockPreviewCard.digitalIntermediate]
             && !underTri.contains { $0.isDigitalIntermediate } && !paperStrip(slide).contains { $0.isDigitalIntermediate },
             "digital intermediate: straight after No Paper under a colour negative, none live under a black-and-white film or a slide")
    let paperGroups = groups(shelfFor(porta))
    c.expect(paperGroups.map(\.brand) == ["", "Fujifilm", "Ilford", "Kodak"]
             && paperGroups.first?.cards.map(\.paper) == [StockPreviewCard.noPaper, StockPreviewCard.digitalIntermediate],
             "paper grid: No Paper and the Digital Intermediate under no maker, then the makers -- \(paperGroups.map(\.brand))")
    let cinePrints = shelfFor(porta).filter(wearsCinePill)
    c.expect(cinePrints.compactMap(\.paper) == ["kodak_2383", "kodak_2393"] && !wearsCinePill(diCard) && !wearsCinePill(shelfFor(porta)[0]),
             "cine: the two cine print films wear the CINE pill, under Kodak; No Paper and the Digital Intermediate do not")
    var printed = FilmParams.default
    printed.load(film: porta, catalog: catalog)
    let paperBefore = printed.printStock
    let diParams = StockPreviewRules.params(diCard, from: printed, catalog)
    c.expect(diParams.digitalIntermediate && !diParams.scanFilm && diParams.printStock == paperBefore,
             "digital intermediate: its card sets the switch and keeps the paper (\(diParams.printStock))")
    c.expect(StockPreviewRules.chosenPaper(diParams, catalog) == StockPreviewCard.digitalIntermediate && StockPreviewRules.chosenPaper(printed, catalog) == paperBefore,
             "digital intermediate: the chosen paper card follows the switch")
    c.expect(StockPreviewRules.paperServes(StockPreviewCard.digitalIntermediate, filmShelf: .negative, catalog)
             && !StockPreviewRules.paperServes(StockPreviewCard.digitalIntermediate, filmShelf: .positive, catalog)
             && !StockPreviewRules.paperServes(StockPreviewCard.digitalIntermediate, filmShelf: .mono, catalog),
             "digital intermediate: served by the Negative shelf, not by Positive or B&W")
    // The No Paper card (2.4.1; the owner, 2026-11-16: "We use B" -- no setting, always shown, FIRST): the paper strip's
    // first card, which scans the film in place of printing it. Under every film; alone under a slide.
    let noPaperUnderPorta = fullStrip(porta)
    c.expect(noPaperUnderPorta.first?.isNoPaper == true && noPaperUnderPorta.first?.paper == StockPreviewCard.noPaper
             && noPaperUnderPorta.dropFirst().map(\.paper) == underPorta.map(\.paper) && noPaperUnderPorta.filter(\.isNoPaper).count == 1,
             "no paper: the strip's first card, before the papers and the Digital Intermediate, always")
    c.expect(fullStrip(slide).map(\.paper) == [StockPreviewCard.noPaper]
             && fullStrip(tri).map(\.paper) == [StockPreviewCard.noPaper] + underTri.map(\.paper),
             "no paper: first under a black-and-white film too, and alone under a slide")
    c.expect(shelfFor(porta).compactMap(\.paper) == [StockPreviewCard.noPaper] + shownPapers
             && shelfFor(slide).first?.isNoPaper == true && shelfFor(tri).first?.isNoPaper == true,
             "no paper: the row shows it first, under every film")
    c.expect(noPaperUnderPorta.first!.slot == "paper:" + StockPreviewCard.noPaper
             && Set(noPaperUnderPorta.map(\.id)).count == noPaperUnderPorta.count
             && noPaperUnderPorta.first!.id != fullStrip(tri).first!.id,
             "no paper: its own slot, an id a film's own")
    let noPaperParams = params(noPaperUnderPorta.first!, printed)
    c.expect(noPaperParams.scanFilm && !noPaperParams.digitalIntermediate && noPaperParams.printStock == paperBefore
             && catalog.isScanned(noPaperParams) && noPaperParams.filmStock == porta,
             "no paper: its card scans the negative, no DI, the paper kept (\(noPaperParams.printStock))")
    var diFrame = printed; diFrame.digitalIntermediate = true
    let noPaperOverDI = params(noPaperUnderPorta.first!, diFrame)
    c.expect(noPaperOverDI.scanFilm && !noPaperOverDI.digitalIntermediate,
             "no paper: its card leaves the Digital Intermediate")
    // (A broken rule that hides the card leaves none under a slide: the card itself then, so the run goes on to be caught.)
    let noPaperSlide = params(fullStrip(slide).first ?? StockPreviewRules.noPaperCard(under: slide), printed)
    c.expect(noPaperSlide.scanFilm && noPaperSlide.filmStock == slide, "no paper: under a slide it is the slide scanned")
    c.expect(noPaperParams.heldToItsFilm(catalog: catalog) == noPaperParams && noPaperSlide.heldToItsFilm(catalog: catalog) == noPaperSlide,
             "no paper: held to its film it is left alone")
    var scannedPorta = printed; scannedPorta.scanFilm = true
    var slideEdit = FilmParams.default; slideEdit.load(film: slide, catalog: catalog)
    c.expect(StockPreviewRules.chosenPaper(noPaperParams, catalog) == StockPreviewCard.noPaper
             && StockPreviewRules.chosenPaper(scannedPorta, catalog) == StockPreviewCard.noPaper
             && StockPreviewRules.chosenPaper(printed, catalog) == paperBefore
             && StockPreviewRules.chosenPaper(diParams, catalog) == StockPreviewCard.digitalIntermediate
             && StockPreviewRules.chosenPaper(slideEdit, catalog) == StockPreviewCard.noPaper,
             "no paper: chosen for a scanned frame and a slide, never for a printed one")
    // Picking another film (the film card's `load(film:)`) puts a scan back to printed: a slide's implicit scan, or a
    // negative scanned by No Paper's card, never carries over to the negative picked (it would show orange).
    var overSlide = slideEdit; overSlide.load(film: porta, catalog: catalog)
    var overScanned = scannedPorta; overScanned.load(film: porta, catalog: catalog)
    c.expect(!overSlide.scanFilm && !catalog.isScanned(overSlide) && !overScanned.scanFilm && !catalog.isScanned(overScanned)
             && StockPreviewRules.chosenPaper(overSlide, catalog) != StockPreviewCard.noPaper,
             "film pick: a negative picked over a slide or a scanned negative is printed, not scanned")
    // A scanned negative, scanned and DI'd, is a scanned one (the model: scanFilm wins).
    var scannedDI = scannedPorta; scannedDI.digitalIntermediate = true
    c.expect(StockPreviewRules.chosenPaper(scannedDI, catalog) == StockPreviewCard.noPaper,
             "no paper: scanFilm wins over a Digital Intermediate left on")
    // The strip's shelves: it serves every film, so every film shelf and every paper shelf shows it.
    c.expect([StockShelf.all, .negative, .positive, .cine, .mono].allSatisfy { StockPreviewRules.paperServes(StockPreviewCard.noPaper, filmShelf: $0, catalog) },
             "no paper: served by every film shelf")
    let shownRow = shelfFor(porta)
    c.expect([StockShelf.all, .standard, .mono].allSatisfy { $0.cards(shownRow, catalog).first?.isNoPaper == true },
             "no paper: on every paper shelf, All, Standard and B&W")
    // The ways back and forth: a paper's card or the DI's card clears it (`print(on:)`, the DI branch).
    var back = scannedPorta
    c.expect(back.print(on: back.printStock, catalog: catalog) && !back.scanFilm, "no paper: a paper's card prints again (`print(on:)` clears scanFilm)")
    let diOver = params(diCard, scannedPorta)
    c.expect(diOver.digitalIntermediate && !diOver.scanFilm, "no paper: the Digital Intermediate's card clears scanFilm")
    c.expect(pick(noPaperUnderPorta.first!, film: porta, paper: paperBefore) == .noPaper
             && pick(noPaperUnderPorta.first!, film: porta, paper: StockPreviewCard.noPaper) == nil,
             "no paper: tapped it is chosen, tapped again it changes nothing")

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
    c.expect(Set(underPorta.map(\.slot)) == Set(paperStrip("kodak_gold_200").map(\.slot)),
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
    let aPaper = underPorta.first { !$0.isDigitalIntermediate }!
    let printedAgain = params(aPaper, scannedNegative)
    c.expect(!printedAgain.scanFilm && !printedAgain.digitalIntermediate && printedAgain.printStock == aPaper.paper,
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
    c.expect(key(base, engine: "halation=v2|abc123") != k, "key: another engine moves it")
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
    let chosenFilm = porta, papers = paperStrip(chosenFilm), chosenPaper = papers.first { !$0.isDigitalIntermediate }!.paper!
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
        list.filter { $0 != .all && $0 != .favourites && (broken == .shelvesOverlap && $0 == .negative
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

    // ---- Favourites (收藏, 2026-11-15) ----
    let favSuite = UserDefaults(suiteName: "stock_previews_selftest.favourites")!
    favSuite.removePersistentDomain(forName: "stock_previews_selftest.favourites")
    defer { favSuite.removePersistentDomain(forName: "stock_previews_selftest.favourites") }
    let personal = StockPersonal(defaults: favSuite)
    c.expect(StockShelf.film.prefix(2) == [.all, .favourites] && StockShelf.paper.prefix(2) == [.all, .favourites],
             "favourites: straight after All on both pills")
    let stripBefore = StockPreviewRules.filmStrip(catalog)
    c.expect(StockShelf.favourites.cards(stripBefore, catalog, personal: personal).isEmpty, "favourites: nothing starred, an empty shelf")
    let firstFilm = stripBefore.first!.film, lastFilm = stripBefore.last!.film
    catalog.setFavourite(lastFilm, true, personal)
    catalog.setFavourite(firstFilm, true, personal)
    var stripAfter = StockPreviewRules.filmStrip(catalog)
    if broken == .favouritesOrderTheStrip {
        func starred(_ card: StockPreviewCard) -> Bool { catalog.isFavourite(card.film, personal) }
        stripAfter = stripAfter.filter(starred) + stripAfter.filter { !starred($0) }
    }
    c.expect(stripAfter == stripBefore, "favourites: a star moves nothing in the film strip")
    c.expect(StockShelf.favourites.cards(stripBefore, catalog, personal: personal).map(\.film) == [firstFilm, lastFilm],
             "favourites: the shelf holds the starred films in the strip's own order")
    c.expect(StockShelf.film.filter { $0 != .all && $0 != .favourites && $0.holds(catalog.stock(firstFilm)!, catalog, personal: personal) }.count == 1,
             "favourites: a starred film is still on its own shelf")
    let paperRow = shelfFor(porta)
    c.expect(StockShelf.favourites.cards(paperRow, catalog, personal: personal).map(\.paper) == [StockPreviewCard.noPaper],
             "favourites: no paper starred, the paper shelf holds No Paper alone")
    catalog.setFavourite(lastFilm, false, personal)
    catalog.setFavourite(firstFilm, false, personal)
    // A push card follows its film.
    catalog.setFavourite("kodak_portra_800_push2", true, personal)
    c.expect(StockShelf.favourites.cards(stripBefore, catalog, personal: personal).map(\.film)
                == stripBefore.map(\.film).filter { $0.hasPrefix("kodak_portra_800") },
             "favourites: a push card follows its film: all three of Portra 800's cards are on the shelf")
    catalog.setFavourite("kodak_portra_800", false, personal)
    // Papers: a starred paper the film cannot print is on the shelf, greyed, never rendered.
    let silverFilm = catalog.films.first(where: \.isMonochrome)!, supra = "kodak_supra_endura"
    catalog.setFavourite(supra, true, personal)
    let favUnderSilver = StockShelf.favourites.cards(shelfFor(silverFilm.id).filter { !$0.isNoPaper }, catalog, personal: personal)
    c.expect(favUnderSilver.map(\.stock) == [supra] && !paperStrip(silverFilm.id).contains(favUnderSilver[0]),
             "favourites: a starred colour paper is on the shelf under a silver film, greyed")
    c.expect(StockShelf.favourites.cards(shelfFor(slide).filter { !$0.isNoPaper }, catalog, personal: personal).map(\.stock) == [supra],
             "favourites: and under a slide")
    // The DI is not on Favourites (as on any by-kind shelf it is not on); No Paper is, as on every shelf.
    let favRow = shelfFor(porta)
    let favOnShelf = StockShelf.favourites.cards(favRow, catalog, personal: personal)
    c.expect(favOnShelf.map(\.paper) == [StockPreviewCard.noPaper, supra], "favourites: No Paper, then the starred paper; never the Digital Intermediate")
    // Favourites on the film row greys no paper.
    func serves(_ paper: String) -> Bool {
        if broken == .favouritesGreyPapers {
            return catalog.films.contains { StockShelf.favourites.holds($0, catalog, personal: personal) && !$0.isPositive && catalog.canPrint(film: $0.id, on: paper) }
        }
        return StockPreviewRules.paperServes(paper, filmShelf: .favourites, catalog)
    }
    catalog.setFavourite(slide, true, personal)
    c.expect(catalog.papers.allSatisfy { serves($0.id) } && serves(StockPreviewCard.digitalIntermediate) && serves(StockPreviewCard.noPaper),
             "favourites: a slide alone starred, and every paper, the DI and No Paper are still offered")
    catalog.setFavourite(slide, false, personal)
    catalog.setFavourite(silverFilm.id, true, personal)
    c.expect(catalog.papers.allSatisfy { serves($0.id) }, "favourites: a silver film alone starred, every paper is still offered")
    catalog.setFavourite(silverFilm.id, false, personal)
    c.expect(catalog.papers.allSatisfy { serves($0.id) }, "favourites: nothing starred on the film row, every paper is still offered")
    // The pill: the row is offered when a stock is starred, and No Paper alone never makes it worth choosing.
    func holdsStock(_ shelf: StockShelf, _ cards: [StockPreviewCard]) -> Bool {
        broken == .favouritesCountNoPaper ? !shelf.cards(cards, catalog, personal: personal).isEmpty : shelf.holdsStock(in: cards, catalog, personal: personal)
    }
    c.expect(holdsStock(.favourites, favRow), "favourites: a starred paper makes its row worth choosing")
    catalog.setFavourite(supra, false, personal)
    c.expect(!holdsStock(.favourites, favRow) && holdsStock(.all, favRow) && holdsStock(.standard, favRow),
             "favourites: the last star off, with No Paper offered, the Favourites row is empty (the pill returns to All)")
    c.expect(StockShelf.all.cards(favRow, catalog, personal: personal) == favRow
             && [StockShelf.favourites, .standard, .mono].allSatisfy { $0.cards(favRow, catalog, personal: personal).first?.isNoPaper == true || $0 == .favourites },
             "favourites: No Paper stays on every paper shelf")
    // Neither the DI's card nor No Paper's can be starred.
    c.expect(!StockPreviewRules.digitalIntermediateCard(under: porta).canBeStarred(catalog) && !StockPreviewRules.noPaperCard(under: porta).canBeStarred(catalog)
             && paperStrip(porta).filter { !$0.isDigitalIntermediate }.allSatisfy { $0.canBeStarred(catalog) }
             && filmStrip().allSatisfy { $0.canBeStarred(catalog) },
             "favourites: the DI and No Paper cannot be starred; every stock's card can")
    // Favourites in the grid: the starred stocks under their makers' names, as every shelf.
    catalog.setFavourite("fujifilm_velvia_100", true, personal)
    catalog.setFavourite("kodak_portra_400", true, personal)
    catalog.setFavourite("kodak_vision3_500t", true, personal)
    let favGroups = groups(StockShelf.favourites.cards(films, catalog, personal: personal))
    c.expect(favGroups.map(\.brand) == ["Fujifilm", "Kodak"] && favGroups.last.map { names($0.cards) } == ["Portra 400", "Vision3 500T"],
             "favourites: the starred films under their makers' names -- \(favGroups.map { ($0.brand, names($0.cards)) })")
    for id in ["fujifilm_velvia_100", "kodak_portra_400", "kodak_vision3_500t"] { catalog.setFavourite(id, false, personal) }
    c.expect(favSuite.object(forKey: StockPersonal.storedKey) == nil, "favourites: every star put off, no record is left")

    // ---- the desktop's grid (2026-11-16) ----
    // Its columns are its width's: the column's 393 pt holds five cards, and a wider column more.
    c.expect(columns(393) == 5 && columns(560) == 7 && columns(700) == 9, "grid: 5 cards across at 393 pt, 7 at 560, 9 at 700 -- \(columns(393)), \(columns(560)), \(columns(700))")
    c.expect(columns(0) == 1 && columns(60) == 1 && columns(StockGridRule.minCell + 2 * StockGridRule.margin) == 1, "grid: never fewer than one card across")
    var lastColumns = 1, gridBad: [String] = []
    for width in stride(from: 96.0, through: 1400, by: 1) {
        let n = columns(width), cell = (width - 2 * StockGridRule.margin - StockGridRule.gap * Double(n - 1)) / Double(n)
        if n < lastColumns { gridBad.append("\(width): \(n) after \(lastColumns)") }
        if cell < StockGridRule.minCell - 1e-9 { gridBad.append("\(width): a card \(cell) wide") }
        // One more column would not fit: no room is left that a card could take.
        if (width - 2 * StockGridRule.margin - StockGridRule.gap * Double(n)) / Double(n + 1) >= StockGridRule.minCell { gridBad.append("\(width): room for \(n + 1)") }
        if broken == .none, abs(StockGridRule.cell(width: width) - cell) > 1e-9 { gridBad.append("\(width): the rule's card is not the width's share") }
        lastColumns = n
    }
    c.expect(gridBad.isEmpty, "grid: at every width the most cards of 64 pt that fit, never fewer as it widens -- \(gridBad.prefix(3))")
    // The interface scale lays the page out in 1/f of the window (`InterfaceScale`): the same window holds fewer cards across at a larger scale.
    c.expect(columns(700 / 1.5) < columns(700) && columns(700 / 0.8) > columns(700), "grid: a larger interface scale, fewer cards across the same window's column")
    // Half the old card (100 x 84), by area, its name under it.
    let cell393 = StockGridRule.cell(width: 393), image393 = StockGridRule.imageHeight(width: 393)
    c.expect(abs(cell393 - 65.8) < 0.01 && image393 == 55 && (cell393 * image393) / (100 * 84) < 0.5 && (cell393 * image393) / (100 * 84) > 0.4,
             "grid: at 393 pt a card's picture is 65.8 x 55, under half the old card -- \(cell393) x \(image393)")
    let row393 = StockGridRule.rowHeight(width: 393)
    let least393 = StockGridRule.minHeight(width: 393)
    c.expect(row393 == 85.0 && least393 == 127.0, "grid: a row is its picture and two lines of name (85); the least strip a header over a row (127) -- \(row393), \(least393)")
    func content(_ cards: [StockPreviewCard], _ width: Double) -> Double {
        StockGridRule.contentHeight(groups: groups(cards).map { (headed: !$0.brand.isEmpty, count: $0.cards.count) }, width: width)
    }
    // Four makers' headers and 1 + 2 + 1 + 5 rows at five across, 8 pt between the 13 lines.
    let filmTall = content(films, 393), paperTall = content(shelfFor(porta), 393)
    c.expect(filmTall == 961.0, "grid: the film strip's cards at 393 pt are 961 pt tall (4 + 4 x 22 + 9 x 85 + 12 x 8 + 8) -- \(filmTall)")
    c.expect(paperTall == 559.0, "grid: the paper strip's at 393 pt, 559 (4 + 3 x 22 + 5 x 85 + 7 x 8 + 8) -- \(paperTall)")
    let noCards = content([], 393), noPaperAlone = content([StockPreviewRules.noPaperCard(under: porta)], 393)
    c.expect(noCards == 0.0 && noPaperAlone == 97.0, "grid: no cards, no height; No Paper alone, one row and no header -- \(noCards), \(noPaperAlone)")

    // ---- where a strip rests (the review of 2026-11-16: never mid-row under the held name) ----
    func layout(_ cards: [StockPreviewCard], _ width: Double) -> StockGridLayout {
        StockGridLayout(groups: groups(cards).map { (headed: !$0.brand.isEmpty, count: $0.cards.count) }, width: width)
    }
    let paperLaid = layout(shelfFor(porta), 393), filmLaid = layout(films, 393)
    c.expect(paperLaid.content == paperTall && filmLaid.content == filmTall && paperLaid.rows.count == 5 && filmLaid.rows.count == 9,
             "layout: as tall as the cards (\(filmLaid.content), \(paperLaid.content)), 9 rows of film and 5 of paper at 393 pt")
    c.expect(paperLaid.rows.map(\.top) == [4, 127, 250, 373, 466] && paperLaid.names == [97, 220, 343],
             "layout: the paper's rows and its makers' names where they are laid -- \(paperLaid.rows.map(\.top)), \(paperLaid.names)")
    c.expect(paperLaid.rows.indices.map(paperLaid.rest) == [0, 97, 220, 343, 436],
             "rest: a row rests with its maker's name at the strip's top, itself straight under it -- \(paperLaid.rows.indices.map(paperLaid.rest))")
    c.expect(paperLaid.rows.flatMap { Array($0.cards) } == Array(0..<shelfFor(porta).count) && paperLaid.row(ofCard: 2) == 1 && paperLaid.row(ofCard: 10) == 4,
             "layout: every card in one row, in the strip's order")
    // A laptop's least strip (127 pt): the cards end at 432, mid-row; the strip's foot is the last row's rest, 436.
    c.expect(foot(paperLaid, 127) == 436 && (broken != .none || paperLaid.trailing(window: 127) == 4), "foot: the strip stops with a row straight under the name -- \(foot(paperLaid, 127))")
    c.expect(paperLaid.foot(window: 559) == 0 && paperLaid.trailing(window: 559) == 0 && paperLaid.foot(window: 900) == 0,
             "foot: a strip that shows all its cards does not scroll")
    var restBad: [String] = []
    var taps2 = 0
    for (name, cards) in [("film", films), ("paper", shelfFor(porta)), ("cine", cineFilms), ("no paper alone", [StockPreviewRules.noPaperCard(under: porta)])] {
        for width in [393.0, 464, 560] {
            let l = layout(cards, width)
            /// Whether the held name's foot cuts a row at `offset`: part of it over the line, part under.
            func cut(_ offset: Double) -> Int? {
                let pinned = l.pinned(at: offset)
                return l.rows.firstIndex { $0.top - offset < pinned - 0.01 && $0.top + l.rowHeight - offset > pinned + 0.01 }
            }
            for window in [127.0, 150, 180, 220, 267, 321, 500] {
                let end = foot(l, window)
                if let row = cut(end), l.content > window { restBad.append("\(name) \(width) \(window): at its foot (\(end)) row \(row) is cut by the name") }
                if broken == .none, l.trailing(window: window) >= l.rowHeight + StockGridRule.brandHeader + 2 * StockGridRule.gap {
                    restBad.append("\(name) \(width) \(window): \(l.trailing(window: window)) pt of empty room at the foot")
                }
                for offset in stride(from: 0.0, through: end, by: 3) {
                    // A card goes under the name as one thing: no row is drawn whose pictures are wholly gone.
                    let pinned = l.pinned(at: offset), hidden = gone(l, at: offset, window: window)
                    for (i, row) in l.rows.enumerated() where i >= hidden {
                        if row.top + l.imageHeight - offset <= pinned, row.top + l.rowHeight - offset > pinned {
                            restBad.append("\(name) \(width) \(window) at \(offset): row \(i)'s names show under the name without their pictures")
                        }
                    }
                    for i in 0..<min(hidden, l.rows.count) where l.rows[i].top + l.imageHeight - offset > pinned + 0.01 {
                        restBad.append("\(name) \(width) \(window) at \(offset): row \(i) is not drawn with a picture still in the window")
                    }
                    for row in l.rows.indices {
                        let to = reveal(l, row: row, from: offset, window: window)
                        let top = l.rows[row].top - to, whole = top >= l.pinned(at: to) - 0.01 && top + l.rowHeight <= window + 0.01
                        if !whole { restBad.append("\(name) \(width) \(window): row \(row) chosen from \(offset) ends cut, at \(to)") }
                        let was = l.rows[row].top - offset
                        let seen = was >= pinned - 0.01 && was + l.rowHeight <= window + 0.01
                        let footCut = was >= pinned - 0.01 && was < window && !seen
                        if seen, to != offset { restBad.append("\(name) \(width) \(window): row \(row) was wholly seen at \(offset) and moved to \(to)") }
                        // Chosen from elsewhere and not wholly seen (off screen, or cut by the name or the foot): it rests
                        // straight under its maker's name, and no row is left cut above it.
                        if !seen, let above = cut(to) { restBad.append("\(name) \(width) \(window): row \(row) revealed from \(offset) to \(to) leaves row \(above) cut under the name") }
                        if !seen, abs(to - min(l.rest(row), foot(l, window))) > 0.01 { restBad.append("\(name) \(width) \(window): row \(row) revealed from \(offset) is at \(to), not at its rest") }
                        // 0.2's rule, up and down: a card tapped where it is seen; a second tap at the first's point lands on
                        // the row it chose, or on no row. (A tapped card cut by the foot comes the least way up for that.)
                        guard was < window, was + l.rowHeight > pinned else { continue }
                        let tapped = reveal(l, row: row, from: offset, window: window, tapped: true)
                        let tappedTop = l.rows[row].top - tapped
                        if tappedTop < l.pinned(at: tapped) - 0.01 || tappedTop + l.rowHeight > window + 0.01 { restBad.append("\(name) \(width) \(window): row \(row) tapped at \(offset) ends cut, at \(tapped)") }
                        if footCut, broken == .none, abs(tapped - (offset + was + l.rowHeight - window)) > 0.01 { restBad.append("\(name) \(width) \(window): row \(row) tapped at the foot moved more than the least way") }
                        for y in stride(from: max(was, pinned) + 0.5, to: min(was + l.rowHeight, window), by: 6) {
                            taps2 += 1
                            if let under = l.rows.firstIndex(where: { $0.top - tapped <= y && y < $0.top - tapped + l.rowHeight }), under != row {
                                restBad.append("\(name) \(width) \(window) at \(offset): a tap at \(y) chose row \(row), a second tap there row \(under)")
                            }
                        }
                    }
                }
            }
        }
    }
    c.expect(taps2 > 50_000, "rest: \(taps2) taps modelled up and down")
    c.expect(restBad.isEmpty, "rest: no name without its picture, a chosen row whole, at rest under its maker's name, never moved from under the pointer -- \(restBad.count), e.g. \(restBad.prefix(2))")
    // The capture the review named: Vision3 500T chosen from the top of a 127 pt film strip, and the paper it brings.
    let vision = films.firstIndex { $0.film == "kodak_vision3_500t" }!, visionRow = filmLaid.row(ofCard: vision)!
    let toVision = reveal(filmLaid, row: visionRow, from: 0, window: 127)
    c.expect(toVision == filmLaid.rest(visionRow) && filmLaid.rows[visionRow].top - toVision == 30 && gone(filmLaid, at: toVision, window: 127) == visionRow,
             "rest: Vision3 500T, chosen off screen, stands 30 pt down a 127 pt strip, under KODAK, and no row above it is drawn -- at \(toVision)")
    let held = filmLaid.shown(at: toVision, window: 127)
    c.expect(held.held == 3 && held.push == 0 && held.rows == visionRow..<(visionRow + 1), "rest: there the fourth maker's name is held, and the one row is asked for -- \(held)")
    let pushing = paperLaid.shown(at: 97 + 110, window: 127)
    c.expect(pushing.held == 0 && pushing.push == -9, "names: the next maker's name, 13 pt under the top, has pushed the held one 9 pt out -- \(pushing)")

    // ---- the two heights ----
    // The column scrolls as one: a strip takes nothing from the other or from Decode. Dragged, it is as tall as
    // dragged, between a header over a row and its cards and the column's window; never dragged, it fits the room.
    let least = StockGridRule.minHeight(width: 393)           // 127
    let standardFilm = StockGridRule.defaultFilm(width: 393), standardPaper = StockGridRule.defaultPaper(width: 393)
    c.expect(standardFilm == 267.0 && standardPaper == 220.0, "heights: a strip never dragged is 267 (film) and 220 (paper) where the room holds them -- \(standardFilm), \(standardPaper)")
    func room(_ height: Double, film: Double? = nil, paper: Double? = nil, filmCards: Double = 961, paperCards: Double = 559,
              filmOpen: Bool = true, paperOpen: Bool = true) -> StripSplit.Room {
        StripSplit.Room(room: height, chrome: 83, lead: 41.5, restMin: 145,
                        film: .init(open: filmOpen, min: least, content: filmCards, dragged: film, standard: standardFilm),
                        paper: .init(open: paperOpen, min: least, content: paperCards, dragged: paper, standard: standardPaper))
    }
    let roomy = resolve(room(900))
    c.expect(roomy == StripSplit(film: 267, paper: 220), "heights: a roomy column, never dragged: the standard heights -- \(roomy)")
    let short = resolve(room(600))
    c.expect(short.film + short.paper <= 600 - 83 - 145 && short.film + short.paper > 600 - 83 - 145 - 2
             && short.film > least && short.paper > least && short.film < 267 && short.paper < 220 && short.film > short.paper,
             "heights: a shorter column, never dragged: both strips less by the same share, Decode's shortest part on screen -- \(short)")
    // A 16-inch laptop's column at 100 % (2026-11-16, the running app): 359 pt for Film & Paper.
    let laptop = resolve(room(359))
    c.expect(laptop == StripSplit(film: least, paper: least), "heights: a laptop's 359 pt, never dragged: a header over one row each -- \(laptop)")
    // Dragged: as dragged whatever the room holds beside it. What is under the strip moves down; the column scrolls.
    let dragged = resolve(room(359, film: 250))
    c.expect(dragged == StripSplit(film: 250, paper: least), "heights: the film dragged to 250 in that column is 250, the paper nobody dragged at its least -- \(dragged)")
    let both = resolve(room(359, film: 250, paper: 300))
    c.expect(both == StripSplit(film: 250, paper: 300), "heights: both dragged, both as dragged: neither takes from the other -- \(both)")
    // …up to what the column shows at once with the strip's header and grip (359 - 41.5), and up to its cards.
    let tallest = resolve(room(359, film: 5000, paper: 5000))
    c.expect(tallest == StripSplit(film: 317, paper: 317), "heights: a strip is never taller than the column shows with its header and grip -- \(tallest)")
    let capped = resolve(room(2000, film: 5000, paper: 5000))
    c.expect(capped == StripSplit(film: 961, paper: 559), "heights: a strip is never taller than its cards -- \(capped)")
    c.expect(resolve(room(900, film: 1, paper: 1)) == StripSplit(film: least, paper: least), "heights: nor shorter than a maker's header over one row")
    let oneRow = resolve(room(900, paper: 300, paperCards: 97))
    c.expect(oneRow.paper == 97 && oneRow.film == 267, "heights: a shelf of one row is as tall as its row, under the least height -- \(oneRow)")
    let foldedPaper = resolve(room(600, paperOpen: false))
    c.expect(foldedPaper.paper == 0 && foldedPaper.film == 267, "heights: a folded strip takes nothing, and the other has the room -- \(foldedPaper)")
    // A window made smaller holds a dragged strip to what it shows, and gives the height back.
    c.expect(resolve(room(300, film: 400)).film == 258 && resolve(room(900, film: 400)).film == 400,
             "heights: a dragged 400 in a 300 pt column is 258, and 400 again in a taller one")
    var splitBad: [String] = []
    for height in stride(from: 0.0, through: 1500, by: 7) {
        for (film, paper) in [(nil, nil), (267.0, 220.0), (127, nil), (nil, 900), (900, 300), (1, 1)] as [(Double?, Double?)] {
            let r = room(height, film: film, paper: paper), s = resolve(r)
            if s.film < least || s.paper < least { splitBad.append("\(height): under a header over a row \(s)") }
            if s.film > r.film.content || s.paper > r.paper.content { splitBad.append("\(height): taller than its cards \(s)") }
            if height >= 41.5 + least, s.film > height - 41.5 || s.paper > height - 41.5 { splitBad.append("\(height): taller than the column shows \(s)") }
            if film == nil, paper == nil, height >= 83 + 2 * least + 145, 83 + s.film + s.paper + 145 > height { splitBad.append("\(height): at rest Decode's shortest part is off screen \(s)") }
            if let film, film >= least, film <= r.most(r.film), s.film != film { splitBad.append("\(height): the film dragged to \(film), shown \(s.film)") }
            // The grips: wherever each is dragged, the strip is shown as the drag left it, and the other is not moved by it
            // once it was dragged itself.
            for grip in [StripSplit.Grip.film, .paper] {
                for travel in [-2000.0, -90, -1, 0, 1, 37, 90, 2000] {
                    let d = drag(grip, r, from: grip == .film ? s.film : s.paper, travel: travel)
                    var after = r
                    if grip == .film { after.film.dragged = d } else { after.paper.dragged = d }
                    let t = StripSplit.resolve(after)
                    if (grip == .film ? t.film : t.paper) != d { splitBad.append("\(height) \(grip) \(travel): dragged to \(d), shown \(t)") }
                    if d < least { splitBad.append("\(height) \(grip) \(travel): dragged under a header over a row, \(d)") }
                    if grip == .film, paper != nil, t.paper != s.paper { splitBad.append("\(height): the film's grip moved a dragged paper") }
                    if grip == .paper, film != nil, t.film != s.film { splitBad.append("\(height): the paper's grip moved a dragged film") }
                }
            }
        }
    }
    c.expect(splitBad.isEmpty, "heights: at every height each strip between its least and its most, a drag shown as dragged -- \(splitBad.count), e.g. \(splitBad.prefix(2))")
    let at900 = room(900), from900 = resolve(at900)
    c.expect(drag(.film, at900, from: from900.film, travel: 100) == 367 && drag(.film, at900, from: from900.film, travel: -500) == least,
             "grip: the film's, dragged down 100: 100 taller; dragged up past everything: a header over a row")
    c.expect(drag(.film, at900, from: from900.film, travel: 5000) == 858 && drag(.paper, at900, from: from900.paper, travel: 5000) == 559,
             "grip: dragged down past everything, a strip stops at what the column shows (858 of 900) or at its cards (559)")

    // Kept when a drag ends; a strip nobody dragged has no key.
    let heightsName = "stock_previews_selftest.heights"
    let heightsSuite = UserDefaults(suiteName: heightsName)!
    heightsSuite.removePersistentDomain(forName: heightsName)
    defer { heightsSuite.removePersistentDomain(forName: heightsName) }
    func written() -> [Double?] { [StockGridHeights.filmKey, StockGridHeights.paperKey].map { heightsSuite.object(forKey: $0) as? Double } }
    MainActor.assumeIsolated {
        let heights = StockGridHeights(defaults: heightsSuite)
        if broken == .heightsWrittenAtRest { heightsSuite.set(267.0, forKey: StockGridHeights.filmKey) }
        c.expect(heights.film == nil && heights.paper == nil && written() == [nil, nil], "heights: never dragged, none kept and none written -- \(written())")
        heights.drag(film: 300)
        if broken == .heightsWrittenAtRest { heights.save() }
        c.expect(heights.film == 300 && heights.paper == nil && written() == [nil, nil], "heights: a step of a drag is shown and not written -- \(written())")
        heights.drag(film: 340)
        heights.save()
        c.expect(written() == [340, nil], "heights: the drag's end writes the strip that was dragged, and not the other -- \(written())")
        let again = StockGridHeights(defaults: heightsSuite)
        c.expect(again.film == 340 && again.paper == nil, "heights: through a launch")
        // A window made smaller shows the strip shorter and keeps what was dragged.
        let small = resolve(room(300, film: again.film)), large = resolve(room(900, film: again.film))
        c.expect(small.film < 340 && large.film == 340 && written() == [340, nil], "heights: a short window shows it shorter; grown again, the height is back -- \(small.film), \(large.film)")
        again.drag(paper: 180)
        again.save()
        c.expect(written() == [340, 180], "heights: both kept, each under its own key")
    }

    return c
}

@main
struct StockPreviewsSelfTest {
    /// Favourites stays (the review of 2026-11-01): by row, through a new page and a launch; a kind does not.
    static func shelfMemory() {
        let name = "stock-shelf-memory-selftest"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        MainActor.assumeIsolated {
            var bad: [String] = []
            func hold(_ ok: Bool, _ what: String) { if !ok { bad.append(what) } }
            let m = StockShelfMemory(defaults: defaults)
            hold(m.shelf(.film, otherwise: .all) == .all && defaults.object(forKey: "develop.shelf.film.favourites") == nil, "nothing chosen: the page's, and nothing written")
            m.choose(.negative, on: .film)
            hold(StockShelfMemory(defaults: defaults).shelf(.film, otherwise: .all) == .all && defaults.object(forKey: "develop.shelf.film.favourites") == nil,
                 "a kind is not remembered")
            m.choose(.favourites, on: .film)
            hold(m.shelf(.film, otherwise: .all) == .favourites, "Favourites stands over the page's kind")
            hold(m.shelf(.paper, otherwise: .standard) == .standard, "the other row keeps its own")
            hold(defaults.bool(forKey: "develop.shelf.film.favourites"), "kept under develop.shelf.film.favourites")
            hold(StockShelfMemory(defaults: defaults).shelf(.film, otherwise: .all) == .favourites, "Favourites through a launch")
            m.choose(.favourites, on: .paper)
            hold(defaults.bool(forKey: "develop.shelf.paper.favourites"), "and the paper row's own key")
            m.choose(.all, on: .film)
            hold(m.shelf(.film, otherwise: .all) == .all, "another shelf ends it")
            hold(StockShelfMemory(defaults: defaults).shelf(.film, otherwise: .all) == .all, "and ends it for good")
            if !bad.isEmpty { print("FAIL shelf memory: \(bad)"); exit(1) }
        }
        defaults.removePersistentDomain(forName: name)
    }

    static func main() {
        shelfMemory()
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
