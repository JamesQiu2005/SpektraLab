//  MacSettingsCheck.swift — a debug build's proof of the Mac's Settings page, in the running app.
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --settings-check <dir> [--settings-check-exit]
//
//  Writes `<dir>/report.json`, every step timed, and draws the page to `<dir>/<language>-<size>-<section>.png`
//  (its own view, as the window holds it: a presented page is not in `--capture-window`'s picture):
//
//  A. **Every way in opens this page**: ⌘,'s own action (`SettingsRequest.openFromMenu`, what
//     `AppMenuCommands`' item calls), and the Mac library's "+" › Settings and › Sources (the very closures
//     the sidebar's two items call, handed here as the sidebar appears). Each must show the Mac page
//     (never the window's `SettingsScreen`) on its section: General, General, Sources.
//  B. **Every Settings item is shown**: each one `MacSettingsCoverage.table` says is shown must have been
//     shown on its section (the page's views note what they stand for as they appear, `macSettingsItem`).
//  C. **The three storage budgets**: each control's own setter (`MacSettingsStorage.budgets`) moved to
//     another choice must change `AppSettings`' value (and the library's report's, for the two it holds),
//     and is put back after; the values at the end must be the values at the start.
//  D. **Sources lists the Mac library's sources**: a scratch folder of one picture is opened as a source
//     (`MacLibraryData.open`), and every source of the store must be drawn on the Sources section; the
//     scratch source is removed after, and the selected source selected again.
//  E. **The pictures**: every section in all four languages, at the window's least size
//     (847 × 539 Mac points) and a large one (1,440 × 900).
//  F. **The selected library's previews** (2026-11-05, before E, the scratch folder selected): its picture
//     developed by hand is kept in that library's `Cache/Previews` (the app's own catalog for a folder),
//     Storage shows the group (where, how many, *Delete Previews*) and measures one develop, *Delete
//     Previews* (the button's own action) takes the file and leaves the library's database as it was; the
//     frame's develop is marked missing, its size kept and the Light Table still taking the frame (review,
//     2026-11-05); then a develop made with the frame carried from no library lands in the app's `Previews`
//     and moves into the library, under its own name, when the frame is carried again.
//  G. **A SpektraLab catalog and a session** made in `<dir>/work/Libraries`, the scratch picture copied in:
//     its develop is in `X.spkcatalog/Cache/Previews` / the session's `.SpektraLab/Cache/Previews`; the
//     session's `session.scan` and sync add nothing for it, and the same file in a visible folder of the
//     session is added (the control); *Delete Previews* empties each. Both sources are removed after.
//  H. **A catalog moved in Finder** (review, 2026-11-05): a catalog referencing the scratch picture keeps its
//     develop; removed from Sources, moved, opened again from its new place and carried, the frame points at
//     the develop that moved with the package (same name, same stamp), and nothing is made where it was. Its
//     `Cache` deleted by hand and the frame carried again: the develop reads missing, its size kept, and a
//     develop lands in the moved catalog.
//
//  Refuses to run without `CFFIXED_USER_HOME` (the debug build shares the owner's bundle id). Nothing is
//  written outside `<dir>` and the scratch home; the language a check's launch is in is never kept
//  (`Language.start`). Not in a release build.

#if DEBUG
import Foundation
import UIKit

@MainActor
enum MacSettingsCheck {
    // MARK: the page's hooks

    /// The section the page shows, and the way to show another; nil while no page is up.
    private(set) static var section: MacSettingsSection?
    private static var select: ((MacSettingsSection) -> Void)?
    /// How many times a page appeared.
    private(set) static var appearances = 0
    /// What the page's views stood for as they appeared, since the last `forget`.
    private(set) static var seen = Set<String>()
    private(set) static var sources = Set<MacSource.ID>()
    /// The Mac library sidebar's "+" › Settings and › Sources, as its items call them.
    static var plusMenu: (settings: () -> Void, sources: () -> Void)?

    static func attach(section: MacSettingsSection, select: @escaping (MacSettingsSection) -> Void) {
        if self.section == nil { appearances += 1 }
        self.section = section
        self.select = select
    }
    static func detach() { section = nil; select = nil }
    static func saw(_ keys: [String]) { seen.formUnion(keys) }
    static func sawSource(_ id: MacSource.ID) { sources.insert(id) }
    private static func forget() { seen = []; sources = [] }

    // MARK: running

    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--settings-check"), i + 1 < arguments.count,
              arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let exits = arguments.contains("--settings-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(2))
            let report = await run(model, out: out)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("settings-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        func step(_ name: String, _ ms: Double, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            s["ms"] = (ms * 10).rounded() / 10
            steps.append(s)
            print("settings-check: \(name) \(Int(ms)) ms")
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("settings-check: FAIL \(what)") }
        }
    }

    private static func ms(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func until(_ seconds: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(ms))
        }
        return done()
    }

    /// Closes the page and waits until it has gone.
    private static func close(_ model: AppServices) async {
        model.router.dismissCover()
        _ = await until(10) { section == nil && model.router.cover == nil }
        try? await Task.sleep(for: .milliseconds(700))
    }

    static func run(_ model: AppServices, out: URL) async -> [String: Any] {
        let r = Report()
        let fm = FileManager.default
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else {
            r.check(false, "CFFIXED_USER_HOME is set (the debug build shares the owner's bundle id): refused to run")
            return ["steps": r.steps, "failures": r.failures, "passed": false]
        }
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "png" {
            try? fm.removeItem(at: old)
        }
        r.step("start", 0, ["home": NSHomeDirectory(), "fixed_home": home, "recipe": "\(model.settings.recipe)",
                            "ticked": model.recipes.saved(as: model.settings.recipe)?.name ?? "none",
                            "recipes": model.recipes.recipes.map { "\($0)" }])
        let settings = model.settings
        let startLimits = [settings.workingCopiesLimit, settings.previewCopiesLimit, settings.fullRenderCacheLimit]
        let startLanguage = Language.shared.current

        // ---- A. Every way in. ----
        var t0 = ContinuousClock.now
        let sidebar = await until(30) { plusMenu != nil }
        r.check(sidebar, "the Mac library's sidebar is up and its \"+\" items are reachable")
        let ways: [(String, () -> Void, MacSettingsSection)] = [
            ("⌘, (AppMenuCommands' Settings item)", { SettingsRequest.openFromMenu(model.router) }, .general),
            ("the library's \"+\" › Settings", { plusMenu?.settings() }, .general),
            ("the library's \"+\" › Sources", { plusMenu?.sources() }, .sources),
        ]
        var opened: [[String: Any]] = []
        for (i, way) in ways.enumerated() {
            t0 = ContinuousClock.now
            let before = appearances
            way.1()
            let came = await until(10) { appearances > before && section != nil }
            try? await Task.sleep(for: .milliseconds(500))
            snapshot("way-\(i + 1)", out: out)
            opened.append(["way": way.0, "shown": came, "section": section?.rawValue ?? "none",
                           "cover": model.router.cover?.id ?? "none", "ms": (ms(since: t0) * 10).rounded() / 10])
            r.check(came, "A: \(way.0) opens the Mac Settings page")
            r.check(section == way.2, "A: \(way.0) opens it on \(way.2.rawValue) (\(section?.rawValue ?? "none"))")
            await close(model)
        }
        r.step("A: the ways in", 0, ["ways": opened])

        // ---- B. Every item of the table shown on its section. ----
        t0 = ContinuousClock.now
        let items = MacSettingsCoverage.table.keys.sorted()
        forget()
        SettingsRequest.openFromMenu(model.router)
        _ = await until(10) { section != nil }
        try? await Task.sleep(for: .milliseconds(500))
        // The title bar (Settings, Done) stands over every section: what it showed as the page opened.
        let bar = seen.intersection(["Settings", "Done"])
        var seenBySection: [MacSettingsSection: Set<String>] = [:]
        // From another section first: the page opened on General, and only a change draws a section anew.
        select?(.diagnostics)
        try? await Task.sleep(for: .milliseconds(500))
        for s in MacSettingsSection.allCases {
            forget()
            select?(s)
            try? await Task.sleep(for: .milliseconds(700))
            seenBySection[s] = seen.union(bar)
        }
        var accounted: [[String: Any]] = []
        for key in items {
            var row: [String: Any] = ["item": key]
            switch MacSettingsCoverage.table[key] {
            case .shown(let s)?:
                let ok = seenBySection[s]?.contains(key) == true
                row["mac"] = "shown on \(s.rawValue)" + (ok ? "" : " (NOT SEEN)")
                r.check(ok, "B: \"\(key)\" is shown on \(s.rawValue)")
            case .shownWhen(let s, let when, let otherwise)?:
                if when(model) {
                    let ok = seenBySection[s]?.contains(key) == true
                    row["mac"] = "shown on \(s.rawValue)" + (ok ? "" : " (NOT SEEN)")
                    r.check(ok, "B: \"\(key)\" is shown on \(s.rawValue)")
                } else {
                    row["mac"] = "not shown now: \(otherwise)"
                }
            case nil:
                break
            }
            accounted.append(row)
        }
        r.step("B: every Settings item", ms(since: t0), [
            "table_items": items.count, "items": accounted,
            "seen": Dictionary(uniqueKeysWithValues: seenBySection.map { ($0.key.rawValue, $0.value.sorted()) }),
        ])

        // ---- C. The three budgets. ----
        t0 = ContinuousClock.now
        select?(.storage)
        try? await Task.sleep(for: .milliseconds(500))
        var budgets: [[String: Any]] = []
        for b in MacSettingsStorage.budgets(model) {
            let before = b.kept(), heldBefore = b.held()
            let other = b.choices.first { $0 > before } ?? b.choices.first { $0 != before } ?? before
            b.set(other)
            try? await Task.sleep(for: .milliseconds(200))
            let keptAfter = b.kept(), heldAfter = b.held()
            let key = "settings." + (b.id == "fullRenders" ? "fullRenderCacheLimit" : b.id + "Limit")
            let savedAfter = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value
            b.set(before)
            try? await Task.sleep(for: .milliseconds(200))
            let restored = b.kept(), savedRestored = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value
            budgets.append(["budget": b.id, "before": before, "held_before": heldBefore, "set_to": other, "settings_after": keptAfter,
                            "report_after": heldAfter, "defaults_after": savedAfter ?? -1, "restored": restored,
                            "defaults_restored": savedRestored ?? -1])
            r.check(other != before, "C: \(b.id) has another choice to move to")
            r.check(keptAfter == other, "C: \(b.id)'s control changes AppSettings (\(keptAfter >> 30) GB, asked \(other >> 30))")
            r.check(heldAfter == other, "C: \(b.id)'s control changes what the page shows held (\(heldAfter >> 30) GB)")
            r.check(savedAfter == other, "C: \(b.id)'s new budget is kept in the defaults")
            r.check(restored == before && savedRestored == before, "C: \(b.id) is put back (\(restored >> 30) GB, was \(before >> 30))")
        }
        let copies = model.originals.copies.limit
        r.check(copies == settings.workingCopiesLimit, "C: the working copies' book holds the kept budget (\(copies >> 30) GB)")
        r.step("C: the budgets", ms(since: t0), ["budgets": budgets])

        // ---- D. Sources. ----
        t0 = ContinuousClock.now
        let store = model.macLibrary
        await store.start()
        let sourcesBefore = store.sources.map(\.id)
        let selectedBefore = store.selectedSourceID
        let scratch = out.appending(path: "work/Settings Check Folder")
        try? fm.removeItem(at: scratch)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let smoke = ProcessInfo.processInfo.environment["SPK_TEST_IMAGES"].map { URL(fileURLWithPath: $0).appending(path: "_smoke_1mp.tif") }
        if let smoke, fm.fileExists(atPath: smoke.path) {
            try? fm.copyItem(at: smoke, to: scratch.appending(path: "smoke.tif"))
        } else {
            let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).pngData { c in
                UIColor.orange.setFill()
                c.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            }
            try? png.write(to: scratch.appending(path: "swatch.png"))
        }
        var added: MacSource?
        do { added = try await store.open(scratch) } catch { r.check(false, "D: a scratch folder opens as a source: \(error.localizedDescription)") }
        forget()
        select?(.sources)
        try? await Task.sleep(for: .milliseconds(900))
        let listed = store.sources.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "name": $0.name, "drawn": sources.contains($0.id)] as [String: Any] }
        // No app library source on the Mac since the library became catalogs (2026-10-24): the scratch folder at least.
        r.check(added.map { a in store.sources.contains { $0.id == a.id } } == true, "D: the store lists the scratch folder (\(store.sources.count) sources)")
        r.check(store.sources.allSatisfy { sources.contains($0.id) }, "D: every source of the Mac library is drawn on Sources")
        r.check(added.map { sources.contains($0.id) } == true, "D: the scratch folder's source is drawn")
        snapshot("sources-with-folder", out: out)

        // ---- F. The selected library's previews (2026-11-05, `LibraryPreviews`). ----
        t0 = ContinuousClock.now
        var previewFacts: [String: Any] = [:]
        let folderSource = added.flatMap { a in store.sources.first { $0.id == a.id } }
        let previewHome = folderSource?.previewHome
        r.check(previewHome != nil, "F: the scratch folder's source has a library to keep previews in (\(folderSource?.libraryPath ?? "none"))")
        if let folderSource, let home = previewHome {
            await store.select(source: folderSource.id)
            await store.loadAll()
            previewFacts["library"] = home.root.path
            previewFacts["folder"] = home.folder.path
            let row = store.images.first
            var made: [MacImage.ID: LibraryFrame.ID] = [:]
            if let row { made = (try? await store.frames(for: [row.id]).frames) ?? [:] }
            if let row, let frame = made[row.id] {
                func developed() -> URL? { model.library.frame(frame)?.developed?.picture.fileURL }
                func settled() -> Bool { developed() != nil && model.library.frame(frame)?.develop.isBusy == false }
                model.develop(frame)
                let kept = await until(120) { settled() }
                let url = developed()
                previewFacts["develop"] = url?.path ?? "none"
                r.check(kept, "F: a picture of the folder's library is developed and kept")
                r.check(url?.deletingLastPathComponent().standardizedFileURL == home.folder.standardizedFileURL,
                        "F: its develop is kept in the library's previews (\(url?.path ?? "none"))")
                // The page: the group for the selected library, its controls.
                forget()
                select?(.general)
                try? await Task.sleep(for: .milliseconds(500))
                select?(.storage)
                try? await Task.sleep(for: .milliseconds(5600))      // the page measures every 5 s
                r.check(["Library previews", "Library previews folder", "Delete Previews"].allSatisfy(seen.contains),
                        "F: Storage shows the selected library's previews, where they are and Delete Previews (\(seen.sorted()))")
                // The review's (c): the app's own libraries' previews are a part of On this Mac, and every library is listed.
                r.check(["Own library previews", "Every library's previews"].allSatisfy(seen.contains),
                        "F: Storage counts the previews of the app's own libraries and lists every library's")
                let own = LibraryPreviews.measureOwn(store: LibraryHost.defaultStore)
                previewFacts["own_libraries"] = ["files": own.files, "bytes": own.bytes]
                r.check(own.files == 1 && own.bytes > 0, "F: a folder's develop is counted among the app's own libraries' previews (\(own.files), \(own.bytes) bytes)")
                let usage = await MacPreviewsUsage.measure(home)
                previewFacts["measured"] = ["files": usage.files, "bytes": usage.bytes, "there": usage.isThere, "folder": usage.hasFolder]
                r.check(usage.isThere && usage.hasFolder && usage.files == 1 && usage.bytes > 0,
                        "F: the library's previews are measured: one develop (\(usage.files), \(usage.bytes) bytes)")
                snapshot("storage-library-previews", out: out)
                // Delete Previews, as its button does it.
                let went = await MacSettingsStorage.deletePreviews(model)
                previewFacts["deleted"] = ["files": went?.files ?? -1, "bytes": went?.bytes ?? -1]
                r.check(went?.files == 1, "F: Delete Previews takes the library's one develop (\(went?.files ?? -1))")
                r.check(url.map { !fm.fileExists(atPath: $0.path) } ?? false, "F: its file is gone")
                // What was known of the develop stays (the Light Table's rule, a film edge's canvas shape); only
                // its picture is missing, and no edit's stamp is its stamp, so it is developed again when asked.
                let after = model.library.frame(frame)
                previewFacts["after_delete"] = ["stamp": after?.developed?.stamp ?? "none", "size": after?.developed.map { "\($0.size.width)x\($0.size.height)" } ?? "none"]
                r.check(after?.developed?.isMissing == true && after?.shownDevelop == nil,
                        "F: the frame's develop is marked missing, so nothing draws its file (\(after?.developed?.stamp ?? "none"))")
                r.check((after?.developed?.size.width ?? 0) > 0 && after.map(MacLightTableCarry.takes) == true,
                        "F: and what was known of it stays: its size, and the Light Table still takes the frame")
                if let after, let want = model.darkroom.stamp(after, edit: after.edit, longEdge: after.previewSize.longEdge) {
                    r.check(after.developed?.stamp != want, "F: and no edit's stamp is a missing develop's: it is developed again when asked")
                }
                r.check(fm.fileExists(atPath: home.root.appending(path: PreviewHome.catalogDatabase).path), "F: the library itself is untouched")
                // The migration: a develop kept in the app's Previews (2.1.3's place) moves in when the frame is carried again.
                LibraryPreviews.forget([frame])
                model.develop(frame)
                _ = await until(120) { settled() }
                let legacy = developed()
                let inApp = legacy.map { $0.standardizedFileURL.path.hasPrefix(ImportService.previews.standardizedFileURL.path + "/") } ?? false
                r.check(inApp, "F: a frame carried from no library keeps its develop in the app's Previews (\(legacy?.path ?? "none"))")
                _ = try? await store.frames(for: [row.id])
                let movedIn = await until(20) { developed()?.deletingLastPathComponent().standardizedFileURL == home.folder.standardizedFileURL }
                previewFacts["migrated"] = ["from": legacy?.path ?? "none", "to": developed()?.path ?? "none"]
                r.check(movedIn, "F: carried from the library again, its develop moves into the library's previews (\(developed()?.path ?? "none"))")
                r.check(movedIn && legacy.map { !fm.fileExists(atPath: $0.path) } == true && developed().map { fm.fileExists(atPath: $0.path) } == true,
                        "F: under its own name, the old file gone and the new one there")
                r.check(developed()?.lastPathComponent == legacy?.lastPathComponent, "F: the same file name: its stamp is what it was made from")
                await MacSettingsStorage.deletePreviews(model)
            } else {
                r.check(false, "F: the scratch folder's picture is made a frame (\(store.images.count) rows)")
            }
        }
        r.step("F: the library's previews", ms(since: t0), previewFacts)

        // ---- G. A SpektraLab catalog and session of their own (2026-11-05). ----
        // Each made in the scratch folder, the picture copied in, carried, developed by hand: its develop is in
        // the catalog's package / the session's hidden folder. The session is scanned after (`session.scan`,
        // and the store's own sync): the preview is not added as a picture; the control, the same file in a
        // visible folder of the session, is — or the check could not fire.
        t0 = ContinuousClock.now
        var libraryFacts: [[String: Any]] = []
        let picture = (try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil))?.first
        let libraries = out.appending(path: "work/Libraries")
        try? fm.removeItem(at: libraries)
        try? fm.createDirectory(at: libraries, withIntermediateDirectories: true)
        for kind in [MacSource.Kind.catalog, .session] {
            var facts: [String: Any] = ["kind": kind.rawValue]
            defer { libraryFacts.append(facts) }
            guard let picture else { r.check(false, "G: the scratch picture is there to import"); break }
            do {
                let made = kind == .catalog ? try await store.newCatalog(named: "Previews Check", in: libraries)
                                            : try await store.newSession(named: "Previews Session", in: libraries)
                guard let home = made.previewHome else { r.check(false, "G: a \(kind.rawValue) has a library to keep previews in"); continue }
                facts["folder"] = home.folder.path
                _ = try await store.importFiles([picture], into: made.id, mode: .copy)
                await store.select(source: made.id)
                await store.loadAll()
                guard let row = store.images.first, let frame = try await store.frames(for: [row.id]).frames[row.id] else {
                    r.check(false, "G: the \(kind.rawValue)'s picture is made a frame (\(store.images.count) rows)")
                    continue
                }
                model.develop(frame)
                _ = await until(120) { model.library.frame(frame)?.developed != nil && model.library.frame(frame)?.develop.isBusy == false }
                let url = model.library.frame(frame)?.developed?.picture.fileURL
                facts["develop"] = url?.path ?? "none"
                r.check(url?.deletingLastPathComponent().standardizedFileURL == home.folder.standardizedFileURL,
                        "G: a \(kind.rawValue)'s picture keeps its develop in the \(kind.rawValue) (\(url?.path ?? "none"))")
                if kind == .catalog {
                    r.check(url?.path.contains(".spkcatalog/Cache/Previews/") == true, "G: inside the catalog's package, Cache/Previews")
                } else if let url {
                    r.check(url.path.contains("/.SpektraLab/Cache/Previews/"), "G: in the session's hidden .SpektraLab/Cache/Previews")
                    let h = try await store.handle(made)
                    let scan = try await store.client.sessionScan(h)
                    await store.synchronize(made.id)
                    await store.loadAll()
                    facts["scan_hidden"] = ["seen": scan.seen, "added": scan.added, "listed": store.total]
                    r.check(scan.added == 0 && store.total == 1,
                            "G: the session's scan and sync do not take the preview for a picture (added \(scan.added), \(store.total) listed)")
                    // The control: the same file in a visible folder of the session is taken.
                    let visible = home.root.appending(path: "Visible Control")
                    try? fm.createDirectory(at: visible, withIntermediateDirectories: true)
                    try? fm.copyItem(at: url, to: visible.appending(path: url.lastPathComponent))
                    let control = try await store.client.sessionScan(h)
                    facts["scan_control"] = ["seen": control.seen, "added": control.added]
                    r.check(control.added == 1, "G: control: the same file in a visible folder is added by the scan (\(control.added))")
                }
                let went = await MacSettingsStorage.deletePreviews(model)
                r.check(went?.files == 1 && url.map { !fm.fileExists(atPath: $0.path) } == true, "G: Delete Previews empties the \(kind.rawValue)'s previews")
                store.remove(source: made.id)
            } catch {
                r.check(false, "G: a \(kind.rawValue) is made and its picture imported: \(error.localizedDescription)")
            }
        }
        r.step("G: a SpektraLab catalog and session", ms(since: t0), ["libraries": libraryFacts])

        // ---- H. A catalog moved in Finder, then its Cache deleted (review, 2026-11-05). ----
        // The scratch picture is referenced (not copied) by a catalog of its own, so the frame is the same frame
        // after the move (frames are joined to rows by the file's path). Its develop is kept in the catalog; the
        // catalog is removed from Sources, moved, and opened again from where it is now: carried, the frame's
        // develop is found under its own name in the moved package and the frame is pointed there. Then the
        // package's Cache is deleted by hand: carried again, the develop is marked missing (its size kept) and a
        // develop asked lands in the moved catalog. Nothing is made where the catalog was.
        t0 = ContinuousClock.now
        var moveFacts: [String: Any] = [:]
        if let picture {
            do {
                let made = try await store.newCatalog(named: "Moved Check", in: libraries)
                guard let home = made.previewHome else { throw MacLibraryError.notSupported("no previews home") }
                _ = try await store.importFiles([picture], into: made.id, mode: .reference)
                await store.select(source: made.id)
                await store.loadAll()
                guard let row = store.images.first, let frame = try await store.frames(for: [row.id]).frames[row.id] else {
                    throw MacLibraryError.notSupported("the moved catalog's picture is made no frame (\(store.images.count) rows)")
                }
                func developed() -> DevelopedPicture? { model.library.frame(frame)?.developed }
                func settled() -> Bool { model.library.frame(frame)?.develop.isBusy == false }
                model.develop(frame)
                _ = await until(120) { developed()?.picture.fileURL?.deletingLastPathComponent().standardizedFileURL == home.folder.standardizedFileURL && settled() }
                let before = developed()
                moveFacts["develop"] = before?.picture.fileURL?.path ?? "none"
                r.check(before?.picture.fileURL?.deletingLastPathComponent().standardizedFileURL == home.folder.standardizedFileURL,
                        "H: the referenced picture's develop is kept in its catalog (\(before?.picture.fileURL?.path ?? "none"))")
                // Moved in Finder: out of Sources, the package moved, opened again from its new place.
                store.remove(source: made.id)
                try? await Task.sleep(for: .milliseconds(300))
                let elsewhere = libraries.appending(path: "Elsewhere")
                try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                let movedRoot = elsewhere.appending(path: home.root.lastPathComponent)
                try fm.moveItem(at: home.root, to: movedRoot)
                let moved = try await store.open(movedRoot)
                guard let movedHome = moved.previewHome else { throw MacLibraryError.notSupported("the moved catalog has no previews home") }
                await store.select(source: moved.id)
                await store.loadAll()
                let movedRow = store.images.first
                var again: LibraryFrame.ID?
                if let movedRow { again = try await store.frames(for: [movedRow.id]).frames[movedRow.id] }
                r.check(again == frame, "H: the moved catalog's picture is the same frame (\(again?.uuidString ?? "none"))")
                let rerooted = await until(20) {
                    developed()?.picture.fileURL?.deletingLastPathComponent().standardizedFileURL == movedHome.folder.standardizedFileURL
                }
                moveFacts["rerooted"] = developed()?.picture.fileURL?.path ?? "none"
                r.check(rerooted && developed()?.isMissing == false && developed()?.stamp == before?.stamp,
                        "H: carried from the moved catalog, the frame's develop is the one that moved with it, its stamp as it was (\(developed()?.picture.fileURL?.path ?? "none"))")
                r.check(!fm.fileExists(atPath: home.root.path), "H: nothing is made where the catalog was")
                // Its Cache deleted by hand: missing, then made again in the moved catalog.
                try? fm.removeItem(at: movedRoot.appending(path: "Cache"))
                _ = try? await store.frames(for: movedRow.map { [$0.id] } ?? [])
                let missing = await until(20) { developed()?.isMissing == true }
                moveFacts["after_cache_deleted"] = developed()?.stamp ?? "none"
                r.check(missing && (developed()?.size.width ?? 0) > 0,
                        "H: with the catalog's Cache deleted, the carried frame's develop reads missing, its size kept (\(developed()?.stamp ?? "none"))")
                model.develop(frame)
                let remade = await until(120) {
                    developed()?.isMissing == false && settled()
                        && developed()?.picture.fileURL.map { fm.fileExists(atPath: $0.path) } == true
                }
                moveFacts["remade"] = developed()?.picture.fileURL?.path ?? "none"
                r.check(remade && developed()?.picture.fileURL?.deletingLastPathComponent().standardizedFileURL == movedHome.folder.standardizedFileURL,
                        "H: developed again, into the moved catalog's previews (\(developed()?.picture.fileURL?.path ?? "none"))")
                r.check(!fm.fileExists(atPath: home.root.path), "H: and still nothing where the catalog was")
                await MacSettingsStorage.deletePreviews(model)
                store.remove(source: moved.id)
            } catch {
                r.check(false, "H: a catalog is made, moved and opened again: \(error.localizedDescription)")
            }
        } else {
            r.check(false, "H: the scratch picture is there to reference")
        }
        if let added { await store.select(source: added.id) }
        r.step("H: a catalog moved, then its Cache deleted", ms(since: t0), moveFacts)

        // ---- E. The pictures, in four languages at two sizes (the scratch source still listed). ----
        let sizes: [(String, CGSize)] = [("min", CGSize(width: 847, height: 539)), ("large", CGSize(width: 1440, height: 900))]
        var drawn: [String] = []
        var windows: [String: [CGFloat]] = [:]
        for language in [AppLanguage.english, .simplified, .traditional, .japanese] {
            Language.shared.choose(language)
            for (name, size) in sizes {
                let got = await resize(to: size)
                windows["\(language.rawValue)-\(name)"] = [got.width, got.height]
                for s in MacSettingsSection.allCases {
                    select?(s)
                    try? await Task.sleep(for: .milliseconds(650))
                    let file = "\(language.rawValue)-\(name)-\(s.rawValue)"
                    snapshot(file, out: out)
                    drawn.append(file + ".png")
                }
            }
        }
        r.check(Set(drawn).count == drawn.count, "E: every language and window size has its own capture")
        Language.shared.choose(startLanguage)
        restoreWindow()
        r.step("E: the pictures", 0, ["files": drawn, "window_mac_points": windows])

        // The sources put back.
        if let added { store.remove(source: added.id) }
        await store.select(source: selectedBefore ?? CatalogSourcesStore.appLibraryID)
        r.step("D: sources", ms(since: t0), ["listed": listed, "before": sourcesBefore.map(\.uuidString),
                                             "after": store.sources.map(\.id.uuidString)])
        r.check(store.sources.map(\.id) == sourcesBefore, "D: the sources are as they were after (\(store.sources.count))")
        await close(model)

        let endLimits = [settings.workingCopiesLimit, settings.previewCopiesLimit, settings.fullRenderCacheLimit]
        r.check(endLimits == startLimits, "the budgets at the end are the budgets at the start")
        r.check(Language.shared.current == startLanguage, "the language at the end is the language at the start")
        return ["steps": r.steps, "failures": r.failures, "passed": r.failures.isEmpty,
                "written": ISO8601DateFormatter().string(from: Date())]
    }

    // MARK: the window and the pictures

    /// The window to `size` Mac points, held there; what it came to, in Mac points.
    private static func resize(to size: CGSize) async -> CGSize {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return .zero }
        let points = CGSize(width: size.width / MacMetric.scale, height: size.height / MacMetric.scale)
        scene.sizeRestrictions?.minimumSize = points
        scene.sizeRestrictions?.maximumSize = points
        _ = await until(5) {
            let b = scene.windows.first?.bounds.size ?? .zero
            return abs(b.width - points.width) < 2 && abs(b.height - points.height) < 2
        }
        try? await Task.sleep(for: .milliseconds(600))
        let b = scene.windows.first?.bounds.size ?? .zero
        return CGSize(width: (b.width * MacMetric.scale).rounded(), height: (b.height * MacMetric.scale).rounded())
    }

    private static func restoreWindow() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.sizeRestrictions?.minimumSize = MacWindow.minimumSize
        scene.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    /// The page in front, drawn as the window holds it, to `<dir>/<name>.png`.
    static func snapshot(_ name: String, out: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return }
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let view = top?.view, view.bounds.width > 0 else { return }
        let picture = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? picture.pngData()?.write(to: out.appending(path: "\(name).png"))
    }
}
#endif
