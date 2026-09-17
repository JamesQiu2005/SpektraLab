//  FilmSection.swift — what the photograph is recorded on: the stock, the
//  physical frame, and the three spatial effects that scale with it.
//
//  Three sections became one, because the drawing makes one: the film list,
//  the Film Type / Side / Side Length rows that used to be Camera's single
//  `Format` pill, and the Grain / Halation / Glare toggles that were their
//  own `Features` card. They belong together for a reason the PRD states —
//  "this is very important, as it goes straight into the grain, halation and
//  glare calculation pipeline" — and a toggle three cards away from the
//  number that scales it is a toggle nobody connects to it.
//
//  ## The frame, and why it is three controls
//
//  The engine takes one number, `film_format_mm`, and it means the frame's
//  **long edge**: pixel pitch is `film_format_mm * 1000 / max(w, h)`, and
//  grain, halation and DIR diffusion are micrometre quantities divided by it.
//  One number cannot tell 645 from 6×6. So the user says a **type**, a
//  **side** and a **length**, and `Session.filmFormatMM(side:sideLengthMM:aspect:)`
//  derives the long edge from that and the photograph's own aspect — which is
//  what makes one `120` entry cover 645, 6×6, 6×7 and 6×9 correctly.
//
//  Side Length is greyed unless the type is Custom, and shows the type's own
//  measurement otherwise: the PRD's "cannot be changed unless custom is
//  selected. Shows the actual Side length if non-custom film type is
//  selected."
//
//  Whether a **crop** re-scales any of this is a Settings toggle and is off by
//  default — cropping a negative does not make its grain coarser. See
//  `Session.physicalAspect`.

import SwiftUI

struct FilmSection: View {
    /// Rows of the film well on screen before it scrolls. **Odd** — see
    /// `StockList.visibleRows`, and `testStockListShowsAnOddNumberOfRows`.
    static let wellRows = 5

    @Bindable var session: Session
    /// Display only; the wire is always millimetres. An app preference rather
    /// than part of a frame's settings, because "show me inches" is a fact
    /// about the reader, not about the photograph.
    @AppStorage(Session.uiKey + "sideUnit") private var unitRaw = SideUnit.mm.rawValue

    private var unit: Binding<SideUnit> {
        Binding(get: { SideUnit(rawValue: unitRaw) ?? .mm }, set: { unitRaw = $0.rawValue })
    }
    private var isCustom: Bool { session.params.filmFrame == FilmFrame.custom.id }

    var body: some View {
        PanelSection("Film", key: "film", menu: { AnyView(menu) }) {
            VStack(alignment: .leading, spacing: 0) {
                StockList(rows: session.catalog.filmsForPicker.map {
                    StockList.Row(id: $0.id, name: $0.name, isCine: $0.isCine, help: "")
                }, selected: session.params.filmStock, visibleRows: Self.wellRows) { id in
                    select(id)
                }
                RailRows {
                    PillMenu(label: "Film Type", options: FilmFrame.all, title: { $0.id },
                             selection: Binding(get: { session.filmFrame },
                                                set: { session.setFilmFrame($0) }),
                             fill: false,
                             trailingBadge: { $0.isCine })
                    PillMenu(label: "Side", options: FilmSide.allCases, title: { $0.title },
                             selection: Binding(get: { session.filmSide },
                                                set: { session.setFilmSide($0) }),
                             fill: false)
                    UnitField(label: "Side Length",
                              value: Binding(get: { session.params.sideLengthMM },
                                             set: { session.setSideLengthMM($0) }),
                              unit: unit,
                              enabled: isCustom,
                              reason: "Side Length is the film type's own measurement. Choose Custom to type one.")
                }
                .padding(.top, Theme.Metric.rowSpacing + 4)
                RailRows {
                    ToggleRow(label: "Grain", isOn: param(\.grainActive))
                    ToggleRow(label: "Halation", isOn: param(\.halationActive))
                    ToggleRow(label: "Glare", isOn: param(\.glareActive))
                }
                .padding(.top, Theme.Metric.rowSpacing + 4)
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

    private func param(_ kp: WritableKeyPath<FilmParams, Bool>) -> Binding<Bool> {
        Binding(get: { session.params[keyPath: kp] },
                set: { var p = session.params; p[keyPath: kp] = $0; session.params = p })
    }

    private var menu: some View {
        Group {
            Button("Reset to Portra 400") { var p = session.params; p.filmStock = "kodak_portra_400"; session.params = p }
            Divider()
            Button("All effects on") {
                var p = session.params
                p.grainActive = true; p.halationActive = true; p.glareActive = true
                session.params = p
            }
            Button("All effects off") {
                var p = session.params
                p.grainActive = false; p.halationActive = false; p.glareActive = false
                session.params = p
            }
        }
    }
}

/// The film and print lists: a well, rows of one line each, and the chosen
/// row carrying a **band** rather than a frame.
///
/// The PRD's own words for what changed: "selected entries has shallow,
/// instead of framed square around it, and the text turns from white to
/// black". So the mark is `Theme.selection` at the full width of the well and
/// exactly one row tall, with the row's text inverted to `Theme.onSelection`.
/// A cinema stock carries the accent `CINE` pill at the trailing edge.
///
/// One view for both lists, because the two drawings of them are the same
/// drawing — and because the previous two implementations had drifted into
/// different row heights, different insets and two spellings of the selection
/// mark.
struct StockList: View {
    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        var isCine = false
        var help = ""
        /// A group caption — "Still", "Cine", "Positive" — rather than a
        /// selectable row.
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
    /// How many rows of the well are on screen before it scrolls.
    ///
    /// **This has to be odd**, and the reason is the scroll below. Centring
    /// the selected row puts *its* centre on the viewport's centre, so the
    /// rows land on the well's edges only when there is a whole number of
    /// rows either side of the middle one — that is, when the count is odd.
    /// At an even count every row sits half a row out of register and the
    /// well cuts the first and last ones through the glyphs, which is what
    /// the film list was doing at 6: a well full of sliced type, which reads
    /// as a grey block rather than as a list.
    ///
    /// The drawing shows five in each. `visibleRowsAreOdd` in
    /// `SpektrafilmTests/LayoutTests.swift` is what keeps it that way.
    var visibleRows: Int
    let select: (String) -> Void

    var body: some View {
        // **Not** `Well`: a well pads its content, and the selection band has
        // to be the well's full width ("selected entries has shallow" — the
        // band *is* the mark, so an inset band reads as a chip). So the well
        // is built here — fill, clip, inset — and the padding is the row's.
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if row.isHeader {
                            Text(row.name)
                                .font(Theme.Font.groupHeader)
                                .foregroundStyle(Theme.Ink.tertiary)
                                .padding(.leading, Theme.Metric.wellPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: Theme.Metric.listRowHeight)
                        } else {
                            StockRow(row: row, selected: row.id == selected) { select(row.id) }
                                .id(row.id)
                        }
                    }
                }
                .padding(.vertical, Theme.Metric.wellVPadding)
            }
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: Theme.Metric.listRowHeight * CGFloat(visibleRows)
                     + Theme.Metric.wellVPadding * 2)
        .background(Theme.well)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.wellRadius, style: .continuous))
        .padding(.horizontal, Theme.Metric.wellInset)
    }
}

struct StockRow: View {
    let row: StockList.Row
    let selected: Bool
    let action: () -> Void

    var body: some View {
        // A plain view with a tap gesture, not a `Button`. macOS gives even a
        // `.plain` button a shape of its own on this release, and it was
        // drawing a rounded plate inside the band — a second selection mark,
        // 8 pt of radius, inset from the one the drawing asks for.
        HStack(spacing: 4) {
            Text(row.name)
                .font(Theme.Font.listItem)
                // An unselected row is a thing being offered, not a thing
                // being said; the selected one is the answer and keeps the
                // full-strength ink against the band.
                .foregroundStyle(selected ? Theme.onSelection : Theme.Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if row.isCine { CinePill().padding(.trailing, Theme.Metric.cinePillTrailing) }
        }
        .padding(.leading, Theme.Metric.wellPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.Metric.listRowHeight)
        .background(selected ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .rowEnabled(row.enabled, because: row.disabledReason)
        .help(row.help)
    }
}
