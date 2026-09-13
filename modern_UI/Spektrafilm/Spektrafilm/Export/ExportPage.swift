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
//  The layout is `reference_layout/Export_Page/notes.md`, which is the
//  authority, and `Reference_Screenshot.jpg` beside it. Every "##" in the
//  notes is a hard constraint and each is cited where it is implemented.
//
//  The style is the rest of the app's: `PanelSection` headers, `Well` grounds,
//  `PillMenu` pills and `Theme` tokens, with no literal colour anywhere except
//  the accent — which is the one `notes.md` names (`#f08724`; `Theme.accent`
//  is `#EE8A2B`, the same orange to within this mockup's CMYK round-trip).

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

    @State private var zoom: CGFloat = 1
    @State private var paneSize: CGSize = .zero
    @State private var proof: SoftProof?
    @State private var proving = false

    @State private var running = false
    @State private var note: ResultNote?

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
        VStack(spacing: Theme.Metric.Export.gap) {
            topBar
            HStack(spacing: 0) {
                settingsPanel
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
    private var topBar: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Theme.Metric.Export.modeToggleLeading)
            modeButton(.grid)
            modeButton(.viewer).padding(.leading, 12)
            // The empty middle is the window's drag surface, exactly as it is
            // on the editor's bar: the titlebar is hidden.
            WindowDragHandle().frame(minWidth: 8, maxWidth: .infinity)
            zoomButton("plus.magnifyingglass", "Zoom in", 1.5)
            zoomPill.padding(.horizontal, 10)
            zoomButton("minus.magnifyingglass", "Zoom out", 1 / 1.5)
            Spacer().frame(width: Theme.Metric.Export.zoomToFilmstrip)
            countPill
            Spacer().frame(width: Theme.Metric.Export.countTrailingInset)
        }
        .frame(height: Theme.Metric.topBarHeight)
        .panelCard()
    }

    /// Both glyphs are named in `notes.md`, and the viewer's is drawn turned a
    /// quarter turn. Selection is the app's accent rather than a plate — the
    /// rule the editor's tool row follows, and the one `notes.md` restates for
    /// the naming chips.
    private func modeButton(_ m: Mode) -> some View {
        let on = mode == m
        return Button { mode = m } label: {
            Image(systemName: m.glyph)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .rotationEffect(.degrees(m == .viewer ? 90 : 0))
                .foregroundStyle(on ? Theme.accent : Theme.text.opacity(0.55))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.help)
    }

    private func zoomButton(_ glyph: String, _ help: String, _ factor: CGFloat) -> some View {
        Button { zoom = (zoom * factor).clamped(to: 0.1...8) } label: {
            Image(systemName: glyph)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mode != .viewer)
        .opacity(mode == .viewer ? 1 : 0.4)
        .help(help)
    }

    private var zoomPill: some View {
        Menu {
            Button("Fit") { zoom = 1 }
            Divider()
            ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { f in
                Button("\(Int(f * 100)) %") { zoom = CGFloat(f) }
            }
        } label: {
            Text("\(Int((zoom * 100).rounded())) %")
                .font(Theme.Font.pill)
                .foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.zoomPill.width, height: Theme.Metric.zoomPill.height)
                .background(Theme.well, in: Capsule())
                .overlay(Capsule().stroke(Theme.text, lineWidth: 1))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(mode != .viewer)
        .opacity(mode == .viewer ? 1 : 0.4)
    }

    /// The pill is centred over the filmstrip card rather than inset from the
    /// window's edge, which is where the reference measures it: it labels the
    /// strip below it.
    private var countPill: some View {
        Text(session.frames.count == 1 ? "1 image" : "\(session.frames.count) images")
            .font(Theme.Font.pill)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: Theme.Metric.zoomPill.height)
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
                .padding(.top, 8)
            }
            footer
        }
        .frame(width: Theme.Metric.Export.leftWidth)
        .panelCard()
    }

    /// The recipe list. `notes.md` fixes the "..." as a system menu — "Do not
    /// rewrite three dot click second layer button, use system-provided one
    /// only" — which is the `Menu` `SectionHeader` already draws, so nothing
    /// here opens a popover of its own.
    private var formulaSection: some View {
        PanelSection("Export Formula", key: "exportFormula", menu: { AnyView(
            Group {
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
            }
        ) }) {
            Well {
                VStack(spacing: 5) {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(store.recipes) { r in recipeRow(r) }
                        }
                    }
                    .frame(height: 196)
                    HStack(spacing: 12) {
                        Spacer()
                        Button { store.add() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Theme.text)
                                .frame(width: 20, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("New recipe")
                        Button { if let s = store.selected { store.remove(s) } } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(store.recipes.count < 2 ? Theme.text.opacity(0.4) : Theme.text)
                                .frame(width: 20, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.recipes.count < 2)
                        .help("Delete this recipe")
                    }
                }
            }
        }
    }

    /// The chosen row is marked by its outline and nothing else. The reference
    /// draws the same rule here: the row's fill is the well it sits in.
    private func recipeRow(_ r: ExportRecipe) -> some View {
        let on = r.id == store.selected?.id
        return Button { store.selectedID = r.id } label: {
            Text(r.name)
                .font(Theme.Font.listItem)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: Theme.Metric.Export.recipeRowHeight)
                .overlay {
                    if on {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Theme.selectionFrame, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var locationSection: some View {
        PanelSection("Location", key: "exportLocation", menu: { AnyView(
            Group {
                Button("Choose Folder…") { chooseFolder() }
                Button("Use the Frame's Own Folder") { recipe.wrappedValue.folder = .besideOriginal }
                Divider()
                Button("Clear Subfolder") { recipe.wrappedValue.subfolder = "" }
            }
        ) }) {
            Well {
                VStack(spacing: 5) {
                    PillMenu(label: "Folder", options: folderOptions, title: { folderLabel($0) },
                             selection: recipe.folder, labelWidth: Theme.Metric.Export.labelWidth)
                    labelled("Subfolder") {
                        TextField("none", text: recipe.subfolder)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 16)
                            .background(Theme.field, in: Capsule())
                            .onSubmit { store.save() }
                    }
                    PillMenu(label: "Existing File", options: ExistingFilePolicy.allCases,
                             title: { $0.label }, selection: recipe.existing,
                             labelWidth: Theme.Metric.Export.labelWidth)
                    caption(writePath)
                }
            }
        }
    }

    /// `notes.md`: "Four Naming options … (at least one must be selected),
    /// selection is marked with Orange highlight `#f08724`, and the actual
    /// order can be altered by user dragging". All four are always drawn, in
    /// the rule's own order; the ones switched on take the accent, the rest
    /// the field colour, and dragging one onto another reorders the row.
    private var namingSection: some View {
        PanelSection("Naming", key: "exportNaming", menu: { AnyView(
            Group {
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
            }
        ) }) {
            Well {
                VStack(alignment: .leading, spacing: 7) {
                    labelled("Format") { tokenRow }
                    labelled("Sample") {
                        Text(sampleName)
                            .font(Theme.Font.listItem)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var tokenRow: some View {
        HStack(spacing: Theme.Metric.Export.tokenSpacing) {
            ForEach(recipe.wrappedValue.naming.chips) { t in tokenChip(t) }
        }
    }

    private func tokenChip(_ t: NameToken) -> some View {
        let on = recipe.wrappedValue.naming.isOn(t)
        let last = recipe.wrappedValue.naming.tokens.count == 1
        return Text(t.label)
            .font(Theme.Font.tab)
            .foregroundStyle(on ? Theme.card : Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: Theme.Metric.Export.tokenHeight)
            .background(on ? Theme.accent : Theme.field, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                var n = recipe.wrappedValue.naming
                n.toggle(t)
                recipe.wrappedValue.naming = n
            }
            // Only the last one on refuses to go off (`NamingRule.toggle`), so
            // the chip says so rather than looking broken.
            .help(on && last ? "A filename needs at least one part"
                  : (on ? "Remove \(t.label) from the filename" : "Add \(t.label) to the filename"))
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
        PanelSection("Format and Size", key: "exportFormat", menu: { AnyView(
            Group {
                Button("Set to Original Size") { recipe.wrappedValue.outputSize = .original }
                    .disabled(recipe.wrappedValue.outputSize.isOriginal)
                Divider()
                openWithMenu
            }
        ) }) {
            Well {
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Format").font(Theme.Font.label).foregroundStyle(Theme.text)
                            .frame(width: Theme.Metric.Export.labelWidth, alignment: .leading)
                        PillField(title: recipe.wrappedValue.format.shortLabel) {
                            ForEach(ExportFormat.allCases) { f in
                                Button(f.shortLabel) { recipe.wrappedValue.format = f }
                            }
                        }
                        depthPill.frame(width: 92)
                    }
                    .frame(height: Theme.Metric.rowHeight)
                    if recipe.wrappedValue.format.takesColorSpace {
                        PillMenu(label: "Color Space", options: ColorSpaceCatalog.all.map(\.space),
                                 title: { ColorSpaceCatalog.name(for: $0) ?? "Unknown profile" },
                                 selection: recipe.colorSpace,
                                 labelWidth: Theme.Metric.Export.labelWidth)
                    }
                    if recipe.wrappedValue.format.takesQuality {
                        ScrubSlider(label: "Quality", sublabel: nil,
                                    value: recipe.quality, range: 0.3...1, snap: 0.01,
                                    format: { String(format: "%.0f %%", $0 * 100) },
                                    onCommit: { store.save() })
                    }
                    sizeRow
                    openWithRow
                    if let note = sizeNote { caption(note, warning: true) }
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
            Text("Size").font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.Export.labelWidth, alignment: .leading)
            numberField(.width)
            Text("×").font(Theme.Font.label).foregroundStyle(Theme.dim)
            numberField(.height)
            Spacer(minLength: 0)
            Menu {
                Button("Set to Original Size") { recipe.wrappedValue.outputSize = .original }
                    .disabled(recipe.wrappedValue.outputSize.isOriginal)
                Divider()
                openWithMenu
            } label: {
                EllipsisGlyph().frame(width: 15, height: 3).padding(6).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Size options")
        }
        .frame(height: Theme.Metric.rowHeight)
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
            .font(Theme.Font.value).foregroundStyle(Theme.text)
            .frame(width: 64, height: 16)
            .background(Theme.field, in: Capsule())
    }

    /// `notes.md`: "Open with allows the user to select the default open_app."
    private var openWithRow: some View {
        HStack(spacing: 6) {
            Text("Open With").font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.Export.labelWidth, alignment: .leading)
            PillField(title: recipe.wrappedValue.openWith?.name ?? "None") {
                openWithItems
            }
        }
        .frame(height: Theme.Metric.rowHeight)
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
        PanelSection("Summary", key: "exportSummary", initiallyExpanded: false, menu: { AnyView(
            Button("Copy Summary") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summaryLines.joined(separator: "\n"), forType: .string)
            }
        ) }) {
            Well {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summaryLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - the footer

    /// Not in the reference, which draws the panel's lower third empty — but a
    /// page that cannot start an export is not a page. It sits where that
    /// empty space is, and carries the progress and the result the old sheet's
    /// footer carried.
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
        .padding(.horizontal, Theme.Metric.wellInset + 4)
        .padding(.vertical, 10)
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
            .foregroundStyle(warning ? Theme.accent : Theme.secondaryText)
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
        let avail = CGSize(width: max(1, paneSize.width - Theme.Metric.Export.proofInset * 2),
                           height: max(1, paneSize.height - Theme.Metric.Export.proofInset * 2 - 44))
        let s = min(avail.width / w, avail.height / h, 1)
        return CGSize(width: (w * s).rounded(), height: (h * s).rounded())
    }

    /// RFC-018 §6's three statements in one place: which space the proof is in
    /// and that the canvas is in another, what the destination could not hold,
    /// and whether this is a proof at all. The middle one is proportional on
    /// purpose — "a saturated frame into sRGB is worth a word, a frame that
    /// fits is worth silence" — so it is absent when the frame fits.
    @ViewBuilder private var proofCaption: some View {
        if let proof, session.selection != nil {
            VStack(spacing: 3) {
                if proof.isPlaceholder {
                    Text("Placeholder — the destination transform is not in this build, so these pixels "
                         + "are the old Display P3 render converted by the system, which clips what it "
                         + "cannot hold.")
                        .foregroundStyle(Theme.accent)
                }
                ForEach(ProofCaveat.lines(for: proof), id: \.text) { caveat in
                    Text(caveat.text)
                        .foregroundStyle(caveat.isWarning ? Theme.accent : Theme.secondaryText)
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

    /// The size stated here is the *proof's*, read off the proof's own pixels,
    /// and not `SoftProof.exportPixelSize` — which is the number meant to be
    /// said and is the wrong one today, because the placeholder body fills it
    /// from the preview render the proof was made out of. Naming a size the
    /// picture on screen does not have would be a small lie in the one place
    /// this page exists to be honest; the recipe's own size is stated in the
    /// Size row and the Summary instead.
    private func spaceLine(_ proof: SoftProof) -> String {
        let canvas = "the canvas is showing \(ColorSpaceCatalog.name(for: .displayP3) ?? "Display P3")"
        return "Proof in \(proof.targetName) · \(proof.image.width) × \(proof.image.height) px · \(canvas)"
    }

    /// Grid mode is the editor's own Browse grid from `Windows/BrowseView.swift`
    /// — the same cells, thumbnails and badges — with this page's selection
    /// rule layered on through `BrowseCell.chosen`.
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
            LazyVStack(alignment: .center, spacing: 18) {
                ForEach(session.frames) { frame in
                    ExportStripCell(frame: frame,
                                    chosen: targets.contains(frame.id),
                                    state: session.frameStates[frame.id] ?? .unprocessed)
                        .onTapGesture { tap(frame) }
                }
            }
            .padding(.horizontal, Theme.Metric.wellInset + 4)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .frame(width: Theme.Metric.Export.rightWidth)
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
    /// the way back.
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

    /// What the file will actually measure. `Exporter` writes the frame at its
    /// own size and has no resize step — it belongs to the pixels stream
    /// (RFC-018 §8) — so a recipe asking for another size says so here rather
    /// than quietly writing something else.
    private var sizeNote: String? {
        guard case .custom(let w, let h) = recipe.wrappedValue.outputSize else { return nil }
        let original = nameContext.pixelSize
        guard original.width > 1 else { return nil }
        return "This recipe asks for \(w) × \(h) px. The export writes the frame at its own size "
            + "(\(Int(original.width)) × \(Int(original.height)) px): `Exporter` has no resize step yet, "
            + "so that is what the files will measure."
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

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.Export.labelWidth, alignment: .leading)
            content()
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func caption(_ text: String, warning: Bool = false) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(warning ? Theme.accent : Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
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
/// not two, and an unchosen cell draws neither.
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
                .frame(maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.selectionFrame, lineWidth: chosen ? 2 : 0))
                badge.padding(5).opacity(chosen ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            if chosen {
                Text(frame.name).font(Theme.Font.caption).foregroundStyle(Theme.text)
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
    var help: String?
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        Menu { menu() } label: {
            HStack {
                Text(title).font(Theme.Font.label)
                    .foregroundStyle(dimmed ? Theme.dim : Theme.text).padding(.leading, 12)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(dimmed ? Theme.dim : Theme.text).padding(.trailing, 8)
            }
            .frame(height: 14)
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
