//  StockPreviewRules.swift — which cards Develop's strips hold, what each is rendered from, and its key.
//
//  design/v4 §2, step 1 (V5's Develop, step 1): the film strip, **each card the
//  frame itself developed through that film on the paper it was made for**, and
//  under it the paper strip, **each card the frame through the chosen film on
//  that paper**. `StockPreviews` renders them; this is the part with no pixel
//  and no page in it, so `tools/stock_previews_selftest.swift` holds it to its
//  rules on a Mac:
//
//  - **A slide film has no paper strip**: its film card is the film scanned, and
//    under it there is nothing to choose (the owner, 2026-10-09).
//  - **Silver goes on silver**: a black-and-white film's paper strip is the
//    silver paper alone; a colour film's is every colour paper. A paper that
//    cannot print the film is not a card of its strip, so nothing is ever
//    rendered on it.
//  - **The film strip goes shelf by shelf**: negative, positive, cine, black
//    and white, the catalogue's order on each; each black-and-white film on
//    the silver paper.
//  - **Under a black-and-white film the paper row shows every paper**
//    (`paperShelf`), the colour ones greyed: never chosen, never rendered.
//  - **A card is what its pair would give this frame**: the frame's own
//    settings with the card's film and paper put in through the model's rules —
//    Film Exposure, white balance, the crop, grain and halation and every other
//    setting that reaches the engine are the frame's. So the key is the whole
//    wire the card is rendered from: any setting that changes the picture
//    changes the key, and none that does not (`StockPreviewKey`).
//  - **What a card leaves out, by name**: the film's edge and the date (the
//    wire's `overscan_active` and `date_imprint_active` are off: they are
//    Format's, drawn round the page's own develop, and a card is the picture);
//    and Edit's adjustments after the print (V5's Layer 2), which are not the
//    develop. Nothing of the film or the print is left out or approximated.
//
//  Foundation only.

import CryptoKit
import Foundation

/// One card of a strip: the film and paper it shows the frame through.
struct StockPreviewCard: Identifiable, Hashable, Sendable {
    enum Strip: String, Hashable, Sendable { case film, paper }

    let strip: Strip
    let film: String
    /// The paper it is printed on; nil: scanned (a slide).
    let paper: String?

    var id: String { strip.rawValue + ":" + film + "|" + (paper ?? StockCatalog.scannedWord) }
    /// The stock the card is of — its name and its swatch: the film on the
    /// film strip, the paper on the paper strip.
    var stock: String { strip == .film ? film : (paper ?? film) }
    /// Its place in the scheduler (`RenderJob.slot`): one card a stock a strip.
    /// The paper strip under another film, or any card under another edit, is
    /// the same slot asked again, and replaces what was asked before.
    var slot: String { strip.rawValue + ":" + stock }

    /// The paper strip's last card, **the Digital Intermediate** (数字中间片, RFC-028; back in 2.2.1):
    /// the DI takes the paper's place, so it is chosen among the papers. Its id is the card's own and
    /// never a paper's: choosing it sets `FilmParams.digitalIntermediate` and leaves `printStock` as it
    /// was (the model's rule: "which paper" and "is there a paper" stay two questions).
    static let digitalIntermediate = "digital_intermediate"
    var isDigitalIntermediate: Bool { strip == .paper && paper == Self.digitalIntermediate }
}

enum StockPreviewRules {
    /// Every film, shelf by shelf -- negative, positive, cine, black and white
    /// (`StockShelf.film`; the owner, 2026-10-19: All mixed them "or it's gonna
    /// cause confusions") -- and in the catalogue's order on a shelf, each on
    /// the paper it was made for (`StockCatalog.ownPaper`); a slide scanned.
    static func filmStrip(_ catalog: StockCatalog = .shared) -> [StockPreviewCard] {
        let shelves = StockShelf.film.filter { $0 != .all }
        func shelf(_ film: Stock) -> Int { shelves.firstIndex { $0.holds(film) } ?? shelves.count }
        return catalog.films.enumerated()
            .sorted { (shelf($0.element), $0.offset) < (shelf($1.element), $1.offset) }
            .map { _, film in
                StockPreviewCard(strip: .film, film: film.id, paper: film.isPositive ? nil : catalog.ownPaper(of: film.id))
            }
    }

    /// The papers under `film`: none under a slide; under a black-and-white
    /// film the silver paper alone; under a colour film every colour paper.
    /// In the catalogue's order.
    static func paperStrip(under film: String, _ catalog: StockCatalog = .shared) -> [StockPreviewCard] {
        guard catalog.stock(film) != nil, !catalog.isSlide(film) else { return [] }
        let papers = catalog.papers.filter { catalog.canPrint(film: film, on: $0.id) }
            .map { StockPreviewCard(strip: .paper, film: film, paper: $0.id) }
        return papers + (takesDigitalIntermediate(film, catalog) ? [digitalIntermediateCard(under: film)] : [])
    }

    /// The DI is a colour negative's: a slide has no mask and no paper, and a black-and-white film's
    /// DI is not one the engine was measured for.
    static func takesDigitalIntermediate(_ film: String, _ catalog: StockCatalog = .shared) -> Bool {
        guard let stock = catalog.stock(film) else { return false }
        return !stock.isPositive && !stock.isMonochrome
    }

    static func digitalIntermediateCard(under film: String) -> StockPreviewCard {
        StockPreviewCard(strip: .paper, film: film, paper: StockPreviewCard.digitalIntermediate)
    }

    /// The paper card that is chosen for `params`: none under a slide, the DI's when it is on, the
    /// paper otherwise.
    static func chosenPaper(_ params: FilmParams, _ catalog: StockCatalog = .shared) -> String {
        if catalog.isSlide(params.filmStock) { return "" }
        return params.digitalIntermediate && !params.scanFilm ? StockPreviewCard.digitalIntermediate : params.printStock
    }

    /// The papers the strip *shows* under `film`: every paper, always, so the
    /// row never changes its length or goes away (the owner, 2026-10-19 for a
    /// black-and-white film; 2026-10-20 for every film, a slide's included:
    /// "instead of the current simply displays no paper, grey out every
    /// paper"). Only those of `paperStrip` can be chosen or are rendered; the
    /// rest are there greyed — every one of them under a slide.
    static func paperShelf(under film: String, _ catalog: StockCatalog = .shared) -> [StockPreviewCard] {
        catalog.papers.map { StockPreviewCard(strip: .paper, film: film, paper: $0.id) } + [digitalIntermediateCard(under: film)]
    }

    /// Whether a paper can print some film on the film row's shelf (the owner,
    /// 2026-10-20: "when the user is filtering the available film … only
    /// selectable papers are shown as available, everything else greys out"):
    /// on All every paper; on Positive none, a slide is scanned; on B&W the
    /// silver paper; on a colour shelf the colour papers.
    static func paperServes(_ paper: String, filmShelf: StockShelf, _ catalog: StockCatalog = .shared) -> Bool {
        guard filmShelf != .all else { return true }
        if paper == StockPreviewCard.digitalIntermediate {
            return catalog.films.contains { filmShelf.holds($0) && takesDigitalIntermediate($0.id, catalog) }
        }
        return catalog.films.contains { filmShelf.holds($0) && !$0.isPositive && catalog.canPrint(film: $0.id, on: paper) }
    }

    /// The settings a card is rendered with: the frame's own, with the card's
    /// film and paper put in as the model puts them in (`print(on:)`: printed,
    /// and no digital intermediate) — or the film scanned — and then held to
    /// the film, so the wire can never print a slide or a colour film on silver.
    static func params(_ card: StockPreviewCard, from frame: FilmParams, _ catalog: StockCatalog = .shared) -> FilmParams {
        var p = frame
        p.filmStock = card.film
        if card.isDigitalIntermediate, takesDigitalIntermediate(card.film, catalog) {
            p.scanFilm = false
            p.digitalIntermediate = true
        } else if let paper = card.paper, !catalog.isSlide(card.film) {
            p.printStock = paper
            p.scanFilm = false
            p.digitalIntermediate = false
        } else {
            p.scanFilm = true
        }
        return p.heldToItsFilm(catalog: catalog)
    }

    /// The frame's edit as a card renders it: `params` in place of its own,
    /// and the rest as it is (the decode, the crop, the film's framing).
    static func edit(_ card: StockPreviewCard, from frame: FrameEdit, _ catalog: StockCatalog = .shared) -> FrameEdit {
        var e = frame
        e.params = params(card, from: frame.params, catalog)
        return e
    }
}

// MARK: - The strips under a finger

/// What a tap on a card chooses: the card's film or its paper.
enum StockPick: Equatable, Sendable {
    case film(String)
    case paper(String)
    /// The paper strip's Digital Intermediate card.
    case digitalIntermediate
}

/// Where a card lies in its strip's viewport: wholly inside it, cut by an
/// edge, or out of it.
enum StripPlacement: Equatable, Sendable {
    case whole, cut, off

    /// From the card's edges in the strip's own coordinates (0 is the strip's
    /// leading edge) and the strip's width; half a point either side is inside.
    static func of(minX: Double, maxX: Double, width: Double) -> StripPlacement {
        if maxX <= 0 || minX >= width { return .off }
        return minX >= -0.5 && maxX <= width + 0.5 ? .whole : .cut
    }
}

/// How a strip moves when its chosen card changes.
enum StripReveal: Equatable, Sendable {
    /// It does not: the card is wholly on screen already.
    case stay
    /// The least that brings the card wholly on screen (`scrollTo` with no anchor).
    case nearest
    /// The card to the middle: it was nowhere on screen.
    case centre
}

extension StockPreviewRules {
    /// A tap on `card` with the frame on `film` and `paper`: what it chooses,
    /// or nil when the card is the one chosen already — a second tap on the
    /// chosen card changes nothing (it does not put the film's own paper back
    /// over a paper picked since).
    static func pick(_ card: StockPreviewCard, film: String, paper: String) -> StockPick? {
        switch card.strip {
        case .film: return card.film == film ? nil : .film(card.film)
        case .paper:
            guard let p = card.paper, p != paper else { return nil }
            return card.isDigitalIntermediate ? .digitalIntermediate : .paper(p)
        }
    }

    /// **A strip never moves a card the finger can see** (0.2, a
    /// tester: "选中一个胶片，再次点击这个胶片，会跳到其他胶片"). The chosen
    /// card's row was scrolled to centre it on every change, so a card tapped
    /// off the middle slid away at once and its neighbour took its place under
    /// the finger: the next tap there chose that neighbour. A tapped card is
    /// on screen, so it stays where it is (or, cut by an edge, comes the least
    /// way in); only a choice made where the row cannot be seen — the paper the
    /// film recommends, an undo — is brought to the middle.
    static func reveal(_ chosen: StripPlacement?) -> StripReveal {
        switch chosen {
        case .whole: return .stay
        case .cut: return .nearest
        case .off, nil: return .centre
        }
    }
}

/// The sizes, and why each.
enum StockPreviewSize {
    /// The card: 100 × 84 pt (design/v4 §6), drawn at 3× on most reference devices the
    /// app runs on (2× on an SE, an XR or an 11) — so 300 × 252 pixels is the
    /// most a card shows.
    static let cardPixels = PixelSize(width: 300, height: 252)
    /// The frame is opened at the meter's own size, so the session meters
    /// what the page's develop meters (the engine meters every session at
    /// 1,600 px, `kMeterLongEdge`, and a picture opened smaller would be
    /// metered smaller: AGENTS.md, "a reference preview size must not change the
    /// meter"). The open is a buffer of 16 B a pixel, 29 MB for 1,600 × 1,200,
    /// made once a strip (`StockPreviews`).
    static let openLongEdge = 1600
    /// What the engine renders: its live tier at the smallest it takes
    /// (`preview_long_edge`'s range is 800…8192). The live tier, labelled as
    /// that, never as `full`.
    static let renderLongEdge = 800

    /// What a card keeps of its render: the smallest picture that covers the
    /// card at 3× in this picture's shape — 336 × 252 for a 4:3 frame on its
    /// side, 300 × 400 upright — so a card aspect-fills without enlarging.
    static func cover(_ picture: PixelSize) -> PixelSize {
        guard picture.width > 0, picture.height > 0 else { return cardPixels }
        let k = max(Double(cardPixels.width) / Double(picture.width), Double(cardPixels.height) / Double(picture.height))
        guard k < 1 else { return picture }
        return PixelSize(width: Int((Double(picture.width) * k).rounded(.up)), height: Int((Double(picture.height) * k).rounded(.up)))
    }
}

/// A card's key: what its picture is made from, as a word. Every input that
/// changes the picture is in it — the whole wire the card is rendered from
/// (the pair, Film Exposure, the crop, grain and halation, Scene Placement,
/// the enlarger), the decode of a RAW, the film's framing cut by the host,
/// the file and its size, the engine's identity, and the sizes above — and
/// nothing else. The same 16 hex name the card's file under `Previews`.
enum StockPreviewKey {
    /// Moved whenever the way a card is made changes, so cards made the old way are made again.
    static let version = "stock-preview.2"

    static func of(wire: [String: ParamValue], decode: String, cut: String?, source: String, engine: String) -> String {
        var hash = SHA256()
        func add(_ s: String) { hash.update(data: Data(s.utf8)); hash.update(data: Data([0])) }
        add(version)
        add(engine)
        add(source)
        add("open \(StockPreviewSize.openLongEdge) render \(StockPreviewSize.renderLongEdge) card \(StockPreviewSize.cardPixels.width)x\(StockPreviewSize.cardPixels.height)")
        add(decode)
        add(cut.map { "cut " + $0 } ?? "")
        // A frame with no Decode curve keys its cards as before the field existed.
        for key in wire.keys.sorted() where !(key == "scene_curve" && wire[key] == .string("")) {
            guard let value = wire[key] else { continue }
            add(key)
            switch value {
            case .double(let number): add("double:" + String(number.bitPattern, radix: 16))
            case .bool(let flag): add(flag ? "bool:true" : "bool:false")
            case .string(let string): add("string:" + string)
            }
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Eight hex of a word: what a frame's pixels are read from, in its cards' names.
    static func tag(_ word: String) -> String {
        SHA256.hash(data: Data(word.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// The shelves the two strips can be narrowed to, each strip's own pill
/// (a tester's want of 2026-10-18, the owner's list): films by what they are,
/// papers by colour or silver. **Paper has no Film shelf**: the two cine print
/// films sit on Standard with the colour papers, so nothing says a cine print
/// is only for a cine negative.
enum StockShelf: String, CaseIterable, Identifiable, Sendable {
    case all, negative, positive, cine, mono
    case standard

    var id: String { rawValue }

    static let film: [StockShelf] = [.all, .negative, .positive, .cine, .mono]
    static let paper: [StockShelf] = [.all, .standard, .mono]

    /// Its word in the pill and the menu. The cine shelf is the owner's "Film",
    /// 电影 in Chinese; in English "Cine", so the pill never reads "Film · Film".
    var title: String {
        switch self {
        case .all: L("All")
        case .negative: L("Negative")
        case .positive: L("Positive")
        case .cine: L("Cine")
        case .mono: L("B&W")
        case .standard: L("Standard")
        }
    }

    /// Whether `stock` is on this shelf. A film is on exactly one shelf beside
    /// All, and so is a paper.
    func holds(_ stock: Stock) -> Bool {
        switch self {
        case .all: true
        case .negative: stock.isFilm && !stock.isPositive && !stock.isCine && !stock.isMonochrome
        case .positive: stock.isFilm && stock.isPositive
        case .cine: stock.isFilm && stock.isCine && !stock.isMonochrome
        case .mono: stock.isMonochrome
        case .standard: stock.isPaper && !stock.isMonochrome
        }
    }

    /// The cards of a strip on this shelf, in the strip's order.
    func cards(_ cards: [StockPreviewCard], _ catalog: StockCatalog = .shared) -> [StockPreviewCard] {
        // The DI card is on the colour papers' shelf: it takes a colour negative.
        self == .all ? cards : cards.filter { $0.isDigitalIntermediate ? self == .standard : (catalog.stock($0.stock).map(holds) ?? false) }
    }
}
