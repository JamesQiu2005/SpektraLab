//  MacLibraryPage.swift — the Library on the Mac (design/MAC-LIBRARY-UI.md).
//
//  The navigator sidebar (`MacLibrarySidebar`) at the left, the one wall, the grid (`MacLibraryGrid`),
//  all reading one `MacLibraryData` (`MacLibraryUI.store`). Chosen by `LibraryScreen` in place of the
//  window's wide page on Mac Catalyst; the window's page, and the host's, are as they were.
//  `LibraryScreen`'s dialogs (Remove, the import's Change) stay its own.
//
//  Keys (§5): ← → ↑ ↓ (⇧ extends), Return opens in Develop, ⌘A, Escape, ⌘+ ⌘−, ⌃⌘S the sidebar,
//  ⌥⌘V the viewer, ⌘1 ⌘2 ⌘3 the navigator's tabs, Delete removes the chosen frames (asked first),
//  0–5 rate the chosen pictures (Capture One's keys), ⇧⌘L (the menu's) the Light Table. The header's
//  loupe and a picture's menu put the chosen pictures on the Light Table (2026-10-24).
//
//  Into Develop (2026-10-24): a picture opened among several chosen carries all of them, in the grid's
//  order, and a collection's right click carries its pictures; Develop's filmstrip is then that set
//  (`MacDevelopCarry`), not the whole app library. A lone picture carries itself.

import SwiftUI

struct MacLibraryPage: View {
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    @Environment(AppRouter.self) private var router

    let confirmRemoval: (Set<LibraryFrame.ID>) -> Void
    let openSettings: (SettingsPage?) -> Void
    /// The host's import banner, with its fade: `LibraryScreen.bottom`.
    let importBanner: AnyView

    @State private var dragStart: CGFloat?
    /// The library's two questions and the pair just made live in `MacLibraryActions` (2026-10-26), so the
    /// develop page's browser asks them the same way.
    private var actions: MacLibraryActions { MacLibraryActions.shared }
    private var browser: MacLibraryBrowser { MacLibraryBrowser.shared }

    var body: some View {
        let store = MacLibraryUI.store(model)
        let rows = store.images
        return presentations(window(store, rows), store)
    }

    /// The page's part of the window (`MainWindowLayout`, 2026-10-27): the column and the viewer. The bar,
    /// the browser panel and what they keep (the search, the store's start, the rows' develop column)
    /// are the shell's, mounted once for every mode.
    @ViewBuilder private func window(_ store: any MacLibraryData, _ rows: [MacImage]) -> some View {
        HStack(spacing: 0) {
            if browser.sidebarShown { columnPane(store, rows) }
            // The grid has the window (`MacLibraryBrowser.fullGrid`): the viewer steps aside for it.
            if !browser.fullGrid { centrePane(rows) }
        }
        .background(Theme.background.ignoresSafeArea())
        .background { if inFront && MacShellPath.split(router.path).stacked.isEmpty { keys(rows) } }
        .overlay(alignment: .bottom) {
            if library.importBanner != nil { importBanner.frame(maxWidth: 560) }
        }
    }

    /// 图库 is in front: no develop on the path (`MacShellPath`). Under 冲洗/编辑 this page stays mounted,
    /// hidden, and its keys are not the window's.
    private var inFront: Bool { MacShellPath.develop(router.path) == nil }

    /// What the page presents over its window: the library's two questions, and the pages a cover takes
    /// whole (The import flow, the export page, the catalog move) — each with the app's objects handed on
    /// again, at the interface scale (InterfaceScale.swift, 2026-10-24). Held apart from `window` so the
    /// type checker keeps its head.
    @ViewBuilder private func presentations<V: View>(_ content: V, _ store: any MacLibraryData) -> some View {
        content
            // One page per request (`MacLibraryBrowser.importRequest`), presented once the last page is off
            // the screen (`importPresented`): a new one is a new flow, never the page a Cancel is still
            // taking down, and a page closes only its own request.
            .fullScreenCover(item: Binding(get: { browser.importPresented }, set: { if $0 == nil, let up = browser.importPresented { browser.closeImport(up.id) } })) { request in
                MacImportFlow(store: store, request: request.id) { browser.closeImport(request.id) }
                    .id(request.id)
                    .interfaceScaled(.macPoints)
                    .appEnvironment(model)
            }
            .fullScreenCover(isPresented: Binding(get: { browser.exportAsked }, set: { browser.exportAsked = $0 })) {
                MacExportPage(store: store, images: store.images.filter { browser.selection.contains($0.id) }) { browser.exportAsked = false }
                    .interfaceScaled(.macPoints)
                    .appEnvironment(model)
            }
            // The SpektraLab Library becoming a catalog, once (`MacLibraryMove`, 2026-10-24): offered at
            // the store's start while the app library has frames no catalog took.
            .fullScreenCover(isPresented: Binding(get: { store.move.showsPage }, set: { if !$0 { store.move.dismiss() } })) {
                MacLibraryMovePage(move: store.move)
                    .interfaceScaled(.macPoints)
                    .appEnvironment(model)
            }
            .onChange(of: store.move.showsPage, initial: true) { _, on in browser.moveShown = on }
            #if DEBUG
            .onAppear { MacLibraryDriver.startIfAsked(model: model, store: store, open: open, makePair: makePair, crop: crop) }
            #endif
    }

    /// The one line between the sidebar and the grid; dragged, the sidebar's width.
    private var wall: some View {
        Rectangle().fill(Theme.wall).frame(width: 1).ignoresSafeArea()
            .overlay {
                Color.clear.frame(width: MacMetric.pt(7)).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            let start = dragStart ?? browser.sidebarWidth
                            dragStart = start
                            let w = start + v.translation.width * MacMetric.scale
                            browser.sidebarWidth = min(max(w, MacMetric.sidebarRange.lowerBound), MacMetric.sidebarRange.upperBound)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            PaneDividers.shared.save()   // the one column, kept for both pages
                        })
                    .hoverEffect(.highlight)
            }
    }

    /// 裁剪 while browsing (`MacLibraryGo.crop`).
    private func crop(_ image: MacImage) { MacLibraryGo.crop(image, model: model) }

    /// The library's column: the catalog's tree (the mode row is the window's bar's since 2026-10-27).
    @ViewBuilder private func columnPane(_ store: any MacLibraryData, _ rows: [MacImage]) -> some View {
        MacLibrarySidebar(store: store, browser: browser, rows: rows, openSettings: openSettings, open: open,
                          openCollection: open(collection:))
            .frame(width: MacMetric.pt(browser.sidebarWidth))
            .overlay(alignment: .trailing) { wall }
    }

    /// The picture (the owner, 2026-10-26: the library's centre is the viewer).
    private func centrePane(_ rows: [MacImage]) -> some View {
        BrowserViewerSplit(image: browser.primary(rows), open: open, chosen: browser.selection.count)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens `image` on the edit page (`MacLibraryGo.open`).
    private func open(_ image: MacImage) { MacLibraryGo.open(image, model: model) }

    /// A collection's pictures (as the filters leave them) into Develop, on the chosen one if it is among
    /// them, else the first. A collection over the carry's limit is refused before its rows are read.
    private func open(collection c: MacCollection) {
        let store = MacLibraryUI.store(model)
        if let n = c.imageCount, n > CatalogSourcesStore.carryLimit {
            actions.refusal = MacLibraryError.tooMany.localizedDescription
            return
        }
        Task {
            if store.selectedCollectionID != c.id { await store.select(collection: c.id) }
            await store.loadAll()
            let rows = store.images
            guard let focus = browser.primary(rows) ?? rows.first else { return }
            do { try await store.openInDevelop(rows.map(\.id), focus: focus.id) } catch { actions.refusal = error.localizedDescription }
        }
    }

    /// **组成半格组 Make Half-Frame Pair** (the owner, 2026-10-25), from a picture's menu — the flow is
    /// `MacLibraryActions.makePair`, which the develop page's browser offers too (2026-10-26).
    private func makePair(_ images: [MacImage]) {
        actions.makePair(images, store: MacLibraryUI.store(model), model: model)
    }

    /// Buttons drawn nowhere, so a hardware keyboard reaches them (as the window pages do, `HiddenKeyEquivalent`).
    /// The arrows, Return and Delete stand down while a text field has the keyboard.
    private func keys(_ rows: [MacImage]) -> some View {
        let typing = browser.typing || browser.modal || router.cover != nil || !router.sheets.isEmpty || actions.confirmingRemoval || actions.refusal != nil   // a field has the keys, or the import or export page is up
        let step = max(browser.columns, 1)
        return Group {
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow, enabled: !typing) { browser.move(-1, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow, enabled: !typing) { browser.move(1, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Up"), key: .upArrow, enabled: !typing) { browser.move(-step, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Down"), key: .downArrow, enabled: !typing) { browser.move(step, extend: false, in: rows) }
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow, modifiers: .shift, enabled: !typing) { browser.move(-1, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow, modifiers: .shift, enabled: !typing) { browser.move(1, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Up"), key: .upArrow, modifiers: .shift, enabled: !typing) { browser.move(-step, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Down"), key: .downArrow, modifiers: .shift, enabled: !typing) { browser.move(step, extend: true, in: rows) }
            HiddenKeyEquivalent(title: L("Open in Develop"), key: .return, enabled: !typing) {
                if let image = browser.primary(rows) { open(image) }
            }
            HiddenKeyEquivalent(title: L("Remove"), key: .delete, enabled: !typing) {
                let ids = Set(rows.filter { browser.selection.contains($0.id) }.compactMap { $0.develop?.frameID })
                if !ids.isEmpty { confirmRemoval(ids) }
            }
            // Esc: while a field is being edited it ends that (the owner, 2026-10-26); otherwise it lets
            // the selection go, as it always has.
            HiddenKeyEquivalent(title: L("Select None"), key: .escape, enabled: !typing) {
                if browser.typing { MacKeyFocus.endEditing() } else { browser.selectNone() }
            }
            HiddenKeyEquivalent(title: L("Larger Thumbnails"), key: "+", modifiers: .command, enabled: !typing) { browser.resize(by: 1.25) }
            HiddenKeyEquivalent(title: L("Larger Thumbnails"), key: "=", modifiers: .command, enabled: !typing) { browser.resize(by: 1.25) }
            HiddenKeyEquivalent(title: L("Smaller Thumbnails"), key: "-", modifiers: .command, enabled: !typing) { browser.resize(by: 1 / 1.25) }
            HiddenKeyEquivalent(title: L("Viewer"), key: "v", modifiers: [.command, .option], enabled: !typing) { browser.viewerShown.toggle() }
            MacShortcutButton(.libraryTab, enabled: !typing) { browser.show(.library) }
            MacShortcutButton(.filtersTab, enabled: !typing) { browser.show(.filters) }
            MacShortcutButton(.infoTab, enabled: !typing) { browser.show(.info) }
            MacShortcutButton(.filters, enabled: !typing) { browser.show(.filters) }
            // The digits (ratings) are the window's (`MainWindowLayout.ratingKeys`): 冲洗 and 编辑 rate too.
        }
        .accessibilityHidden(true)
    }
}
