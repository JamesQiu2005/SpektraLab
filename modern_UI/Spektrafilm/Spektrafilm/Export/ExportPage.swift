//  ExportPage.swift — the export page: the recipe on the left, the picture it
//  will write in the middle, the worklist down the right.
//
//  It replaces a 590 pt sheet whose own header argued that the image could be
//  left out, "because the canvas behind this sheet is already showing the
//  frame at the grade being exported". RFC-018 §2.5 retires that: the app now
//  converts once, at the end, per destination, so the canvas is a Display P3
//  proof and nothing more — and the recipes most likely to differ from it are
//  exactly the ones a person cannot check by looking at the canvas. So the
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
    /// The frames this export will write. **Not** `session.selection`: the
    /// two are different questions — what gets exported, and what is on the
    /// canvas — and `notes.md` is explicit that multi-selecting must not move
    /// the second one ("the viewed image stays as the one the user is
    /// previously on").
    @State private var targets: Set<URL> = []
    /// Where a ⇧-click's range starts, in `session.frames` order.
    @State private var anchor: URL?
    /// The settings card folds away to the left, which is what the tab on its
    /// trailing edge in the drawing is for.
    @State private var settingsCollapsed = false

    @State private var zoom: CGFloat = 1
    @State private var paneSize: CGSize = .zero
    @State private var proof: SoftProof?
    @State private var proving = false

    @State private var running = false
    @State private var note: ResultNote?

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
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                centre
                stripPanel
            }
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
    private func adoptSessionSelection() {
        guard let sel = session.selection else { return }
        if targets.isEmpty { targets = [sel] }
        if anchor == nil { anchor = sel }
    }

    /// `notes.md`: "Multi-select is allowed, and the export setting is applied
    /// to all the selected images." A plain click is a new single selection;
    /// ⌘ and ⇧ extend the *export* set and deliberately leave the viewed frame
    /// alone, so the proof on screen does not jump away from what the person
    /// was looking at while they pick the rest of the batch.
    ///
    /// The modifier is read off `NSEvent` rather than declared as three
    /// gestures: a plain `TapGesture` on macOS matches a ⌘-click too, so
    /// stacked variants both fire and a ⌘-click becomes a plain one as well.
    private func tap(_ frame: Frame) {
        let flags = NSEvent.modifierFlags
        let url = frame.id
        if flags.contains(.shift), let anchor,
           let a = session.frames.firstIndex(where: { $0.id == anchor }),
           let b = session.frames.firstIndex(where: { $0.id == url }) {
            targets = Set(session.frames[a <= b ? a...b : b...a].map(\.id))
            return
        }
        if flags.contains(.command) {
            if targets.contains(url) { targets.remove(url) } else { targets.insert(url) }
            return
        }
        targets = [url]
        anchor = url
        if session.selection != url { session.select(url) }
    }

    /// The batch, in the strip's order so the run is reproducible.
    private var batch: [URL] {
        session.frames.map(\.id).filter { targets.contains($0) }
    }

    // MARK: - the proof

    /// What the proof depends on: which frame, which destination space, and
    /// how many pixels are worth rendering. Everything else a recipe carries —
    /// the name, the folder, the existing-file policy — changes no pixel, and
    /// keying on the whole recipe would re-render the proof on every keystroke
    /// in the Name field.
    private struct ProofKey: Hashable {
        var frame: URL?
        var space: ExportColorSpace
        var takesColour: Bool
        var maxPixels: Int
    }

    private var proofKey: ProofKey {
        ProofKey(frame: session.selection,
                 space: recipe.wrappedValue.colorSpace,
                 takesColour: recipe.wrappedValue.format.takesColorSpace,
                 maxPixels: proofBudget)
    }

    /// The proof is rendered at the size it is shown at, rounded up to a whole
    /// megapixel so a window resize does not start a render per frame. Capped
    /// both ways: below 1 MP the picture on screen is soft, and past 8 MP the
    /// page is rendering pixels no display here can show.
    private var proofBudget: Int {
        guard paneSize.width > 1, paneSize.height > 1 else { return 2_000_000 }
        let wanted = Int(paneSize.width * paneSize.height * 4)
        return min(8_000_000, max(1_000_000, (wanted + 999_999) / 1_000_000 * 1_000_000))
    }

    private func makeProof() async {
        guard session.selection != nil else { proof = nil; return }
        // The centre has not been laid out yet, so `proofBudget` would be a
        // guess that is replaced a moment later and this would render the
        // proof twice on every open. The pane's own first pass sets
        // `paneSize`, which changes the key and brings us back. In Grid mode
        // there is no pane at all, and the proof is wanted the moment the
        // Viewer brings one.
        guard paneSize.width > 1 else { return }
        proving = true
        defer { proving = false }
        // Nothing on the canvas yet (the page opened from Browse, say): ask
        // for the develop the way every other view that wants a picture does.
        if session.serviceSessionIDForExport == nil { _ = await session.ensureDeveloped() }
        let made = await session.softProof(recipe: recipe.wrappedValue, maxPixels: proofBudget)
        guard !Task.isCancelled else { return }
        proof = made
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
            zoomButton("plus.magnifyingglass", "Zoom in", 1.5)
            zoomPill.padding(.horizontal, M.zoomClusterGap)
            zoomButton("minus.magnifyingglass", "Zoom out", 1 / 1.5)
            Spacer().frame(width: M.zoomToCount)
            countPill
            Spacer().frame(width: M.countTrailingInset)
        }
        .frame(height: M.topBarHeight)
        .panelCard()
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
        .frame(width: M.leftWidth)
        .panelCard()
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
                        PillMenu(label: "Color Space", options: ColorSpaceCatalog.all.map(\.space),
                                 title: { ColorSpaceCatalog.name(for: $0) ?? "Unknown profile" },
                                 selection: recipe.colorSpace,
                                 labelWidth: M.labelWidth, font: F.label)
                    }
                    if recipe.wrappedValue.format.takesQuality {
                        ScrubSlider(label: "Quality", sublabel: nil,
                                    value: recipe.quality, range: 0.3...1, snap: 0.01,
                                    format: { String(format: "%.0f", $0 * 100) },
                                    metrics: Self.sliderMetrics,
                                    onCommit: { store.save() })
                    }
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

    /// Not in the drawing, which leaves the card's lower third empty and has
    /// no way to start an export anywhere in it — and a page that cannot
    /// export is not a page. It sits where that empty space is, and carries
    /// the progress and the result the old sheet's footer carried.
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

    private var centre: some View {
        Group {
            switch mode {
            case .viewer: viewerPane
            case .grid: gridPane
            }
        }
        // `notes.md`: "Remember to write the transition between the modes in
        // both ways." Both branches carry one and the animation is on the
        // container, so neither direction is the one that happens to animate.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
        .animation(.easeOut(duration: 0.18), value: mode)
        // The tab the drawing puts on the settings card's trailing edge, which
        // folds that card away. The band belongs to the canvas, as in the
        // editor: the pill is revealed on approach rather than always drawn.
        .overlay(alignment: .leading) {
            HoverEdgeTab(edge: .leading, collapsed: $settingsCollapsed)
        }
    }

    private var viewerPane: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    if let proof {
                        Image(decorative: proof.image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                    } else if proving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(session.selection == nil
                             ? "No frame is open. Choose one from the strip."
                             : "This recipe writes no colour, so there is nothing to prove.")
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
        guard let proof else { return CGSize(width: 320, height: 213) }
        let w = CGFloat(proof.image.width), h = CGFloat(proof.image.height)
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
                ForEach(ProofCaveat.lines(for: proof), id: \.text) { caveat in
                    Text(caveat.text)
                        .foregroundStyle(caveat.isWarning ? Theme.exportAccent : Theme.secondaryText)
                }
                Text(spaceLine(proof)).foregroundStyle(Theme.dim)
            }
            .font(Theme.Font.caption)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.bottom, 10)
        }
    }

    /// The size stated is the **recipe's**, read through the same `size`
    /// binding the Size row shows, so the two cannot disagree.
    ///
    /// Not `SoftProof.exportPixelSize`: that field is meant to be the file's
    /// size and currently reports the *geometry's* own — `framed` in
    /// `SoftProof.softProof` is the canvas's current tier, so on a frame whose
    /// canvas is showing a preview it reads 2678 × 1785 where the export
    /// writes 6000 × 4000. Stating it here would be a lie in the one place
    /// this page exists to be honest. See the note to the pixels stream.
    private func spaceLine(_ proof: SoftProof) -> String {
        let canvas = "the canvas is showing \(ColorSpaceCatalog.name(for: .displayP3) ?? "Display P3")"
        let px = size.wrappedValue
        let file = "\(Int(px.width)) × \(Int(px.height)) px"
        return "Proof in \(proof.targetName) · writing \(file) · \(canvas)"
    }

    /// Grid mode is the editor's own Browse grid from `Windows/BrowseView.swift`
    /// — the same cells, thumbnails and badges — with this page's selection
    /// rule layered on through `BrowseCell.chosen`.
    ///
    /// The drawing annotates this mode in the artboard's margin — "Turns to
    /// choose grid size in grid view mode" — and draws no control for it. The
    /// grid therefore sizes itself to the pane, and that annotation is the one
    /// thing in the drawing this page does not implement.
    private var gridPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 250), spacing: 16)],
                      spacing: 16) {
                ForEach(session.frames) { frame in
                    BrowseCell(session: session, frame: frame, chosen: targets.contains(frame.id))
                        .onTapGesture { tap(frame) }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([frame.id])
                            }
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .transition(.opacity)
    }

    // MARK: - the right card

    private var stripPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .center, spacing: M.cellLabelGap) {
                ForEach(session.frames) { frame in
                    ExportStripCell(frame: frame,
                                    chosen: targets.contains(frame.id),
                                    state: session.frameStates[frame.id] ?? .unprocessed)
                        .onTapGesture { tap(frame) }
                }
            }
            .padding(.horizontal, M.thumbMargin)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(width: M.rightWidth)
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
    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            Text(label).font(F.label).foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: M.labelWidth, alignment: .leading)
            content()
        }
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
        Task {
            defer { running = false }
            let home = session.selection
            let urls = batch
            var written: [URL] = []
            var problems: [String] = []
            var fellBack = false
            for (i, url) in urls.enumerated() {
                session.exportProgress = Double(i) / Double(urls.count)
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
                        fellBack = fellBack || fb
                    case .skipped(let existing):
                        problems.append("\(existing.lastPathComponent) already exists; this recipe skips it.")
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(EngineMessage.userFacing(error))")
                }
            }
            session.exportProgress = nil
            if let home, session.selection != home { session.select(home) }
            if fellBack {
                problems.append("The chosen profile could not be resolved on this machine; those files "
                                + "were tagged Display P3 instead.")
            }
            if !written.isEmpty, let app = r.openWith {
                NSWorkspace.shared.open(written,
                                        withApplicationAt: URL(fileURLWithPath: app.path),
                                        configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    guard let error else { return }
                    Task { @MainActor in
                        note = ResultNote(text: "Could not open the files in \(app.name): "
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
/// `notes.md`: "Only the chosen image gets a white frame around it, and the
/// actual image name got displayed, the non-selected ones are just there (no
/// actual grey frame around it)." So the frame and the name are one decision,
/// not two, and an unchosen cell draws neither. **The drawing disagrees**: it
/// strokes the unchosen cell as well, in `#686969` (`cls-2`). `notes.md` is
/// the authority on behaviour, so the grey frame is not drawn — and this
/// comment is the record of the choice rather than a silent omission.
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

    static func lines(for proof: SoftProof) -> [Line] {
        var out: [Line] = []
        if proof.compressedFraction >= silence {
            out.append(Line(text: "\(share(proof.compressedFraction)) of the frame is outside "
                             + "\(proof.targetName) and was rolled into it rather than cut off.",
                            isWarning: false))
        }
        if proof.clippedFraction >= silence {
            out.append(Line(text: "\(share(proof.clippedFraction)) of the frame sits on the edge of "
                             + "\(proof.targetName) and has lost detail.",
                            isWarning: true))
        }
        return out
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
