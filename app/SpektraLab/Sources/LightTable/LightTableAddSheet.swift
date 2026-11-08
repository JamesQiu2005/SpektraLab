//  LightTableAddSheet.swift — *Add to Light Table* (design/lighttable L2, `st_picking` in
//  gen_lighttable.py): the Library's own grid in a sheet, frames picked by a tap, *Lay Down n*.
//
//  - **The Library's own grid**: its days, its tiles (`LibraryTile`, with the Select mode's pick
//    circle), its sort (the `···` menu's, `FrameCatalog.oldestFirstKey`). Every frame, pairs
//    too, whatever collection the Library's pill shows: the sheet has no pill to change it, and
//    a frame hidden by a filter the page cannot show would look lost.
//  - **A frame already on the table** says *On the table* over its tile, under the table's own
//    stand loupe, and cannot be picked.
//  - **At `room` picks** (the table holds 99 films) the tiles still to pick dim and take no tap;
//    a picked tile can always be unpicked.
//  - A frame still developing shows what its Library tile shows (the ring) and can be picked:
//    the table starts no job.
//  - *Lay Down n* hands the picked frames over in the Library's order and the sheet closes
//    itself. The close button cancels. No long press anywhere (RFC-045).
//
//  The page presents it with SwiftUI's own `.sheet` and hands it the app's objects
//  (`.appEnvironment(model)`): a sheet is its own hosting controller. It dresses itself as the
//  app's sheets are dressed (`spkSheet`), at the drawing's height (its top at 214 on the 852).

import SwiftUI

struct LightTableAddSheet: View {
    /// The frames already on the table: their tiles say *On the table* and cannot be picked.
    let onTable: Set<UUID>
    /// How many more films the table takes (99 at most on it).
    let room: Int
    /// *Lay Down n*: the picked frames, in the Library's order. The sheet closes itself after.
    let layDown: ([UUID]) -> Void

    @Environment(FrameCatalog.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// The Library's own sort (its `···` menu).
    @AppStorage(FrameCatalog.oldestFirstKey) private var oldestFirst = false
    @State private var picked: Set<UUID> = []

    /// The days the sheet lists. only the frames the
    /// table takes, as the Mac library's own way onto it (`MacLightTableCarry.takes`: a film size recorded,
    /// a film edge on or a pair; the owner: "the same filter apply there too? ... yes"), a day left
    /// with none of them not listed. The window and the host list every frame, as before.
    static func days(_ all: [LibraryDay]) -> [LibraryDay] {
        return all.compactMap { d in
            let taken = d.frames.filter(MacLightTableCarry.takes)
            return taken.isEmpty ? nil : LibraryDay(day: d.day, frames: taken)
        }
    }

    /// Where the drawing puts the sheet's top edge on its 852 pt page (`LT852.sheet_y`).
    static let top: CGFloat = 214

    var body: some View {
        let days = Self.days(library.everyDay(oldestFirst: oldestFirst))
        let chosen = days.flatMap(\.frames).map(\.id).filter(picked.contains)
        GeometryReader { geo in
            VStack(spacing: 0) {
                SheetHeader(title: L("Add to Light Table")) { dismiss() }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                            DayHeader(day: day.day, now: library.now())
                                .padding(.top, i == 0 ? 0 : DayHeader.gap)
                            // On its side (the light table turns, 2026-10-19) twice the Library's
                            // columns, so a tile keeps about its upright size.
                            LazyVGrid(columns: geo.size.width > geo.size.height
                                      ? Array(repeating: GridItem(.flexible(), spacing: Theme.Metric.gridGap), count: 2 * Theme.Metric.gridColumns)
                                      : LibraryScreen.columns, spacing: Theme.Metric.gridGap) {
                                ForEach(day.frames) { frame in tile(frame, full: chosen.count >= room) }
                            }
                        }
                    }
                    // Room to scroll the last row clear of the button.
                    .padding(.bottom, Self.button + 16 + Self.bottom(geo) + 24)
                }
                .scrollIndicators(.hidden)
                // The drawing's first day starts 64 under the sheet's top; the header is 63.
                .padding(.top, 64 - SheetHeader.height(subtitle: false))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) { band(chosen, bottom: Self.bottom(geo)) }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.sheet.ignoresSafeArea())
        .presentationDetents([.fraction((Theme.Metric.designHeight - Self.top) / Theme.Metric.designHeight), .large])
        .presentationDragIndicator(.hidden)          // `SheetHeader` draws the drawing's own
        .presentationCornerRadius(Theme.Metric.sheetRadius)
        .presentationBackground(Theme.sheet)
        .presentationContentInteraction(.scrolls)
        .appColorScheme()
    }

    // MARK: a tile

    @ViewBuilder private func tile(_ frame: LibraryFrame, full: Bool) -> some View {
        let there = onTable.contains(frame.id)
        let on = picked.contains(frame.id)
        let shut = there || (full && !on)
        LibraryTile(frame: frame, mark: there ? .none : .pick(on))
            .overlay {
                if there {
                    // `library_tiles(on_table=…)`: 0.62 black, the table's loupe, and its words.
                    ZStack {
                        Color.black.opacity(0.62)
                        VStack(spacing: 5) {
                            DrawnGlyph(icon: .standLoupe, size: 20, color: Theme.secondaryText)
                            DrawnText(L("On the table"), 12, .semibold, Theme.secondaryText)
                        }
                    }
                    .allowsHitTesting(false)
                } else if shut {
                    // The table is full: what is left to pick dims, as a tile in use does (`tile(dim=True)`).
                    Color.black.opacity(0.6).allowsHitTesting(false)
                }
            }
            .onTapGesture { toggle(frame.id) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(there ? frame.fileName + ", " + L("On the table") : frame.fileName)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { toggle(frame.id) }
            .disabled(shut)
    }

    /// *Lay Down n*: the frames handed over, and the sheet away.
    private func lay(_ chosen: [UUID]) {
        layDown(chosen)
        dismiss()
    }

    private func toggle(_ id: UUID) {
        guard !onTable.contains(id) else { return }
        if picked.contains(id) {
            picked.remove(id)
        } else if picked.count < room {
            picked.insert(id)
        }
    }

    // MARK: the button

    /// The capsule's height, and how far its foot sits above the screen's edge: the drawing's
    /// `H - 80` on a host with a home indicator, `H - 64` on one without.
    private static let button: CGFloat = 48
    private static func bottom(_ geo: GeometryProxy) -> CGFloat { geo.safeAreaInsets.bottom > 0 ? 32 : 16 }

    /// *Lay Down n* on the sheet's colour, the grid running out under a short fade above it.
    private func band(_ chosen: [UUID], bottom: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.sheet.opacity(0), Theme.sheet], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
                .allowsHitTesting(false)
            CapsuleButton(title: L("Lay Down \(chosen.count)"), height: Self.button, enabled: !chosen.isEmpty) {
                lay(chosen)
            }
            .padding(.horizontal, Theme.Metric.margin)
            .padding(.top, 16)
            .padding(.bottom, bottom)
            .background(Theme.sheet)
        }
    }
}
