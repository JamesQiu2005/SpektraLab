//  LightTablePane.swift — the light table's page (RFC-045, design/lighttable L1, L3–L11).
//
//  Pushed from the Library's quiet loupe (`Route.lightTable`); a place you go to and come back from,
//  like Develop. Built around the app's own chrome, as the drawings draw it:
//
//  - **Top bar:** ‹ the page under it (`BackWay`), *Light Table*, `···` with Tidy Up, Random (随机: square, as first put down), Scatter (打乱:
//    dropped, a little turned) and Take All Off.
//  - **The table** (`LightTableView`) between the top bar and the band, on the app's black desk, with
//    its fingers (`LightTableGestures`) and the chosen film's ring, a soft grey-white
//    (`LightTableMetalView.ringWhite`, the owner's word of 2026-10-17).
//  - **The band:** the status line in the develop page's words (`8 films · A4`, `8 films · A5 ·
//    Landscape`, `8 films · 3.5×`, `Loupe · 3×`, a chosen film's `stock · format · size · angle`, the
//    size and then the format dropping to fit), with the V5 Undo pill for 6 s after a take-off, Tidy
//    Up, Random, Scatter, Take All Off or a change of the table's size or way up; or, while Turn is lit,
//    Crop's Straighten ruler, ±45° with its detent at square.
//  - **The action row:** at rest Add, Loupe, Fit, the table's **Size** and its **Orientation**, and
//    the accent *Share*; with a film chosen its four actions, Turn 90°, Turn, Develop and Take Off
//    (Share, Size and Orientation hidden: the designer's proposal 4).
//
//  **The table's size and way up** (the owner, 2026-10-19): A4, A5 or A6, portrait or landscape,
//  the person's choice and never the host's own way up. Size is a disc reading the size it is
//  ("A4"), which opens the three as a pull-down menu, each with its millimetres, the one it is
//  checked (HIG: a pull-down menu from a button; the Camera app's discs read their state the same
//  way). Orientation is a disc of its own, Apple's `rectangle.portrait.rotate` (or `.landscape.`,
//  the way it is now), one tap turning the table. Either glides the pad, the films and the view
//  to the new table together (`LightTableController.setTable`), and offers Undo when films lie on
//  it, as a film or two may have had to move to stay clear of one another.
//
//  What the owner accepted with the drawings (2026-10-17): the black desk on the screen with the
//  share picture keeping the white one, a tap brings a film to the top, the two-finger turn only on the
//  chosen film, Share hidden while a film is chosen, Tidy Up in `···`. The page itself stays portrait
//  (the app is); the table on it turns since 2026-10-19.
//
//  **On window** (PAGES.md/lighttable.md, 2026-10-20): the page keeps the host's upright arrangement
//  whatever the window's shape — the band and the action row at the foot, never the host's side rail,
//  decided by the device, not by width over height — with the rest row centred under the table and
//  Share at its trailing end. It adds **Actual Size** (`1:1`, after Fit) where the screen's size is
//  known (`ActualSize`): a tap goes to the table's real millimetres about the view's middle, a second
//  tap back to fit; a pinch leaves it; the status line says `Actual Size`.
//
//  RAM first: the table reads pictures that exist and never starts a develop; its textures are
//  emptied whenever the page is not in front (`close`) and read again when it is (`reopen`). The
//  layout is kept beside the library's own file (`LightTableStore.beside`); the demo library and the
//  snapshot harness keep it in memory only.

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LightTablePane: View {
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var table: LightTableController?
    @State private var back = BackWay.library
    /// The Loupe tool: one finger only magnifies.
    @State private var loupeMode = false
    @State private var adding = false
    @State private var sharing = false
    @State private var undo: Undo?

    /// What Undo puts back, and the line that says what happened, for 6 s.
    private struct Undo: Equatable {
        var kept: LightTableModel
        var text: String
        var token = UUID()
    }

    private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    var body: some View {
        macPage
            .onAppear(perform: open)
            .onDisappear { table?.close(); MacRailPictures.shared.empty() }
            .onChange(of: model.library.frames) { _, frames in table?.sync(frames) }
            #if DEBUG
            // `--lighttable-check` times the sheet this page had until 2026-10-24 against the page it has now.
            .sheet(isPresented: $legacySheet) { addSheet }
            #endif
    }

    // MARK: opening

    private func open() {
        #if DEBUG
        MacLightTableCheckHook.page = checkProbe
        #endif
        if let table {
            attachRenders(table)
            table.reopen(model.library.frames)
            layCarried(table)
            return
        }
        back = router.backWay(for: .lightTable)
        let frames = model.library.frames
        let memoryOnly = model.isSnapshot || frames.contains(where: \.isDemo)
        let c = LightTableController(frames: frames, bodySeed: model.settings.bodySeed,
                                     store: LightTableStore(url: memoryOnly ? nil : LightTableStore.beside))
        c.select(nil)
        c.lensOnPointer = true          // a mouse's loupe: the lens on the pointer, as the website's
        table = c
        attachRenders(c)
        layCarried(c)
    }

    /// the films read the full-size renders kept for
    /// them, and where nothing large enough of one is kept, one job is asked for it (`MacRenderCache`). The
    /// window's table reads what the library has, as it did.
    private func attachRenders(_ c: LightTableController) {
        #if SPK_ENGINE
        if !model.isSnapshot { model.renderCache.attach(c) }
        #if DEBUG
        LightTableCheckHook.table = c
        #endif
        #endif
    }

    /// the pictures the Mac library chose (its
    /// header's loupe, a picture's menu) are laid on the table, once, when the page opens; a moment after,
    /// as `--open-lighttable` does, so the view has its size and the free spots are its.
    private func layCarried(_ c: LightTableController) {
        let ids = MacLightTableCarry.shared.take()
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            c.add(ids)
            c.select(nil)
        }
    }

    // MARK: the table

    /// `inset`: where the table fits inside the view (the Mac's floating panels keep the paper clear of them).
    @ViewBuilder private func tableArea(inset: LightTableViewport.Insets = .init(top: 10, left: 10, bottom: 10, right: 10)) -> some View {
        if let table {
            ZStack(alignment: .top) {
                LightTableView(controller: table, inset: inset) { view in
                    view.ringColor = LightTableMetalView.ringWhite
                    LightTableGestures.attach(to: view, loupeMode: { loupeMode }, clickMode: { macTool == .click && !adding })
                    _ = MacLightTableMenu(view: view, actions: menuActions(table))
                    view.describe = { id in describe(id, in: table) }
                    view.filmActions = { id in filmActions(id, in: table) }
                    view.activate = { id in
                        if table.selected == id { table.select(nil) } else { table.select(id); table.bringToTop(id) }
                    }
                    view.tableValue = { statusParts(table).last ?? "" }
                    view.escape = { table.select(nil) }
                }
                .clipped()
                if table.model.order.isEmpty {
                    // L1: an empty table offers the Library.
                    CapsuleButton(title: L("Add from Library"), width: 181) { openAdding() }
                        .frame(maxHeight: .infinity)
                        // In the middle of the room the table fits in (the Mac's panels move its insets; the
                        // window's are 10 all round, so nothing moves there).
                        .padding(EdgeInsets(top: inset.top - 10, leading: inset.left - 10,
                                            bottom: inset.bottom - 10, trailing: inset.right - 10))
                        .accessibilityIdentifier("lighttable.add-from-library")
                }
                if table.turningAngle != nil, let id = table.selected, let it = table.model.item(id) {
                    // L5: the angle while two fingers turn the film, at the top of the view.
                    Text(Self.angle(it.rot))
                        .font(Theme.Font.ui(13, .semibold)).monospacedDigit()
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(Theme.panel.opacity(0.86), in: Capsule())
                        .padding(.top, max(12, inset.top + 2))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        } else {
            Color.clear
        }
    }

    // MARK: the band

    /// The status line's candidates, longest first.
    private func statusParts(_ t: LightTableController) -> [String] {
        if sharing { return [L("Making the picture")] }
        if let undo { return [undo.text] }
        let n = t.model.order.count
        if loupeMode { return [L("Loupe") + Fmt.dot + "3×"] }
        if t.isActualSize, t.selected == nil {
            // window: "11 films  ·  A4  ·  Actual Size".
            let name = t.model.paper.name, actual = L("Actual Size")
            if n == 0 { return [name + Fmt.dot + actual] }
            return [[Self.films(n), name, actual], [Self.films(n), actual]].map { $0.joined(separator: Fmt.dot) }
        }
        if let id = t.selected, let it = t.model.item(id), let f = t.frame(id) {
            let name = Self.stockName(f), format = Self.formatName(f)
            let size = Self.sizeText(it.lying)
            let angle = Self.isSquare(it.rot) ? nil : Self.angle(it.rot)
            return [[name, format, size, angle], [name, format, angle], [name, angle]]
                .map { $0.compactMap { $0 }.joined(separator: Fmt.dot) }
        }
        let m = t.model
        let name = m.paper.name, way = m.portrait ? nil : L("Landscape"), size = Self.sizeText(Self.tableSize(m))
        if n == 0 { return [[name, way, size], [name, size]].map { $0.compactMap { $0 }.joined(separator: Fmt.dot) } }
        if t.viewport.isZoomed { return [Self.films(n) + Fmt.dot + Self.times(t.viewport.zoom)] }
        return [[Self.films(n), name, way], [Self.films(n), name]].map { $0.compactMap { $0 }.joined(separator: Fmt.dot) }
    }

    // MARK: what the controls do

    private var count: Int { table?.model.order.count ?? 0 }

    /// The table at a size or turned (`setTable`): the loupe put away first; Undo offered when films
    /// lie on it, with the line saying what the table is now.
    private func setTable(paper: LightTablePaper? = nil, portrait: Bool? = nil) {
        guard let table else { return }
        let kept = table.snapshot()
        if loupeMode {
            loupeMode = false
            table.loupe(at: nil)
        }
        guard table.setTable(paper: paper ?? table.model.paper, portrait: portrait ?? table.model.portrait) else { return }
        let m = table.model
        let line = [m.paper.name, m.portrait ? L("Portrait") : L("Landscape"), Self.sizeText(Self.tableSize(m))].joined(separator: Fmt.dot)
        if count > 0 { offerUndo(kept, line) } else { withAnimation(motion) { undo = nil } }
    }

    private func toggleLoupe() {
        guard let table else { return }
        loupeMode.toggle()
        if loupeMode {
            table.select(nil)
            table.loupe(at: CGPoint(x: table.viewport.size.width / 2, y: table.viewport.size.height / 2))
        } else {
            table.loupe(at: nil)
        }
    }

    private func takeOff(_ id: UUID, in table: LightTableController) {
        let kept = table.snapshot()
        let name = table.frame(id).map(Self.stockName) ?? ""
        table.remove(id)
        offerUndo(kept, L("Taken off") + Fmt.dot + name)
    }

    private func takeAllOff() {
        guard let table, count > 0 else { return }
        let kept = table.snapshot(), n = count
        loupeMode = false
        table.loupe(at: nil)
        table.removeAll()
        offerUndo(kept, L("Taken all off") + Fmt.dot + Self.films(n))
    }

    /// Tidy Up: every film square, in rows, in the order the frames were taken.
    private func tidyUp() {
        guard let table, count > 0 else { return }
        let kept = table.snapshot()
        let order = table.model.order.compactMap { table.frame($0) }
            .sorted { ($0.captureDate, $0.importedAt) < ($1.captureDate, $1.importedAt) }
            .map(\.id)
        table.tidyUp(order)
        offerUndo(kept, L("Tidied up") + Fmt.dot + Self.films(count))
    }

    /// Random (随机, 2026-10-19): every film laid square at random, as films are first put down, a
    /// new layout each time, with the same Undo.
    private func random() {
        guard let table, count > 0 else { return }
        let kept = table.snapshot()
        table.random()
        offerUndo(kept, L("Laid at random") + Fmt.dot + Self.films(count))
    }

    /// Scatter (打乱; 随机 until 2026-10-19): every film scattered at random and a little turned, a
    /// new scatter each time, with the same Undo.
    private func scatter() {
        guard let table, count > 0 else { return }
        let kept = table.snapshot()
        table.scatter()
        offerUndo(kept, L("Scattered") + Fmt.dot + Self.films(count))
    }

    private func offerUndo(_ kept: LightTableModel, _ text: String) {
        let next = Undo(kept: kept, text: text)
        withAnimation(motion) { undo = next }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if undo?.token == next.token { withAnimation(motion) { undo = nil } }
        }
    }

    private func undoNow() {
        guard let table, let undo else { return }
        table.restore(undo.kept)
        withAnimation(motion) { self.undo = nil }
    }

    /// *Lay Down n*: the picked frames onto the table, the last on top; nothing left chosen.
    private func layDown(_ ids: [UUID]) {
        guard let table else { return }
        undo = nil
        table.add(ids)
        table.select(nil)
    }

    @ViewBuilder private var addSheet: some View {
        if let table {
            #if DEBUG
            // The sheet the Mac had until 2026-10-24, shown only by `--lighttable-check` to time it.
            LightTableAddSheet(onTable: Set(table.model.order), room: max(0, LightTable.films - table.model.order.count),
                               layDown: layDown)
                .appEnvironment(model)
                .presentationCornerRadius(Theme.Metric.sheetRadius)
                .presentationBackground(Theme.sheet)
                .appColorScheme()
                .onAppear { MacLightTableCheckHook.legacyShownAt = .now }
                .onDisappear { MacLightTableCheckHook.legacyGoneAt = .now }
            #else
            LightTableAddSheet(onTable: Set(table.model.order), room: max(0, LightTable.films - table.model.order.count),
                               layDown: layDown)
                .appEnvironment(model)
                .presentationCornerRadius(Theme.Metric.sheetRadius)
                .presentationBackground(Theme.sheet)
                .appColorScheme()
            #endif
        }
    }

    /// The Add page: the window's sheet, or on the Mac its page over the window, at once (`MacLightTableAddPage`).
    private func openAdding() {
        if let table, table.held != nil { table.putDown(back: true) }
        if loupeMode { toggleLoupe() }
        adding = true
    }

    // MARK: Share

    /// The share picture drawn offscreen and handed straight to the system's share sheet; the
    /// picture is let go of once its file is written, the file once the sheet is done.
    private func share() {
        guard let table, !sharing, count > 0 else { return }
        // Poster or Contact Sheet, then the system's sheet (LightTableExportSheet.swift).
        LightTableExportPresenter.present(table)
    }

    // MARK: VoiceOver

    private func describe(_ id: UUID, in table: LightTableController) -> (label: String, value: String) {
        guard let f = table.frame(id), let it = table.model.item(id) else { return ("", "") }
        let l = it.lying
        let label = L("\(Self.stockName(f)), \(Self.formatName(f)), \(Self.mm(l.width)) by \(Self.mm(l.height)) millimetres")
        let value = Self.isSquare(it.rot) ? L("Not turned") : L("Turned \(Self.angle(it.rot))")
        return (label, value)
    }

    private func filmActions(_ id: UUID, in table: LightTableController) -> [UIAccessibilityCustomAction] {
        func action(_ name: String, _ run: @escaping () -> Void) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { _ in run(); return true }
        }
        let step = 5.0
        return [
            action(L("Turn Left")) { table.turnQuarter(id, dir: 1) },
            action(L("Turn Right")) { table.turnQuarter(id, dir: -1) },
            action(L("Bring to Top")) { table.bringToTop(id) },
            action(L("Move Left")) { table.move(id, by: CGVector(dx: -step, dy: 0)) },
            action(L("Move Right")) { table.move(id, by: CGVector(dx: step, dy: 0)) },
            action(L("Move Up")) { table.move(id, by: CGVector(dx: 0, dy: step)) },
            action(L("Move Down")) { table.move(id, by: CGVector(dx: 0, dy: -step)) },
            action(L("Zoom to Film")) { table.zoomToFilm(id) },
            action(L("Look Closer")) {
                table.select(nil)
                loupeMode = true
                if let box = table.screenBox(id) { table.loupe(at: CGPoint(x: box.midX, y: box.midY)) }
            },
            action(L("Develop")) { router.open(.develop(id)) },
            action(L("Take Off")) { takeOff(id, in: table) },
        ]
    }

    // MARK: - the Mac's page

    // The owner: the bottom controls "to the top right of the window", the website's [拖动 | 点击], its loupe,
    // zoom and Share; a 1:1 read from the display; "that library-like rail on the right; it should be
    // collapsible"; a right click to rotate a film or take it off; the Add page "similar to the import page".
    // The bar is `MacLightTableBar`, the rail `MacLightTableRail`, the menu `MacLightTableMenu`, the Add page
    // `MacLightTableAddPage`; what each control does is this page's own (`macActions`), the window's functions.

    /// How the pointer moves a film, and whether the rail is out: a person's own, kept for the next visit.
    @AppStorage("lighttable.mac.tool") private var macToolRaw = MacLightTableTool.drag.rawValue
    @AppStorage("lighttable.mac.rail") private var macRail = true
    #if DEBUG
    @State private var legacySheet = false
    #endif
    private var macTool: MacLightTableTool { MacLightTableTool(rawValue: macToolRaw) ?? .drag }

    /// The interface scale the develop page is drawn at (`InterfaceScale`): the floating panels are drawn in its
    /// points, so their discs are the develop bar's at every scale.
    @AppStorage(InterfaceScale.key) private var interfaceScaleRaw = InterfaceScale.standard.rawValue

    /// The table fills the window, edge to edge and under the title bar; the controls float over it on panels
    /// (2026-10-26, the owner: "all control assets floating over the base canvas"): the title panel top left,
    /// the tools panel top right (`MacLightTableBar.swift`), the rail below the tools at the right, each
    /// `MacLightTableFloat.gap` from the window's edges and from each other (`MacLightTablePanel.swift`). The
    /// table fits between them (its insets), so the paper is never under a panel at Fit. Between the panels a
    /// click is the table's; on a panel it is the panel's.
    private var macPage: some View {
        GeometryReader { geo in
            let f = (InterfaceScale(rawValue: interfaceScaleRaw) ?? .standard).factor(.padPoints)
            // The window's own top inset (`WindowShape.safeTop`, in develop points: 41 under a windowed title
            // bar, 0 in full screen), as the develop bar reads it: a reader that ignores the safe area is told 0.
            let safeTop = (model.window.safeTop ?? 0) * f
            let gap = MacLightTableFloat.gap * f
            // Below the title bar when windowed (the page starts under it, as the develop bar's does); a clear
            // margin of its own in full screen, where the window's top is the display's.
            let top = safeTop + (safeTop > 0 ? MacLightTableFloat.gapUnderTitleBar : MacLightTableFloat.gap) * f
            let band = MacLightTableFloat.band * f
            // The reader ignores the safe area: its size is the window's, title bar included.
            let whole = geo.size
            let railTop = top + band + gap
            let railShown = macRail && table != nil
            let inset = LightTableViewport.Insets(top: top + band + 10, left: 10, bottom: 10,
                                                  right: railShown ? MacLightTableRail.width + 2 * gap : 10)
            ZStack(alignment: .topLeading) {
                tableArea(inset: inset)
                    .frame(width: whole.width, height: whole.height)
                if let table {
                    MacLightTableFloatRow(spacing: gap) {
                        MacLightTableTitlePanel(backTitle: back.title, status: statusParts(table), sharing: sharing,
                                                undoShown: undo != nil, back: { router.back() }, undo: { undoNow() })
                            .floatingPanel(factor: f)
                            .clearsWindowControls()
                        MacLightTableToolsPanel(table: table, tool: macTool, loupe: loupeMode, railShown: macRail,
                                                sharing: sharing, actions: macActions(table))
                            .floatingPanel(factor: f)
                    }
                    .frame(width: max(0, whole.width - 2 * gap), height: band, alignment: .topLeading)
                    .offset(x: gap, y: top)
                    if railShown {
                        MacLightTableRail(table: table, add: openAdding, spreadOut: tidyUp, clear: takeAllOff, menu: menuActions(table))
                            .frame(height: max(0, whole.height - railTop - gap))
                            .clipShape(RoundedRectangle(cornerRadius: MacLightTableFloat.railRadius * f, style: .continuous))
                            .background(MacPanelGround(radius: MacLightTableFloat.railRadius * f))
                            .accessibilityIdentifier("lighttable.rail")
                            .offset(x: whole.width - gap - MacLightTableRail.width, y: railTop)
                    }
                }
            }
            .frame(width: whole.width, height: whole.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .background { if !adding && router.path.last == .lightTable && router.cover == nil && router.sheets.isEmpty { macKeys } }
        .overlay {
            if adding, let table {
                // Over the whole window, drawn and gone in the pass that sets `adding`: no presentation.
                MacLightTableAddPage(onTable: Set(table.model.order), room: max(0, LightTable.films - table.model.order.count),
                                     tableLine: tableLine(table), layDown: { ids in
                                         adding = false
                                         layDown(ids)
                                     }, cancel: { adding = false })
                    .ignoresSafeArea()
            }
        }
    }

    /// "3 films · A4 · Landscape": the Add page's line for the table as it is.
    private func tableLine(_ t: LightTableController) -> String {
        let n = t.model.order.count
        return ([n == 0 ? L("No films") : Self.films(n), Self.tableName(t.model)]).joined(separator: Fmt.dot)
    }

    private func macActions(_ table: LightTableController) -> MacLightTableActions {
        MacLightTableActions(
            back: { router.back() },
            setTool: { setTool($0) },
            toggleLoupe: { toggleLoupe() },
            zoomIn: { table.zoom(to: table.viewport.zoom * 1.5) },
            zoomOut: { table.zoom(to: table.viewport.zoom / 1.5) },
            fit: { table.fit() },
            actualSize: { if loupeMode { toggleLoupe() }; table.actualSize() },
            setTable: { paper, portrait in setTable(paper: paper, portrait: portrait) },
            tidyUp: { tidyUp() }, random: { random() }, scatter: { scatter() }, takeAllOff: { takeAllOff() },
            share: { share() },
            toggleRail: { macRail.toggle() },
            undo: { undoNow() },
            add: { openAdding() })
    }

    /// The menu's and the rail's actions on a film: the page's own (Take Off with its Undo).
    private func menuActions(_ table: LightTableController) -> MacLightTableMenu.Actions {
        MacLightTableMenu.Actions(rotateRight: { table.turnQuarter($0, dir: -1) },
                                  rotateLeft: { table.turnQuarter($0, dir: 1) },
                                  takeOff: { takeOff($0, in: table) })
    }

    /// The pointer's tool (D, C): a film in hand is put back first, the loupe put away (the website's `setTool`).
    private func setTool(_ t: MacLightTableTool) {
        table?.putDown(back: true)
        if loupeMode { toggleLoupe() }
        macToolRaw = t.rawValue
    }

    /// What a key does on the Mac's table (the website's keys, and the window page's): one door, so the check
    /// presses what the keyboard presses.
    enum MacKey: String, CaseIterable {
        case drag, click, loupe, fit, actualSize, zoomIn, zoomOut, rotateRight, rotateLeft, takeOff
        case left, right, up, down, bigLeft, bigRight, bigUp, bigDown, escape, develop, rail
    }

    private func macKey(_ k: MacKey) {
        guard let table, !adding else { return }
        let chosen = table.selected
        func move(_ dx: Double, _ dy: Double) { if let id = chosen { table.move(id, by: CGVector(dx: dx, dy: dy)) } }
        switch k {
        case .drag: setTool(.drag)
        case .click: setTool(.click)
        case .loupe: if !table.model.order.isEmpty { toggleLoupe() }
        case .fit: table.fit()
        case .actualSize: macActions(table).actualSize()
        case .zoomIn: table.zoom(to: table.viewport.zoom * 1.5)
        case .zoomOut: table.zoom(to: table.viewport.zoom / 1.5)
        case .rotateRight: if let id = chosen { table.turnQuarter(id, dir: -1) }
        case .rotateLeft: if let id = chosen { table.turnQuarter(id, dir: 1) }
        case .takeOff: if let id = chosen { takeOff(id, in: table) }
        case .left: move(-1, 0)
        case .right: move(1, 0)
        case .up: move(0, 1)
        case .down: move(0, -1)
        case .bigLeft: move(-10, 0)
        case .bigRight: move(10, 0)
        case .bigUp: move(0, 10)
        case .bigDown: move(0, -10)
        case .escape:
            // A film in hand back where it was; else the loupe away; else the choice let go.
            if table.held != nil { table.putDown(back: true) } else if loupeMode { toggleLoupe() } else { table.select(nil) }
        case .develop: if let id = chosen { router.open(.develop(id)) }
        case .rail: macRail.toggle()
        }
    }

    /// The keys, as hidden buttons (the library's `HiddenKeyEquivalent`), standing down while the Add page is up.
    private var macKeys: some View {
        Group {
            MacShortcutButton(.tableDrag) { macKey(.drag) }
            MacShortcutButton(.tableClick) { macKey(.click) }
            MacShortcutButton(.tableLoupe) { macKey(.loupe) }
            MacShortcutButton(.tableFit) { macKey(.fit) }
            MacShortcutButton(.tableActual) { macKey(.actualSize) }
            MacShortcutButton(.tableZoomIn) { macKey(.zoomIn) }
            MacShortcutButton(.tableZoomOut) { macKey(.zoomOut) }
            MacShortcutButton(.tableRight) { macKey(.rotateRight) }
            MacShortcutButton(.tableLeft) { macKey(.rotateLeft) }
            HiddenKeyEquivalent(title: L("Take Off"), key: .delete) { macKey(.takeOff) }
            HiddenKeyEquivalent(title: L("Move Left"), key: .leftArrow) { macKey(.left) }
            HiddenKeyEquivalent(title: L("Move Right"), key: .rightArrow) { macKey(.right) }
            HiddenKeyEquivalent(title: L("Move Up"), key: .upArrow) { macKey(.up) }
            HiddenKeyEquivalent(title: L("Move Down"), key: .downArrow) { macKey(.down) }
            HiddenKeyEquivalent(title: L("Move Left"), key: .leftArrow, modifiers: .shift) { macKey(.bigLeft) }
            HiddenKeyEquivalent(title: L("Move Right"), key: .rightArrow, modifiers: .shift) { macKey(.bigRight) }
            HiddenKeyEquivalent(title: L("Move Up"), key: .upArrow, modifiers: .shift) { macKey(.bigUp) }
            HiddenKeyEquivalent(title: L("Move Down"), key: .downArrow, modifiers: .shift) { macKey(.bigDown) }
            HiddenKeyEquivalent(title: L("Put Back"), key: .escape) { macKey(.escape) }
            HiddenKeyEquivalent(title: L("Develop"), key: .return) { macKey(.develop) }
            HiddenKeyEquivalent(title: L("Films on the Table"), key: "0", modifiers: [.command, .option]) { macKey(.rail) }
        }
        .accessibilityHidden(true)
    }

    #if DEBUG
    /// The page's own controls, for `--lighttable-check` (Sources/Mac/LightTable/MacLightTableCheck.swift).
    private var checkProbe: MacLightTableCheckHook.Page {
        MacLightTableCheckHook.Page(
            key: { macKey($0) },
            actions: { table.map { macActions($0) } },
            menuActions: { table.map { menuActions($0) } },
            tool: { macTool },
            loupe: { loupeMode },
            rail: { macRail },
            adding: { adding },
            setAdding: { adding = $0 },
            setLegacySheet: { legacySheet = $0 },
            undoShown: { undo != nil },
            status: { table.map { statusParts($0) } ?? [] })
    }
    #endif

    // MARK: words

    static func films(_ n: Int) -> String { n == 1 ? L("1 film") : L("\(n) films") }

    static func stockName(_ f: LibraryFrame) -> String {
        StockCatalog.shared.stock(f.edit.params.filmStock)?.shortName ?? f.edit.params.filmStock
    }

    /// The format a person names the frame by: a pair's half frame, the film's under Film Edge, or
    /// the frame's own film size.
    static func formatName(_ f: LibraryFrame) -> String {
        if f.pair != nil { return FilmEdgeFormat.half.label }
        if f.edit.filmEdge.effective { return f.edit.filmEdge.format.label }
        return L(shown: f.edit.params.filmFrame)
    }

    /// "56 × 56 mm", "69.5 × 56 mm".
    static func sizeText(_ s: CGSize) -> String { "\(mm(s.width)) × \(mm(s.height)) mm" }

    /// The lit area as it lies, width first: 210 × 297 for A4 portrait.
    static func tableSize(_ m: LightTableModel) -> CGSize { CGSize(width: 2 * m.half.width, height: 2 * m.half.height) }

    /// "A4", "A5  ·  Landscape": the table's size, and its way up when it is not the host's own.
    static func tableName(_ m: LightTableModel) -> String { m.portrait ? m.paper.name : m.paper.name + Fmt.dot + L("Landscape") }

    static func mm(_ v: Double) -> String {
        let r = LightTable.jsRound(v * 10) / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)
    }

    /// "3.5×", "8×".
    static func times(_ z: Double) -> String {
        let r = (z * 10).rounded() / 10
        return (r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)) + "×"
    }

    /// An angle as the status line reads it: −180 to 180, counter-clockwise positive, "+4.0°".
    static func angle(_ rot: Double) -> String {
        var d = (rot / LightTable.deg).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return signedDegrees(d)
    }

    static func signedDegrees(_ d: Double) -> String { abs(d) < 0.05 ? "0°" : Fmt.signed(d, decimals: 1) + "°" }

    /// Lying as it was laid down: no turn to say.
    static func isSquare(_ rot: Double) -> Bool { angle(rot) == "0°" }
}

/// The share picture as a file the system's share sheet can take, and the sheet itself.
@MainActor
enum LightTableSharing {
    /// The picture written as a JPEG in its own colour space (Display P3), in the temporary folder.
    static func write(_ image: CGImage) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpektraLab-Light-Table.jpg")
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    /// Apple's share sheet over whatever is in front, with the file; the file goes when it closes.
    static func present(_ url: URL) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top else { return }
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}

#if DEBUG
/// The table the page has open, for a debug build's check (`--render-check`, Sources/Mac/Render).
@MainActor
enum LightTableCheckHook {
    static weak var table: LightTableController?
}

/// The Mac page's own controls, for `--lighttable-check`.
@MainActor
enum MacLightTableCheckHook {
    struct Page {
        var key: (LightTablePane.MacKey) -> Void
        var actions: () -> MacLightTableActions?
        var menuActions: () -> MacLightTableMenu.Actions?
        var tool: () -> MacLightTableTool
        var loupe: () -> Bool
        var rail: () -> Bool
        var adding: () -> Bool
        var setAdding: (Bool) -> Void
        var setLegacySheet: (Bool) -> Void
        var undoShown: () -> Bool
        var status: () -> [String]
    }
    static var page: Page?
    /// When the sheet the Mac had until 2026-10-24 appeared and went.
    static var legacyShownAt: ContinuousClock.Instant?
    static var legacyGoneAt: ContinuousClock.Instant?
}
#endif
