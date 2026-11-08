//  MacExportPage.swift — the Mac's one Export page, for the library's chosen pictures and for Develop.
//
//  The owner, 2026-10-24: "Export is simply the existing export page (the one Develop opens: the
//  picture on the left, the panel on the right …), but: move the controls to the left (unified), reuse
//  the library preview code, and sequential batch export should also be there."
//
//  - **Two ways in, one page.** The library's Export icon (the sidebar's tab bar) brings the chosen
//    pictures, in the grid's order (`MacLibraryPage`'s cover, `init(store:images:done:)`); Develop's
//    Export button brings its frame (`SheetRoute.export`, which on the Mac is this page instead of the
//    window's sheet: `SheetHost`, `init(frameIDs:done:)`). A picture of a catalog, a session or a folder
//    that is not a frame yet becomes one here, read in place, as Develop makes it (`frames(for:)`).
//  - **The controls at the left**, in the develop column's width, as the Mac library's sidebar and the
//    Mac develop page keep theirs: the window sheet's own rows, unchanged — Recipe (`RecipeChips`, every
//    chip whole), Format, Size (its page, pushed in the column), Colour, Quality, Save to — then the
//    batch's progress and the button.
//  - **The library's preview at the right**: `BrowserViewerSplit` for the picture in front, and beside it,
//    when there are several, the chosen pictures as the library's grid (`MacGridCell`) to step through
//    (a click, ← →), with the library's viewer switch (2026-10-25). Every picture is drawn developed, as
//    the canvas has it (`MacShownFrame`). While a batch runs the viewer follows the picture under way, and
//    each cell says how its picture went.
//  - **A batch is one picture at a time, in order** (`MacExportRun`): "3 of 12", Stop, a picture that
//    cannot be read said on its line while the rest go on, each developed again from its original.
//  - **Save to Files is a folder, chosen once** (Finder's open panel, kept for the next batch); each file
//    goes in as its picture finishes. Share hands the batch's files to the system's sheet at the end.
//
//  The window's and the reference device's Export sheet are as they were: this file is the Mac's alone.

import SwiftUI
import UniformTypeIdentifiers

struct MacExportPage: View {
    /// One picture of the page: the library's row (or a frame's, made into one), its frame, and why it has
    /// none where it has none.
    struct Picture: Identifiable, Equatable {
        let id: Int
        let image: MacImage
        let frameID: LibraryFrame.ID?
        var why: String?
    }

    private let store: (any MacLibraryData)?
    private let images: [MacImage]
    private let frameIDs: [LibraryFrame.ID]
    /// Closes the page.
    let done: () -> Void

    /// The library's way in: the chosen pictures, in the grid's order.
    init(store: any MacLibraryData, images: [MacImage], done: @escaping () -> Void) {
        self.store = store
        self.images = images
        self.frameIDs = []
        self.done = done
    }

    /// Develop's way in (and Exporting's): frames of the app's library.
    init(frameIDs: [LibraryFrame.ID], done: @escaping () -> Void) {
        self.store = nil
        self.images = []
        self.frameIDs = frameIDs
        self.done = done
    }

    /// The app's objects, for a way in that does not hand them on: a full-screen cover is a hosting
    /// controller of its own, and the library's cover gives the page none ("No Observable object of type
    /// FrameCatalog", the first run of `--export-check`, 2026-10-24). The root's `SheetHost` sets it.
    @MainActor static weak var app: AppServices?

    var body: some View {
        let loader = MacExportLoader(store: store, images: images, frameIDs: frameIDs, done: done)
        if let app = Self.app { loader.appEnvironment(app) } else { loader }
    }

    /// The library's chosen pictures as frames, made for those without (read in place); one whose file is
    /// not there is left out of the batch and says why.
    static func resolve(_ images: [MacImage], in store: any MacLibraryData) async throws -> [Picture] {
        let made = try await store.frames(for: images.map(\.id), focus: nil).frames
        return images.enumerated().map { i, image in
            let frame = made[image.id]
            // Its disk away, its file gone, or a file the app cannot make a frame of: the line says which.
            let why: String? = frame != nil ? nil
                : image.isOffline ? L("Not connected")
                : !FileManager.default.fileExists(atPath: image.url.path) ? L("Original missing")
                : L("This picture cannot be opened")
            return Picture(id: i, image: image, frameID: frame, why: why)
        }
    }

    /// Frames of the app's library as the page's pictures (the library's own row for each).
    static func pictures(_ ids: [LibraryFrame.ID], in library: FrameCatalog) -> [Picture] {
        ids.compactMap { library.frame($0) }.enumerated().map { i, f in
            Picture(id: i, image: CatalogSourcesStore.row(f, source: CatalogSourcesStore.appLibraryID), frameID: f.id)
        }
    }
}

/// Finds the page's pictures (the library's become frames here), then shows the page.
private struct MacExportLoader: View {
    let store: (any MacLibraryData)?
    let images: [MacImage]
    let frameIDs: [LibraryFrame.ID]
    let done: () -> Void
    typealias Picture = MacExportPage.Picture

    @Environment(FrameCatalog.self) private var library
    @State private var pictures: [Picture]?
    @State private var refusal: String?

    var body: some View {
        Group {
            if let pictures {
                MacExportScreen(pictures: pictures, refusal: refusal, done: done)
            } else {
                ZStack {
                    Theme.background
                    ProgressView().tint(Theme.secondaryText)
                }
                .ignoresSafeArea()
            }
        }
        .task {
            guard pictures == nil else { return }
            if let store {
                do { pictures = try await MacExportPage.resolve(images, in: store) } catch {
                    refusal = error.localizedDescription
                    pictures = images.enumerated().map { Picture(id: $0, image: $1, frameID: nil, why: nil) }
                }
            } else {
                pictures = MacExportPage.pictures(frameIDs, in: library)
            }
            #if DEBUG
            MacExportCheck.pageShown(pictures?.count ?? 0)
            #endif
        }
    }
}

/// The page itself, once its pictures are known.
private struct MacExportScreen: View {
    let pictures: [MacExportPage.Picture]
    let refusal: String?
    let done: () -> Void

    @Environment(FrameCatalog.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(ExportService.self) private var exporter
    @Environment(ExportRecipeStore.self) private var recipes
    @Environment(AppServices.self) private var model

    /// The recipe being made; nil until it is changed, which reads the last one (as the sheet does).
    @State private var recipe: ExportRecipe?
    /// The picture in front (the viewer's); nil after a click on the grid's empty space.
    @State private var focus: Int? = 0
    /// The viewer beside the grid, or the grid alone (the library's switch); kept for the next batch.
    @AppStorage("mac.export.viewerShown") private var viewerShown = true
    /// The cells' size, Mac points, as the library's slider sets its own.
    @State private var cell: Double = 150
    /// Frames whose develop this page has asked for (`want`): asked once.
    @State private var asked: Set<LibraryFrame.ID> = []
    @State private var choosingSize = false
    @State private var picking = false
    /// The folder was asked for by Export: the batch begins once it is chosen.
    @State private var startsAfterPicking = false
    @State private var folder: URL? = MacExportFolder.saved()
    @State private var sharing: [URL] = []

    private var run: MacExportRun { .shared }
    private var frames: [LibraryFrame] { pictures.compactMap { $0.frameID.flatMap { library.frame($0) } } }
    /// A batch under way, this page's or one it was opened over (Develop's Exporting).
    private var busy: Bool { run.isRunning || exporter.isExporting }

    var body: some View {
        let binding = Binding(get: { recipe ?? opening }, set: { recipe = $0 })
        HStack(spacing: 0) {
            column(binding)
                .frame(width: WindowLayout.columnWidth)
            Rectangle().fill(Theme.wall).frame(width: 1).ignoresSafeArea()
            preview
        }
        .background(Theme.background.ignoresSafeArea())
        .appColorScheme()
        .background { keys }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            let begins = startsAfterPicking
            startsAfterPicking = false
            guard case .success(let url) = result else { return }
            folder = url
            MacExportFolder.remember(url)
            if begins { start(binding.wrappedValue, folder: url) }
        }
        .sheet(isPresented: Binding(get: { !sharing.isEmpty }, set: { if !$0 { sharing = [] } })) {
            SystemShareSheet(items: sharing).ignoresSafeArea()
        }
        .onAppear {
            if !run.isRunning { run.reset() }
            if let i = followed { focus = i }
            #if DEBUG
            // `--export-check`: the check presses this page's own Export, with its recipe and folder.
            MacExportCheck.attach { r, f in
                recipe = r
                if let f { folder = f }
                start(r, folder: f)
            }
            #endif
        }
        // While a batch runs the viewer shows the picture under way.
        .onChange(of: run.current?.frameID) { _, _ in if let i = followed { focus = i } }
        .onChange(of: run.isRunning) { was, now in
            guard was, !now, run.recipe?.destination == .share, !run.shareFiles.isEmpty else { return }
            sharing = run.shareFiles
        }
    }

    private var followed: Int? {
        guard run.isRunning, let id = run.current?.frameID else { return nil }
        return pictures.firstIndex { $0.frameID == id }
    }

    /// What the page opens with: the last recipe, and as the saved recipe it is where it still makes
    /// what one of them makes, so that chip is lit (`ExportRecipe.opening`).
    private var opening: ExportRecipe {
        var r = ExportRecipe.opening(settings.recipe)
        if let saved = recipes.saved(as: r)
            ?? recipes.recipes.first(where: { ExportRecipe.opening($0).sameSettings(as: r) }) {
            r.id = saved.id
            r.title = saved.title
        }
        return r
    }

    // MARK: the column

    private func column(_ recipe: Binding<ExportRecipe>) -> some View {
        ZStack {
            if choosingSize {
                ExportSizePage(frames: frames, size: recipe.size, backTitle: L("Export")) {
                    withAnimation(.snappy(duration: 0.3)) { choosingSize = false }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            } else {
                VStack(spacing: 0) {
                    header
                    ScrollView(.vertical) {
                        controls(recipe)
                            .disabled(busy)
                            .opacity(busy ? 0.55 : 1)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    footer(recipe.wrappedValue)
                }
                .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Export")).font(Theme.Font.sheetTitle).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.Font.sheetSub).foregroundStyle(Theme.dim)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Closing during a batch leaves it running, as the window's Exporting sheet does.
            CloseButton(action: done).accessibilityLabel(L("Close"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func controls(_ recipe: Binding<ExportRecipe>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(L("Recipe")).padding(.horizontal, 20).padding(.top, 6)
            RecipeChips(recipe: recipe, admit: { ExportRecipe.opening($0) }, wraps: true)
                .padding(.top, 10)
            GroupBox(radius: 14) {
                ExportRow(label: L("Format"), height: 46) { FormatSwitch(recipe: recipe) }
                    .modifier(Separated())
                ExportSizeRow(size: recipe.wrappedValue.size, line: sizeLine(recipe.wrappedValue)) {
                    withAnimation(.snappy(duration: 0.3)) { choosingSize = true }
                }
                .modifier(Separated())
                ColourRow(recipe: recipe).modifier(Separated())
                QualityRow(recipe: recipe)
            }
            .padding(.horizontal, Theme.Metric.margin)
            .padding(.top, 18)
            SectionLabel(L("Save to")).padding(.horizontal, 20).padding(.top, 24)
            SegmentedSwitch(options: ExportRecipe.Destination.allCases, selection: recipe.destination,
                            title: \.shownTitle, height: 32, track: Theme.card)
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.top, 10)
            if recipe.wrappedValue.destination == .files {
                GroupBox(radius: 14) { folderRow }
                    .padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, 10)
            }
            Note(L("Every size develops again from the original. ")
                 + (FeatureFlags.backgroundFinish ? L("You can leave the app while it works.")
                                                  : L("Keep SpektraLab open while it works.")))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
    }

    /// The folder the batch goes into: chosen once, kept for the next.
    private var folderRow: some View {
        Button {
            startsAfterPicking = false
            picking = true
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Folder")).font(Theme.Font.ui(14, .semibold)).foregroundStyle(Theme.text)
                    // The whole place, in as many lines as it takes: never cut (2026-09-28, no "…").
                    Text(folder.map { MacExportFolder.place($0) } ?? L("Choose a Folder…"))
                        .font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Chevron()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        .accessibilityIdentifier("mac.export.folder")
    }

    // MARK: the batch and the button

    private func footer(_ recipe: ExportRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !run.lines.isEmpty || exporter.isExporting { progress }
            if let refusal {
                Text(L(shown: refusal)).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                CapsuleButton(title: L("Stop"), primary: false, height: 48) {
                    if run.isRunning { run.stop() } else { exporter.stop() }
                }
            } else {
                CapsuleButton(title: buttonTitle(recipe), height: 48, enabled: !frames.isEmpty) { start(recipe) }
            }
        }
        .padding(.horizontal, Theme.Metric.margin)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.wall).frame(height: 1) }
    }

    /// "Exporting  3 of 12", the bar, the picture under way; when it has ended, what it came to; and every
    /// picture that did not go, with why.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.isRunning ? L("Exporting") : summary)
                    .font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if run.isRunning { Text(run.countText).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.dim) }
            }
            ProgressView(value: run.lines.isEmpty ? 0 : run.fraction).tint(Theme.accent)
            if run.isRunning, let line = run.current {
                Text(line.name + Fmt.dot + words(line))
                    .font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.accent)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            ForEach(run.problems.prefix(5)) { line in
                Text(line.name + Fmt.dot + (line.problem ?? ""))
                    .font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if run.problems.count > 5 {
                Text(L("\(run.problems.count - 5) more")).font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.danger)
            }
            if run.isFinished, let folder = run.folder, run.saved > 0 {
                Button(L("Show in Finder")) { UIApplication.shared.open(folder) }
                    .font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    /// What a line under way is doing.
    private func words(_ line: MacExportRun.Line) -> String {
        switch line.state {
        case .waiting(let why): why.isEmpty ? L("Waiting its turn") : why
        case .running: L("Developing at \(ExportWords.size(run.recipe?.size ?? .full, capped: nil))")
        default: ""
        }
    }

    /// What the ended batch came to: "11 of 12 saved to Export." (the folder by its name: the Folder row
    /// above says where it is).
    private var summary: String {
        let made = run.saved, all = run.lines.count
        let stopped = run.wasStopped ? L("Stopped. ") : ""
        guard made > 0 else { return stopped + L("No file was made.") }
        if let folder = run.folder {
            let place = folder.lastPathComponent
            return stopped + (all == 1 ? L("Saved to \(place).") : L("\(made) of \(all) saved to \(place)."))
        }
        return stopped + (all == 1 ? L("The file is ready to share.") : L("\(made) of \(all) ready to share."))
    }

    /// "_DSC0061  ·  1 frame", "3 frames".
    private var subtitle: String {
        pictures.count == 1 ? (frames.first?.stem ?? pictures[0].image.fileName) + Fmt.dot + L("1 frame")
            : L("\(pictures.count) frames")
    }

    /// The file's real size, as the sheet's Size row says it (`FullExport.sizeLine`).
    private func sizeLine(_ recipe: ExportRecipe) -> String {
        guard frames.count == 1, let frame = frames.first else {
            return L("\(frames.count) frames, each at \(ExportWords.size(recipe.size, capped: nil))")
        }
        let out = exporter.outputSize(frame, recipe)
        let held: String = switch exporter.limit(frame, recipe) {
        case .device?: L(", this Mac's limit")
        case nil: ""
        }
        return out.text + Fmt.dot + Fmt.megapixels(out.megapixels) + held
    }

    /// "Export 12 MP", "Export" at full size, "Export 3" (the sheet's words).
    private func buttonTitle(_ recipe: ExportRecipe) -> String {
        if pictures.count > 1 { return L("Export \(frames.count)") }
        return recipe.size == .full ? L("Export") : L("Export \(ExportWords.short(recipe.size))")
    }

    /// Export: the batch, one picture at a time (`MacExportRun`). `chosen` is a folder just picked, before
    /// the page's own state has it.
    private func start(_ recipe: ExportRecipe, folder chosen: URL? = nil) {
        guard !frames.isEmpty else { return }
        let folder = chosen ?? self.folder
        // Files with no folder yet (or one that has gone): Finder's panel first, then the batch.
        if recipe.destination == .files, folder.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            startsAfterPicking = true
            picking = true
            return
        }
        settings.recipe = recipe
        let leftOut = pictures.compactMap { p -> MacExportRun.LeftOut? in
            p.why.map { .init(name: p.image.fileName, why: $0) }
        }
        run.start(frames.map(\.id), leftOut: leftOut, recipe: recipe, folder: folder, exporter: exporter)
    }

    // MARK: the preview

    /// The library's viewer and browser (the owner, 2026-10-25: "the way export preview works should be
    /// like the main library"): the picture in front large, and beside it the batch as the grid's cells,
    /// under a header with the library's switch (`MacViewerGlyph`) — the viewer put away, the grid takes
    /// the room. One picture is the viewer alone. Each picture is drawn developed, as the canvas has it
    /// (`MacShownFrame`); one with no develop yet has its develop asked as it comes into view, and wears
    /// the develop ring over its camera's preview until it lands (`want`).
    private var preview: some View {
        VStack(spacing: 0) {
            if pictures.count > 1 {
                previewHeader
                Rectangle().fill(Theme.wall).frame(height: 1)
                if viewerShown {
                    HStack(spacing: 0) {
                        viewer
                        Rectangle().fill(Theme.wall).frame(width: 1)
                        grid.frame(width: MacMetric.pt(MacLibraryBrowser.shared.browserWidth))
                    }
                } else {
                    grid
                }
            } else {
                viewer
            }
        }
        .onChange(of: focus, initial: true) { _, i in if let i, pictures.indices.contains(i) { want(pictures[i]) } }
        // The pictures as the recipe's colour space holds them (`CanvasGamut`): switching the recipe from
        // Display P3 to sRGB shows the sRGB file's colours before it is written (2.2.1).
        .environment(\.gamutProof, CanvasGamut((recipe ?? opening).colour))
    }

    private var viewer: some View {
        BrowserViewerSplit(image: focus.flatMap { pictures.indices.contains($0) ? pictures[$0].image : nil }, open: { _ in })
    }

    /// The switch, the count, the cells' size: the library's header, for the batch.
    private var previewHeader: some View {
        HStack(spacing: MacMetric.pt(8)) {
            Button { viewerShown.toggle() } label: { MacViewerGlyph(on: viewerShown) }
                .buttonStyle(.plain)
                .help(L("Viewer"))
                .accessibilityLabel(L("Viewer"))
                .accessibilityAddTraits(viewerShown ? .isSelected : [])
                .accessibilityIdentifier("mac.export.viewer")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L("\(pictures.count) frames")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                .fixedSize().layoutPriority(1)
            HStack(spacing: MacMetric.pt(5)) {
                Image(systemName: "photo").font(MacMetric.font(9)).foregroundStyle(Theme.dim)
                Slider(value: $cell, in: MacMetric.cellRange)
                    .frame(width: MacMetric.pt(100))
                    .controlSize(.mini)
                    .accessibilityLabel(L("Thumbnail Size"))
                Image(systemName: "photo").font(MacMetric.font(13)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, MacMetric.pt(10))
        .frame(height: MacMetric.pt(MacMetric.gridHeader))
        .background(Theme.panel)
    }

    /// The batch as the grid's cells, the one in front framed; each says how its export went. A click puts
    /// a picture in front; a click on the empty space puts none (as the library's grid, 2026-10-25).
    private var grid: some View {
        GeometryReader { geo in
            let layout = MacGridLayout(width: geo.size.width, cell: cell, count: pictures.count)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVGrid(columns: layout.items, alignment: .leading, spacing: layout.gap) {
                        ForEach(pictures) { p in
                            MacGridCell(image: p.image, side: layout.side, selected: p.id == focus, focused: p.id == focus)
                                .overlay(alignment: .topTrailing) { badge(p).padding(MacMetric.pt(8)) }
                                .modifier(MacClick { _ in focus = p.id })
                                .onAppear { want(p) }
                                .id(p.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(p.image.fileName)
                                .accessibilityAddTraits(p.id == focus ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { focus = p.id }
                                .accessibilityIdentifier("mac.export.cell")
                        }
                    }
                    .padding(layout.gap)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .modifier(MacEmptyClick(layout: layout) { focus = nil })
                }
                .scrollIndicators(.automatic)
                .onChange(of: focus) { _, i in
                    guard let i else { return }
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(i) }
                }
            }
        }
        .background(Theme.background)
    }

    /// A picture shown with no develop of its own, or with one its edit no longer makes: its develop,
    /// asked once, as the Light Table asks one for a film it lays down (`MacRenderCache.tableWants`). A
    /// frame with a develop page open on it has that page's (`MacShownFrame`); one the engine cannot read
    /// (its disk away) keeps its preview, and the develop is not queued (`AppServices.queueDevelop`).
    private func want(_ p: MacExportPage.Picture) {
        guard let id = p.frameID, !asked.contains(id), let f = library.frame(id), !f.isPair,
              model.darkroom.makesPictures, model.openSession(id) == nil, !f.develop.isBusy else { return }
        // A develop whose file is missing (`DevelopedPicture.isMissing`) is none.
        guard model.darkroom.needsDevelop(f) else { return }
        asked.insert(id)
        model.develop(id)
    }

    /// A cell's corner: under way, saved, not saved or never begun, stopped. Nothing before a batch, but
    /// for a picture that cannot go at all.
    @ViewBuilder private func badge(_ p: MacExportPage.Picture) -> some View {
        let state: MacExportRun.Line.State? = p.frameID.flatMap { run.line(for: $0)?.state } ?? p.why.map { .leftOut($0) }
        switch state {
        case .running(let progress)?:
            ProgressRing(progress: progress.fraction, diameter: MacMetric.pt(16), lineWidth: 2)
        case .saved?:
            Image(systemName: "checkmark.circle.fill").font(MacMetric.font(13)).foregroundStyle(Theme.accent)
        case .failed?, .leftOut?:
            Image(systemName: "exclamationmark.triangle.fill").font(MacMetric.font(12)).foregroundStyle(Theme.danger)
        case .stopped?:
            Image(systemName: "minus.circle.fill").font(MacMetric.font(13)).foregroundStyle(Theme.secondaryText)
        case .waiting?, nil:
            EmptyView()
        }
    }

    // MARK: keys

    /// Page actions commit focused fields first; arrows keep their normal text-editing guard.
    private var keys: some View {
        Group {
            HiddenKeyEquivalent(title: L("Previous"), key: .leftArrow, enabled: !choosingSize) { focus = max((focus ?? 1) - 1, 0) }
            HiddenKeyEquivalent(title: L("Next"), key: .rightArrow, enabled: !choosingSize) {
                focus = min((focus ?? -1) + 1, pictures.count - 1)
            }
        }
        .macPageActions(confirmTitle: L("Export"), confirmEnabled: !choosingSize && !busy && !frames.isEmpty,
                        cancelEnabled: !choosingSize, confirm: { start(recipe ?? opening) }, cancel: done)
        .accessibilityHidden(true)
    }
}

/// The hairline under a row of the box, as the sheet draws it (`ExportSheet`'s `separated`).
private struct Separated: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) { RowSeparator(leading: 14).offset(y: 0.5) }
    }
}
