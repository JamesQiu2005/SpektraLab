//  LibraryRail.swift — the Library's left rail: the source, then Catalog,
//  Collections, Folders (or a session's four folders), then Filters.
//
//  Roles come from a collection's `kind`, never from its name: Capture One
//  names its own collections in its UI language ("全部图像", "最近导入").
//  A SpektraLab catalog has no Catalog collections of its own, so All Images
//  is the rail's, and is the whole library (`images.list` with no collection).

import SwiftUI

struct LibraryRail: View {
    @Bindable var library: LibraryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LibrarySourceWell(library: library)
                if library.isOpen {
                    catalogSection
                    if library.isSession { sessionSection }
                    if !albums.isEmpty || !library.readOnly { collectionsSection }
                    if !folders.isEmpty { foldersSection }
                    LibraryFilters(library: library)
                }
            }
            .padding(12)
        }
    }

    // MARK: sections

    private var catalogKinds: Set<String> { ["all_images", "recent_imports", "recent_captures", "in_library", "trash"] }
    private var albumKinds: Set<String> { ["project", "group", "album", "smart_album"] }

    private var catalogRows: [LibraryCollection] {
        library.collections.filter { catalogKinds.contains($0.kind) && $0.kind != "all_images" }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
    }
    private var albums: [LibraryCollection] { library.collections.filter { albumKinds.contains($0.kind) } }
    private var folders: [LibraryCollection] { library.collections.filter { $0.kind == "folder" } }

    private var catalogSection: some View {
        LibrarySection(title: library.isSession ? L("Session", zh: "会话") : L("Catalog", zh: "目录")) {
            row(nil, name: L("All Images", zh: "全部图像"), glyph: "photo.on.rectangle",
                count: library.info?.counts.images)
            ForEach(catalogRows) { c in
                row(c.uuid, name: c.name, glyph: glyph(c.kind), count: c.imageCount)
            }
        }
    }

    /// A session's folders by role, in the order a shoot moves through them.
    private var sessionSection: some View {
        LibrarySection(title: L("Folders", zh: "文件夹")) {
            ForEach(library.sessionFolders.filter { $0.role != nil }) { f in
                let collection = folders.first { $0.folder == f.path }
                HStack(spacing: 0) {
                    row(collection?.uuid ?? "", name: roleName(f.role), glyph: roleGlyph(f.role),
                        count: f.imageCount, enabled: collection != nil)
                    if f.role == "trash", (f.imageCount ?? 0) > 0 {
                        Button(L("Empty", zh: "清空")) { Task { await library.emptyTrash() } }
                            .buttonStyle(.plain)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.accent)
                            .padding(.leading, 6)
                    }
                }
            }
            Button(L("Scan for New Captures", zh: "扫描新采集")) { Task { await library.refresh() } }
                .buttonStyle(.plain)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Ink.secondary)
                .padding(.top, 2)
        }
    }

    @State private var naming = false
    @State private var newName = ""

    private var collectionsSection: some View {
        LibrarySection(title: L("Collections", zh: "汇集"), trailing: library.readOnly ? nil : AnyView(
            Button { naming = true } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Ink.secondary)
                .help(L("New Album", zh: "新建相册"))
        )) {
            ForEach(tree(albums)) { item in
                row(item.c.uuid, name: item.c.name, glyph: glyph(item.c.kind), count: item.c.imageCount,
                    depth: item.depth, locked: !item.c.editable && library.readOnly)
            }
            if naming {
                TextField(L("Album name", zh: "相册名称"), text: $newName)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: Theme.Metric.fieldRadius).fill(Theme.ground.opacity(0.55)))
                    .onSubmit {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        naming = false
                        newName = ""
                        if !name.isEmpty { Task { await library.newAlbum(named: name) } }
                    }
                    .onExitCommand { naming = false; newName = "" }
            }
        }
    }

    private var foldersSection: some View {
        LibrarySection(title: library.isSession ? L("All Folders", zh: "全部文件夹") : L("Folders", zh: "文件夹")) {
            ForEach(tree(folders)) { item in
                let offline = isOffline(item.c)
                HStack(spacing: 0) {
                    row(item.c.uuid, name: item.c.name, glyph: offline ? "externaldrive.badge.xmark" : "folder",
                        count: item.c.imageCount, depth: item.depth, dimmed: offline)
                    if offline, let loc = location(for: item.c) {
                        Button(L("Locate…", zh: "查找…")) {
                            if let url = LibraryPanels.locateFolder() { Task { await library.relink(loc.uuid, to: url) } }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.accent)
                        .padding(.leading, 6)
                    }
                }
            }
        }
    }

    // MARK: rows

    private func row(_ uuid: String?, name: String, glyph: String, count: Int?, depth: Int = 0,
                     enabled: Bool = true, dimmed: Bool = false, locked: Bool = false) -> some View {
        let on = library.scope == uuid && enabled
        return Button {
            if enabled { library.show(collection: uuid) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: glyph)
                    .font(Theme.Font.small)
                    .frame(width: 14)
                Text(name)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(Theme.Ink.tertiary)
                }
                Spacer(minLength: 6)
                if let count {
                    Text(count.formatted())
                        .font(Theme.Font.value)
                        .foregroundStyle(on ? Theme.onSelection : Theme.Ink.tertiary)
                }
            }
            .foregroundStyle(on ? Theme.onSelection : Theme.Ink.primary)
            .padding(.leading, CGFloat(depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.selection : .clear))
            .contentShape(Rectangle())
            .opacity(enabled && !dimmed ? 1 : Theme.disabledOpacity)
        }
        .buttonStyle(.plain)
    }

    private struct Item: Identifiable { let c: LibraryCollection; let depth: Int; var id: String { c.uuid } }

    /// A flat list in tree order, each with its depth. Parents that are not
    /// in the list (a root, a project above a filtered kind) are skipped.
    private func tree(_ list: [LibraryCollection]) -> [Item] {
        let ids = Set(list.map(\.uuid))
        let children = Dictionary(grouping: list) { c in c.parent.flatMap { ids.contains($0) ? $0 : nil } ?? "" }
        var out: [Item] = []
        func walk(_ parent: String, _ depth: Int) {
            for c in (children[parent] ?? []).sorted(by: { ($0.position ?? 0, $0.name) < ($1.position ?? 0, $1.name) }) {
                out.append(Item(c: c, depth: depth))
                walk(c.uuid, depth + 1)
            }
        }
        walk("", 0)
        return out
    }

    private func location(for c: LibraryCollection) -> LibraryLocation? {
        guard let folder = c.folder else { return nil }
        return library.locations.first { $0.path == folder }
    }

    private func isOffline(_ c: LibraryCollection) -> Bool { location(for: c)?.online == false }

    private func glyph(_ kind: String) -> String {
        switch kind {
        case "recent_imports": "square.and.arrow.down"
        case "recent_captures": "camera"
        case "trash": "trash"
        case "project": "folder.badge.person.crop"
        case "group": "square.stack"
        case "smart_album": "gearshape"
        case "album": "rectangle.stack"
        default: "photo"
        }
    }

    private func roleName(_ role: String?) -> String {
        switch role {
        case "capture": L("Capture", zh: "采集")
        case "selects": L("Selects", zh: "精选")
        case "output": L("Output", zh: "输出")
        case "trash": L("Trash", zh: "废纸篓")
        default: role ?? ""
        }
    }

    private func roleGlyph(_ role: String?) -> String {
        switch role {
        case "capture": "camera"
        case "selects": "star"
        case "output": "square.and.arrow.up"
        case "trash": "trash"
        default: "folder"
        }
    }
}

/// The source, at the top of the rail: what is open, how many photos, and
/// the state line (A1–A5) with the one action each state offers.
struct LibrarySourceWell: View {
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let info = library.info {
                Text(library.kindLabel)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Ink.tertiary)
                Text(library.isCaptureOne ? (info.origin.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? info.name) : info.name)
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("\(info.counts.images.formatted()) " + L("photos", zh: "张照片"))
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.Ink.secondary)
                    if library.readOnly {
                        Label(L("Read-only", zh: "只读"), systemImage: "lock.fill")
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    if let format = info.origin.format {
                        Text(format).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
                    }
                }
            } else {
                Text(L("No library open", zh: "未打开图库"))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            stateRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.wellRadius).fill(Theme.ground.opacity(0.55)))
        .overlay(alignment: .topTrailing) { switcher.padding(6) }
    }

    @ViewBuilder private var stateRow: some View {
        switch library.sourceState {
        case .reading(let what):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(what).font(Theme.Font.small).foregroundStyle(Theme.accent)
            }
        case .busy:
            HStack(spacing: 6) {
                Text(L("Capture One is writing", zh: "Capture One 正在写入")).font(Theme.Font.small).foregroundStyle(Theme.accent)
                Button(L("Refresh", zh: "刷新")) { Task { await library.refresh(force: true) } }
                    .buttonStyle(.plain).font(Theme.Font.small).foregroundStyle(Theme.accent)
            }
        default:
            if let line = Self.stateLine(library.sourceState) {
                Text(line)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if library.isCaptureOne {
                Button(L("Refresh", zh: "刷新")) { Task { await library.refresh(force: true) } }
                    .buttonStyle(.plain).font(Theme.Font.small).foregroundStyle(Theme.Ink.secondary)
            }
        }
    }

    /// The words for a state that needs them; nil for "read and current".
    static func stateLine(_ s: LibraryModel.SourceState) -> String? {
        switch s {
        case .none, .ready, .reading: nil
        case .notFound(let m): L("Not found", zh: "未找到") + " · " + m
        case .tooNew(let m): m
        case .busy: L("Capture One is writing", zh: "Capture One 正在写入")
        case .inUse(let m): L("Open in another SpektraLab", zh: "已在另一个 SpektraLab 中打开") + " · " + m
        case .failed(let m): m
        }
    }

    private var switcher: some View {
        Menu {
            ForEach(library.recents) { r in
                Button(r.name + " — " + LibraryWelcome.kindName(r.kind)) { Task { await library.open(r) } }
            }
            if !library.recents.isEmpty { Divider() }
            Button(L("New Catalog…", zh: "新建目录…")) {
                if let url = LibraryPanels.newCatalog() { Task { await library.create(.catalog, at: url) } }
            }
            Button(L("New Session…", zh: "新建会话…")) {
                if let url = LibraryPanels.newSession() { Task { await library.create(.session, at: url) } }
            }
            Button(L("Open Library…", zh: "打开图库…")) {
                if let url = LibraryPanels.openLibrary() { Task { await library.open(at: url) } }
            }
            Button(L("Open Capture One Catalog…", zh: "打开 Capture One 目录…")) {
                if let url = LibraryPanels.openCaptureOne() { Task { await library.openCaptureOne(at: url) } }
            }
            if library.isOpen {
                Divider()
                if !library.readOnly {
                    Button(L("Add Photos…", zh: "添加照片…")) {
                        let urls = LibraryPanels.addPhotos()
                        if !urls.isEmpty { Task { await library.add(urls, copy: false) } }
                    }
                    Button(L("Copy Photos In…", zh: "拷贝照片…")) {
                        let urls = LibraryPanels.addPhotos()
                        if !urls.isEmpty { Task { await library.add(urls, copy: true) } }
                    }
                    Divider()
                }
                Button(L("Close Library", zh: "关闭图库")) { Task { await library.close() } }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Search, rating, colour tag, and SpektraLab's own: developed or not.
struct LibraryFilters: View {
    @Bindable var library: LibraryModel

    var body: some View {
        LibrarySection(title: L("Filters", zh: "过滤器"), trailing: library.query.isFiltered ? AnyView(
            Button(L("Clear", zh: "清除")) { library.query = LibraryQuery(collection: library.query.collection,
                                                                       sort: library.query.sort,
                                                                       descending: library.query.descending) }
                .buttonStyle(.plain)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.accent)
        ) : nil) {
            TextField(L("Search", zh: "搜索"), text: $library.query.text)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: Theme.Metric.fieldRadius).fill(Theme.ground.opacity(0.55)))
            HStack(spacing: 4) {
                Text(L("Rating", zh: "评级")).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
                Spacer()
                ForEach(1...5, id: \.self) { n in
                    let on = (library.query.minRating ?? 0) >= n
                    Button { library.query.minRating = library.query.minRating == n ? nil : n } label: {
                        Text("★").font(Theme.Font.body).foregroundStyle(on ? Theme.Ink.primary : Theme.Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Text(L("Colour Tag", zh: "色标")).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
                Spacer()
                ForEach(1...7, id: \.self) { t in
                    let on = library.query.colorTags.contains(t)
                    Button {
                        if on { library.query.colorTags.removeAll { $0 == t } } else { library.query.colorTags.append(t) }
                    } label: {
                        LibraryColorTag.swatch(t)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(on ? Theme.selection : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker(selection: $library.query.hasEdit) {
                Text(L("Any", zh: "全部")).tag(Bool?.none)
                Text(L("Developed", zh: "已显影")).tag(Bool?.some(true))
                Text(L("Not developed", zh: "未显影")).tag(Bool?.some(false))
            } label: {
                Text("SpektraLab").font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
            }
            .pickerStyle(.menu)
            .font(Theme.Font.small)
        }
    }
}

/// A titled group in the rail, with an optional control at its trailing end.
struct LibrarySection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(Theme.Font.rightSectionTitle)
                    .foregroundStyle(Theme.Ink.secondary)
                Spacer()
                trailing
            }
            .padding(.bottom, 2)
            content
        }
    }
}
