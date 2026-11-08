//  MacLibraryDriver.swift — a debug build's way round the Mac library without a mouse.
//
//      SpektraLab --mac-drive [--window-size 1427x977] [--open-catalog <path>] [--capture-window <dir>]
//      notifyutil -p com.spektralab.mac.lib.<step>
//
//  Steps: select.first, select.next, select.extend (⇧→), open (what Return and a double click call),
//  back, tab.library, tab.filters, tab.info, collection.all, collection.import (the latest import with
//  more than one picture), filter.rating (the highest rating with pictures), filter.clear, larger,
//  smaller, viewer, browser.wide, browser.default, mode.library, mode.develop, mode.edit, scroll.last, lighttable; catalog.new, catalog.copy, catalog.update, panel.cancel, panel.state, panel.key, panel.windows, panel.paste (2026-10-24: the save panel and the helper's
//  copy and update, as the menus call them); pair.make (a picture's 组成半格组 on the chosen pictures) and
//  remove.chosen (the chosen pictures' frames removed, as Remove's confirmation does; 2026-10-25); import.drop (a drop of
//  `--drop-list <file>`'s paths, `MacImportDrop.receive`), import.new, import.run, import.cancel and import.state (the
//  page's New Catalog, Import, Cancel, and its state on the console; 2026-11-05); select.all, copy, paste,
//  clip.film, previews.stop, previews.develop, previews.state (a paste's previews, 2026-11-05). Each calls what the page's keys and clicks call, and is
//  logged ("mac library drive"). With `--notify-tag <t>` the names are `com.spektralab.mac.lib.<t>.<step>`.
//  `--window-size` is in Mac points. Not in a release build.

#if DEBUG
import notify
import ObjectiveC
import UIKit

@MainActor
enum MacLibraryDriver {
    private static var tokens: [Int32] = []
    private static var started = false

    static func startIfAsked(model: AppServices, store: any MacLibraryData, open: @escaping (MacImage) -> Void,
                             makePair: @escaping ([MacImage]) -> Void = { _ in },
                             crop: @escaping (MacImage) -> Void = { _ in },
                             arguments: [String] = CommandLine.arguments) {
        guard !started else { return }
        started = true
        if let i = arguments.firstIndex(of: "--window-size"), i + 1 < arguments.count {
            let wh = arguments[i + 1].split(separator: "x").compactMap { Double($0) }
            if wh.count == 2 { resize(to: CGSize(width: wh[0], height: wh[1])) }
        }
        if let i = arguments.firstIndex(of: "--open-catalog"), i + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[i + 1])
            Task {
                await store.start()
                _ = try? await store.open(url)
            }
        }
        guard arguments.contains("--mac-drive") else { return }
        let browser = MacLibraryBrowser.shared
        func apply(_ edit: @escaping (inout MacImageQuery) -> Void) {
            var q = store.query
            edit(&q)
            Task { await store.apply(q) }
        }
        func mode(_ m: WorkspaceMode) {
            if MacShellPath.develop(model.router.path) != nil, let dev = MacShellBar.shared.develop { dev.chooseSurface(m) }
            else { MacLibraryGo.choose(m, rows: store.images, model: model) }
        }
        let steps: [(String, @MainActor () -> Void)] = [
            ("select.first", { browser.selectNone(); browser.focus = nil; browser.move(1, extend: false, in: store.images) }),
            ("select.next", { browser.move(1, extend: false, in: store.images) }),
            ("select.extend", { browser.move(1, extend: true, in: store.images) }),
            ("open", { if let image = browser.primary(store.images) { open(image) } }),
            ("back", { model.router.back() }),
            ("tab.library", { browser.navigator = .library }),
            ("tab.filters", { browser.navigator = .filters }),
            ("tab.info", { browser.navigator = .info }),
            ("collection.all", { Task { await store.select(collection: store.tree.defaultSelection) } }),
            ("collection.import", {
                let imports = store.tree.fixed.first { $0.kind == .recentImports }?.children ?? []
                if let batch = imports.first(where: { ($0.imageCount ?? 0) > 1 }) { Task { await store.select(collection: batch.id) } }
            }),
            ("filter.rating", {
                if let top = store.facets.ratings.filter({ $0.value > 0 && $0.count > 0 }).map(\.value).max() {
                    apply { $0.ratings = [top] }
                }
            }),
            ("filter.clear", { apply { $0 = $0.cleared } }),
            ("catalog.new", { Task { let why = await MacCatalogActions.newCatalog(store); Log.note(.library, "mac library drive: new catalog", ["refused": why ?? "-"]) } }),
            ("catalog.copy", {
                guard let s = store.selectedSource else { return }
                Task { let why = await MacCatalogActions.copyToCatalog(store, s); Log.note(.library, "mac library drive: copy", ["refused": why ?? "-"]) }
            }),
            ("catalog.update", {
                guard let s = store.selectedSource else { return }
                Task { let why = await MacCatalogActions.update(store, s); Log.note(.library, "mac library drive: update", ["refused": why ?? "-"]) }
            }),
            ("panel.cancel", { MacSavePanel.press("cancel") }),
            // The save panel's name field and the window that has the keys, on the console (2026-11-05: Edit's
            // Paste into the panel's field, `MacAppKitEdit`).
            ("panel.state", { NSLog("[panel] name %@ · %@", (MacSavePanel.shown?.value(forKey: "nameFieldStringValue") as? String) ?? "-",
                                    MacAppKitEdit.keyWindowFacts.description) }),
            // This app made active and the panel its key window, for a check run while another app is in front.
            ("panel.key", { MacAppKitEdit.debugActivate(MacSavePanel.shown) }),
            ("panel.windows", { for line in MacAppKitEdit.windowFacts { NSLog("[panel] window %@", line) } }),
            // Whether AppKit's nil-targeted paste: and selectAll: — what the Edit menu sends while the panel
            // is key (`MacAppKitEdit.send`) — would find a taker from the panel's first responder up
            // (`-[NSResponder tryToPerform:with:]`), for a run where the panel cannot be key.
            ("panel.paste", {
                guard let first = MacSavePanel.shown?.value(forKey: "firstResponder") as? NSObject else { NSLog("[panel] no first responder"); return }
                let sel = NSSelectorFromString("tryToPerform:with:")
                typealias Try = @convention(c) (NSObject, Selector, Selector, AnyObject?) -> Bool
                guard let m = class_getInstanceMethod(type(of: first), sel) else { return }
                let call = unsafeBitCast(method_getImplementation(m), to: Try.self)
                let all = call(first, sel, #selector(UIResponder.selectAll(_:)), nil)
                let took = call(first, sel, #selector(UIResponder.paste(_:)), nil)
                NSLog("[panel] from %@ up: selectAll: taken %d, paste: taken %d", String(describing: type(of: first)), all, took)
            }),
            ("pair.make", { makePair(store.images.filter { browser.selection.contains($0.id) }) }),
            // 裁剪 from the library (the owner, 2026-10-26: persistent in every mode).
            ("crop", { if let image = browser.primary(store.images) { crop(image) } }),
            ("remove.chosen", {
                model.remove(Set(store.images.filter { browser.selection.contains($0.id) }.compactMap { $0.develop?.frameID }))
            }),
            ("larger", { browser.resize(by: 1.25) }),
            ("smaller", { browser.resize(by: 1 / 1.25) }),
            // The viewer and its browser beside it (⌥⌘V), for a capture of the split (2026-10-26).
            ("viewer", { browser.viewerShown.toggle() }),
            // The browser panel at its widest and its narrowest (2026-10-27: the rows' captures).
            ("browser.wide", { browser.browserWidth = MacMetric.browserRange.upperBound }),
            ("browser.default", { browser.browserWidth = MacMetric.browserWidth }),
            // The window's mode row, as a press on it does (`MainWindowLayout`, 2026-10-27).
            ("mode.library", { model.router.toLibrary() }),
            ("mode.develop", { mode(.develop) }),
            ("mode.edit", { mode(.edit) }),
            ("scroll.last", { browser.scrollTarget = store.images.last?.id }),
            ("lighttable", { MacLibraryGo.putOnLightTable(store.images.filter { browser.selection.contains($0.id) }, model: model) }),
            // Copy and Paste Settings, and the previews a paste develops (2026-11-05): ⌘A, Edit's Copy and
            // Paste as ⌘C ⌘V press them, a clip of another film (`clip.film`, the next free colour negative
            // after the one the clip has), the sidebar's Stop, and a picture's Develop Previews.
            ("select.all", { browser.selectAll(store.images) }),
            // Where a scroll posted to the process lands (`MacScrollMonitor.debugAim…`, 2026-11-05).
            ("pointer.picture", { MacScrollMonitor.shared.debugAimAtPicture() }),
            ("pointer.row", { MacWheelRows.shared.debugAimAtRow() }),
            ("presets", { NotificationCenter.default.post(name: .spkDebugPresets, object: nil) }),
            ("copy", { _ = MacEditCommands.edit(#selector(UIResponder.copy(_:))) }),
            ("paste", { _ = MacEditCommands.edit(#selector(UIResponder.paste(_:))) }),
            ("clip.film", {
                let films = StockCatalog.shared.films.filter { $0.type == "negative" && $0.use == "still" && $0.monochrome != true }
                let now = model.library.clipboard?.settings.params.filmStock ?? FrameEdit.default.params.filmStock
                let next = films.firstIndex { $0.id == now }.map { films[(films.index(after: $0)) % films.count] } ?? films.first
                var e = model.library.clipboard?.settings ?? .default
                if let next { e.params.filmStock = next.id }
                model.library.clipboard = SettingsClip(groups: [.filmAndPaper], settings: e, sourceName: "drive", sourceAspect: 1.5)
                NSLog("mac library drive: clip film %@", next?.id ?? "-")
            }),
            ("previews.stop", { MacLibraryActions.shared.stopPreviews(model: model) }),
            ("previews.develop", {
                let ids = store.images.filter { browser.selection.contains($0.id) }.compactMap { $0.develop?.frameID }
                NSLog("mac library drive: develop previews %ld", MacLibraryActions.shared.developPreviews(of: ids, model: model))
            }),
            ("previews.state", {
                let frames = store.images.compactMap { $0.develop.flatMap { model.library.frame($0.frameID) } }
                NSLog("mac library drive: previews rows %ld framed %ld busy %ld stale %ld developingCount %ld notice %@", store.images.count, frames.count,
                      frames.filter(\.develop.isBusy).count, frames.filter { MacPreviewStaleness.outOfDate($0, model: model) }.count,
                      model.library.developingCount, MacLibraryActions.shared.notice?.line ?? "-")
            }),
            // A Finder drop, through the entry point the window's drop calls once its files are read
            // (`MacImportDrop.receive`; a real drag cannot be posted to a scratch copy): the paths are
            // `--drop-list <file>`'s lines, read when the step runs (2026-11-05).
            ("import.drop", {
                let list = arguments.firstIndex(of: "--drop-list").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
                let lines = list.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.split(separator: "\n") ?? []
                let urls = lines.map { URL(fileURLWithPath: String($0)) }
                MacImportDrop.receive(.init(urls: urls), router: model.router)
            }),
            ("import.new", { MacImportFlow.debugSession?.destination = .newCatalog }),
            ("import.run", { if let s = MacImportDrop.open { Task { if await s.run() != nil { s.debugCancel?() } } } }),
            ("import.cancel", { MacImportDrop.open?.debugCancel?() }),
            ("import.state", {
                let s = MacImportDrop.open
                let state: [String: Any] = [
                    "import_asked": browser.importAsked, "dropped_pending": browser.droppedPicks?.urls.count ?? -1,
                    // What UIKit has on screen, not a model's word for it (a weak session can outlive its page).
                    "covers_on_screen": MacImportDropCheck.covers().joined(separator: ","),
                    "page_open": s != nil, "picked": s?.picked.map(\.lastPathComponent).joined(separator: ",") ?? "-",
                    "found": s?.files.count ?? -1, "destination": s.map { $0.destinationSource?.name ?? "new catalog" } ?? "-",
                    "placement": s.map { "\($0.placement)" } ?? "-", "not_ready": s?.notReady ?? "-",
                    "sources": store.sources.map(\.name).joined(separator: ","), "selected": store.selectedSource?.name ?? "-",
                    "rows": store.images.count,
                ]
                NSLog("mac library drive: import state %@", "\(state)")   // the console: the log is inert until started
            }),
        ]
        for (name, step) in steps {
            var token: Int32 = 0
            notify_register_dispatch("com.spektralab.mac.lib" + MacWindowCapture.notifyTag(arguments) + "." + name, &token, .main) { _ in
                MainActor.assumeIsolated {
                    step()
                    Log.note(.library, "mac library drive", ["step": name, "collection": store.selectedCollectionID ?? "-",
                                                             "rows": store.images.count, "total": store.total,
                                                             "selected": browser.selection.count, "path": model.router.path.count])
                }
            }
            tokens.append(token)
        }
    }

    /// The window to `size` Mac points, as a person would drag it.
    private static func resize(to size: CGSize) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let points = CGSize(width: size.width / MacMetric.scale, height: size.height / MacMetric.scale)
        scene.sizeRestrictions?.minimumSize = points
        scene.sizeRestrictions?.maximumSize = points
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            scene.sizeRestrictions?.minimumSize = MacWindow.minimumSize
            scene.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }
}
#endif
