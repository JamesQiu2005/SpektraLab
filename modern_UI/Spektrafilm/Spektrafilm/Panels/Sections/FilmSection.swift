//  FilmSection.swift — what the photograph is recorded on: the stock, the
//  physical frame, and the three spatial effects that scale with it.
//
//  Three sections became one, because the drawing makes one: the film list,
//  the Film Format / Side / Side Length rows that used to be Camera's single
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
    /// Rows of the film list on screen before it scrolls. v3's illustration
    /// shows two group captions and seven stocks; at 18 pt a row that is
    /// 9 rows tall shows the Positive group whole and the Negative group's
    /// first rows, which is the drawing's proportion without pretending the
    /// catalogue is nine stocks long. See `StockList.visibleRows` — the
    /// odd-count rule this number used to obey is gone.
    static let wellRows = 9

    @Bindable var session: Session
    /// Display only; the wire is always millimetres. An app preference rather
    /// than part of a frame's settings, because "show me inches" is a fact
    /// about the reader, not about the photograph.
    @AppStorage(Session.uiKey + "sideUnit") private var unitRaw = SideUnit.mm.rawValue
    /// RFC-025: Settings → Decouple effects. Shows the strengths; the
    /// strengths are the frame's and render whether or not they are shown.
    @AppStorage(Session.decoupleEffectsKey) private var decoupleEffects = false

    private var unit: Binding<SideUnit> {
        Binding(get: { SideUnit(rawValue: unitRaw) ?? .mm }, set: { unitRaw = $0.rawValue })
    }
    private var isCustom: Bool { session.params.filmFrame == FilmFrame.custom.id }

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
            VStack(alignment: .leading, spacing: 0) {
                StockList(rows: stockRows,
                          selected: session.params.filmStock,
                          visibleRows: Self.wellRows) { id in
                    select(id)
                }
                RailRows {
                    // `title: { $0.id }` — a film format is `135`, `120`, `APS`
                    // and so on, which the spec keeps as they are. Only the
                    // row's label is translated.
                    PillMenu(label: L(.filmFormat), options: FilmFrame.all, title: { $0.id },
                             selection: Binding(get: { session.filmFrame },
                                                set: { session.setFilmFrame($0) }),
                             fill: false,
                             trailingBadge: { $0.isCine })
                    PillMenu(label: L(.filmFormatSide), options: FilmSide.allCases, title: { L($0.key) },
                             selection: Binding(get: { session.filmSide },
                                                set: { session.setFilmSide($0) }),
                             fill: false)
                    UnitField(label: L(.filmFormatSideLength),
                              value: Binding(get: { session.params.sideLengthMM },
                                             set: { session.setSideLengthMM($0) }),
                              unit: unit,
                              enabled: isCustom,
                              reason: L(.reasonNonCustomSideLength))
                }
                .padding(.top, Theme.Metric.rowSpacing + 4)
                RailRows {
                    if decoupleEffects {
                        decoupledEffects
                    } else {
                        ToggleRow(label: L(.filmGrain), isOn: param(\.grainActive))
                        ToggleRow(label: L(.filmHalation), isOn: param(\.halationActive))
                        ToggleRow(label: L(.filmGlare), isOn: param(\.glareActive))
                    }
                }
                .padding(.top, Theme.Metric.rowSpacing + 4)
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

    private func param(_ kp: WritableKeyPath<FilmParams, Bool>) -> Binding<Bool> {
        Binding(get: { session.params[keyPath: kp] },
                set: { var p = session.params; p[keyPath: kp] = $0; session.params = p })
    }

    private func effect<V>(_ kp: WritableKeyPath<EffectStrengths, V>) -> Binding<V> {
        Binding(get: { session.params.effects[keyPath: kp] },
                set: { var p = session.params; p.effects[keyPath: kp] = $0; session.params = p })
    }

    /// RFC-025's rows: each effect's switch, then what it can be tuned by. The
    /// switches are the same three fields as the coupled rows plus the two
    /// that used to ride on them (grain's sub-layer model, the couplers), so a
    /// frame reads identically in either mode. A strength greys, rather than
    /// hides, while its effect is off: the value is still the frame's.
    @ViewBuilder private var decoupledEffects: some View {
        let p = session.params
        ToggleRow(label: L(.filmGrain), isOn: param(\.grainActive))
        strength(\.grain, range: EffectStrengths.grainRange, enabled: p.grainActive)
        ToggleRow(label: L(.filmGrainLayers), isOn: effect(\.grainLayered),
                  enabled: p.grainActive, reason: L(.reasonEffectOff))
        ToggleRow(label: L(.filmHalation), isOn: param(\.halationActive))
        strength(\.halation, range: EffectStrengths.halationRange, enabled: p.halationActive)
        strength(\.scatter, label: L(.filmScatter), range: EffectStrengths.scatterRange,
                 enabled: p.halationActive)
        ToggleRow(label: L(.filmCouplers), isOn: effect(\.couplersActive))
        strength(\.couplers, range: EffectStrengths.couplersRange,
                 enabled: p.effects.couplersActive)
        ToggleRow(label: L(.filmGlare), isOn: param(\.glareActive))
        strength(\.glare, range: EffectStrengths.glareRange, enabled: p.glareActive)
    }

    /// A multiplier on what the film does, so its neutral is 1 -- the fill
    /// grows from there, and a double-click puts it back.
    private func strength(_ kp: WritableKeyPath<EffectStrengths, Double>,
                          label: String = L(.filmEffectStrength),
                          range: ClosedRange<Double>, enabled: Bool) -> some View {
        ScrubSlider(label: label, value: effect(kp), range: range, zero: 1, snap: 0.25,
                    format: { String(format: "%.2f×", $0) },
                    disabled: !enabled)
    }

    private var menu: some View {
        Group {
            // The header's arrow is this item; both say the same thing in
            // words, which is the point of §8.3 — a reset affordance whose
            // scope is not named is the ellipsis problem again.
            Button("Reset the film stock to Portra 400") {
                var p = session.params; p.filmStock = "kodak_portra_400"; session.params = p
                session.applyFilmStageRule()
            }
            Divider()
            Button(L(.helpAllEffectsOn)) {
                var p = session.params
                p.grainActive = true; p.halationActive = true; p.glareActive = true
                session.params = p
            }
            Button(L(.helpAllEffectsOff)) {
                var p = session.params
                p.grainActive = false; p.halationActive = false; p.glareActive = false
                session.params = p
            }
            // Offered whenever a frame carries strengths, shown or not: with
            // the sliders hidden this is the only way to see there is
            // something to reset, and the only way to reset it.
            if decoupleEffects || !session.params.effects.isDefault {
                Button(L(.helpResetEffectStrengths)) {
                    var p = session.params; p.effects = .default; session.params = p
                }
                .disabled(session.params.effects.isDefault)
            }
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
        .frame(height: Theme.Metric.listRowHeight * CGFloat(visibleRows))
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
