//  LibraryWindow.swift — the Library, as a window of its own beside the
//  editor.
//
//  **A window, not a mode.** The design (`modern_UI/design/v2-capture-one`)
//  drew the Library behind a Library | Develop | Edit switch; the owner
//  rejected a surface switch on the desktop the same day (decision 12: both
//  rails always on screen, no shell that hides one view behind another). A
//  separate window is the arrangement that keeps that decision: the editor is
//  untouched, the Library can sit on a second display, and Develop brings the
//  editor forward with the frame on it. PRD-v2.0.0 §16 Q2 is still the
//  owner's; this view does not depend on its host, so it can move into the
//  main window if the answer is a mode.
//
//  Its parts are the design's: the Library rail (the source, Catalog,
//  Collections, Folders, Filters), the grid, and the Info rail.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryWindow: View {
    @Bindable var library: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Session.uiKey + "library.thumb") private var thumb: Double = 150

    var body: some View {
        HStack(spacing: 0) {
            LibraryRail(library: library)
                .frame(width: 268)
                .background(Theme.card)
            VerticalHairline()
            VStack(spacing: 0) {
                LibraryToolbar(library: library, thumb: $thumb)
                Hairline(tier: .region)
                centre
            }
            .frame(minWidth: 420)
            VerticalHairline()
            LibraryInfoRail(library: library, develop: develop)
                .frame(width: 292)
                .background(Theme.card)
        }
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 620)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let d = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) }
                }
                await library.add(urls, copy: false)
            }
            return library.isOpen && !library.readOnly
        }
    }

    @ViewBuilder private var centre: some View {
        if let c1 = library.captureOneSession {
            LibraryCaptureOneSessionPage(library: library, session: c1)
        } else if !library.isOpen {
            LibraryWelcome(library: library)
        } else if library.rows.isEmpty && !library.loading {
            LibraryEmpty(library: library)
        } else {
            LibraryGrid(library: library, thumb: thumb, develop: develop)
        }
    }

    private func develop(_ id: String?) {
        Task {
            if await library.develop(id) { openWindow(id: "editor") }
        }
    }
}

// MARK: - tool bar

struct LibraryToolbar: View {
    @Bindable var library: LibraryModel
    @Binding var thumb: Double

    var body: some View {
        HStack(spacing: 14) {
            if library.isOpen {
                Text("\(library.kindLabel) › \(library.scopeName)")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                if library.readOnly {
                    Label(L("Read-only", zh: "只读"), systemImage: "lock.fill")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Ink.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.pill))
                }
            }
            Spacer(minLength: 8)
            if let toast = library.toast {
                Text(toast)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            }
            if library.isOpen {
                Text(countLine)
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.Ink.secondary)
                Menu {
                    Picker(L("Sort", zh: "排序"), selection: $library.query.sort) {
                        Text(L("Capture Date", zh: "拍摄日期")).tag(LibraryQuery.Sort.captured)
                        Text(L("Import Date", zh: "导入日期")).tag(LibraryQuery.Sort.imported)
                        Text(L("File Name", zh: "文件名")).tag(LibraryQuery.Sort.name)
                        Text(L("Rating", zh: "评级")).tag(LibraryQuery.Sort.rating)
                    }
                    Toggle(L("Newest First", zh: "最新在前"), isOn: $library.query.descending)
                } label: {
                    Text(sortName).font(Theme.Font.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Slider(value: $thumb, in: 90...320)
                    .frame(width: 110)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.topBarHeight)
        .animation(.easeOut(duration: Theme.Motion.quickDuration), value: library.toast)
    }

    private var countLine: String {
        let photos = L("photos", zh: "张照片")
        let shown = library.loading && library.rows.count < library.total
            ? "\(library.rows.count.formatted()) / \(library.total.formatted()) \(photos)"
            : "\(library.total.formatted()) \(photos)"
        return library.selection == nil ? shown : shown + " · 1 " + L("selected", zh: "已选")
    }

    private var sortName: String {
        switch library.query.sort {
        case .captured: L("Capture Date", zh: "拍摄日期")
        case .imported: L("Import Date", zh: "导入日期")
        case .name: L("File Name", zh: "文件名")
        case .rating: L("Rating", zh: "评级")
        case .added: L("Added", zh: "添加日期")
        }
    }
}

// MARK: - grid

struct LibraryGrid: View {
    @Bindable var library: LibraryModel
    let thumb: Double
    let develop: (String?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumb, maximum: thumb * 1.4), spacing: 10)],
                          spacing: 14) {
                    ForEach(library.rows) { row in
                        LibraryCell(library: library, row: row, side: thumb)
                            .id(row.uuid)
                            .onTapGesture(count: 2) { develop(row.uuid) }
                            .onTapGesture { library.selection = row.uuid; focused = true }
                            .contextMenu { LibraryCellMenu(library: library, row: row, develop: develop) }
                    }
                }
                .padding(14)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) { develop(nil); return .handled }
            .onKeyPress(.leftArrow) { step(-1, proxy); return .handled }
            .onKeyPress(.rightArrow) { step(1, proxy); return .handled }
            .onKeyPress(characters: .decimalDigits) { press in
                guard let n = Int(press.characters), n <= 5 else { return .ignored }
                Task { await library.setRating(n == 0 ? nil : n) }
                return .handled
            }
        }
    }

    private func step(_ d: Int, _ proxy: ScrollViewProxy) {
        let rows = library.rows
        guard !rows.isEmpty else { return }
        let i = library.selection.flatMap { s in rows.firstIndex { $0.uuid == s } } ?? (d > 0 ? -1 : rows.count)
        let j = min(max(i + d, 0), rows.count - 1)
        library.selection = rows[j].uuid
        proxy.scrollTo(rows[j].uuid)
    }
}

struct LibraryCell: View {
    let library: LibraryModel
    let row: LibraryImage
    let side: Double

    private var selected: Bool { library.selection == row.uuid }
    private var dim: Bool { !library.canDevelop(row) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Rectangle().fill(Theme.ground.opacity(0.6))
                LibraryThumbnail(url: row.url, maxPixel: Int(side * 2), offline: row.isOffline)
                    .padding(4)
                    .opacity(dim ? Theme.disabledOpacity : 1)
            }
            .frame(height: side * 0.78)
            .overlay(alignment: .topLeading) {
                if row.isOffline { mark(L("Offline", zh: "离线"), danger: true) }
            }
            .overlay(alignment: .topTrailing) {
                if row.hasEdit { mark(L("Print", zh: "印相"), danger: false) }
            }
            .overlay(alignment: .bottomTrailing) {
                if row.variants.count > 1 { mark("\(row.variants.count)", danger: false) }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(selected ? Theme.selectionFrame : .clear, lineWidth: 2)
            )
            HStack(spacing: 4) {
                // Wraps rather than truncates: no "…" (the UI text-fit rule).
                Text(row.fileName)
                    .font(Theme.Font.small)
                    .foregroundStyle(selected ? Theme.Ink.primary : Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                if let tag = row.colorTag, tag > 0 { LibraryColorTag.swatch(tag).frame(width: 7, height: 7) }
                if row.rating > 0 {
                    Text(String(repeating: "★", count: row.rating))
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func mark(_ text: String, danger: Bool) -> some View {
        Text(text)
            .font(Theme.Font.small)
            .foregroundStyle(danger ? Color.white : Theme.onSelection)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(danger ? Color(hex: 0xC2453D) : Theme.selection.opacity(0.85)))
            .padding(6)
    }
}

/// A file's embedded preview, from the filmstrip's cache. An offline
/// original is not asked for: its volume is gone, and the stat alone can
/// stall on a network share.
struct LibraryThumbnail: View {
    let url: URL
    let maxPixel: Int
    var offline = false
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: "\(url.path)|\(maxPixel)") {
            guard !offline else { image = nil; return }
            image = await ThumbnailCache.cameraPreviews.thumbnail(for: url, maxPixel: maxPixel)
        }
    }
}

struct LibraryCellMenu: View {
    let library: LibraryModel
    let row: LibraryImage
    let develop: (String?) -> Void

    var body: some View {
        Button(L("Develop", zh: "显影")) { develop(row.uuid) }.disabled(!library.canDevelop(row))
        Button(L("Show in Finder", zh: "在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
            .disabled(row.isOffline)
        Button(L("Copy File Path", zh: "拷贝文件路径")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.path, forType: .string)
        }
        if !library.readOnly {
            Divider()
            Button(L("New Variant", zh: "新建变体")) {
                library.selection = row.uuid
                Task { await library.newVariant() }
            }
            let albums = library.collections.filter { $0.kind == "album" && $0.editable }
            if !albums.isEmpty {
                Menu(L("Add to Album", zh: "添加到相册")) {
                    ForEach(albums) { a in
                        Button(a.name) {
                            library.selection = row.uuid
                            Task { await library.addSelection(toAlbum: a.uuid) }
                        }
                    }
                }
            }
        }
        if library.isSession {
            Divider()
            Button(L("Move to Selects", zh: "移到精选")) { library.selection = row.uuid; Task { await library.move(toRole: "selects") } }
            Button(L("Move to Trash", zh: "移到废纸篓")) { library.selection = row.uuid; Task { await library.move(toRole: "trash") } }
            Button(L("Put Back", zh: "放回原处")) { library.selection = row.uuid; Task { await library.putBack() } }
        }
    }
}

// MARK: - pages without a grid

struct LibraryWelcome: View {
    let library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 18) {
            Text(L("Library", zh: "图库"))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.Ink.primary)
            if case .reading(let what) = library.sourceState {
                ProgressView().controlSize(.small)
                Text(what).font(Theme.Font.small).foregroundStyle(Theme.Ink.secondary)
            } else if let message = LibrarySourceWell.stateLine(library.sourceState) {
                Text(message)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                action(L("New Catalog…", zh: "新建目录…")) {
                    if let url = LibraryPanels.newCatalog() { Task { await library.create(.catalog, at: url) } }
                }
                action(L("New Session…", zh: "新建会话…")) {
                    if let url = LibraryPanels.newSession() { Task { await library.create(.session, at: url) } }
                }
                action(L("Open Library…", zh: "打开图库…")) {
                    if let url = LibraryPanels.openLibrary() { Task { await library.open(at: url) } }
                }
                action(L("Open Capture One Catalog…", zh: "打开 Capture One 目录…")) {
                    if let url = LibraryPanels.openCaptureOne() { Task { await library.openCaptureOne(at: url) } }
                }
            }
            if !library.recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Recent", zh: "最近")).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
                    ForEach(library.recents) { r in
                        Button { Task { await library.open(r) } } label: {
                            HStack {
                                Text(r.name).font(Theme.Font.body).foregroundStyle(Theme.Ink.primary)
                                Spacer()
                                Text(LibraryWelcome.kindName(r.kind)).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func kindName(_ k: LibraryModel.Recent.Kind) -> String {
        switch k {
        case .catalog: L("Catalog", zh: "目录")
        case .session: L("Session", zh: "会话")
        case .captureOne: "Capture One"
        }
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Ink.primary)
                .frame(width: 260, height: 26)
                .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
        }
        .buttonStyle(.plain)
    }
}

struct LibraryEmpty: View {
    let library: LibraryModel

    var body: some View {
        VStack(spacing: 12) {
            Text(L("No photos", zh: "没有照片"))
                .font(Theme.Font.label)
                .foregroundStyle(Theme.Ink.secondary)
            if library.query.isFiltered {
                Button(L("Clear Filters", zh: "清除过滤器")) { library.query = LibraryQuery(collection: library.query.collection) }
                    .buttonStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.accent)
            } else if !library.readOnly {
                Button(L("Add Photos…", zh: "添加照片…")) {
                    let urls = LibraryPanels.addPhotos()
                    if !urls.isEmpty { Task { await library.add(urls, copy: false) } }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Capture One session: what the probe read, and the one thing 2.0 can do
/// with it — open its Capture folder as a folder.
struct LibraryCaptureOneSessionPage: View {
    let library: LibraryModel
    let session: LibraryModel.CaptureOneSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Text(L("Capture One Session", zh: "Capture One 会话"))
                .font(Theme.Font.railTitle)
                .foregroundStyle(Theme.Ink.primary)
            Text(session.folder.lastPathComponent)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Ink.secondary)
            if let format = session.probe.format {
                Text(format).font(Theme.Font.value).foregroundStyle(Theme.Ink.tertiary)
            }
            if let n = session.probe.images {
                Text("\(n.formatted()) " + L("photos", zh: "张照片")).font(Theme.Font.value).foregroundStyle(Theme.Ink.tertiary)
            }
            Text(L("Read in a later version", zh: "将在后续版本中读取"))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.accent)
            Button(L("Open Capture Folder", zh: "打开采集文件夹")) {
                library.openCaptureOneSessionFolder()
                openWindow(id: "editor")
            }
            .buttonStyle(.plain)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Ink.primary)
            .padding(.horizontal, 14).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Capture One's eight colour tags (0 = none), as swatches. The colours are
/// Capture One's own order: red, orange, yellow, green, blue, pink, purple.
enum LibraryColorTag {
    static let colors: [Color] = [
        .clear, Color(hex: 0xE5534B), Color(hex: 0xEE8A3C), Color(hex: 0xE9C93F), Color(hex: 0x5DB14E),
        Color(hex: 0x4C8BE0), Color(hex: 0xE46FB0), Color(hex: 0x9967D6),
    ]

    static func swatch(_ tag: Int) -> some View {
        Circle().fill(colors[min(max(tag, 0), colors.count - 1)])
    }
}
