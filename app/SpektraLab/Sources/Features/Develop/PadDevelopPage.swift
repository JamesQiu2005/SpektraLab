//  PadDevelopPage.swift — the develop page in the column.
//
//  PAGES.md §1–§3 (2026-10-20). This file **places** V5's page and never redraws a control: every
//  band, panel, card, slider, wheel, curve and button here is `DevelopWorkspace`'s own, on the same
//  `OpenFrameSession`, with the same ranges and detents. The picture side — the picture and the line
//  under it — and the column: the histogram, the steps, the panel, taking all the height left. The
//  column's height **unfolds** what a short window folds, and only where an existing view does it:
//  Adjust's tiles staying above the open tool, its bar under them; a panel never scrolled where it fits.
//
//  **A resize is not a new page.** The page's state is `DevelopWorkspace`'s and the session's, and the
//  canvas is one view (`DevelopRegions`), so the zoom, Compare and the original survive, and nothing
//  is developed again.
//
//  **Keys** (PAGES.md §6): ⌘B the column; ← → the frame; Space held, the original; ⌘Z and ⇧⌘Z are
//  the menu bar's Edit menu, told what they mean here (`DevelopMenuCommands.swift`).

import SwiftUI

extension DevelopWorkspace {
    /// The column is in; always while a crop stands in it.
    private var columnShown: Bool { !(pad?.columnHidden ?? false) || inlineCrop != nil }

    /// the crop open in this page (`InlineCrop`):
    /// the router's, for this frame. Only a wide window's page is its host (`hostInlineCrop`).
    var inlineCrop: InlineCrop? {
        guard let crop = router.inlineCrop, crop.frameID == frame.id, router.inlineCropHost == frame.id else { return nil }
        return crop
    }

    /// The page: the picture side and the column (`DevelopRegions`).
    var pageBody: some View {
        GeometryReader { geo in
            let cropping = inlineCrop
            let layers: CGFloat = pair != nil ? 44 : 0
            // the column is as wide as it was
            // dragged, from today's 393 pt ("the current width should be the narrowest width") to as wide as
            // the picture side (`PaneDividers`).
            let splits = PaneDividers.shared
            let columnWidth = splits.column(in: geo.size.width)
            let wall = WindowLayout.column(width: geo.size.width, hasColumn: columnShown, columnWidth: columnWidth)
            // The filmstrip too, from today's height up ("its current height is also the narrowest").
            let stripHeight = Self.infoStripHeight
            // Mac (the owner, 2026-10-27): the bar is the window's (`WindowToolbar`, full width above the
            // page, the actions pinned to its trailing edge), so the picture side keeps no top band of its
            // own — and nothing of it can be clipped by the browser beside it.
            let topBand: CGFloat = 0
            DevelopRegions(top: topBand, layers: layers, filmstrip: stripHeight, columnWidth: columnWidth) {
                // The one canvas, whatever the window: never rebuilt by a resize.
                DevelopCanvas(frame: frame, edit: session.edit, showsOriginal: original,
                              comparing: comparing, split: $split, initialZoom: opening.zoom,
                              developed: session.developed, progress: status.progress, piece: pieceMarks,
                              allowsOriginalHold: true)
                    // under an inline crop the crop is the picture; the canvas stays (a crop
                    // left keeps its zoom), unseen and untouched.
                    .opacity(cropping == nil ? 1 : 0)
                    .allowsHitTesting(cropping == nil)
                    .accessibilityHidden(cropping != nil)
                    .accessibilityAction(named: original ? L("Process") : L("Original", as: "the picture")) {
                        guard hasOriginal else { return }
                        comparing = false; original.toggle()
                    }
                    .padPart(.canvas)
                if let pair {
                    // Under the piece, no wider than the column (PAGES.md W-P1).
                    layerPicker(pair).frame(maxWidth: WindowLayout.columnWidth)
                        .frame(maxWidth: .infinity)
                        .padPart(.layers)
                }
                // Mac (the owner, 2026-10-27): the line under the picture, in the filmstrip's place — the
                // same strip the library draws under its viewer (`MacInfoStrip`), with the develop's own
                // line in it, so the column keeps no status row.
                if cropping == nil {
                    macInfoStrip.padPart(.filmstrip)
                }
                if columnShown {
                    Rectangle().fill(Theme.wall).padPart(.rule)
                    Group {
                        if cropping != nil {
                            // The column has no header of its own (the mode row is the window's bar's): the
                            // crop's controls stand in its place (`CropScreen(inline:)`, over the page).
                            Color.clear.frame(width: wall.columnWidth)
                        } else {
                            column(width: wall.columnWidth, height: geo.size.height)
                        }
                    }
                    .background(Theme.background)
                    .padPart(.controls)
                }
                if let cropping {
                    CropScreen(frameID: frame.id, target: cropping.target,
                               inline: CropPlacement(columnWidth: wall.columnWidth,
                                                     columnTop: topBand, pictureTop: topBand),
                               finishes: cropping.finishes)
                        // One crop's state is never the other's: Develop's and Edit's are two pages.
                        .id(cropping.target == .source ? "crop.source" : "crop.finished")
                        .padPart(.crop)
                }
                if columnShown, wall.rule != nil {
                    // the line between the column and the picture side is dragged.
                    DividerGrip(way: .sideways, value: wall.columnWidth, range: PaneDividers.columnRange(in: geo.size.width),
                                   grows: 1, label: L("Column width"),
                                   set: { splits.columnWidth = $0 }, ended: { splits.save() })
                        .padPart(.columnGrip)
                }
            }
        }
        // The keys and the menu bar.
        .background { keys }
        // ⌘Z and ⇧⌘Z are the menu bar's: it is told what they mean here (DevelopMenuCommands.swift).
        .focusedSceneValue(\.padEditActions, editActions)
        .focusable(true)
        .focusEffectDisabled()
        .focused($keysFocused)
        .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
            // Space held: the original, as a finger held on the picture (PAGES.md W-X2).
            guard hasOriginal, inlineCrop == nil else { return .ignored }
            if press.phase == .down { comparing = false; original = true } else { original = false }
            return .handled
        }
        // the page takes this frame's crops in place (`AppRouter.show`).
        .onAppear { joinWideWindow(); unfoldInColumn(); router.inlineCropHost = frame.id }
        .onDisappear {
            if UndoRedoRecipient.session === session { UndoRedoRecipient.session = nil }
            leaveInlineCrop()
        }
        .onChange(of: navigation.panelFolded) { _, _ in unfoldInColumn() }
    }

    private var editActions: UndoRedoActions {
        // Under an inline crop ⌘Z is the crop's (the Mac's `MacFlowUndo`), never the develop's under it.
        if inlineCrop != nil { return UndoRedoActions(canUndo: false, canRedo: false, undo: {}, redo: {}) }
        return UndoRedoActions(canUndo: session.canUndo, canRedo: session.canRedo, undo: { session.undo() }, redo: { session.redo() })
    }

    /// The page goes (another frame, the Library): its crop goes with it, unwritten, as Cancel leaves it.
    private func leaveInlineCrop() {
        if router.inlineCrop?.frameID == frame.id { router.inlineCrop = nil }
        // The next frame's page may have taken the host already (it appears before this one goes).
        if router.inlineCropHost == frame.id { router.inlineCropHost = nil }
    }

    /// The keys and the menu bar take this page, on opening.
    private func joinWideWindow() {
        keysFocused = true
        UndoRedoRecipient.session = session
    }

    /// The column never folds its panel away: it has the room (its toggle puts the whole column away).
    private func unfoldInColumn() {
        if navigation.panelFolded { session.pageNavigation.panelFolded = false }
    }

    /// Another frame from the filmstrip or the arrow keys: this page's state goes with it.
    func switchFrame(to id: LibraryFrame.ID) {
        guard let pad, id != frame.id else { return }
        var carried = DevelopOpening()
        carried.surface = navigation.surface
        carried.step = navigation.step
        carried.editTool = navigation.tool
        carried.adjustTool = navigation.adjust
        carried.adjustState = adjustState
        carried.darkroom = navigation.darkroom
        carried.enlargerTool = enlargerTool
        carried.decodeTool = navigation.decodeTool
        carried.effectsPage = effectsPage
        carried.panelFolded = navigation.panelFolded
        // The Mac's strip is the window's browser (`MainWindowLayout`), not the filmstrip this page was
        // opened with: a picture clicked there is walked by these rows, whatever the carry was.
        pad.select(id, carrying: carried, strip: macStripRows)
    }

    /// The browser's rows as frames, in its order — the strip the Mac's page walks (`MacDevelopOpening`
    /// knows the same rows): the picture just made a frame may not be in them yet, and `select` adds it.
    var macStripRows: [LibraryFrame.ID] {
        MacLibraryUI.store(model).images.compactMap { $0.develop?.frameID }
    }

    /// What the window's bar shows of this page, as values (`MainWindowLayout`): when any of it changes the
    /// page publishes its half again.
    struct MacBarSignature: Hashable {
        var frame: LibraryFrame.ID
        var edit: Bool
        var inCrop: Bool
        var columnShown: Bool
        var cropEnabled: Bool
        var canUndo: Bool, canRedo: Bool
        var resetTitle: String?, resetEnabled: Bool
        var paste: String?
        var compare: Bool, compareEnabled: Bool, original: Bool
    }

    var macBarSignature: MacBarSignature {
        MacBarSignature(frame: frame.id, edit: navigation.surface == .edit, inCrop: inlineCrop != nil,
                        columnShown: columnShown, cropEnabled: cropAction != nil,
                        canUndo: session.canUndo, canRedo: session.canRedo,
                        resetTitle: resetTitle, resetEnabled: resetTitle != nil && resetChangesAnything,
                        paste: model.library.clipboard?.summary, compare: comparing, compareEnabled: hasOriginal,
                        original: original)
    }

    /// This page's half of the window's bar (the owner, 2026-10-27): the column's toggle, 裁剪 (this
    /// surface's — Develop's crop of the picture before the film, Edit's of the finished one), the
    /// surface, and the actions — undo, redo, ⋯ (Reset on the Mac), Paste, Compare, Export (`exportIDs`).
    func publishShellBar() {
        let s = macBarSignature
        let session = session, router = router, frame = frame
        MacShellBar.shared.develop = MacDevelopBar(
            owner: ObjectIdentifier(session), frameID: frame.id,
            surface: s.edit ? .edit : .develop, inCrop: s.inCrop, columnShown: s.columnShown,
            toggleColumn: { withAnimation(motion) { pad?.columnHidden.toggle() } },
            crop: { cropAction?() }, cropEnabled: s.cropEnabled,
            chooseSurface: { mode in
                original = false
                withAnimation(motion) { session.show(mode == .edit ? .edit : .develop) }
            },
            canUndo: s.canUndo, canRedo: s.canRedo,
            undo: { session.undo() }, redo: { session.redo() },
            resetTitle: s.resetTitle, resetEnabled: s.resetEnabled, reset: { asksReset = true },
            copySettings: { router.present(.copySettings(frame.id)) }, presets: { presets = true },
            settings: { router.show(.settings) },
            pasteEnabled: s.paste != nil, pasteHint: s.paste ?? L("Nothing is copied yet"),
            paste: { pasteSettings() },
            compareOn: s.compare, compareEnabled: s.compareEnabled, originalOn: s.original,
            compare: { original = false; comparing.toggle() },
            toggleOriginal: { comparing = false; original.toggle() },
            export: { router.present(.export(exportIDs)) },
            open: { switchFrame(to: $0) })
    }

    /// The page goes: its half of the bar with it — unless the next page has published already.
    func withdrawShellBar() {
        if MacShellBar.shared.develop?.owner == ObjectIdentifier(session) { MacShellBar.shared.develop = nil }
    }

    // MARK: the column

    /// The column, `width` wide.
    private func column(width: CGFloat, height: CGFloat) -> some View {
        // Edit has no tools band (DevelopInspectorParts.swift).
        let tabs: CGFloat = !showsNavigationBand ? 0 : typeSize.isAccessibilitySize ? 60 : 56
        // The column has no header (the mode row is the window's bar's), no action row (the actions are
        // on the window's bar) and no status line (it is the info strip's, under the picture): the
        // histogram first, on Develop and on Edit alike (HistogramPanel.swift).
        let histogram = HistogramPanel.height()
        let room = max(height - histogram - tabs, 0)
        return VStack(spacing: 0) {
            histogramPanel.frame(height: histogram, alignment: .top)
            if showsNavigationBand { navigationBand.frame(height: tabs) }
            columnPanel(width: width, room: room).frame(height: room, alignment: .top).clipped()
        }
        .frame(width: width)
    }

    /// The info strip's height on the Mac (`MacInfoStrip`); the filmstrip's place it stands in.
    private static var infoStripHeight: CGFloat {
        MacInfoStrip.height
    }

    /// The strip under the picture: this frame's library row (its exposure, name, rating and label), the
    /// develop's line, or how many pictures the browser has chosen.
    private var macInfoStrip: some View {
        let row = MacLibraryUI.store(model).images.first { $0.develop?.frameID == frame.id }
        let item = row.map(MacInfoStrip.Item.init) ?? MacInfoStrip.Item(name: frame.fileName)
        return MacInfoStrip(image: item, chosen: MacLibraryBrowser.shared.selection.count,
                            status: (status.text, status.busy))
    }

    /// What Export takes on the Mac: the frames chosen in the browser, in the browser's order, and with
    /// fewer than two the open picture (`MacDevelopExport`). The window's filmstrip answers as it did.
    private var exportIDs: [LibraryFrame.ID] {
        MacDevelopExport.ids(current: frame.id, model: model)
    }

    @ViewBuilder private func columnPanel(width: CGFloat, room: CGFloat) -> some View {
        if navigation.surface == .develop, navigation.step == .filmAndPaper, let stockStrip {
            // The film's pill over its cards in rows, then the paper's; one row each, as the host,
            // where the column is too short for two. Decode under them: a part taller than the room
            // left (the curve) scrolls, and the strips keep their rows whichever part is shown.
            // a folded strip gives its rows to the other.
            let prefs = DevelopPanelPrefs.shared
            let rows = [3, 2].first(where: {
                StockPreviewPanel.height(rows: $0, compact: compact, filmFolded: prefs.filmRowCollapsed,
                                         paperFolded: prefs.paperRowCollapsed) <= room
            }) ?? 1
            ScrollView(.vertical) {
                StockPreviewPanel(session: session, strip: stockStrip, compact: compact, crop: nil, rows: rows,
                                  decode: decodeSection, status: nil, foldable: true)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
        } else if navigation.surface == .develop {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    panel.frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .scrollIndicators(.hidden)
        } else {
            // Edit is Adjust — no EngineRouter
            // (its Latitude card, Enlarger and Effects) and no Crop in the column (DevelopInspectorParts.swift).
            columnAdjust(width: width, room: room)
        }
    }

    /// Adjust in the column: every tile at once in a matrix, and the open tile's bar and control under
    /// it. Where the matrix would leave a tool too little room, the host's row that scrolls, the tool
    /// under it; where not even that, the host's way — the tool in the tiles' place, under its bar.
    /// The choice is the column's height alone, so opening a tool never re-lays the tiles.
    private func columnAdjust(width: CGFloat, room: CGFloat) -> some View {
        let bar: CGFloat = 56, toolRoom: CGFloat = 260
        let across = AdjustStrip.columns(in: width)
        let matrix = AdjustStrip.matrixHeight(columns: across) + 24
        let isMatrix = room - matrix - bar - 1 >= toolRoom
        let tiles = isMatrix ? matrix : AdjustStrip.tileHeight + 24
        let under = room - tiles - bar - 1
        let tilesStay = isMatrix || navigation.adjust == nil || under >= toolRoom
        return VStack(spacing: 0) {
            if tilesStay {
                AdjustStrip(session: session, columns: isMatrix ? across : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
            }
            if let tool = navigation.adjust {
                Rectangle().fill(Theme.rule).frame(height: 0.5)
                AdjustToolBar(session: session, tool: tool, state: $adjustState).frame(height: bar)
                AdjustInspector(session: session, height: min(tilesStay ? under : room - bar, 420), state: $adjustState,
                            holdsStripHeight: !tilesStay)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: keys

    @ViewBuilder private var keys: some View {
        // no frame changes and no column put away under an inline crop.
        if let pad, inlineCrop == nil {
            // the browser's rows are the page's neighbours, so ← and →
            // walk what the browser shows — the pictures the library has never opened included, made a
            // frame as a click on the row makes one.
            HiddenKeyEquivalent(title: L("Previous photo"), key: .leftArrow, enabled: macPhotoKeysFree && browserNeighbour(-1) != nil) {
                if let row = browserNeighbour(-1) { MacDevelopOpening.open(row, store: MacLibraryUI.store(model)) { switchFrame(to: $0) } }
            }
            HiddenKeyEquivalent(title: L("Next photo"), key: .rightArrow, enabled: macPhotoKeysFree && browserNeighbour(1) != nil) {
                if let row = browserNeighbour(1) { MacDevelopOpening.open(row, store: MacLibraryUI.store(model)) { switchFrame(to: $0) } }
            }
        }
    }

    private var macPhotoKeysFree: Bool {
        !MacLibraryBrowser.shared.typing && !MacLibraryBrowser.shared.modal && router.cover == nil
            && router.sheets.isEmpty && MacShellPath.split(router.path).stacked.isEmpty && inlineCrop == nil
    }
    /// The row `step` places from the open picture in the browser's rows, nil past either end.
    private func browserNeighbour(_ step: Int) -> MacImage? {
        let rows = MacLibraryUI.store(model).images
        guard let i = rows.firstIndex(where: { $0.develop?.frameID == frame.id }) else { return nil }
        let j = i + step
        return rows.indices.contains(j) ? rows[j] : nil
    }
}
