//  MacImportDropCheck.swift — a debug build's proof of the drop-to-import path, in the running app
//  (2026-11-05).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --drop-check <dir> [--drop-check-cycles N] [--drop-check-exit]
//
//  Run in a fresh home (it makes catalogs under its `~/Pictures`). Writes `<dir>/report.json`; the exit
//  status is 0 only when every step held. What is on screen is read from UIKit (the presented view
//  controllers), never from the model's word for it: the import page that stayed up after Cancel
//  (2026-11-05, round 1) had `importAsked` false and a weak session the check believed.
//
//  1. **The providers**: a Finder drag's file URLs are the originals, in order; a file-reference URL
//     (`file:///.file/id=…`) is read as the file's path; a provider with only the file's data gives a
//     copy, said to be one, in the drop's temporary folder; a PDF, a LUT and a text file are left out,
//     and an item that names only such types is refused before it is read (`mayHold`).
//  2. **Many files**: a few hundred providers read concurrently, in their order, timed against reading
//     them one at a time.
//  3. **A drop with no catalog** (through `perform`, as the window's drop): the page opens with exactly
//     those picks and New Catalog as *Import To*; a drop on the open page adds; Cancel takes the page off
//     the screen, makes no catalog, leaves nothing pending.
//  4. **Asked again while the last page is going** (the cover's reversed dismissal, measured on 2.1.3):
//     `cycles` times, Cancel then a drop or an Import 0–450 ms later — each gets a *new* page with the
//     new picks, and each Cancel takes it off the screen.
//  5. **Two drops before the page is up** join; **a drop while the page asks Finder** is refused and its
//     temporary copies removed; the panel cancelled closes the page.
//  6. **The owner's flow**: *New Catalog…* (the save panel answered), the catalog made and open and
//     empty; Import, its Finder panel cancelled; then a drop — the page opens with *Import To* that
//     catalog and *Add to Catalog*. And the same with the import page itself cancelled.
//  7. **Temporary copies**: copied into the catalog by default, *Add to Catalog* refused for them in the
//     catalog's words; replaced picks and a closed page remove them.
//  8. **A drop of nothing to import** opens no page and says so.

#if DEBUG
import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
enum MacImportDropCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--drop-check"), i + 1 < arguments.count else { return }
        func arg(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let cycles = arg("--drop-check-cycles").flatMap(Int.init) ?? 10
        let exits = arguments.contains("--drop-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let report = await run(model, out: out, cycles: cycles)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("drop-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(report["passed"] as? Bool == true ? 0 : 1)
            }
        }
    }

    // MARK: - the report

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var checks = 0
        func record(_ name: String, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            steps.append(s)
            print("drop-check: \(name) \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what); print("drop-check: FAIL \(what)") }
        }
    }

    // MARK: - what is on screen

    /// The view controllers presented over every window, by class (a state in brackets): UIKit's own word.
    static func covers() -> [String] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap { w -> [String] in
            var out: [String] = []
            var vc = w.rootViewController?.presentedViewController
            while let v = vc {
                var name = String(describing: type(of: v))
                if v.isBeingPresented { name += "(presenting)" }
                if v.isBeingDismissed { name += "(dismissing)" }
                out.append(name)
                vc = v.presentedViewController
            }
            return out
        }
    }

    private static func ms(since t0: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - t0
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    /// A page up and settled: the session a request presented (not `old`), on screen alone and not moving,
    /// with `picks` picks taken (they arrive a moment after it appears).
    private static func pageUp(notOld old: MacImportSession? = nil, picks: Int = 1, seconds: Double = 6) async -> MacImportSession? {
        let t0 = ContinuousClock.now
        let browser = MacLibraryBrowser.shared
        while ms(since: t0) < Int(seconds * 1000) {
            if let s = MacImportDrop.open, s !== old, !s.closed, s.picked.count >= picks, browser.importAsked,
               browser.importShown == browser.importRequest?.id,
               covers() == ["PresentationHostingController<AnyView>"] { return s }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// The page's Cancel, then the cover off the screen: ms it took, or -1 (still up after 4 s).
    @discardableResult
    private static func cancel(_ s: MacImportSession?) async -> Int {
        let t0 = ContinuousClock.now
        s?.debugCancel?()
        return await gone(t0)
    }

    private static func gone(_ t0: ContinuousClock.Instant = .now) async -> Int {
        while ms(since: t0) < 4000 {
            if covers().isEmpty, !MacLibraryBrowser.shared.importAsked { return ms(since: t0) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return -1
    }

    /// Takes down whatever a failed step left on screen, so the next step starts clean.
    private static func clear() async {
        MacLibraryBrowser.shared.importAsked = false
        MacImportDrop.letGo()
        if await gone() < 0 {
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                w.rootViewController?.dismiss(animated: false)
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    /// The window's drop, as `MacImportDropTarget.performDrop` makes it: Finder's providers for `urls`.
    private static func drop(_ urls: [URL], router: AppRouter) -> Bool {
        MacImportDrop.perform(urls.map { NSItemProvider(object: $0 as NSURL) }, router: router)
    }

    /// The AppKit open panel the page shows (a sheet on the window), when it is up.
    private static func openPanel() -> NSObject? {
        guard let cls = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = cls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return nil }
        return windows.first { NSStringFromClass(type(of: $0)).contains("OpenPanel") && ($0.value(forKey: "visible") as? Bool) == true }
    }

    private static func waitFor(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
        let t0 = ContinuousClock.now
        while ms(since: t0) < Int(seconds * 1000) {
            if ok() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return ok()
    }

    /// A temporary copy as `MacImportDrop.inPlace` keeps one: `<root>/<drop>/<file>/<name>`.
    private static func tempCopy(of url: URL) -> URL {
        let target = MacImportDrop.tempRoot.appending(path: UUID().uuidString).appending(path: UUID().uuidString)
            .appending(path: url.lastPathComponent)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: url, to: target)
        return target
    }

    // MARK: - the run

    static func run(_ model: AppServices, out: URL, cycles: Int) async -> [String: Any] {
        let r = Report()
        // Step 6 makes a catalog in ~/Pictures and selects it: never in the owner's own home (the debug
        // build shares their bundle id), and never over catalogs already there.
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else {
            r.check(false, "CFFIXED_USER_HOME is set (the debug build shares the owner's bundle id): refused to run")
            return ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": false]
        }
        let store = model.macLibrary
        let router = model.router
        let fm = FileManager.default
        let library = MacLibraryBrowser.shared
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        await store.start()
        // The temporary folder is the user's ($TMPDIR, not the scratch home): only what this run leaves counts.
        let tempBefore = Set((try? fm.contentsOfDirectory(atPath: MacImportDrop.tempRoot.path)) ?? [])
        let fresh = store.sources.filter(\.acceptsImports).isEmpty
        r.record("start", ["home": NSHomeDirectory(), "sources": store.sources.map(\.name)])
        r.check(fresh, "the home has no catalog (run in a fresh CFFIXED_USER_HOME)")
        guard fresh else { return ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": false] }

        // Pictures: a folder with a picture in it and one in a subfolder, loose ones, and things that are not.
        let folder = work.appending(path: "Shoot")
        try? fm.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
        let jpeg = picture.jpegData(compressionQuality: 0.9) ?? Data()
        try? jpeg.write(to: folder.appending(path: "a.jpg"))
        try? picture.pngData()?.write(to: folder.appending(path: "sub/b.png"))
        let loose = work.appending(path: "loose.jpg"), other = work.appending(path: "other.jpg"), third = work.appending(path: "third.jpg")
        for u in [loose, other, third] { try? jpeg.write(to: u) }
        let cube = work.appending(path: "look.cube"), pdf = work.appending(path: "notes.pdf"), text = work.appending(path: "readme.txt")
        try? Data("LUT_3D_SIZE 2\n".utf8).write(to: cube)
        try? Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf)
        try? Data("hello".utf8).write(to: text)

        // 1. The providers.
        do {
            let finder = await MacImportDrop.read([NSItemProvider(object: folder as NSURL), NSItemProvider(object: loose as NSURL)])
            r.record("1 finder providers", ["urls": finder.urls.map(\.path), "copies": finder.copies])
            r.check(finder.urls == [folder.standardizedFileURL, loose.standardizedFileURL] && !finder.copies,
                    "a Finder drag's file URLs are the originals, in order, not copies")

            // A file-reference URL as a drag's pasteboard carries it: "file:///.file/id=…" as the bytes
            // under `public.file-url`, and as an NSURL. Measured: Swift's `URL` resolves a reference to its
            // path wherever one is made or bridged, so this stays green with `pathURL`'s own resolution
            // removed (2026-11-05); it is kept as the guard that a dropped reference ends as the path.
            let reference = (NSURL(fileURLWithPath: loose.path).fileReferenceURL() as NSURL?)
            var asBytes: [String] = [], asObject: [String] = []
            if let ref = reference {
                let bytes = NSItemProvider(item: Data((ref.absoluteString ?? "").utf8) as NSData, typeIdentifier: UTType.fileURL.identifier)
                asBytes = await MacImportDrop.read([bytes]).urls.map(\.path)
                asObject = await MacImportDrop.read([NSItemProvider(object: ref)]).urls.map(\.path)
            }
            r.record("1 file-reference URL", ["reference": reference?.absoluteString ?? "-", "as_bytes": asBytes, "as_object": asObject])
            r.check(reference?.absoluteString?.contains("/.file/id=") == true, "the case is a real file-reference URL")
            r.check(asBytes == [loose.standardizedFileURL.path], "a file-reference URL's bytes are read as the file's path: \(asBytes)")
            r.check(asObject == [loose.standardizedFileURL.path], "and an NSURL of one too: \(asObject)")

            // A provider with only the file's data (another app's drag): no file URL, a file representation.
            let handed = NSItemProvider()
            handed.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { done in
                let tmp = FileManager.default.temporaryDirectory.appending(path: "drop-check-\(UUID().uuidString).jpg")
                try? jpeg.write(to: tmp)
                done(tmp, false, nil)
                return nil
            }
            let copied = await MacImportDrop.read([handed])
            let copyURL = copied.urls.first
            r.record("1 data-only provider", ["read": copied.urls.map(\.path), "copies": copied.copies])
            r.check(copied.copies && copied.urls.count == 1, "a provider with only the file's data gives one copy, said to be one")
            r.check(copyURL.map { $0.path.hasPrefix(MacImportDrop.tempRoot.standardizedFileURL.path + "/") && fm.fileExists(atPath: $0.path) } == true,
                    "the copy is in the drop's temporary folder")
            if let copyURL {
                MacImportDrop.discard([copyURL])
                r.check(!fm.fileExists(atPath: copyURL.deletingLastPathComponent().deletingLastPathComponent().path),
                        "a discarded copy's folders are removed")
            }

            let mixed = await MacImportDrop.read([cube, pdf, loose, text].map { NSItemProvider(object: $0 as NSURL) })
            r.record("1 not pictures", ["read": mixed.urls.map(\.lastPathComponent)])
            r.check(mixed.urls == [loose.standardizedFileURL], "a LUT, a PDF and a text file are left out: \(mixed.urls.map(\.lastPathComponent))")
            let pdfOnly = NSItemProvider(item: Data("%PDF".utf8) as NSData, typeIdentifier: UTType.pdf.identifier)
            let jpegOnly = NSItemProvider(item: jpeg as NSData, typeIdentifier: UTType.jpeg.identifier)
            let fileOnly = NSItemProvider(object: cube as NSURL)
            r.check(!MacImportDrop.mayHold([pdfOnly]), "a drag that says it is a PDF is refused before it is read")
            r.check(MacImportDrop.mayHold([jpegOnly]) && MacImportDrop.mayHold([pdfOnly, jpegOnly]), "one that holds a picture is taken")
            r.check(MacImportDrop.mayHold([fileOnly]), "one that says only 'a file' is read (what it is decides then)")
        }

        // 2. Many files.
        do {
            let many = work.appending(path: "Many")
            try? fm.createDirectory(at: many, withIntermediateDirectories: true)
            let n = 400
            let urls = (0..<n).map { many.appending(path: String(format: "IMG_%04d.jpg", $0)) }
            for u in urls { try? jpeg.write(to: u) }
            // Two kinds of provider: made here (in process), and handed back by a pasteboard (loaded
            // from the pasteboard server, as a drag's are from the drag's pasteboard). Interleaved
            // (this machine drifts), three rounds, at several widths; 1 is round 1's one at a time.
            let board = UIPasteboard(name: UIPasteboard.Name("com.spektralab.drop-check.\(UUID().uuidString)"), create: true)
            let widths = [1, 4, 16, 64, n]
            var times: [String: [Int]] = [:]
            var all = MacImportDrop.Picks(urls: []), wrong: [String] = []
            for _ in 0..<3 {
                for kind in ["in_process", "pasteboard"] {
                    for w in widths {
                        var providers = urls.map { NSItemProvider(object: $0 as NSURL) }
                        if kind == "pasteboard", let board {
                            board.itemProviders = providers
                            providers = board.itemProviders
                        }
                        let t0 = ContinuousClock.now
                        let got = await MacImportDrop.read(providers, width: w)
                        times["\(kind) w\(w)", default: []].append(ms(since: t0))
                        if got.urls != urls.map(\.standardizedFileURL) { wrong.append("\(kind) w\(w): \(got.urls.count)") }
                        if kind == "in_process", w == MacImportDrop.readWidth { all = got }
                    }
                }
            }
            if let board { UIPasteboard.remove(withName: board.name) }
            r.record("2 many providers", ["providers": n, "ms": times, "wrong": wrong, "width_used": MacImportDrop.readWidth])
            r.check(all.urls == urls.map(\.standardizedFileURL), "\(n) providers read, every file, in the drop's order")
            r.check(wrong.isEmpty, "at every width, from both kinds of provider: \(wrong.prefix(3))")
        }

        // 3. A drop with no catalog, as the window's drop makes it.
        do {
            r.check(covers().isEmpty, "nothing presented before the first drop: \(covers())")
            r.check(drop([folder, loose], router: router), "the window takes a drop of a folder and a picture")
            let s = await pageUp(picks: 2)
            r.check(s != nil, "a drop opens the import page")
            if let s {
                await s.scanFinished()
                await s.existingRead()
                r.record("3 drop opened the page", ["picked": s.picked.map(\.lastPathComponent), "found": s.files.count,
                                                    "destination": s.destinationSource?.name ?? "new catalog"])
                r.check(s.picked == [folder.standardizedFileURL, loose.standardizedFileURL], "its picks are exactly what was dropped")
                r.check(s.files.count == 3, "and the scan finds the folder's pictures and the loose one: \(s.files.count)")
                r.check(library.droppedPicks == nil, "the page took the drop (none pending)")
                r.check(s.destination == .newCatalog, "with no catalog, Import To is New Catalog")
                _ = drop([other, loose], router: router)
                _ = await waitFor(3) { s.picked.count == 3 }
                r.check(s.picked.map(\.lastPathComponent) == ["Shoot", "loose.jpg", "other.jpg"], "a drop on the open page adds what it did not have: \(s.picked.map(\.lastPathComponent))")
                s.destination = .newCatalog
                s.newCatalogName = "Dropped Then Cancelled"
                let ms = await cancel(s)
                let made = ((try? fm.contentsOfDirectory(atPath: MacCatalogActions.pictures.path)) ?? []).filter { $0.hasSuffix(".spkcatalog") }
                r.record("3 cancelled", ["gone_ms": ms, "covers": covers(), "catalogs": made])
                r.check(ms >= 0, "Cancel takes the page off the screen (\(covers()))")
                r.check(made.isEmpty && store.sources.isEmpty, "a New Catalog chosen and cancelled is never made")
                r.check(library.droppedPicks == nil && MacImportDrop.open == nil, "nothing pending, no page open")
            }
            await clear()
        }

        // 4. Asked again while the last page is going.
        do {
            var bad: [String] = []
            let gaps = [0, 40, 120, 250, 450]
            for i in 0..<max(cycles, 1) {
                let gap = gaps[i % gaps.count]
                let byImport = i % 2 == 1
                _ = drop([loose], router: router)
                guard let first = await pageUp() else { bad.append("#\(i) the first page never came up"); await clear(); continue }
                try? await Task.sleep(for: .milliseconds(150 + (i * 37) % 400))
                let t0 = ContinuousClock.now
                first.debugCancel?()
                try? await Task.sleep(for: .milliseconds(gap))
                let mid = covers()
                if byImport {
                    MacImportFlow.debugPicks = [third]
                    library.importAsked = true      // the sidebar's Import, ⌘I
                } else {
                    _ = drop([third], router: router)
                }
                let second = await pageUp(notOld: first)
                MacImportFlow.debugPicks = nil
                let picked = second?.picked.map(\.lastPathComponent) ?? []
                if second == nil { bad.append("#\(i) \(byImport ? "Import" : "drop") \(gap) ms after Cancel opened no new page (mid \(mid), now \(covers()), old session \(MacImportDrop.open === first ? "still the open one" : "gone"))") }
                else if picked != ["third.jpg"] { bad.append("#\(i) the new page's picks are \(picked)") }
                try? await Task.sleep(for: .milliseconds((i * 53) % 300))
                let off = await cancel(second ?? MacImportDrop.open)
                if off < 0 { bad.append("#\(i) the page stayed on screen after Cancel: \(covers()), importAsked \(library.importAsked)") }
                print("drop-check: cycle \(i) \(byImport ? "import" : "drop") gap \(gap) ms: mid \(mid), second \(second == nil ? "NONE" : "new"), off \(off) ms, \(ms(since: t0)) ms in all")
                if second == nil || off < 0 { await clear() }
            }
            r.record("4 asked again while going", ["cycles": cycles, "failed": bad])
            r.check(bad.isEmpty, "every Import or drop after a Cancel gets a new page, and every Cancel takes it away (\(bad.count) of \(cycles) failed: \(bad.prefix(3)))")
            await clear()
        }

        // 4b. The net under a stuck page (2026-11-05: one plain Cancel in the gate run left the page standing,
        // not dismissing, nothing asked). SwiftUI cannot be made to leave it standing on purpose, so the
        // net's own act is checked: the page's controller found (`MacImportCoverProbe`), taken down by
        // UIKit alone, and SwiftUI left consistent: the request let go, the page's `onDisappear` run,
        // nothing else dismissed, and the next drop gets a new page that a Cancel closes.
        do {
            _ = drop([loose], router: router)
            let first = await pageUp()
            let id = library.importShown
            r.check(first != nil && id != nil && MacImportCover.stands(id!), "the net finds the open page's own controller")
            if let id {
                let t0 = ContinuousClock.now
                MacImportCover.takeDown(id)
                let off = await gone(t0)
                r.record("4b the net takes the page down", ["gone_ms": off, "covers": covers(), "shown": library.importShown.map { "\($0)" } ?? "-",
                                                         "asked": library.importAsked])
                r.check(off >= 0 && library.importShown == nil, "taken down by UIKit, the page goes and SwiftUI lets its request go (\(covers()))")
                r.check(first?.closed == true, "and the page's session is closed")
            }
            _ = drop([third], router: router)
            let second = await pageUp(notOld: first)
            r.check(second?.picked.map(\.lastPathComponent) == ["third.jpg"], "after it, a drop opens a new page with the drop")
            r.check(await cancel(second) >= 0, "and that page's Cancel takes it away")
            await clear()
        }

        // 5. Two drops before the page is up; a drop while the page asks Finder.
        do {
            MacImportDrop.receive(.init(urls: [loose]), router: router)
            MacImportDrop.receive(.init(urls: [other, loose]), router: router)
            let s = await pageUp(picks: 2)
            r.check(s?.picked.map(\.lastPathComponent) == ["loose.jpg", "other.jpg"],
                    "two drops before the page is up join: \(s?.picked.map(\.lastPathComponent) ?? [])")
            await cancel(s)
            await clear()

            library.importAsked = true          // Import: the page asks Finder as it opens
            let panelUp = await waitFor(8) { openPanel() != nil && MacImportDrop.open?.finderUp == true }
            r.check(panelUp, "Import shows the Finder panel")
            if panelUp {
                r.check(!MacImportDrop.accepts(router), "a drop is refused while the page asks Finder")
                let temp = tempCopy(of: loose)
                MacImportDrop.receive(.init(urls: [temp], copies: true), router: router)
                r.check(library.droppedPicks == nil, "and is not kept for later")
                r.check(!fm.fileExists(atPath: temp.path), "its temporary copy is removed")
                openPanel()?.perform(NSSelectorFromString("cancel:"), with: nil)
                let off = await gone()
                r.record("5 drop under the Finder panel", ["gone_ms": off, "covers": covers()])
                r.check(off >= 0, "the panel cancelled with nothing picked closes the page (\(covers()))")
            }
            await clear()
        }

        // 6. The owner's flow: New Catalog…, Import cancelled, then a drop.
        do {
            let place = MacCatalogActions.pictures.appending(path: "Owner.spkcatalog")
            MacSavePanel.debugAnswer = place
            let why = await MacCatalogActions.newCatalog(store)
            MacSavePanel.debugAnswer = nil
            let made = store.sources.first { $0.path.map { URL(fileURLWithPath: $0).standardizedFileURL } == place.standardizedFileURL }
                ?? store.sources.first { $0.name == "Owner" }
            r.record("6 new catalog", ["refused": why ?? "-", "sources": store.sources.map(\.name), "selected": store.selectedSource?.name ?? "-"])
            r.check(why == nil && made != nil && store.selectedSourceID == made?.id, "New Catalog… makes the catalog and opens it")
            r.check(store.images.isEmpty, "empty")

            library.importAsked = true
            let panelUp = await waitFor(8) { openPanel() != nil }
            r.check(panelUp, "Import shows the Finder panel")
            openPanel()?.perform(NSSelectorFromString("cancel:"), with: nil)
            r.check(await gone() >= 0, "its Finder panel cancelled closes the import page (\(covers()))")

            r.check(drop([folder], router: router), "then the window takes a drop")
            let s = await pageUp()
            r.check(s != nil, "and it opens the import page")
            if let s, let made {
                r.record("6 drop after New Catalog", ["destination": s.destinationSource?.name ?? "new catalog", "placement": "\(s.placement)"])
                r.check(s.destination == .source(made.id), "Import To is the catalog just made: \(s.destinationSource?.name ?? "new catalog")")
                r.check(s.placement == .inPlace, "with Add to Catalog")
                r.check(s.picked == [folder.standardizedFileURL], "and the drop as its picks")
                await cancel(s)
            }
            await clear()

            // The same with the import page itself cancelled (its picks from the Finder panel's stand-in).
            MacImportFlow.debugPicks = [loose]
            library.importAsked = true
            let p = await pageUp()
            MacImportFlow.debugPicks = nil
            r.check(await cancel(p) >= 0, "the import page cancelled goes")
            _ = drop([other], router: router)
            let q = await pageUp(notOld: p)
            r.check(q?.destination == made.map { .source($0.id) } && q?.picked.map(\.lastPathComponent) == ["other.jpg"],
                    "a drop after it opens the page for that catalog with the drop: \(q?.destinationSource?.name ?? "-") \(q?.picked.map(\.lastPathComponent) ?? [])")
            await cancel(q)
            await clear()
        }

        // 7. Temporary copies.
        do {
            let temp = tempCopy(of: loose)
            MacImportDrop.receive(.init(urls: [temp], copies: true), router: router)
            let s = await pageUp()
            if let s {
                await s.scanFinished()
                r.check(s.picksAreCopies && s.placement == .intoLibrary, "temporary copies default to a copy into the catalog (\(s.placement))")
                s.placement = .inPlace
                r.check(!s.canImport && s.notReady == L("These pictures came from another app: copy them into the catalog or to a folder."),
                        "and Add to Catalog is refused for them, in the catalog's words: \(s.notReady ?? "-")")
                _ = await s.receivePicks([loose])        // the Finder panel's Choose…: the picks replaced
                r.check(!fm.fileExists(atPath: temp.path), "copies replaced by a new pick are removed")
                let temp2 = tempCopy(of: other)
                _ = await s.receivePicks([temp2], adding: true, copies: true)
                await cancel(s)
                r.check(!fm.fileExists(atPath: temp2.deletingLastPathComponent().path), "a closed page removes its copies")
            } else {
                r.check(false, "a drop of temporary copies opens the page")
            }
            await clear()
        }

        // 8. Nothing to import.
        do {
            MacLibraryActions.shared.refusal = nil
            r.check(drop([cube, pdf], router: router), "a drop the cursor could not judge is read")
            let said = await waitFor(4) { MacLibraryActions.shared.refusal != nil }
            r.record("8 nothing to import", ["covers": covers(), "said": MacLibraryActions.shared.refusal ?? "-"])
            r.check(said && !library.importAsked, "a drop of a LUT and a PDF opens no page and says why")
            MacLibraryActions.shared.refusal = nil
            MacLibraryActions.shared.refusalTitle = nil
            await clear()
        }

        r.check(covers().isEmpty && !library.importAsked && MacImportDrop.open == nil, "nothing is left on screen at the end: \(covers())")
        let leftovers = Set((try? fm.contentsOfDirectory(atPath: MacImportDrop.tempRoot.path)) ?? []).subtracting(tempBefore)
        r.check(leftovers.isEmpty,"no drop's temporary folder is left: \(leftovers)")
        print("drop-check: \(r.failures.isEmpty ? "passed" : "\(r.failures.count) failure(s)") (\(r.checks) checks)")
        return ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": r.failures.isEmpty]
    }
}
#endif
