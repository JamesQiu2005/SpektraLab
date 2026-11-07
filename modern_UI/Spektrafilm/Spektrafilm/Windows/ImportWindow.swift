// A separate window keeps culling keys and source previews away from the editor.
import AppKit
import SwiftUI
import Observation
import ImageIO

@MainActor @Observable
private final class ImportModel {
    var urls: [URL] = []
    var checked: Set<URL> = []
    var focus: URL?
    var anchor: URL?
    var ratings: [URL: Int] = [:]
    var rawOnly = true
    /// Suspected duplicates, each mapped to the path it appears to copy.
    var duplicates: [URL: String] = [:]
    var hideDuplicates = true
    var filter = 0 // 0: all, 1…5: minimum stars, 6: checked
    var size = 160.0
    var preview = false
    var loading = true
    // The shared filmstrip cache may hold developed pixels; culling shows the source.
    let cache = ImportPreviewDecoder.makeCache()

    var visible: [URL] {
        let base = rawOnly ? ImportSelection.removingPairedJPEGs(urls, rawExtensions: ImageDecoder.rawExtensions) : urls
        return ImportSelection.filtered(base, minimumRating: filter == 6 ? 0 : filter,
                                        checkedOnly: filter == 6, checked: checked, ratings: ratings,
                                        hiding: hideDuplicates ? Set(duplicates.keys) : [])
    }

    func click(_ url: URL) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            checked.formUnion(ImportSelection.range(in: visible, anchor: anchor, end: url))
        } else {
            anchor = url
            if flags.contains(.command) { toggle(url) }
        }
        focus = url
    }

    func toggle(_ url: URL) {
        if !checked.insert(url).inserted { checked.remove(url) }
    }

    func key(_ event: NSEvent, columns: Int) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let list = visible
        switch event.keyCode {
        case 53:
            if preview { preview = false; return true }
            return false
        case 36, 76:
            if focus != nil { preview.toggle() }; return true
        case 49:
            if let focus { toggle(focus) }; return true
        case 123, 124, 125, 126:
            guard !list.isEmpty else { return true }
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
            let index = list.firstIndex(of: focus ?? list[0]) ?? 0
            focus = list[min(max(index + delta, 0), list.count - 1)]
            return true
        default:
            guard let text = event.charactersIgnoringModifiers, let stars = Int(text), (0...5).contains(stars) else { return false }
            let targets = checked.isEmpty ? focus.map { [$0] } ?? [] : Array(checked)
            for url in targets { Ratings.set(stars, for: url); ratings[url] = stars }
            return true
        }
    }
}

@MainActor
private final class ImportPanel: NSWindow {
    var handleKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ImportWindowController: NSWindowController, NSWindowDelegate {
    // Retain until close, including the titlebar's close button.
    private static var active: ImportWindowController?

    static func show(folder: URL, session: Session) {
        active?.close()
        let model = ImportModel()
        let window = ImportPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Import", zh: "导入") + " · " + folder.lastPathComponent
        window.minSize = NSSize(width: 760, height: 520)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        let controller = ImportWindowController(window: window)
        active = controller
        window.delegate = controller
        window.contentView = NSHostingView(rootView: ImportWindow(model: model, folder: folder,
            cancel: { [weak controller] in controller?.close() },
            commit: { [weak controller, weak session] in
                guard let session, !session.batchExporting else { return }
                session.open(urls: ImportSelection.importURLs(model.checked))
                controller?.close()
            }))
        window.handleKey = { [weak window] event in
            let width = window?.contentView?.bounds.width ?? 1000
            return model.key(event, columns: max(1, Int((width - 28) / (model.size + 12))))
        }
        window.center()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if Self.active === self { Self.active = nil }
    }

    override func close() {
        super.close()
        if Self.active === self { Self.active = nil }
    }
}

@MainActor
private struct ImportWindow: View {
    @Bindable var model: ImportModel
    let folder: URL
    let cancel: () -> Void
    let commit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(L("Select All", zh: "全选")) { model.checked.formUnion(model.visible) }
                Button(L("Select None", zh: "全不选")) { model.checked.subtract(model.visible) }
                Button(L("Invert", zh: "反选")) { model.checked.formSymmetricDifference(model.visible) }
                Toggle(L("RAW only (paired JPEGs hidden)", zh: "只显示 RAW（隐藏配对 JPEG）"), isOn: $model.rawOnly)
                Toggle(L("Hide suspected duplicates", zh: "隐藏疑似重复") + " (\(model.duplicates.count))",
                       isOn: $model.hideDuplicates)
                    .help(L("Same size and same first 64 KB as another photo in this folder, or as one already rated or developed elsewhere.",
                            zh: "与本文件夹里另一张、或其他位置已打星/已修的照片大小相同且前 64 KB 相同。"))
                Spacer()
                Picker(L("Filter", zh: "筛选"), selection: $model.filter) {
                    Text(L("All", zh: "全部")).tag(0)
                    ForEach(1...5, id: \.self) { Text("≥\($0)★").tag($0) }
                    Text(L("Checked", zh: "已勾选")).tag(6)
                }.frame(width: 150)
                Slider(value: $model.size, in: 110...260).frame(width: 100)
                    .accessibilityLabel(L("Thumbnail size", zh: "缩略图大小"))
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.preview, let url = model.focus {
                ImportSourceImage(url: url, cache: model.cache, maxPixel: 2048)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(url.lastPathComponent)
                Button(L("Back to Grid (Esc)", zh: "返回网格（Esc）")) { model.preview = false }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.size), spacing: 12)], spacing: 12) {
                            ForEach(model.visible, id: \.self) { url in
                                cell(url).id(url)
                            }
                        }.padding(4)
                    }
                    .onChange(of: model.focus) { _, url in
                        if let url { proxy.scrollTo(url) }
                    }
                }
                if model.visible.isEmpty { Text(L("No matching photos", zh: "没有符合条件的照片")) }
            }
            HStack {
                Text(L("Click: focus · ⌘click / Space: check · Shift: range · 0–5: rate · Return: preview",
                       zh: "点击：焦点 · ⌘点击 / 空格：勾选 · Shift：范围 · 0–5：星级 · 回车：预览"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel", zh: "取消"), action: cancel)
                Button(L("Import Selected", zh: "导入所选") + " (\(model.checked.count))", action: commit)
                    .disabled(model.checked.isEmpty)
            }
        }
        .padding(16)
        .background(Theme.card)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .task {
            let urls = await Task.detached(priority: .userInitiated) { [folder] in Library.frames(at: folder).map(\.id) }.value
            guard !Task.isCancelled else { return }
            // A 64 KB read per file, off the main actor, before the grid shows:
            // hiding duplicates by default must not make cells vanish later.
            // The sidecar store is scanned here too (its first scan reads
            // every sidecar); the catalog is main-actor and indexed.
            let (prints, developed) = await Task.detached(priority: .userInitiated) {
                var prints: [URL: ImportSelection.Fingerprint] = [:]
                var developed: [ImportSelection.Fingerprint: [String]] = [:]
                for url in urls {
                    guard let p = ImportSelection.Fingerprint.of(url) else { continue }
                    prints[url] = p
                    if developed[p] == nil { developed[p] = Sidecar.knownCopies(size: p.size, headDigest: p.headDigest) }
                }
                return (prints, developed)
            }.value
            guard !Task.isCancelled else { return }
            model.urls = urls
            model.ratings = Dictionary(uniqueKeysWithValues: urls.map { ($0, Ratings.rating(for: $0)) })
            model.duplicates = ImportSelection.suspectedDuplicates(urls, fingerprints: prints) { p in
                (developed[p] ?? []) + Ratings.knownCopies(size: p.size, headDigest: p.headDigest)
            }
            model.focus = model.visible.first
            model.loading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: Ratings.didChange)) { note in
            if let url = note.object as? URL { model.ratings[url] = Ratings.rating(for: url) }
        }
        .onChange(of: model.visible) { _, visible in
            if let focus = model.focus, !visible.contains(focus) { model.focus = visible.first; model.preview = false }
        }
    }

    private func cell(_ url: URL) -> some View {
        VStack(spacing: 5) {
            ImportSourceImage(url: url, cache: model.cache, maxPixel: 520)
                .frame(height: model.size * 0.68)
                .overlay(alignment: .topLeading) {
                    Button { model.toggle(url) } label: {
                        Image(systemName: model.checked.contains(url) ? "checkmark.square.fill" : "square")
                            .padding(6).background(.black.opacity(0.6))
                    }.buttonStyle(.plain).accessibilityLabel(L("Check photo", zh: "勾选照片"))
                }
            Text(url.lastPathComponent).lineLimit(1).font(.caption)
            if let original = model.duplicates[url] {
                Text(L("Suspected duplicate", zh: "疑似重复")).font(.caption2).foregroundStyle(.orange)
                    .help(original)
            }
            Text(String(repeating: "★", count: model.ratings[url] ?? 0) + String(repeating: "☆", count: 5 - (model.ratings[url] ?? 0)))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(5)
        .background(model.checked.contains(url) ? Color.accentColor.opacity(0.16) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.focus == url ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.focus = url; model.preview = true }
        .onTapGesture { model.click(url) }
    }
}

@MainActor
private struct ImportSourceImage: View {
    let url: URL
    let cache: ThumbnailCache
    let maxPixel: Int
    @State private var image: CGImage?
    @State private var edited = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.2)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if edited {
                Text(L("Edited", zh: "已有编辑")).font(.caption2).padding(4).background(.black.opacity(0.7))
            }
        }
        .task(id: url) {
            let result = await cache.thumbnail(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = result
            let hasEdits = await Task.detached(priority: .utility) { [url] in Sidecar.load(for: url)?.hasUserEdits == true }.value
            guard !Task.isCancelled else { return }
            edited = hasEdits
        }
    }
}

// Serial ImageIO work bounds decode concurrency even during rapid scrolling.
// RAW files without an embedded preview stay placeholders rather than triggering
// a full sensor decode just to browse a folder.
actor ImportPreviewDecoder {
    static let shared = ImportPreviewDecoder()

    nonisolated static func makeCache() -> ThumbnailCache {
        ThumbnailCache(byteLimit: 96_000_000, decoder: { url, size in
            await shared.image(url, maxPixel: size)
        })
    }

    func image(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let raw = ImageDecoder.rawExtensions.contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !raw,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
