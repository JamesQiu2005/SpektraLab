//  MainWindowLayout.swift — the Mac's one window, and the mode as state (the owner, 2026-10-27).
//
//  "I don't want another page transition to happen when switching between library and develop/edit."
//  Until now 冲洗/编辑 was a page pushed over the library (`Route.develop` on the NavigationStack), each
//  page drawing its own bar and its own browser, so a mode press slid one window over another and made
//  the bar and the browser again (the browser's scroll position with them).
//
//  Now the window is this shell, mounted once: the bar (`WindowToolbar`) across the top, the browser panel
//  (`FloatingBrowser` round one `MacLibraryGrid`) at the right, and between them the mode's own content
//  — the library page's column and viewer, or the develop page's column, canvas and info strip. The mode
//  is the router's path, read, not pushed: a `.develop` on it is 冲洗/编辑, none is 图库. So everything that
//  already asks the path — ⌘[ (`router.back`), `toLibrary`, a
//  develop page's own ways back — means the same as before, and only what the window draws changed.
//
//  - The NavigationStack still carries the full-window pages — the Light Table, the photo and gallery
//    pages — but only what lies *above* the last develop (`MacShellPath`); the shell is its root.
//  - The library page stays mounted while 冲洗/编辑 is in front (hidden, its keys off), so its sidebar's
//    scroll, its presentations and its state are as they were when 图库 comes back. The develop page is
//    made on entering and let go on leaving, as before (its session keeps and leaves as it did).
//  - The bar and the panel are drawn at the Mac-point scale in every mode (`interfaceScaled(.macPoints)`);
//    until now the develop page drew its copies at the window-point scale, ~12 % larger.
//  - The develop page tells the bar what its half holds — undo, the actions, its crop, its column — as a
//    plain value with closures (`MacDevelopBar` in `MacShellBar`), not as views: a page's views cannot be
//    drawn outside it.
//
//  Mac only. The window and the reference device keep their pages and their pushes.

import Darwin
import GameController
import SwiftUI

/// What the develop page in front gives the window's bar: its state, as values, and its acts, as closures.
struct MacDevelopBar {
    /// Which page this is (its session), so a page leaving clears only its own.
    let owner: ObjectIdentifier
    var frameID: LibraryFrame.ID
    var surface: WorkspaceMode
    /// An inline crop is open: the mode row and the actions stand down (its Cancel and Done are the way on).
    var inCrop: Bool
    var columnShown: Bool
    var toggleColumn: () -> Void
    var crop: () -> Void
    var cropEnabled: Bool
    var chooseSurface: (WorkspaceMode) -> Void
    var canUndo: Bool, canRedo: Bool
    var undo: () -> Void, redo: () -> Void
    var resetTitle: String?, resetEnabled: Bool
    var reset: () -> Void
    var copySettings: () -> Void, presets: () -> Void, settings: () -> Void
    var pasteEnabled: Bool, pasteHint: String
    var paste: () -> Void
    var compareOn: Bool, compareEnabled: Bool, originalOn: Bool
    var compare: () -> Void, toggleOriginal: () -> Void
    /// Space, down, repeated or up: the original (`DevelopWorkspace.spaceOriginal`). True where the page took it.
    var space: (KeyPress.Phases) -> Bool
    var export: () -> Void
    /// Another frame on this page (`switchFrame`): what a browser row asks for in 冲洗/编辑.
    var open: (LibraryFrame.ID) -> Void
}

/// The bar's share the develop page publishes (`DevelopWorkspace.publishShellBar`); nil in 图库.
@MainActor @Observable
final class MacShellBar {
    static let shared = MacShellBar()
    var develop: MacDevelopBar?
}

/// The router's path as the window draws it: up to and including the last develop is the shell's (the
/// mode), what lies above it the NavigationStack's (full-window pages).
enum MacShellPath {
    static func isDevelop(_ r: Route) -> Bool { if case .develop = r { true } else { false } }

    static func split(_ path: [Route]) -> (base: [Route], stacked: [Route]) {
        guard let i = path.lastIndex(where: isDevelop) else { return ([], path) }
        return (Array(path[...i]), Array(path[(i + 1)...]))
    }

    /// The develop in the shell, if any.
    static func develop(_ path: [Route]) -> Route? { split(path).base.last }

    @MainActor static func binding(_ router: AppRouter) -> Binding<[Route]> {
        Binding(get: { split(router.path).stacked },
                set: { router.path = split(router.path).base + $0 })
    }
}

/// The library's ways onward, shared by its page and the window's bar and browser.
@MainActor
enum MacLibraryGo {
    /// Opens `image` on the develop page (the store makes its frame the first time). Among several chosen
    /// it carries them all, in the grid's order; alone, itself.
    static func open(_ image: MacImage, model: AppServices) {
        let store = MacLibraryUI.store(model)
        let browser = MacLibraryBrowser.shared
        browser.lastOpened = image.id
        let chosen = browser.selection
        let ids = chosen.count > 1 && chosen.contains(image.id) ? store.images.filter { chosen.contains($0.id) }.map(\.id) : [image.id]
        Task {
            do { try await store.openInDevelop(ids, focus: image.id) } catch { MacLibraryActions.shared.refusal = error.localizedDescription }
        }
    }

    /// A mode pressed in 图库: 冲洗 or 编辑 opens a picture on that surface — a chosen one, or else the
    /// picture `modePicture` resolves (the owner, 2026-10-27: a selection is not required), which also
    /// becomes the selection the browser shows.
    static func choose(_ mode: WorkspaceMode, rows: [MacImage], model: AppServices) {
        guard mode != .library, let image = modePicture(rows) else { return }
        let browser = MacLibraryBrowser.shared
        browser.selection = [image.id]
        browser.focus = image.id
        MacDevelopWanted.surface = mode == .edit ? .edit : .develop
        open(image, model: model)
    }

    /// The browser's focus, else the picture this library last opened, else the first row in the current
    /// sort. Nil only when the browser has no rows — the one case the modes stand down.
    static func modePicture(_ rows: [MacImage]) -> MacImage? {
        let browser = MacLibraryBrowser.shared
        if let id = browser.focus, let image = rows.first(where: { $0.id == id }) { return image }
        if let id = browser.lastOpened, let image = rows.first(where: { $0.id == id }) { return image }
        return rows.first
    }

    /// 裁剪 while browsing (the owner, 2026-10-26): the picture's pre-film crop, made a frame first if the
    /// library has never opened it. Over the library the crop page is a cover.
    static func crop(_ image: MacImage, model: AppServices) {
        let store = MacLibraryUI.store(model)
        if let id = image.develop?.frameID { model.router.show(.crop(id)); return }
        guard let macStore = store as? CatalogSourcesStore else { return }
        Task {
            guard let made = try? await macStore.frames(for: [image.id]), let id = made.frames[image.id] else { return }
            model.router.show(.crop(id))
        }
    }

    /// The grid takes the window (the owner, 2026-10-26), in any mode: pressed in 冲洗/编辑 it goes to 图库
    /// with it on; pressed again, the viewer has the window back.
    static func fullGrid(model: AppServices) {
        let browser = MacLibraryBrowser.shared
        browser.fullGrid.toggle()
        guard browser.fullGrid else { return }
        browser.viewerShown = true
        model.router.toLibrary()
    }

    /// The Light Table with `images` laid on it; with none, as it is.
    static func putOnLightTable(_ images: [MacImage], model: AppServices) {
        let store = MacLibraryUI.store(model)
        Task {
            do { try await store.putOnLightTable(images.map(\.id)) } catch { MacLibraryActions.shared.refusal = error.localizedDescription }
        }
    }
}

struct MainWindowLayout: View {
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @AppStorage(InterfaceScale.key) private var scaleChoice = InterfaceScale.standard.rawValue
    /// A drag the import page takes is over the window (`MacImportDropZone`, `MacDropOffer`).
    @State private var dropWatch = MacImportDropWatch()

    private var browser: MacLibraryBrowser { MacLibraryBrowser.shared }
    private var bar: MacShellBar { MacShellBar.shared }
    private var actions: MacLibraryActions { MacLibraryActions.shared }

    var body: some View {
        let store = MacLibraryUI.store(model)
        let rows = store.images
        let develop = MacShellPath.develop(router.path)
        let f = (InterfaceScale(rawValue: scaleChoice) ?? .standard).factor(.macPoints)
        VStack(spacing: 0) {
            // The bar, the keys and the watches of the develop page's half read apart (`OwnReads`): the page republishes
            // its half for every Undo that greys (each press and lift), and read here each re-made the whole window —
            // its browser grid and the develop page under it (2.4.0 A2).
            OwnReads { topBar(store, rows, inDevelop: develop != nil) }
                .interfaceScaled(.macPoints)
                .frame(height: WindowToolbar<EmptyView, EmptyView, EmptyView>.height * f)
                #if DEBUG
                .onAppear { MacShellTrace.appeared("bar") }
                #endif
            GeometryReader { geo in
                HStack(spacing: 0) {
                    content(develop)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if browser.viewerShown {
                        panel(store, rows, inDevelop: develop != nil, room: geo.size, factor: f)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        // Pictures and folders dragged from Finder, in every mode: the import page with them as picked
        // (`MacImportDrop`, 2026-11-05). Refused (the cursor's ⊘) under another page's cover or sheet, and
        // for files that are not pictures, folders or catalogs; not answered at all for a drag from inside
        // the app or one with no file (`MacDropOffer`, 2026-11-09).
        .macImportDropZone(router: router, watch: dropWatch)
        .overlay {
            if dropWatch.shown || browser.dropReading != nil { MacImportDropNote(reading: browser.dropReading).ignoresSafeArea() }
        }
        // A key while the note is up: it belongs to no drag (a backstop; a drag's end is heard).
        .onKeyPress(phases: .down) { _ in
            if dropWatch.shown { dropWatch.apply { $0.interrupted() } }
            return .ignored
        }
        .background { OwnReads { shellKeys(store, rows) } }
        .background { OwnReads { ratingKeys(store, rows) } }
        .background { OwnReads { developWatch(store, rows) } }
        // A click anywhere outside the field being edited ends its editing (the owner, 2026-10-26: the
        // search and filter fields "never leave their editing state … it blocks the keyboard").
        .modifier(MacEndEditingOnClick())
        // Esc ends a field's editing wherever the field is (the owner, 2026-10-26): the key a Mac's
        // fields let go on. The field itself does not see it — a `UITextField` passes it up.
        .onKeyPress(.escape) {
            guard MacKeyFocus.editingField != nil else { return .ignored }
            MacKeyFocus.cancelEditing()
            return .handled
        }
        .background { MacKeyAnchorView() }
        .macLibraryDialogs()
        // A double exposure's second exposure, asked for over the library (合成 with one picture chosen).
        .spkSheet(item: Binding(get: { actions.secondExposure }, set: { actions.secondExposure = $0 }), detents: [.large]) { asking in
            MacPhotoPicker(title: L("Double Exposure"), subtitle: L("Choose the second exposure, on the same frame of film"),
                           marked: [asking.first], markedText: L("Same one, mirrored"), confirm: L("Create"),
                           close: { actions.secondExposure = nil }) { second in
                actions.makeDouble(from: asking.first, with: second, model: model)
            }
            .appEnvironment(model)
        }
        .task { await store.start() }
        .onChange(of: store.selectedCollectionID) { _, _ in browser.collectionChanged() }
        .onChange(of: store.selectedSourceID) { _, _ in browser.collectionChanged() }
        // The pair's row has landed (`MacPairRows.swift`): chosen, and scrolled to.
        .onChange(of: actions.landing.flatMap { id in rows.first { $0.develop?.frameID == id }?.id }) { _, row in
            guard let row else { return }
            actions.landing = nil
            choose(row)
        }
        // The search field reaches the query a moment after the typing stops — in every mode.
        .task(id: browser.search) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, store.query.text != browser.search else { return }
            var q = store.query
            q.text = browser.search
            await store.apply(q)
        }
        // Back in 图库: the window's own key chain takes hold again — the develop page had it while it was
        // in front (`DevelopWorkspace` is `.focusable`), and a page that comes back has no one to ask for it.
        .onChange(of: develop != nil) { _, isDevelop in
            if !isDevelop { MacKeyFocus.shared.takeKeys() }
        }
        #if DEBUG
        .onChange(of: develop != nil) { _, on in MacShellTrace.mode(on ? "develop" : "library") }
        #endif
    }

    /// What follows the library's frames, the develop page's half of the bar and the browser's choice, in a view of its
    /// own (`OwnReads`): the rows' develop column, the open frame's row chosen, a row chosen opened.
    private func developWatch(_ store: any MacLibraryData, _ rows: [MacImage]) -> some View {
        Color.clear.frame(width: 0, height: 0)
            // A frame made, developed or changed: the rows' develop column again. The library's frames are read here and
            // not in the window's body: every step on the develop page writes its frame's edit (2.4.0 A2).
            .onChange(of: Self.signature(library.frames)) { _, _ in (store as? MacDevelopRefreshing)?.refreshDevelopInfo() }
            // 冲洗/编辑: the open frame's row is the chosen one — unless others are chosen beside it (the batch).
            .onChange(of: bar.develop?.frameID, initial: true) { _, _ in markOpen(rows) }
            .onChange(of: rows.count) { _, _ in markOpen(rows) }
            // 冲洗/编辑: a click that leaves one row chosen opens it, as Capture One's browser does (the owner,
            // 2026-10-26: the canvas must follow "when you click a new image"). A ⌘/⇧ batch leaves the open
            // picture where it is, and `markOpen` choosing the open row is no new picture.
            .onChange(of: browser.selection) { _, chosen in
                guard let dev = bar.develop, MacShellPath.develop(router.path) != nil, !dev.inCrop,
                      chosen.count == 1, let id = chosen.first,
                      let row = rows.first(where: { $0.id == id }),
                      row.develop?.frameID != dev.frameID else { return }
                openRow(row, store: store)
            }
            .accessibilityHidden(true)
    }

    /// The mode's content: the library page (mounted always, hidden under 冲洗/编辑), and the develop page
    /// over it while a develop is on the path. No transition: the swap is the frame it happens in.
    @ViewBuilder private func content(_ develop: Route?) -> some View {
        ZStack {
            LibraryScreen()
                .opacity(develop == nil ? 1 : 0)
                .allowsHitTesting(develop == nil)
                .accessibilityHidden(develop != nil)
            if let develop {
                RouteContent(route: develop)
                    .id(develop)
            }
        }
        .transaction { $0.animation = nil }
    }

    /// Shell bindings are off under fields, presentations, stacked pages and inline crop.
    private var shortcutsFree: Bool { Self.shortcutsFree(router) }

    private static func shortcutsFree(_ router: AppRouter) -> Bool {
        let browser = MacLibraryBrowser.shared, actions = MacLibraryActions.shared
        return !browser.typing && !browser.modal && router.cover == nil && router.sheets.isEmpty
            && MacShellPath.split(router.path).stacked.isEmpty && MacShellBar.shared.develop?.inCrop != true
            && !actions.confirmingRemoval && actions.refusal == nil && !MacVariantActions.shared.confirmingDelete
    }

    @ViewBuilder private func shellKeys(_ store: any MacLibraryData, _ rows: [MacImage]) -> some View {
        let free = shortcutsFree
        let dev = MacShellPath.develop(router.path) != nil ? bar.develop : nil
        MacShortcutButton(.grid, enabled: free) { MacLibraryGo.fullGrid(model: model) }
        MacShortcutButton(.browser, enabled: free) { browser.viewerShown.toggle() }
        MacShortcutButton(.column, enabled: free) {
            if let dev { dev.toggleColumn() } else { browser.sidebarShown.toggle() }
        }
        MacShortcutButton(.crop, enabled: free && (dev?.cropEnabled ?? (browser.primary(rows) != nil))) {
            if let dev { dev.crop() } else if let row = browser.primary(rows) { MacLibraryGo.crop(row, model: model) }
        }
        MacShortcutButton(.lightTable, enabled: free) {
            MacLibraryGo.putOnLightTable(rows.filter { browser.selection.contains($0.id) }, model: model)
        }
        MacShortcutButton(.selectAll, enabled: free && !rows.isEmpty) { browser.selectAll(rows) }
        MacShortcutButton(.selectNone, enabled: free && !browser.selection.isEmpty) { browser.selectNone() }
        MacShortcutButton(.invert, enabled: free && !rows.isEmpty) {
            browser.selection = Set(rows.map(\.id)).subtracting(browser.selection)
        }
        MacShortcutButton(.previous, enabled: free && !rows.isEmpty) { browser.move(-1, extend: false, in: rows) }
        MacShortcutButton(.next, enabled: free && !rows.isEmpty) { browser.move(1, extend: false, in: rows) }
        MacShortcutButton(.first, enabled: free && !rows.isEmpty) { if let row = rows.first { choose(row.id) } }
        MacShortcutButton(.last, enabled: free && !rows.isEmpty) { if let row = rows.last { choose(row.id) } }
        MacShortcutButton(.compare, enabled: free && dev?.compareEnabled == true) { dev?.compare() }
        // Space: the original, held or switched (Settings › General › Keyboard; `MacSpaceKey`).
        MacShortcutButton(.original, enabled: free && dev != nil) { if let dev { MacSpaceKey.pressed(dev) } }
        // ⌘C copies the open frame's settings (冲洗/编辑) or the chosen picture's (图库) with the groups last
        // ticked; ⇧⌘C asks on the sheet. ⌘V (⇧⌘V) pastes onto every chosen picture, or onto the open frame
        // when it is the only one or nothing is chosen (`pasteSettings`). Both arrive as Edit's Copy and
        // Paste, so a field being edited keeps its own (`MacKeySpec.standard`).
        let source = dev?.frameID ?? browser.primary(rows)?.develop.map(\.frameID).flatMap { library.frame($0)?.id }
        MacShortcutButton(.copy, enabled: free && source != nil) {
            if let source { actions.copySettings(of: source, model: model) }
        }
        MacShortcutButton(.copyChoosing, enabled: free && source != nil) {
            if let dev { dev.copySettings() } else if let source { router.present(.copySettings(source)) }
        }
        MacShortcutButton(.paste, enabled: free && library.clipboard != nil && (dev != nil || !browser.selection.isEmpty)) {
            pasteSettings(store, rows, dev)
        }
        MacShortcutButton(.reset, enabled: free && dev?.resetEnabled == true) { dev?.reset() }
        MacShortcutButton(.export, enabled: free && (dev != nil || !browser.selection.isEmpty)) {
            if let dev { dev.export() } else { browser.exportAsked = true }
        }
        ForEach([MacShortcut.red, .yellow, .green], id: \.rawValue) { shortcut in
            MacShortcutButton(shortcut, enabled: free && !browser.selection.isEmpty && store.selectedSource?.isHelperBacked == true) {
                let label: MacColorLabel = shortcut == .red ? .red : shortcut == .yellow ? .yellow : .green
                let ids = rows.filter { browser.selection.contains($0.id) }.map(\.id)
                Task {
                    do { try await store.setColorLabel(label, for: ids) }
                    catch { actions.refusal = error.localizedDescription }
                }
            }
        }
        // F2 New Variant, F3 Clone Variant (Capture One's keys on the Mac; PRD-G §3): the Image menu's acts, on the open
        // frame in 冲洗/编辑, else on the chosen pictures (`MacVariantActions.menuCells`). Refused, the key does nothing
        // and the Image menu says why.
        let cells = MacVariantActions.menuCells(model)
        let variantsFree = free && MacVariantActions.refusal(.new, cells, model: model) == nil
        MacShortcutButton(.newVariant, enabled: variantsFree) {
            if MacAppKitEdit.isKeyRepeat { return }
            MacVariantActions.shared.perform(.new, MacVariantActions.menuCells(model), model: model)
        }
        MacShortcutButton(.cloneVariant, enabled: variantsFree) {
            if MacAppKitEdit.isKeyRepeat { return }
            MacVariantActions.shared.perform(.clone, MacVariantActions.menuCells(model), model: model)
        }
        MacShortcutButton(.fullScreen, enabled: free) {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow,
                  let ns = MacDisplay.nsWindow(for: window) else { return }
            ns.perform(NSSelectorFromString("toggleFullScreen:"), with: nil)
        }
    }

    /// ⌘V: the chosen pictures, all of them; in 冲洗/编辑 with nothing chosen but the open frame, the page's
    /// own Paste (its session, its Undo, its alert for a film this build does not have).
    private func pasteSettings(_ store: any MacLibraryData, _ rows: [MacImage], _ dev: MacDevelopBar?) {
        // ⌘V held down is one paste: AppKit fires a menu's key on every repeat (the review, 2026-11-05).
        if MacAppKitEdit.isKeyRepeat { return }
        let chosen = rows.filter { browser.selection.contains($0.id) }
        if let dev, chosen.allSatisfy({ $0.develop?.frameID == dev.frameID }) { dev.paste(); return }
        actions.pasteSettings(onto: chosen, store: store, model: model)
    }

    /// 0–5 on the chosen pictures, in every mode (the owner, 2026-10-27: the stars could not be changed in
    /// 冲洗 and 编辑 — the digits lived on the library page, which keeps no keys while hidden). Off while a
    /// field has the keyboard or a full-window page is over the shell.
    @ViewBuilder private func ratingKeys(_ store: any MacLibraryData, _ rows: [MacImage]) -> some View {
        let free = shortcutsFree
        ForEach(0...5, id: \.self) { r in
            HiddenKeyEquivalent(title: MacWords.rating(r), key: KeyEquivalent(Character(String(r))), enabled: free) {
                let ids = rows.filter { browser.selection.contains($0.id) }.map(\.id)
                guard !ids.isEmpty, store.selectedSource?.isHelperBacked == true else { return }
                Task {
                    do { try await store.setRating(r, for: ids) } catch { actions.refusal = error.localizedDescription }
                }
            }
        }
    }

    // MARK: the bar

    private func topBar(_ store: any MacLibraryData, _ rows: [MacImage], inDevelop: Bool) -> some View {
        let dev = inDevelop ? bar.develop : nil
        return WindowToolbar(browser: browser) {
            sharedControls(store, rows, dev)
        } mode: {
            modeSwitch(rows, dev, inDevelop: inDevelop)
        } actions: {
            if let dev, !dev.inCrop { MacDevelopActions(bar: dev) }
            // 图库 only: 合成, of the pictures chosen (the owner's decision 10).
            else if !inDevelop {
                MacCombineMenu(chosen: browser.picked(in: rows),
                               makeDouble: { images in actions.makeDouble(images, store: store, model: model) },
                               makePair: { images in actions.makePair(images, store: store, model: model) })
            }
        }
    }

    @ViewBuilder private func sharedControls(_ store: any MacLibraryData, _ rows: [MacImage], _ dev: MacDevelopBar?) -> some View {
        if let dev {
            MacSharedControls(store: store, browser: browser, columnShown: dev.columnShown,
                              toggleColumn: dev.toggleColumn,
                              lightTable: { MacLibraryGo.putOnLightTable($0, model: model) },
                              fullGrid: { MacLibraryGo.fullGrid(model: model) },
                              crop: dev.crop, cropping: dev.inCrop, cropEnabled: dev.cropEnabled)
        } else {
            let picture = browser.primary(rows)
            MacSharedControls(store: store, browser: browser, columnShown: browser.sidebarShown,
                              toggleColumn: { browser.sidebarShown.toggle() },
                              lightTable: { MacLibraryGo.putOnLightTable($0, model: model) },
                              fullGrid: { MacLibraryGo.fullGrid(model: model) },
                              // Always there, disabled with nothing chosen: the bar must not change shape
                              // when a picture is picked (the owner, 2026-10-27).
                              crop: { if let picture { MacLibraryGo.crop(picture, model: model) } },
                              cropEnabled: picture != nil)
        }
    }

    @ViewBuilder private func modeSwitch(_ rows: [MacImage], _ dev: MacDevelopBar?, inDevelop: Bool) -> some View {
        if inDevelop {
            MacModeSwitch(current: dev?.surface ?? .develop) { mode in
                switch mode {
                case .library: router.toLibrary()
                case .develop, .edit:
                    browser.fullGrid = false      // a surface wants the picture: the viewer comes back
                    dev?.chooseSurface(mode)
                }
            }
            .rowEnabled(!(dev?.inCrop ?? false))
        } else {
            // 冲洗 and 编辑 need no selection (the owner, 2026-10-27); only a library with no rows stands
            // them down, saying why in place.
            MacModeSwitch(current: .library,
                          enabled: { mode in mode == .library || !rows.isEmpty },
                          unavailable: { mode in (mode == .library || !rows.isEmpty) ? nil : L("There is no picture to open") },
                          choose: { mode in
                              browser.fullGrid = false
                              MacLibraryGo.choose(mode, rows: rows, model: model)
                          })
        }
    }

    // MARK: the browser

    /// The floating panel, drawn at the Mac-point scale whatever the mode: its width is the page's
    /// figure × the scale, no wider than the window leaves beside the column and the least picture.
    private func panel(_ store: any MacLibraryData, _ rows: [MacImage], inDevelop: Bool, room: CGSize, factor f: CGFloat) -> some View {
        let column: CGFloat
        if inDevelop {
            // The develop column is scene points on a page drawn at the window-point factor.
            let padF = (InterfaceScale(rawValue: scaleChoice) ?? .standard).factor(.padPoints)
            let shown = bar.develop?.columnShown ?? true
            column = shown ? PaneDividers.shared.column(in: room.width / padF) * padF / f : 0
        } else {
            column = browser.sidebarShown ? MacMetric.pt(browser.sidebarWidth) : 0
        }
        let limit = FloatingBrowser<EmptyView>.limit(width: room.width / f, column: column)
        // The whole room right of the column when the grid has the window; its kept width otherwise.
        let width = (browser.fullGrid ? room.width / f - column : min(MacMetric.pt(browser.browserWidth), limit)) + 8
        return FloatingBrowser(browser: browser, limit: limit, full: browser.fullGrid) {
            MacLibraryGrid(store: store, browser: browser, rows: rows,
                           open: { row in openRow(row, store: store) },
                           lightTable: { MacLibraryGo.putOnLightTable($0, model: model) },
                           makePair: { images in actions.makePair(images, store: store, model: model) },
                           makeDouble: { images in actions.makeDouble(images, store: store, model: model) },
                           confirmRemoval: { ids in actions.ask(ids) },
                           // The thumbnails' size in 冲洗/编辑 too (the owner, 2026-10-26: the cells are
                           // squares sized by this slider, so the canvas's browser needs it as the
                           // library's does). The header drops it whole when its width cannot hold it.
                           bar: .slim, sizeSlider: true, viewer: false)
        }
        .padding(.top, 8)
        .interfaceScaled(.macPoints)
        .frame(width: width * f)
        #if DEBUG
        .onAppear { MacShellTrace.appeared("browser") }
        #endif
    }

    /// A row opened (a double click, Return in the grid): in 图库 into Develop; in 冲洗/编辑 onto the page,
    /// made a frame first if the library has never opened it.
    private func openRow(_ row: MacImage, store: any MacLibraryData) {
        browser.fullGrid = false
        if let dev = bar.develop, MacShellPath.develop(router.path) != nil {
            MacDevelopOpening.open(row, store: store) { dev.open($0) }
        } else {
            MacLibraryGo.open(row, model: model)
        }
    }

    private func choose(_ row: MacImage.ID) {
        browser.selection = [row]
        browser.focus = row
        browser.scrollTarget = row
    }

    /// The open frame's row is the chosen one, unless the person has chosen others beside it.
    private func markOpen(_ rows: [MacImage]) {
        guard let current = bar.develop?.frameID, MacShellPath.develop(router.path) != nil,
              let row = rows.first(where: { $0.develop?.frameID == current })?.id,
              !browser.selection.contains(row) else { return }
        choose(row)
    }

    /// What of the frames the develop column depends on: which frames, their film, their develop's state.
    private static func signature(_ frames: [LibraryFrame]) -> Int {
        var h = Hasher()
        h.combine(frames.count)
        for f in frames {
            h.combine(f.id)
            h.combine(f.edit.params.filmStock)
            h.combine(f.develop.isBusy)
            h.combine(f.developed?.stamp)
            h.combine(f.isFavourite)
        }
        return h.finalize()
    }
}

/// Undo, Redo, the actions menu (Reset, Copy Settings, Presets, Canvas Colour Space, Settings), Paste, Compare,
/// then Export: the develop page's half of the bar, drawn from its `MacDevelopBar`.
struct MacDevelopActions: View {
    let bar: MacDevelopBar
    @Environment(AppSettings.self) private var settings

    private var disc: CGFloat { MacMetric.pt(28) }

    var body: some View {
        HStack(spacing: MacMetric.pt(6)) {
            Button(action: bar.undo) { round("arrow.uturn.backward") }
                .disabled(!bar.canUndo).accessibilityLabel(L("Undo"))
            Button(action: bar.redo) { round("arrow.uturn.forward") }
                .disabled(!bar.canRedo).accessibilityLabel(L("Redo"))
            Menu {
                Button(L("Undo"), action: bar.undo).disabled(!bar.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button(L("Redo"), action: bar.redo).disabled(!bar.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Button(L("Reset") + (bar.resetTitle.map { " " + $0 } ?? ""), action: bar.reset)
                    .disabled(!bar.resetEnabled)
                Divider()
                Button(L("Copy Settings"), action: bar.copySettings)
                Button(L("Presets"), action: bar.presets)
                Divider()
                // The space the canvas shows its picture in (`CanvasGamut`, 2.2.1): a proof, never an edit. This is
                // the Mac's menu; the host's `DevelopWorkspace.moreMenu` has the same picker.
                Picker(L("Canvas Colour Space"), selection: Binding(get: { settings.canvasGamut },
                                                                   set: { settings.canvasGamut = $0 })) {
                    ForEach(CanvasGamut.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("mac.develop.canvas-gamut")
                Divider()
                Button(L("Settings"), action: bar.settings)
            } label: { round("ellipsis") }
                .menuIndicator(.hidden)
                .accessibilityLabel(L("Edit actions"))
                .accessibilityIdentifier("v5.edit-actions")
            Button(action: bar.paste) { round("doc.on.clipboard") }
                .disabled(!bar.pasteEnabled)
                .accessibilityLabel(L("Paste Settings"))
                .accessibilityHint(bar.pasteHint)
                .accessibilityIdentifier("v5.paste")
            Button(action: bar.compare) { round("rectangle.lefthalf.filled", selected: bar.compareOn) }
                .disabled(!bar.compareEnabled)
                .accessibilityLabel(L("Compare"))
                .accessibilityAddTraits(bar.compareOn ? .isSelected : [])
                .contextMenu {
                    Button(bar.originalOn ? L("Process") : L("Original", as: "the picture"), action: bar.toggleOriginal)
                }
            CapsuleButton(title: L("Export"), height: disc, width: MacMetric.pt(84), action: bar.export)
                .padding(.leading, MacMetric.pt(2))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func round(_ name: String, selected: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: disc * 0.42))
            .foregroundStyle(selected ? Theme.onSelection : Theme.text)
            .frame(width: disc, height: disc)
            .background(selected ? Theme.accent : Theme.card, in: Circle())
            .contentShape(Circle())
    }
}

/// The window's plain keys — the ones a person presses without ⌘.
///
/// SwiftUI's `keyboardShortcut` lands in the Mac's menu, and a Catalyst window drops the entries that have
/// no modifier: measured 2026-10-26 on the shell — ⌘= resized the thumbnails while ← → and the digits did
/// nothing, and `.onKeyPress` on the same view saw every one of those keys arrive. So the plain keys are
/// `UIKeyCommand`s with `wantsPriorityOverSystemBehavior`, held by a view that is the window's first
/// responder whenever no field is being edited (`MacLightTableMenu` is the same pattern).
final class MacKeyAnchor: UIView {
    static weak var shared: MacKeyAnchor?

    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { becomeFirstResponder() } }
    @objc func spkShortcut(_ command: UIKeyCommand) { MacShortcutRegistry.shared.perform(command) }
    // Edit's Select All, Copy and Paste (`MacKeySpec.standard`): ⌘A, ⌘C and ⌘V, and their menu items.
    override func selectAll(_ sender: Any?) { MacShortcutRegistry.shared.performStandard(#selector(selectAll(_:))) }
    override func copy(_ sender: Any?) { MacShortcutRegistry.shared.performStandard(#selector(copy(_:))) }
    override func paste(_ sender: Any?) { MacShortcutRegistry.shared.performStandard(#selector(paste(_:))) }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(spkShortcut(_:)), let c = sender as? UIKeyCommand { return MacShortcutRegistry.shared.canPerform(c) }
        if MacKeySpec.standard(for: action) != nil { return MacShortcutRegistry.shared.canPerformStandard(action) }
        return super.canPerformAction(action, withSender: sender)
    }
    override var keyCommands: [UIKeyCommand]? { MacShortcutRegistry.shared.keyCommands }
}

struct MacKeyAnchorView: UIViewRepresentable {
    func makeUIView(context: Context) -> MacKeyAnchor {
        let view = MacKeyAnchor(frame: .zero)
        MacKeyAnchor.shared = view
        MacKeyFocus.anchor = view
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ view: MacKeyAnchor, context: Context) {}
}

/// Who has the keys: a field being edited, or the page (`MacLibraryPage`, `DevelopWorkspace`).
///
/// Catalyst leaves a tapped `UITextField` as the window's first responder until something asks it to
/// stand down, and nothing on these pages did: the owner, 2026-10-26 — "the two search fields never quit
/// their input status … it blocks the keyboard so only some keyboard functions work". A field that keeps
/// the keys takes every letter and arrow, so the browser's own shortcuts never see them.
///
/// `pulse` counts the times a field has been left: a page in front takes the keys again when it moves,
/// which is what makes ← → and the digits work after a search (`MacEndEditingOnClick`).
@MainActor @Observable
final class MacKeyFocus {
    static let shared = MacKeyFocus()
    private(set) var pulse = 0
    struct Commit {
        let owner: UUID
        let finish: () -> Void
        /// Esc: what is typed goes, and the field closes (a slider's number, 2026-11-11). Nil: Esc is `finish`.
        var cancel: (() -> Void)? = nil
    }
    /// Numeric fields commit synchronously before a page's Return action reads their bound values.
    static var commitEditing: Commit? { didSet { MacShortcutRegistry.shared.typingMayHaveChanged() } }
    /// A press on a slider's number is under way: if it is a click, it opens the number for typing, and the
    /// click is the field's, not the page's (`MacEndEditingRecognizer`). Set at the press, let go a turn after.
    static var fieldOpening = false

    /// The field being edited, if any: the window's first responder when it takes text.
    ///
    /// **Any `UITextInput`, not only `UITextField` and `UITextView`** (issue #112, 2.3.2): a SwiftUI
    /// `TextField` on Catalyst is a text input without being a `UITextField`, so a number box with the
    /// keys read as no field at all, `MacShortcutRegistry.typing` was false, and 0–5 went to the rating
    /// instead of the box (6–9, which no shortcut takes, arrived). The click recogniser below already
    /// used the wide test (`isEditingText`). The window's own anchor takes no text and is never one.
    static var editingField: UIView? {
        guard let r = UIResponder.spkFirstResponder, !(r is MacKeyAnchor) else { return nil }
        return (r is UITextField || r is UITextView || r is UITextInput) ? r as? UIView : nil
    }

    /// A page in front asks for the keys again (a click that is not on a field).
    ///
    /// The pulse is what actually ends a field's editing: a SwiftUI `TextField` whose `@FocusState` is
    /// still true holds on — measured 2026-10-26, `resignFirstResponder()` answered false — so each field
    /// clears its own focus on the pulse, and the anchor asks for the keys once that has happened.
    func takeKeys() {
        pulse += 1
        MacLibraryBrowser.shared.typing = false
        DispatchQueue.main.async { MacKeyAnchor.shared?.becomeFirstResponder() }
    }

    /// The window's own first responder, for when no field has the keys (`MacKeyAnchorView`): a Catalyst
    /// window gives SwiftUI's key commands to the responder chain, and with nothing first the plain keys
    /// are dropped (measured 2026-10-26: ⌘-shortcuts worked, ← → and the digits did not).
    static weak var anchor: MacKeyAnchor?

    /// Esc: a field that can put its text back does (a slider's number); any other ends as `endEditing`.
    static func cancelEditing() {
        guard let cancel = commitEditing?.cancel else { endEditing(); return }
        cancel()
        shared.takeKeys()
    }

    /// Editing ends — the field keeps its text, it only stops taking the keys.
    static func endEditing() {
        guard editingField != nil || commitEditing != nil else { return }
        commitEditing?.finish()
        shared.takeKeys()
    }
}

extension UIResponder {
    private static weak var spkFound: UIResponder?
    /// The window's first responder: only a responder answers this message, so the one that does is it.
    static var spkFirstResponder: UIResponder? {
        spkFound = nil
        UIApplication.shared.sendAction(#selector(spkNoteAsFirstResponder(_:)), to: nil, from: nil, for: nil)
        return spkFound
    }
    @objc fileprivate func spkNoteAsFirstResponder(_ sender: Any) { UIResponder.spkFound = self }
}

/// A click that lands anywhere but on the field being edited ends its editing — a Mac's fields do, and
/// Finder's search does. The click itself still reaches what it hit: the recogniser never cancels touches
/// and recognises beside every other gesture (a cell's, a marquee's).
struct MacEndEditingOnClick: ViewModifier {
    func body(content: Content) -> some View {
        content.gesture(MacEndEditingRecognizer())
    }
}

struct MacEndEditingRecognizer: UIGestureRecognizerRepresentable {
    final class Tap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            cancelsTouchesInView = false
            delegate = self
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    func makeUIGestureRecognizer(context: Context) -> Tap { Tap(target: nil, action: nil) }

    func handleUIGestureRecognizerAction(_ recognizer: Tap, context: Context) {
        guard recognizer.state == .ended, let window = recognizer.view?.window else { return }
        let point = recognizer.location(in: window)
        // A click on a field is the field's — it puts the caret where it was clicked, and takes the keys.
        if let hit = window.hitTest(point, with: nil), Self.isEditingText(hit) { return }
        // So is a click on a slider's number, which opens it for typing (`SliderField`): the box over the field
        // is not the field, and the keys taken back here would close it again as it opens (2026-11-11).
        if MacKeyFocus.fieldOpening { return }
        if MacKeyFocus.editingField != nil { MacKeyFocus.endEditing() }
        // The page in front has the keys again: a Catalyst window gives key commands only to a first
        // responder, and a click on a cell is the cell's, not the page's (measured 2026-10-26: ← → did
        // nothing after a click on a picture until the page was told to take the keys).
        MacKeyFocus.shared.takeKeys()
    }

    /// Whether the hit view is a text field or text view, or lives in one. Any `UITextInput` counts:
    /// SwiftUI's selectable text (`.textSelection(.enabled)`, a `TextSelectionInteractionView` on
    /// Catalyst) is one, and taking the keys from it on the click would put the anchor first and leave
    /// ⌘C copying settings over the words just selected (`MacEditCommands.copier`).
    private static func isEditingText(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let here = v {
            if here is UITextField || here is UITextView || here is UITextInput { return true }
            v = here.superview
        }
        return false
    }
}

#if DEBUG
/// The proof that a mode press makes nothing again (2026-10-27): every appearance of the bar and the
/// browser, and every mode change, as `[shell]` lines (`log show … "[shell]"`), counted.
@MainActor
enum MacShellTrace {
    private static var counts: [String: Int] = [:]
    static func appeared(_ what: String) {
        counts[what, default: 0] += 1
        NSLog("[shell] %@ appeared (#%d)", what, counts[what] ?? 0)
    }
    static func mode(_ mode: String) {
        NSLog("[shell] mode %@ · bar appeared %d · browser appeared %d", mode, counts["bar"] ?? 0, counts["browser"] ?? 0)
    }
}
#endif

/// Space on the Mac (2026-11-11): the develop page's original (`DevelopWorkspace.spaceOriginal`), from the window's
/// key command — the one path a plain key reliably takes here (measured: with SwiftUI's hosting view first, a held
/// Space reached neither `.onKeyPress` nor the anchor's `pressesBegan`, while the arrows' commands fired). A command
/// hears the key go down, and again on each auto-repeat, but never come up; so while a press is watched, every
/// further one is its repeat, and the release is read off the system's key state (`CGEventSourceKeyState`, which a
/// Catalyst SDK does not declare and the process has: looked up by name). `GCKeyboard` was tried first and reads
/// the physical keyboard alone; where neither answers, the repeats stopping is the release.
@MainActor
enum MacSpaceKey {
    private static var watching: Task<Void, Never>?
    /// When the last auto-repeat of the bar arrived: the last resort's sign that it is still held.
    private static var lastRepeat = Date.distantPast
    /// Longer than the system's first repeat delay at its slowest setting a person keeps (about half a second).
    private static let repeatSilence: TimeInterval = 0.6
    /// The spacebar's virtual key code.
    private static let spaceKeyCode: UInt16 = 49

    private typealias KeyState = @convention(c) (Int32, UInt16) -> Bool
    /// `CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, key)`.
    private static let keyState: KeyState? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSourceKeyState")
        .map { unsafeBitCast($0, to: KeyState.self) }

    /// Whether the bar is down, if the system says.
    private static var spaceDown: Bool? {
        if let keyState { return keyState(0, spaceKeyCode) }
        return GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: .spacebar)?.isPressed
    }

    static func pressed(_ dev: MacDevelopBar) {
        // A press already watched: this is its auto-repeat.
        if watching != nil || MacAppKitEdit.isKeyRepeat { lastRepeat = Date(); return }
        let took = dev.space(.down)
        #if DEBUG
        NSLog("[space] down · taken %d · key state %@", took ? 1 : 0, keyState != nil ? "system" : "keyboard")
        #endif
        guard took else { return }
        lastRepeat = Date()
        watching = Task { @MainActor in
            defer { watching = nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                if let down = spaceDown {
                    if !down { break }
                } else if Date().timeIntervalSince(lastRepeat) > repeatSilence {
                    break
                }
            }
            #if DEBUG
            NSLog("[space] up")
            #endif
            _ = MacShellBar.shared.develop?.space(.up)
        }
    }
}
