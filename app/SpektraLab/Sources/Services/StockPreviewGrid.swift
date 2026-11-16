//  StockPreviewGrid.swift — the desktop's film and paper browser: its order, its grid and its two heights.
//
//  The owner, 2026-11-16 (2.4.1): "film and paper selections will be optimized for desktop logic, we're switching
//  from the current horizontal scroll to vertical scroll, each film / paper preview pill will be half the size as the
//  current style, with the text moved to the bottom of each preview, similar to how library is managed. […] how many
//  papers can be filled horizontally will be managed together by the UI scale / width of left panel. How much
//  vertical space each film / paper selection will occupy is also draggable. The split line can be dragged and
//  maximum / minimum height should also be managed and considered throughly. Cine also get their unique cine pill
//  with accent […]. The new arrangement order will also be: (in alphabetical order): Brand name -> film name […].
//  The brand name should also take presence where appropriate."
//
//  This is the part of it with no view in it, so `tools/stock_previews_selftest.swift` holds it to its rules:
//
//  - **Brand, then name** (`brandOrder`): the makers in alphabetical order, a maker's stocks by the name their card
//    wears, a number in a name by its value (Vision3 50D before Vision3 200T), **a push card straight after its
//    film** (Portra 800, +1, +2) whatever it is called. It replaces the strips' shelf-by-shelf order of 2026-10-19
//    on both strips; a shelf (Negative, Cine, Favourites …) still narrows the strip and keeps this order.
//  - **A cine stock is filed under its maker** like any other and wears the CINE pill (`wearsCinePill`): the order
//    has no exception, and the Cine shelf is still the way to see them alone.
//  - **The paper strip leads with the two cards that are no paper's**, No Paper first (the owner, 2026-11-16) and the
//    Digital Intermediate beside it, under no maker's header (`StockPreviewRules.paperShelf`); the papers follow by
//    maker.
//  - **The grid's columns are its width's** (`StockGridRule.columns`): as many cards of at least `minCell` as fit.
//    The width is the column's in the page's own points, so the interface scale (which lays the page out in 1/f of
//    the window) and the column's dragged width decide it together.
//  - **Each strip is as tall as it was dragged** (`StripSplit`, `StockGridHeights`): never shorter than a maker's
//    header over one row of cards, never taller than its cards, and never taller than the column shows at once
//    with the strip's header and grip. The column scrolls as one, so a strip takes nothing from the other or from
//    Decode: what is under it moves down. A strip nobody dragged fits the room (more rows in a tall window, one in
//    a short one). A window made smaller holds a dragged strip to what it shows and gives the height back when it
//    grows. Two keys, written when a drag ends: a height never dragged is not on disk.
//
//  Foundation only.

import Foundation
import Observation

// MARK: - brand, then name

extension Stock {
    /// The maker, as the grid's headers name it: the name's first word ("Kodak", "Fujifilm", "CineStill", "Ilford").
    /// The check holds every stock's id to begin with it, so a maker of two words fails there and not on the page.
    var brand: String { name.split(separator: " ").first.map(String.init) ?? name }
}

extension StockCatalog {
    /// How far a push card is pushed, and the film it is a card of (`favouriteID`'s rule): 0 and itself for a film.
    func push(of id: String) -> (base: String, level: Int) {
        let base = favouriteID(of: id)
        guard base != id, let level = Int(id.dropFirst(base.count).drop { !$0.isNumber }) else { return (id, 0) }
        return (base, level)
    }
}

/// A maker's cards in a strip's grid, under its name.
struct StockBrandGroup: Identifiable, Equatable, Sendable {
    /// The maker; empty for the cards that are no maker's (No Paper, the Digital Intermediate): no header.
    let brand: String
    let cards: [StockPreviewCard]
    var id: String { brand }
}

extension StockPreviewRules {
    /// Two names as a reader files them: case-blind, a number by its value, the same in every language.
    static func filed(_ a: String, before b: String) -> Bool { filing(a, b) == .orderedAscending }

    private static func filing(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .numeric], range: nil, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// `stocks` by maker, then by the name on the card; a push card straight after the film it pushes. Sorted once
    /// for a list of a catalogue (`Filed`): the strips read their order at every draw of the panel, a slider's
    /// every step among them.
    static func brandOrder(_ stocks: [Stock], _ catalog: StockCatalog = .shared) -> [Stock] {
        Filed.shared.order(stocks, in: catalog) { sorted(stocks, catalog) }
    }

    private static func sorted(_ stocks: [Stock], _ catalog: StockCatalog) -> [Stock] {
        struct Card { let stock: Stock; let base: String; let level: Int }
        let cards = stocks.map { stock -> Card in
            let push = catalog.push(of: stock.id)
            return Card(stock: stock, base: catalog.stock(push.base)?.shortName ?? stock.shortName, level: push.level)
        }
        return cards.sorted { a, b in
            for step in [filing(a.stock.brand, b.stock.brand), filing(a.base, b.base)] where step != .orderedSame {
                return step == .orderedAscending
            }
            if a.level != b.level { return a.level < b.level }
            let names = filing(a.stock.shortName, b.stock.shortName)
            return names == .orderedSame ? a.stock.id < b.stock.id : names == .orderedAscending
        }.map(\.stock)
    }

    /// The orders made so far, by the list and the catalogue they were made from; read from any thread.
    private final class Filed: @unchecked Sendable {
        static let shared = Filed()
        private struct Key: Hashable { let stocks: [Stock]; let catalog: [Stock] }
        private let lock = NSLock()
        private var orders: [Key: [Stock]] = [:]

        func order(_ stocks: [Stock], in catalog: StockCatalog, make: () -> [Stock]) -> [Stock] {
            let key = Key(stocks: stocks, catalog: catalog.stocks)
            lock.lock()
            if let kept = orders[key] { lock.unlock(); return kept }
            lock.unlock()
            let made = make()
            lock.lock(); orders[key] = made; lock.unlock()
            return made
        }
    }

    /// A strip's cards under their makers, in the strip's order: each run of one maker's cards is a group. The
    /// cards that are no stock's are a group with no name.
    static func groups(_ cards: [StockPreviewCard], _ catalog: StockCatalog = .shared) -> [StockBrandGroup] {
        var groups: [StockBrandGroup] = []
        var brand = "", run: [StockPreviewCard] = []
        for card in cards {
            let own = catalog.stock(card.stock)?.brand ?? ""
            if own != brand, !run.isEmpty { groups.append(StockBrandGroup(brand: brand, cards: run)); run = [] }
            brand = own
            run.append(card)
        }
        if !run.isEmpty { groups.append(StockBrandGroup(brand: brand, cards: run)) }
        return groups
    }

    /// Whether a card wears the CINE pill: a motion-picture stock's, the camera films and the print films alike.
    static func wearsCinePill(_ card: StockPreviewCard, _ catalog: StockCatalog = .shared) -> Bool {
        catalog.stock(card.stock)?.isCine ?? false
    }
}

// MARK: - the grid

/// The grid a strip's cards are laid in: half the old card (100 × 84 pt, its name on the picture), the name under
/// the picture as the library's tiles have theirs. Half by area: at the narrowest column five cards across are
/// 66 × 55 pt, 0.43 of the old card — at half its width a paper's name ("Crystal Archive II") no longer fits two
/// lines of type that can be read.
enum StockGridRule {
    /// The narrowest a card is laid: one more column is added only when every card keeps this.
    static let minCell = 64.0
    /// Between cards, across and down, and between a maker's header and its first row.
    static let gap = 8.0
    /// Either side of the grid: the column's own margin, where its headers' words start.
    static let margin = 16.0
    /// A card's picture, as the old card: 100 × 84.
    static let imageAspect = 0.84
    /// Under the picture: 4 pt, then two lines of the name.
    static let captionGap = 4.0
    static let caption = 26.0
    /// A maker's name over its cards.
    static let brandHeader = 22.0
    /// Over the first line and under the last, inside the strip's scroll: room for the chosen card's ring.
    static let padTop = 4.0
    static let padBottom = 8.0

    /// How many cards across a grid `width` wide (the column's width, in the page's points).
    static func columns(width: Double) -> Int {
        max(1, Int(((width - 2 * margin + gap) / (minCell + gap)).rounded(.down)))
    }

    /// A card's width there: the columns share the width exactly.
    static func cell(width: Double) -> Double {
        let n = Double(columns(width: width))
        return max((width - 2 * margin - gap * (n - 1)) / n, 1)
    }

    static func imageHeight(width: Double) -> Double { (cell(width: width) * imageAspect).rounded() }

    /// A row of cards: the picture, and the name under it.
    static func rowHeight(width: Double) -> Double { imageHeight(width: width) + captionGap + caption }

    /// A strip's cards laid out, top to bottom: each group its header (where it has a name) and its rows.
    static func contentHeight(groups: [(headed: Bool, count: Int)], width: Double) -> Double {
        let n = columns(width: width), row = rowHeight(width: width)
        var lines = 0, height = 0.0
        for group in groups where group.count > 0 {
            if group.headed { lines += 1; height += brandHeader }
            let rows = (group.count + n - 1) / n
            lines += rows; height += Double(rows) * row
        }
        guard lines > 0 else { return 0 }
        return padTop + height + gap * Double(lines - 1) + padBottom
    }

    /// The least a strip is dragged to: a maker's header over one row of cards.
    static func minHeight(width: Double) -> Double { padTop + brandHeader + gap + rowHeight(width: width) + padBottom }

    /// A strip never dragged, where the room holds it (`StripSplit.resolve`): the film's two rows and half of a
    /// third (the cut row says there is more), the paper's two.
    static func defaultFilm(width: Double) -> Double { (minHeight(width: width) + 1.5 * (rowHeight(width: width) + gap)).rounded() }
    static func defaultPaper(width: Double) -> Double { (minHeight(width: width) + rowHeight(width: width) + gap).rounded() }
}

// MARK: - where a strip rests

/// A strip's cards laid out top to bottom — where each row and each maker's name is — and what follows from where
/// the strip is scrolled to. The review of 2026-11-16: a strip that rested mid-row showed the row above's names
/// under the held maker's name with their pictures gone ("it reads as broken"). So:
///
/// - **A row has a place of rest** (`rest`): straight under its maker's name, the name at the strip's top. A card
///   chosen where it could not be seen is brought there, never to the middle (`reveal`).
/// - **The strip's foot is a place of rest too** (`foot`, `trailing`): it scrolls just far enough past its last
///   card for a row to stand under the name there, less than a row's worth of empty room.
/// - **A card goes under the name as one thing** (`Shown.gone`): a row whose pictures are wholly under the held
///   name is not drawn at all, so no name is ever left showing without its picture, wherever a wheel leaves the
///   strip. Between rests a row is cut as any scrolled row is: part of its pictures, and its names whole.
///
/// No snapping of the wheel to rows (the third thing the review asked to be weighed): a scroll's end is UIKit's on
/// this Mac build, where a posted wheel does not reach a scroll view, so whether a snap fights a trackpad's glide or
/// swallows a mouse wheel's single clicks could not be seen; and with a row drawn whole or not at all no place a
/// wheel leaves the strip shows an orphaned name.
struct StockGridLayout: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        /// Its top among the strip's cards, from the strip's own top.
        let top: Double
        /// Whether a maker's name stands over its group.
        let headed: Bool
        /// Which of the strip's cards it holds.
        let cards: Range<Int>
    }

    let rows: [Row]
    /// Each maker's name's top, in order.
    let names: [Double]
    let rowHeight: Double
    let imageHeight: Double
    /// The cards' height: `StockGridRule.contentHeight`.
    let content: Double

    init(groups: [(headed: Bool, count: Int)], width: Double) {
        let across = StockGridRule.columns(width: width)
        rowHeight = StockGridRule.rowHeight(width: width)
        imageHeight = StockGridRule.imageHeight(width: width)
        var rows: [Row] = [], names: [Double] = []
        var y = StockGridRule.padTop, card = 0
        for group in groups where group.count > 0 {
            if group.headed {
                names.append(y)
                y += StockGridRule.brandHeader + StockGridRule.gap
            }
            for at in stride(from: 0, to: group.count, by: across) {
                let n = Swift.min(across, group.count - at)
                rows.append(Row(top: y, headed: group.headed, cards: (card + at)..<(card + at + n)))
                y += rowHeight + StockGridRule.gap
            }
            card += group.count
        }
        self.rows = rows
        self.names = names
        content = rows.isEmpty ? 0 : y - StockGridRule.gap + StockGridRule.padBottom
    }

    func row(ofCard index: Int) -> Int? { rows.firstIndex { $0.cards.contains(index) } }

    /// What stands over a row at rest: its maker's name and the gap under it, or the strip's own top margin.
    func lead(_ row: Int) -> Double {
        rows[row].headed ? StockGridRule.brandHeader + StockGridRule.gap : StockGridRule.padTop
    }

    /// Where the strip is scrolled to with `row` at rest: straight under its maker's name.
    func rest(_ row: Int) -> Double { row == 0 ? 0 : Swift.max(rows[row].top - lead(row), 0) }

    /// The furthest the strip scrolls in a window `window` tall: the first place of rest at or past where its
    /// cards end; nowhere where they all fit.
    func foot(window: Double) -> Double {
        let natural = content - window
        guard natural > 0 else { return 0 }
        return rows.indices.lazy.map(rest).first { $0 >= natural - 0.5 } ?? natural
    }

    /// The empty room under the last card that lets the strip reach its foot.
    func trailing(window: Double) -> Double { Swift.max(foot(window: window) - Swift.max(content - window, 0), 0) }

    /// The maker whose name is held at the strip's top at `offset`: the last one at the top or past it.
    func held(at offset: Double) -> Int? { names.lastIndex { $0 <= offset + 0.01 } }

    /// How much of the strip's top the held name covers.
    func pinned(at offset: Double) -> Double { held(at: offset) == nil ? 0 : StockGridRule.brandHeader }

    /// What the strip shows scrolled to `offset`.
    struct Shown: Equatable, Sendable {
        /// The maker whose name is held at the top, among the strip's names.
        var held: Int?
        /// How far the next maker's name, coming up under it, has pushed the held one out (0 or less).
        var push: Double
        /// The rows from the first that are not drawn: their pictures are wholly under the held name or past the top.
        var gone: Int
        /// The rows drawn in the window, whole or cut: their cards are asked for.
        var rows: Range<Int>
    }

    func shown(at offset: Double, window: Double) -> Shown {
        let held = held(at: offset), pinned = pinned(at: offset)
        var push = 0.0
        if let held, held + 1 < names.count {
            // To half a point: the name moves only while the next one is within a name's height of the top.
            push = Swift.min(((names[held + 1] - offset - StockGridRule.brandHeader) * 2).rounded() / 2, 0)
        }
        let gone = rows.firstIndex { $0.top + imageHeight - offset > pinned + 0.01 } ?? rows.count
        let last = rows.lastIndex { $0.top - offset < window } ?? -1
        return Shown(held: held, push: push, gone: gone, rows: gone..<Swift.max(last + 1, gone))
    }

    /// Where the strip goes when the card in `row` is chosen, from `offset`:
    ///
    /// - **nowhere** where the row is wholly seen (`StockPreviewRules.reveal`: a card the pointer can see is never
    ///   moved from under it);
    /// - **the least way up** where the card was `tapped` and only the strip's foot cuts it: any more would put
    ///   another card under the pointer (0.2's rule);
    /// - **to its rest** otherwise — the held name cuts it, it is not on screen, or it was chosen from elsewhere
    ///   (the paper a film brings, an undo) with only a part of it in the window: straight under its maker's name.
    func reveal(row: Int, from offset: Double, window: Double, tapped: Bool = false) -> Double {
        let top = rows[row].top - offset, bottom = top + rowHeight
        let pinned = pinned(at: offset)
        if top >= pinned - 0.01, bottom <= window + 0.01 { return offset }
        if tapped, top >= pinned - 0.01, top < window { return Swift.min(offset + bottom - window, foot(window: window)) }
        return Swift.min(rest(row), foot(window: window))
    }
}

// MARK: - the two heights

/// How tall the column's two strips are. **The column scrolls as one, as it always has**: Decode under the strips
/// is several windows tall on a RAW, and a 16-inch laptop's column at 100 % leaves Film & Paper some 360 pt (seen
/// in the running app, 2026-11-16) — less than both strips at their least and Decode's shortest part. So a strip's
/// height takes nothing from anything: what is under it moves down and is scrolled to. Each strip is held between
/// its least and its most on its own.
struct StripSplit: Equatable, Sendable {
    var film: Double
    var paper: Double

    /// One strip: whether it is open (not folded to its header), the least it is dragged to, how tall its cards
    /// are, the height it was dragged to (nil: never) and the one it has until it is.
    struct Section: Equatable, Sendable {
        var open = true
        var min: Double
        var content: Double
        var dragged: Double?
        var standard: Double

        /// The least it takes: a maker's header over a row, or its cards where they are shorter (a shelf of one row).
        var least: Double { open ? Swift.min(min, content) : 0 }
    }

    struct Room: Equatable, Sendable {
        /// The height the column shows of Film & Paper at once.
        var room: Double
        /// What is neither strip nor Decode: the two headers and the open strips' grips.
        var chrome: Double
        /// What a strip is never shown without: its header over it and its grip under it.
        var lead: Double
        /// Decode's header and its shortest part, and the switch: what the strips nobody dragged leave on screen.
        var restMin: Double
        var film: Section
        var paper: Section

        /// The most a strip is shown or dragged to: its cards, and never more than the column shows at once
        /// with the strip's header and grip — a strip taller than the column's window could not be seen whole,
        /// and its grip would be off screen while its cards are on.
        func most(_ s: Section) -> Double {
            guard s.open else { return 0 }
            return Swift.max(Swift.min(s.content, room - lead).rounded(.down), s.least)
        }

        fileprivate func held(_ height: Double, _ s: Section) -> Double { Swift.min(Swift.max(height, s.least), most(s)) }
    }

    /// The two heights. **A strip that was dragged is as tall as it was dragged**, held to its least and its most.
    /// **A strip nobody dragged fits the room**: its standard height where the room holds both strips and Decode's
    /// shortest part, less — by the same share of what each has above its least — where it does not, down to a
    /// maker's header over one row.
    static func resolve(_ r: Room) -> StripSplit {
        var film = r.held(r.film.dragged ?? r.film.standard, r.film)
        var paper = r.held(r.paper.dragged ?? r.paper.standard, r.paper)
        let filmGives = r.film.open && r.film.dragged == nil ? film - r.film.least : 0
        let paperGives = r.paper.open && r.paper.dragged == nil ? paper - r.paper.least : 0
        let over = r.chrome + film + paper + r.restMin - r.room
        if over > 0, filmGives + paperGives > 0 {
            let share = Swift.min(over / (filmGives + paperGives), 1)
            film -= filmGives * share
            paper -= paperGives * share
        }
        return StripSplit(film: film.rounded(.down), paper: paper.rounded(.down))
    }

    enum Grip: Sendable { case film, paper }

    /// The height a grip dragged `travel` points down from `start` leaves the strip above it: between a maker's
    /// header over one row and the strip's most. **A grip sizes its own strip and nothing else.**
    static func drag(_ grip: Grip, in r: Room, from start: Double, travel: Double) -> Double {
        r.held((start + travel).rounded(), grip == .film ? r.film : r.paper)
    }
}

/// The two strips' heights as the person dragged them, kept across launches (`develop.wide.filmGrid.height`,
/// `develop.wide.paperGrid.height`, in the page's points). Each is kept as dragged and held to the room where it
/// is shown (`StripSplit.resolve`), so a window made smaller and larger again gives the height back. **Written when
/// a drag ends**, never at a step of it and never at rest: a strip nobody dragged has no key and fits its room.
@MainActor
@Observable
final class StockGridHeights {
    static let shared = StockGridHeights(defaults: .standard)

    nonisolated static let filmKey = "develop.wide.filmGrid.height"
    nonisolated static let paperKey = "develop.wide.paperGrid.height"

    /// Nil: never dragged.
    private(set) var film: Double?
    private(set) var paper: Double?
    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults`: the app's own; a check hands in a suite of its own (trap 24).
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let film = defaults.double(forKey: Self.filmKey), paper = defaults.double(forKey: Self.paperKey)
        self.film = film > 0 ? film : nil
        self.paper = paper > 0 ? paper : nil
    }

    /// A step of a drag: the heights it leaves, in memory. A nil leaves that strip's as it is.
    func drag(film: Double? = nil, paper: Double? = nil) {
        if let film, film != self.film { self.film = film }
        if let paper, paper != self.paper { self.paper = paper }
    }

    /// A drag ended: what it left is kept.
    func save() {
        if let film { defaults.set(film, forKey: Self.filmKey) }
        if let paper { defaults.set(paper, forKey: Self.paperKey) }
    }
}
