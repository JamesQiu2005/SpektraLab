//  MacImportDrop.swift — pictures and folders dragged onto the window open the import page (2026-11-05).
//
//  The owner: "drag in a lot of images / a single image: if no catalog is created or opened, this
//  behaviour would automatically enter the import page, and all the existing settings still apply."
//  Until now the Mac window took no drop at all: the only drop handler was the window's wide library page
//  (`LibraryWidePage.drop`, a copy into the app library), which the Mac never shows, so a Finder drag
//  was refused in every mode — with no catalog, after a catalog was made, after an import was
//  cancelled ("the bug is persistent": nothing was ever there to take it).
//
//  Now a drop on the window, in 图库, 冲洗 or 编辑 (`MainWindowLayout`), is the Import command with the
//  Finder panel already answered: the page opens with exactly what was dropped as its picks, and every
//  choice of the page applies as it does after the panel — Include Subfolders, Exclude Duplicates, Add
//  to Catalog or a copy, the collection, the filters; with no catalog open, *Import To* is New Catalog
//  (its name and folder), as after the panel; with a catalog open (one just made by *New Catalog…*
//  among them), that catalog. A drop on the open import page adds to its picks (Capture One's Import
//  window takes a drop the same way), and a second drop before the page is up joins the first; during
//  its run, while its own Finder panel is up, or under any other page's cover or sheet, a drop is
//  refused (the cursor shows it), as is one that is plainly no picture, folder or catalog. A dropped
//  catalog or session is opened, as the panel's pick of one is.
//
//  The files are the originals, not copies: a Finder drag carries their file URLs (`public.file-url`,
//  sometimes as a file-reference URL, `file:///.file/id=…`, read as its path), and the app is not
//  sandboxed, so *Add to Catalog* references the files where they are. An app that hands over only a
//  temporary file (a picture dragged out of another app, not Finder) gets it copied into a folder of the
//  drop's own, the page will not reference those copies (`picksAreCopies`), and the folder is removed
//  whenever the copies are let go (`discard`).
//
//  The page is one request at a time (`MacLibraryBrowser.importRequest`): a drop just after a Cancel
//  gets a new page, never the one still being taken down.

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum MacImportDrop {
    /// What a drop gave: the URLs, and whether any are copies the system handed over (not in place).
    struct Picks: Equatable {
        var urls: [URL]
        var copies = false

        /// `more` after these, without the ones already here.
        func adding(_ more: Picks) -> Picks {
            let known = Set(urls.map(\.standardizedFileURL))
            return Picks(urls: urls + more.urls.filter { !known.contains($0.standardizedFileURL) }, copies: copies || more.copies)
        }
    }

    /// The types the window's drop target accepts: Finder's file URLs first, then what an app may
    /// offer of a picture or a folder.
    static let types: [UTType] = [.fileURL, .folder, .directory, .rawImage, .image]

    /// A drop is taken now: no other page's cover or sheet is up, no import is running, and the import
    /// page is not asking Finder (its answer would replace the picks). The open page itself takes one.
    static func accepts(_ router: AppRouter) -> Bool {
        let browser = MacLibraryBrowser.shared
        guard router.cover == nil, router.sheets.isEmpty, !browser.exportAsked, !browser.moveShown,
              !browser.sourcePickerShown, !running, open?.finderUp != true else { return false }
        return true
    }

    /// The import page's session while it is open (`MacImportFlow`).
    static weak var open: MacImportSession?
    /// An import's run is in hand: a drop then is refused, not queued.
    static var running: Bool { open?.progress != nil }

    /// The window's drop, and the import page's: the providers' files, then `receive`. True when the drop
    /// is taken (its files are read after, off the drop's own call, while the window says how many).
    static func perform(_ providers: [NSItemProvider], router: AppRouter) -> Bool {
        guard !providers.isEmpty, accepts(router) else { return false }
        let browser = MacLibraryBrowser.shared
        browser.dropReading = providers.count
        Task {
            let t0 = ContinuousClock.now
            let picks = await read(providers)
            browser.dropReading = nil
            let d = ContinuousClock.now - t0
            Log.note(.library, "mac import: dropped", ["files": picks.urls.count, "providers": providers.count, "copies": picks.copies,
                                                       "ms": Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)])
            if picks.urls.isEmpty {
                nothingToImport(providers)
                return
            }
            receive(picks, router: router)
        }
        return true
    }

    /// The one way in after the files are read (the driver's `import.drop` and the checks call it too):
    /// the picks are handed to the import page, which opens if it is not open. A drop the page has not
    /// taken yet is joined, never replaced; one refused now is let go (its copies removed).
    static func receive(_ picks: Picks, router: AppRouter) {
        guard !picks.urls.isEmpty else { return }
        guard accepts(router) else { discard(picks.urls); return }
        let browser = MacLibraryBrowser.shared
        browser.droppedPicks = browser.droppedPicks.map { $0.adding(picks) } ?? picks
        // A new request if none (a page being taken down is not one); open, the page adds them (`onChange`);
        // asked, not yet up, it takes them as it appears.
        browser.importAsked = true
    }

    /// A drop not taken by the page that closes: let go, with any temporary copies.
    static func letGo() {
        let browser = MacLibraryBrowser.shared
        if let left = browser.droppedPicks { discard(left.urls) }
        browser.droppedPicks = nil
    }

    /// Nothing dropped was a picture, a folder or a catalog: said where the person is looking.
    private static func nothingToImport(_ providers: [NSItemProvider]) {
        Log.warn(.library, "mac import: a drop held nothing to import",
                 ["types": providers.flatMap(\.registeredTypeIdentifiers).joined(separator: ",")])
        let words = L("Only pictures, folders of pictures and catalogs can be imported.")
        if let page = open, !page.closed {
            page.say(words)
        } else {
            let actions = MacLibraryActions.shared
            actions.refusalTitle = L("Nothing to Import")
            actions.refusal = words
        }
    }

    // MARK: - what a drop may hold

    /// Before anything is read (the drag is over the window): false only when every item says it is
    /// something else — a PDF, a LUT, text — so the cursor refuses it. An item that says only "a file"
    /// may be anything and is read; what it is decides then (`usable`).
    nonisolated static func mayHold(_ providers: [NSItemProvider]) -> Bool {
        if providers.isEmpty { return true }
        let generic: [UTType] = [.fileURL, .url, .data, .item, .content, .text, .plainText, .utf8PlainText]
        return providers.contains { p in
            let named = p.registeredTypeIdentifiers.compactMap { UTType($0) }.filter { t in !generic.contains(t) }
            if named.isEmpty { return true }
            return named.contains { t in
                t.isDynamic || t.conforms(to: .image) || t.conforms(to: .folder) || t.conforms(to: .directory)
                    || t.conforms(to: .package)
                    || MacLibraryDocuments.kind(of: URL(fileURLWithPath: "x." + (t.preferredFilenameExtension ?? "-"))) != nil
            }
        }
    }

    /// A dropped file the page can take: a folder (walked by the scan), a catalog or session (opened), or
    /// a picture by the scan's own classification (`MacImportScan.classify`).
    nonisolated static func usable(_ url: URL) -> Bool {
        if MacLibraryDocuments.kind(of: url) != nil { return true }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return true }
        if case .picture = MacImportScan.classify(url, type: nil) { return true }
        return false
    }

    // MARK: - reading the providers

    /// Where a drop's temporary copies go: `<root>/<drop>/<file>/<name>`.
    nonisolated static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "SpektraLab Drops")
    }

    /// Each provider's file, read all at once (a Finder drag of 800 files is 800 providers), kept in the
    /// drop's order: its URL where it is (a Finder drag), else the system's file in place, else a copy of
    /// the system's temporary file. A provider with none of these, or whose file is no picture, folder or
    /// catalog, is left out (a copy made for it removed).
    nonisolated static func read(_ providers: [NSItemProvider], width: Int = readWidth) async -> Picks {
        let keep = tempRoot.appending(path: UUID().uuidString)
        let boxes = providers.map(ProviderBox.init)
        let found = await withTaskGroup(of: (Int, URL, Bool)?.self) { group in
            // At most `width` in flight: each waits on the provider's own loading.
            var next = 0
            func start() {
                guard next < boxes.count else { return }
                let i = next, box = boxes[i]
                next += 1
                group.addTask { await one(box.provider, keep: keep).map { (i, $0.0, $0.1) } }
            }
            for _ in 0..<max(width, 1) { start() }
            var out: [(Int, URL, Bool)] = []
            for await r in group {
                if let r { out.append(r) }
                start()
            }
            return out.sorted { $0.0 < $1.0 }
        }
        var picks = Picks(urls: [])
        var dropped: [URL] = []
        var seen = Set<String>()     // a set: a scan of the list per file cost 0.4 s at 400 files (measured)
        for (_, url, copied) in found {
            guard usable(url) else { if copied { dropped.append(url) }; continue }
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            picks.urls.append(url)
            picks.copies = picks.copies || copied
        }
        discard(dropped)
        return picks
    }

    /// How many providers are read at once (measured by `--drop-check`, step 2).
    nonisolated static let readWidth = 16

    /// `NSItemProvider` is not `Sendable`; each is read by one task only.
    private struct ProviderBox: @unchecked Sendable { let provider: NSItemProvider }

    nonisolated private static func one(_ p: NSItemProvider, keep: URL) async -> (URL, Bool)? {
        if let url = await fileURL(p) { return (url, false) }
        guard let type = p.registeredTypeIdentifiers.first(where: { id in
            UTType(id).map { t in t.conforms(to: .image) || t.conforms(to: .folder) || t.conforms(to: .directory) } ?? false
        }) else { return nil }
        return await inPlace(p, type: type, keep: keep)
    }

    /// `public.file-url`: Finder's drag. Read as data (the URL's bytes) or as a URL, as the provider
    /// offers; a file-reference URL (`file:///.file/id=…`) is resolved to the file's path, so a catalog
    /// row stores the path and a dropped `.spkcatalog` is known by its extension.
    nonisolated static func fileURL(_ p: NSItemProvider) async -> URL? {
        guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let u as URL: url = u
                case let d as Data: url = URL(dataRepresentation: d, relativeTo: nil)
                case let s as String: url = URL(string: s)
                default: url = nil
                }
                done.resume(returning: url.flatMap(pathURL))
            }
        }
    }

    /// A file URL as a path URL: a file-reference URL resolved (nil when the file is gone). Measured
    /// 2026-11-05: Swift's `URL` already resolves a reference wherever one is made or bridged, so this
    /// is a guard for one that arrives unresolved (a vanished file's), not the thing that resolves them.
    nonisolated static func pathURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        if (url as NSURL).isFileReferenceURL() { return (url as NSURL).filePathURL?.standardizedFileURL }
        return url.standardizedFileURL
    }

    /// The system's file for `type`: in place if the provider can give it so, else copied under `keep`
    /// while the system's temporary file still exists (only during the completion handler).
    nonisolated private static func inPlace(_ p: NSItemProvider, type: String, keep: URL) async -> (URL, Bool)? {
        await withCheckedContinuation { (done: CheckedContinuation<(URL, Bool)?, Never>) in
            _ = p.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, isInPlace, _ in
                guard let url else { done.resume(returning: nil); return }
                if isInPlace { done.resume(returning: (url.standardizedFileURL, false)); return }
                let fm = FileManager.default
                let target = keep.appending(path: UUID().uuidString).appending(path: url.lastPathComponent)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: url, to: target)
                    done.resume(returning: (target, true))
                } catch {
                    done.resume(returning: nil)
                }
            }
        }
    }

    /// Removes the temporary copies among `urls` (anything else is left alone): each copy's folder, and
    /// its drop's folder once empty.
    nonisolated static func discard(_ urls: [URL]) {
        let root = tempRoot.standardizedFileURL.path + "/"
        let fm = FileManager.default
        for url in urls {
            let path = url.standardizedFileURL.path
            // `<drop>/<file>/<name>` below the root, and nothing shallower.
            guard path.hasPrefix(root), path.dropFirst(root.count).split(separator: "/").count >= 3 else { continue }
            let file = url.standardizedFileURL.deletingLastPathComponent()
            try? fm.removeItem(at: file)
            let drop = file.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: drop.path))?.isEmpty == true { try? fm.removeItem(at: drop) }
        }
    }
}

/// Whether a drop zone's 松手即导入 note is up (`MacDropNoteState`), for the view that draws it.
@MainActor
@Observable
final class MacImportDropWatch {
    private(set) var note = MacDropNoteState()
    var shown: Bool { note.shown }

    func apply(_ change: (inout MacDropNoteState) -> Void) {
        var next = note
        change(&next)
        if next != note { note = next }
    }
}

extension View {
    /// The window's, or the import page's, drop target for 松手即导入 (`MacDropOffer`): `watch` says when
    /// its note is up.
    func macImportDropZone(router: AppRouter, watch: MacImportDropWatch) -> some View {
        background { MacImportDropZone(router: router, watch: watch).allowsHitTesting(false) }
    }
}

/// The drop target itself, through UIKit (2026-11-09, PRD-C): a `UIDropInteraction` on the view of the
/// controller that hosts the zone — the window's for the window, the presented page's own for the import
/// page — so it hears every drag over any part of it. Unlike SwiftUI's `onDrop` its session says
/// whether the drag began in this app (`localDragSession`) and always says it has ended
/// (`sessionDidEnd`), wherever it ended. A drag of a kind the page takes (`MacDropOffer`) shows the note
/// while the target takes drops (`MacImportDrop.accepts`), and is refused with the cursor's ⊘ while it
/// does not; one of files that are not pictures is refused with the ⊘; anything else — a drag from inside
/// the app, a web page's picture, text — is not this target's at all, and nothing is shown.
struct MacImportDropZone: UIViewRepresentable {
    let router: AppRouter
    let watch: MacImportDropWatch

    func makeCoordinator() -> Coordinator { Coordinator(router: router, watch: watch) }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) { context.coordinator.router = router }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) { coordinator.detach() }

    /// Placed in the zone's view: when it is in a window, the interaction goes on the top of its hierarchy.
    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            MainActor.assumeIsolated { if window != nil { coordinator?.attach(near: self) } else { coordinator?.detach() } }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDropInteractionDelegate, UIGestureRecognizerDelegate {
        var router: AppRouter
        let watch: MacImportDropWatch
        private var interaction: UIDropInteraction?
        private var click: UITapGestureRecognizer?
        private weak var host: UIView?
        private var observers: [NSObjectProtocol] = []

        init(router: AppRouter, watch: MacImportDropWatch) {
            self.router = router
            self.watch = watch
            super.init()
            // The app no longer in front: no drag of its is over it. (A backstop: the session's end is heard.)
            for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.interrupt("the app left the front") }
                })
            }
        }

        deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

        func attach(near view: UIView) {
            // The view of the controller that hosts the zone: the window's own for the window, the presented
            // page's for the import page (never the window's transition view, which both are inside).
            var top = view
            while !(top.next is UIViewController), let up = top.superview, !(up is UIWindow) { top = up }
            guard top !== host else { return }
            detach()
            let drop = UIDropInteraction(delegate: self)
            top.addInteraction(drop)
            // A click anywhere on it: a note still up then belongs to no drag (a backstop).
            let tap = UITapGestureRecognizer(target: self, action: #selector(clicked))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            top.addGestureRecognizer(tap)
            interaction = drop
            click = tap
            host = top
            #if DEBUG
            NSLog("[drop] the import drop zone is on %@ (%.0f x %.0f)", String(describing: type(of: top)), top.bounds.width, top.bounds.height)
            #endif
        }

        func detach() {
            if let interaction { host?.removeInteraction(interaction) }
            if let click { host?.removeGestureRecognizer(click) }
            interaction = nil
            click = nil
            host = nil
            watch.apply { $0.ended() }
        }

        @objc private func clicked() { interrupt("a click") }

        /// A key while the note is up (the page's own key handler calls it): the same backstop.
        func interrupt(_ why: String) {
            guard watch.shown else { return }
            watch.apply { $0.interrupted() }
            Log.note(.library, "mac import: the drop note taken down", ["by": why])
        }

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        private func verdict(_ session: UIDropSession) -> MacDropVerdict {
            MacDropOffer.verdict(local: session.localDragSession != nil, items: session.items.map(\.itemProvider.registeredTypeIdentifiers))
        }

        // MARK: UIDropInteractionDelegate

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            switch verdict(session) {
            case .files, .notImportable: return true      // the second only to show the cursor's ⊘
            case .inApp, .noFile, .empty: return false
            }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            let v = verdict(session), ok = MacImportDrop.accepts(router)
            watch.apply { $0.entered(v, accepting: ok) }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            let v = verdict(session), ok = MacImportDrop.accepts(router)
            // An update after a click took the note down brings nothing back (`MacDropNoteState.updated`).
            watch.apply { $0.updated(v, accepting: ok) }
            return UIDropProposal(operation: v.takes && ok ? .copy : .forbidden)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            watch.apply { $0.exited() }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            watch.apply { $0.ended() }
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            watch.apply { $0.dropped() }
            guard verdict(session).takes else { return }
            _ = MacImportDrop.perform(session.items.map(\.itemProvider), router: router)
        }
    }
}
