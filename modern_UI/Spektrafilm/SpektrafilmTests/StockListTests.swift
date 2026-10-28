//  StockListTests.swift — the film and print lists after v3 took their well
//  away, and the two rules that replaced the one this file inherited.
//
//  ## What happened to the odd-row rule
//
//  `LayoutTests.testStockListShowsAnOddNumberOfRows` asserted that each list
//  showed an **odd** number of rows, and it was a real rule with a real
//  defect behind it: the list centres its selected row, which puts that row's
//  centre on the viewport's centre, so rows landed on the viewport's edges
//  only with a whole number of them either side of the middle one. At an even
//  count every row sat half a row out of register and the well's 11.5 pt
//  corner radius cut the first and last rows through the glyphs. The film
//  list shipped at 6 and did exactly that.
//
//  v3 removes both halves of it. There is **no well** — the rows sit directly
//  on the rail, so there is no corner to cut with — and the lists are
//  **grouped**, so a viewport holding a caption and four rows cannot be
//  described by the parity of a row count at all. Handoff §3 says so
//  directly: "a grouped implementation must use complete row alignment and
//  update that assumption rather than blindly reuse the odd-count rule."
//
//  So the surviving rule is the one underneath it — the viewport is a whole
//  multiple of the row pitch, so whatever is scrolled to rests on a row
//  boundary — and it is asserted here rather than as a parity check.
//
//  `LayoutTests.testWellPaddingClearsItsOwnCornerRadius` is gone with the
//  same drawing. `wellVPadding` and `wellRadius` still exist, but the only
//  thing that reads them now is the export page's recipe list, whose own
//  drawing has not been translated; asserting them against the editor's
//  lists would be asserting a relationship no editor view has any more.

import SwiftUI
import XCTest

@MainActor
final class StockListTests: XCTestCase {

    /// A list's viewport is a whole number of rows.
    func testEveryListViewportRestsOnARowBoundary() {
        let pitch = Theme.Metric.listRowHeight
        for (name, rows) in [("film", FilmSection.wellRows),
                             ("print", PrintProfileSection.wellRows)] {
            XCTAssertGreaterThan(rows, 0, "\(name)")
            let height = pitch * CGFloat(rows)
            XCTAssertEqual(height.truncatingRemainder(dividingBy: pitch), 0, accuracy: 0.001,
                           "the \(name) list's viewport would present a part row at its edge")
        }
    }

    /// A list is **exactly** its rows tall — measured on the real view, not
    /// recomputed from the same tokens the view uses.
    ///
    /// This is the assertion that catches the padding coming back. The old
    /// 8 pt of `wellVPadding` existed to hold rows off a corner radius; with
    /// the plate gone it is a gap that floats the first row away from the
    /// section header above it *and* breaks the boundary rule above, because
    /// a viewport of `pitch * n + 16` does not rest on a row. Restating the
    /// arithmetic here would pass either way — hosting the view is what makes
    /// it evidence.
    func testAListIsExactlyItsRowsTall() {
        let pitch = Theme.Metric.listRowHeight
        let rows = (0..<6).map { StockList.Row(id: "s\($0)", name: "Stock \($0)") }
        let list = StockList(rows: rows, selected: "s2",
                             visibleRows: FilmSection.wellRows) { _ in }
        let host = NSHostingView(rootView: list)
        host.frame = CGRect(x: 0, y: 0, width: Theme.Metric.leftPanelWidth, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height,
                       pitch * CGFloat(FilmSection.wellRows), accuracy: 0.5,
                       "a list's height is its rows and nothing else")
    }

    /// **The whole catalogue is on offer, grouped.**
    ///
    /// Handoff §8.6: v3's illustration shows 3 positive and 4 negative rows,
    /// and those are the counts of a *viewport*, not a filter or permission
    /// to drop entries. The grouping is taken from the catalogue's `type`
    /// rather than from names or the artwork's order.
    func testFilmGroupingKeepsTheWholeCatalogue() throws {
        let catalog = StockCatalog.shared
        // A catalogue is needed for this to say anything; the bundle carries
        // one, and an empty one would make every assertion below vacuous —
        // `try`, not `try?`, because a discarded skip is a test that passes
        // on no evidence.
        try XCTSkipIf(catalog.films.isEmpty, "no catalogue in the test bundle")
        let grouped = catalog.filmGroups.flatMap(\.films)
        XCTAssertEqual(Set(grouped.map(\.id)), Set(catalog.films.map(\.id)),
                       "grouping dropped or invented a film")
        XCTAssertEqual(grouped.count, catalog.films.count, "a film is in two groups")
        // Positive first, as drawn, and the split is on `type`.
        // Black and white is a third group, where it is on offer (Debug).
        XCTAssertEqual(catalog.filmGroups.map(\.title),
                       FeatureFlags.blackAndWhite ? ["Positive", "Negative", "Black & White"] : ["Positive", "Negative"])
        for group in catalog.filmGroups {
            for film in group.films {
                XCTAssertEqual(film.isMonochrome, group.title == "Black & White",
                               "\(film.id) is in the \(group.title) group")
            }
        }
        for group in catalog.filmGroups {
            for film in group.films {
                XCTAssertEqual(film.isPositive, group.title == "Positive",
                               "\(film.id) is in the \(group.title) group")
            }
        }
        // Within a group the picker's order survives, so a cine stock still
        // follows its group's stills rather than being hoisted.
        let pickerOrder = catalog.filmsForPicker.map(\.id)
        for group in catalog.filmGroups {
            let indices = group.films.compactMap { pickerOrder.firstIndex(of: $0.id) }
            XCTAssertEqual(indices, indices.sorted(), "\(group.title) reordered the picker")
        }
    }

    /// The paper list's own grouping is untouched by v3, including the
    /// `scan_film` sentinel that is not a paper.
    func testPaperGroupsAreUnchanged() {
        XCTAssertEqual(StockCatalog.shared.paperGroups.map(\.title), ["Still", "Cine"])
    }

    /// The selection mark is a capsule inside its row, and every number that
    /// makes it one holds.
    ///
    /// Four separate mistakes are available here and each of them would still
    /// draw *something*: a mark as tall as its row (a filled cell), a mark as
    /// wide as the rail (the band v3 replaced), text starting on the capsule's
    /// own edge, and a radius that is not half the height (a rounded rectangle
    /// rather than a capsule).
    func testTheSelectionMarkIsACapsuleInsideItsRow() {
        let m = Theme.Metric.self
        XCTAssertLessThan(m.stockSelectionHeight, m.listRowHeight)
        XCTAssertEqual(m.stockSelectionRadius, m.stockSelectionHeight / 2, accuracy: 0.01)
        // On the reference rail the capsule is 210.74 wide — inset at both
        // ends, and by different amounts.
        let width = m.leftPanelWidth - m.stockLeadingInset - m.stockTrailingInset
        XCTAssertEqual(width, 210.74, accuracy: 0.1)
        XCTAssertLessThan(width, m.leftPanelWidth)
        XCTAssertGreaterThan(m.stockTextLeadingInset, m.stockLeadingInset)
        XCTAssertLessThan(m.stockTextLeadingInset,
                          m.leftPanelWidth - m.stockTrailingInset)
    }

    /// The lists stopped using `well`, and that is a colour decision worth
    /// pinning.
    ///
    /// `well` is still `ground` — a lighter grey than the rail — and the
    /// export page's recipe list still sits on it. The editor's stock lists
    /// sit on `stockList`, which is the rail's own colour. Handoff §9 warns
    /// against the shortcut that would have made this one line: "Do not
    /// overwrite generic `well` to change only stock lists."
    func testTheStockListsSitOnTheRail() {
        XCTAssertEqual(Theme.stockList, Theme.card,
                       "v3 puts the lists straight on the rail")
        XCTAssertNotEqual(Theme.stockList, Theme.well,
                          "overwriting `well` would have dragged the export page along")
        XCTAssertEqual(Theme.well, Theme.ground,
                       "the export page's well is unchanged")
    }

    // MARK: - black and white (FeatureFlags.blackAndWhite, 2026-10-09)

    private static let silverFilms = ["fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400",
                                      "kodak_tmax_100", "kodak_tri_x_400"]
    private static let silverPaper = "ilford_multigrade_iv_rc"

    /// The four films and their paper are in the catalogue exactly where the
    /// flag offers them, each film declares that paper, and the engine has a
    /// profile in the bundle for every one of them.
    func testTheBlackAndWhiteStocksAreListedWhereTheFlagIsOn() throws {
        let catalog = StockCatalog.shared
        try XCTSkipIf(catalog.films.isEmpty, "no catalogue in the test bundle")
        let mono = catalog.stocks.filter(\.isMonochrome)
        guard FeatureFlags.blackAndWhite else {
            return XCTAssertTrue(mono.isEmpty, "black and white is listed with its flag off")
        }
        XCTAssertEqual(mono.filter(\.isFilm).map(\.id).sorted(), Self.silverFilms)
        XCTAssertEqual(mono.filter(\.isPaper).map(\.id), [Self.silverPaper])
        for id in Self.silverFilms {
            XCTAssertEqual(catalog.stock(id)?.targetPrint, Self.silverPaper)
            XCTAssertNotNil(StockCatalog.bundle.url(forResource: id, withExtension: "json",
                                                    subdirectory: "Resources/engine/profiles"),
                            "\(id) is listed and the bundle has no profile for it: run engine/build.sh bundle")
        }
    }

    /// Silver film on silver paper, colour on colour: choosing a film across
    /// the line takes its paper, and the paper list refuses the other kind.
    func testABlackAndWhiteFilmTakesItsPaperAndAColourFilmGivesItBack() throws {
        try XCTSkipUnless(FeatureFlags.blackAndWhite)
        let session = Session()
        session.selectFilmStock("kodak_portra_400")
        session.selectPrintStock("kodak_supra_endura")
        XCTAssertEqual(session.params.printStock, "kodak_supra_endura")

        session.selectFilmStock("kodak_tri_x_400")
        XCTAssertEqual(session.params.printStock, Self.silverPaper)
        session.selectPrintStock("kodak_supra_endura")
        XCTAssertEqual(session.params.printStock, Self.silverPaper, "a colour paper took a black-and-white film")
        session.selectFilmStock("ilford_hp5_plus_400")
        XCTAssertEqual(session.params.printStock, Self.silverPaper)

        session.selectFilmStock("kodak_gold_200")
        XCTAssertFalse(session.catalog.stock(session.params.printStock)?.isMonochrome ?? true,
                       "a colour film kept the silver paper")
        session.selectPrintStock(Self.silverPaper)
        XCTAssertFalse(session.catalog.stock(session.params.printStock)?.isMonochrome ?? true,
                       "the silver paper took a colour film")
    }

    /// What a black-and-white film changes on the wire, and that a colour
    /// frame's wire is what it was: grain as one layer, Multigrade filter 2 on
    /// the enlarger, no EDR.
    func testABlackAndWhiteFilmPrintsOneGrainLayerThroughFilter2() throws {
        try XCTSkipUnless(FeatureFlags.blackAndWhite)
        func wire(_ p: FilmParams) -> [String: ParamValue] { p.fullDelta }
        var colour = FilmParams.default
        colour.grainActive = true
        colour.extendedDynamicRange = true
        XCTAssertEqual(wire(colour)["grain_sublayers_active"], .bool(true))
        XCTAssertEqual(wire(colour)["extended_dynamic_range"], .bool(true))
        XCTAssertNil(wire(colour)["y_filter_neutral"], "a colour frame's stamp gained a field")
        XCTAssertEqual(wire(colour)["grain_amount"], .double(1), "a colour film's grain moved")

        for film in Self.silverFilms {
            var p = colour
            p.filmStock = film
            p.printStock = Self.silverPaper
            let w = wire(p)
            XCTAssertEqual(w["grain_active"], .bool(true))
            XCTAssertEqual(w["grain_sublayers_active"], .bool(false), "\(film) renders grain in sub-layers")
            XCTAssertEqual(w["c_filter_neutral"], .double(0))
            XCTAssertEqual(w["m_filter_neutral"], .double(0))
            XCTAssertEqual(w["y_filter_neutral"], .double(68))
            XCTAssertEqual(w["extended_dynamic_range"], .bool(false), "the silver paper has no EDR calibration")
            // Grain strength 1 is the film's own published granularity.
            XCTAssertEqual(w["grain_amount"], .double(FilmParams.ownGrain(of: film)))
            XCTAssertNotEqual(FilmParams.ownGrain(of: film), 1, "\(film) has no grain of its own")
            p.effects.grain = 2
            XCTAssertEqual(wire(p)["grain_amount"], .double(min(2, 2 * FilmParams.ownGrain(of: film))),
                           "the wire's range is 0…2")
            // The pack rides in the delta from a colour frame, or the session
            // would keep the colour pair's.
            XCTAssertEqual(p.delta(from: colour).delta["y_filter_neutral"], .double(68))
        }
    }

    /// The film's own words on its edge, as the strips carry them.
    func testBlackAndWhiteEdgeText() throws {
        try XCTSkipUnless(FeatureFlags.blackAndWhite)
        let catalog = StockCatalog.shared
        XCTAssertEqual(Session.edgeText(for: catalog.stock("kodak_tri_x_400")), "KODAK 400TX")
        XCTAssertEqual(Session.edgeText(for: catalog.stock("kodak_tmax_100"), gauge: "120"), "KODAK 100TMX")
        XCTAssertEqual(Session.edgeText(for: catalog.stock("fujifilm_neopan_acros_100_ii")), "FUJI 100 ACROS II")
        XCTAssertEqual(Session.edgeText(for: catalog.stock("ilford_hp5_plus_400")), "ILFORD HP5 PLUS")
    }
}
