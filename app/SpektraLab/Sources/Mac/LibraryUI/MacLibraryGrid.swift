//  MacLibraryGrid.swift — the grid right of the wall (design/MAC-LIBRARY-UI.md §2, §4, §5).
//
//  Capture One's browser, not Photos': one continuous grid with no breaks by day, a header row with the
//  sort, the count ("9,661 images"), the thumbnails' size and a search field. Each row is as tall as its
//  tallest picture at the column's width (2026-10-27, `MacRowLayout`); a picture is never cut; what is
//  set on it (film, rating, colour label) is one small line directly under it.
//  Click selects; ⌘-click and ⇧-click extend; a drag from the space between pictures draws a marquee
//  (Finder's: ⇧ adds, ⌘ toggles); a click on that space chooses nothing (2026-10-25); a double click
//  opens the frame in edit. With the viewer shown
//  (`BrowserViewerSplit`) the grid is a browser at the right of the chosen picture, under the same header.
//  The cells' arithmetic and the marquee (`MacGridLayout`, `MacMarquee`) are shared with the import
//  page's grid (`Sources/Mac/Import`, 2026-10-24).

import SwiftUI
import UIKit

/// What the browser's own bar shows. `.full` is the library's header — sidebar, viewer, loupe, sort,
/// size, search, the count. `.slim` is the develop page's (the owner, 2026-10-26: the shared bar above
/// the window holds those controls there): the count and the search alone.
enum MacBrowserHeader { case full, slim, none }

struct MacLibraryGrid: View {
    let store: any MacLibraryData
    let browser: MacLibraryBrowser
    /// The rows the store has loaded, in the query's order.
    let rows: [MacImage]
    let open: (MacImage) -> Void
    /// The Light Table, with these pictures laid on it (none: as it is).
    let lightTable: ([MacImage]) -> Void
    /// 组成半格组: a half-frame pair of these one or two pictures (`MacLibraryPage.makePair`). Nil where
    /// the page that owns the pair's flow and its refusals is not the one showing the browser.
    var makePair: (([MacImage]) -> Void)? = nil
    /// Remove's confirmation, which the library page's own alert asks. Nil: the item is not offered.
    var confirmRemoval: ((Set<LibraryFrame.ID>) -> Void)? = nil
    /// The bar this grid draws itself (`MacBrowserHeader`).
    var bar: MacBrowserHeader = .full
    /// The thumbnails' size in a slim header — the library's floating panel has it, the develop page's
    /// does not (the owner, 2026-10-27: the panel's header is "count · selected · search, and in 图库 the
    /// thumbnail-size slider").
    var sizeSlider = false
    /// Whether the grid draws the viewer and its browser split itself. The pages now stand the viewer and
    /// the floating panel themselves (`WindowToolbar`, `FloatingBrowser`), so neither draws them twice.
    var viewer = true
    /// 裁剪 on a picture — the page's own way to it (the owner, 2026-10-26: it works while browsing).
    /// Nil: the bar shows no Crop.
    var crop: ((MacImage) -> Void)? = nil

    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model
    @FocusState private var searching: Bool
    /// The last click, for a double click: which cell, and when.
    @State private var lastClick: (id: MacImage.ID, at: Date)?
    /// A marquee being drawn, in the grid's own space.
    @State private var marquee: MacMarquee?
    /// Why *New Catalog…* on the empty library did not make one.
    @State private var notMade: String?

    var body: some View {
        VStack(spacing: 0) {
            switch bar {
            case .full: header
            case .slim: slimHeader
            case .none: EmptyView()
            }
            if bar != .none { Rectangle().fill(Theme.wall).frame(height: 1) }
            if viewer, browser.viewerShown {
                HStack(spacing: 0) {
                    BrowserViewerSplit(image: browser.primary(rows), open: open, chosen: browser.selection.count)
                    MacBrowserSplit(browser: browser) { content }
                }
            } else {
                content
            }
        }
        .onChange(of: searching) { _, on in browser.typing = on }
    }

    /// The floating panel's header (`MacBrowserHeader.slim`): the count and what is chosen, the
    /// thumbnails' size where `sizeSlider` asks for it, and the search — one line at the window bar's
    /// rhythm (22 pt controls, 12 pt type, the bar's inset). Nothing is cut short: what the panel's width
    /// cannot hold is left off whole, measured in the pass that draws it — the size slider first, then
    /// "N selected"; the count and the search (at its least) stay.
    private var slimHeader: some View {
        GeometryReader { geo in
            let fit = slimFit(width: geo.size.width - MacMetric.pt(12) * 2)
            HStack(spacing: MacMetric.pt(8)) {
                countLine(alwaysSelection: true, showsSelection: fit.selection)
                Spacer(minLength: 0)
                if fit.sort { MacSortControls(store: store) }
                if fit.slider { sizeControl }
                searchField
            }
            .padding(.horizontal, MacMetric.pt(12))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: MacMetric.pt(MacMetric.panelHeader))
    }

    /// Which of the header's parts fit in `width` (this page's points).
    private func slimFit(width: CGFloat) -> (sort: Bool, slider: Bool, selection: Bool) {
        func w(_ s: String, _ size: CGFloat, _ weight: UIFont.Weight) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size / MacMetric.scale, weight: weight)]).width)
        }
        let gap = MacMetric.pt(8)
        let count = w(countText, 13, .semibold)
        let picked = w(L("\(browser.selection.count.formatted()) selected"), 12, .regular) + MacMetric.pt(6)
        let search = MacMetric.pt(90)
        let slider = MacMetric.pt(70 + 5 * 2) + w("", 9, .regular) + MacMetric.pt(9 + 13)
        // The size slider first, the count of what is chosen second (the owner, 2026-10-26: the cells are
        // the slider's squares in 冲洗/编辑 too): at 1100 × 700 the panel holds the count, the slider and
        // the search, and "N selected" — which the picture's own frames and the info strip already say —
        // is the part that goes. Both are whole or absent; neither is drawn cut.
        // The order (the owner, 2026-10-27: the sort belongs here too, kept in step with the bar's) goes
        // before the slider and the count of what is chosen.
        let sort = w(MacWords.sort(store.query.sort), 12, .medium) + MacMetric.pt(8 * 2 + 4 + 10 + 4 + 22)
        var room = width - count - gap - search
        let sorts = room >= sort + gap
        if sorts { room -= sort + gap }
        let fits = sizeSlider && room >= slider + gap
        if fits { room -= slider + gap }
        let selection = browser.selection.count > 0 && room >= picked
        return (sorts, fits, selection)
    }

    /// The thumbnails' size (`trailingControls`, alone).
    private var sizeControl: some View {
        @Bindable var browser = browser
        return HStack(spacing: MacMetric.pt(5)) {
            Image(systemName: "photo").font(MacMetric.font(9)).foregroundStyle(Theme.dim)
            Slider(value: $browser.cell, in: MacMetric.cellRange)
                .frame(width: MacMetric.pt(70))
                .controlSize(.mini)
                .accessibilityLabel(L("Thumbnail Size"))
            Image(systemName: "photo").font(MacMetric.font(13)).foregroundStyle(Theme.dim)
        }
        .fixedSize()
    }

    // MARK: the header

    private var header: some View {
        // The count sits in the middle of the header whatever the two sides hold: each side takes an equal
        // share of what is left around it.
        return HStack(spacing: MacMetric.pt(8)) {
            HStack(spacing: MacMetric.pt(8)) { leadingControls }
                .frame(maxWidth: .infinity, alignment: .leading)
            countLine()
                .layoutPriority(1)
            HStack(spacing: MacMetric.pt(8)) { trailingControls }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, MacMetric.pt(10))
        .frame(height: MacMetric.pt(MacMetric.gridHeader))
        .background(Theme.panel)
    }

    /// The sidebar, the viewer, the sort and its direction.
    @ViewBuilder private var leadingControls: some View {
        // The window's one group (`MacSharedControls`, the owner, 2026-10-26): the same view the develop
        // page's picture bar wears, in the place it has stood since 2026-10-23.
        let picture = browser.primary(rows)
        MacSharedControls(store: store, browser: browser, columnShown: browser.sidebarShown,
                          toggleColumn: { browser.sidebarShown.toggle() },
                          lightTable: lightTable,
                          fullGrid: { browser.fullGrid.toggle() },
                          crop: crop.map { crop in { if let picture { crop(picture) } } },
                          cropEnabled: picture != nil)
    }

    /// The thumbnails' size and the search field.
    @ViewBuilder private var trailingControls: some View {
        @Bindable var browser = browser
        HStack(spacing: MacMetric.pt(5)) {
            Image(systemName: "photo").font(MacMetric.font(9)).foregroundStyle(Theme.dim)
            Slider(value: $browser.cell, in: MacMetric.cellRange)
                .frame(width: MacMetric.pt(100))
                .controlSize(.mini)
                .accessibilityLabel(L("Thumbnail Size"))
            Image(systemName: "photo").font(MacMetric.font(13)).foregroundStyle(Theme.dim)
        }
        searchField
    }

    /// "9,661 images"; with a filter, "312 of 9,661 images".
    private var countText: String {
        let total = store.total
        let all = store.tree.find(store.selectedCollectionID)?.imageCount ?? total
        return store.query.isFiltered && all != total ? L("\(total.formatted()) of \(all.formatted()) images")
                                                      : L("\(total.formatted()) images")
    }

    /// The count and how many are chosen. `alwaysSelection`: the panel says "1 selected" too, where the
    /// batch it will export is one picture; `showsSelection`: whether there is room to say it at all.
    private func countLine(alwaysSelection: Bool = false, showsSelection: Bool = true) -> some View {
        let picked = browser.selection.count
        return HStack(spacing: MacMetric.pt(6)) {
            Text(countText).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
            if showsSelection, picked > (alwaysSelection ? 0 : 1) {
                Text(L("\(picked.formatted()) selected")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        @Bindable var browser = browser
        return HStack(spacing: MacMetric.pt(4)) {
            Image(systemName: "magnifyingglass").font(MacMetric.font(11)).foregroundStyle(Theme.dim)
            TextField(L("Search"), text: $browser.search)
                .font(MacMetric.font(12))
                .textFieldStyle(.plain)
                .focused($searching)
                .onSubmit { searching = false }          // Return: the text is kept, the field lets go
                .onKeyPress(.escape) { searching = false; return .handled }   // Esc: the same, as a Mac's field
                .onChange(of: MacKeyFocus.shared.pulse) { _, _ in searching = false }   // a click outside
            if !browser.search.isEmpty {
                Button { browser.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Clear"))
            }
        }
        .padding(.horizontal, MacMetric.pt(7))
        .frame(minWidth: MacMetric.pt(90), idealWidth: MacMetric.pt(170), maxWidth: MacMetric.pt(170))
        .frame(height: MacMetric.pt(22))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(11), style: .continuous))
    }

    // MARK: the grid

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            VStack(spacing: MacMetric.pt(8)) {
                if let working = store.activity.working {
                    ProgressView().controlSize(.small)
                    Text(L(shown: working)).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                } else if let problem = store.activity.problem {
                    Text(L("This library cannot be shown")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                    Text(L(shown: problem)).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                } else if store.sources.isEmpty {
                    // No catalog yet (2026-10-24: the SpektraLab Library is the person's catalogs).
                    Text(L("No catalog yet")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                    Text(L("Make a SpektraLab catalog, or open a catalog or a folder from the + menu below the sidebar."))
                        .font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button(L("New Catalog…")) { Task { notMade = await MacCatalogActions.newCatalog(store) } }
                        .font(MacMetric.font(12, .medium)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    if let notMade {
                        Text(L(shown: notMade)).font(MacMetric.font(12)).foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                } else if store.query.isFiltered {
                    Text(L("No image matches the filters.")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                    Button(L("Clear Filters")) { browser.search = ""; change { $0 = $0.cleared } }
                        .font(MacMetric.font(12, .medium)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                } else {
                    Text(L("No images in this collection.")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                }
            }
            .padding(MacMetric.pt(24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    /// The browser's cells (the owner, 2026-10-26: "each image, no matter what its aspect ratio is,
    /// occupies one square space and is always centred in that square, and its size is adjusted using the
    /// current slider"): every cell is the slider's square, the picture fitted inside it and centred both
    /// ways, and the dot · ★ · tag on one fixed-height line under it (`MacRowLayout`, `MacBrowserCell`) —
    /// so every row is the same height and the grid does not jump about when a portrait follows a
    /// landscape. The arithmetic, not hit-testing, answers the marquee and the empty click.
    private var grid: some View {
        GeometryReader { geo in
            let aspects = rows.map { MacRowLayout.aspect(of: $0, library: library, model: model) }
            let layout = MacRowLayout(width: geo.size.width, cell: browser.cell, aspects: aspects)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: layout.spacing) {
                        ForEach(0..<layout.rowCount, id: \.self) { r in
                            HStack(alignment: .top, spacing: layout.spacing) {
                                ForEach(layout.indices(ofRow: r), id: \.self) { i in
                                    cell(rows[i], i, layout)
                                }
                            }
                            .frame(height: layout.cellHeight, alignment: .top)
                            .id(MacRowLayout.RowID(r))
                        }
                    }
                    .padding(.horizontal, layout.edge)
                    .padding(.vertical, layout.edge)
                    // The space under the last row is the grid's too: a marquee starts there, as in Finder.
                    .frame(minHeight: geo.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(MacMarqueeRecognizer { state, point, flags in
                        if MacMarquee.drive(&marquee, state, point, flags, layout: layout, rows: rows, browser: browser) { searching = false }
                    })
                    .modifier(MacEmptyClick(layout: layout) { searching = false; browser.selectNone() })
                    .overlay(alignment: .topLeading) { MacMarquee.drawn(marquee) }
                    .padding(.bottom, MacMetric.pt(24))
                }
                .scrollIndicators(.automatic)
                .background(Theme.background)
                .onChange(of: browser.scrollTarget) { _, id in
                    guard let id else { return }
                    if let i = rows.firstIndex(where: { $0.id == id }) { proxy.scrollTo(MacRowLayout.RowID(i / layout.columns)) }
                    browser.scrollTarget = nil
                }
                .onAppear { browser.columns = layout.columns }
                .onChange(of: layout.columns) { _, n in browser.columns = n }
            }
        }
    }

    /// One picture of a row: its square, the picture fitted and centred in it, and the line under it.
    private func cell(_ image: MacImage, _ i: Int, _ layout: MacRowLayout) -> some View {
        MacBrowserCell(image: image, side: layout.side, picture: layout.pictureSize(i), pad: layout.pad,
                       line: layout.line, selected: browser.selection.contains(image.id),
                       focused: browser.focus == image.id && browser.selection.count > 1)
            // The store pages its rows: the next page when the last one shows.
            .onAppear { if image.id == rows.last?.id, rows.count < store.total { Task { await store.loadMore() } } }
            .modifier(MacClick { flags in click(image, flags) })
            .contextMenu { menu(image) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(image.fileName)
            .accessibilityAddTraits(browser.selection.contains(image.id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(image) }
            .accessibilityIdentifier("mac.library.cell")
            .frame(width: layout.cellWidth, alignment: .center)
    }

    private func click(_ image: MacImage, _ flags: UIKeyModifierFlags) {
        let command = flags.contains(.command), shift = flags.contains(.shift)
        let now = Date()
        // A second click on the same cell within the system's double-click time: open it.
        if !command, !shift, let last = lastClick, last.id == image.id, now.timeIntervalSince(last.at) < 0.5 {
            lastClick = nil
            open(image)
            return
        }
        lastClick = (image.id, now)
        searching = false
        browser.click(image.id, command: command, shift: shift, in: rows)
    }

    /// The store's query, changed and applied.
    private func change(_ edit: (inout MacImageQuery) -> Void) {
        var q = store.query
        edit(&q)
        Task { await store.apply(q) }
    }

    /// The frame's menu: the window menu's actions through the same router. On a cell among several chosen,
    /// Export, Favourite and Remove are for all the chosen frames.
    @ViewBuilder private func menu(_ image: MacImage) -> some View {
        let many = browser.selection.contains(image.id) && browser.selection.count > 1
        let chosen = many ? rows.filter { browser.selection.contains($0.id) } : [image]
        let frames = chosen.compactMap { $0.develop?.frameID }
        Button { open(image) } label: { Label(L("Open in Develop"), systemImage: "slider.horizontal.3") }
        Button { lightTable(chosen) } label: { Label(L("Put on Light Table"), systemImage: "rectangle.on.rectangle") }
        // A half-frame pair of the one or two chosen photographs (the owner, 2026-10-25): two fill its holes;
        // one asks for the second, as the window library's Pair does. A pair is not a frame of another pair.
        // Not offered where the page showing the browser does not own the pair's flow and its refusals.
        if let makePair {
            Button { makePair(chosen) } label: { Label(L("Make Half-Frame Pair"), systemImage: "rectangle.split.2x1") }
                .disabled(!(1...2).contains(chosen.count) || chosen.contains { $0.kind == .pair || $0.develop.flatMap { library.frame($0.frameID) }?.isPair == true })
        }
        if let id = image.develop?.frameID, library.frame(id) != nil {
            Button { router.present(.info(id)) } label: { Label(L("Info"), systemImage: "info.circle") }
            Divider()
            Button { router.present(.export(frames)) } label: {
                Label(frames.count > 1 ? L("Export \(frames.count)") : L("Export"), systemImage: "square.and.arrow.up")
            }
            Button { router.present(.copySettings(id)) } label: { Label(L("Copy Settings"), systemImage: "square.on.square") }
            pasteItem(chosen)
            // Previews of an edit they no longer have, made again (a Stop, or the app quit mid-way). Which
            // of them are owed is asked when it is pressed (`developPreviews`): a menu is built with its cell,
            // on every render, and a stamp per chosen frame there was hundreds per render after ⌘A.
            if frames.contains(where: { f in library.frame(f).map { !$0.develop.isBusy && model.openSession($0.id) == nil } ?? false }) {
                Button { MacLibraryActions.shared.developPreviews(of: frames, model: model) } label: {
                    Label(frames.count > 1 ? L("Develop Previews") : L("Develop Preview"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            let favourite = frames.compactMap { library.frame($0) }.allSatisfy(\.isFavourite)
            Button {
                for f in frames { library.update(f) { $0.isFavourite = !favourite } }
            } label: {
                Label(favourite ? L("Unfavourite") : L("Favourite"), systemImage: favourite ? "heart.slash" : "heart")
            }
        } else {
            // Never opened: nothing to copy yet, but a paste makes its frame (`MacLibraryActions.pasteSettings`).
            Divider()
            pasteItem(chosen)
        }
        // 从 SpektraLab 中移除 for every picture, edited or not: it goes into its source's 回收站 (an edited
        // one's frame asked about first, `MacLibraryActions.removeFromSpektraLab`). In 回收站, and only
        // there, 放回 and 移到废纸篓 instead. Offered where the page has the library's dialogs.
        if confirmRemoval != nil {
            let actions = MacLibraryActions.shared
            Divider()
            if image.isTrashed || store.tree.find(store.selectedCollectionID)?.kind == .trash {
                Button { actions.putBack(chosen, store: store) } label: { Label(L("Put Back"), systemImage: "arrow.uturn.backward") }
                Button(role: .destructive) { actions.askDiscard(chosen, store: store) } label: {
                    Label(L("Move to Trash"), systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    actions.removeFromSpektraLab(chosen, frames: Set(frames.filter { library.frame($0) != nil }), store: store)
                } label: { Label(L("Remove from SpektraLab"), systemImage: "trash") }
            }
        }
    }

    /// 粘贴设置 beside 拷贝设置 (the owner, 2026-11-05: the menu had Copy and never Paste): onto every chosen
    /// picture when the cell is one of several chosen, as Export is; greyed with nothing copied.
    @ViewBuilder private func pasteItem(_ chosen: [MacImage]) -> some View {
        Button { MacLibraryActions.shared.pasteSettings(onto: chosen, store: store, model: model) } label: {
            Label(chosen.count > 1 ? L("Paste Settings to \(chosen.count)") : L("Paste Settings"), systemImage: "doc.on.clipboard")
        }
        .disabled(library.clipboard == nil)
    }
}

/// One cell: the picture fitted in a square, and under it what is set on it.
struct MacGridCell: View {
    let image: MacImage
    let side: CGFloat
    let selected: Bool
    /// The cell the keys move from, among several chosen.
    var focused = false
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model

    /// The picture's margin in its cell, and the badge line under it (the marquee's arithmetic reads them).
    static var inset: CGFloat { MacMetric.pt(6) }
    static var badges: CGFloat { MacMetric.pt(14) }
    private var inset: CGFloat { Self.inset }
    private var badges: CGFloat { Self.badges }

    var body: some View {
        let box = CGSize(width: side - inset * 2, height: side - inset * 2 - badges)
        VStack(spacing: 0) {
            picture(in: box)
                .frame(width: box.width, height: box.height)
            badgeLine.frame(height: badges)
        }
        .padding(inset)
        .frame(width: side, height: side)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: MacMetric.pt(4), style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: MacMetric.pt(4), style: .continuous)
                        .strokeBorder(Theme.selectionFrame, lineWidth: focused ? 2 : 1.5))
            }
        }
        .contentShape(Rectangle())
    }

    /// A picture opened in Develop is drawn as its frame (its develop); any other by its file's embedded preview.
    @ViewBuilder private func picture(in box: CGSize) -> some View {
        if let id = image.develop?.frameID, let kept = library.frame(id) {
                let frame = MacShownFrame.of(kept, model: model)
                let a = MacShownFrame.aspect(frame)
                let fit = box.width / box.height > a ? CGSize(width: box.height * a, height: box.height)
                                                     : CGSize(width: box.width, height: box.width / a)
                FrameView(frame: frame, pointSize: max(fit.width, fit.height), contentMode: .fit)
                    .frame(width: fit.width, height: fit.height)
                    .overlay { MacDevelopVeil(frame: frame, ring: MacMetric.pt(18)) }
        } else {
            MacFileThumb(url: image.url, box: box)
        }
    }

    private var badgeLine: some View { MacBadgeLine(image: image) }
}

/// Only what is set, each in a place of its own so one never moves or covers another: the film's round
/// dot at the left, the rating's stars in the middle, the colour label (a square, never read as a film)
/// and an original that is away at the right. One line, `MacGridCell.badges` tall.
struct MacBadgeLine: View {
    let image: MacImage
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model

    var body: some View {
        ZStack {
            HStack(spacing: MacMetric.pt(4)) {
                if let id = image.develop?.frameID, let frame = library.frame(id) {
                    StockDot(color: StockCatalog.shared.stock(frame.edit.params.filmStock)?.color ?? Theme.card, diameter: MacMetric.pt(6))
                    // Its preview is of an edit it no longer has (`MacPreviewStaleness`): Develop Previews.
                    if MacPreviewStaleness.outOfDate(frame, model: model) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(MacMetric.font(9)).foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                MacColorTag(label: image.colorLabel)
                if image.isOffline {
                    Image(systemName: "externaldrive.badge.xmark").font(MacMetric.font(9)).foregroundStyle(Theme.danger)
                }
            }
            if image.rating > 0 {
                Text(String(repeating: "★", count: image.rating)).font(MacMetric.font(9)).foregroundStyle(Theme.secondaryText)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// A file not yet a frame: its camera's embedded preview (`ThumbnailStore`: a RAW's own preview, decoded
/// off the main thread, at the size it is drawn), fitted.
struct MacFileThumb: View {
    let url: URL
    let box: CGSize
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    /// ImageIO could not make one (a file it cannot read, or cannot reach): said, not left loading.
    @State private var failed = false

    var body: some View {
        let px = PictureLoading.maxPixel(points: max(box.width, box.height), scale: scale) ?? 256
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.plot)
                    .frame(width: box.width * 0.9, height: box.width * 0.6)
                    .overlay {
                        if failed { Image(systemName: "photo.badge.exclamationmark").font(MacMetric.font(16)).foregroundStyle(Theme.faint) }
                    }
            }
        }
        .frame(width: box.width, height: box.height)
        .task(id: "\(url.path)@\(px)") {
            // The frame the camera cropped to (`CameraCrop`: a Leica Q3's digital zoom), as the frame made
            // of this file will open with it in Develop. Cut here and not in `ThumbnailStore`, whose
            // picture of a file is the whole source a frame's crop is drawn over (`CroppedPicture`, the
            // crop page).
            let known = MacCameraCrops.shared.known(url)
            let hit = ThumbnailStore.shared.cached(.file(url), maxPixel: px) ?? ThumbnailStore.shared.cachedAny(.file(url))
            // A picture already in memory is drawn at once — cut where the crop is known, whole until
            // the header has said (a DNG's first sight this session) — never the placeholder first.
            if let hit {
                image = MacCameraCrops.cut(hit, known)
                if known != nil { MacThumbAspects.shared.learn(url, image?.size ?? hit.size) }
            }
            // Nil: not read (the header could not be): the picture is shown whole, and asked again next time.
            let reading: CameraCrop.Reading?
            if let known { reading = known } else { reading = await MacCameraCrops.shared.read(url) }
            guard !Task.isCancelled else { return }
            if known == nil, let hit { image = MacCameraCrops.cut(hit, reading) }
            let made = await ThumbnailStore.shared.image(.file(url), maxPixel: px)
            guard !Task.isCancelled else { return }
            if let made { image = MacCameraCrops.cut(made, reading) } else if image == nil { failed = true }
            if let image { MacThumbAspects.shared.learn(url, image.size) }
        }
    }
}

/// The camera's crop of each file a cell has shown (`CameraCrop`), its header read once off the main
/// thread. `known` is nil for a file whose header has not been read; only a header that was read is
/// kept — one that could not be (a disk away, no access) is asked again by the next cell that shows the
/// file, so a disk mounted later is not taken for a file with no crop until the app quits.
@MainActor
final class MacCameraCrops {
    static let shared = MacCameraCrops()
    private var kept: [URL: CameraCrop.Reading] = [:]

    /// Only a DNG carries DefaultUserCrop: any other file is known to have none without a read.
    func known(_ url: URL) -> CameraCrop.Reading? {
        url.pathExtension.lowercased() == "dng" ? kept[url] : CameraCrop.Reading.uncropped
    }

    /// The file's header, read now; nil where it could not be read, which is not kept.
    func read(_ url: URL) async -> CameraCrop.Reading? {
        let reading = await Task.detached(priority: .utility) { CameraCrop.reading(url) }.value
        if let reading { kept[url] = reading }
        return reading
    }

    /// `image` (a file's preview, turned as the file says) cut to the camera's crop; as it is with none,
    /// with no reading, and where the preview is already of the crop and not of the whole picture (a
    /// camera that wrote its preview cut: `CameraCrop.previewIsCut`).
    static func cut(_ image: UIImage, _ reading: CameraCrop.Reading?) -> UIImage {
        guard let reading, let crop = reading.crop, let cg = image.cgImage else { return image }
        guard !CameraCrop.previewIsCut(width: cg.width, height: cg.height, reading) else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let r = CGRect(x: crop.x * w, y: crop.y * h, width: crop.width * w, height: crop.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 1, r.height >= 1, let out = cg.cropping(to: r) else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: - the grid's arithmetic and its marquee, shared with the import page's grid (2026-10-24)

/// A grid of square cells as both grids lay it out: fixed columns of `side`, `gap` apart and `gap` in
/// from the edge, as many as the asked cell size fits. A marquee reads which cells it touches from this
/// arithmetic, not from hit-testing (a lazy grid has no views for the rows scrolled away).
/// What a marquee and an empty click ask of a grid's arithmetic (`MacGridLayout`'s square cells, the
/// browser's rows `MacRowLayout`).
@MainActor
protocol MacGridGeometry {
    /// Whether `p` is on a picture (not a margin, a badge line or a gap).
    func onPicture(_ p: CGPoint) -> Bool
    /// The index of the cell `p` is in; nil in a gap, beside the last row, or under it.
    func cell(at p: CGPoint) -> Int?
    /// The indices of the cells `rect` touches.
    func cells(in rect: CGRect) -> [Int]
}

struct MacGridLayout: MacGridGeometry {
    let side: CGFloat
    let gap: CGFloat
    let columns: Int
    /// How many cells there are.
    let count: Int

    /// `cell`: the asked side, Mac points (`MacLibraryBrowser.cell`).
    @MainActor
    init(width: CGFloat, cell: Double, count: Int) {
        gap = MacMetric.pt(MacMetric.cellGap)
        let asked = MacMetric.pt(CGFloat(cell))
        columns = max(1, Int(((width - gap) / (asked + gap)).rounded(.down)))
        side = max(((width - gap) / CGFloat(columns) - gap).rounded(.down), 1)
        self.count = count
    }

    var items: [GridItem] { Array(repeating: GridItem(.fixed(side), spacing: gap), count: columns) }

    /// Whether `p` is on a picture (not its cell's margin, its badge line or a gap).
    @MainActor
    func onPicture(_ p: CGPoint) -> Bool {
        let pitch = side + gap
        let c = Int(((p.x - gap) / pitch).rounded(.down)), r = Int(((p.y - gap) / pitch).rounded(.down))
        guard c >= 0, c < columns, r >= 0, r * columns + c < count else { return false }
        let inset = MacGridCell.inset, badges = MacGridCell.badges
        let box = CGRect(x: gap + CGFloat(c) * pitch + inset, y: gap + CGFloat(r) * pitch + inset,
                         width: side - inset * 2, height: side - inset * 2 - badges)
        return box.contains(p)
    }

    /// The index of the cell `p` is in (its margin and badge line included, as a click on a cell takes them);
    /// nil in a gap, beside the last row, or under it.
    func cell(at p: CGPoint) -> Int? {
        let pitch = side + gap
        let c = Int(((p.x - gap) / pitch).rounded(.down)), r = Int(((p.y - gap) / pitch).rounded(.down))
        guard c >= 0, c < columns, r >= 0, r * columns + c < count else { return nil }
        let box = CGRect(x: gap + CGFloat(c) * pitch, y: gap + CGFloat(r) * pitch, width: side, height: side)
        return box.contains(p) ? r * columns + c : nil
    }

    /// The indices of the cells `rect` touches.
    func cells(in rect: CGRect) -> [Int] {
        guard count > 0, columns > 0 else { return [] }
        let pitch = side + gap
        let lastRow = (count - 1) / columns
        let r0 = max(0, Int(((rect.minY - gap) / pitch).rounded(.down)))
        let r1 = min(lastRow, Int(((rect.maxY - gap) / pitch).rounded(.down)))
        let c0 = max(0, Int(((rect.minX - gap) / pitch).rounded(.down)))
        let c1 = min(columns - 1, Int(((rect.maxX - gap) / pitch).rounded(.down)))
        guard r0 <= r1, c0 <= c1 else { return [] }
        var out: [Int] = []
        for r in r0...r1 {
            for c in c0...c1 {
                let i = r * columns + c
                guard i < count else { continue }
                let cell = CGRect(x: gap + CGFloat(c) * pitch, y: gap + CGFloat(r) * pitch, width: side, height: side)
                if cell.intersects(rect) { out.append(i) }
            }
        }
        return out
    }
}

/// The browser's cells (the owner, 2026-10-26: "each image, no matter what its aspect ratio is, occupies
/// one square space and is always centred in that square, and its size is adjusted using the current
/// slider"): fixed columns, every cell the same square `side` — as many as the asked thumbnail size fits,
/// the squares taking the width between them, as `MacGridLayout` does — with the picture aspect-fitted
/// and centred in its square both ways, and the dot · ★ · tag line a fixed height directly under it. Every
/// row is therefore the same height, and the grid does not move when a portrait follows a landscape.
///
/// A cell's frame is the square and its line with `pad` round them, so a click anywhere on a cell —
/// including the band beside a portrait — chooses that picture, while a marquee may start in that band
/// (`onPicture` is the picture alone) and, as in Finder, in the gaps and under the last row.
struct MacRowLayout: MacGridGeometry {
    /// A row's id in the scroll view (`ScrollViewReader` scrolls to rows, which a lazy stack keeps).
    struct RowID: Hashable { let row: Int; init(_ row: Int) { self.row = row } }

    /// The square's side; a cell is this wide and this tall plus the line, each size with `pad` round it.
    let side: CGFloat
    let columns: Int
    /// Between two cells, across and down; and the grid's margin.
    let spacing: CGFloat
    let edge: CGFloat
    /// The selection frame's margin round the square and its line.
    let pad: CGFloat
    let line: CGFloat
    /// Each picture's drawn size — its aspect fitted in the square, centred in it.
    let sizes: [CGSize]

    var count: Int { sizes.count }
    var cellWidth: CGFloat { side + pad * 2 }
    var cellHeight: CGFloat { side + line + pad * 2 }
    var rowCount: Int { (count + columns - 1) / columns }
    var rowTops: [CGFloat] { (0..<rowCount).map { edge + CGFloat($0) * (cellHeight + spacing) } }
    var rowHeights: [CGFloat] { Array(repeating: cellHeight, count: rowCount) }

    /// `cell`: the asked square, Mac points (`MacLibraryBrowser.cell`); `aspects`: width ÷ height.
    @MainActor
    init(width: CGFloat, cell: Double, aspects: [CGFloat]) {
        spacing = MacMetric.pt(3)
        pad = MacMetric.pt(4)
        edge = MacMetric.pt(5)
        line = MacGridCell.badges
        let asked = MacMetric.pt(CGFloat(cell)) + MacMetric.pt(4) * 2
        columns = max(1, Int(((width - edge * 2 + spacing) / (asked + spacing)).rounded(.down)))
        let square = max(((width - edge * 2 + spacing) / CGFloat(columns) - spacing - pad * 2).rounded(.down), 1)
        side = square
        self.sizes = aspects.map { a -> CGSize in
            let a = max(a, 0.05)
            return a >= 1 ? CGSize(width: square, height: (square / a).rounded())
                          : CGSize(width: (square * a).rounded(), height: square)
        }
    }

    func indices(ofRow r: Int) -> [Int] { Array((r * columns)..<min((r + 1) * columns, count)) }
    func pictureSize(_ i: Int) -> CGSize { sizes[i] }

    /// The cell's frame — its square, the line under it, `pad` round both — in the grid's space.
    func hug(_ i: Int) -> CGRect {
        let r = i / columns, c = i % columns
        return CGRect(x: edge + CGFloat(c) * (cellWidth + spacing),
                      y: edge + CGFloat(r) * (cellHeight + spacing),
                      width: cellWidth, height: cellHeight)
    }

    /// The picture alone: its size, centred in the square both ways.
    func picture(_ i: Int) -> CGRect {
        let f = hug(i), s = sizes[i]
        return CGRect(x: f.minX + pad + (side - s.width) / 2, y: f.minY + pad + (side - s.height) / 2,
                      width: s.width, height: s.height)
    }

    private func candidate(_ p: CGPoint) -> Int? {
        let c = Int(((p.x - edge) / (cellWidth + spacing)).rounded(.down))
        let r = Int(((p.y - edge) / (cellHeight + spacing)).rounded(.down))
        guard c >= 0, c < columns, r >= 0 else { return nil }
        let i = r * columns + c
        return i < count ? i : nil
    }

    func onPicture(_ p: CGPoint) -> Bool {
        guard let i = candidate(p) else { return false }
        return picture(i).contains(p)
    }

    func cell(at p: CGPoint) -> Int? {
        guard let i = candidate(p) else { return nil }
        return hug(i).contains(p) ? i : nil
    }

    func cells(in rect: CGRect) -> [Int] {
        guard count > 0 else { return [] }
        var out: [Int] = []
        for r in 0..<rowCount where rowTops[r] <= rect.maxY && rowTops[r] + cellHeight >= rect.minY {
            for i in indices(ofRow: r) where hug(i).intersects(rect) { out.append(i) }
        }
        return out
    }

    /// The shape a cell is drawn in (trap 33: the canvas's frame where the picture has one): a frame's
    /// develop, through Edit's crop; else the file's preview as it was seen (`MacThumbAspects`); else the
    /// size the library read; else 3 : 2.
    @MainActor
    static func aspect(of image: MacImage, library: FrameCatalog, model: AppServices) -> CGFloat {
        if let id = image.develop?.frameID, let kept = library.frame(id) {
            return MacShownFrame.aspect(MacShownFrame.of(kept, model: model))
        }
        if let seen = MacThumbAspects.shared.seen[image.url] { return seen }
        if let p = image.pixelSize, p.width > 0, p.height > 0 { return CGFloat(p.aspect) }
        return 1.5
    }
}

/// The shapes of file previews as they were decoded (orientation applied, which a file's stored pixel
/// size may not have), so a row learns its height from the picture it shows.
@MainActor
@Observable
final class MacThumbAspects {
    static let shared = MacThumbAspects()
    private(set) var seen: [URL: CGFloat] = [:]
    func learn(_ url: URL, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let a = size.width / size.height
        if let old = seen[url], abs(old - a) < 0.01 { return }
        seen[url] = a
    }
}

/// One picture in the browser's grid (the owner, 2026-10-26): a square `side` with the picture
/// aspect-fitted and centred in it both ways, the dot · ★ · tag line a fixed height under the square, and
/// the selection frame round the square and its line (`pad`). Every cell is the same size, so nothing
/// moves when the rows change shape.
struct MacBrowserCell: View {
    let image: MacImage
    /// The square the picture is fitted in — the same for every cell.
    let side: CGFloat
    /// The picture's drawn size in it (`MacRowLayout.pictureSize`).
    let picture: CGSize
    let pad: CGFloat
    let line: CGFloat
    let selected: Bool
    var focused = false
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            shown.frame(width: picture.width, height: picture.height)
                .frame(width: side, height: side)
            MacBadgeLine(image: image).frame(width: side, height: line)
        }
        .padding(pad)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: MacMetric.pt(4), style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: MacMetric.pt(4), style: .continuous)
                        .strokeBorder(Theme.selectionFrame, lineWidth: focused ? 2 : 1.5))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var shown: some View {
        if let id = image.develop?.frameID, let kept = library.frame(id) {
            let frame = MacShownFrame.of(kept, model: model)
            FrameView(frame: frame, pointSize: max(picture.width, picture.height), contentMode: .fit)
                .overlay { MacDevelopVeil(frame: frame, ring: MacMetric.pt(18)) }
        } else {
            MacFileThumb(url: image.url, box: picture)
        }
    }
}

/// Finder's marquee over a grid: drawn from the space between and under the pictures (one that starts on
/// a picture is not a marquee: pictures are not dragged out yet); ⇧ adds to what was chosen, ⌘ toggles,
/// neither replaces.
struct MacMarquee {
    var start: CGPoint
    var now: CGPoint
    /// What was chosen when it began, and how it combines.
    var base: Set<MacImage.ID>
    var flags: UIKeyModifierFlags
    var rect: CGRect {
        CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
    }

    /// One step of a drag (`MacMarqueeRecognizer`) over `rows` laid out as `layout`, choosing in `browser`.
    /// True when a marquee began (the grid then takes the keyboard back from a field).
    @MainActor
    static func drive(_ marquee: inout MacMarquee?, _ state: UIGestureRecognizer.State, _ point: (now: CGPoint, start: CGPoint),
                      _ flags: UIKeyModifierFlags, layout: any MacGridGeometry, rows: [MacImage], browser: MacLibraryBrowser) -> Bool {
        switch state {
        case .began:
            guard !layout.onPicture(point.start) else { marquee = nil; return false }
            marquee = MacMarquee(start: point.start, now: point.now, base: browser.selection, flags: flags)
            return true
        case .changed:
            guard var m = marquee else { return false }
            m.now = point.now
            marquee = m
            let ids = layout.cells(in: m.rect).filter { $0 < rows.count }.map { rows[$0].id }
            let set = Set(ids)
            if m.flags.contains(.command) {
                browser.selection = m.base.symmetricDifference(set)
            } else if m.flags.contains(.shift) {
                browser.selection = m.base.union(set)
            } else {
                browser.selection = set
            }
            if let first = ids.first { browser.anchor = first; browser.focus = first }
            return false
        default:
            marquee = nil
            return false
        }
    }

    /// The marquee as drawn over the grid (in the grid's own space), or nothing.
    @ViewBuilder static func drawn(_ marquee: MacMarquee?) -> some View {
        if let r = marquee?.rect {
            Rectangle().fill(Theme.accent.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }
}

/// A click with the modifier keys held as it landed (the event's own, through UIKit's tap recogniser).
struct MacClick: ViewModifier {
    let action: (UIKeyModifierFlags) -> Void
    func body(content: Content) -> some View {
        content.gesture(MacClickRecognizer(action: action))
    }
}

/// A mouse or trackpad drag (a click held and moved; a scroll is the scroll view's): where it is now and
/// where it began, in the view's own space, with the modifier keys.
struct MacMarqueeRecognizer: UIGestureRecognizerRepresentable {
    let action: (UIGestureRecognizer.State, (now: CGPoint, start: CGPoint), UIKeyModifierFlags) -> Void
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        return pan
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let now = context.converter.localLocation
        let moved = recognizer.translation(in: recognizer.view)
        action(recognizer.state, (now, CGPoint(x: now.x - moved.x, y: now.y - moved.y)), recognizer.modifierFlags)
    }
}

/// A click on a grid's empty space — a gap, beside the last row, under it — lets the selection go
/// (the owner, 2026-10-25: "in every library, the user should be able to click onto an empty part to
/// de-select"). Finder's and Capture One's way. A click on a cell is the cell's own (`MacClick`), and a
/// drag is the marquee's: a tap recogniser fails as soon as the pointer moves, so neither is taken from.
struct MacEmptyClick: ViewModifier {
    let layout: any MacGridGeometry
    let clear: () -> Void
    func body(content: Content) -> some View {
        content.gesture(MacPointClickRecognizer { point in if layout.cell(at: point) == nil { clear() } })
    }
}

/// A click and where it landed, in the view's own space.
struct MacPointClickRecognizer: UIGestureRecognizerRepresentable {
    let action: (CGPoint) -> Void
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { UITapGestureRecognizer() }
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action(context.converter.localLocation) }
    }
}

/// The viewer-and-browser switch's glyph (the library's, the import page's, the export page's): a large
/// picture with a column of thumbnails beside it, as the layout it switches is. It was
/// `rectangle.lefthalf.inset.filled` until 2026-10-25, which the owner read as the develop page's Compare
/// (`rectangle.lefthalf.filled`): "we need to change that icon, as it is the same one as the before and
/// after". `squares.leading.rectangle`, mirrored, so the thumbnails are at the right as the browser is.
struct MacViewerGlyph: View {
    let on: Bool
    var body: some View {
        Image(systemName: "squares.leading.rectangle").font(MacMetric.font(14))
            .scaleEffect(x: -1, y: 1)
            .foregroundStyle(on ? Theme.accent : Theme.secondaryText)
            .frame(width: MacMetric.pt(26), height: MacMetric.pt(22)).contentShape(Rectangle())
    }
}

struct MacClickRecognizer: UIGestureRecognizerRepresentable {
    let action: (UIKeyModifierFlags) -> Void
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { UITapGestureRecognizer() }
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action(recognizer.modifierFlags) }
    }
}
