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

    private static let sliderMetrics = SliderMetrics(
        labelWidth: M.labelWidth, valueWidth: 40, rowHeight: M.rowHeight,
        trackHeight: M.trackHeight, labelFont: F.label, valueFont: F.value)

    enum Mode: String, CaseIterable, Identifiable {
        case grid, viewer
        var id: String { rawValue }
        /// `notes.md` names both glyphs.
        var glyph: String { self == .grid ? "square.grid.2x2" : "rectangle.grid.3x1" }
        var help: String { self == .grid ? "Grid" : "Viewer" }
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
        VStack(spacing: M.gap) {
            topBar
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            mode = startIn
            adoptSessionSelection()
        }
        // A selection that arrives *after* the page does — the page opened
        // from Browse, or a develop that had not finished — is still the one
        // thing on the canvas, so it is what this export is for until the
        // person says otherwise. Without this the page sits with nothing
        // chosen and a proof of a picture it will not write.
        .onChange(of: session.selection) { _, _ in adoptSessionSelection() }
        .task(id: proofKey) { await makeProof() }
        .task(id: recipe.wrappedValue.format) { OpenWithCatalog.refresh(for: recipe.wrappedValue.format) }
    }

    // MARK: - the worklist

    /// What the page opens with: whatever the editor had on the canvas.
    ///
    /// The canvas's frame is a member of the set by construction, so this only
    /// has to cover the one case where it is not — a page opened onto a
    /// session whose set is empty, which is a folder opened straight into
    /// Browse and then exported.
    private func adoptSessionSelection() {
        guard let sel = session.selection, session.selectedFrames.isEmpty else { return }
        session.click(sel)
    }

    /// `notes.md`: "Multi-select is allowed, and the export setting is applied
    /// to all the selected images." This is the editor's own gesture, on the
    /// editor's own set: a plain click picks one frame and opens it, ⌘ toggles
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
        session.click(frame.id, command: NSEvent.modifierFlags.contains(.command))
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
    /// **The window's size is not in here and must not be.** The proof is the
    /// file's own pixels, so it does not depend on how much of it is on
    /// screen; a resize that started a 24-megapixel render would be the worst
    /// kind of waste, and there used to be a budget in this key that did
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
        /// Whether the centre has a pane to draw in — **not a proof input but
        /// a cost input**, and the one thing here that does not change a
        /// pixel. In Grid mode there is no pane at all, and a full-resolution
        /// proof is seconds of engine time. It is a `Bool` and not `paneSize`
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

    /// **The proof is asked for at the file's own size.** The user: "that's
    /// actually why I insisted on the export path actually showing how the
    /// exported image look like, with the full set export resolution, instead
    /// of the current preview cache."
    ///
    /// That took two changes, and the first was not enough on its own — worth
    /// keeping because the second is not where anyone would look for it.
    /// Removing the `maxPixels` budget here was measured, at the time, to
    /// leave the proof coming back 2678 × 1785 on a 6000 × 4000 frame: the
    /// budget was the *smaller* of two bounds, and `softProof` also clamped to
    /// the tier on the canvas (`min(exportSize, framed)`, where `framed`
    /// descends from the preview). Both are gone — `softProof` is
    /// `Exporter.filePixels`, which renders the full-tier source the export
    /// writes from — so there is no size argument left to pass and no ceiling
    /// left to miss.

    /// Renders the proof, keeping whatever is already on screen until the new
    /// one is ready.
    ///
    /// **Coalescing is `.task(id:)`'s**, not a queue: when the key changes
    /// SwiftUI cancels this task and starts another, so the last edit wins and
    /// the ones before it are abandoned rather than run in turn. A full-size
    /// proof is expensive enough that the difference matters — a queue would
    /// render every keystroke and show the first one last.
    private func makeProof() async {
        guard session.selection != nil else { proof = nil; return }
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
        let made = await session.softProof(recipe: recipe.wrappedValue)
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
            Spacer().frame(width: M.modeToggleLeading)
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
        .panelCard()
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
                zoomButton("plus.magnifyingglass", "Zoom in", 1.5)
                zoomPill.padding(.horizontal, M.zoomClusterGap)
                zoomButton("minus.magnifyingglass", "Zoom out", 1 / 1.5)
            }
            .frame(width: M.zoomClusterWidth)
            .transition(.opacity)
        } else {
            DetentSlider(value: $gridColumns, range: M.gridColumns,
                         width: M.zoomClusterWidth,
                         help: "Thumbnail size — \(gridColumns) columns")
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
            Button("Fit") { zoom = 1 }
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
        Text(session.frames.count == 1 ? "1 image" : "\(session.frames.count) images")
            .font(F.label)
            .foregroundStyle(Theme.text)
            .frame(width: M.pillWidth + 22, height: M.pillHeight)
            .background(Theme.well, in: Capsule())
            .help(batch.count == session.frames.count
                  ? "Every image in the session"
                  : "\(batch.count) of \(session.frames.count) selected for this export")
    }

    // MARK: - the left card

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    formulaSection
                    locationSection
                    namingSection
                    formatSection
                    summarySection
                }
                .padding(.top, 4)
            }
            footer
        }
        .panelCard()
        // The system's own alert with a text field in it — the same rule the
        // section menus follow, applied to the one thing on this page that
        // needs typing.
        .alert("Rename Recipe", isPresented: Binding(
            get: { renameDraft != nil },
            set: { if !$0 { renameDraft = nil } })) {
            TextField("Name", text: Binding(get: { renameDraft ?? "" },
                                            set: { renameDraft = $0 }))
            Button("Cancel", role: .cancel) { renameDraft = nil }
            Button("Rename") {
                let trimmed = (renameDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { recipe.wrappedValue.name = trimmed }
                renameDraft = nil
            }
        } message: {
            Text("The name in the recipe list.")
        }
    }

    /// The recipe list. `notes.md` fixes the "..." as a system menu — "Do not
    /// rewrite three dot click second layer button, use system-provided one
    /// only" — which is the `Menu` `SectionHeader` already draws, so nothing
    /// here opens a popover of its own.
    private var formulaSection: some View {
        PanelSection("Export Formula", key: "exportFormula", menu: sectionMenu {
            Button("New Recipe") { store.add() }
            Button("Duplicate") { if let s = store.selected { store.duplicate(s) } }
                .disabled(store.selected == nil)
            Button("Rename…") { renameDraft = store.selected?.name ?? "" }
                .disabled(store.selected == nil)
            Divider()
            Button("Delete") { if let s = store.selected { store.remove(s) } }
                .disabled(store.recipes.count < 2)
            Divider()
            Button("Reveal Recipes File in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.url])
            }
        }, metrics: Self.sectionMetrics) {
            // The list is inset 1 pt from the well's own edge rather than by
            // `wellPadding`: the drawing's chosen row is 2 units in from the
            // well edge, not from its content box.
            Well(padding: 1, vertical: 6) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: M.recipeRowSpacing) {
                            ForEach(store.recipes) { r in recipeRow(r) }
                        }
                    }
                    .frame(height: M.formulaListHeight)
                    .padding(.top, 9)
                    HStack(spacing: 14) {
                        Spacer()
                        railButton("plus", "New recipe", dimmed: false) { store.add() }
                        railButton("minus", "Delete this recipe", dimmed: store.recipes.count < 2) {
                            if let s = store.selected { store.remove(s) }
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
        }
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

    /// The chosen row is marked by its outline and nothing else — the drawing
    /// draws the same rule here: the row's fill is the well it sits in.
    private func recipeRow(_ r: ExportRecipe) -> some View {
        let on = r.id == store.selected?.id
        return Button { store.selectedID = r.id } label: {
            Text(r.name)
                .font(F.listItem)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 15)
                .frame(height: M.recipeRowHeight)
                .overlay {
                    if on {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(Theme.selectionFrame, lineWidth: 1.3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var locationSection: some View {
        PanelSection("Location", key: "exportLocation", menu: sectionMenu {
            Button("Choose Folder…") { chooseFolder() }
            Button("Use the Frame's Own Folder") { recipe.wrappedValue.folder = .besideOriginal }
            Divider()
            Button("Clear Subfolder") { recipe.wrappedValue.subfolder = "" }
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical) {
                VStack(spacing: M.rowSpacing) {
                    PillMenu(label: "Folder", options: folderOptions, title: { folderLabel($0) },
                             selection: recipe.folder, labelWidth: M.labelWidth, font: F.label)
                    row("Subfolder") {
                        TextField("none", text: recipe.subfolder)
                            .textFieldStyle(.plain)
                            .font(F.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, 8)
                            .frame(height: M.rowHeight)
                            .background(Theme.field, in: Capsule())
                            .onSubmit { store.save() }
                    }
                    PillMenu(label: "Existing File", options: ExistingFilePolicy.allCases,
                             title: { $0.label }, selection: recipe.existing,
                             labelWidth: M.labelWidth, font: F.label)
                    Text(writePath)
                        .font(F.value).foregroundStyle(Theme.dim)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// `notes.md`: "Four Naming options … (at least one must be selected),
    /// selection is marked with Orange highlight `#f08724`, and the actual
    /// order can be altered by user dragging". All four are always drawn, in
    /// the rule's own order; the ones switched on take the accent and the rest
    /// the grey plate the drawing gives every chip, and dragging one onto
    /// another reorders the row.
    private var namingSection: some View {
        PanelSection("Naming", key: "exportNaming", menu: sectionMenu {
            Button("Original Name Only") {
                var n = recipe.wrappedValue.naming
                for t in n.chips where n.isOn(t) && t != .originalName { n.toggle(t) }
                if !n.isOn(.originalName) { n.toggle(.originalName) }
                recipe.wrappedValue.naming = n
            }
            Button("Select All") {
                var n = recipe.wrappedValue.naming
                for t in n.chips where !n.isOn(t) { n.toggle(t) }
                recipe.wrappedValue.naming = n
            }
            Divider()
            Button("Reset the Order") {
                var n = recipe.wrappedValue.naming
                n.resetOrder()
                recipe.wrappedValue.naming = n
            }
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical) {
                VStack(alignment: .leading, spacing: M.rowSpacing) {
                    row("Format") { tokenRow }
                    row("Sample") {
                        Text(sampleName)
                            .font(F.label)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var tokenRow: some View {
        HStack(spacing: M.chipSpacing) {
            ForEach(recipe.wrappedValue.naming.chips) { t in tokenChip(t) }
        }
    }

    private func tokenChip(_ t: NameToken) -> some View {
        let on = recipe.wrappedValue.naming.isOn(t)
        let last = recipe.wrappedValue.naming.tokens.count == 1
        return Text(t.label)
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
            .help(on && last ? "A filename needs at least one part"
                  : (on ? "Remove \(t.helpName) from the filename" : "Add \(t.helpName) to the filename"))
            .draggable(t.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let moving = NameToken(rawValue: raw) else { return false }
                var n = recipe.wrappedValue.naming
                n.move(moving, before: t)
                recipe.wrappedValue.naming = n
                return true
            }
    }

    private var formatSection: some View {
        PanelSection("Format and Size", key: "exportFormat", menu: sectionMenu {
            Button("Set to Original Size") { recipe.wrappedValue.outputSize = .original }
                .disabled(recipe.wrappedValue.outputSize.isOriginal)
            Divider()
            openWithMenu
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical) {
                VStack(spacing: M.rowSpacing) {
                    HStack(spacing: 12) {
                        Text("Format").font(F.label).foregroundStyle(Theme.text)
                            .frame(width: M.labelWidth, alignment: .leading)
                        PillField(title: recipe.wrappedValue.format.shortLabel, font: F.label) {
                            ForEach(ExportFormat.allCases) { f in
                                Button(f.shortLabel) { recipe.wrappedValue.format = f }
                            }
                        }
                        depthPill
                    }
                    .frame(height: M.rowHeight)
                    if recipe.wrappedValue.format.takesColorSpace {
                        // The name is data, not a fixed label: an installed
                        // profile can be called anything, and the narrowest
                        // card truncates the long ones. The tooltip carries
                        // the whole of it, so a truncated name costs a hover
                        // rather than the information.
                        PillMenu(label: "Color Space", options: ColorSpaceCatalog.all.map(\.space),
                                 title: { ColorSpaceCatalog.name(for: $0) ?? "Unknown profile" },
                                 selection: recipe.colorSpace,
                                 labelWidth: M.labelWidth, font: F.label)
                            .help(ColorSpaceCatalog.name(for: recipe.wrappedValue.colorSpace)
                                  ?? "This profile is not on this machine")
                    }
                    if recipe.wrappedValue.format.takesQuality {
                        ScrubSlider(label: "Quality", sublabel: nil,
                                    value: recipe.quality, range: 0.3...1, snap: 0.01,
                                    format: { String(format: "%.0f", $0 * 100) },
                                    metrics: Self.sliderMetrics,
                                    onCommit: { store.save() })
                    }
                    if recipe.wrappedValue.format == .tiff { previewRow }
                    sizeRow
                    openWithRow
                }
            }
        }
    }

    /// The bit depth is not a free choice: `ExportFormat` *is* the format and
    /// the depth together, so this pill switches between the two containers
    /// that carry the asked-for depth, and says why it is inert for JPEG and
    /// the DI package rather than pretending to move.
    private var depthPill: some View {
        let format = recipe.wrappedValue.format
        return PillField(title: "\(format.bitDepth) bit",
                         dimmed: !format.depthIsChoosable,
                         font: F.label,
                         help: format.depthIsChoosable
                         ? "Bit depth. 16-bit switches to TIFF, 8-bit to PNG."
                         : "\(format.shortLabel) has one depth — it is part of the format.") {
            ForEach([8, 16], id: \.self) { depth in
                Button("\(depth) bit") {
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
        row("Preview") {
            CheckBox(isOn: recipe.embedsPreview)
                .help("Writes a preview image into the TIFF, about a tenth larger. "
                      + "Off unless a recipe asks for it.")
        }
    }

    /// Size + the "..." `notes.md` asks for by name: "for the size three dot,
    /// include set to originals".
    private var sizeRow: some View {
        HStack(spacing: 6) {
            Text("Size").font(F.label).foregroundStyle(Theme.text)
                .frame(width: M.labelWidth, alignment: .leading)
            numberField(.width)
            Text("×").font(F.label).foregroundStyle(Theme.dim)
            numberField(.height)
            Spacer(minLength: 0)
            Menu {
                Button("Set to Original Size") { recipe.wrappedValue.outputSize = .original }
                    .disabled(recipe.wrappedValue.outputSize.isOriginal)
                Divider()
                openWithMenu
            } label: {
                EllipsisGlyph().frame(width: 15, height: 3).padding(4).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Size options")
        }
        .frame(height: M.rowHeight)
    }

    private enum SizeAxis { case width, height }

    private func numberField(_ axis: SizeAxis) -> some View {
        TextField("", value: Binding(
            get: { Int(axis == .width ? size.wrappedValue.width : size.wrappedValue.height) },
            set: { new in
                let w = axis == .width ? new : Int(size.wrappedValue.width)
                let h = axis == .height ? new : Int(size.wrappedValue.height)
                recipe.wrappedValue.outputSize = .custom(width: max(1, w), height: max(1, h))
            }), format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(F.label).foregroundStyle(Theme.text)
            .frame(width: 62, height: M.rowHeight)
            .background(Theme.field, in: Capsule())
    }

    /// `notes.md`: "Open with allows the user to select the default open_app."
    private var openWithRow: some View {
        HStack(spacing: 6) {
            Text("Open With").font(F.label).foregroundStyle(Theme.text)
                .frame(width: M.labelWidth, alignment: .leading)
            PillField(title: recipe.wrappedValue.openWith?.name ?? "None", font: F.label) {
                openWithItems
            }
        }
        .frame(height: M.rowHeight)
    }

    @ViewBuilder private var openWithMenu: some View {
        Menu("Open With") { openWithItems }
    }

    @ViewBuilder private var openWithItems: some View {
        Button("None") { recipe.wrappedValue.openWith = nil }
        if !OpenWithCatalog.apps.isEmpty { Divider() }
        ForEach(OpenWithCatalog.apps, id: \.path) { app in
            Button(app.name) { recipe.wrappedValue.openWith = app }
        }
    }

    private var summarySection: some View {
        PanelSection("Summary", key: "exportSummary", initiallyExpanded: false, menu: sectionMenu {
            Button("Copy Summary") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summaryLines.joined(separator: "\n"), forType: .string)
            }
        }, metrics: Self.sectionMetrics) {
            Well(padding: M.wellPadding, vertical: M.wellVertical) {
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
                Text(running ? "Exporting…" : exportButtonTitle)
                    .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                Spacer()
                Button(running ? "Exporting…" : "Export") { run() }
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
        case 0: "No images selected"
        case 1: "1 image"
        default: "\(batch.count) images"
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
                    centre
                    PanelResizeHandle(side: .leadingEdge, range: M.rightRange,
                                      width: $rightWidth.width)
                    stripPanel
                        .frame(width: rightWidth.width)
                }
                .transition(.opacity)
            case .grid:
                gridCard
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
    private var displayImage: CGImage? { filePreview ?? proof?.image }

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
                        ProgressView().controlSize(.small)
                    } else {
                        Text(session.selection == nil
                             ? "No frame is open. Choose one from the strip."
                             : "Nothing to prove for this recipe.")
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
            VStack(spacing: 3) {
                if proof.isPlaceholder {
                    Text("Placeholder — these pixels are not the ones the file will carry.")
                        .foregroundStyle(Theme.exportAccent)
                }
                let caveats = ProofCaveat.lines(for: proof)
                ForEach(caveats, id: \.text) { caveat in
                    Text(caveat.text)
                        .foregroundStyle(caveat.isWarning ? Theme.exportAccent : Theme.secondaryText)
                }
                HStack(spacing: 5) {
                    // A full-size proof takes a moment, and the picture on
                    // screen is the previous one while it does. This says so
                    // without covering the picture with a spinner.
                    if proving { ProgressView().controlSize(.mini).scaleEffect(0.55) }
                    Text(spaceLine(proof)).foregroundStyle(Theme.dim)
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
        // One size, and it is the image's: there is no `exportPixelSize` any
        // more, because there is no second size for it to be. The line below
        // used to say "the file *will be*", which was true while the proof was
        // a sample of it.
        let pixels = "\(proof.image.width) × \(proof.image.height)"
        let canvas = session.workingSpaceName
        var lines = [
            "The picture above is a proof: the file's own pixels, through the same "
            + "conversion the export will run.",
            "The file is \(pixels) px, in \(proof.targetName).",
        ]
        if proof.targetName != canvas { lines.append("The canvas is in \(canvas).") }
        if let detail = ProofCaveat.explain(proof) { lines.append(detail) }
        return lines.joined(separator: "\n")
    }

    /// The one-line caption. See `captionHelp` for the rest of it.
    private func spaceLine(_ proof: SoftProof) -> String {
        let canvas = session.workingSpaceName
        return proof.targetName == canvas
            ? "Proof in \(proof.targetName)"
            : "Proof in \(proof.targetName) · the canvas is \(canvas)"
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
                    ForEach(session.frames) { frame in
                        ExportGridCell(frame: frame,
                                       chosen: session.isPicked(frame.id),
                                       state: session.frameStates[frame.id] ?? .unprocessed,
                                       width: cell)
                            .onTapGesture { tap(frame) }
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([frame.id])
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
        .panelCard()
        .transition(.opacity)
    }

    // MARK: - the right card

    private var stripPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .center, spacing: M.cellLabelGap) {
                ForEach(session.frames) { frame in
                    ExportStripCell(frame: frame,
                                    chosen: session.isPicked(frame.id),
                                    state: session.frameStates[frame.id] ?? .unprocessed)
                        .onTapGesture { tap(frame) }
                }
            }
            .padding(.horizontal, M.thumbMargin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .panelCard()
    }

    // MARK: - derived strings

    private var folderOptions: [ExportFolder] {
        if case .fixed(let p) = recipe.wrappedValue.folder { return [.besideOriginal, .fixed(path: p)] }
        return [.besideOriginal]
    }

    private func folderLabel(_ f: ExportFolder) -> String {
        switch f {
        case .besideOriginal: "Beside the original"
        case .fixed(let p): (p as NSString).abbreviatingWithTildeInPath
        }
    }

    /// The naming context for the frame on the canvas, or the model sample
    /// when there is none — so the page shows a real filename whenever it can.
    private var nameContext: NamingRule.Context {
        guard let sel = session.selection else { return NamingRule.sampleContext }
        let out = session.geometry.outputSize(for: session.sourceImageSize)
        let scale = session.sourceLongEdge > 0
            ? session.sourceLongEdge / max(session.sourceImageSize.width, session.sourceImageSize.height) : 1
        return NamingRule.Context(
            originalName: sel.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock,
            printStock: session.params.printStock,
            pixelSize: CGSize(width: (out.width * scale).rounded(), height: (out.height * scale).rounded()),
            counter: 1, date: Date())
    }

    private var sampleName: String {
        recipe.wrappedValue.naming.stem(nameContext) + "." + recipe.wrappedValue.format.ext
    }

    /// The two fields show the original size until one is edited, and then
    /// show what was typed — "set to originals" in `notes.md`'s phrasing is
    /// the way back. `ExportRecipe.pixelSize` is the same reading the export
    /// path makes, so the page and the file cannot disagree about it.
    private var size: Binding<CGSize> {
        Binding(get: {
            switch recipe.wrappedValue.outputSize {
            case .original: return nameContext.pixelSize
            case .custom(let w, let h): return CGSize(width: CGFloat(w), height: CGFloat(h))
            }
        }, set: { s in
            recipe.wrappedValue.outputSize = .custom(width: Int(s.width), height: Int(s.height))
        })
    }

    private var writePath: String {
        let source = session.selection ?? URL(fileURLWithPath: "/Users/you/Pictures/_DSC4037.NEF")
        return recipe.wrappedValue.directory(for: source).path
    }

    private var summaryLines: [String] {
        let r = recipe.wrappedValue
        var lines = [
            "Recipe  \(r.name)",
            "Images  \(batch.count) of \(session.frames.count)",
            "File name  \(sampleName)",
            "Format  \(r.format.shortLabel) · \(r.format.bitDepth) bit",
        ]
        if r.format.takesColorSpace {
            lines.append("Colour space  \(ColorSpaceCatalog.name(for: r.colorSpace) ?? "Unknown profile")")
        } else {
            lines.append("Colour space  untagged (density)")
        }
        if let proof, session.selection != nil { lines.append("Proof  \(proof.targetName)") }
        lines.append("Folder  \(writePath)")
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
            Text(label).font(F.label).foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: M.labelWidth, alignment: .leading)
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
        panel.prompt = "Choose"
        panel.message = "Where should this recipe write its files?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recipe.wrappedValue.folder = .fixed(path: url.path)
    }

    // MARK: - running it

    /// `notes.md`: "the export setting is applied to all the selected images".
    /// The batch runs through the one frame at a time the engine can hold, so
    /// each is selected, developed and written in turn, and the frame the
    /// person was looking at is put back afterwards.
    private func run() {
        guard let r = store.selected, !batch.isEmpty, !running else { return }
        running = true
        note = nil
        // The file on the pane is about to be replaced by one that does not
        // exist yet; until it does, the render stands.
        filePreview = nil
        Task {
            defer { running = false }
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
            for (i, url) in urls.enumerated() {
                session.exportProgress = Double(i) / Double(urls.count)
                // `select`, not `click`: the run has to put each frame on the
                // canvas — the exporter reads the open frame — and a click
                // would collapse the picked set to that one frame on the first
                // pass and empty the batch it is walking.
                if session.selection != url { session.select(url) }
                guard let sid = await session.ensureDeveloped() else {
                    problems.append("\(url.lastPathComponent) is still developing.")
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
                        problems.append("\(existing.lastPathComponent) already exists — skipped.")
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(EngineMessage.userFacing(error))")
                }
            }
            session.exportProgress = nil
            if let home, session.selection != home { session.select(home) }
            if let target = shown ?? written.first { filePreview = Self.embeddedPreview(of: target) }
            if fellBack {
                problems.append("That profile is not on this machine — the files were tagged "
                                + "Display P3 instead.")
            }
            if !written.isEmpty, let app = r.openWith {
                NSWorkspace.shared.open(written,
                                        withApplicationAt: URL(fileURLWithPath: app.path),
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    guard let error else { return }
                    Task { @MainActor in
                        note = ResultNote(text: "\(app.name) would not open them: "
                                          + error.localizedDescription, warning: true)
                    }
                }
            }
            var parts: [String] = written.isEmpty
                ? ["Nothing was written."]
                : ["Wrote " + written.map(\.lastPathComponent).joined(separator: ", ")]
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
/// are just there (no actual grey frame around it)." So the frame and the name
/// are one decision, not two, and an unchosen cell draws neither.
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
    let state: FrameState
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                            .aspectRatio(3 / 2, contentMode: .fit)
                            .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: Theme.Metric.Export.thumbMax)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.selectionFrame, lineWidth: chosen ? 2 : 0))
                badge.padding(5).opacity(chosen ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            if chosen {
                Text(frame.name)
                    .font(Theme.Font.Export.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .help(frame.name)
        .task(id: frame.id) {
            image = await ThumbnailCache.shared.thumbnail(for: frame.id, maxPixel: 1024)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
            guard (n.object as? URL) == frame.id else { return }
            Task { image = await ThumbnailCache.shared.thumbnail(for: frame.id, maxPixel: 1024) }
        }
    }

    /// The same three states the filmstrip and the browse grid use, and
    /// suppressed on the chosen cell for the same reason the filmstrip
    /// suppresses it there: next to the selection frame a second mark reads as
    /// more state to decode.
    @ViewBuilder private var badge: some View {
        switch state {
        case .unprocessed: EmptyView()
        case .processed: Circle().fill(Theme.text).frame(width: 7, height: 7).shadow(radius: 1)
        case .stale: Circle().stroke(Theme.text, lineWidth: 1.4).frame(width: 7, height: 7).shadow(radius: 1)
        }
    }
}

// MARK: - the grid's cell

/// One cell of the grid card: the thumbnail with its filename beneath.
///
/// Not `BrowseCell`. The editor's browse grid is a worklist and draws each
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
    let state: FrameState
    /// The column's thumbnail width, from the card's width and the slider.
    let width: CGFloat
    @State private var image: CGImage?

    /// The box a picture is fitted into, and the cell's own width. Nearly
    /// square, and slightly taller — the drawing's two example frames are a
    /// landscape filling the box's width and a portrait filling its height,
    /// both centred, which is only possible if the box is a little taller than
    /// it is wide.
    private var box: CGSize { CGSize(width: width, height: width * 1.03) }

    /// The stroke is on the **picture**, not on the box: the drawing's
    /// landscape frame hugs a landscape frame of film and its portrait hugs a
    /// portrait one, so a wide picture is outlined wide. `.aspectRatio(.fit)`
    /// returns a view of the fitted size, so an overlay here is the picture's
    /// own bounds — which is why this is an overlay *inside* the box rather
    /// than one on the cell.
    private var frameStroke: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Theme.selectionFrame, lineWidth: chosen ? 2 : 0)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .frame(width: box.width, height: box.height)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .overlay(frameStroke)
                        } else {
                            // Nothing of its own to hug yet, so a 3:2 stand-in
                            // on the card's colour.
                            Rectangle().fill(Theme.card)
                                .aspectRatio(3 / 2, contentMode: .fit)
                                .overlay(frameStroke)
                        }
                    }
                badge.padding(4).opacity(chosen ? 0 : 1)
            }
            Text(frame.name)
                .font(Theme.Font.Export.label)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: box.width)
        }
        .help(frame.name)
        .task(id: frame.id) {
            image = await ThumbnailCache.shared.thumbnail(for: frame.id, maxPixel: 1024)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
            guard (n.object as? URL) == frame.id else { return }
            Task { image = await ThumbnailCache.shared.thumbnail(for: frame.id, maxPixel: 1024) }
        }
    }

    /// The same three states as everywhere else in the app, suppressed on the
    /// chosen cell for the same reason the filmstrip suppresses it there.
    @ViewBuilder private var badge: some View {
        switch state {
        case .unprocessed: EmptyView()
        case .processed: Circle().fill(Theme.text).frame(width: 7, height: 7).shadow(radius: 1)
        case .stale: Circle().stroke(Theme.text, lineWidth: 1.4).frame(width: 7, height: 7).shadow(radius: 1)
        }
    }
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
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(dimmed ? Theme.dim : Theme.text).padding(.trailing, 6)
            }
            .frame(height: Theme.Metric.Export.rowHeight - 1)
            .frame(maxWidth: .infinity)
            .background(Theme.field, in: Capsule())
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
    static func lines(for proof: SoftProof) -> [Line] {
        var out: [Line] = []
        if proof.compressedFraction >= silence {
            out.append(Line(text: "\(share(proof.compressedFraction)) rolled into \(proof.targetName)",
                            isWarning: false))
        }
        if proof.clippedFraction >= silence {
            out.append(Line(text: "\(share(proof.clippedFraction)) clipped in \(proof.targetName)",
                            isWarning: true))
        }
        return out
    }

    /// The long form, for wherever there is room to hover.
    static func explain(_ proof: SoftProof) -> String? {
        guard !lines(for: proof).isEmpty else { return nil }
        var out: [String] = []
        if proof.compressedFraction >= silence {
            out.append("\(share(proof.compressedFraction)) of the frame is outside "
                       + "\(proof.targetName) and was rolled into it rather than cut off.")
        }
        if proof.clippedFraction >= silence {
            out.append("\(share(proof.clippedFraction)) of the frame sits on the edge of "
                       + "\(proof.targetName) and has lost detail.")
        }
        return out.joined(separator: "\n")
    }

    static func share(_ fraction: Double) -> String {
        if fraction >= emphatic { return "\(Int((fraction * 100).rounded())) %" }
        if fraction * 1000 < 1 { return "Under 0.1 %" }
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
            .appending(path: "filmify-openwith-probe.\(ext)")
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
