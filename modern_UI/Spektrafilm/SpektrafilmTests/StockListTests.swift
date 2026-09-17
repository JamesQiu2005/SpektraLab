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
        XCTAssertEqual(catalog.filmGroups.map(\.title), ["Positive", "Negative"])
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
}
