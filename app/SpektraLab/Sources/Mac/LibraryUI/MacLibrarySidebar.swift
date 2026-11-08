//  MacLibrarySidebar.swift — the navigator: Xcode's frame, Capture One's contents
//  (design/MAC-LIBRARY-UI.md §3). It reads one `MacLibraryData`.
//
//  - **Tabs** across the top (Xcode's navigator bar): Library, Filters, Info; ⌘1 ⌘2 ⌘3; at its right
//    Import and Export (the chosen pictures).
//  - **Library**: the source picker (each catalog, session and folder: the SpektraLab Library is the
//    person's catalogs since 2026-10-24, `MacLibraryMove`), then the
//    store's tree with its counts: Catalog Collections (All Images, Recent Imports ▸ each import, …),
//    User Collections, Folders. A row's right click opens its pictures in Develop, the strip theirs.
//  - **Filters**: the store's facets, each value a checkmark row with its count. Within a facet any value
//    matches; across facets all must (the store's query).
//  - **Info**: the chosen picture's metadata as label/value rows.
//  - **The bottom bar** (Xcode's): "+" (Open Catalog or Folder…, Import…) and a Filter field that
//    narrows the rows of the tab shown.
//
//  Rows are 24 Mac points with 13-pt text, counts in `dim`; the chosen row wears v2's white capsule.
//  No text is cut short: a long name wraps and its row grows.

import SwiftUI
import UniformTypeIdentifiers

struct MacLibrarySidebar: View {
    let store: any MacLibraryData
    let browser: MacLibraryBrowser
    let rows: [MacImage]
    let openSettings: (SettingsPage?) -> Void
    let open: (MacImage) -> Void
    /// A collection's pictures into Develop, its filmstrip theirs (a right click on its row).
    let openCollection: (MacCollection) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model
    @FocusState private var filtering: Bool
    @State private var picking = false
    @State private var refusal: String?

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Rectangle().fill(Theme.wall).frame(height: 1)
            Group {
                switch browser.navigator {
                case .library: libraryPane
                case .filters: filtersPane
                case .info: infoPane
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // The library's activity line; a paste onto pictures not open says it here too (`notice`).
            if let line = store.activity.working ?? store.activity.problem ?? MacLibraryActions.shared.notice?.line {
                Text(L(shown: line)).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MacMetric.pt(10)).padding(.vertical, MacMetric.pt(4))
            }
            // The previews under way (a paste's, the Light Table's, Export's): how many, and Stop
            // (2026-11-05). Their tiles carry the ring; stopped, they keep the old preview, marked.
            if library.developingCount > 0 { developingLine }
            Rectangle().fill(Theme.wall).frame(height: 1)
            bottomBar
        }
        .background(Theme.panel.ignoresSafeArea())
        .onChange(of: filtering) { _, on in browser.typing = on }
        #if DEBUG
        // `--settings-check` presses the "+" menu's Settings and Sources as the items do.
        .onAppear { MacSettingsCheck.plusMenu = (settings: plusSettings, sources: plusSources) }
        #endif
        .onChange(of: picking) { _, on in browser.sourcePickerShown = on }
        .alert(L("This library cannot be shown"), isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(refusal.map { L(shown: $0) } ?? "")
        }
    }

    private var developingLine: some View {
        let n = library.developingCount
        return HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(8)) {
            Text(n == 1 ? L("Developing 1 picture") : L("Developing \(n) pictures"))
                .font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Stop")) { MacLibraryActions.shared.stopPreviews(model: model) }
                .buttonStyle(.borderless).font(MacMetric.font(11))
        }
        .padding(.horizontal, MacMetric.pt(10)).padding(.vertical, MacMetric.pt(4))
    }

    /// The "+" menu's Settings and Sources: the Mac's Settings page, on its first section or on Sources.
    private func plusSettings() { openSettings(nil) }
    private func plusSources() { openSettings(.sources) }

    /// What "Open" may pick: a folder (a session, a Capture One session, any Finder folder), a Capture One
    /// catalog, a SpektraLab catalog. All go to the store's `open`: a Capture One catalog is never linked
    /// as a folder of frames.
    private func openSource() {
        guard !picking else { return }
        picking = true
        Task {
            defer { picking = false }
            guard let url = await MacOpenPanel.choose(multiple: false)?.first else { return }
            do { _ = try await store.open(url) } catch { refusal = error.localizedDescription }
        }
    }

    // MARK: the tabs

    private var tabs: some View {
        HStack(spacing: MacMetric.pt(2)) {
            ForEach(MacNavigator.allCases, id: \.self) { tab in
                let on = browser.navigator == tab
                Button { browser.navigator = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(MacMetric.font(14, on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.dim)
                        .frame(width: MacMetric.pt(32), height: MacMetric.pt(24))
                        .background {
                            if on { RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous).fill(Theme.card) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("mac.library.tab.\(tab.rawValue)")
            }
            Spacer(minLength: 0)
            // Import (a Finder panel, then the import page) and Export (the chosen pictures), 2026-10-24.
            barButton(L("Import"), "square.and.arrow.down", id: "mac.library.import") { browser.importAsked = true }
            barButton(L("Export"), "square.and.arrow.up", id: "mac.library.export") { browser.exportAsked = true }
                .disabled(browser.selection.isEmpty)
        }
        .padding(.horizontal, MacMetric.pt(8))
        .frame(height: MacMetric.pt(MacMetric.tabBar))
    }

    private func barButton(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(MacMetric.font(14))
                .foregroundStyle(Theme.dim)
                .frame(width: MacMetric.pt(28), height: MacMetric.pt(24))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    // MARK: Library

    private var libraryPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: MacMetric.pt(4)) {
                sourcePicker
                barButton(L("Open Catalog or Folder…"), "plus", id: "mac.library.add-source", action: openSource)
                    .disabled(picking || store.activity.working != nil)
            }
                .padding(.horizontal, MacMetric.pt(8))
                .padding(.vertical, MacMetric.pt(6))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The Light Table is entered from the grid's header (its loupe, beside the viewer), with the
                    // chosen pictures, for every source alike; it was a row here for the app library only.
                    ForEach(outline) { row in outlineRow(row) }
                }
                .padding(.bottom, MacMetric.pt(8))
            }
            .scrollIndicators(.automatic)
        }
    }

    private func sourceName(_ s: MacSource) -> String {
        switch s.kind {
        case .appLibrary: L("SpektraLab Library")
        case .captureOneCatalog, .catalog: L("Catalog: \(s.name)")
        case .captureOneSession, .session: L("Session: \(s.name)")
        case .folder: s.name
        }
    }

    /// What the selected source offers as a catalog: a Capture One catalog copied into a SpektraLab one;
    /// a copy updated from it (2026-10-24).
    @ViewBuilder private var catalogCommands: some View {
        if let s = store.selectedSource, s.kind == .captureOneCatalog {
            Button { run { await MacCatalogActions.copyToCatalog(store, s) } } label: {
                Label(L("Copy to SpektraLab Catalog…"), systemImage: "doc.on.doc")
            }
            .disabled(store.activity.working != nil)
        }
        if let s = store.selectedSource, s.isCopiedFromCaptureOne {
            Button { run { await MacCatalogActions.update(store, s) } } label: {
                Label(L("Update from Capture One"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(store.activity.working != nil)
        }
    }

    /// A catalog command, its refusal shown.
    private func run(_ body: @escaping () async -> String?) {
        Task { if let why = await body() { refusal = why } }
    }

    private var sourcePicker: some View {
        Menu {
            Picker(L("Library"), selection: Binding(get: { store.selectedSourceID }, set: { id in
                if let id { Task { await store.select(source: id) } }
            })) {
                ForEach(store.sources) { s in
                    // By what it is, never by whose file it is: a Capture One catalog is a catalog (2026-10-24).
                    Label(sourceName(s), systemImage: MacWords.symbol(s.kind))
                        .tag(Optional(s.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button { run { await MacCatalogActions.newCatalog(store) } } label: { Label(L("New Catalog…"), systemImage: "plus.rectangle.on.folder") }
            Button(action: openSource) { Label(L("Open Catalog or Folder…"), systemImage: "plus") }
            catalogCommands
        } label: {
            HStack(spacing: MacMetric.pt(5)) {
                Text(store.selectedSource.map(sourceName) ?? "")
                    .font(MacMetric.font(12, .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.activity.working != nil { ProgressView().controlSize(.mini) }
                Image(systemName: "chevron.up.chevron.down").font(MacMetric.font(9, .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, MacMetric.pt(8))
            .padding(.vertical, MacMetric.pt(4))
            .frame(minHeight: MacMetric.pt(24))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(L("Library"))
        .accessibilityValue(store.selectedSource?.name ?? "")
        .accessibilityIdentifier("mac.library.source")
    }

    private struct OutlineRow: Identifiable {
        enum Kind { case section(String, String), node(MacCollection) }
        let kind: Kind
        let depth: Int
        var id: String {
            switch kind {
            case .section(let id, _): id
            case .node(let c): c.id
            }
        }
    }

    /// The tree as rows under its three headings: folded headings and closed rows hide what is under them;
    /// the Filter field keeps the rows whose name holds its text, and the rows over them.
    private var outline: [OutlineRow] {
        let needle = browser.rowFilter.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ n: MacCollection) -> Bool {
            MacWords.title(n).lowercased().contains(needle) || n.children.contains(where: matches)
        }
        var out: [OutlineRow] = []
        func walk(_ list: [MacCollection], _ depth: Int) {
            for n in list {
                if !needle.isEmpty, !matches(n) { continue }
                out.append(OutlineRow(kind: .node(n), depth: depth))
                if !n.children.isEmpty, !needle.isEmpty || !browser.folded.contains(n.id) { walk(n.children, depth + 1) }
            }
        }
        let t = store.tree
        let fixedTitle = L("Catalog Collections")
        for (id, title, list) in [("section.fixed", fixedTitle, t.fixed), ("section.user", L("User Collections"), t.user),
                                  ("section.folders", L("Folders"), t.folders)] where !list.isEmpty {
            out.append(OutlineRow(kind: .section(id, title), depth: 0))
            if !browser.folded.contains(id) || !needle.isEmpty { walk(list, 0) }
        }
        return out
    }

    @ViewBuilder private func outlineRow(_ row: OutlineRow) -> some View {
        switch row.kind {
        case .section(let id, let title):
            SectionRow(title: title, folded: browser.folded.contains(id)) { fold(id) }
        case .node(let n):
            let on = store.selectedCollectionID == n.id
            SidebarLine(depth: row.depth, selected: on,
                        disclosure: n.children.isEmpty ? nil : !browser.folded.contains(n.id),
                        disclose: { fold(n.id) }) {
                Image(systemName: MacWords.symbol(n)).font(MacMetric.font(12)).foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
            } label: {
                Text(MacWords.title(n)).font(MacMetric.font(13)).foregroundStyle(on ? Theme.onSelection : Theme.text)
            } trailing: {
                if let c = Self.count(n) { Count(value: c, selected: on) }
            } action: {
                // A folder that holds only folders (a volume, "Users") opens and closes, in every catalog:
                // there is nothing of its own to show.
                if n.kind == .folder, !n.children.isEmpty, (n.imageCount ?? 0) == 0 { fold(n.id) }
                else { Task { await store.select(collection: n.id) } }
            }
            .rowEnabled(n.isSupported)
            .contextMenu {
                Button { openCollection(n) } label: { Label(L("Open in Develop"), systemImage: "slider.horizontal.3") }
                    .disabled(!n.isSupported || n.imageCount == 0)
            }
            .accessibilityIdentifier("mac.library.collection")
        }
    }

    /// Capture One's way with counts: none on Recent Imports and Recent Captures themselves, and no "0" on a
    /// folder that only holds folders.
    private static func count(_ n: MacCollection) -> Int? {
        switch n.kind {
        case .recentImports, .recentCaptures: return nil
        case .folder where !n.children.isEmpty && (n.imageCount ?? 0) == 0: return nil
        default: return n.imageCount
        }
    }

    private func fold(_ id: String) {
        if browser.folded.contains(id) { browser.folded.remove(id) } else { browser.folded.insert(id) }
    }

    // MARK: Filters

    /// The store's query, changed and applied.
    private func change(_ edit: (inout MacImageQuery) -> Void) {
        var q = store.query
        edit(&q)
        Task { await store.apply(q) }
    }

    private struct FacetRow: Identifiable {
        let id: String
        let title: String
        let count: Int
        let on: Bool
        var depth = 0
        /// A year that opens into its months: whether it is open.
        var opens: Bool? = nil
        var swatch: Color? = nil
        let toggle: () -> Void
    }

    private func facetGroups() -> [(id: String, title: String, rows: [FacetRow])] {
        let f = store.facets, q = store.query
        var groups: [(String, String, [FacetRow])] = []
        groups.append(("rating", L("Rating"), f.ratings.sorted { $0.value < $1.value }.map { v in
            FacetRow(id: "rating.\(v.value)", title: MacWords.rating(v.value), count: v.count, on: q.ratings.contains(v.value)) {
                change { $0.ratings.formSymmetricDifference([v.value]) }
            }
        }))
        groups.append(("colour", L("Colour Label"), f.colorLabels.sorted { $0.value < $1.value }.map { v in
            FacetRow(id: "colour.\(v.value)", title: MacWords.colorName(v.value), count: v.count, on: q.colorLabels.contains(v.value),
                     swatch: MacWords.color(v.value)) {
                change { $0.colorLabels.formSymmetricDifference([v.value]) }
            }
        }))
        var dates: [FacetRow] = []
        for y in f.years.sorted(by: { $0.value > $1.value }) {
            let from = "\(y.value)-01-01", to = "\((Int(y.value) ?? 0) + 1)-01-01"
            let open = browser.folded.contains("open.year.\(y.value)")
            dates.append(FacetRow(id: "year.\(y.value)", title: y.value, count: y.count, on: q.capturedFrom == from && q.capturedTo == to,
                                  opens: open) { change { Self.range(&$0, from, to) } })
            if open {
                for m in f.months.filter({ $0.value.hasPrefix(y.value + "-") }).sorted(by: { $0.value > $1.value }) {
                    let parts = m.value.split(separator: "-").compactMap { Int($0) }
                    guard parts.count == 2 else { continue }
                    let mFrom = String(format: "%04d-%02d-01", parts[0], parts[1])
                    let mTo = parts[1] == 12 ? String(format: "%04d-01-01", parts[0] + 1) : String(format: "%04d-%02d-01", parts[0], parts[1] + 1)
                    dates.append(FacetRow(id: "month.\(m.value)", title: MacWords.month(m.value), count: m.count,
                                          on: q.capturedFrom == mFrom && q.capturedTo == mTo, depth: 1) { change { Self.range(&$0, mFrom, mTo) } })
                }
            }
        }
        groups.append(("date", L("Date"), dates))
        groups.append(("camera", L("Camera"), f.cameras.map { v in
            FacetRow(id: "camera.\(v.value ?? "")", title: v.value ?? L("Unknown"), count: v.count, on: q.cameras.contains(v.value)) {
                change { $0.cameras.formSymmetricDifference([v.value]) }
            }
        }))
        groups.append(("lens", L("Lens"), f.lenses.map { v in
            FacetRow(id: "lens.\(v.value ?? "")", title: v.value ?? L("Unknown"), count: v.count, on: q.lenses.contains(v.value)) {
                change { $0.lenses.formSymmetricDifference([v.value]) }
            }
        }))
        groups.append(("kind", L("File Type"), f.kinds.map { v in
            let kind = MacImage.FileKind(rawValue: v.value)
            return FacetRow(id: "kind.\(v.value)", title: MacWords.kind(v.value), count: v.count, on: kind.map(q.kinds.contains) ?? false) {
                if let kind { change { $0.kinds.formSymmetricDifference([kind]) } }
            }
        }))
        if !f.keywords.isEmpty {
            groups.append(("keyword", L("Keywords"), f.keywords.map { v in
                FacetRow(id: "keyword.\(v.value)", title: v.value, count: v.count, on: q.keywords.contains(v.value)) {
                    change { $0.keywords.formSymmetricDifference([v.value]) }
                }
            }))
        }
        groups.append(("developed", L("SpektraLab"), [
            FacetRow(id: "developed", title: L("Opened in Develop"), count: f.developed, on: q.developedOnly) {
                change { $0.developedOnly.toggle() }
            },
        ]))
        return groups.filter { !$0.2.isEmpty }.map { (id: $0.0, title: $0.1, rows: $0.2) }
    }

    /// A date range ticked: the one chosen, or none when it was chosen already.
    private static func range(_ q: inout MacImageQuery, _ from: String, _ to: String) {
        if q.capturedFrom == from && q.capturedTo == to { q.capturedFrom = nil; q.capturedTo = nil }
        else { q.capturedFrom = from; q.capturedTo = to }
    }

    private var filtersPane: some View {
        let needle = browser.rowFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let groups = facetGroups()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.query.isFiltered {
                    Button { browser.search = ""; change { $0 = $0.cleared } } label: {
                        Text(L("Clear Filters")).font(MacMetric.font(12, .medium)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, MacMetric.pt(14)).frame(height: MacMetric.pt(24))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if store.facets.undescribed > 0 {
                    Text(L("Reading \(store.facets.undescribed) files…")).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                        .padding(.horizontal, MacMetric.pt(14)).padding(.vertical, MacMetric.pt(4))
                }
                ForEach(groups, id: \.id) { group in
                    let id = "facet." + group.id
                    SectionRow(title: group.title, folded: browser.folded.contains(id)) { fold(id) }
                    if !browser.folded.contains(id) {
                        ForEach(group.rows.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }) { facetLine($0) }
                    }
                }
            }
            .padding(.bottom, MacMetric.pt(8))
        }
    }

    private func facetLine(_ r: FacetRow) -> some View {
        SidebarLine(depth: r.depth, selected: false, disclosure: r.opens,
                    disclose: { fold("open." + r.id) }) {
            Image(systemName: r.on ? "checkmark.square.fill" : "square")
                .font(MacMetric.font(12)).foregroundStyle(r.on ? Theme.text : Theme.dim)
        } label: {
            HStack(spacing: MacMetric.pt(5)) {
                if let c = r.swatch {
                    RoundedRectangle(cornerRadius: MacMetric.pt(2)).fill(c).frame(width: MacMetric.pt(10), height: MacMetric.pt(10))
                }
                Text(r.title).font(MacMetric.font(13)).foregroundStyle(r.count == 0 && !r.on ? Theme.dim : Theme.text)
            }
        } trailing: {
            Count(value: r.count, selected: false)
        } action: {
            r.toggle()
        }
        .accessibilityAddTraits(r.on ? .isSelected : [])
        .accessibilityIdentifier("mac.library.facet")
    }

    // MARK: Info

    @ViewBuilder private var infoPane: some View {
        let count = browser.selection.count
        if let image = browser.primary(rows) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if count > 1 {
                        Text(L("\(count.formatted()) selected; the first of them:"))
                            .font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                            .padding(.horizontal, MacMetric.pt(14)).padding(.top, MacMetric.pt(8))
                    }
                    Text(image.fileName).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, MacMetric.pt(14)).padding(.vertical, MacMetric.pt(8))
                    ForEach(infoRows(image), id: \.0) { row in
                        if row.0 == L("Rating") || row.0 == L("Colour Label") {
                            HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(8)) {
                                Text(row.0).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                                    .frame(width: MacMetric.pt(84), alignment: .trailing)
                                MacMetadataPicker(field: row.0 == L("Rating") ? .rating : .color,
                                                  images: rows.filter { browser.selection.contains($0.id) })
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, MacMetric.pt(14))
                        } else { InfoLine(label: row.0, value: row.1) }
                    }
                    Button { open(image) } label: {
                        Text(L("Open in Develop")).font(MacMetric.font(12, .semibold)).foregroundStyle(Theme.onSelection)
                            .padding(.horizontal, MacMetric.pt(12)).frame(height: MacMetric.pt(24))
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, MacMetric.pt(14)).padding(.top, MacMetric.pt(12))
                }
            }
        } else {
            Text(L("No Selection")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity).padding(.top, MacMetric.pt(40))
        }
    }

    private func infoRows(_ i: MacImage) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let d = i.captureDate { rows.append((L("Taken"), d.formatted(date: .abbreviated, time: .shortened))) }
        if let c = i.cameraModel { rows.append((L("Camera"), c)) }
        if let l = i.lens { rows.append((L("Lens"), l)) }
        if let e = i.exposure { rows.append((L("Exposure"), e)) }
        if let s = i.pixelSize, s.width > 0 { rows.append((L("Size"), "\(s.width) × \(s.height)")) }
        rows.append((L("File Type"), (i.url.pathExtension.uppercased()) + (i.kind == .raw ? " · RAW" : "")))
        rows.append((L("Rating"), MacWords.rating(i.rating)))
        rows.append((L("Colour Label"), MacWords.colorName(i.colorLabel?.rawValue ?? 0)))
        if let d = i.develop {
            rows.append((L("Film"), [d.film, d.paper].compactMap { $0 }.joined(separator: " · ")))
        } else {
            rows.append((L("Film"), L("Not developed")))
        }
        let folders = i.url.deletingLastPathComponent().pathComponents.filter { $0 != "/" && $0 != "Volumes" }.suffix(3)
        if !folders.isEmpty { rows.append((L("Where"), folders.joined(separator: " › "))) }
        if i.isOffline { rows.append((L("Original"), L("Not connected"))) }
        return rows
    }

    // MARK: the bottom bar

    private var bottomBar: some View {
        @Bindable var browser = browser
        return HStack(spacing: MacMetric.pt(6)) {
            Menu {
                Button(action: openSource) { Label(L("Open Catalog or Folder…"), systemImage: "camera.aperture") }
                // The Mac's import flow (a Finder panel, then the import page, `MacImportFlow`), not the window's sheet.
                Button { browser.importAsked = true } label: { Label(L("Import…"), systemImage: "square.and.arrow.down") }
                Button { run { await MacCatalogActions.newCatalog(store) } } label: { Label(L("New Catalog…"), systemImage: "plus.rectangle.on.folder") }
                catalogCommands
                if let s = store.selectedSource {
                    Button { Task { await store.synchronize(s.id) } } label: { Label(L("Read Again"), systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { store.remove(source: s.id) } label: { Label(L("Remove from List"), systemImage: "minus.circle") }
                }
                Divider()
                // The Mac's Settings page (Sources/Mac/Settings), on its Sources section or its first.
                Button(action: plusSources) { Label(L("Sources"), systemImage: "externaldrive") }
                Button(action: plusSettings) { Label(L("Settings"), systemImage: "gearshape") }
            } label: {
                Image(systemName: "plus").font(MacMetric.font(13, .medium)).foregroundStyle(Theme.secondaryText)
                    .frame(width: MacMetric.pt(22), height: MacMetric.pt(22)).contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(L("Add"))
            HStack(spacing: MacMetric.pt(4)) {
                Image(systemName: "line.3.horizontal.decrease").font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                TextField(L("Filter"), text: $browser.rowFilter)
                    .font(MacMetric.font(12)).textFieldStyle(.plain)
                    .focused($filtering)
                    .onSubmit { filtering = false }         // Return: the text is kept, the field lets go
                    .onKeyPress(.escape) { filtering = false; return .handled }   // Esc: the same
                    .onChange(of: MacKeyFocus.shared.pulse) { _, _ in filtering = false }   // a click outside
                if !browser.rowFilter.isEmpty {
                    Button { browser.rowFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear"))
                }
            }
            .padding(.horizontal, MacMetric.pt(7))
            .frame(height: MacMetric.pt(22))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(11), style: .continuous))
        }
        .padding(.horizontal, MacMetric.pt(8))
        .frame(height: MacMetric.pt(MacMetric.bottomBar))
    }
}

// MARK: - rows

/// A heading over rows: small capitals in `dim`, its chevron folding what is under it.
private struct SectionRow: View {
    let title: String
    let folded: Bool
    let fold: () -> Void

    var body: some View {
        Button(action: fold) {
            HStack(spacing: MacMetric.pt(4)) {
                Image(systemName: "chevron.right")
                    .font(MacMetric.font(8, .bold)).foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: MacMetric.pt(12))
                Text(title.uppercased()).font(MacMetric.font(11, .semibold)).tracking(0.4).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MacMetric.pt(8))
            .padding(.top, MacMetric.pt(6))
            .frame(minHeight: MacMetric.pt(24))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(folded ? L("Folded") : "")
    }
}

/// A row of the outline or of Filters: its indent, its chevron (if it opens), its glyph, its words and
/// its count; chosen, v2's white capsule.
private struct SidebarLine<Glyph: View, Label: View, Trailing: View>: View {
    let depth: Int
    let selected: Bool
    /// nil: nothing opens under it; else whether it is open.
    var disclosure: Bool?
    var disclose: () -> Void = {}
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder let label: () -> Label
    @ViewBuilder let trailing: () -> Trailing
    let action: () -> Void

    var body: some View {
        HStack(spacing: MacMetric.pt(4)) {
            Color.clear.frame(width: MacMetric.pt(MacMetric.indent) * CGFloat(depth), height: 1)
            Group {
                if let disclosure {
                    Button(action: disclose) {
                        Image(systemName: "chevron.right")
                            .font(MacMetric.font(9, .bold))
                            .foregroundStyle(selected ? Theme.onSelection.opacity(0.7) : Theme.dim)
                            .rotationEffect(.degrees(disclosure ? 90 : 0))
                            .frame(width: MacMetric.pt(14), height: MacMetric.pt(20)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: MacMetric.pt(14), height: 1)
                }
            }
            Button(action: action) {
                HStack(spacing: MacMetric.pt(6)) {
                    glyph().frame(width: MacMetric.pt(16))
                    label()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .frame(minHeight: MacMetric.pt(MacMetric.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, MacMetric.pt(2))
        .padding(.trailing, MacMetric.pt(8))
        .background {
            if selected { RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous).fill(Theme.selection) }
        }
        .padding(.horizontal, MacMetric.pt(6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct Count: View {
    let value: Int
    let selected: Bool
    var body: some View {
        Text(value.formatted()).font(MacMetric.font(12)).monospacedDigit()
            .foregroundStyle(selected ? Theme.onSelection.opacity(0.6) : Theme.dim)
            .fixedSize()
    }
}

/// Info's label/value row: the label right-aligned in its column, the value wrapping.
private struct InfoLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MacMetric.pt(8)) {
            Text(label).font(MacMetric.font(11)).foregroundStyle(Theme.dim)
                .multilineTextAlignment(.trailing)
                .frame(width: MacMetric.pt(84), alignment: .trailing)
            Text(value).font(MacMetric.font(12)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, MacMetric.pt(10))
        .padding(.vertical, MacMetric.pt(3))
        .frame(minHeight: MacMetric.pt(20))
    }
}
