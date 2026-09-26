//  FilmSection.swift — what the photograph is recorded on: the stock.
//
//  **v4 (2026-09-26) gave the frame its own section.** The Film Format / Side
//  / Side Length rows and the effect switches moved to the Parameters rail's
//  Pre-Dev tab (`FilmFormatSection`), beside Camera, and the left rail became
//  the choices of *material* — film, paper, crop and enlarger — so this is the
//  stock list and nothing else. Dragging the divider under it shows more
//  stocks (`StockList` fills a section the user has sized).

import SwiftUI

struct FilmSection: View {
    /// Rows of the film list on screen before it scrolls, while the section
    /// is at its own height. v3's illustration shows two group captions and
    /// seven stocks; at 18 pt a row that is 9 rows tall shows the Positive
    /// group whole and the Negative group's first rows.
    static let wellRows = 9

    @Bindable var session: Session

    var body: some View {
        PanelSection(L(.sectionFilm), key: "film",
                     // The reset arrow's scope is a *named* stock, and a film
                     // name is a profile name — the spec keeps those as they
                     // are. Left in English on purpose, and it is not
                     // `helpResetFilmExposure`: this resets the stock, that
                     // one resets the exposure.
                     action: SectionAction(help: "Reset the film stock to Portra 400") {
                         var p = session.params; p.filmStock = "kodak_portra_400"; session.params = p
                         session.applyFilmStageRule()
                     },
                     menu: { AnyView(menu) }) {
            StockList(rows: stockRows,
                      selected: session.params.filmStock,
                      visibleRows: Self.wellRows) { id in
                select(id)
            }
        }
    }

    /// Positive and Negative, as two visible groups — v3's own division, and
    /// taken from the catalogue's `type` rather than from the artwork's order
    /// (handoff §8.6). A group with nothing in it is not drawn, so a
    /// catalogue with no slide films shows one list rather than an empty
    /// caption.
    private var stockRows: [StockList.Row] {
        session.catalog.filmGroups.filter { !$0.films.isEmpty }.flatMap { group in
            // The id keeps the catalogue's English title — it is the row's
            // identity — while the *name* is what the spec translates. A film
            // entry's own name is a profile name and stays as it is.
            [StockList.Row(id: "__group_" + group.title, name: L(filmGroup: group.title), isHeader: true)]
            + group.films.map {
                StockList.Row(id: $0.id, name: $0.name, isCine: $0.isCine, help: "")
            }
        }
    }

    /// Choosing a film also follows its **declared** paper, unless the user
    /// has already made a pairing of their own.
    private func select(_ id: String) {
        var p = session.params
        p.filmStock = id
        if let target = session.catalog.stock(id)?.targetPrint,
           session.catalog.stock(target) != nil,
           !session.catalog.isDeclaredPairing(film: p.filmStock, paper: p.printStock) {
            p.printStock = target
        }
        session.params = p
        // A slide film has no print stage. A positive declares no
        // `targetPrint`, so the branch above leaves `printStock` where it
        // was — which is the point: coming back to a negative restores the
        // paper rather than landing on a default.
        session.applyFilmStageRule()
    }

    private var menu: some View {
        // The header's arrow is this item; both say the same thing in words,
        // which is the point of §8.3 — a reset affordance whose scope is not
        // named is the ellipsis problem again.
        Button("Reset the film stock to Portra 400") {
            var p = session.params; p.filmStock = "kodak_portra_400"; session.params = p
            session.applyFilmStageRule()
        }
    }
}

/// The film and print lists: rows of one line each, sitting **directly on
/// the rail**, with the chosen row carrying a white capsule.
///
/// **v3 (2026-09-18) took the plate away.** There is no lighter well behind
/// these rows any more and no outer clipping radius — `Theme.stockList` is
/// the rail's own colour — and the rounding moved to the *mark*: the
/// selection is a 15.27 pt capsule inset 16.79 from the leading edge and
/// 26.48 from the trailing one, in `#ffffff`, with the row's text inverted to
/// near-black. The 2026-09-17 version was a full-width `#c9caca` band on a
/// well; the reason the drawing changed it is legible in the two side by
/// side — a band the width of its container reads as "this cell is filled",
/// a capsule inside it reads as "this row is chosen", and only the second one
/// survives being the only mark in a list of 28.
///
/// One view for both lists, because the two drawings of them are the same
/// drawing — and because the previous two implementations had drifted into
/// different row heights, different insets and two spellings of the mark.
struct StockList: View {
    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        var isCine = false
        var help = ""
        /// A group caption — "Positive", "Negative", "Still", "Cine" —
        /// rather than a selectable row.
        var isHeader = false
        /// Whether the row can be chosen. A disabled row greys and stops
        /// taking clicks, which is the PRD's one rule for anything
        /// non-selectable (`View.rowEnabled(_:)`), rather than a row that
        /// looks live and quietly does nothing.
        var enabled = true
        /// Why it cannot be chosen — shown as the row's tooltip, so the greying
        /// is explained where it is seen.
        var disabledReason = ""
    }

    let rows: [Row]
    let selected: String?
    /// How many rows of the list are on screen before it scrolls.
    ///
    /// **A whole number, and that is now the whole rule.** It used to have to
    /// be *odd*: the list centred its selected row, which put that row's
    /// centre on the viewport's centre, so the rows landed on the viewport's
    /// edges only with a whole number of them either side of the middle one.
    /// At an even count every row sat half a row out of register and the
    /// well's 11.5 pt corner cut the first and last rows through the glyphs.
    ///
    /// v3 removes both halves of that. There is no corner to cut with, and
    /// the lists are grouped now — a viewport holding a header and four rows
    /// cannot be described by the parity of a row count at all. What matters
    /// instead is that the viewport is a whole multiple of the row pitch, so
    /// that whatever is scrolled to rests on a row boundary; handoff §3 asks
    /// for exactly that ("a grouped implementation must use complete row
    /// alignment and update that assumption rather than blindly reuse the
    /// odd-count rule"). `StockListTests` pins it.
    var visibleRows: Int
    let select: (String) -> Void
    /// In a section the user has sized (`SectionLayout.swift`) the list takes
    /// whatever height it is offered, at least its own rows.
    @Environment(\.sectionSized) private var sized

    var body: some View {
        ScrollViewReader { proxy in
            // `showsIndicators: true`: v3 draws a 3.04 pt thumb beside each
            // group, and unlike the old well — whose plate told you where the
            // list ended — a list sitting straight on the rail has no other
            // edge to say that it scrolls.
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.isHeader {
                            Text(row.name)
                                .font(Theme.Font.stockGroup)
                                .foregroundStyle(Theme.Ink.tertiary)
                                .padding(.leading, Theme.Metric.stockTextLeadingInset)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Theme.Metric.listRowHeight)
                        } else {
                            StockRow(row: row, selected: row.id == selected) { select(row.id) }
                                .id(row.id)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        // A whole number of rows, and **no vertical padding**: the old 8 pt
        // existed to hold the rows off a corner radius that no longer exists,
        // and with the plate gone it is just a gap that makes the list's top
        // row float away from the section header above it.
        // Two rows at least once sized: shorter than its own rows it scrolls
        // itself, rather than landing in the section's fallback scroll view.
        .frame(minHeight: Theme.Metric.listRowHeight * CGFloat(sized ? 2 : visibleRows),
               maxHeight: sized ? .infinity : Theme.Metric.listRowHeight * CGFloat(visibleRows))
        .background(Theme.stockList)
    }
}

struct StockRow: View {
    let row: StockList.Row
    let selected: Bool
    let action: () -> Void

    var body: some View {
        // A plain view with a tap gesture, not a `Button`. macOS gives even a
        // `.plain` button a shape of its own on this release, and it was
        // drawing a rounded plate inside the mark — a second selection mark,
        // 8 pt of radius, inset from the one the drawing asks for.
        HStack(spacing: 4) {
            Text(row.name)
                .font(Theme.Font.stockItem)
                // An unselected row is a thing being offered, not a thing
                // being said; the selected one is the answer and takes the
                // near-black ink against the white capsule.
                .foregroundStyle(selected ? Theme.onSelection : Theme.Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if row.isCine { CinePill().padding(.trailing, Theme.Metric.cinePillTrailing) }
        }
        // The text sits inside the capsule, not flush with it: v3 puts the
        // capsule's leading edge at 16.79 and the glyphs at 21.33.
        .padding(.leading, Theme.Metric.stockTextLeadingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The **row** is the pitch and the **capsule** is the mark, and they
        // are deliberately not the same height: 18 against 15.27. A mark as
        // tall as its own row is a filled cell.
        .frame(height: Theme.Metric.listRowHeight)
        .background(alignment: .leading) {
            if selected {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: Theme.Metric.stockSelectionRadius,
                                     style: .continuous)
                        .fill(Theme.selection)
                        .frame(width: max(0, geo.size.width
                                             - Theme.Metric.stockLeadingInset
                                             - Theme.Metric.stockTrailingInset),
                               height: Theme.Metric.stockSelectionHeight)
                        .offset(x: Theme.Metric.stockLeadingInset,
                                y: (geo.size.height - Theme.Metric.stockSelectionHeight) / 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .rowEnabled(row.enabled, because: row.disabledReason)
        .help(row.help)
    }
}
