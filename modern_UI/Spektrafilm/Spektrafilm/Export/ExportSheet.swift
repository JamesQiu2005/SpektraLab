//  ExportSheet.swift — the export page: recipes on the left, what the chosen
//  one does on the right.
//
//  It replaces a radio group of four formats. The information architecture is
//  Capture One's (`PRD/export_page_reference_capture_one.png`) because that
//  is what the user asked to reference, and the *style* is this app's —
//  `PanelSection` headers, `Well` grounds, `PillMenu` pills, `Theme` tokens,
//  nothing drawn with a literal colour. The reference's centre image pane is
//  deliberately not reproduced: the canvas behind this sheet is already
//  showing the frame at the grade being exported, and a second, smaller copy
//  of it inside the sheet would be a worse view of the same thing.
//
//  The model is in `ExportRecipe.swift` — including the JSON file the
//  recipes live in, which the PRD asked for by name. This file is the view
//  and nothing else: everything it writes goes through `ExportRecipeStore`,
//  so the file on disk and the sheet cannot disagree.

import AppKit
import SwiftUI

struct ExportSheet: View {
    @Bindable var session: Session
    @State private var store = ExportRecipeStore()
    @State private var running = false
    @State private var result: String?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    /// The selected recipe, written straight back through the store so every
    /// edit is saved. There is no "apply" button on purpose — a recipe is a
    /// saved preference, and a preference that needs confirming is one people
    /// lose.
    private var recipe: Binding<ExportRecipe> {
        Binding(get: { store.selected ?? ExportRecipe() },
                set: { store.selected = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                recipeRail.frame(width: 236)
                Divider().overlay(Theme.ground)
                settings.frame(width: 352)
            }
            .frame(height: 486)
            footer
        }
        .frame(width: 590)
        .background(Theme.card)
        .preferredColorScheme(.dark)
    }

    // MARK: - the recipes

    private var recipeRail: some View {
        VStack(spacing: 0) {
            Text("Export recipes")
                .font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Metric.wellInset + 4)
                .padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(store.recipes) { r in recipeRow(r) }
                }
                .padding(.horizontal, Theme.Metric.wellInset)
            }
            Spacer(minLength: 0)
            // The file is the format of record, so it is reachable from here
            // rather than only from a support article.
            HStack(spacing: 6) {
                railButton("plus", "New recipe") { store.add() }
                railButton("minus", "Delete recipe") {
                    if let s = store.selected { store.remove(s) }
                }
                .disabled(store.recipes.count < 2)
                .opacity(store.recipes.count < 2 ? 0.4 : 1)
                railButton("plus.square.on.square", "Duplicate recipe") {
                    if let s = store.selected { store.duplicate(s) }
                }
                Spacer()
                railButton("folder", "Reveal export-recipes.json in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.url])
                }
            }
            .padding(.horizontal, Theme.Metric.wellInset + 4)
            .padding(.vertical, 10)
        }
    }

    private func recipeRow(_ r: ExportRecipe) -> some View {
        let on = r.id == (store.selected?.id)
        return Button { store.selectedID = r.id } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(on ? Theme.accent : Theme.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).font(Theme.Font.listItem).foregroundStyle(Theme.text).lineLimit(1)
                    Text(r.format.rawValue).font(Theme.Font.caption).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Theme.well : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func railButton(_ glyph: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - what the recipe does

    private var settings: some View {
        ScrollView {
            VStack(spacing: 0) {
                nameSection
                locationSection
                namingSection
                formatSection
                summarySection
            }
            .padding(.top, 10)
        }
    }

    private var nameSection: some View {
        PanelSection("Recipe", systemImage: "square.stack", key: "exportRecipe") {
            Well {
                labelled("Name") {
                    TextField("", text: recipe.name)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.label).foregroundStyle(Theme.text)
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .background(Theme.field, in: Capsule())
                        .onSubmit { store.save() }
                }
            }
        }
    }

    private var locationSection: some View {
        PanelSection("Location", systemImage: "folder", key: "exportLocation") {
            Well {
                VStack(spacing: 4) {
                    labelled("Folder") {
                        HStack(spacing: 6) {
                            Text(folderLabel).font(Theme.Font.label).foregroundStyle(Theme.text)
                                .lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(height: 16)
                                .background(Theme.field, in: Capsule())
                            Button("Choose…") { chooseFolder() }
                                .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                            if case .fixed = recipe.wrappedValue.folder {
                                Button("Reset") { recipe.wrappedValue.folder = .besideOriginal }
                                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.dim)
                                    .help("Write beside the original frame instead")
                            }
                        }
                    }
                    labelled("Subfolder") {
                        TextField("none", text: recipe.subfolder)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, 8)
                            .frame(height: 16)
                            .background(Theme.field, in: Capsule())
                            .onSubmit { store.save() }
                    }
                    PillMenu(label: "Existing", options: ExistingFilePolicy.allCases,
                             title: { $0.label }, selection: recipe.existing)
                    caption(samplePath)
                }
            }
        }
    }

    /// The token row and its sample. The sample is the control's whole
    /// justification: a naming scheme you cannot see the result of is one you
    /// find out about after the batch.
    private var namingSection: some View {
        PanelSection("Naming", systemImage: "textformat", key: "exportNaming") {
            Well {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Format").font(Theme.Font.label).foregroundStyle(Theme.text)
                            .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
                        tokenFlow
                    }
                    labelled("Separator") {
                        TextField("_", text: recipe.naming.separator)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.label).foregroundStyle(Theme.text)
                            .padding(.horizontal, 8)
                            .frame(width: 60, height: 16)
                            .background(Theme.field, in: Capsule())
                            .onSubmit { store.save() }
                        Spacer()
                    }
                    caption("Sample  " + sampleName)
                }
            }
        }
    }

    /// Every token is a toggle. Order follows the order they are switched on,
    /// which is the simplest rule that is also predictable — and it is
    /// visible in the sample underneath, so it never has to be guessed at.
    private var tokenFlow: some View {
        HStack(spacing: 4) {
            ForEach(NameToken.allCases) { t in
                let on = recipe.wrappedValue.naming.tokens.contains(t)
                Button {
                    var tokens = recipe.wrappedValue.naming.tokens
                    if let i = tokens.firstIndex(of: t) { tokens.remove(at: i) } else { tokens.append(t) }
                    recipe.wrappedValue.naming.tokens = tokens
                } label: {
                    Text(t.label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(on ? Theme.card : Theme.text)
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(on ? Theme.accent : Theme.field, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(on ? "Remove \(t.label) from the filename" : "Add \(t.label) to the filename")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formatSection: some View {
        PanelSection("Format and colour", systemImage: "doc", key: "exportFormat") {
            Well {
                VStack(spacing: 4) {
                    PillMenu(label: "Format", options: ExportFormat.allCases,
                             title: { $0.rawValue }, selection: recipe.format)
                    if recipe.wrappedValue.format.takesColorSpace {
                        PillMenu(label: "Colour space", options: ColorSpaceCatalog.all.map(\.space),
                                 title: { ColorSpaceCatalog.name(for: $0) ?? "Unknown profile" },
                                 selection: recipe.colorSpace)
                    }
                    if recipe.wrappedValue.format.takesQuality {
                        ScrubSlider(label: "Quality", sublabel: nil,
                                    value: recipe.quality, range: 0.3...1, snap: 0.01,
                                    format: { String(format: "%.0f %%", $0 * 100) },
                                    onCommit: { store.save() })
                    }
                    caption(recipe.wrappedValue.format.note)
                    if recipe.wrappedValue.format.isEightBit,
                       recipe.wrappedValue.colorSpace != .sRGB {
                        caption("8-bit in a wide-gamut space bands in smooth gradients. sRGB is the safer tag for a JPEG or PNG that will be looked at on someone else's screen.")
                    }
                    if recipe.wrappedValue.format == .di {
                        caption("Photoshop: open the TIFF, add a Color Lookup adjustment layer, load the .cube. Capture One cannot load .cube; convert it to an ICC (see docs). The DI file carries no rendering profile on purpose, so there is no colour space to choose.")
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        PanelSection("Summary", systemImage: "list.bullet", key: "exportSummary") {
            Well {
                VStack(alignment: .leading, spacing: 3) {
                    summaryRow("Recipe", recipe.wrappedValue.name)
                    summaryRow("File name", sampleName + "." + recipe.wrappedValue.format.ext)
                    summaryRow("Size", dimensions)
                    summaryRow("Colour space", recipe.wrappedValue.format.takesColorSpace
                               ? (ColorSpaceCatalog.name(for: recipe.wrappedValue.colorSpace) ?? "Unknown profile")
                               : "untagged (density)")
                }
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label).font(Theme.Font.caption).foregroundStyle(Theme.dim)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            Text(value).font(Theme.Font.caption).foregroundStyle(Theme.text)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: - footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let problem = store.problem {
                message(problem, warning: true)
            }
            if let result {
                message(result, warning: failed)
            }
            HStack(spacing: 8) {
                if running, let p = session.exportProgress {
                    ProgressView(value: p).controlSize(.small).frame(width: 90)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(running ? "Exporting…" : "Export") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || session.selection == nil || store.selected == nil)
            }
        }
        .padding(.horizontal, Theme.Metric.wellInset + 4)
        .padding(.vertical, 12)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.ground).frame(height: 1) }
    }

    private func message(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(warning ? Theme.accent : Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - helpers

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            content()
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption).foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private var folderLabel: String {
        switch recipe.wrappedValue.folder {
        case .besideOriginal: "Beside the original"
        case .fixed(let p): p
        }
    }

    /// The naming context for the *current* frame where there is one, and the
    /// model sample where there is not — so the sheet shows a real filename
    /// rather than a placeholder whenever it can.
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

    private var sampleName: String { recipe.wrappedValue.naming.stem(nameContext) }

    private var dimensions: String {
        let s = nameContext.pixelSize
        guard s.width > 1 else { return "—" }
        let mp = Double(s.width * s.height) / 1_000_000
        return String(format: "%d × %d px  ·  %.1f MP", Int(s.width), Int(s.height), mp)
    }

    private var samplePath: String {
        let source = session.selection ?? URL(fileURLWithPath: "/Users/you/Pictures/_DSC4037.NEF")
        return recipe.wrappedValue.directory(for: source).path
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

    private func run() {
        guard let r = store.selected else { return }
        running = true
        result = nil
        failed = false
        Task {
            defer { running = false }
            guard let sid = await session.currentServiceSession() else {
                result = "The frame is still developing."
                failed = true
                return
            }
            do {
                session.exportProgress = 0
                let out = try await Exporter.export(session: session, recipe: r,
                                                    context: nameContext, sessionID: sid)
                session.exportProgress = nil
                switch out {
                case .skipped(let url):
                    result = "\(url.lastPathComponent) already exists; this recipe is set to skip."
                    failed = true
                case .wrote(let urls, let note, let fellBack):
                    var text = "Wrote " + urls.map(\.lastPathComponent).joined(separator: ", ")
                    if fellBack {
                        text += "\nThe chosen profile could not be resolved on this machine; the file was tagged Display P3 instead."
                    }
                    if let note { text += "\n\(note)" }
                    result = text
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            } catch {
                session.exportProgress = nil
                result = EngineMessage.userFacing(error)
                failed = true
            }
        }
    }
}
