// RFC-038: V5 chrome on the existing session and photographic controls.
// Edit's band is Adjust · EngineRouter · Crop (2026-10-19): Adjust is Layer 2 as
// Litti's flow (`AdjustInspector`): a strip of tiles, and an open tile's bar in
// place of the page's own.
import SwiftUI

struct DevelopWorkspace: View {
    @Bindable var session: OpenFrameSession
    let frame: LibraryFrame
    let back: BackWay
    let opening: DevelopOpening
    var stockStrip: StockStrip? = nil
    @State var compact = false

    @Environment(AppServices.self) var model
    @Environment(AppRouter.self) var router
    @Environment(AppSettings.self) var settings
    @Environment(ExportService.self) var exporter
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var typeSize
    @State var asksReset = false
    @State var presets = false
    @State var missingPaste = false
    @State var comparing = false
    @State var original = false
    @State var split = 0.5
    @State var latitudeFolded = true
    @State var enlargerTool = EnlargerTool.colour
    /// The shelf the Enlarger's papers are narrowed to, its header's pill; All when the page opens.
    @State var enlargerPaperShelf = StockShelf.all
    /// EngineRouter's Effects tile: the chip it is showing, kept for the page session. (Film & Paper's
    /// Decode keeps its chip in the session's navigation, `DevelopPageNavigation.decodeTool`.)
    @State var effectsPage = EffectsPage.grain
    @State var cameraWhiteBalance: (temperature: Double, tint: Double)?
    @State var initialized = false
    @State var adjustState = AdjustState()
    /// The column's (`PadDevelopPage.swift`): the window's shape, the page's filmstrip and column, and the
    /// keys' focus.
    @Environment(WindowShape.self) var window: WindowShape?
    @Environment(DevelopController.self) var pad: DevelopController?
    @FocusState var keysFocused: Bool

    var navigation: DevelopPageNavigation { session.pageNavigation }
    var hasOriginal: Bool { frame.originalPicture != nil || session.developed != nil || frame.developed != nil }
    var pair: HalfFramePair? { FeatureFlags.halfFramePair ? session.pair : nil }
    var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    var body: some View {
        // The column on one canvas (`PadDevelopPage.swift`): a window resized moves the parts, it never
        // makes the page again.
        Group {
            // The window's bar and its browser are the window's (`MainWindowLayout`, the owner, 2026-10-27:
            // no page transition between 图库 and 冲洗/编辑): the page is its column, canvas and strip, and
            // it tells the bar what its half holds (`publishShellBar`). The window and the reference device keep theirs.
            if pad != nil {
                pageBody
                    .onChange(of: macBarSignature, initial: true) { _, _ in publishShellBar() }
                    .onDisappear { withdrawShellBar() }
                    // A field left (the browser's search, its own Return or the shell's click-outside):
                    // the page has the keys again, as it does when it opens (`joinWideWindow`).
                    .onChange(of: MacKeyFocus.shared.pulse) { _, _ in keysFocused = true }
            } else {
                pageBody
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < 720 } action: { compact = $0 }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            session.pageNavigation.step = opening.step
            session.pageNavigation.tool = DevelopPageNavigation.isAvailable(opening.editTool) ? opening.editTool : .darkroom
            keepEditOnAdjust()
            session.pageNavigation.adjust = opening.adjustTool
            if let state = opening.adjustState { adjustState = state }
            session.pageNavigation.darkroom = opening.darkroom
            enlargerTool = opening.enlargerTool
            session.pageNavigation.decodeTool = opening.decodeTool
            if EffectsPage.darkroom.contains(opening.effectsPage) { effectsPage = opening.effectsPage }
            session.pageNavigation.panelFolded = opening.panelFolded
            session.show(opening.surface)
            // The library's mode row opened this page as 编辑 (`MacModeSwitch`), or 冲洗: the row's mode is
            // the page's, whatever this session last kept.
            if let wanted = MacDevelopWanted.surface {
                MacDevelopWanted.surface = nil
                session.show(wanted)
            }
            comparing = opening.compare
            let decode = session.edit.decode
            if decode.whiteBalance == .asShot { cameraWhiteBalance = (decode.temperature, decode.tint) }
        }
        .onChange(of: session.frame?.edit) { _, edit in
            guard let edit, edit != session.edit else { return }
            session.acceptKeptEdit(edit)
        }
        .resetAlert(resetTitle, isPresented: $asksReset) { performReset() }
        .alert(L("Unavailable materials"), isPresented: $missingPaste) {
            Button(L("OK"), role: .cancel) {}
        }
        // A sheet is a hosting controller of its own on the Mac: it has none of the page's objects unless
        // handed them (2026-11-05: Presets ended the app, "No Observable object of type AppServices found").
        .sheet(isPresented: $presets) { PresetSheet(session: session).appEnvironment(model) }
        #if DEBUG
        // `--mac-drive`'s `presets`: the bar's Presets, as its menu item sets it.
        .onReceive(NotificationCenter.default.publisher(for: .spkDebugPresets)) { _ in presets = true }
        #endif
        .onDisappear { original = false; asksReset = false }
        .onChange(of: navigation.surface) { _, _ in
            original = false; asksReset = false
            if navigation.surface == .edit, navigation.tool.isLive, pair != nil { session.pick(.film) }
        }
        .onChange(of: navigation.tool) { _, _ in
            original = false; asksReset = false
            if navigation.tool.isLive, pair != nil { session.pick(.film) }
        }
        .onChange(of: navigation.step) { _, _ in original = false; asksReset = false }
        .onChange(of: navigation.darkroom) { _, _ in original = false }
        .onChange(of: session.layer) { _, _ in original = false; asksReset = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in original = false; comparing = false }
        .onChange(of: frame.id) { _, _ in original = false; comparing = false }
    }

    var status: DevelopStatus {
        if let status = opening.status { return status }
        if !session.status.busy, case .offline = frame.original {
            return DevelopStatus(text: L("Original not connected") + Fmt.dot + L("editing its preview"), busy: false, progress: nil)
        }
        return session.status
    }

    var navigationBand: some View {
        VStack(spacing: 0) {
            if navigation.surface == .develop {
                HStack(spacing: 0) {
                    ForEach(DevelopStep.allCases) { step in
                        choice(step.title, selected: navigation.step == step) {
                            withAnimation(motion) { session.pageNavigation.select(step) }
                        }
                        .accessibilityIdentifier("v5.step.\(step.rawValue)")
                    }
                }
                .background { Capsule().fill(Theme.card).frame(height: 30) }
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 0) {
                    ForEach(EditTool.allCases) { tool in
                        choice(tool.title, selected: navigation.tool == tool) {
                            original = false
                            withAnimation(motion) { session.pageNavigation.select(tool) }
                        }
                        .disabled(!DevelopPageNavigation.isAvailable(tool))
                        .opacity(DevelopPageNavigation.isAvailable(tool) ? 1 : Theme.disabledOpacity)
                        .accessibilityIdentifier("v5.tool.\(tool.rawValue)")
                    }
                }
                .background { Capsule().fill(Theme.card).frame(height: 30) }
                .padding(.horizontal, 16)
            }
            Rectangle().fill(Theme.rule).frame(height: 0.5).padding(.top, 8)
        }
    }

    func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.Font.ui(13, selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.onSelection : Theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(minWidth: 44)
                .frame(height: 26)
                .background { if selected { Capsule().fill(Theme.selection) } }
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder var panel: some View {
        if navigation.surface == .develop {
            switch navigation.step {
            case .filmAndPaper:
                if let stockStrip {
                    StockPreviewPanel(session: session, strip: stockStrip, compact: compact, crop: nil,
                                      decode: decodeSection, status: developStatusFoot,
                                      foldable: true)
                } else {
                    FilmPanel(session: session, pro: false, includesPaper: true, cardsOpenOn: opening.cardsOpenOn)
                }
            case .format:
                VStack(spacing: 0) {
                    if let pair { PairFramePanel(session: session, frame: frame, pair: pair) }
                    else { FramePanel(session: session, frame: frame, v5: true, wide: true) }
                    // 片边 and 日期后背 under the
                    // film's sizes, in the old rows' place, each folding (`FilmEdgeColumn`).
                    if let filmEdgeColumn { filmEdgeColumn }
                    let removed = session.binding(\.params.antihalationRemoved)
                    Toggle(isOn: removed) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(L("Remove anti-halation layer"))
                            }
                            Text(L("Experimental simulation for all stocks"))
                                .font(Theme.Font.ui(11)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .font(Theme.Font.ui(13)).padding(.horizontal, 16).padding(.vertical, 12)
                    // Grain and Halation with
                    // the other effects, here under the switch (`wideEffects`).
                    Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
                    wideEffects
                }
                // The film edge, the date back, the grain and the halation are the film's (Apply Film Emulation).
                .rowEnabled(session.edit.appliesFilm)
                .padding(.bottom, 12)
            }
        } else if navigation.tool == .crop {
            // Edit's crop cuts the finished picture, film edge and all (2026-10-20).
            Button { openPrintCrop() } label: {
                Label(L("Crop"), systemImage: "crop")
                    .font(Theme.Font.ui(15, .medium))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
            .disabled(pair != nil && pair?.pickedSide(session.layer) == nil)
        } else if navigation.tool == .darkroom, let page = navigation.darkroom {
            darkroomControls(page)
        } else {
            darkroomStrip
        }
    }

    /// Film & Paper's Decode, under the strips: its parts' resets are the page's own.
    var decodeSection: DecodeSection {
        DecodeSection(session: session, frame: frame, cameraWhiteBalance: cameraWhiteBalance, tool: $session.pageNavigation.decodeTool,
                      moved: { changesAnything($0) }, reset: { resetScopes([$0]) }, stacked: true)
    }

    /// What Film & Paper's ↺ puts back: the whole of Decode — Film Exposure, the white balance, the
    /// curve — and a Scene Placement the frame was given before the curve replaced it (2026-10-24),
    /// which nothing else on the page can take off any more. The stocks stay.
    static let decodeScopes: [PageResetScope] = [.filmExposure, .decode, .sceneCurve, .placement]

    /// Several resets as one step of the page's Undo, each the page's own (`AppServices.resetPage`).
    func resetScopes(_ scopes: [PageResetScope]) {
        let owns = session.beginHistoryTransaction()
        for scope in scopes where changesAnything(scope) { model.resetPage(scope, in: session) }
        if owns { session.endHistoryTransaction() }
    }

    // MARK: EngineRouter, arranged as Adjust (2026-10-22)
    //
    // The owner: "The way 暗房 is arranged is officially gonna be the same as that in 调整". So its
    // rows became Adjust's parts: the strip — the Latitude card over the tiles, Enlarger · Effects
    // (`DarkroomPage`; Decode moved to Film & Paper on 2026-10-24) — as tall as it is, the picture taking the rest; a tile opens its
    // controls in the strip's place, in the panel's room, and its bar takes the page's bar's place:
    // 🗑 the tile back to rest at once (its `scopes`, one step of Undo, the ↶ beside it), its name —
    // or, on the Enlarger, the papers' shelf, which took the page's name there before — and ✓ back
    // to the strip. EngineRouter tapped again with a tile open is the strip again, as Adjust is.
    //
    // **Why the Effects pills did nothing until then**: the Couplers and Scene Placement rows each
    // drew pro-control's Effects page, chips and all, bound to `.constant(.couplers)` and
    // `.constant(.placement)`. A tap set a constant: the chip pressed, and the page stayed. The
    // Effects tile's pills are bound to the page's own `effectsPage`.

    /// The strip: the Latitude card, and the three tiles under it.
    var darkroomStrip: some View {
        VStack(spacing: 0) {
            LatitudeCard(readout: session.latitude.readout, note: session.latitude.note,
                         showsPlacement: false, collapsed: $latitudeFolded)
                .frame(height: latitudeFolded ? 30 : 76)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .rowEnabled(session.edit.appliesFilm)
            darkroomTiles
                .padding(.top, 4).padding(.bottom, 12)
        }
    }

    /// Enlarger · Effects, as Adjust's tiles. They fit any window: no scroll.
    var darkroomTiles: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(DarkroomPage.allCases) { page in
                EditTile(title: page.title, symbol: page.symbol, moved: darkroomMoved(page),
                         open: navigation.darkroom == page, identifier: "v5.darkroom.\(page.rawValue)",
                         value: summary(page)) {
                    session.pageNavigation.open(page)
                }
                .rowEnabled(session.edit.appliesFilm)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A container of its own: an identifier on a bare stack is handed down to every tile, over theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("darkroom.strip")
    }

    /// Whether a tile holds anything its 🗑 would put back: its dot, and its 🗑 enabled.
    func darkroomMoved(_ page: DarkroomPage) -> Bool { page.scopes.contains { changesAnything($0) } }

    /// What VoiceOver reads after a tile's name: the rows' summaries, as they were.
    func summary(_ page: DarkroomPage) -> String {
        let p = session.edit.params
        switch page {
        case .enlarger:
            // Pre-flash is the Enlarger's own now: said here when it is on.
            let brightness = Fmt.signed(p.printBrightnessStops) + " EV"
            return p.preflashExposure == 0 ? brightness
                : brightness + Fmt.dot + String(format: L("Pre-flash %.3f"), p.preflashExposure)
        case .effects: return darkroomMoved(.effects) ? L("Edited") : ""
        }
    }

    /// The open tile's controls, in the strip's place.
    func darkroomControls(_ page: DarkroomPage) -> some View {
        detailControls(page)
            .rowEnabled(session.edit.appliesFilm)
    }

    @ViewBuilder func detailControls(_ page: DarkroomPage) -> some View {
        switch page {
        case .enlarger:
            PrintPanel(session: session, pro: true, tool: $enlargerTool, papers: stockStrip, paperShelf: enlargerPaperShelf)
        case .effects:
            EffectsPanel(session: session, frame: frame, pro: true, page: $effectsPage, placementOpen: .constant(false),
                         pages: EffectsPage.darkroom)
        }
    }

    /// The open tile's bar, in the page's bar's place (Adjust's `EditToolBar`).
    func darkroomBar(_ page: DarkroomPage) -> some View {
        EditToolBar(session: session, title: page.title, atRest: !darkroomMoved(page), identifier: "darkroom",
                    reset: { resetDarkroom(page) }, done: { session.pageNavigation.closeDarkroom() }) {
            if page == .enlarger, let strip = stockStrip, !strip.paperCards.isEmpty {
                // The papers' shelf, as Develop's Paper pill: the Enlarger's name is the
                // ENLARGER line's under the papers, so the pill takes the name's place, as
                // Tone's and Curve's menus take theirs.
                StockShelfPill(title: L("Paper"), shelves: StockShelf.paper, shelf: $enlargerPaperShelf,
                               all: strip.paperCards)
                    .accessibilityIdentifier("v5.enlarger.paper-shelf")
            } else {
                Text(page.title).font(Theme.Font.ui(15, .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// A tile's 🗑: every scope it holds, as one step of the page's Undo. Each is the page's own
    /// reset as it was (`AppServices.resetPage`: a pair's frame's print and decode are that frame's).
    func resetDarkroom(_ page: DarkroomPage) {
        let owns = session.beginHistoryTransaction()
        for scope in page.scopes where changesAnything(scope) { model.resetPage(scope, in: session) }
        if owns { session.endHistoryTransaction() }
    }

    func layerPicker(_ pair: HalfFramePair) -> some View {
        HStack(spacing: 0) {
            ForEach([HalfFramePair.Layer.left, .film, .right], id: \.self) { layer in
                choice(pair.title(layer), selected: session.layer == layer) { session.pick(layer) }
                    .disabled(navigation.surface == .edit && navigation.tool.isLive && layer != .film)
            }
        }
        .padding(.horizontal, 16)
        .background { Capsule().fill(Theme.card).frame(height: 30).padding(.horizontal, 16) }
    }

    var pieceMarks: PieceMarks? {
        guard let pair else { return nil }
        let rects = session.developed == nil && frame.developed == nil ? pair.holeRects : session.frameRects
        return PieceMarks(rects: rects, picked: session.layer) { session.pick($0) }
    }

    var resetScope: PageResetScope? {
        if navigation.surface == .develop { return navigation.step == .filmAndPaper ? .filmExposure : .format }
        switch navigation.tool {
        case .adjust: return nil
        case .crop: return pair != nil && pair?.pickedSide(session.layer) == nil ? nil : .crop
        case .darkroom:
            // An open tile's reset is its bar's 🗑 (`resetDarkroom`), and the strip has no reset of
            // the whole darkroom (RFC-039): the ↺ stands down, where a wide window's column keeps it.
            return nil
        }
    }
    /// Edit's Adjust, on its strip: the page's ↺ is the whole of Layer 2 (a
    /// tile's own 🗑 is in its bar). Not a `PageResetScope`: it is three of them.
    var adjusting: Bool { navigation.surface == .edit && navigation.tool == .adjust }
    /// A EngineRouter tile is open: its bar is in the page's bar's place, as an Adjust tile's is.
    var darkroomOpen: Bool { navigation.surface == .edit && navigation.tool == .darkroom && navigation.darkroom != nil }
    /// Edit's Adjust and Crop, and EngineRouter's strip: a panel no taller than what it shows, the picture
    /// over it as large as fits. An open EngineRouter tile keeps the panel's room: the Enlarger is taller
    /// than an reference device's panel, and scrolls in it.
    var fitsPanel: Bool {
        navigation.surface == .edit && !navigation.panelFolded
            && (navigation.tool == .adjust || navigation.tool == .crop || navigation.tool == .darkroom && navigation.darkroom == nil)
    }

    /// The action row's place: an open tile's bar — Adjust's or EngineRouter's — or the page's actions.
    @ViewBuilder var actionRow: some View {
        if adjusting, let tool = navigation.adjust {
            AdjustToolBar(session: session, tool: tool, state: $adjustState)
        } else if darkroomOpen, let page = navigation.darkroom {
            darkroomBar(page)
        } else {
            actions
        }
    }
    /// Film & Paper: the page's ↺ is the whole of Decode (`decodeScopes`), not a `PageResetScope`.
    var resettingDecode: Bool { navigation.surface == .develop && navigation.step == .filmAndPaper }
    var resetTitle: String? {
        adjusting ? L("Adjust") : resettingDecode ? L("Develop") : resetScope?.title
    }
    func performReset() {
        if adjusting { session.resetEdit() }
        else if resettingDecode { resetScopes(filmAndPaperResetScopes) }
        else if resettingWideFormat { resetScopes(Self.wideFormatScopes) }
        else if let scope = resetScope { model.resetPage(scope, in: session) }
    }

    var resetChangesAnything: Bool {
        if adjusting { return AdjustTool.allCases.contains { !$0.isAtRest(in: session.adjustments) } }
        if resettingDecode { return filmAndPaperResetScopes.contains { changesAnything($0) } }
        if resettingWideFormat { return Self.wideFormatScopes.contains { changesAnything($0) } }
        guard let scope = resetScope else { return false }
        return changesAnything(scope)
    }

    /// Whether resetting `scope` would change anything on this page's frame, or its picked layer.
    func changesAnything(_ scope: PageResetScope) -> Bool {
        // A pair's selected-layer values live outside FrameEdit.
        if scope == .decode, let pair, let side = pair.pickedSide(session.layer) ?? session.placementSide,
           let source = model.library.frame(pair[side]?.frame) {
            return source.edit.decode.whiteBalance != .asShot
        }
        if let pair, let side = pair.pickedSide(session.layer) {
            if scope == .filmExposure { return pair[side]?.exposureEV != 0 }
            if scope == .crop { return pair[side]?.placement != HalfFramePair.Placement() }
            let trim = pair.trim(on: session.layer, look: session.edit.params)
            if scope == .enlarger { return trim.brightnessStops != 0 || trim.yFilterShift != 0 || trim.mFilterShift != 0 }
            if scope == .preflash { return trim.preflashExposure != 0 }
        }
        return session.edit.resetting(scope) != session.edit
    }

    var actions: some View {
        HStack(spacing: 8) {
            resetButton
            moreMenu()
            pasteButton()
            compareButton()
            Spacer(minLength: 0)
            CapsuleButton(title: L("Export"), width: 112) { router.present(.export([frame.id])) }
        }
        .padding(.horizontal, 16)
    }

    // The action row's pieces, laid in a row.

    var resetButton: some View {
        Button { asksReset = true } label: { roundSymbol("arrow.counterclockwise") }
            .disabled(resetTitle == nil || !resetChangesAnything)
            .accessibilityLabel(L("Reset") + " " + (resetTitle ?? ""))
    }

    func moreMenu(diameter: CGFloat = Theme.Metric.roundButton) -> some View {
        Menu {
            Button(L("Undo")) { session.undo() }
                .disabled(!session.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button(L("Redo")) { session.redo() }
                .disabled(!session.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            // Reset is here, not a
            // button of its own on the Mac's picture bar.
            Button(L("Reset") + (resetTitle.map { " " + $0 } ?? "")) { asksReset = true }
                .disabled(resetTitle == nil || !resetChangesAnything)
            Divider()
            // The space the canvas shows its picture in (`CanvasGamut`, 2.2.1): a proof, never an edit.
            Picker(L("Canvas Colour Space"), selection: Binding(get: { model.settings.canvasGamut },
                                                               set: { model.settings.canvasGamut = $0 })) {
                ForEach(CanvasGamut.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Divider()
            Button(L("Copy Settings")) { router.present(.copySettings(frame.id)) }
            Button(L("Presets")) { presets = true }
            Divider()
            // The owner, on the host (2026-10-15): the Settings page was
            // reachable from the Library, and from the page
            // one edits on not at all -- the entry gate this adds.
            Button(L("Settings")) { router.show(.settings) }
        } label: { roundSymbol("ellipsis", diameter: diameter) }
            .accessibilityLabel(L("Edit actions"))
            .accessibilityIdentifier("v5.edit-actions")
    }

    func pasteButton(diameter: CGFloat = Theme.Metric.roundButton) -> some View {
        symbolButton("doc.on.clipboard", title: L("Paste Settings"), round: true, diameter: diameter) { pasteSettings() }
            .disabled(model.library.clipboard == nil)
            .accessibilityIdentifier("v5.paste")
            .accessibilityHint(model.library.clipboard?.summary ?? L("Nothing is copied yet"))
    }

    func compareButton(diameter: CGFloat = Theme.Metric.roundButton) -> some View {
        symbolButton("rectangle.lefthalf.filled", title: L("Compare"), round: true, selected: comparing, diameter: diameter) {
            original = false; comparing.toggle()
        }
        .disabled(!hasOriginal)
        .contextMenu {
            Button(original ? L("Process") : L("Original", as: "the picture")) { comparing = false; original.toggle() }
        }
    }

    /// A symbol on a disc. `diameter` is `Theme.Metric.roundButton` (44) everywhere on the host, the
    /// Duo's rail included; the Mac's picture bar asks for `Theme.Metric.barRound` (36), so the row is
    /// smaller at every interface scale (the owner, 2026-10-26). The glyph is drawn at the size the
    /// 44 pt disc draws it at, scaled with the disc.
    func roundSymbol(_ name: String, selected: Bool = false,
                     diameter: CGFloat = Theme.Metric.roundButton) -> some View {
        Disc(diameter: diameter, lit: selected ? Theme.accent : nil) {
            Image(systemName: name).font(.system(size: Disc<Image>.symbolSize(diameter)))
        }
    }

    func symbolButton(_ name: String, title: String, round: Bool = false,
                              selected: Bool = false, diameter: CGFloat = Theme.Metric.roundButton,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if round { roundSymbol(name, selected: selected, diameter: diameter) }
            else {
                Image(systemName: name).font(.system(size: 19))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func pasteSettings() {
        guard let clip = model.library.clipboard else { return }
        guard clip.missingMaterials.isEmpty else { missingPaste = true; return }
        model.pasteSettings(into: session)
    }

    /// Develop's crop cuts the picture before the film; Edit's (`finished`)
    /// the picture as it finishes. A pair's frame is placed under its hole.
    func openCrop() { openCrop(finished: false) }
    /// Film & Paper's Crop button: none on a pair's whole piece, which has no one picture to cut.
    var cropAction: (() -> Void)? { pair != nil && pair?.pickedSide(session.layer) == nil ? nil : openCrop }
    func openPrintCrop() { openCrop(finished: true) }

    func openCrop(finished: Bool) {
        if let pair {
            guard let side = pair.pickedSide(session.layer) else { return }
            router.show(.pairPlace(frame.id, side))
        } else {
            router.show(finished ? .printCrop(frame.id) : .crop(frame.id))
        }
    }

    func share() {
        if exporter.isExporting { router.present(.exporting); return }
        var recipe = settings.recipe
        recipe.destination = .share
        exporter.start([frame.id], recipe: recipe)
        router.present(.exporting)
    }
}

#if DEBUG
extension Notification.Name {
    /// `--mac-drive`'s `presets` (`MacLibraryDriver`): this page's Presets sheet, as the bar's item opens it.
    static let spkDebugPresets = Notification.Name("spk.debug.presets")
}
#endif
