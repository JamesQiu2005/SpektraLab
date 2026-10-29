//  ExportPage.swift — the export page: the recipe on the left, the picture it
//  will write in the middle, the worklist down the right.
//
//  It replaces a 590 pt sheet whose own header argued that the image could be
//  left out, "because the canvas behind this sheet is already showing the
//  frame at the grade being exported". RFC-018 §2.5 retires that: the app now
//  converts once, at the end, per destination, so the canvas is a proof of the
//  *working* space and nothing more — and the recipes most likely to differ
//  from it are exactly the ones a person cannot check by looking at the canvas. So the
//  centre pane is the point of this page, and it is a soft proof
//  (`Export/SoftProof.swift`) rather than a second copy of the canvas.
//
//  **The layout is `reference_layout/Export_Page/export_page.svg`** — read as
//  a document: the numbers it is drawn with come from its markup rather than
//  from a render of it, which is why they are halves of its own (its window is
//  2981.27 units wide and its artboard is at 2×, the same scale the editor's
//  tokens were measured at — three of them land on the drawing exactly). Its
//  `notes.md` remains the authority on *behaviour*, and the two are cited
//  where they disagree.
//
//  The style is the rest of the app's: `PanelSection` headers, `Well` grounds,
//  `PillMenu` pills, `ScrubSlider` and `Theme` tokens. This page's drawing has
//  tighter rows, a heavier face and its own orange, so it passes those three
//  through `SectionMetrics`, `SliderMetrics` and its own accent token rather
//  than restyling the shared controls.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportPage: View {
    @Bindable var session: Session
    /// Which mode to open in. Only the snapshot harness passes anything but
    /// the default: `--export-grid` is how the Grid half of the mode
    /// transition gets looked at, and a transition only ever exercised in one
    /// direction is the one that is broken.
    var startIn: Mode = .viewer
    @State private var store = ExportRecipeStore()

    /// Which of the two modes the centre is in (`notes.md`: "There are two
    /// modes").
    @State private var mode: Mode = .viewer
    /// The settings card folds away to the left, which is what the tab on its
    /// trailing edge in the drawing is for. Persisted like the editor's own
    /// collapse flags (`Session.leftCollapsed` and friends), so a card someone
    /// folded stays folded — and so a capture can reach the folded state
    /// without a pointer.
    @AppStorage(Session.uiKey + "exportSettingsCollapsed") private var settingsCollapsed = false
    /// Both cards' widths, and the user's. The page opens at the drawing's own
    /// and the grips move the edges from there — which is what makes the
    /// collapse tab non-fixed: it hangs off the canvas, so it follows the edge
    /// wherever the edge goes (`Controls/PanelResize.swift` says why nothing
    /// about the tab had to change).
    @State private var leftWidth = PanelWidthStore(name: "export.left", range: M.leftRange)
    @State private var rightWidth = PanelWidthStore(name: "export.right", range: M.rightRange)
    /// How many columns the Grid draws its thumbnails in — the value the bar's
    /// detented slider sets. Persisted like every other view setting, so the
    /// grid someone arranged is the grid they come back to.
    @AppStorage(Session.uiKey + "exportGridColumns") private var gridColumns = 5

    @State private var zoom: CGFloat = 1
    @State private var paneSize: CGSize = .zero
    @State private var proof: SoftProof?
    @State private var proving = false
    /// **The picture that came out of the file**, after an export has actually
    /// written one. The user's answer to what the pane shows once there is a
    /// file to show: "the render before, the file's own embedded preview
    /// after" — which is a stronger claim than the proof makes, because it is
    /// not "this is what it will look like" but "this is what it does look
    /// like".
    ///
    /// Cleared whenever a new proof is rendered, so any edit puts the render
    /// back: it describes one file that exists, and the next keystroke is
    /// about to make a different one.
    @State private var filePreview: CGImage?

    @State private var running = false
    /// The batch in flight, kept so Stop can cancel it.
    @State private var runTask: Task<Void, Never>?
    @State private var note: ResultNote?
    /// The rename dialog's draft, non-nil while it is up. A recipe is a named
    /// thing — the list is a list of names — and the old sheet's Name field
    /// went with the sheet: without this, every recipe anyone creates is called
    /// "Untitled" for good, which the drawing would not have caught because it
    /// draws the list, not the making of one.
    @State private var renameDraft: String?

    /// The drawing's own numbers, so the body reads the way the drawing does.
    private typealias M = Theme.Metric.Export
    private typealias F = Theme.Font.Export

    private static let sectionMetrics = SectionMetrics(
        headerHeight: M.headerHeight, headerToWell: M.headerToWell,
        wellToHeader: M.wellToHeader, titleFont: F.sectionTitle)

    /// Every label in the page's label column, so the column can be measured
    /// off them (`Theme.Metric.Export.labelWidth(fitting:)`). A label added to
    /// a row goes here too; `LayoutTests` checks the column holds them all.
    @MainActor static var columnLabels: [String] { [L("Folder", zh: "文件夹"), L("Subfolder", zh: "子文件夹"), L("Existing File", zh: "已有文件"), L("Format", zh: "格式"), L("File name", zh: "文件名"),
                               L("Color Space", zh: "色彩空间"), L("Quality", zh: "质量"), L("Size", zh: "尺寸"), L("Open With", zh: "打开方式"), L("Preview", zh: "预览")] }

    /// The label column: wide enough for the widest label at the scale in use.
    @MainActor static var labelColumn: CGFloat { M.labelWidth(fitting: columnLabels) }

    private static var sliderMetrics: SliderMetrics { SliderMetrics(
        labelWidth: labelColumn, valueWidth: 40, rowHeight: M.rowHeight,
        trackHeight: M.trackHeight, labelFont: F.label, valueFont: F.value) }

    enum Mode: String, CaseIterable, Identifiable {
        case grid, viewer
        var id: String { rawValue }
        /// `notes.md` names both glyphs.
        var glyph: String { self == .grid ? "square.grid.2x2" : "rectangle.grid.3x1" }
        @MainActor var help: String { self == .grid ? L("Grid", zh: "网格") : L("Viewer", zh: "查看器") }
    }

    private struct ResultNote: Identifiable {
        let id = UUID()
        var text: String
        var warning: Bool
    }

    /// The selected recipe, written straight back through the store so every
    /// edit is saved. There is no "apply" button on purpose — a recipe is a
    /// saved preference, and a preference that needs confirming is one people
    /// lose.
    private var recipe: Binding<ExportRecipe> {
        Binding(get: { store.selected ?? ExportRecipe() },
                set: { store.selected = $0 })
    }

    var body: some View {
        // Three flush columns, and the bar floats over the middle one.
        //
        // This page kept the **old** shape for two months after the editor
        // stopped using it: four rounded cards, `M.gap` between them, on a
        // visible ground. The 2026-09-17 drawing had already retired that
        // language, and so had this page's own drawing —
        // `export_page.svg` runs its settings rail and its worklist to the
        // window's edges at full height and separates everything with 1 pt
        // hairlines, exactly as the editor's does. A page on cards beside an
        // editor on rails is two apps.
        //
        // The bar moved with it. It used to be a full-width row *above* the
        // columns, which is why the rails began 31 pt down and the window had
        // no square corner; it is now the editor's arrangement — a pill on
        // the ground over the centre column only, with the rails running the
        // full height either side of it.
        HStack(spacing: 0) {
                if !settingsCollapsed {
                    settingsPanel
                        .frame(width: leftWidth.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    PanelResizeHandle(side: .trailingEdge, range: M.leftRange,
                                      width: $leftWidth.width)
                }
                // Everything right of the settings card, as one thing — because
                // the collapse tab hangs off *its* leading edge, and in Grid
                // mode that edge belongs to a different card than in Viewer.
                // The tab follows whichever is there, which is what makes it
                // non-fixed in the sense the user meant.
                rightOfSettings
                    // `stroked` only in Grid: there the pill sits on the grid
                    // card, which is the same colour as the pill. On the
                    // ground in Viewer the original drawing draws it plain,
                    // and its tab is deliberately unstroked — a border there
                    // would be inventing one.
                    .overlay(alignment: .leading) {
                        HoverEdgeTab(edge: .leading, collapsed: $settingsCollapsed,
                                     stroked: mode == .grid)
                    }
        }
        // `notes.md`: "write the transition between the modes in both
        // ways" — both branches of `rightOfSettings` carry one and the
        // animation is on the row that holds them.
        .animation(.easeOut(duration: 0.18), value: mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            mode = startIn
        }
        .task(id: proofKey) { await makeProof() }
        .task(id: recipe.wrappedValue.format) { OpenWithCatalog.refresh(for: recipe.wrappedValue.format) }
    }

    // MARK: - the worklist

    /// The picked set, in the strip's order, is the page's content.
    private var worklist: [Frame] {
        session.frames.filter { session.isPicked($0.id) }
    }

    /// `notes.md`: "Multi-select is allowed, and the export setting is applied
    /// to all the selected images." The export page's gesture keeps that set
    /// as its content: a plain click opens one picked frame, while ⌘ toggles
    /// one without moving the canvas, so the proof on screen does not jump
    /// away from what the person was looking at while they pick the rest of
    /// the batch.
    ///
    /// There is no ⇧-click, and the user's rule is the one that decides it —
    /// "single click only selects one item, only cmd + click can be used to
    /// select multiple one". It used to extend a range from an anchor here and
    /// it was removed. A range would also be the one selection gesture that
    /// changes its meaning when the sort order does, but that is a second
    /// reason, not the reason.
    ///
    /// The modifier is read off `NSEvent` rather than declared as two
    /// gestures: a plain `TapGesture` on macOS matches a ⌘-click too, so
    /// stacked variants both fire and a ⌘-click becomes a plain one as well.
    private func tap(_ frame: Frame) {
        if NSEvent.modifierFlags.contains(.command) {
            session.togglePick(frame.id)
        } else {
            session.open(frame.id)
        }
    }

    /// The frames this export will write, in the strip's order so the run is
    /// reproducible — `notes.md`: "the export setting is applied to all the
    /// selected images".
    ///
    /// `session.selectedFrames`, and **not** `session.selection`: the two are
    /// different questions — what gets exported, and what is on the canvas —
    /// and `notes.md` is explicit that picking several must not move the
    /// second one ("the viewed image stays as the one the user is previously
    /// on"). The set lives on `Session` beside the open frame rather than here
    /// because the filmstrip and the Browse grid mark the same frames; a batch
    /// kept on this page is a batch that can disagree with what the person can
    /// see. It was a local `Set<URL>` until multi-selection landed.
    ///
    /// RFC-017 §8 Q2 wants apply-to-all to take "the selection when there is
    /// one, the folder otherwise". This property is that input.
    private var batch: [URL] { session.selectedFrames }

    // MARK: - the proof

    /// What the proof depends on: which frame, which destination space, and
    /// whether the format has a colour at all. Everything else a recipe
    /// carries — the name, the folder, the existing-file policy — changes no
    /// pixel, and keying on the whole recipe would re-render the proof on
    /// every keystroke in the Name field.
    ///
    /// **The window's size is not in here and must not be.** The render is the
    /// file's own full-size pixels regardless of how much of it is on screen;
    /// the pane contributes only the display downsample chosen when that
    /// render starts. A resize that started a 24-megapixel render would be the
    /// worst kind of waste, and there used to be a budget in this key that did
    /// exactly that.
    private struct ProofKey: Hashable {
        var frame: URL?
        var space: ExportColorSpace
        var takesColour: Bool
        /// The recipe's own output size, because it is a size the *file* will
        /// have — the proof is the file's pixels now, so anything that changes
        /// how many there are changes the proof. (It is a size, unlike the
        /// next field, and it comes from the recipe rather than the window.)
        var outputSize: OutputSize
        /// Whether the centre has a pane to draw in — **not a render input but
        /// a cost input**, and the one thing here that does not change the
        /// file-sized render. In Grid mode there is no pane at all, and the
        /// render is seconds of engine time. It is a `Bool` and not `paneSize`
        /// for the reason above: a resize must not re-key this, and a resize
        /// cannot change whether a pane exists.
        var hasPane: Bool
    }

    private var proofKey: ProofKey {
        ProofKey(frame: session.selection,
                 space: recipe.wrappedValue.colorSpace,
                 takesColour: recipe.wrappedValue.format.takesColorSpace,
                 outputSize: recipe.wrappedValue.outputSize,
                 hasPane: paneSize.width > 1)
    }

    /// **The render is still full size; only what the page holds and draws
    /// shrank.** `softProofForDisplay` runs `Exporter.filePixels` at the
    /// file's own size, keeps the full-frame statistics, then downsamples the
    /// converted texture once to roughly twice the pane's longest side. The
    /// page holds only that display image and the file's real pixel size.
    ///
    /// This does **not** reverse "the proof is the file": it is still the same
    /// `Exporter.filePixels` tail, with the display downsample after the
    /// transform. Do not re-add the old `maxPixels` or canvas-tier clamps;
    /// those bounded the render, while this bounds only the page's copy.

    /// Renders the proof, keeping whatever is already on screen until the new
    /// one is ready.
    ///
    /// **Coalescing is `.task(id:)`'s**, not a queue: when the key changes
    /// SwiftUI cancels this task and starts another, so the last edit wins and
    /// the ones before it are abandoned rather than run in turn. A full-size
    /// proof is expensive enough that the difference matters — a queue would
    /// render every keystroke and show the first one last.
    private func makeProof() async {
        guard !worklist.isEmpty, session.selection != nil else { proof = nil; return }
        // Nothing to show it in. In Grid mode there is no pane at all, and the
        // proof is wanted the moment the Viewer brings one back.
        guard paneSize.width > 1 else { return }
        proving = true
        defer { proving = false }
        // The develop, if the frame has not been through one, is `softProof`'s
        // — it is the same request for the page and for the export, so it is
        // asked for on the side both of them share rather than here.
        //
        // Cancellation is the task's too: a superseded call returns nil rather
        // than a stale picture, so a keystroke that changes the key does not
        // have to be waited on and cannot land the old proof. A superseded
        // render's result is dropped rather than shown — the pane is already
        // showing the previous proof, which is a truer thing to look at than a
        // picture of a recipe the person has moved on from.
        let made = await session.softProofForDisplay(recipe: recipe.wrappedValue,
                                                     paneSize: paneSize)
        guard !Task.isCancelled else { return }
        // An edit puts the render back: `filePreview` describes one file that
        // exists, and this key changing means the next one will not be it.
        filePreview = nil
        proof = made
    }

    /// The file's second page, or nil when it has one image and no more.
    ///
    /// **By index, not by thumbnail.** `CGImageSourceCreateThumbnailAtIndex`
    /// does not find an embedded preview — measured by the writer's half of
    /// this seam — and silently returns a downscale of the full picture at the
    /// same cost, so a thumbnail call looks like it worked and shows the wrong
    /// thing.
    ///
    /// A JPEG or a PNG has one image and returns nil here, which is the whole
    /// of the "only where there is something to swap to" rule: the caller
    /// keeps the render it already had.
    /// `internal`, not private, so a test can reach it: the index is the whole
    /// of the behaviour and the obvious alternative is silently wrong.
    static func embeddedPreview(of url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 1 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 1, nil)
    }

    // MARK: - the top bar

    /// The page's own bar: the mode toggle, the zoom cluster and the count. It
    /// is the window's first row and spans it, like the editor's, so the three
    /// window buttons land on its centreline (`Windows/TrafficLights.swift`).
    ///
    /// The count pill is centred **over the filmstrip card** rather than inset
    /// from the window's edge — measured, its centre is 0.65 pt from the
    /// card's — because it labels the strip below it.
    private var topBar: some View {
        HStack(spacing: 0) {
            // `M.modeToggleLeading` is **not** used any more, and leaving it
            // in was a layout bug rather than a cosmetic one. It is 330 pt:
            // the distance from the *window's* leading edge to the mode
            // buttons, measured while the bar was a full-width row that had
            // to clear the window buttons and the settings card. The bar is a
            // pill over the centre column now, so that spacer became 330 pt
            // of minimum width demanded from the middle of the layout — which
            // the settings rail paid for. Widening the rail by 120 moved its
            // edge by 114, and by 188 moved it 168.5, because the bar would
            // not compress. `ExportPanelTests` measures exactly that.
            Spacer().frame(width: Theme.Metric.barPadding)
            modeButton(.grid)
            modeButton(.viewer).padding(.leading, M.modeSpacing)
            // The empty middle is the window's drag surface, exactly as it is
            // on the editor's bar: the titlebar is hidden.
            WindowDragHandle().frame(minWidth: 8, maxWidth: .infinity)
            // One span, two controls: the zoom cluster in Viewer mode, where
            // the drawing puts it, and the grid-size slider in Grid mode. Both
            // are exactly `zoomClusterWidth` wide, so switching modes does not
            // move the count pill beside them.
            windowCluster
            Spacer().frame(width: M.zoomToCount)
            countPill
            Spacer().frame(width: M.countTrailingInset)
        }
        .frame(height: M.topBarHeight)
        .barCard()
        // `notes.md`: "Remember to write the transition between the modes in
        // both ways." Both branches of the cluster carry one and the animation
        // is on the row that holds them, so neither direction is the one that
        // happens to animate.
        .animation(.easeOut(duration: 0.18), value: mode)
    }

    /// The bar's right-hand control. In Viewer it is the zoom cluster the
    /// drawing draws there; in Grid it is the slider the drawing's own margin
    /// asks for — "Turns to choose grid size in grid view mode", at x 2279.75
    /// of the artboard, which halves to 1139.9 pt and lands inside this span.
    ///
    /// What it sizes is the **thumbnail**, and the pane still takes the width
    /// it is given: the count of columns is what the stops stand for, and the
    /// cells grow into whatever the pane can afford. That is Finder's
    /// behaviour, and the user asked for Finder's.
    @ViewBuilder private var windowCluster: some View {
        if mode == .viewer {
            // One `HStack`, not three loose controls: a transition belongs to
            // a view, and three siblings each fading on their own is a
            // cross-fade with holes in it — the buttons would pop while the
            // pill dissolved. One container is one transition, in both
            // directions.
            HStack(spacing: 0) {
                zoomButton("plus.magnifyingglass", L("Zoom in", zh: "放大"), 1.5)
                zoomPill.padding(.horizontal, M.zoomClusterGap)
                zoomButton("minus.magnifyingglass", L("Zoom out", zh: "缩小"), 1 / 1.5)
            }
            .frame(width: M.zoomClusterWidth)
            .transition(.opacity)
        } else {
            DetentSlider(value: $gridColumns, range: M.gridColumns,
                         width: M.zoomClusterWidth,
                         help: L("Thumbnail size — \(gridColumns) columns", zh: "缩略图大小——\(gridColumns) 列"))
                .transition(.opacity)
        }
    }

    /// Both glyphs are named in `notes.md`, and the viewer's is drawn turned a
    /// quarter turn. Selection is this page's accent rather than a plate — the
    /// rule the editor's tool row follows for the same reason, and the one
    /// `notes.md` restates for the naming chips.
    private func modeButton(_ m: Mode) -> some View {
        let on = mode == m
        return Button { mode = m } label: {
            Image(systemName: m.glyph)
                .font(.system(size: M.modeGlyph, weight: .regular))
                .rotationEffect(.degrees(m == .viewer ? 90 : 0))
                .foregroundStyle(on ? Theme.exportAccent : Theme.exportChip)
                .frame(width: 24, height: M.topBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.help)
    }

    private func zoomButton(_ glyph: String, _ help: String, _ factor: CGFloat) -> some View {
        Button { zoom = (zoom * factor).clamped(to: 0.1...8) } label: {
            Image(systemName: glyph)
                .font(.system(size: M.modeGlyph, weight: .regular))
                .foregroundStyle(Theme.text.opacity(0.5))
                .frame(width: 24, height: M.topBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mode != .viewer)
        .opacity(mode == .viewer ? 1 : 0.4)
        .help(help)
    }

    /// A plain well-coloured capsule with no outline: the drawing strokes
    /// neither this pill nor the count beside it.
    private var zoomPill: some View {
        Menu {
            Button(L("Fit", zh: "适合")) { zoom = 1 }
            Divider()
            ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { f in
                Button("\(Int(f * 100)) %") { zoom = CGFloat(f) }
            }
        } label: {
            Text("\(Int((zoom * 100).rounded())) %")
                .font(F.pill)
                .foregroundStyle(Theme.text)
                .frame(width: M.pillWidth, height: M.pillHeight)
                .background(Theme.well, in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(mode != .viewer)
        .opacity(mode == .viewer ? 1 : 0.4)
    }

    private var countPill: some View {
        Text(batch.count == 1 ? L("1 image", zh: "1 张图像") : "\(batch.count) images")
            .font(F.label)
            .foregroundStyle(Theme.text)
            .frame(width: M.pillWidth + 22, height: M.pillHeight)
            .background(Theme.well, in: Capsule())
            .help(batch.count == session.frames.count
                  ? L("Every image in the session", zh: "本次会话中的全部图像")
                  : L("\(batch.count) of \(session.frames.count) selected for this export", zh: "已为本次导出选择 \(batch.count) / \(session.frames.count) 张"))
    }

    // MARK: - the left card

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            // The window buttons' row.
            //
            // Required, not decorative. `ExportWindow` hides the titlebar and
            // *places* the three buttons at `Export.topBarHeight / 2`; while
            // the page opened with a full-width bar they landed in it. Now
            // that the rails run to the top of the window, this rail owns
            // that row, and without it "Export Formula" is drawn underneath
            // the close button.
            railHeader
            Hairline()
            ScrollView {
                // A hairline **between** sections, never after the last —
                // the same rule the editor's rail follows, and for the same
                // reason: a rule with nothing under it is a border, and this
                // rail has no bottom to border. The sections used to sit
                // flush against each other inside a card, which is what made
                // five headers read as one undifferentiated column.
                VStack(spacing: 0) {
                    let sections: [(String, AnyView)] =
                        [("formula", AnyView(formulaSection)),
                         ("location", AnyView(locationSection)),
                         ("naming", AnyView(namingSection)),
                         ("format", AnyView(formatSection)),
                         ("summary", AnyView(summarySection))]
                    ForEach(Array(sections.enumerated()), id: \.element.0) { index, entry in
                        if index > 0 { Hairline() }
                        entry.1
                    }
                }
            }
            footer
        }
        .railCard()
        // The system's own alert with a text field in it — the same rule the
        // section menus follow, applied to the one thing on this page that
        // needs typing.
        .alert(L("Rename Recipe", zh: "重命名配方"), isPresented: Binding(
            get: { renameDraft != nil },
            set: { if !$0 { renameDraft = nil } })) {
            TextField(L("Name", zh: "名称"), text: Binding(get: { renameDraft ?? "" },
                                            set: { renameDraft = $0 }))
            Button(L("Cancel", zh: "取消"), role: .cancel) { renameDraft = nil }
            Button(L("Rename", zh: "重命名")) {
                let trimmed = (renameDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { recipe.wrappedValue.name = trimmed }
                renameDraft = nil
            }
        } message: {
            Text(L("The name in the recipe list.", zh: "配方列表中显示的名称。"))
        }
    }

    /// The strip at the top of the settings rail that the three window
    /// buttons are placed over. Empty on purpose — the drawing puts nothing
    /// else in it — and a drag surface, as the editor's rail header is.
    private var railHeader: some View {
        Color.clear
            .frame(height: M.topBarHeight)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle())
    }

    /// The recipe list. `notes.md` fixes the "..." as a system menu — "Do not
    /// rewrite three dot click second layer button, use system-provided one
    /// only" — which is the `Menu` `SectionHeader` already draws, so nothing
    /// here opens a popover of its own.
    private var formulaSection: some View {
        PanelSection(L("Export Formula", zh: "导出配方"), key: "exportFormula", menu: sectionMenu {
            Button(L("New Recipe", zh: "新建配方")) { store.add() }
            Button(L("Duplicate", zh: "复制")) { if let s = store.selected { store.duplicate(s) } }
                .disabled(store.selected == nil)
            Button(L("Rename…", zh: "重命名…")) { renameDraft = store.selected?.name ?? "" }
                .disabled(store.selected == nil)
            Divider()
            Button(L("Delete", zh: "删除")) { if let s = store.selected { store.remove(s) } }
                .disabled(store.recipes.count < 2)
            Divider()
            Button(L("Reveal Recipes File in Finder", zh: "在访达中显示配方文件")) {
                NSWorkspace.shared.activateFileViewerSelecting([store.url])
            }
        }, metrics: Self.sectionMetrics) {
            // The list is inset 1 pt from the well's own edge rather than by
            // `wellPadding`: the drawing's chosen row is 2 units in from the
            // well edge, not from its content box.
            Well(padding: 1, vertical: 6, inset: M.wellInset) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: M.recipeRowSpacing) {
                            ForEach(store.recipes) { r in recipeRow(r) }
                        }
                    }
                    // As tall as it needs to be, up to the drawing's height.
                    // Fixed at 144 it drew a 144 pt well around four 19.6 pt
                    // rows — two thirds of it empty, on a page whose whole
                    // complaint was that it does not look like the rest of the
                    // app. Nothing else here holds a list open past its
                    // contents; the stock lists show a fixed count because
                    // they have forty rows to scroll, and this has four.
                    .frame(height: formulaListHeight)
                    .padding(.top, 9)
                    HStack(spacing: 14) {
                        Spacer()
                        railButton("plus", L("New recipe", zh: "新建配方"), dimmed: false) { store.add() }
                        railButton("minus", L("Delete this recipe", zh: "删除此配方"), dimmed: store.recipes.count < 2) {
                            if let s = store.selected { store.remove(s) }
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
        }
    }

    /// The recipe list's height: its rows, bounded by the drawing's own 144 so
    /// a long list still scrolls rather than pushing Location off the rail.
    private var formulaListHeight: CGFloat {
        let rows = CGFloat(max(1, store.recipes.count))
        let content = rows * M.recipeRowHeight + (rows - 1) * M.recipeRowSpacing
        return min(content, M.formulaListHeight)
    }

    private func railButton(_ glyph: String, _ help: String, dimmed: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(dimmed ? Theme.text.opacity(0.4) : Theme.text)
                .frame(width: 16, height: 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dimmed)
        .help(help)
    }

    /// The chosen row is a **band**, as every other list in the app marks one.
    ///
    /// It was a 1.3 pt white outline, which is what this page's own drawing
    /// draws — and which the 2026-09-17 drawing had already retired everywhere
    /// else, in the user's own words: "selected entries has shallow, instead
    /// of framed square around it, and the text turns from white to black".
    /// The film list and the paper list both do that; this one kept the frame,
    /// so the app marked a selection two different ways depending on which
    /// page you were on. That is the mismatch with "the actual frontend" at
    /// its most literal, and the newer drawing is the one that wins.
    ///
    /// Plain views with a tap gesture rather than a `Button`, for the reason
    /// `StockRow` gives: on this release a `.plain` button still draws a
    /// rounded plate of its own inside the band.
    private func recipeRow(_ r: ExportRecipe) -> some View {
        let on = r.id == store.selected?.id
        return Text(r.name)
            .font(F.listItem)
            .foregroundStyle(on ? Theme.onSelection : Theme.Ink.secondary)
            // A recipe's name is the user's; it wraps rather than truncates.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 15)
            .padding(.trailing, 8)
            .frame(minHeight: M.recipeRowHeight)
            .background(on ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { store.selectedID = r.id }
            .help(r.name)
    }

    /// Where the files land, and — the part that was missing — **how many
    /// places that is**.
    ///
    /// The folder is chosen in the row itself rather than in the section's
    /// "...": a destination reached only through a menu on a header is a
    /// destination people do not know they can change, and "Beside the
    /// original" being the sole visible option read as the only one.
    ///
    /// The line at the foot used to print one path with its head truncated.
    /// Under `.besideOriginal` that path is the open frame's folder and the
    /// batch may be writing into a dozen others — the page stated one of them
    /// as if it were the answer. It now counts them, and the button beside it
    /// opens the one it can show.
    private var locationSection: some View {
        PanelSection(L("Location", zh: "位置"), key: "exportLocation", menu: sectionMenu {
            Button(L("Choose Folder…", zh: "选择文件夹…")) { chooseFolder() }
            Button(L("Use the Frame's Own Folder", zh: "使用原图所在文件夹")) { recipe.wrappedValue.folder = .besideOriginal }
            Divider()
            Button(L("Clear Subfolder", zh: "清除子文件夹")) { recipe.wrappedValue.subfolder = "" }
            Button(L("Reveal in Finder", zh: "在访达中显示")) { reveal(destinationFolders.first) }
                .disabled(destinationFolders.isEmpty)
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical, inset: M.wellInset, fill: false) {
                VStack(spacing: M.rowSpacing) {
                    HStack(spacing: 0) {  // the label column carries the gap
                        Text(L("Folder", zh: "文件夹")).font(F.label).foregroundStyle(Theme.Ink.secondary)
                            .fixedSize().frame(minWidth: ExportPage.labelColumn, alignment: .leading)
                        PillField(title: folderLabel(recipe.wrappedValue.folder), font: F.label,
                                  help: folderHelp) {
                            Button(L("Beside the original", zh: "原图旁")) {
                                recipe.wrappedValue.folder = .besideOriginal
                            }
                            if case .fixed(let p) = recipe.wrappedValue.folder {
                                Button((p as NSString).abbreviatingWithTildeInPath) {}
                                    .disabled(true)
                            }
                            Divider()
                            Button(L("Choose Folder…", zh: "选择文件夹…")) { chooseFolder() }
                        }
                    }
                    .frame(height: M.rowHeight)
                    row(L("Subfolder", zh: "子文件夹")) {
                        TextField("none", text: recipe.subfolder)
                            .textFieldStyle(.plain)
                            .font(F.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, 8)
                            .frame(height: M.rowHeight)
                            .background(Theme.pill, in: Capsule())
                            .onSubmit { store.save() }
                    }
                    PillMenu(label: L("Existing File", zh: "已有文件"), options: ExistingFilePolicy.allCases,
                             title: { [names = existingNames] in names[$0] ?? $0.label }, selection: recipe.existing,
                             labelWidth: ExportPage.labelColumn, font: F.label)
                    destinationLine
                }
            }
        }
    }

    /// The resolved destination, and the Finder button for it.
    private var destinationLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(destinationSummary)
                .font(F.value).foregroundStyle(Theme.Ink.tertiary)
                // Every character of it: it wraps as far as it has to.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(destinationHelp)
            Button(L("Reveal", zh: "显示")) { reveal(destinationFolders.first) }
                .buttonStyle(.plain)
                .font(F.value).foregroundStyle(Theme.exportAccent)
                .help(destinationFolders.count > 1
                      ? L("Open the first of these folders. The rest are beside their own frames.", zh: "打开其中第一个文件夹。其余文件夹位于各自原图旁。")
                      : L("Open this folder in the Finder. A folder that does not exist yet opens "
                        + "its nearest parent — the export creates the rest.",
                        zh: "在访达中打开此文件夹。尚不存在的文件夹会打开其最近的上级文件夹——其余部分由导出创建。"))
                .rowEnabled(!destinationFolders.isEmpty)
        }
    }

    /// Every distinct folder this recipe would write into for the current
    /// selection. One under a fixed folder; under `.besideOriginal`, as many
    /// as the batch has source folders.
    private var destinationFolders: [URL] {
        let r = recipe.wrappedValue
        let sources = batch.isEmpty ? [session.selection].compactMap { $0 } : batch
        guard !sources.isEmpty else { return [URL(fileURLWithPath: writePath)] }
        var seen: [URL] = []
        for s in sources where !seen.contains(r.directory(for: s)) {
            seen.append(r.directory(for: s))
        }
        return seen
    }

    private var destinationSummary: String {
        let folders = destinationFolders
        guard let first = folders.first else { return writePath }
        let path = (first.path as NSString).abbreviatingWithTildeInPath
        guard folders.count > 1 else { return path }
        return "\(folders.count) folders — one beside each original, starting \(path)"
    }

    private var destinationHelp: String {
        let folders = destinationFolders
        guard folders.count > 1 else { return folders.first?.path ?? writePath }
        let shown = folders.prefix(8).map(\.path)
        let rest = folders.count - shown.count
        return ([L("Beside the original writes into each frame's own folder:", zh: "“原图旁”会写入每张图像各自的文件夹：")] + shown
                + (rest > 0 ? [L("…and \(rest) more", zh: "……以及另外 \(rest) 个")] : [])).joined(separator: "\n")
    }

    private var folderHelp: String {
        switch recipe.wrappedValue.folder {
        case .besideOriginal:
            L("Each frame's own folder. A batch drawn from several folders therefore writes "
            + "into several — the line below counts them.",
              zh: "每张图像各自的文件夹。因此来自多个文件夹的一批图像会写入多个文件夹——下方一行列出了数量。")
        case .fixed:
            L("One folder for every frame in the batch.", zh: "本批所有图像写入同一个文件夹。")
        }
    }

    /// Open a folder in the Finder, walking up to the nearest one that exists:
    /// the subfolder is created by the export and not before, so the exact
    /// path is usually not there yet and `selectFile` on it would do nothing
    /// at all rather than say why.
    private func reveal(_ url: URL?) {
        guard var u = url else { return }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        while !(fm.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue) {
            let parent = u.deletingLastPathComponent()
            if parent.path == u.path { return }
            u = parent
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: u.path)
    }

    /// `notes.md`: "Four Naming options … (at least one must be selected),
    /// selection is marked with Orange highlight `#f08724`, and the actual
    /// order can be altered by user dragging". All four are always drawn, in
    /// the rule's own order; the ones switched on take the accent and the rest
    /// the grey plate the drawing gives every chip, and dragging one onto
    /// another reorders the row.
    private var namingSection: some View {
        PanelSection(L("Naming", zh: "命名"), key: "exportNaming", menu: sectionMenu {
            Button(L("Original Name Only", zh: "仅原文件名")) {
                var n = recipe.wrappedValue.naming
                for t in n.chips where n.isOn(t) && t != .originalName { n.toggle(t) }
                if !n.isOn(.originalName) { n.toggle(.originalName) }
                recipe.wrappedValue.naming = n
            }
            Button(L("Select All", zh: "全选")) {
                var n = recipe.wrappedValue.naming
                for t in n.chips where !n.isOn(t) { n.toggle(t) }
                recipe.wrappedValue.naming = n
            }
            Divider()
            Button(L("Reset the Order", zh: "恢复默认顺序")) {
                var n = recipe.wrappedValue.naming
                n.resetOrder()
                recipe.wrappedValue.naming = n
            }
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical, inset: M.wellInset, fill: false) {
                VStack(alignment: .leading, spacing: M.rowSpacing) {
                    row(L("Format", zh: "格式")) { tokenRow }
                    resolvedNameRow
                }
            }
        }
    }

    /// The filename this recipe writes, **whole**.
    ///
    /// It was one line, `truncationMode(.middle)`, at the width of a 313 pt
    /// card — so the moment more than two tokens were on, the middle of the
    /// name was replaced by an ellipsis. The middle is where the tokens are.
    /// A naming control whose read-out hides the part you are editing is a
    /// control you verify by exporting, which is the thing the read-out exists
    /// to avoid: "the current truncated sample hides the exact information
    /// users need to check".
    ///
    /// So it wraps instead of truncating, it is selectable so the exact string
    /// can be copied and compared, and it is drawn in the value face because
    /// it is the answer rather than the question. It is resolved against the
    /// open frame whenever there is one (`nameContext`) — the rest of a batch
    /// differs only where the original-name token is.
    private var resolvedNameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(L("File name", zh: "文件名")).font(F.label).foregroundStyle(Theme.Ink.secondary)
                .fixedSize().frame(minWidth: ExportPage.labelColumn, alignment: .leading)
            Text(sampleName)
                .font(F.value).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(session.selection == nil
              ? L("An example — no frame is open, so this is the model frame from the recipe file.", zh: "示例——当前没有打开图像，因此显示的是配方文件中的示例图像。")
              : L("The name this recipe gives the open frame. Every other frame in the batch "
                + "differs only where the original name is.",
                  zh: "此配方为当前图像生成的文件名。本批其他图像只有原文件名部分不同。"))
    }

    private var tokenRow: some View {
        // Wraps (2026-09-28): the chips' words are in full now, and four of
        // them are wider than the row at a large interface scale.
        FlowLayout(spacing: M.chipSpacing, lineSpacing: 3) {
            ForEach(recipe.wrappedValue.naming.chips) { t in tokenChip(t) }
        }
    }

    private func tokenChip(_ t: NameToken) -> some View {
        let on = recipe.wrappedValue.naming.isOn(t)
        let last = recipe.wrappedValue.naming.tokens.count == 1
        return Text(tokenName(t))
            .font(F.chip)
            .foregroundStyle(on ? Theme.card : Theme.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .frame(height: M.chipHeight)
            .background(on ? Theme.exportAccent : Theme.exportChip, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                var n = recipe.wrappedValue.naming
                n.toggle(t)
                recipe.wrappedValue.naming = n
            }
            // Only the last one on refuses to go off (`NamingRule.toggle`), so
            // the chip says so rather than looking broken.
            .help(on && last ? L("A filename needs at least one part", zh: "文件名至少需要一个部分")
                  : (on ? L("Remove \(t.helpName) from the filename", zh: "从文件名中移除\(tokenName(t))")
                      : L("Add \(t.helpName) to the filename", zh: "将\(tokenName(t))加入文件名")))
            .draggable(t.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let moving = NameToken(rawValue: raw) else { return false }
                var n = recipe.wrappedValue.naming
                n.move(moving, before: t)
                recipe.wrappedValue.naming = n
                return true
            }
    }

    /// **No section menu.** It carried two items, and both were a second way
    /// to do something the well already does: "Set to Original Size" is now
    /// the Size row's own first choice, and Open With had a row of its own
    /// three lines below it. The user's note — "there are two repeated paths
    /// to show open with, keep the explicit one" — is the general rule as much
    /// as the particular fix: a "..." that only repeats the panel under it
    /// teaches people to open it looking for something that is not there.
    private var formatSection: some View {
        PanelSection(L("Format and Size", zh: "格式与尺寸"), key: "exportFormat", metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical, inset: M.wellInset, fill: false) {
                VStack(spacing: M.rowSpacing) {
                    HStack(spacing: 0) {  // the label column carries the gap
                        Text(L("Format", zh: "格式")).font(F.label).foregroundStyle(Theme.Ink.secondary)
                            .fixedSize().frame(minWidth: ExportPage.labelColumn, alignment: .leading)
                        PillField(title: formatName(recipe.wrappedValue.format), font: F.label) {
                            ForEach(ExportFormat.allCases) { f in
                                Button(formatName(f)) { recipe.wrappedValue.format = f }
                            }
                        }
                        // Its natural width, so the format name beside it keeps the
                        // rest of the row. Sharing it evenly truncated "DI
                        // package" to "DI pack…" to make room for a pill that
                        // says "16 bit" and cannot be changed.
                        depthPill.fixedSize().padding(.leading, 12)
                    }
                    .frame(height: M.rowHeight)
                    if recipe.wrappedValue.format == .di { diNote }
                    if recipe.wrappedValue.format.takesColorSpace {
                        // The name is data, not a fixed label: an installed
                        // profile can be called anything, and the narrowest
                        // card truncates the long ones. The tooltip carries
                        // the whole of it, so a truncated name costs a hover
                        // rather than the information.
                        PillMenu(label: L("Color Space", zh: "色彩空间"), options: ColorSpaceCatalog.all.map(\.space),
                                 title: { [unknown = L("Unknown profile", zh: "未知描述文件")] in ColorSpaceCatalog.name(for: $0) ?? unknown },
                                 selection: recipe.colorSpace,
                                 labelWidth: ExportPage.labelColumn, font: F.label)
                            .help(ColorSpaceCatalog.name(for: recipe.wrappedValue.colorSpace)
                                  ?? L("This profile is not on this machine", zh: "本机没有此描述文件"))
                    }
                    if recipe.wrappedValue.format.takesQuality {
                        ScrubSlider(label: L("Quality", zh: "质量"), sublabel: nil,
                                    value: recipe.quality, range: 0.3...1, snap: 0.01,
                                    format: { String(format: "%.0f", $0 * 100) },
                                    metrics: Self.sliderMetrics,
                                    onCommit: { store.save() })
                    }
                    if recipe.wrappedValue.format.carriesPreviewPage { previewRow }
                    sizeRows
                    openWithRow
                }
            }
        }
    }

    /// What the Digital Intermediate **is**, on the page, because nothing else
    /// on it says (RFC-028). The file is Cineon log, not a picture, and the
    /// last line is the next step: it is an input to a grading system.
    private var diNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("The frame's Digital Intermediate, whatever paper is chosen: the negative with its orange mask removed, as 16-bit Cineon log in ProPhoto primaries, untagged.",
                   zh: "这张照片的数字中间片，与所选相纸无关：去除橙色色罩的负片，以 ProPhoto 原色的 16 位 Cineon 对数保存，不嵌入色彩配置。"))
            Text(L("Next: open it in Resolve, Nuke or Photoshop with one of the two view LUTs beside it (to ProPhoto RGB, to Rec.709) — the view the canvas shows.",
                   zh: "下一步：在 Resolve、Nuke 或 Photoshop 中打开，并套用旁边两个视图 LUT 之一（转 ProPhoto RGB、转 Rec.709），即画布上看到的样子。"))
        }
        .font(F.value).foregroundStyle(Theme.Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(L("Cineon: white 685, black 95 (the film base), 0.002 density per code. The file's second page is the DI view, so it has a picture for whoever opens it. A slide film has no Digital Intermediate.",
                zh: "Cineon：白点 685，黑点 95（片基），每码值 0.002 密度。文件第二页是数字中间片视图，打开即可看到画面。正片没有数字中间片。"))
    }

    /// The bit depth is not a free choice: `ExportFormat` *is* the format and
    /// the depth together, so this pill switches between the two containers
    /// that carry the asked-for depth, and says why it is inert for JPEG and
    /// the DI package rather than pretending to move.
    private var depthPill: some View {
        let format = recipe.wrappedValue.format
        return PillField(title: L("\(format.bitDepth) bit", zh: "\(format.bitDepth) 位"),
                         dimmed: !format.depthIsChoosable,
                         font: F.label,
                         help: format.depthIsChoosable
                         ? L("Bit depth. 16-bit switches to TIFF, 8-bit to PNG.", zh: "位深。16 位切换为 TIFF，8 位切换为 PNG。")
                         : L("\(format.shortLabel) has one depth — it is part of the format.", zh: "\(formatName(format)) 只有一种位深——它是格式的一部分。")) {
            ForEach([8, 16], id: \.self) { depth in
                Button(L("\(depth) bit", zh: "\(depth) 位")) {
                    if let f = ExportFormat.withDepth(depth, like: format) { recipe.wrappedValue.format = f }
                }
            }
        }
    }

    /// Write a preview into the TIFF. Off by default, TIFF only, and a row
    /// that exists in no drawing — the user's call of 2026-09-14: "every TIFF,
    /// but opt-in per recipe".
    ///
    /// The checkbox is the app's own `CheckBox`; the row is this page's,
    /// because `ToggleRow` is drawn at the editor's size and font and this
    /// page's rows are tighter. The cost is in the tooltip rather than on the
    /// page: it is a tenth of the file, which is worth knowing before ticking
    /// it and not worth a sentence in front of someone who has not.
    private var previewRow: some View {
        row(L("Preview", zh: "预览")) {
            CheckBox(isOn: recipe.embedsPreview)
                .help(L("Writes a preview image into the TIFF, about a tenth larger. "
                      + "Off unless a recipe asks for it.",
                      zh: "在 TIFF 中写入一张预览图，文件约增大十分之一。除非配方要求，否则关闭。"))
        }
    }

    /// Size: **what kind of size**, then the number it needs, then the pixels
    /// that fall out of it.
    ///
    /// It was two fields, `width × height`, and both of its problems came from
    /// that. The first is the bug: each field wrote its own axis and left the
    /// other alone, so typing a width silently changed the shape of the
    /// picture and the resample stretched it. The second is that a width means
    /// nothing to a batch — one recipe runs over every selected frame
    /// (`notes.md`), and a selection of portraits and landscapes has no common
    /// width, only a common long edge.
    ///
    /// So the row leads with the choice and the number is subordinate to it,
    /// and the line under it states the result in pixels rather than leaving
    /// it to be inferred: a size control whose consequence you have to work
    /// out is a size control you check after the export instead of before.
    private var sizeRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {  // the label column carries the gap
                Text(L("Size", zh: "尺寸")).font(F.label).foregroundStyle(Theme.Ink.secondary)
                    .fixedSize().frame(minWidth: ExportPage.labelColumn, alignment: .leading)
                PillField(title: sizeModeLabel, font: F.label,
                          help: L("Original keeps each frame's own pixels. "
                          + "Long edge resamples every frame so its longer side is the "
                          + "number you set, whichever way round the frame is.",
                          zh: "“原始”保留每张图像自身的像素。“长边”会重新采样每张图像，使其较长的一边等于设定值，无论横竖。")) {
                    Button(L("Original Size", zh: "原始尺寸")) { recipe.wrappedValue.outputSize = .original }
                    Button(L("Resize: Long Edge", zh: "调整尺寸：长边")) {
                        recipe.wrappedValue.outputSize = OutputSize.clamped(currentLongEdge)
                    }
                }
                if recipe.wrappedValue.outputSize.edge != nil { longEdgeField.padding(.leading, 6) }
            }
            .frame(height: M.rowHeight)
            Text(resultingSizeLine)
                .font(F.value).foregroundStyle(Theme.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, ExportPage.labelColumn)
                .help(resultingSizeHelp)
        }
    }

    /// The frame's own long edge, which is what "Resize" starts at — switching
    /// the mode must not itself resample anything. The number is there to be
    /// changed, not to be discovered afterwards.
    private var currentLongEdge: Int {
        let p = nameContext.pixelSize
        return max(1, Int(max(p.width, p.height).rounded()))
    }

    private var sizeModeLabel: String {
        recipe.wrappedValue.outputSize.isOriginal ? L("Original", zh: "原始") : L("Long Edge", zh: "长边")
    }

    /// The largest number the field takes. For one frame that is the frame's
    /// own long edge — there is no super-resolution path, so anything above
    /// it would be a promise the export does not keep. A batch can hold
    /// frames bigger than this one, so it keeps the global bound and
    /// `OutputSize.pixels(for:)` stops each frame at its own size.
    private var longEdgeCeiling: Int {
        batch.count > 1 ? OutputSize.bounds.upperBound
                        : max(OutputSize.bounds.lowerBound, currentLongEdge)
    }

    /// One number, committed on Return or on leaving the field, clamped to
    /// `OutputSize.bounds` and to `longEdgeCeiling` rather than accepted and
    /// quietly not honoured.
    private var longEdgeField: some View {
        TextField("", value: Binding(
            get: { recipe.wrappedValue.outputSize.edge ?? currentLongEdge },
            set: { recipe.wrappedValue.outputSize = OutputSize.clamped(min($0, longEdgeCeiling)) }),
                  format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(F.label).foregroundStyle(Theme.text)
            .frame(width: 62, height: M.rowHeight)
            .background(Theme.pill, in: Capsule())
            .onSubmit { store.save() }
            .help(L("Pixels on the longer side, \(OutputSize.bounds.lowerBound)–"
                  + "\(longEdgeCeiling). Frames are never enlarged.",
                  zh: "较长一边的像素数，\(OutputSize.bounds.lowerBound)–\(longEdgeCeiling)。图像永远不会被放大。"))
    }

    /// The pixels this recipe writes **for the frame on the canvas** — and, in
    /// a batch, the fact that the others are their own shape.
    ///
    /// Said about one named frame rather than about "the export", because
    /// under Original a batch has as many answers as it has frames and under a
    /// long edge it still has one answer per aspect ratio. Naming which frame
    /// it is is the difference between a read-out and a claim.
    private var resultingSizeLine: String {
        let source = nameContext.pixelSize
        let out = recipe.wrappedValue.outputSize.pixels(for: source) ?? source
        let px = "\(Int(out.width)) × \(Int(out.height)) px"
        guard batch.count > 1 else { return px }
        let others = batch.count - 1
        return recipe.wrappedValue.outputSize.isOriginal
            ? "\(px) for this frame · \(others) more at their own sizes"
            : "\(px) for this frame · \(others) more, each keeping its own shape, none enlarged"
    }

    private var resultingSizeHelp: String {
        recipe.wrappedValue.outputSize.isOriginal
            ? L("Every frame is written at its own pixels, after the crop and the straighten.", zh: "每张图像按裁剪和拉直后的原始像素写出。")
            : L("Every frame is resampled so its longer side is "
              + "\(recipe.wrappedValue.outputSize.edge ?? currentLongEdge) px. "
              + "A portrait and a landscape in the same batch therefore come out the same "
              + "size on their long side and keep their own shape. A frame already smaller "
              + "than that is written at its own pixels — nothing is ever enlarged.",
                zh: "每张图像都会重新采样，使较长一边为 \(recipe.wrappedValue.outputSize.edge ?? currentLongEdge) px。"
                  + "因此同一批中的竖幅和横幅长边尺寸相同，并保持各自的比例。本已小于此尺寸的图像按原始像素写出——永远不会放大。")
    }

    /// `notes.md`: "Open with allows the user to select the default open_app."
    ///
    /// **The only way in.** It used to be reachable from here, from the Size
    /// row's "..." and from the section's — three doors onto one pill, two of
    /// them invisible until opened. This is the explicit one and the other two
    /// are gone.
    private var openWithRow: some View {
        HStack(spacing: 0) {  // the label column carries the gap
            Text(L("Open With", zh: "打开方式")).font(F.label).foregroundStyle(Theme.Ink.secondary)
                .fixedSize().frame(minWidth: ExportPage.labelColumn, alignment: .leading)
            PillField(title: recipe.wrappedValue.openWith?.name ?? L("None", zh: "无"), font: F.label,
                      help: L("Hand the finished files to this application when the export ends.", zh: "导出结束后，用此应用打开生成的文件。")) {
                openWithItems
            }
        }
        .frame(height: M.rowHeight)
    }

    @ViewBuilder private var openWithItems: some View {
        Button(L("None", zh: "无")) { recipe.wrappedValue.openWith = nil }
        if !OpenWithCatalog.apps.isEmpty { Divider() }
        ForEach(OpenWithCatalog.apps, id: \.path) { app in
            Button(app.name) { recipe.wrappedValue.openWith = app }
        }
    }

    private var summarySection: some View {
        // **Open by default.** It was shut, which put the one view that
        // states the whole recipe in one place behind a click, and left the
        // rail's bottom third empty to do it. Everything else on this page
        // is a control; this is the read-back, and a read-back nobody opens
        // is a read-back that is not checked.
        PanelSection(L("Summary", zh: "摘要"), key: "exportSummary", menu: sectionMenu {
            Button(L("Copy Summary", zh: "拷贝摘要")) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summaryLines.joined(separator: "\n"), forType: .string)
            }
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical, inset: M.wellInset, fill: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(F.value).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - the footer

    /// The export affordance, in the card's lower third — which the drawing
    /// leaves empty, because it draws no way to start an export anywhere in
    /// it. The user's decision put the button here, with the progress and the
    /// result beside it: a page that cannot export is not a page, so this is
    /// part of the page rather than an addition to it.
    private var footer: some View {
        VStack(spacing: 6) {
            if let problem = store.problem { message(problem, warning: true) }
            if let note { message(note.text, warning: note.warning) }
            HStack(spacing: 8) {
                if running, let p = session.exportProgress {
                    ProgressView(value: p).controlSize(.small).frame(width: 70)
                }
                Text(running ? L("Exporting…", zh: "正在导出…") : exportButtonTitle)
                    .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                Spacer()
                if running {
                    // Cancels between frames: the frame being written is
                    // finished (or dropped whole), never cut off mid-file.
                    Button(L("Stop", zh: "停止")) { runTask?.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(running ? L("Exporting…", zh: "正在导出…") : L("Export", zh: "导出")) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || batch.isEmpty || store.selected == nil)
            }
        }
        .padding(.horizontal, M.wellPadding + 4)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.well).frame(height: 1) }
    }

    private var exportButtonTitle: String {
        switch batch.count {
        case 0: L("No images selected", zh: "未选择图像")
        case 1: L("1 image", zh: "1 张图像")
        default: L("\(batch.count) images", zh: "\(batch.count) 张图像")
        }
    }

    private func message(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(warning ? Theme.exportAccent : Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - the centre

    /// The proof, on the ground — Viewer mode's centre pane. Grid mode does not
    /// put cells here at all: the grid card takes this space and the filmstrip
    /// card's together, which is the correction the second drawing makes.
    private var centre: some View {
        viewerPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
    }

    /// The bar's reserved strip: ground, with the pill floating on it.
    ///
    /// The strip is *reserved* rather than overlaid, which is the editor's
    /// arrangement and is there for the same reason — it is the only one in
    /// which a picture fitted to the pane is never partly under a toolbar.
    private var barStrip: some View {
        topBar
            .padding(.horizontal, Theme.Metric.barInset)
            .padding(.top, Theme.Metric.barTop)
            .padding(.bottom, Theme.Metric.barTop)
            .frame(maxWidth: .infinity)
            .background(Theme.ground)
    }

    /// Viewer's middle column: the bar's strip, then the proof.
    private var centreWithBar: some View {
        VStack(spacing: 0) {
            barStrip
            centre
        }
    }

    /// What sits to the right of the settings card. In Viewer it is the proof
    /// on the ground with the filmstrip card beside it; in Grid the drawing
    /// makes the centre pane and the filmstrip **one card** — x 634.64 width
    /// 2350.54 against a window 2981.27 wide, so it starts one gap right of
    /// the settings card and ends at the window's edge — and the grid lives
    /// inside that.
    ///
    /// **The gap is 6 pt, not the drawing's 3.9.** The drawing measures 7.81
    /// units between the two cards, which is 3.9 pt — but the resize handle
    /// has to live between them in both modes or the settings card cannot be
    /// dragged in Grid, and the handle is `PanelResizeHandle.hitWidth`, 6 pt.
    /// Adding a spacer to make up the drawing's number would put 9.9 pt there
    /// and separate the two cards further than anything draws them. So the
    /// handle *is* the gap, and the 2.1 pt between 6 and 3.9 is what the
    /// control costs. `Theme.Metric.Export.gridGap` is not used for it.
    ///
    /// A `ZStack` rather than a bare `@ViewBuilder` switch: a transition keeps
    /// both branches alive while it runs, and a modifier applied to the
    /// conditional is applied to *each* of them — which meant two hover bands
    /// and two collapse tabs for the length of every mode change. One
    /// container, one overlay, and only its contents swap.
    private var rightOfSettings: some View {
        ZStack {
            switch mode {
            case .viewer:
                HStack(spacing: 0) {
                    centreWithBar
                    PanelResizeHandle(side: .leadingEdge, range: M.rightRange,
                                      width: $rightWidth.width)
                    stripPanel
                        .frame(width: rightWidth.width)
                }
                .transition(.opacity)
            case .grid:
                VStack(spacing: 0) {
                    barStrip
                    gridCard
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What is on the pane: the file's own picture once one has been written
    /// and it carries one, the render otherwise. **Nothing on this page asks
    /// which**, and there is no caption, badge or border that says so — the
    /// whole point is that after an export the pane is not a prediction, and a
    /// label announcing the difference would turn it back into one.
    private var displayImage: CGImage? { filePreview ?? proof?.displayImage }

    private var viewerPane: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    if let shown = displayImage {
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                    } else if proving {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Rendering the preview…", zh: "正在渲染预览…"))
                                .font(Theme.Font.label).foregroundStyle(Theme.Ink.tertiary)
                        }
                    } else {
                        Text(worklist.isEmpty
                             ? L("Nothing is selected. ⌘-click images in the filmstrip to add them.", zh: "未选择任何图像。在胶片条中按住 ⌘ 点按图像以添加。")
                             : session.selection == nil
                               ? L("No frame is open. Choose one from the strip.", zh: "没有打开的图像。请从胶片条中选择一张。")
                               : L("Nothing to prove for this recipe.", zh: "此配方没有可预览的内容。"))
                            .font(Theme.Font.label).foregroundStyle(Theme.dim)
                    }
                }
                .frame(width: max(geo.size.width, fitted.width * zoom),
                       height: max(geo.size.height, fitted.height * zoom))
                .overlay(alignment: .bottom) { proofCaption }
            }
            .onAppear { paneSize = geo.size }
            .onChange(of: geo.size) { _, s in paneSize = s }
        }
        .transition(.opacity)
    }

    /// The proof's size on screen at 100 %: the picture fitted into the pane
    /// with the page's own air around it.
    private var fitted: CGSize {
        guard let shown = displayImage else { return CGSize(width: 320, height: 213) }
        let w = CGFloat(shown.width), h = CGFloat(shown.height)
        guard w > 0, h > 0, paneSize.width > 1 else { return CGSize(width: 320, height: 213) }
        let avail = CGSize(width: max(1, paneSize.width - M.proofInset * 2),
                           height: max(1, paneSize.height - M.proofInset * 2 - 44))
        let s = min(avail.width / w, avail.height / h, 1)
        return CGSize(width: (w * s).rounded(), height: (h * s).rounded())
    }

    /// RFC-018 §6's three statements in one place: which space the proof is in
    /// and that the canvas is in another, what the destination could not hold,
    /// and whether this is a proof at all. The middle one is proportional on
    /// purpose — "a saturated frame into sRGB is worth a word, a frame that
    /// fits is worth silence" — so it is absent when the frame fits.
    ///
    /// `isPlaceholder` is false now that the output transform has landed, and
    /// the branch stays because the API keeps the field: it is what a future
    /// approximation — a lower-resolution proof, a cached one — would set.
    @ViewBuilder private var proofCaption: some View {
        if let proof, session.selection != nil {
            // **What it is, then what is wrong with it.** The caveats used to
            // come first, so the first line of the caption was "44 % rolled
            // into Display P3" — a statement about a picture that had not yet
            // been identified as a preview of anything. Naming the thing costs
            // one line and is what the rest of the caption is then about.
            VStack(spacing: 3) {
                Text(spaceLine(proof)).foregroundStyle(Theme.secondaryText)
                // A full-size render takes a moment, and the picture on screen
                // is the **previous** one while it does. A spinner on its own
                // said "something is happening"; it did not say that what you
                // are looking at is out of date, which is the only part that
                // can mislead. So it says it.
                if proving {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini).scaleEffect(0.55)
                        Text(L("Updating preview…", zh: "正在更新预览…")).foregroundStyle(Theme.dim)
                    }
                }
                if proof.isPlaceholder {
                    Text(L("Placeholder — these pixels are not the ones the file will carry.", zh: "占位图——这些像素不是文件最终写入的像素。"))
                        .foregroundStyle(Theme.exportAccent)
                }
                let caveats = ProofCaveat.lines(for: proof, chinese: chinese)
                ForEach(caveats, id: \.text) { caveat in
                    Text(caveat.text)
                        .foregroundStyle(caveat.isWarning ? Theme.exportAccent : Theme.dim)
                }
            }
            .font(Theme.Font.caption)
            .help(captionHelp(proof))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.bottom, 10)
        }
    }

    /// The space, and **only** the space. The size is stated two other places
    /// — the Size row and the Summary — and the canvas is worth mentioning
    /// only when it is a different space, which is the case RFC-018 §6 is
    /// actually about. Naming the file's pixels and both spaces in one line
    /// told a photographer nothing they could act on.
    /// The long version, one hover away: what a proof is, one size, and both
    /// spaces. Cheap to reach, and not in the way.
    private func captionHelp(_ proof: SoftProof) -> String {
        // The size is the file's, carried by the proof independently of the
        // smaller display image. It used to say "the file *will be*", which was
        // true while the proof was a sample rather than the same render.
        let pixels = "\(Int(proof.filePixelSize.width)) × \(Int(proof.filePixelSize.height))"
        let canvas = session.workingSpaceName
        var lines = [
            L("The picture above is a proof of the file: the same render and conversion "
              + "as the export, shown downsampled for the pane.",
              zh: "上方画面是文件的校样：与导出相同的渲染和转换，按窗格大小缩小显示。"),
            L("The file is \(pixels) px, in \(proof.targetName).", zh: "文件为 \(pixels) px，色彩空间为 \(proof.targetName)。"),
        ]
        if proof.targetName != canvas { lines.append(L("The canvas is in \(canvas).", zh: "画布的色彩空间为 \(canvas)。")) }
        if let detail = ProofCaveat.explain(proof, chinese: chinese) { lines.append(detail) }
        return lines.joined(separator: "\n")
    }

    /// The one-line caption. See `captionHelp` for the rest of it.
    ///
    /// **It leads with what the picture is.** It used to read "Proof in
    /// Display P3 · the canvas is Linear ProPhoto", which asks the reader to
    /// hold two spaces and two meanings of the word *canvas* — the pane in
    /// front of them, and the working space — before it has told them what
    /// they are looking at. The working space is still one hover away in
    /// `captionHelp`, where a second space is a detail rather than a
    /// comparison the caption makes on the reader's behalf.
    private func spaceLine(_ proof: SoftProof) -> String {
        L("Output preview · \(proof.targetName)", zh: "输出预览 · \(proof.targetName)")
    }

    /// Grid mode's card: the centre pane and the filmstrip as one, from just
    /// right of the settings card to the window's right edge, with the grid
    /// inside it. The drawing's own card — see `rightOfSettings`.
    ///
    /// The columns are the bar's detented slider and nothing else, so the grid
    /// never chooses a size for itself: two panes of different widths show the
    /// same count and a different thumbnail, which is Finder's behaviour and
    /// what the user asked for.
    ///
    /// Laid out from the leading edge rather than centred, at the drawing's
    /// own inset: the pitch is what falls out of the card's width and the
    /// column count, and a thumbnail takes the drawing's 0.66 of its column,
    /// so the gap between two is the other third at every count.
    private var gridCard: some View {
        GeometryReader { geo in
            let pitch = max(1, geo.size.width - M.gridPadding) / CGFloat(gridColumns)
            let cell = pitch * M.gridCellFraction
            let gap = pitch - cell
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap),
                                         count: gridColumns),
                          alignment: .leading,
                          spacing: M.gridRowSpacing) {
                    if worklist.isEmpty {
                        emptyWorklist
                    } else {
                        ForEach(worklist) { frame in
                            ExportGridCell(frame: frame,
                                           chosen: frame.id == session.selection,
                                           state: session.frameStates[frame.id] ?? .unprocessed,
                                           width: cell,
                                           geometry: session.thumbnailGeometry(for: frame.id))
                                .onTapGesture { tap(frame) }
                                .contextMenu {
                                    Button(L("Reveal in Finder", zh: "在访达中显示")) {
                                        NSWorkspace.shared.activateFileViewerSelecting([frame.id])
                                    }
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, M.gridPadding)
                .padding(.top, M.gridTopInset)
                .padding(.bottom, M.gridTopInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .railCard()
        .transition(.opacity)
    }

    // MARK: - the right card

    // Internal so the export-panel test can render the smallest view that owns
    // the worklist ForEach, rather than trying to count cells in the full page.
    var stripPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .center, spacing: M.cellLabelGap) {
                if worklist.isEmpty {
                    emptyWorklist
                } else {
                    ForEach(worklist) { frame in
                        ExportStripCell(frame: frame,
                                        chosen: frame.id == session.selection,
                                        state: session.frameStates[frame.id] ?? .unprocessed,
                                        geometry: session.thumbnailGeometry(for: frame.id))
                            .onTapGesture { tap(frame) }
                    }
                }
            }
            .padding(.horizontal, M.thumbMargin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .railCard()
    }

    private var emptyWorklist: some View {
        Text(L("Nothing is selected. ⌘-click images in the filmstrip to add them.", zh: "未选择任何图像。在胶片条中按住 ⌘ 点按图像以添加。"))
            .font(Theme.Font.label)
            .foregroundStyle(Theme.dim)
            .multilineTextAlignment(.center)
            .padding(20)
    }

    // MARK: - derived strings

    private var folderOptions: [ExportFolder] {
        if case .fixed(let p) = recipe.wrappedValue.folder { return [.besideOriginal, .fixed(path: p)] }
        return [.besideOriginal]
    }

    /// The display names of what the recipe stores in English: the chips,
    /// the format and the existing-file policy keep their English values,
    /// which the recipe file and the tests read.
    private var chinese: Bool { Localization.shared.resolved == .simplifiedChinese }

    private func tokenName(_ t: NameToken) -> String {
        guard chinese else { return t.label }
        switch t {
        case .originalName: return "原文件名"
        case .filmStock: return "胶片"
        case .printStock: return "印相"
        case .date: return "日期"
        }
    }

    private func formatName(_ f: ExportFormat) -> String {
        f == .di ? L(f.shortLabel, zh: "数字中间片") : f.shortLabel
    }

    private var existingNames: [ExistingFilePolicy: String] {
        guard chinese else { return [:] }
        return [.addSuffix: "添加后缀", .overwrite: "覆盖", .skip: "跳过"]
    }

    private func folderLabel(_ f: ExportFolder) -> String {
        switch f {
        case .besideOriginal: L("Beside the original", zh: "原图旁")
        // The folder's own name (2026-09-28). The whole path did not fit the
        // pill and truncated to "~/Documents/Summer 2026/SpektraL…"; it is
        // stated in full, wrapped, on the line under the rows and in this
        // pill's menu.
        case .fixed(let p): (p as NSString).lastPathComponent
        }
    }

    /// The naming context for the frame on the canvas, or the model sample
    /// when there is none — so the page shows a real filename whenever it can.
    private var nameContext: NamingRule.Context {
        guard let sel = session.selection else { return NamingRule.sampleContext }
        return NamingRule.Context(
            originalName: sel.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock,
            printStock: session.params.printStock,
            pixelSize: session.printPixelSize,
            counter: 1, date: Date())
    }

    private var sampleName: String {
        recipe.wrappedValue.naming.stem(nameContext) + "." + recipe.wrappedValue.format.ext
    }

    private var writePath: String {
        let source = session.selection ?? URL(fileURLWithPath: "/Users/you/Pictures/_DSC4037.NEF")
        return recipe.wrappedValue.directory(for: source).path
    }

    private var summaryLines: [String] {
        let r = recipe.wrappedValue
        var lines = [
            L("Recipe  \(r.name)", zh: "配方  \(r.name)"),
            L("Images  \(batch.count) of \(session.frames.count)", zh: "图像  \(batch.count) / \(session.frames.count)"),
            L("File name  \(sampleName)", zh: "文件名  \(sampleName)"),
            L("Format  \(r.format.shortLabel) · \(r.format.bitDepth) bit", zh: "格式  \(formatName(r.format)) · \(r.format.bitDepth) 位"),
            L("Size  \(resultingSizeLine)", zh: "尺寸  \(resultingSizeLine)"),
        ]
        if r.format.takesColorSpace {
            let name = ColorSpaceCatalog.name(for: r.colorSpace) ?? L("Unknown profile", zh: "未知描述文件")
            lines.append(L("Color Space  \(name)", zh: "色彩空间  \(name)"))
        } else {
            lines.append(L("Color Space  untagged (density)", zh: "色彩空间  未标记（密度）"))
        }
        if let proof, session.selection != nil { lines.append(L("Proof  \(proof.targetName)", zh: "校样  \(proof.targetName)")) }
        lines.append(L("Folder  \(destinationSummary)", zh: "文件夹  \(destinationSummary)"))
        return lines
    }

    // MARK: - helpers

    /// A labelled row: the label in the drawing's own column, the control
    /// after it, and the pair on the drawing's row height.
    ///
    /// **`maxWidth: .infinity, alignment: .leading` is load-bearing.** A
    /// `VStack` centres its children, so a row whose control is narrower than
    /// the well — a checkbox is 21 pt — collapses to the width of its own
    /// contents and is then centred, which puts the label halfway across the
    /// well while every neighbouring row's label is at the column. It filled
    /// by accident before, because every control in a row happened to want all
    /// the width it could get.
    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            // `Ink.secondary`, as every label in the editor is: a label is the
            // thing being asked and the control beside it is the thing being
            // said. Drawn in `Theme.text` they were the same weight, the same
            // size and the same colour as the values, which is the "everything
            // competing, nothing leading" the rails were rebuilt to fix — and
            // this page had stayed behind. `PillMenu`'s own rows were already
            // secondary, so the well did not even agree with itself.
            Text(label).font(F.label).foregroundStyle(Theme.Ink.secondary)
                .fixedSize().frame(minWidth: ExportPage.labelColumn, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: M.rowHeight)
    }

    /// `PanelSection`'s menu is an `AnyView` closure; this keeps the call sites
    /// reading like a menu rather than like a cast.
    private func sectionMenu<V: View>(@ViewBuilder _ content: @escaping () -> V) -> () -> AnyView {
        { AnyView(content()) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose", zh: "选择")
        panel.message = L("Where should this recipe write its files?", zh: "此配方应将文件写入何处？")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recipe.wrappedValue.folder = .fixed(path: url.path)
    }

    // MARK: - running it

    /// `notes.md`: "the export setting is applied to all the selected images".
    /// The batch runs through the one frame at a time the engine can hold, so
    /// each is selected, developed and written in turn, and the frame the
    /// person was looking at is put back afterwards.
    ///
    /// While it runs, `session.batchExporting` holds the open frame and the
    /// picked set still — the exporter writes whatever frame is open, so a
    /// click that moved it mid-run used to put one frame's render under
    /// another's name.
    private func run() {
        guard let r = store.selected, !batch.isEmpty, !running else { return }
        running = true
        session.batchExporting = true
        note = nil
        // The file on the pane is about to be replaced by one that does not
        // exist yet; until it does, the render stands.
        filePreview = nil
        runTask = Task {
            defer { running = false; session.batchExporting = false; runTask = nil }
            let home = session.selection
            let urls = batch
            var written: [URL] = []
            /// The file the pane will show once the run is over: the one
            /// written for the frame the person was looking at.
            ///
            /// **A batch writes several files and the pane shows one picture**,
            /// and the frame the person was viewing is the one they were
            /// looking at when they pressed Export — `notes.md`'s "the viewed
            /// image stays as the one the user is previously on" is about
            /// exactly that. If their frame was not in the batch, the first
            /// file written is the fallback.
            var shown: URL?
            var problems: [String] = []
            var fellBack = false
            var stoppedAt: Int?
            for (i, url) in urls.enumerated() {
                if Task.isCancelled { stoppedAt = i; break }
                session.exportProgress = Double(i) / Double(urls.count)
                // `select`, not `click`: the run has to put each frame on the
                // canvas — the exporter reads the open frame — and a click
                // would collapse the picked set to that one frame on the first
                // pass and empty the batch it is walking.
                if session.selection != url { session.select(url) }
                session.lastError = nil
                guard let sid = await session.ensureDeveloped() else {
                    // The frame was just selected and nothing else can move
                    // it, so a nil here is a develop that failed — say why
                    // rather than suggesting a wait that will not help.
                    let why = session.refusal?.message ?? session.lastError
                    problems.append(L("\(url.lastPathComponent) could not be developed",
                                      zh: "\(url.lastPathComponent) 无法显影")
                                    + (why.map { L(": \($0)", zh: "：\($0)") } ?? L(".", zh: "。")))
                    continue
                }
                if Task.isCancelled { stoppedAt = i; break }
                // Belt and braces for the lock above: the exporter writes the
                // open frame, so it must be this one.
                guard session.selection == url else {
                    problems.append(L("\(url.lastPathComponent) was skipped: another frame was opened.",
                                      zh: "已跳过 \(url.lastPathComponent)：打开了另一张图像。"))
                    continue
                }
                do {
                    let out = try await Exporter.export(session: session, recipe: r,
                                                        context: nameContext, sessionID: sid)
                    switch out {
                    case .wrote(let files, _, let fb):
                        written += files
                        if url == home, let first = files.first { shown = first }
                        fellBack = fellBack || fb
                    case .skipped(let existing):
                        problems.append(L("\(existing.lastPathComponent) already exists — skipped.",
                                          zh: "\(existing.lastPathComponent) 已存在——已跳过。"))
                    }
                } catch is CancellationError {
                    stoppedAt = i; break
                } catch {
                    let why = (error as? Exporter.ExportError).flatMap { chinese ? $0.chineseDescription : nil }
                        ?? EngineMessage.userFacing(error)
                    problems.append(L("\(url.lastPathComponent): \(why)", zh: "\(url.lastPathComponent)：\(why)"))
                }
            }
            if let stoppedAt {
                problems.append(L("Stopped — \(urls.count - stoppedAt) of \(urls.count) not exported.",
                                  zh: "已停止——\(urls.count) 张中有 \(urls.count - stoppedAt) 张未导出。"))
            }
            session.exportProgress = nil
            if let home, session.selection != home { session.select(home) }
            if let target = shown ?? written.first { filePreview = Self.embeddedPreview(of: target) }
            if fellBack {
                problems.append(L("That profile is not on this machine — the files were tagged "
                                  + "Display P3 instead.",
                                  zh: "本机没有该描述文件——文件已改为标记 Display P3。"))
            }
            if !written.isEmpty, let app = r.openWith {
                NSWorkspace.shared.open(written,
                                        withApplicationAt: URL(fileURLWithPath: app.path),
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    guard let error else { return }
                    Task { @MainActor in
                        note = ResultNote(text: L("\(app.name) would not open them: ", zh: "\(app.name) 无法打开这些文件：")
                                          + error.localizedDescription, warning: true)
                    }
                }
            }
            var parts: [String] = written.isEmpty
                ? [L("Nothing was written.", zh: "没有写入任何文件。")]
                : [L("Wrote ", zh: "已写入 ") + written.map(\.lastPathComponent).joined(separator: ", ")]
            parts += problems
            note = ResultNote(text: parts.joined(separator: "\n"), warning: !problems.isEmpty)
        }
    }
}

// MARK: - the strip's cell

/// One thumbnail down the right-hand card.
///
/// `notes.md`, and it is right: "Only the chosen image gets a white frame
/// around it, and the actual image name got displayed, the non-selected ones
/// are just there (no actual grey frame around it). The export batch is the
/// worklist, while `chosen` is only the current preview, so filenames remain
/// visible for every item even though only one gets the white frame.
///
/// This was briefly changed to stroke every cell in the drawing's `#686969`,
/// on a reading of the grid drawing's two rectangles per cell as chrome. They
/// are not: they are two example images — a white-framed 3:2 landscape and a
/// grey-framed 2:3 portrait, overlapping, each hugging its own aspect. The
/// drawing was a diagram of the behaviour, and the notes had described it
/// correctly from the start.
private struct ExportStripCell: View {
    let frame: Frame
    let chosen: Bool
    /// Unread by this cell; kept as the guard test's construction seam.
    let state: FrameState
    /// The frame's crop, turn and flips, drawn over its thumbnail.
    var geometry: Geometry = .default

    /// Keep the frame on the fitted image, not on the strip's fixed-height
    /// layout box.  The latter is what made a portrait thumbnail look as if
    /// it had a square frame: the box is deliberately shared by every cell,
    /// while the picture inside it has its own aspect ratio.
    private var frameStroke: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Theme.selectionFrame, lineWidth: chosen ? 2 : 0)
    }

    var body: some View {
        CropMaskedThumbnail(url: frame.id, geometry: geometry, maxPixel: 1024) { image in
            cell(image)
        }
        .help(frame.name)
    }

    private func cell(_ image: CGImage?) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let box = CGSize(width: geometry.size.width,
                                 height: Theme.Metric.Export.thumbMax)
                ZStack {
                    Color.clear
                    if let image {
                        let size = exportFittedImageSize(
                            imageSize: CGSize(width: image.width, height: image.height), in: box)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .overlay(frameStroke)
                    } else {
                        let size = exportFittedImageSize(imageSize: CGSize(width: 3, height: 2), in: box)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.well)
                            .frame(width: size.width, height: size.height)
                            .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                            .overlay(frameStroke)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metric.Export.thumbMax)
            .frame(maxWidth: .infinity)
            Text(frame.name)
                .font(Theme.Font.Export.label)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - the grid's cell

/// One cell of the grid card: the thumbnail with its filename beneath.
///
/// Not the filmstrip's cell. The editor's strip is a worklist and draws each
/// frame on a lighter plate inside a 3:2 box; the drawing's grid card draws
/// the frame itself on the card, stroked, at whatever shape it is — a
/// landscape one is wide and short, a portrait one is the other way about —
/// and its name centred under it. The two are different cells that happen to
/// show the same picture.
///
/// The white frame marks the **chosen** item and nothing else — the grid
/// drawing's second rectangle in each cell is a grey-framed *example*, not a
/// rule about unselected cells. It hugs the picture rather than boxing the
/// cell: 3:2 on a landscape frame of film, 2:3 on a portrait one, which is how
/// the editor's own filmstrip draws it. The cell keeps its pitch for layout;
/// what is drawn inside it is the picture's own size.
private struct ExportGridCell: View {
    let frame: Frame
    let chosen: Bool
    /// Unread by this cell; kept as the guard test's construction seam.
    let state: FrameState
    /// The column's thumbnail width, from the card's width and the slider.
    let width: CGFloat
    /// The frame's crop, turn and flips, drawn over its thumbnail.
    var geometry: Geometry = .default

    /// The box a picture is fitted into, and the cell's own width. Nearly
    /// square, and slightly taller — the drawing's two example frames are a
    /// landscape filling the box's width and a portrait filling its height,
    /// both centred, which is only possible if the box is a little taller than
    /// it is wide.
    private var box: CGSize { CGSize(width: width, height: width * 1.03) }

    /// The stroke is on the **picture**, not on the box: the drawing's
    /// landscape frame hugs a landscape frame of film and its portrait hugs a
    /// portrait one, so a wide picture is outlined wide. The fitted size is
    /// calculated explicitly from the pixels and the box before the overlay
    /// is attached, rather than relying on SwiftUI's proposed size.
    private var frameStroke: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Theme.selectionFrame, lineWidth: chosen ? 2 : 0)
    }

    var body: some View {
        CropMaskedThumbnail(url: frame.id, geometry: geometry, maxPixel: 1024) { image in
            cell(image)
        }
        .help(frame.name)
    }

    private func cell(_ image: CGImage?) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Color.clear
                    .frame(width: box.width, height: box.height)
                        .overlay {
                            if let image {
                                let size = exportFittedImageSize(
                                    imageSize: CGSize(width: image.width, height: image.height), in: box)
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .frame(width: size.width, height: size.height)
                                    .overlay(frameStroke)
                            } else {
                                // Nothing of its own to hug yet, so a 3:2 stand-in
                                // on the card's colour.
                                let size = exportFittedImageSize(imageSize: CGSize(width: 3, height: 2), in: box)
                                Rectangle().fill(Theme.card)
                                    .frame(width: size.width, height: size.height)
                                    .overlay(frameStroke)
                            }
                        }
            }
            Text(frame.name)
                .font(Theme.Font.Export.label)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: box.width)
        }
    }
}

/// Return the exact size an export thumbnail occupies when aspect-fitted into
/// its layout box. Keeping this calculation explicit makes the selection
/// outline attach to the picture's bounds, rather than to SwiftUI's proposed
/// box (which can be wider than a portrait image).
func exportFittedImageSize(imageSize: CGSize, in box: CGSize) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0,
          box.width > 0, box.height > 0 else { return .zero }
    let scale = min(box.width / imageSize.width, box.height / imageSize.height)
    return CGSize(width: (imageSize.width * scale).rounded(),
                  height: (imageSize.height * scale).rounded())
}

// MARK: - the pill chrome

/// The capsule `PillMenu` draws, for the rows whose menu is not a plain list:
/// the format and its bit depth, which are one setting in two controls, and
/// Open With, whose list is the machine's installed applications.
///
/// The chrome is written out rather than `PillMenu` generalised because
/// `PillMenu` lives in `Controls/` and belongs to the whole app; when a third
/// caller wants this shape, that is the moment to give it a home there.
private struct PillField<MenuContent: View>: View {
    let title: String
    var dimmed = false
    var font: Font = Theme.Font.label
    var help: String?
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        Menu { menu() } label: {
            HStack {
                Text(title).font(font)
                    .foregroundStyle(dimmed ? Theme.dim : Theme.text).padding(.leading, 9)
                Spacer(minLength: 4)
                // `PillMenu`'s mark, not SF Symbols' double chevron. One
                // glyph for "there is more under this", everywhere — the two
                // pills sat in the same row wearing different ones.
                Triangle()
                    .stroke(dimmed ? Theme.dim : Theme.text,
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                    .frame(width: 8, height: 5)
                    .padding(.trailing, 8)
            }
            .frame(height: Theme.Metric.Export.rowHeight - 1)
            .frame(maxWidth: .infinity)
            .background(Theme.pill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(dimmed)
        .help(help ?? "")
    }
}

// MARK: - what the destination could not hold

/// RFC-018 §6's middle statement, in words whose size follows the number: "a
/// saturated frame into sRGB is worth a word, a frame that fits is worth
/// silence."
///
/// Two things get said, because they are two different losses. *Compressed*
/// means the gamut map moved the pixel and it kept its detail at a lower
/// chroma; *clipped* means it ended up pinned to the container's edge and lost
/// detail. The second is the one worth interrupting for, so it is the one
/// drawn in the accent.
///
/// `compressedFraction` and not `movedFraction`: the latter is RFC §5.3's
/// literal counter — pixels the knee acted on — which reads ~1.0 on a plain
/// grey frame and is not a warning about anything.
enum ProofCaveat {
    struct Line: Hashable {
        var text: String
        var isWarning: Bool
    }

    /// Below this fraction the sentence is longer than the problem.
    static let silence = 0.0001      // 0.01 % of the frame
    /// At least this much and the wording stops being hedged.
    static let emphatic = 0.01       // 1 %

    /// **A number and a verb, and nothing else.** The verbs are the whole
    /// distinction — *rolled* kept its detail at a lower chroma, *clipped*
    /// lost it — and the sentences that used to spell that out are what the
    /// user asked to stop reading. `explain(_:)` is the same two statements
    /// for a tooltip, where they cost nothing.
    static func lines(for proof: SoftProof, chinese: Bool = false) -> [Line] {
        var out: [Line] = []
        if proof.compressedFraction >= silence {
            out.append(Line(text: chinese ? "\(share(proof.compressedFraction, chinese: true)) 压入 \(proof.targetName)"
                                    : "\(share(proof.compressedFraction)) rolled into \(proof.targetName)",
                            isWarning: false))
        }
        if proof.clippedFraction >= silence {
            out.append(Line(text: chinese ? "\(share(proof.clippedFraction, chinese: true)) 在 \(proof.targetName) 中被裁切"
                                    : "\(share(proof.clippedFraction)) clipped in \(proof.targetName)",
                            isWarning: true))
        }
        return out
    }

    /// The long form, for wherever there is room to hover.
    static func explain(_ proof: SoftProof, chinese: Bool = false) -> String? {
        guard !lines(for: proof).isEmpty else { return nil }
        var out: [String] = []
        if proof.compressedFraction >= silence {
            out.append(chinese
                       ? "画面中有 \(share(proof.compressedFraction, chinese: true)) 超出 \(proof.targetName)，已被压入其中而非直接裁掉。"
                       : "\(share(proof.compressedFraction)) of the frame is outside "
                       + "\(proof.targetName) and was rolled into it rather than cut off.")
        }
        if proof.clippedFraction >= silence {
            out.append(chinese
                       ? "画面中有 \(share(proof.clippedFraction, chinese: true)) 落在 \(proof.targetName) 的边缘，已丢失细节。"
                       : "\(share(proof.clippedFraction)) of the frame sits on the edge of "
                       + "\(proof.targetName) and has lost detail.")
        }
        return out.joined(separator: "\n")
    }

    static func share(_ fraction: Double, chinese: Bool = false) -> String {
        if fraction >= emphatic { return "\(Int((fraction * 100).rounded())) %" }
        if fraction * 1000 < 1 { return chinese ? "不足 0.1 %" : "Under 0.1 %" }
        return String(format: "%.1f %%", fraction * 100)
    }
}

// MARK: - Open With

/// The applications this machine says can open the recipe's format.
///
/// Asked once per extension and cached: `NSWorkspace`'s handler query wants a
/// file to ask about, so a throwaway one with the right suffix is made in the
/// temporary directory — cheaper and far more reliable than walking
/// `/Applications` and guessing at which bundles open a TIFF.
@MainActor
enum OpenWithCatalog {
    private(set) static var apps: [OpenWith] = []
    private static var cache: [String: [OpenWith]] = [:]

    static func refresh(for format: ExportFormat) {
        let ext = format.ext
        if let hit = cache[ext] { apps = hit; return }
        let probe = FileManager.default.temporaryDirectory
            .appending(path: "spektralab-openwith-probe.\(ext)")
        FileManager.default.createFile(atPath: probe.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: probe) }
        let list = NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .map { OpenWith(path: $0.path) }
            .filter { !$0.name.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache[ext] = list
        apps = list
    }
}
