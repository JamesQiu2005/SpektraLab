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
            // The pair's 44-unit band under the picture is gone on the Mac: its rows are the 图层 panel's, in the
            // column (`LayersPanel`, LAYERS-SPEC §3).
            let layers: CGFloat = 0
            let arranging = LayersStage.shared.arranging(frame.id)
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
                // The one canvas, whatever the window: never rebuilt by a resize. Built in a view of its own
                // (`OwnReads`): the edit, the develop and the status line it is handed change with every layer act and
                // job, and read in the page's body each re-made the whole page — its column too (2.4.0 A2).
                // Made again for each frame (2.4.0 A2b): the zoom and the pan, the pictures it has decoded (one
                // frame's never drawn under the next, `FramePicture`, `HDRImage`), the mask stage and its pointer
                // are a frame's, as they were when the whole page was made again.
                OwnReads { canvas(cropping: cropping, arranging: arranging) }.id(frame.id).padPart(.canvas)
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
        // ⌘Z and ⇧⌘Z are the menu bar's: it is told what they mean here (DevelopMenuCommands.swift). Told from a view of
        // its own (`OwnReads`), and without Undo's state, which greys inside every drag's step: read in the page's body,
        // each press re-made the whole page (2.4.0 A2: a brush's press 60–120 ms to its first frame on 45 MP, Debug).
        .background { OwnReads { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true).focusedSceneValue(\.padEditActions, editActions) } }
        .focusable(true)
        .focusEffectDisabled()
        .focused($keysFocused)
        .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { press in
            spaceOriginal(press.phase) ? .handled : .ignored
        }
        // the page takes this frame's crops in place (`AppRouter.show`).
        .onAppear {
            #if DEBUG && SPK_ENGINE
            TransitionMarks.mark("page.appear")
            #endif
            joinWideWindow(); unfoldInColumn(); router.inlineCropHost = frame.id
        }
        .onDisappear {
            if UndoRedoRecipient.session === session { UndoRedoRecipient.session = nil }
            leaveInlineCrop()
        }
        // Another frame on the same page (2.4.0 A2b): the keys, Undo and the crop's host are the next frame's — what a
        // page made for it did on appearing — and a crop of the last frame goes, unwritten, as it went with its page.
        .onChange(of: frame.id) { last, _ in
            if router.inlineCrop?.frameID == last { router.inlineCrop = nil }
            joinWideWindow(); unfoldInColumn(); router.inlineCropHost = frame.id
        }
        .onChange(of: navigation.panelFolded) { _, _ in unfoldInColumn() }
    }

    /// The canvas with what lies over it (`pageBody`'s, read apart).
    @ViewBuilder private func canvas(cropping: InlineCrop?, arranging: LayerPick?) -> some View {
        #if DEBUG && SPK_ENGINE
        let _ = TransitionMarks.mark("canvas.body")
        let _ = TransitionMarks.canvas(frame.id)
        #endif
        DevelopCanvas(frame: frame, edit: session.edit, showsOriginal: original,
                      comparing: comparing, split: $split, initialZoom: opening.zoom,
                      developed: session.developed, progress: status.progress, piece: pieceMarks,
                      allowsOriginalHold: true)
            // under an inline crop the crop is the picture; the canvas stays (a crop
            // left keeps its zoom), unseen and untouched.
            // 摆放 puts the canvas back to its fit: a fraction of the picture on screen is then a fraction
            // of the frame (`ArrangeOverlay`).
            .id(arranging == nil ? "canvas" : "canvas.arranging")
            .overlay {
                let aspect = CGFloat(DevelopedFrameView.shownAspect(frame: frame, edit: session.edit, model: model,
                                                                    developed: session.developed))
                if let arranging {
                    ArrangeOverlay(session: session, frame: frame, pick: arranging, aspect: aspect)
                } else if let alone = session.alone, session.double != nil, cropping == nil {
                    // One exposure alone (the panel's eye, R9).
                    LayerAloneOverlay(session: session, frame: frame, position: alone, aspect: aspect)
                }
            }
            .opacity(cropping == nil ? 1 : 0)
            .allowsHitTesting(cropping == nil)
            .accessibilityHidden(cropping != nil)
            .accessibilityAction(named: original ? L("Process") : L("Original", as: "the picture")) {
                guard hasOriginal else { return }
                comparing = false; original.toggle()
            }
    }

    /// Space: the original (PAGES.md W-X2) — held, while the bar is down; or, with Settings › General ›
    /// Keyboard's *Press to switch*, each press switching between the original and the develop. The page's
    /// own key while SwiftUI's focus is on it, and otherwise the window's Space command (`MacSpaceKey`, through
    /// `MacDevelopBar.space`), which is most of the time on the Mac: the page's `.onKeyPress` rarely sees the bar. False — not
    /// this page's — where there is no original or a crop is open.
    func spaceOriginal(_ phase: KeyPress.Phases) -> Bool {
        guard hasOriginal, inlineCrop == nil else { return false }
        switch settings.spaceOriginal {
        case .hold:
            if phase == .down { comparing = false; original = true } else if phase == .up { original = false }
        case .toggle:
            // A held bar repeats: one press is one switch.
            if phase == .down { comparing = false; original.toggle() }
        }
        return true
    }

    private var editActions: UndoRedoActions {
        // Under an inline crop ⌘Z is the crop's (the Mac's `MacFlowUndo`), never the develop's under it.
        if inlineCrop != nil { return UndoRedoActions(undo: {}, redo: {}) }
        return UndoRedoActions(undo: { session.undo() }, redo: { session.redo() })
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

    /// Another frame from the browser, the arrow keys or a variant made: this page's state goes with it.
    ///
    /// The page is kept and handed the next frame (2.4.0 A2b, `DevelopPane.switchSession`), unless something on it is
    /// held (`pageHolds`): then it is made again, as it was for every change of frame before. A number being typed
    /// is taken first, on this frame, as a click outside it takes it; 编辑历史 is this frame's and closes.
    func switchFrame(to id: LibraryFrame.ID) {
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("switch")
        #endif
        guard let pad, id != frame.id else { return }
        MacKeyFocus.commitEditing?.finish()
        if case .history(frame.id)? = router.sheets.last { router.dismissSheet() }
        var remake = pageHolds
        #if DEBUG
        // SPK_PAGE_REMAKE=1: every change of frame makes the page again, as before 2.4.0 A2b (the transitions case's
        // "before", red on the switch's bars).
        if ProcessInfo.processInfo.environment["SPK_PAGE_REMAKE"] != nil { remake = true }
        #endif
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
        // The next frame is drawn as it is, not animated to: the 图层 panel's height (`layersHeight`'s animation) and
        // the like move with a row or a layer, never with a change of picture — a page made again had none to animate.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { pad.select(id, carrying: carried, strip: macStripRows, remake: remake) }
    }

    /// Something on the page is held that lives in its views and must not go to the next frame: a control's drag (its
    /// value on the move is the view's, its writes bound to this frame's session), a tool's drag on the picture, a
    /// field with the keys (a layer's name, a number), a popover of the mask tools or 人's menu, the crop, a sheet or
    /// a cover, 摆放, the 图层 panel's question, Reset's question, Presets. Where one is, the page is made again for
    /// the next frame — what every change of frame did before 2.4.0 A2b — rather than kept.
    var pageHolds: Bool {
        let tools = MaskTools.shared, stage = LayersStage.shared
        return session.controlHeld || tools.dragging
            || MacKeyFocus.editingField != nil || MacKeyFocus.commitEditing != nil
            || tools.popover || tools.combineOpen || tools.refineOpen != nil || MaskFinding.shared.peopleOpen
            || router.inlineCrop != nil || !router.sheets.isEmpty || router.cover != nil
            || stage.arranging != nil || stage.asking != nil || stage.refused != nil || stage.renaming != nil
            || asksReset || presets || missingPaste
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
        // 摆放 is the page's crop of a pair's frame or a double's exposure: the bar wears it as it wears a crop.
        MacBarSignature(frame: frame.id, edit: navigation.surface == .edit,
                        inCrop: inlineCrop != nil || LayersStage.shared.arranging(frame.id) != nil,
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
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("bar")
        #endif
        let s = macBarSignature
        let session = session, router = router, frame = frame
        MacShellBar.shared.develop = MacDevelopBar(
            owner: ObjectIdentifier(session), frameID: frame.id,
            surface: s.edit ? .edit : .develop, inCrop: s.inCrop, columnShown: s.columnShown,
            toggleColumn: { withAnimation(motion) { pad?.columnHidden.toggle() } },
            // 裁剪 pressed while 摆放 is open finishes it, as it finishes a crop.
            crop: {
                if LayersStage.shared.arranging(frame.id) != nil { LayersStage.shared.arranging = nil } else { cropAction?() }
            },
            cropEnabled: s.cropEnabled,
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
            space: { spaceOriginal($0) },
            export: {
                // An unfilled pair or double alone: Export answers with why, and the way to fill it (R10; the
                // owner's decision 7), where it used to open a sheet whose only outcome was "not saved".
                let has: (UUID) -> Bool = { model.library.frame($0) != nil }
                if exportIDs == [frame.id], LayerRules.refusal(session.layerPiece, has: has) != nil {
                    let empty = LayerRules.rows(session.layerPiece, has: has).first { $0.isEmpty }?.pick
                    LayersStage.shared.refused = .init(frame: frame.id, pick: empty ?? .film)
                } else {
                    router.present(.export(exportIDs))
                }
            },
            open: { switchFrame(to: $0) })
    }

    /// The page goes: its half of the bar with it — unless the next page has published already.
    func withdrawShellBar() {
        if MacShellBar.shared.develop?.owner == ObjectIdentifier(session) { MacShellBar.shared.develop = nil }
    }

    // MARK: the column

    /// The column, `width` wide. Built in a view of its own (`OwnReads`): what it reads — the row picked, the mask
    /// layers, the tools — re-makes the column, never the page with its canvas and the window's browser (2.4.0 A2).
    private func column(width: CGFloat, height: CGFloat) -> some View {
        OwnReads { columnContent(width: width, height: height) }
    }

    private func columnContent(width: CGFloat, height: CGFloat) -> some View {
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("column.body")
        #endif
        // Edit has no tools band (DevelopInspectorParts.swift).
        // 图层 under the histogram, pinned, in both modes (`LayersPanel`). A picture's row picked, the column is
        // that picture's page and has no steps (the owner's decision 3); 摆放 takes the column whole.
        let piece = session.layerPiece
        let arranging = LayersStage.shared.arranging(frame.id)
        let picture = session.layerPick.isPicture
        // A mask layer's page has no band either (MASKS-SPEC §5).
        let band = showsNavigationBand && !picture && maskPage == nil && arranging == nil
        let tabs: CGFloat = !band ? 0 : typeSize.isAccessibilitySize ? 60 : 56
        let layersHeight = LayersPanel.height(piece, session: session)
        // The column has no header (the mode row is the window's bar's), no action row (the actions are
        // on the window's bar) and no status line (it is the info strip's, under the picture): the
        // histogram first, on Develop and on Edit alike (HistogramPanel.swift).
        let histogram = HistogramPanel.height()
        let room = max(height - histogram - layersHeight - tabs, 0)
        return VStack(spacing: 0) {
            // The frame's: it holds its session's histogram while it is shown (`HistogramPanel.holder`), so it is made
            // again with the next frame's session (2.4.0 A2b).
            histogramPanel.frame(height: histogram, alignment: .top).id(frame.id)
            LayersPanel(session: session, frame: frame).frame(height: layersHeight, alignment: .top)
            if band { navigationBand.frame(height: tabs) }
            Group {
                if let arranging {
                    ArrangeColumn(session: session, frame: frame, pick: arranging)
                } else {
                    columnPanel(width: width, room: room)
                }
            }
            .frame(height: room, alignment: .top).clipped()
        }
        .frame(width: width)
        .animation(.easeOut(duration: 0.18), value: layersHeight)
        .layerSheets(session: session, frame: frame)
        // 摆放 is of this picture and this mode: another frame, or Edit, closes it (Done).
        .onChange(of: frame.id) { _, _ in LayersStage.shared.arranging = nil }
        .onChange(of: navigation.surface) { _, _ in LayersStage.shared.arranging = nil }
    }

    /// The info strip's height on the Mac (`MacInfoStrip`); the filmstrip's place it stands in.
    private static var infoStripHeight: CGFloat {
        MacInfoStrip.height
    }

    /// The strip under the picture: this frame's library row (its exposure, name, rating and label), the
    /// develop's line, or how many pictures the browser has chosen.
    private var macInfoStrip: some View {
        OwnReads { macInfoStripContent }
    }

    private var macInfoStripContent: some View {
        let row = MacLibraryUI.store(model).images.first { $0.develop?.frameID == frame.id }
        let item = row.map(MacInfoStrip.Item.init) ?? MacInfoStrip.Item(name: frame.fileName)
        // 仅显示蒙版 (MASKS-SPEC §6.1): while the picked layer's mask is shown alone, the strip's line says so.
        let line = MaskTools.shared.aloneShown(session) ? (L("Show Mask Alone"), false) : (status.text, status.busy)
        return MacInfoStrip(image: item, chosen: MacLibraryBrowser.shared.selection.count, status: line)
    }

    /// What Export takes on the Mac: the frames chosen in the browser, in the browser's order, and with
    /// fewer than two the open picture (`MacDevelopExport`). The window's filmstrip answers as it did.
    private var exportIDs: [LibraryFrame.ID] {
        MacDevelopExport.ids(current: frame.id, model: model)
    }

    /// The mask layer whose page the column is, in either mode (MASKS-SPEC §5): nil with 胶片 or a picture picked.
    private var maskPage: LocalLayer? {
        guard FeatureFlags.maskLayers, case .mask = LayerRules.page(session.layerPick, piece: session.layerPiece,
                                                                   mode: navigation.surface == .edit ? .edit : .develop,
                                                                   has: { _ in true }, layers: session.maskLayers) else { return nil }
        return session.chromeMaskLayer
    }

    @ViewBuilder private func columnPanel(width: CGFloat, room: CGFloat) -> some View {
        if let layer = maskPage {
            MaskPage(session: session, layer: layer)
        } else if session.layerPick.isPicture {
            // A pair's frame or a double's exposure picked: its own page in Develop; in Edit nothing of its own,
            // the tools standing down under the line that says so (`LayerPage.swift`).
            if navigation.surface == .develop {
                ScrollView(.vertical) {
                    LayerPictureColumn(session: session, frame: frame, pick: session.layerPick)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 0) {
                    LayerStandsDown(session: session, name: LayerRules.summary(session.layerPick, in: LayerRules.rows(session.layerPiece, has: { _ in true })))
                    FoldRule()
                    columnAdjust(width: width, room: room).rowEnabled(false)
                }
            }
        } else if navigation.surface == .develop, navigation.step == .filmAndPaper, let stockStrip {
            // The film's pill over its cards in rows, then the paper's; one row each, as the host,
            // where the column is too short for two. Decode under them: a part taller than the room
            // left (the curve) scrolls, and the strips keep their rows whichever part is shown.
            // a folded strip gives its rows to the other.
            let prefs = DevelopPanelPrefs.shared
            let rows = [3, 2].first(where: {
                StockPreviewPanel.height(rows: $0, compact: compact, filmFolded: prefs.filmRowCollapsed,
                                         paperFolded: prefs.paperRowCollapsed, decodeFolded: prefs.decodeCollapsed) <= room
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

    /// Adjust in the column (2026-11-11): small pills for every tool, any number of tools open under them, one
    /// order for both that is dragged into shape, the column scrolling as one, the layout remembered
    /// (`AdjustColumn`). The column's width and room no longer decide anything: it scrolls.
    private func columnAdjust(width: CGFloat, room: CGFloat) -> some View {
        AdjustColumn(session: session, state: $adjustState)
    }

    // MARK: keys

    /// The page's keys, read apart (`OwnReads`): a tool lit, a part chosen or a row picked changes which are enabled,
    /// and read in the page's body each re-made the whole page (2.4.0 A2: ~50 ms of SwiftUI's update for a tool's click
    /// on a 45 MP frame, Debug).
    private var keys: some View {
        OwnReads { keysContent }
    }

    @ViewBuilder private var keysContent: some View {
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
            // ↑ ↓ walk the 图层 panel's rows, and stop at its ends (LAYERS-SPEC §7): with the column put away
            // there is no panel to walk, and a single frame has one row.
            let layerKeys = macPhotoKeysFree && columnShown
                && (!session.layerPiece.isSingle || (LayerRules.takesMasks(session.layerPiece) && !(session.maskLayers?.items.isEmpty ?? true)))
            HiddenKeyEquivalent(title: L("Previous Layer"), key: .upArrow, enabled: layerKeys) { stepLayer(-1) }
            HiddenKeyEquivalent(title: L("Next Layer"), key: .downArrow, enabled: layerKeys) { stepLayer(1) }
            // ⌫ removes the picked mask layer (MASKS-SPEC §8). Held against the Curve panel's Delete Point: that one is
            // registered only while a curve point is chosen on 胶片's column, which is not on screen while a mask layer's
            // page is, and this one only while a mask layer is picked; no field is being edited (`macPhotoKeysFree`
            // reads `typing`, which a row being renamed sets).
            // ⌫ also removes the chosen part first (MASKS-SPEC §8): with one chosen, that part; with none, the layer.
            HiddenKeyEquivalent(title: maskTools.chosenPart != nil ? L("Remove") : L("Delete Layer"), key: .delete,
                                enabled: macPhotoKeysFree && columnShown && maskPage != nil) {
                maskTools.delete(session)
            }
            if FeatureFlags.maskLayers, LayerRules.takesMasks(session.layerPiece) { maskKeys }
        }
        if LayersStage.shared.arranging(frame.id) != nil {
            HiddenKeyEquivalent(title: L("Done"), key: .return, enabled: !MacLibraryBrowser.shared.typing) { LayersStage.shared.arranging = nil }
        }
    }

    private var maskTools: MaskTools { .shared }

    /// The mask tools' plain keys (MASKS-SPEC §8; `MaskKey`, whose specs `mac_shortcuts_selftest` holds): enabled under
    /// `macPhotoKeysFree`'s conditions; `[` `]` `⇧[` `⇧]` only while 画笔 or 橡皮 is lit, `M` `⌥M` only with a mask layer
    /// picked, Esc only while a tool is lit or its popover open.
    @ViewBuilder private var maskKeys: some View {
        let free = macPhotoKeysFree && columnShown
        // The edit's layer: the moving one would make the whole page again at every move of a stroke, and the
        // chrome's at its press and lift (2.4.0 A1).
        let picked = free && session.maskPick.flatMap { session.maskLayers?[$0] } != nil
        let brush = free && maskTools.lit?.isBrush == true
        maskKey(.showMask, enabled: picked) { maskTools.alone = false; maskTools.held.toggle() }
        maskKey(.maskAlone, enabled: picked) { maskTools.alone.toggle() }
        maskKey(.brush, enabled: free) { maskTools.light(.brush) }
        maskKey(.eraser, enabled: free) { maskTools.light(.eraser) }
        maskKey(.smaller, enabled: brush) { maskTools.step { $0.smaller() } }
        maskKey(.larger, enabled: brush) { maskTools.step { $0.larger() } }
        maskKey(.softer, enabled: brush) { maskTools.step { $0.softer() } }
        maskKey(.harder, enabled: brush) { maskTools.step { $0.harder() } }
        maskKey(.putDown, enabled: free && (maskTools.lit != nil || maskTools.popover)) {
            if maskTools.popover { maskTools.popover = false } else { maskTools.putDown() }
        }
    }

    private func maskKey(_ key: MaskKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        MacKeyRegistration(specs: key.specs, title: key.title, enabled: enabled, action: action)
            .frame(width: 0, height: 0).accessibilityHidden(true)
    }

    /// The row `delta` from the picked one; in 摆放, between the pictures being arranged.
    private func stepLayer(_ delta: Int) {
        let rows = LayerRules.rows(session.layerPiece, layers: session.maskLayers, alone: session.alone,
                                   has: { model.library.frame($0) != nil })
        let stage = LayersStage.shared
        if stage.arranging(frame.id) != nil {
            let next = LayerRules.step(session.layerPick, by: delta, in: rows, among: LayerRules.arrangeable)
            session.pick(row: next)
            stage.arranging = .init(frame: frame.id, pick: next)
        } else {
            session.pick(row: LayerRules.step(session.layerPick, by: delta, in: rows))
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

/// A part of a large view built in a view of its own: the observed values `content` reads are this view's to follow,
/// so a change to one of them re-makes this part and not the view that holds it (an `@Observable` read is tracked
/// against the body being evaluated). What the page's column, keys and strip read changes with each row, tool and
/// layer act; the page around them — the canvas, the window's bar and browser — does not (2.4.0 A2).
struct OwnReads<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View { content() }
}
