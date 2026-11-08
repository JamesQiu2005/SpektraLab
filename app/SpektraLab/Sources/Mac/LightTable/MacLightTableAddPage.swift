//  MacLightTableAddPage.swift — *Add to Light Table* on the Mac: a page over the whole window (2026-10-24).
//
//  The owner: "I can click to exit this in the light table but it is slow. The way it is displayed should be
//  similar to the import page." So it is built as the import page is (`MacImportFlow`), at the library's Mac
//  metrics, and it is not a sheet:
//
//  - **The left column**: *On the Table* (how many films lie on it, and how many more it takes: 99 at most),
//    *Shown* (the one rule for what may lie on the table, `MacLightTableCarry.takes`: a frame of SpektraLab's
//    whose film's size is known), *Date Taken* (each day with its count, ticked; a day unticked is not shown).
//  - **The right**: the frames the table takes, in the library's order (`LightTableAddSheet.days`, the
//    filter's one home), in the library's own cells (`MacGridCell`) with its selection — click, ⌘-click,
//    ⇧-click, a marquee from the space between, ⌘A, ⇧⌘A, the arrows — and its thumbnail size. A frame already
//    on the table says *On the table* and cannot be chosen; past the table's room no more can be (the
//    selection keeps the first in the grid's order, and the bar says so). A double click lays that one down.
//  - **The bottom bar**: *Select All*, *Select None*, the count, *Cancel* (Esc) and *Lay Down n* (Return).
//
//  **Opening and closing at once.** The sheet it replaces took its time to go: a SwiftUI sheet is a hosting
//  controller of its own that UIKit presents and dismisses with its animation, and its grid of every day's
//  tiles was built in it each time (`--lighttable-check` times both, report.json `add_page`). This page is an
//  overlay of the Light Table's own page — drawn in the same pass as the state that shows it, gone in the
//  same pass as the one that hides it, no presentation, no animation, the table's textures untouched under it.
//  While it is up the table's own keys stand down (the page's `adding`).

import SwiftUI
import UIKit

struct MacLightTableAddPage: View {
    /// The frames already on the table.
    let onTable: Set<UUID>
    /// How many more films the table takes.
    let room: Int
    /// The table's line ("3 films · A4").
    let tableLine: String
    /// *Lay Down n*: the chosen frames, in the grid's order. The page is closed by its caller.
    let layDown: ([UUID]) -> Void
    let cancel: () -> Void

    @Environment(FrameCatalog.self) private var library
    @AppStorage(FrameCatalog.oldestFirstKey) private var oldestFirst = false
    @State private var browser = MacLibraryBrowser()
    @State private var hiddenDays: Set<Date> = []
    @State private var marquee: MacMarquee?
    @State private var lastClick: (id: MacImage.ID, at: Date)?
    /// The selection was cut to the table's room.
    @State private var trimmed = false
    /// The selection as the last cut to the room left it.
    @State private var lastCut: Set<MacImage.ID>?

    #if DEBUG
    /// When the page last appeared and went (`--lighttable-check`).
    static var shownAt: ContinuousClock.Instant?
    static var goneAt: ContinuousClock.Instant?
    /// The rows the page shows, and its own selection, for the check.
    static weak var shown: MacLibraryBrowser?
    static var shownRows: [LibraryFrame.ID] = []
    /// The page's own *Lay Down n*, as it stands, and whether the selection was cut to the room.
    static var pressLayDown: (() -> Void)?
    static var wasTrimmed = false
    #endif

    private static let columnWidth: CGFloat = 250

    @State private var made = MacAddRows()

    var body: some View {
        let days = made.days(library.frames, oldestFirst: oldestFirst) { LightTableAddSheet.days(library.everyDay(oldestFirst: oldestFirst)) }
        let rows = days.filter { !hiddenDays.contains($0.day) }.flatMap { made.rows($0) }
        let chosen = rows.filter { browser.selection.contains($0.id) }.compactMap { UUID(uuidString: $0.id.image) }
        VStack(spacing: 0) {
            Text(L("Add to Light Table")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: MacMetric.pt(MacMetric.gridHeader))
                .background(Theme.panel)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Theme.wall).frame(height: 1)
            HStack(spacing: 0) {
                column(days)
                    .frame(width: MacMetric.pt(Self.columnWidth))
                    .background(Theme.panel)
                Rectangle().fill(Theme.wall).frame(width: 1)
                VStack(spacing: 0) {
                    header(rows)
                    Rectangle().fill(Theme.wall).frame(height: 1)
                    if rows.isEmpty { emptyGrid(days.isEmpty) } else { grid(rows) }
                }
                .background(Theme.background)
            }
            Rectangle().fill(Theme.wall).frame(height: 1)
            bottomBar(rows, chosen: chosen)
        }
        .background(Theme.background.ignoresSafeArea())
        .background { keys(rows, chosen: chosen) }
        .macPageActions(confirmTitle: L("Lay Down \(chosen.count)"), confirmEnabled: !chosen.isEmpty,
                        confirm: { layDown(chosen) }, cancel: cancel)
        .onChange(of: browser.selection) { _, _ in sanitize(rows) }
        #if DEBUG
        .onChange(of: chosen, initial: true) { _, now in Self.pressLayDown = { layDown(now) } }
        .onChange(of: trimmed, initial: true) { _, t in Self.wasTrimmed = t }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in Self.shownRows = ids.compactMap { UUID(uuidString: $0.image) } }
        #endif
        .onAppear {
            #if DEBUG
            Self.shownAt = .now
            Self.shown = browser
            Self.shownRows = rows.compactMap { UUID(uuidString: $0.id.image) }
            #endif
        }
        .onDisappear {
            #if DEBUG
            Self.goneAt = .now
            #endif
        }
        .accessibilityIdentifier("lighttable.add-page")
    }

    // MARK: the selection

    private func pickable(_ row: MacImage) -> Bool { !onTable.contains(UUID(uuidString: row.id.image) ?? UUID()) }

    /// A frame on the table is never chosen; past the room, the first in the grid's order are kept.
    private func sanitize(_ rows: [MacImage]) {
        // The selection this pass made itself: what it said stands.
        if let cut = lastCut, cut == browser.selection { return }
        let allowed = rows.filter { pickable($0) && browser.selection.contains($0.id) }.map(\.id)
        let kept = Set(allowed.prefix(room))
        trimmed = allowed.count > room
        lastCut = trimmed ? kept : nil
        if kept != browser.selection { browser.selection = kept }
    }

    // MARK: the left column

    private func column(_ days: [LibraryDay]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacMetric.pt(4)) {
                heading(L("On the Table"))
                Text(tableLine).font(MacMetric.font(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MacMetric.pt(12))
                Text(room == 0 ? L("The table is full: 99 films.") : L("\(room.formatted()) more fit."))
                    .font(MacMetric.font(11)).foregroundStyle(room == 0 ? Theme.danger : Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MacMetric.pt(12))
                heading(L("Shown"))
                Text(L("Only pictures developed in SpektraLab with a film size (a film edge, or a pair) go on the Light Table."))
                    .font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MacMetric.pt(12))
                if !days.isEmpty {
                    heading(L("Date Taken"))
                    ForEach(days) { d in
                        dayRow(d)
                    }
                }
            }
            .padding(.bottom, MacMetric.pt(16))
        }
        .scrollIndicators(.automatic)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased()).font(MacMetric.font(11, .semibold)).tracking(0.4).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MacMetric.pt(12))
            .padding(.top, MacMetric.pt(12))
            .frame(minHeight: MacMetric.pt(24), alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }

    private func dayRow(_ d: LibraryDay) -> some View {
        let on = !hiddenDays.contains(d.day)
        return Button {
            if on { hiddenDays.insert(d.day) } else { hiddenDays.remove(d.day) }
        } label: {
            HStack(spacing: MacMetric.pt(7)) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(MacMetric.font(13)).foregroundStyle(on ? Theme.accent : Theme.dim)
                    .frame(width: MacMetric.pt(16))
                Text(d.day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Language.shared.current.locale)))
                    .font(MacMetric.font(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(d.frames.count.formatted()).font(MacMetric.font(12)).monospacedDigit().foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, MacMetric.pt(12))
            .frame(minHeight: MacMetric.pt(MacMetric.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: the grid

    private func header(_ rows: [MacImage]) -> some View {
        @Bindable var browser = browser
        let picked = browser.selection.count
        return HStack(spacing: MacMetric.pt(8)) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            HStack(spacing: MacMetric.pt(6)) {
                Text(L("\(rows.count.formatted()) images")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                if picked > 0 {
                    Text(L("\(picked.formatted()) selected")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                }
            }
            .fixedSize()
            .layoutPriority(1)
            HStack(spacing: MacMetric.pt(5)) {
                Image(systemName: "photo").font(MacMetric.font(9)).foregroundStyle(Theme.dim)
                Slider(value: $browser.cell, in: MacMetric.cellRange)
                    .frame(width: MacMetric.pt(100))
                    .controlSize(.mini)
                    .accessibilityLabel(L("Thumbnail Size"))
                Image(systemName: "photo").font(MacMetric.font(13)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, MacMetric.pt(10))
        .frame(height: MacMetric.pt(MacMetric.gridHeader))
        .background(Theme.panel)
    }

    private func emptyGrid(_ none: Bool) -> some View {
        VStack(spacing: MacMetric.pt(8)) {
            Text(none ? L("No picture in the library can go on the Light Table yet.") : L("No pictures on the days ticked."))
                .font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if none {
                Text(L("Give a picture a film edge in Develop, and it can lie on the table at its film's size."))
                    .font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MacMetric.pt(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grid(_ rows: [MacImage]) -> some View {
        GeometryReader { geo in
            let layout = MacGridLayout(width: geo.size.width, cell: browser.cell, count: rows.count)
            let full = browser.selection.count >= room
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: layout.items, alignment: .leading, spacing: layout.gap) {
                        ForEach(rows) { image in
                            let there = !pickable(image)
                            let shut = there || (full && !browser.selection.contains(image.id))
                            MacGridCell(image: image, side: layout.side, selected: browser.selection.contains(image.id),
                                        focused: browser.focus == image.id && browser.selection.count > 1)
                                .opacity(shut ? 0.38 : 1)
                                .overlay(alignment: .topLeading) {
                                    if there {
                                        HStack(spacing: MacMetric.pt(3)) {
                                            DrawnGlyph(icon: .standLoupe, size: MacMetric.pt(10), color: Theme.text)
                                            Text(L("On the table")).font(MacMetric.font(9, .semibold)).foregroundStyle(Theme.text).fixedSize()
                                        }
                                        .padding(.horizontal, MacMetric.pt(4)).frame(height: MacMetric.pt(14))
                                        .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(3), style: .continuous))
                                        .padding(MacMetric.pt(8))
                                        .allowsHitTesting(false)
                                    }
                                }
                                .id(image.id)
                                .modifier(MacClick { flags in click(image, flags, rows) })
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(there ? image.fileName + ", " + L("On the table") : image.fileName)
                                .accessibilityAddTraits(browser.selection.contains(image.id) ? [.isButton, .isSelected] : .isButton)
                                .accessibilityIdentifier("lighttable.add.cell")
                        }
                    }
                    .padding(layout.gap)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(MacMarqueeRecognizer { state, point, flags in
                        _ = MacMarquee.drive(&marquee, state, point, flags, layout: layout, rows: rows, browser: browser)
                    })
                    // A click on the empty space chooses nothing, as the library's grid (2026-10-25).
                    .modifier(MacEmptyClick(layout: layout) { browser.selectNone() })
                    .overlay(alignment: .topLeading) { MacMarquee.drawn(marquee) }
                    .padding(.bottom, MacMetric.pt(24))
                }
                .scrollIndicators(.automatic)
                .onChange(of: browser.scrollTarget) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                    browser.scrollTarget = nil
                }
                .onAppear { browser.columns = layout.columns }
                .onChange(of: layout.columns) { _, n in browser.columns = n }
            }
        }
    }

    /// The library grid's click; a double click lays that frame down.
    private func click(_ image: MacImage, _ flags: UIKeyModifierFlags, _ rows: [MacImage]) {
        guard pickable(image) else { return }
        let command = flags.contains(.command), shift = flags.contains(.shift)
        let now = Date()
        if !command, !shift, let last = lastClick, last.id == image.id, now.timeIntervalSince(last.at) < 0.5,
           let id = UUID(uuidString: image.id.image) {
            lastClick = nil
            layDown([id])
            return
        }
        lastClick = (image.id, now)
        browser.click(image.id, command: command, shift: shift, in: rows)
    }

    // MARK: the bar

    private func bottomBar(_ rows: [MacImage], chosen: [UUID]) -> some View {
        HStack(spacing: MacMetric.pt(10)) {
            Button(L("Select All")) { browser.selectAll(rows) }
                .buttonStyle(MacAddButtonStyle(kind: .plain))
                .disabled(!rows.contains(where: pickable) || room == 0)
            if !browser.selection.isEmpty {
                Button(L("Select None")) { browser.selectNone() }
                    .buttonStyle(MacAddButtonStyle(kind: .plain))
            }
            Group {
                if trimmed {
                    Text(L("The table holds 99 films: \(room.formatted()) more fit.")).foregroundStyle(Theme.danger)
                } else if chosen.isEmpty {
                    Text(L("Choose the pictures to lay on the table.")).foregroundStyle(Theme.dim)
                } else {
                    Text("")
                }
            }
            .font(MacMetric.font(12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            Button(L("Cancel"), action: cancel)
                .buttonStyle(MacAddButtonStyle(kind: .plain))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("lighttable.add.cancel")
            Button(L("Lay Down \(chosen.count)")) { layDown(chosen) }
                .buttonStyle(MacAddButtonStyle(kind: .primary))
                .disabled(chosen.isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("lighttable.add.lay-down")
        }
        .padding(.horizontal, MacMetric.pt(14))
        .frame(maxWidth: .infinity)
        .frame(height: MacMetric.pt(44))
        .background(Theme.panel)
    }

    /// The selection's keys, as the library's and the import page's.
    private func keys(_ rows: [MacImage], chosen: [UUID]) -> some View {
        let step = max(browser.columns, 1)
        return Group {
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow) { browser.move(-1, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow) { browser.move(1, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Up"), key: .upArrow) { browser.move(-step, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Down"), key: .downArrow) { browser.move(step, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow, modifiers: .shift) { browser.move(-1, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow, modifiers: .shift) { browser.move(1, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Up"), key: .upArrow, modifiers: .shift) { browser.move(-step, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Down"), key: .downArrow, modifiers: .shift) { browser.move(step, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Select All"), key: "a", modifiers: .command) { browser.selectAll(rows) }
            HiddenKeyEquivalent(title: L("Select None"), key: "a", modifiers: [.command, .shift]) { browser.selectNone() }
            HiddenKeyEquivalent(title: L("Larger Thumbnails"), key: "=", modifiers: .command) { browser.resize(by: 1.25) }
            HiddenKeyEquivalent(title: L("Smaller Thumbnails"), key: "-", modifiers: .command) { browser.resize(by: 1 / 1.25) }
        }
        .accessibilityHidden(true)
    }
}

/// The page's days and rows, made once for the library as it is (a click re-draws the page; it must not sort
/// and group every frame again, nor make every row again).
@MainActor
private final class MacAddRows {
    private var frames: [LibraryFrame]?
    private var oldestFirst = false
    private var kept: [LibraryDay] = []
    private var rowsByDay: [Date: [MacImage]] = [:]

    func days(_ frames: [LibraryFrame], oldestFirst: Bool, make: () -> [LibraryDay]) -> [LibraryDay] {
        if self.frames != frames || self.oldestFirst != oldestFirst {
            self.frames = frames
            self.oldestFirst = oldestFirst
            kept = make()
            rowsByDay = [:]
        }
        return kept
    }

    func rows(_ day: LibraryDay) -> [MacImage] {
        if let r = rowsByDay[day.day] { return r }
        let r = day.frames.map { CatalogSourcesStore.row($0, source: CatalogSourcesStore.appLibraryID) }
        rowsByDay[day.day] = r
        return r
    }
}

/// The page's buttons, as the import page's: the primary one in the accent, the others on `Theme.card`.
private struct MacAddButtonStyle: ButtonStyle {
    enum Kind { case primary, plain }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MacMetric.font(13, kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Theme.onSelection : Theme.text)
            .padding(.horizontal, MacMetric.pt(14))
            .frame(height: MacMetric.pt(28))
            .background(kind == .primary ? Theme.accent : Theme.card,
                        in: RoundedRectangle(cornerRadius: MacMetric.pt(6), style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : Theme.disabledOpacity)
            .fixedSize()
            .contentShape(Rectangle())
    }
}
