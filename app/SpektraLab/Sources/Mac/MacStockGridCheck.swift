//  MacStockGridCheck.swift — a debug build's proof of the desktop's Film and Paper grids (2.4.1, 2026-11-16), in the
//  running app:
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --stock-grid-check <dir> --export-check-pictures <raw> [--export-check-exit]
//
//  The picture (copied into `<dir>/work/Card`) is linked, made a frame and opened in Develop. Then, with the window
//  captured at every state (`--capture-window`), **the page is held to the rules it is laid by** (trap 33: the
//  rules are `stock_previews_selftest`'s, and a green rule is not a correct surface):
//
//  - **The grids are the rule's**: each strip's scroll view is as wide as the column, holds `StockGridRule.columns`
//    cards across and is as tall inside as `StockGridLayout` says — its cards, and the room that lets it reach its foot.
//  - **A chosen card rests under its maker's name** (the review of 2026-11-16): a film chosen off screen, and the
//    paper it brings, leave their strips scrolled exactly to their rows' rests; mid-scroll captures for a look.
//  - **The two heights are `StripSplit.resolve`'s** for the room the column shows: at rest, at a wider column, with
//    a strip dragged taller than the column shows and shorter than a row, on a shelf of three cards, at two
//    interface scales.
//  - **Nothing is written at rest**, nor at a step of a drag; the drag's end writes the strip that was dragged.
//  - **Only the cards on screen are asked for**, and a film chosen off screen is brought into its strip's window.
//  - **A mouse and a trackpad** (round 4, `MacStockGridHandCheck.swift`): the grip dragged, the maker's name over a row,
//    where a scroll goes and where it leaves the strip, the strip's indicator at the panel's left — each event posted
//    into the app's own queue (`MacHIDPost`), the app in the background.
//
//  `<dir>/report.json` and the captures are left for a look. Not in a release build.

#if targetEnvironment(macCatalyst) && DEBUG
import Foundation
import SwiftUI
import UIKit

@MainActor
enum MacStockGridCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = MacCheckFolder.index(of: "--stock-grid-check", in: arguments) else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--export-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        let exits = arguments.contains("--export-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let report = await run(model, out: out, picture: pictures.first)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            let failures = (report["failures"] as? [String]) ?? ["no report"]
            print("stock-grid-check: \(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))") — \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(failures.isEmpty ? 0 : 1)
            }
        }
    }

    /// A scroll view of the window, as it is laid: where it is, how large, and how large inside.
    struct Scroll {
        let view: UIScrollView
        var frame: CGRect
        var content: CGSize
    }

    /// Every scroll view on screen in the key window, in the window's own points.
    static func scrolls() -> [Scroll] {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return [] }
        var found: [Scroll] = []
        func walk(_ v: UIView) {
            if let s = v as? UIScrollView, !s.isHidden, s.bounds.width > 0, s.bounds.height > 0 {
                found.append(Scroll(view: s, frame: s.convert(s.bounds, to: window), content: s.contentSize))
            }
            v.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// The scroll views of the column's Film & Paper, found by what they hold: the one as tall inside as the film's
    /// cards are at its own width, the one as tall as the paper's, and the column's own, which holds both. Their
    /// sizes are their own bounds', the page's points (the window draws the page larger, `InterfaceScale`); their
    /// places, the window's.
    struct Laid {
        var film: Scroll?, paper: Scroll?, column: Scroll?
        func height(_ s: Scroll?) -> Double { s.map { Double($0.view.bounds.height) } ?? -1 }
        func width(_ s: Scroll?) -> Double { s.map { Double($0.view.bounds.width) } ?? -1 }
    }

    static func content(_ cards: [StockPreviewCard], width: Double) -> Double {
        StockGridRule.contentHeight(groups: StockPreviewRules.groups(cards).map { (headed: !$0.brand.isEmpty, count: $0.cards.count) }, width: width)
    }

    static func layout(_ cards: [StockPreviewCard], width: Double) -> StockGridLayout {
        StockGridLayout(groups: StockPreviewRules.groups(cards).map { (headed: !$0.brand.isEmpty, count: $0.cards.count) }, width: width)
    }

    static func laid(film: [StockPreviewCard], paper: [StockPreviewCard]) -> Laid {
        let all = scrolls()
        func grid(_ cards: [StockPreviewCard], not other: UIScrollView? = nil) -> Scroll? {
            all.first { s in
                // As tall inside as its cards, and the room under them that lets it reach its foot (`StockGridLayout.trailing`).
                let l = layout(cards, width: Double(s.view.bounds.width))
                return s.view !== other && s.content.width <= s.view.bounds.width + 0.5
                    && abs(Double(s.content.height) - l.content - l.trailing(window: Double(s.view.bounds.height))) < 1
            }
        }
        let f = grid(film), p = grid(paper, not: f?.view)
        let outer = f.flatMap { f in
            sequence(first: f.view.superview, next: { $0?.superview }).lazy.compactMap { $0 as? UIScrollView }.first
        }
        return Laid(film: f, paper: p, column: outer.flatMap { o in all.first { $0.view === o } })
    }

    static func run(_ model: AppServices, out: URL, picture: URL?) async -> [String: Any] {
        let fm = FileManager.default
        var failures: [String] = [], facts: [String: Any] = [:]
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("stock-grid-check: FAIL \(what)") } else { print("stock-grid-check: ok \(what)") }
        }
        guard let picture else { return ["failures": ["no picture (--export-check-pictures)"]] }
        let work = out.appending(path: "work"), card = work.appending(path: "Card")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: picture, to: card.appending(path: picture.lastPathComponent))
        let store = model.macLibrary
        await store.start()
        do { _ = try await store.open(card) } catch { check(false, "the folder links: \(error.localizedDescription)") }
        await store.loadAll()
        guard let row = store.images.first(where: { $0.fileName == picture.lastPathComponent }),
              let id = (try? await store.frames(for: [row.id], focus: nil).frames)?[row.id] else {
            return ["failures": failures + ["the picture is a frame"]]
        }
        guard let s = await MacMasksCheck.develop(model, id) else { return ["failures": failures + ["the frame opens in Develop"]] }
        let strip = model.stockPreviews.strip(for: id)
        let defaults = UserDefaults.standard
        func kept() -> [Double?] { [StockGridHeights.filmKey, StockGridHeights.paperKey].map { defaults.object(forKey: $0) as? Double } }
        func words(_ k: [Double?]) -> String { k.map { $0.map { String($0) } ?? "none" }.joined(separator: ", ") }
        let heights = StockGridHeights.shared
        var filmCards = strip.filmCards
        func paperCards() -> [StockPreviewCard] { StockPreviewRules.paperShelf(under: s.edit.params.filmStock) }

        /// The page against the rules, at this moment: the grids' columns and cards, and the two heights.
        func hold(_ name: String, decodeOpen: Bool = true) async -> Laid {
            await MacMasksCheck.pause(0.8)
            let l = laid(film: filmCards, paper: paperCards())
            guard let film = l.film, let paper = l.paper, let column = l.column else {
                check(false, "\(name): the film's grid, the paper's and the column's scroll are on the page (\(l.film != nil), \(l.paper != nil), \(l.column != nil))")
                facts[name] = scrolls().map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.view.bounds.width))x\(Int($0.view.bounds.height)) inside \(Int($0.content.width))x\(Int($0.content.height))" }
                return l
            }
            let width = l.width(film)
            check(l.width(paper) == width && l.width(column) == width, "\(name): both grids are the column's width (\(width))")
            let header = Double(ColumnSectionHeader<EmptyView>.height), grip = Double(StripSplitGrip.height)
            let least = StockGridRule.minHeight(width: width)
            let room = StripSplit.Room(
                room: l.height(column), chrome: 2 * header + 2 * grip, lead: header + grip,
                restMin: Double((decodeOpen ? DecodeSection.stackedHeight : DecodeSection.foldedHeight) + StockPreviewPanel.switchHeight),
                film: .init(min: least, content: content(filmCards, width: width), dragged: heights.film, standard: StockGridRule.defaultFilm(width: width)),
                paper: .init(min: least, content: content(paperCards(), width: width), dragged: heights.paper, standard: StockGridRule.defaultPaper(width: width)))
            let want = StripSplit.resolve(room)
            facts[name] = ["column": width, "room": room.room, "across": StockGridRule.columns(width: width), "film": l.height(film),
                           "paper": l.height(paper), "film_inside": Double(film.content.height), "paper_inside": Double(paper.content.height),
                           "film_at": Double(film.view.contentOffset.y), "paper_at": Double(paper.view.contentOffset.y),
                           "column_inside": Double(column.content.height)]
            // Within half a point: the page's points are laid on the window's pixels (a strip of 127 pt is 127.2).
            check(abs(want.film - l.height(film)) <= 0.5 && abs(want.paper - l.height(paper)) <= 0.5,
                  "\(name): the strips are as tall as the rule says for a room of \(room.room) (film \(l.height(film)) for \(want.film), paper \(l.height(paper)) for \(want.paper))")
            // At rest: no native scroll bar inside a strip, under either "Show scroll bars" (the owner's capture, 2026-11-16).
            strips(l, name, check: check)
            await MacMasksCheck.capture(name)
            // And right after a strip scroll, at three interface scales.
            if ["grid-393", "grid-560-scale-80", "scale-150"].contains(name) {
                await scrolledStrip(name + "-strip-scrolled", film: filmCards, paper: paperCards(), check: check)
            }
            return l
        }

        // 1. At rest, the narrowest column: five cards across, nothing written.
        PaneDividers.shared.columnWidth = PaneDividers.minColumn
        _ = await MacMasksCheck.until(60, every: 200) { !strip.shown.isEmpty && strip.shown.allSatisfy { strip.state($0).image != nil } }
        await MacMasksCheck.settle(model)
        let rest0 = await hold("grid-393")
        check(abs(rest0.width(rest0.film) - Double(PaneDividers.minColumn)) < 1 && StockGridRule.columns(width: rest0.width(rest0.film)) == 5,
              "at rest: the column's 393 pt holds five cards across")
        check(kept() == [nil, nil], "at rest: neither height is written (\(words(kept())))")
        let asked = strip.shown
        facts["asked_at_rest"] = asked.map(\.slot)
        check(!asked.isEmpty && asked.count < filmCards.count + paperCards().count,
              "at rest: only the cards on screen are asked for (\(asked.count) of \(filmCards.count + paperCards().count))")
        check(asked.allSatisfy { strip.state($0).image != nil }, "at rest: every card on screen has its picture")

        // 2. A cine film chosen from elsewhere (as an undo or a preset would): brought into the film's window.
        s.change { $0.params.load(film: "kodak_vision3_500t") }
        _ = await MacMasksCheck.developed(s, model, from: nil)
        _ = await MacMasksCheck.until(30, every: 200) { strip.shown.contains { $0.film == "kodak_vision3_500t" && $0.strip == .film } }
        _ = await MacMasksCheck.until(60, every: 200) { strip.shown.allSatisfy { strip.state($0).image != nil } }
        let cine = await hold("grid-cine-chosen")
        check(strip.shown.contains { $0.strip == .film && $0.film == "kodak_vision3_500t" }, "a film chosen off screen is brought into the film's window")
        check(strip.shown.contains { $0.strip == .paper && $0.paper == "kodak_2383" }, "and the paper it brings into the paper's")
        // …each to its row's rest: straight under its maker's name, no row cut above it (the review of 2026-11-16).
        func rests(_ scroll: Scroll?, _ cards: [StockPreviewCard], on stock: String, _ what: String) {
            guard let scroll, let at = cards.firstIndex(where: { $0.stock == stock }) else { check(false, "\(what): its strip is on the page"); return }
            let l = layout(cards, width: Double(scroll.view.bounds.width)), window = Double(scroll.view.bounds.height)
            guard let row = l.row(ofCard: at) else { check(false, "\(what): its row"); return }
            let rest = min(l.rest(row), l.foot(window: window)), now = Double(scroll.view.contentOffset.y)
            let top = l.rows[row].top - now
            check(abs(now - rest) <= 0.5 && abs(top - l.lead(row)) <= 0.5,
                  "\(what) rests straight under its maker's name: the strip at \(now) for \(rest), the row \(top) pt down a \(window) pt window")
        }
        rests(cine.film, filmCards, on: "kodak_vision3_500t", "the chosen film")
        rests(cine.paper, paperCards(), on: "kodak_2383", "the paper it brings")
        // Mid-scroll, as a wheel may leave the strip: a row cut by the held name keeps its names (its pictures are
        // part seen); a row whose pictures are wholly under the name is not drawn — no names without pictures.
        if let film = cine.film {
            let l = layout(filmCards, width: Double(film.view.bounds.width))
            let from = l.rest(max(l.rows.count - 3, 0))
            film.view.setContentOffset(CGPoint(x: 0, y: from + 40), animated: false)
            await MacMasksCheck.pause(0.6)
            await MacMasksCheck.capture("grid-mid-scroll")
            film.view.setContentOffset(CGPoint(x: 0, y: from + 70), animated: false)
            await MacMasksCheck.pause(0.6)
            await MacMasksCheck.capture("grid-mid-scroll-names-gone")
            let gone = l.shown(at: from + 70, window: Double(film.view.bounds.height)).gone
            facts["mid_scroll"] = ["from": from, "gone_at_plus_70": gone, "gone_at_plus_40": l.shown(at: from + 40, window: Double(film.view.bounds.height)).gone]
            // Back to the chosen film's rest for what follows.
            if let at = filmCards.firstIndex(where: { $0.stock == "kodak_vision3_500t" }), let row = l.row(ofCard: at) {
                film.view.setContentOffset(CGPoint(x: 0, y: min(l.rest(row), l.foot(window: Double(film.view.bounds.height)))), animated: false)
            }
            await MacMasksCheck.pause(0.4)
        }

        // 3. A wider column: more cards across, the same rules. At 80 %, where this window's page has the room for a
        // wider column (the column is held to what the picture side and the browser beside it leave: 464 pt here).
        defaults.set(InterfaceScale.p80.rawValue, forKey: InterfaceScale.key)
        PaneDividers.shared.columnWidth = 560
        let wide = await hold("grid-560-scale-80")
        facts["wide_across"] = StockGridRule.columns(width: wide.width(wide.film))
        check(wide.width(wide.film) > 440 && StockGridRule.columns(width: wide.width(wide.film)) > 5,
              "a wider column holds more cards across (\(StockGridRule.columns(width: wide.width(wide.film))) at \(wide.width(wide.film)))")
        check(strip.shown.contains { $0.strip == .film && $0.film == s.edit.params.filmStock },
              "the cards laid in other rows, the chosen film is still in its strip's window")
        rests(wide.film, filmCards, on: "kodak_vision3_500t", "the chosen film, its cards laid in other rows,")
        PaneDividers.shared.columnWidth = PaneDividers.minColumn
        defaults.removeObject(forKey: InterfaceScale.key)
        await MacMasksCheck.pause(0.8)

        // 4. The film's grip dragged: a step shows and writes nothing; its end writes the film's height alone.
        heights.drag(film: 250)
        let dragged = await hold("split-film-250")
        check(kept() == [nil, nil], "a step of a drag writes nothing (\(words(kept())))")
        heights.save()
        check(kept() == [250, nil], "the drag's end writes the film's height alone (\(words(kept())))")
        check(dragged.height(dragged.film) == 250, "the film dragged to 250 is 250 tall, whatever the room (\(dragged.height(dragged.film)))")
        // Dragged past everything: neither strip is taller than the column shows with its header and grip.
        heights.drag(film: 5000, paper: 5000)
        let most = await hold("split-most")
        check(most.height(most.film) <= most.height(most.column) - Double(ColumnSectionHeader<EmptyView>.height + StripSplitGrip.height),
              "dragged past everything, the film's strip, its header and its grip are in the column's window (\(most.height(most.film)) of \(most.height(most.column)))")
        // Dragged to nothing: each strip keeps a maker's name over one row.
        heights.drag(film: 1, paper: 1)
        let leastLaid = await hold("split-least")
        let least = StockGridRule.minHeight(width: leastLaid.width(leastLaid.film))
        check(abs(leastLaid.height(leastLaid.film) - least) <= 0.5 && abs(leastLaid.height(leastLaid.paper) - least) <= 0.5,
              "dragged to nothing, each strip keeps a header over one row (\(leastLaid.height(leastLaid.film)), \(leastLaid.height(leastLaid.paper)) for \(least))")
        heights.drag(film: 220, paper: 180)
        _ = await hold("split-220-180")

        // 4b. A person's pointer and wheel, through the window server (round 4, 2026-11-16: `hand`): the grip dragged
        // at three interface scales, the cursor over it, the maker's name over a row, and where a scroll goes.
        let handFacts = await hand(model, s, out: out, check: { check($0, $1) }, film: filmCards, paper: paperCards,
                                   hold: { await hold($0) })
        facts["hand"] = handFacts
        heights.drag(film: 220, paper: 180)
        heights.save()

        // 5. Decode folded: the strips keep what they were dragged to.
        DevelopPanelPrefs.shared.decodeCollapsed = true
        _ = await hold("decode-folded", decodeOpen: false)
        DevelopPanelPrefs.shared.decodeCollapsed = false

        // 6. Favourites: the starred stocks under their makers' names; a shelf of two rows is as tall as its cards.
        for film in ["fujifilm_velvia_100", "kodak_portra_400", "kodak_vision3_500t"] { StockCatalog.shared.setFavourite(film, true) }
        StockShelfMemory.shared.choose(.favourites, on: .film)
        filmCards = StockShelf.favourites.cards(strip.filmCards)
        let fav = await hold("favourites")
        check(fav.height(fav.film) == min(content(filmCards, width: fav.width(fav.film)), heights.film ?? .infinity),
              "Favourites: the film's strip is no taller than its three cards under two makers (\(fav.height(fav.film)) of \(content(filmCards, width: fav.width(fav.film))))")
        StockShelfMemory.shared.choose(.all, on: .film)
        for film in ["fujifilm_velvia_100", "kodak_portra_400", "kodak_vision3_500t"] { StockCatalog.shared.setFavourite(film, false) }
        filmCards = strip.filmCards

        // 7. The interface scale: the page is laid in 1/f of the window, so the same window's column holds what its
        // own width in the page's points holds.
        for scale in [InterfaceScale.p150, .p120] {
            defaults.set(scale.rawValue, forKey: InterfaceScale.key)
            let scaled = await hold("scale-\(scale.rawValue)")
            facts["scale_\(scale.rawValue)_across"] = StockGridRule.columns(width: scaled.width(scaled.film))
        }
        defaults.removeObject(forKey: InterfaceScale.key)

        // 8. The second language.
        Language.shared.choose(.simplified)
        _ = await hold("grid-393.zh-Hans")
        Language.shared.choose(.english)

        // 9. Apply Film Emulation off: every card still and grey, none asked for.
        s.change { $0.setAppliesFilm(false) }
        await MacMasksCheck.pause(1.0)
        check(strip.shown.isEmpty, "the film not applied: no card is asked for (\(strip.shown.count))")
        await MacMasksCheck.capture("film-off")
        s.change { $0.setAppliesFilm(true) }
        return ["failures": failures, "facts": facts]
    }
}
#endif
