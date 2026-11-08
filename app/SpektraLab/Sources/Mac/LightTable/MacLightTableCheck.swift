//  MacLightTableCheck.swift — a debug build's proof of the Mac's Light Table in the running app (2026-10-24).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --lighttable-check <dir> [--lighttable-check-exit]
//          [--lighttable-check-pictures <folder> …]
//
//  Writes `<dir>/report.json`, every step timed, and draws the page to `<dir>/<language>-<size>-<what>.png`.
//  The pictures are copied into `<dir>/work` and linked as a Finder folder; the scratch home holds the library.
//
//  1. **Frames**: nine RAWs made frames (no develop): two 135 strips, two 6 × 9 strips, a 6 × 9 filed, a 6 × 17
//     strip, a 645 strip, and two left plain — which `MacLightTableCarry.takes` refuses.
//  2. **The Add page**: the sheet the Mac had (`LightTableAddSheet`) and the page that replaces it, each opened
//     and closed three times: from the state that shows it to its `onAppear`, from the state that hides it to its
//     `onDisappear` (and, for the page, to the next frame the display shows), and the main thread's longest
//     stall meanwhile. The page lists exactly the frames the filter takes; five laid down; the five then *On the
//     table* and not chosen by ⌘A; the last two laid down; a page with room for one keeps one of a ⌘A.
//  3. **The bar**: each control through the page's own actions and keys — Drag/Click (and the Click tool's
//     pick-up, follow, put-down and Esc, its free turn), Loupe, −/Fit/+, 1:1, the table's size and its way up,
//     ···, Share.
//  4. **1:1**: the display read (`MacDisplay`), and the table at Actual Size on A6 landscape drawn and its own
//     millimetre scale measured in the picture's pixels: its ticks a millimetre apart at the zoom set, a
//     centimetre of table against the display's pixels a centimetre, and back on the glass.
//  5. **The rail**: its films in the order laid, each tile turned as its film lies (after a Rotate Right), put
//     away and brought back (the table taking the room), and, with the queue idle, built afresh with no job.
//  6. **The menu**: a right click's menu on a film (exactly Rotate Right, Rotate Left, Take Off), each item sent
//     up the responder chain as AppKit sends it, and R / ⇧R / ⌫ / the arrows through the page's keys; none off a
//     film.
//  7. **The pictures**, in English and Simplified Chinese, at 847 × 539 and 1,440 × 900 Mac points.
//
//  What it cannot do is move a real pointer: the gestures (a drag, a click on the table, a corner's turn, a
//  trackpad's turn) are driven through the controller calls they make, and the context menu is built and its
//  items sent, not opened by a right click. Not in a release build.

#if DEBUG
import Foundation
import ImageIO
import SwiftUI
import UIKit

@MainActor
enum MacLightTableCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--lighttable-check"), i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--lighttable-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        if pictures.isEmpty {
            guard let root = ProcessInfo.processInfo.environment["SPK_TEST_IMAGES"], !root.isEmpty else {
                print("lighttable-check: supply --lighttable-check-pictures or SPK_TEST_IMAGES; no fixtures were run")
                if arguments.contains("--lighttable-check-exit") { exit(2) }
                return
            }
            pictures = [URL(fileURLWithPath: root + "/Nikon Z7ii"), URL(fileURLWithPath: root + "/A7m3")]
        }
        let exits = arguments.contains("--lighttable-check-exit")
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let report = await run(model, out: out, pictures: pictures)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("lighttable-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    // MARK: - the report

    @MainActor private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var checks = 0
        func step(_ name: String, _ ms: Double, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            s["ms"] = MacLightTableCheck.round1(ms)
            steps.append(s)
            print("lighttable-check: \(name) \(Int(ms)) ms \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what); print("lighttable-check: FAIL \(what)") } else { print("lighttable-check: ok \(what)") }
        }
        var json: [String: Any] { ["steps": steps, "failures": failures, "checks": checks, "passed": failures.isEmpty] }
    }

    nonisolated static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    nonisolated static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    private static func ms(since t0: ContinuousClock.Instant) -> Double { ms(t0, .now) }
    nonisolated static func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
        let d = b - a
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func until(_ seconds: Double, every ms: Int = 20, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(ms))
        }
        return done()
    }

    /// The next frame the display shows after now.
    private static func nextFrame() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            FrameTick(c).start()
        }
    }

    @MainActor private final class FrameTick: NSObject {
        private var c: CheckedContinuation<Void, Never>?
        private var link: CADisplayLink?
        private var me: FrameTick?
        init(_ c: CheckedContinuation<Void, Never>) { self.c = c }
        func start() {
            me = self
            let l = CADisplayLink(target: self, selector: #selector(fired))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc func fired() {
            link?.invalidate()
            link = nil
            c?.resume()
            c = nil
            me = nil
        }
    }

    /// The main thread's longest stall: a 2 ms beat on the main actor, its widest gap.
    @MainActor private final class Stalls {
        private(set) var longest = 0.0
        private var task: Task<Void, Never>?
        func start() {
            longest = 0
            task = Task { @MainActor [weak self] in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2))
                    let now = ContinuousClock.now
                    let gap = MacLightTableCheck.ms(last, now)
                    if let self, gap > self.longest { self.longest = gap }
                    last = now
                }
            }
        }
        func stop() -> Double { task?.cancel(); task = nil; return MacLightTableCheck.round1(longest) }
    }

    /// The scheduler's jobs as it shows them, sampled every 10 ms: every job seen, by id and kind.
    @MainActor private final class JobWatch {
        private(set) var jobs: [UUID: String] = [:]
        private var task: Task<Void, Never>?
        private let before: Set<UUID>
        init(_ scheduler: RenderQueue) {
            before = Set(scheduler.snapshots.map(\.id)).union(scheduler.records.map(\.jobID))
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.sample(scheduler)
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        func sample(_ scheduler: RenderQueue) {
            for s in scheduler.snapshots where !before.contains(s.id) { jobs[s.id] = s.job.kind.rawValue }
            for r in scheduler.records where !before.contains(r.jobID) { jobs[r.jobID] = r.kind }
        }
        func stop(_ scheduler: RenderQueue) -> [String: Int] {
            sample(scheduler)
            task?.cancel()
            return Dictionary(grouping: jobs.values, by: { $0 }).mapValues(\.count)
        }
    }

    // MARK: - the window and the pictures

    private static var window: UIWindow? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    }

    private static func tableView(in v: UIView?) -> LightTableMetalView? {
        guard let v else { return nil }
        if let t = v as? LightTableMetalView, t.window != nil { return t }
        for s in v.subviews { if let t = tableView(in: s) { return t } }
        return nil
    }

    /// The window to `size` Mac points, held there; what it came to, Mac points.
    private static func resize(to size: CGSize) async -> CGSize {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return .zero }
        let points = CGSize(width: size.width / MacMetric.scale, height: size.height / MacMetric.scale)
        scene.sizeRestrictions?.minimumSize = points
        scene.sizeRestrictions?.maximumSize = points
        _ = await until(5) {
            let b = scene.windows.first?.bounds.size ?? .zero
            return abs(b.width - points.width) < 2 && abs(b.height - points.height) < 2
        }
        try? await Task.sleep(for: .milliseconds(700))
        let b = scene.windows.first?.bounds.size ?? .zero
        return CGSize(width: (b.width * MacMetric.scale).rounded(), height: (b.height * MacMetric.scale).rounded())
    }

    private static func restoreWindow() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.sizeRestrictions?.minimumSize = MacWindow.minimumSize
        scene.sizeRestrictions?.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    /// The window as it holds its page (and a sheet in front of it), to `<dir>/<name>.png`. Where
    /// `drawHierarchy` leaves the table's Metal layer out, the same picture made offscreen is laid in under
    /// the window's own (`metal`: "drawn" or "laid in").
    @discardableResult
    private static func snapshot(_ name: String, out: URL) -> [String: Any] {
        guard let window, let root = window.rootViewController?.view, root.bounds.width > 0 else { return ["file": name, "drawn": false] }
        // The window as the display shows it, by the window server (title bar and all): the truth of what a person
        // sees. `drawHierarchy` only where that cannot be had.
        if let facts = MacDisplay.windowFacts(for: window) {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let file = out.appending(path: "\(name).png")
            if spawn("/usr/sbin/screencapture", ["-x", "-o", "-l\(facts.number)", file.path]) == 0,
               FileManager.default.fileExists(atPath: file.path) {
                return ["file": name + ".png", "picture": "the window server's"]
            }
        }
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        let views = [root] + (top !== window.rootViewController ? [top!.view!] : [])
        let picture = UIGraphicsImageRenderer(bounds: root.bounds).image { _ in
            for v in views { _ = v.drawHierarchy(in: v.convert(v.bounds, to: root), afterScreenUpdates: true) }
        }
        var metal = "none on the page"
        var image = picture
        if let t = tableView(in: root), t.bounds.width > 0 {
            let frame = t.convert(t.bounds, to: root)
            if isBlack(picture, in: frame) {
                // drawHierarchy draws a Metal layer black: the table's own picture offscreen, under the window's.
                let c = t.controller
                let still = c.still(size: c.viewport.size, scale: Double(window.screen.scale), inset: c.viewport.inset)
                c.still = false
                t.setNeedsLayout()
                if let still {
                    image = UIGraphicsImageRenderer(bounds: root.bounds).image { ctx in
                        picture.draw(at: .zero)
                        ctx.cgContext.saveGState()
                        ctx.cgContext.clip(to: frame)
                        // only the table's own pixels: what is drawn over it stays (`lighter` keeps the brighter)
                        UIImage(cgImage: still, scale: window.screen.scale, orientation: .up).draw(in: frame, blendMode: .lighten, alpha: 1)
                        ctx.cgContext.restoreGState()
                    }
                    metal = "laid in"
                }
            } else {
                metal = "drawn"
            }
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: out.appending(path: "\(name).png"))
        return ["file": name + ".png", "metal": metal]
    }

    /// The middle of `frame` is black in `image` (a Metal layer `drawHierarchy` could not see).
    private static func isBlack(_ image: UIImage, in frame: CGRect) -> Bool {
        guard let cg = image.cgImage else { return false }
        let s = image.scale
        let probe = CGRect(x: (frame.midX - 20) * s, y: (frame.midY - 20) * s, width: 40 * s, height: 40 * s).integral
        guard let crop = cg.cropping(to: probe),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let d = ctx.data?.bindMemory(to: UInt8.self, capacity: 4) else { return false }
        return Int(d[0]) + Int(d[1]) + Int(d[2]) < 12
    }

    // MARK: - the run

    static func run(_ model: AppServices, out: URL, pictures: [URL]) async -> [String: Any] {
        let r = Report()
        let fm = FileManager.default
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else {
            r.check(false, "CFFIXED_USER_HOME is set (the debug build shares the owner's bundle id): refused to run")
            return r.json
        }
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "png" {
            try? fm.removeItem(at: old)
        }
        let store = model.macLibrary
        let scheduler = model.scheduler
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let startLanguage = Language.shared.current
        Language.shared.choose(.english)
        r.step("start", 0, ["home": NSHomeDirectory(), "frames": model.library.frames.count, "engine": model.darkroom.makesPictures])
        r.check(model.library.frames.isEmpty, "a fresh library in the scratch home (\(model.library.frames.count) frames)")

        // ---- 1. Frames: nine RAWs, seven with a film size, two plain. ----
        var t0 = ContinuousClock.now
        let raws = pictures.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["nef", "arw"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard raws.count >= 9 else {
            r.check(false, "nine RAWs to lay on the table (found \(raws.count))")
            return r.json
        }
        let card = work.appending(path: "Card")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for u in raws.prefix(9) { try? fm.copyItem(at: u, to: card.appending(path: u.lastPathComponent)) }
        await store.start()
        do { _ = try await store.open(card) } catch { r.check(false, "1: the scratch folder links: \(error.localizedDescription)") }
        await store.loadAll()
        let rows = raws.prefix(9).compactMap { u in store.images.first { $0.fileName == u.lastPathComponent } }
        r.check(rows.count == 9, "1: the folder lists its nine pictures (\(rows.count))")
        let made = (try? await store.frames(for: rows.map(\.id)).frames) ?? [:]
        let ids = rows.compactMap { made[$0.id] }
        r.check(ids.count == 9, "1: nine frames made (\(ids.count))")
        guard ids.count == 9 else { return r.json }
        let plan: [(FilmEdgeFormat, FilmEdgeView)?] = [(.f135, .strip), (.f135, .strip), (.f6x9, .strip), (.f6x9, .strip), (.f6x9, .filed),
                                                       (.f6x17, .strip), (.f645, .strip), nil, nil]
        for (id, p) in zip(ids, plan) {
            guard let p else { continue }
            model.library.update(id) { $0.edit.filmEdge.active = true; $0.edit.filmEdge.format = p.0; $0.edit.filmEdge.mode = p.1 }
        }
        let takes = ids.filter { model.library.frame($0).map(MacLightTableCarry.takes) ?? false }
        let name = { (id: UUID) in model.library.frame(id)?.fileName ?? id.uuidString }
        r.step("1: frames", ms(since: t0), ["frames": ids.map(name), "taken": takes.map(name),
                                            "formats": zip(ids, plan).map { name($0.0) + ": " + ($0.1.map { "\($0.0.rawValue) \($0.1.rawValue)" } ?? "plain") }])
        r.check(takes.count == 7, "1: the filter takes the seven with a film size, not the two plain (\(takes.count))")

        // ---- Open the table, empty. ----
        model.router.toLibrary()
        model.router.open(.lightTable)
        let opened = await until(20) { LightTableCheckHook.table != nil && MacLightTableCheckHook.page != nil && tableView(in: window?.rootViewController?.view) != nil }
        r.check(opened, "the Light Table page opens")
        guard opened, let table = LightTableCheckHook.table, let page = MacLightTableCheckHook.page else { return r.json }
        try? await Task.sleep(for: .milliseconds(800))
        r.check(table.model.order.isEmpty, "the table is empty at first (\(table.model.order.count))")
        snapshot("en-default-empty", out: out)
        if let v = tableView(in: window?.rootViewController?.view), let window {
            let layer = v.layer as? CAMetalLayer
            r.step("the table's view", 0, [
                "bounds": [Double(v.bounds.width), Double(v.bounds.height)], "content_scale": Double(v.contentScaleFactor),
                "layer_contents_scale": Double(v.layer.contentsScale), "drawable": [Double(v.drawableSize.width), Double(v.drawableSize.height)],
                "metal_layer_drawable": [Double(layer?.drawableSize.width ?? 0), Double(layer?.drawableSize.height ?? 0)],
                "window_screen_scale": Double(window.screen.scale), "main_screen_scale": Double(UIScreen.main.scale),
                "trait_display_scale": Double(v.traitCollection.displayScale), "window_bounds": [Double(window.bounds.width), Double(window.bounds.height)],
                "display_problem": { _ = MacDisplay.reading(for: window); return MacDisplay.problem ?? "none" }(),
                "appkit_windows": MacDisplay.nsWindows(),
            ])
        }
        if CommandLine.arguments.contains("--lighttable-check-diag") { return r.json }

        // ---- 2. The Add page, against the sheet it replaces. ----
        t0 = ContinuousClock.now
        var legacy: [[String: Double]] = [], pages: [[String: Double]] = []
        let stalls = Stalls()
        for _ in 0..<3 {
            MacLightTableCheckHook.legacyShownAt = nil; MacLightTableCheckHook.legacyGoneAt = nil
            var a = ContinuousClock.now
            stalls.start()
            page.setLegacySheet(true)
            _ = await until(10, every: 1) { MacLightTableCheckHook.legacyShownAt != nil }
            let openStall = stalls.stop()
            let open = MacLightTableCheckHook.legacyShownAt.map { ms(a, $0) } ?? -1
            try? await Task.sleep(for: .milliseconds(1200))
            // Closed as its × closes it (SwiftUI's `dismiss`, UIKit's animated dismissal), the state put back after.
            a = ContinuousClock.now
            var dismissed: ContinuousClock.Instant?
            stalls.start()
            window?.rootViewController?.presentedViewController?.dismiss(animated: true) { dismissed = .now }
            _ = await until(10, every: 1) { MacLightTableCheckHook.legacyGoneAt != nil && dismissed != nil }
            let close = MacLightTableCheckHook.legacyGoneAt.map { ms(a, $0) } ?? -1
            let gone = dismissed.map { ms(a, $0) } ?? -1
            let closeStall = stalls.stop()
            page.setLegacySheet(false)
            legacy.append(["open_ms": round1(open), "close_ms": round1(close), "dismissal_done_ms": round1(gone),
                           "open_stall_ms": openStall, "close_stall_ms": closeStall])
            try? await Task.sleep(for: .milliseconds(800))
        }
        for i in 0..<3 {
            MacLightTableAddPage.shownAt = nil; MacLightTableAddPage.goneAt = nil
            var a = ContinuousClock.now
            stalls.start()
            page.setAdding(true)
            _ = await until(10, every: 1) { MacLightTableAddPage.shownAt != nil }
            await nextFrame()
            let openFrame = ms(since: a)
            let openStall = stalls.stop()
            let open = MacLightTableAddPage.shownAt.map { ms(a, $0) } ?? -1
            try? await Task.sleep(for: .milliseconds(600))
            if i == 0 { snapshot("en-default-add-page-empty-table", out: out) }
            a = ContinuousClock.now
            stalls.start()
            page.setAdding(false)
            _ = await until(10, every: 1) { MacLightTableAddPage.goneAt != nil }
            let close = MacLightTableAddPage.goneAt.map { ms(a, $0) } ?? -1
            await nextFrame()
            let closeFrame = ms(since: a)
            let closeStall = stalls.stop()
            pages.append(["open_ms": round1(open), "open_to_frame_ms": round1(openFrame), "close_ms": round1(close),
                          "close_to_frame_ms": round1(closeFrame), "open_stall_ms": openStall, "close_stall_ms": closeStall])
            try? await Task.sleep(for: .milliseconds(400))
        }
        func median(_ xs: [[String: Double]], _ k: String) -> Double { let v = xs.compactMap { $0[k] }.sorted(); return v.isEmpty ? -1 : v[v.count / 2] }
        r.step("2: the Add page against the old sheet", ms(since: t0), [
            "old_sheet": legacy, "page": pages,
            "old_sheet_close_median_ms": median(legacy, "close_ms"), "page_close_median_ms": median(pages, "close_ms"),
            "page_close_to_frame_median_ms": median(pages, "close_to_frame_ms"),
            "old_sheet_open_median_ms": median(legacy, "open_ms"), "page_open_median_ms": median(pages, "open_ms"),
        ])
        r.check(legacy.allSatisfy { ($0["close_ms"] ?? -1) >= 0 }, "2: the old sheet was shown and closed three times")
        r.check(pages.allSatisfy { ($0["close_ms"] ?? 99) >= 0 && ($0["close_ms"] ?? 99) < 50 },
                "2: the page goes in the pass that hides it (< 50 ms: \(pages.map { $0["close_ms"] ?? -1 }))")
        r.check(pages.allSatisfy { ($0["open_ms"] ?? 999) >= 0 && ($0["open_ms"] ?? 999) < 100 },
                "2: the page is drawn in the pass that shows it (< 100 ms: \(pages.map { $0["open_ms"] ?? -1 }))")
        r.check(median(pages, "close_ms") < median(legacy, "close_ms"), "2: the page closes sooner than the sheet did")

        // The page lists what the filter takes, and lays down what is chosen.
        t0 = ContinuousClock.now
        page.setAdding(true)
        _ = await until(5) { MacLightTableAddPage.shown != nil && MacLightTableAddPage.shownAt != nil }
        try? await Task.sleep(for: .milliseconds(400))
        let listed = MacLightTableAddPage.shownRows
        r.check(Set(listed) == Set(takes) && listed.count == takes.count, "2: the page lists exactly the seven the filter takes (\(listed.count): \(listed.map(name)))")
        let firstFive = Array(listed.prefix(5))
        MacLightTableAddPage.shown?.selection = Set(firstFive.map { MacImage.ID(source: CatalogSourcesStore.appLibraryID, image: $0.uuidString) })
        try? await Task.sleep(for: .milliseconds(300))
        snapshot("en-default-add-page-five-chosen", out: out)
        MacLightTableAddPage.pressLayDown?()
        _ = await until(5) { !page.adding() && table.model.order.count == 5 }
        try? await Task.sleep(for: .milliseconds(700))
        r.check(!page.adding() && Set(table.model.order) == Set(firstFive), "2: Lay Down 5 puts those five on the table and closes the page (\(table.model.order.count))")
        page.setAdding(true)
        _ = await until(5) { MacLightTableAddPage.shown != nil }
        try? await Task.sleep(for: .milliseconds(400))
        MacLightTableAddPage.shown?.selectAll(listed.compactMap { model.library.frame($0) }.map { CatalogSourcesStore.row($0, source: CatalogSourcesStore.appLibraryID) })
        try? await Task.sleep(for: .milliseconds(300))
        let pickedAll = MacLightTableAddPage.shown?.selection.compactMap { UUID(uuidString: $0.image) } ?? []
        snapshot("en-default-add-page-on-the-table", out: out)
        r.check(Set(pickedAll) == Set(listed).subtracting(firstFive), "2: ⌘A chooses the two not on the table, never the five on it (\(pickedAll.map(name)))")
        MacLightTableAddPage.pressLayDown?()
        _ = await until(5) { !page.adding() && table.model.order.count == 7 }
        try? await Task.sleep(for: .milliseconds(900))
        r.check(table.model.order.count == 7, "2: the last two laid down: seven on the table (\(table.model.order.count))")
        let room = await roomCheck(model, takes: takes)
        r.check(room.kept == 1 && room.trimmed, "2: with room for one film, ⌘A keeps one and says the table is full (\(room.kept), \(room.trimmed))")
        r.step("2: the Add page lays down", ms(since: t0), ["listed": listed.map(name), "laid_first": firstFive.map(name),
                                                            "select_all_then": pickedAll.map(name), "room_one": ["kept": room.kept, "said": room.trimmed]])

        // ---- 3. The bar. ----
        t0 = ContinuousClock.now
        table.tidyUp(table.model.order)
        try? await Task.sleep(for: .milliseconds(900))
        var bar: [String: Any] = [:]
        page.key(.click)
        r.check(page.tool() == .click, "3: C chooses the Click tool")
        let film = table.model.order[0]
        if let box = table.screenBox(film), let before = table.model.item(film)?.centre {
            let p = CGPoint(x: box.midX, y: box.midY)
            table.pickUp(film, at: p)
            r.check(table.held == film, "3: Click: a click on a film picks it up")
            table.follow(CGPoint(x: p.x + 30, y: p.y + 20))
            try? await Task.sleep(for: .milliseconds(100))
            table.putDown()
            let after = table.model.item(film)?.centre ?? before
            let dx = Double(after.x - before.x), dy = Double(after.y - before.y)
            let ex = 30 / table.viewport.s, ey = -20 / table.viewport.s
            r.check(table.held == nil && abs(dx - ex) < 0.6 && abs(dy - ey) < 0.6,
                    "3: Click: it follows the pointer and a click puts it down there (\(round3(dx)), \(round3(dy)) mm against \(round3(ex)), \(round3(ey)))")
            bar["click_moved_mm"] = [round3(dx), round3(dy)]
            if let box2 = table.screenBox(film) {
                let at = table.model.item(film)?.centre
                table.pickUp(film, at: CGPoint(x: box2.midX, y: box2.midY))
                table.follow(CGPoint(x: box2.midX + 60, y: box2.midY))
                page.key(.escape)
                r.check(table.held == nil && table.model.item(film)?.centre == at, "3: Click: Esc puts the film in hand back where it was")
            }
        }
        if let it = table.model.item(film) {
            table.beginTurn(film)
            table.turnFreely(film, to: LightTable.settle(it.rot + 32 * LightTable.deg))
            table.endTurn(film)
            let deg = (table.model.item(film)?.rot ?? 0) / LightTable.deg
            r.check(abs(deg - (it.rot / LightTable.deg + 32)) < 0.01, "3: Click: a free turn turns the film (\(round3(deg))°)")
            table.beginTurn(film)
            table.turnFreely(film, to: LightTable.settle(it.rot + 2 * LightTable.deg))
            table.endTurn(film)
            r.check(abs((table.model.item(film)?.rot ?? 1) - it.rot) < 1e-9, "3: Click: within 4° of square it settles square")
        }
        page.key(.drag)
        r.check(page.tool() == .drag, "3: D chooses the Drag tool")
        page.key(.loupe)
        try? await Task.sleep(for: .milliseconds(300))
        let loupeOn = table.loupeOn && page.loupe()
        snapshot("en-default-loupe", out: out)
        page.key(.loupe)
        r.check(loupeOn && !table.loupeOn, "3: L puts the loupe up and away")
        var zooms: [Double] = []
        for (k, want) in [(LightTablePane.MacKey.zoomIn, 1.5), (.zoomIn, 2.25), (.zoomOut, 1.5), (.fit, 1.0)] {
            page.key(k)
            _ = await until(3) { abs(table.viewport.zoom - want) < 0.005 }     // the zoom eases there over 260 ms
            try? await Task.sleep(for: .milliseconds(100))
            zooms.append(round3(table.viewport.zoom))
        }
        bar["zoom_steps"] = zooms
        r.check(abs(zooms[0] - 1.5) < 0.01 && abs(zooms[1] - 2.25) < 0.01 && abs(zooms[2] - 1.5) < 0.01 && abs(zooms[3] - 1) < 0.01,
                "3: + zooms ×1.5, − back, Fit to 1 (\(zooms))")
        page.key(.actualSize)
        try? await Task.sleep(for: .milliseconds(450))
        r.check(table.isActualSize && abs(table.viewport.s - (table.pointsPerMM ?? -1)) < 1e-6,
                "3: 1:1 sets the table at the display's points a millimetre (\(round3(table.viewport.s)) against \(round3(table.pointsPerMM ?? -1)))")
        page.key(.actualSize)
        try? await Task.sleep(for: .milliseconds(450))
        r.check(!table.isActualSize && abs(table.viewport.zoom - 1) < 0.01, "3: 1:1 again goes back to fit")
        let acts = page.actions()
        acts?.setTable(.a5, nil)
        try? await Task.sleep(for: .milliseconds(700))
        let a5 = table.model.paper == .a5
        acts?.setTable(nil, !table.model.portrait)
        try? await Task.sleep(for: .milliseconds(700))
        r.check(a5 && !table.model.portrait, "3: the size menu sets A5, the orientation button turns it (\(table.model.paper.name), portrait \(table.model.portrait))")
        acts?.setTable(.a4, true)
        try? await Task.sleep(for: .milliseconds(700))
        r.check(table.model.paper == .a4 && table.model.portrait, "3: and back to A4 upright")
        acts?.scatter()
        try? await Task.sleep(for: .milliseconds(700))
        r.check(page.undoShown(), "3: ··· › Scatter offers Undo")
        acts?.undo()
        try? await Task.sleep(for: .milliseconds(700))
        acts?.share()
        let sheetUp = await until(5) { window?.rootViewController?.presentedViewController != nil }
        try? await Task.sleep(for: .milliseconds(900))
        let presented = window?.rootViewController?.presentedViewController.map { String(describing: type(of: $0)) } ?? "none"
        snapshot("en-default-share", out: out)
        r.check(sheetUp && presented.contains("LightTableExportSheet"), "3: Share opens the Poster / Contact Sheet sheet (\(presented))")
        // The same UIKit page sheet with no grid in it, closed the same way: what the old Add sheet's close owes
        // to the sheet itself, and what to its grid.
        var shareGone: ContinuousClock.Instant?
        let shareStalls = Stalls()
        let shareT0 = ContinuousClock.now
        shareStalls.start()
        window?.rootViewController?.presentedViewController?.dismiss(animated: true) { shareGone = .now }
        _ = await until(5, every: 1) { shareGone != nil }
        bar["share_sheet_close"] = ["dismissal_done_ms": round1(shareGone.map { ms(shareT0, $0) } ?? -1), "stall_ms": shareStalls.stop()]
        _ = await until(5) { window?.rootViewController?.presentedViewController == nil }
        try? await Task.sleep(for: .milliseconds(500))
        r.step("3: the bar", ms(since: t0), bar)

        // ---- 4. 1:1 against the display. ----
        t0 = ContinuousClock.now
        let reading = MacDisplay.reading(for: window)
        var oneToOne: [String: Any] = [:]
        if let reading {
            oneToOne["display"] = ["id": Int(reading.displayID), "name": reading.name, "builtin": reading.builtin,
                                   "mm": [round3(Double(reading.millimetres.width)), round3(Double(reading.millimetres.height))],
                                   "mode_points": [Double(reading.points.width), Double(reading.points.height)],
                                   "mode_pixels": [Double(reading.pixels.width), Double(reading.pixels.height)],
                                   "mac_points_per_scene_point": round3(reading.macPointsPerScenePoint), "drawable_scale": reading.drawableScale,
                                   "mac_points_per_mm": round3(MacActualSize.macPointsPerMM(points: reading.points, millimetres: reading.millimetres) ?? -1),
                                   "pixels_per_mm": round3(MacActualSize.pixelsPerMM(reading) ?? -1),
                                   "scene_points_per_mm": round3(MacActualSize.scenePointsPerMM(reading) ?? -1),
                                   "ppi": round1((MacActualSize.pixelsPerMM(reading) ?? 0) * 25.4)] as [String: Any]
        }
        r.check(reading != nil && table.pointsPerMM != nil, "4: the display's size and mode are read, and the table has a 1:1")
        let kept = table.snapshot()
        acts?.takeAllOff()
        try? await Task.sleep(for: .milliseconds(900))
        acts?.setTable(.a6, false)
        try? await Task.sleep(for: .milliseconds(900))
        page.key(.actualSize)
        try? await Task.sleep(for: .milliseconds(600))
        if let reading, let ppmm = table.pointsPerMM, let window {
            let scale = Double(window.screen.scale)
            let image = table.still(size: table.viewport.size, scale: scale, inset: table.viewport.inset)
            table.still = false
            if let image {
                try? UIImage(cgImage: image).pngData()?.write(to: out.appending(path: "measure-1to1-a6.png"))
                let half = table.model.half
                let corner = table.viewport.toScreen(CGPoint(x: -half.width, y: half.height))
                // a row 1 mm in from the top edge, from 2.5 mm in from each end (the left scale's own ticks are there)
                let s = table.viewport.s
                let m = ticks(image, y: (Double(corner.y) + 1.0 * s) * scale, x0: (Double(corner.x) + 2.5 * s) * scale,
                              x1: (Double(corner.x) + (2 * Double(half.width) - 2.5) * s) * scale)
                let pxPerMM = m.pitch
                let onGlass = MacActualSize.millimetres(drawablePixels: 10 * pxPerMM, reading) ?? -1
                let tableBacking = pxPerMM / scale * reading.macPointsPerScenePoint * Double(reading.pixels.width / reading.points.width)
                let displayBacking = MacActualSize.pixelsPerMM(reading) ?? -1
                oneToOne["measured"] = ["ticks_found": m.count, "drawable_px_per_mm": round3(pxPerMM), "drawable_px_per_cm": round3(10 * pxPerMM),
                                        "scene_points_per_mm_measured": round3(pxPerMM / scale), "scene_points_per_mm_set": round3(ppmm),
                                        "table_backing_px_per_cm": round3(10 * tableBacking), "display_backing_px_per_cm": round3(10 * displayBacking),
                                        "one_cm_on_the_glass_mm": round3(onGlass), "fit_residual_px": round3(m.residual),
                                        "picture": "measure-1to1-a6.png"] as [String: Any]
                r.check(m.count >= 100, "4: the table's millimetre ticks are found along its top edge (\(m.count))")
                r.check(abs(pxPerMM / scale / ppmm - 1) < 0.005,
                        "4: the ticks are 1 mm apart at the zoom set (\(round3(pxPerMM / scale)) against \(round3(ppmm)) points a mm)")
                r.check(abs(tableBacking / displayBacking - 1) < 0.005,
                        "4: a centimetre of table is the display's pixels a centimetre (\(round3(10 * tableBacking)) against \(round3(10 * displayBacking)) px)")
                r.check(abs(onGlass - 10) < 0.05, "4: 1 cm of table measures \(round3(onGlass)) mm on the glass")
            } else { r.check(false, "4: the table at 1:1 is drawn") }
            // The same scale as the display shows it: the window captured by the window server (`screencapture -l`),
            // in the display's own pixels, and the ticks measured there.
            if let facts = MacDisplay.windowFacts(for: window), let view = tableView(in: window.rootViewController?.view) {
                try? await Task.sleep(for: .milliseconds(500))
                let file = out.appending(path: "screen-1to1-a6.png")
                let status = spawn("/usr/sbin/screencapture", ["-x", "-o", "-l\(facts.number)", file.path])
                if status == 0, let src = CGImageSourceCreateWithURL(file as CFURL, nil), let shot = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    let k = Double(facts.frame.width / window.bounds.width)          // Mac points a scene point
                    let px = k * facts.backing                                      // the capture's pixels a scene point
                    let half = table.model.half, s = table.viewport.s
                    let corner = table.viewport.toScreen(CGPoint(x: -half.width, y: half.height))
                    let a = view.convert(CGPoint(x: Double(corner.x) + 2.5 * s, y: Double(corner.y) + 1.0 * s), to: window)
                    let b = view.convert(CGPoint(x: Double(corner.x) + (2 * Double(half.width) - 2.5) * s, y: Double(corner.y) + 1.0 * s), to: window)
                    let m = ticks(shot, y: Double(a.y) * px, x0: Double(a.x) * px, x1: Double(b.x) * px)
                    let displayPx = MacActualSize.pixelsPerMM(reading) ?? -1
                    oneToOne["screen"] = ["capture": "screen-1to1-a6.png", "capture_px": [shot.width, shot.height],
                                          "window_mac_points": [Double(facts.frame.width), Double(facts.frame.height)], "backing": facts.backing,
                                          "ticks_found": m.count, "screen_px_per_mm": round3(m.pitch), "screen_px_per_cm": round3(10 * m.pitch),
                                          "display_px_per_cm": round3(10 * displayPx), "fit_residual_px": round3(m.residual),
                                          "one_cm_on_the_glass_mm": round3(10 * m.pitch / displayPx * 10) / 10] as [String: Any]
                    r.check(m.count >= 100 && abs(m.pitch / displayPx - 1) < 0.01,
                            "4: on the screen itself, a centimetre of table is \(round3(10 * m.pitch)) of the display's pixels against its \(round3(10 * displayPx)) a centimetre (\(m.count) ticks)")
                } else {
                    oneToOne["screen"] = ["capture": "failed", "status": Int(status)]
                    r.check(false, "4: the window is captured as the display shows it (screencapture \(status))")
                }
            }
        } else {
            oneToOne["problem"] = MacDisplay.problem ?? "no reading"
        }
        snapshot("en-default-1to1-a6", out: out)
        page.key(.actualSize)
        acts?.setTable(.a4, true)
        try? await Task.sleep(for: .milliseconds(800))
        table.restore(kept)
        try? await Task.sleep(for: .milliseconds(900))
        r.check(table.model.order.count == 7 && table.model.paper == .a4, "4: the table put back as it was (\(table.model.order.count), \(table.model.paper.name))")
        r.step("4: 1:1", ms(since: t0), oneToOne)

        // ---- 5. The rail. ----
        t0 = ContinuousClock.now
        var rail: [String: Any] = [:]
        r.check(page.rail(), "5: the rail is out by default")
        let order = LightTableRail.order(table.model)
        rail["order"] = order.map(name)
        r.check(Set(order) == Set(table.model.order) && order.count == 7, "5: the rail lists every film on the table (\(order.count))")
        r.check(Array(order.prefix(5)) == firstFive, "5: in the order they were laid: the five first, as the page listed them")
        table.bringToTop(order[3])
        r.check(LightTableRail.order(table.model) == order, "5: a film brought to the top keeps its place in the rail")
        let first = order[0]
        let rotBefore = table.model.item(first)?.rot ?? 0
        page.menuActions()?.rotateRight(first)
        try? await Task.sleep(for: .milliseconds(500))
        let rotAfter = table.model.item(first)?.rot ?? 0
        if let it = table.model.item(first) {
            let tile = LightTableRail.tile(it, box: CGSize(width: 150, height: 118))
            rail["first_tile"] = ["film": name(first), "table_degrees": round3(rotAfter / LightTable.deg), "tile_screen_degrees": round3(tile.angle / LightTable.deg),
                                  "tile_box": [round1(Double(tile.extent.width)), round1(Double(tile.extent.height))]] as [String: Any]
            r.check(abs(rotAfter - rotBefore + LightTable.quarter) < 1e-9 && abs(tile.angle + rotAfter) < 1e-12,
                    "5: after Rotate Right its tile is turned as it lies (table \(round3(rotAfter / LightTable.deg))°, tile \(round3(tile.angle / LightTable.deg))° on the screen)")
        }
        table.select(first)
        try? await Task.sleep(for: .milliseconds(500))
        snapshot("en-default-rail-open", out: out)
        // The room the table fits in: the view fills the window since 2026-10-26 and the rail floats over it,
        // so the rail moves the table's right inset, not the view's width.
        let tableRoom = { table.viewport.size.width - table.viewport.inset.left - table.viewport.inset.right }
        let widthOpen = tableRoom()
        page.key(.rail)
        try? await Task.sleep(for: .milliseconds(700))
        let widthClosed = tableRoom()
        snapshot("en-default-rail-closed", out: out)
        r.check(!page.rail() && widthClosed > widthOpen + 100, "5: ⌥⌘0 puts the rail away, the table takes its room (\(round1(widthOpen)) → \(round1(widthClosed)) points)")
        // No job: the queue idle first (the table's own asks for what it shows), then the rail built afresh.
        let idleAt = ContinuousClock.now
        let idle = await until(900, every: 250) { scheduler.isIdle && table.making.isEmpty }
        rail["waited_for_the_table_s"] = round1(ms(since: idleAt) / 1000)
        try? await Task.sleep(for: .seconds(1))
        MacRailPictures.shared.empty()
        let readsBefore = MacRailPictures.shared.reads
        let watch = JobWatch(scheduler)
        page.key(.rail)
        _ = await until(30) { MacRailPictures.shared.reads - readsBefore >= min(order.count, 4) }
        try? await Task.sleep(for: .seconds(2))
        let jobs = watch.stop(scheduler)
        let reads = MacRailPictures.shared.reads - readsBefore
        var origins: [[String: String]] = []
        for id in order {
            let src = table.pictureSource(id, edge: 512)
            origins.append(["film": name(id), "rail": MacRailPictures.shared.readFrom[src.key] ?? "(not read at 512)",
                            "rail_rule_at_512": LightTableTextures.origin(src), "table": table.textureFacts(id).from ?? "nothing"])
        }
        rail["queue_idle_first"] = idle
        rail["rail_reads"] = reads
        rail["jobs_while_the_rail_was_built"] = jobs
        rail["sources"] = origins
        r.check(page.rail(), "5: and brings it back")
        r.check(reads >= min(order.count, 4), "5: the rail read a picture for each tile it shows (\(reads) of \(order.count): the rest are below the fold, read as they scroll in)")
        r.check(jobs.isEmpty, "5: building the rail asked for no job (\(jobs))")
        snapshot("en-default-rail-back", out: out)
        r.step("5: the rail", ms(since: t0), rail)

        // ---- 6. The menu, and the keys. ----
        t0 = ContinuousClock.now
        var menuFacts: [String: Any] = [:]
        if let view = tableView(in: window?.rootViewController?.view), let menu = view.contextMenu as? MacLightTableMenu,
           let target = table.model.order.last, let box = table.screenBox(target) {
            let flat = flatten(menu.menu(at: CGPoint(x: box.midX, y: box.midY)))
            menuFacts["items"] = flat.map { $0.title.isEmpty ? "—" : $0.title }
            menuFacts["keys"] = flat.compactMap { ($0.command as? UIKeyCommand).map(keyName) }
            r.check(flat.map(\.title) == [L("Rotate Right"), L("Rotate Left"), "", L("Take Off")],
                    "6: the menu is exactly Rotate Right, Rotate Left, a separator, Take Off (\(flat.map(\.title)))")
            r.check(table.selected == target, "6: the film right-clicked is chosen")
            let rot0 = table.model.item(target)?.rot ?? 0
            func send(_ i: Int) -> Bool {
                guard i < flat.count, let k = flat[i].command as? UIKeyCommand, let action = k.action else { return false }
                return UIApplication.shared.sendAction(action, to: nil, from: k, for: nil)
            }
            let sentRight = send(0)
            let rightOK = abs((table.model.item(target)?.rot ?? 0) - (rot0 - LightTable.quarter)) < 1e-9
            let sentLeft = send(1)
            let leftOK = abs((table.model.item(target)?.rot ?? 0) - rot0) < 1e-9
            r.check(sentRight && sentLeft && rightOK && leftOK, "6: Rotate Right turns it a quarter clockwise, Rotate Left back (sent up the responder chain: \(sentRight), \(sentLeft))")
            let sentOff = send(3)
            try? await Task.sleep(for: .milliseconds(300))
            r.check(sentOff && !table.model.order.contains(target) && page.undoShown(), "6: Take Off takes it off, with Undo")
            page.actions()?.undo()
            try? await Task.sleep(for: .milliseconds(600))
            r.check(table.model.order.contains(target), "6: Undo puts it back")
            let corner = table.viewport.toScreen(CGPoint(x: -table.model.half.width + 1, y: -table.model.half.height + 1))
            let emptyThere = table.film(at: corner) == nil
            r.check(emptyThere && menu.menu(at: corner) == nil, "6: the empty table has no menu")
            // The keys, through the page's own door.
            table.select(target)
            let k0 = table.model.item(target)?.rot ?? 0
            page.key(.rotateRight)
            let k1 = table.model.item(target)?.rot ?? 0
            page.key(.rotateLeft)
            let k2 = table.model.item(target)?.rot ?? 0
            r.check(abs(k1 - (k0 - LightTable.quarter)) < 1e-9 && abs(k2 - k0) < 1e-9, "6: R turns the chosen film right, ⇧R left")
            let p0 = table.model.item(target)?.centre ?? .zero
            page.key(.right)
            page.key(.bigDown)
            let p1 = table.model.item(target)?.centre ?? .zero
            r.check(abs(Double(p1.x - p0.x) - 1) < 1e-6 && abs(Double(p1.y - p0.y) + 10) < 1e-6,
                    "6: → moves it 1 mm, ⇧↓ 10 mm (\(round3(Double(p1.x - p0.x))), \(round3(Double(p1.y - p0.y))))")
            page.key(.takeOff)
            try? await Task.sleep(for: .milliseconds(300))
            r.check(!table.model.order.contains(target), "6: ⌫ takes the chosen film off")
            page.actions()?.undo()
            try? await Task.sleep(for: .milliseconds(600))
            let registered = keyCommands()
            menuFacts["key_commands_found"] = registered
            r.check(registered.contains("r") && registered.contains("⇧r") && registered.contains("⌫"),
                    "6: R, ⇧R and ⌫ are the window's key commands while the table is in front")
            drawMenu(flat, out: out, name: "en-menu")
        } else {
            r.check(false, "6: the table view carries its menu")
        }
        r.step("6: the menu and the keys", ms(since: t0), menuFacts)

        // ---- 7. The pictures, in two languages at two sizes. ----
        t0 = ContinuousClock.now
        var drawn: [Any] = []
        var windows: [String: [CGFloat]] = [:]
        let sizes: [(String, CGSize)] = [("min", CGSize(width: 847, height: 539)), ("large", CGSize(width: 1440, height: 900))]
        for language in [AppLanguage.english, .simplified] {
            Language.shared.choose(language)
            let lang = language == .english ? "en" : "zh-Hans"
            for (sizeName, size) in sizes {
                let got = await resize(to: size)
                windows["\(lang)-\(sizeName)"] = [got.width, got.height]
                let stem = "\(lang)-\(sizeName)"
                if !page.rail() { page.key(.rail) }
                page.key(.fit)
                table.select(table.model.order.first)
                try? await Task.sleep(for: .milliseconds(800))
                drawn.append(snapshot("\(stem)-fitted", out: out))
                if table.model.order.count > 1, let box = table.screenBox(table.model.order[1]) {
                    table.zoom(to: 3, around: CGPoint(x: box.midX, y: box.midY))
                }
                try? await Task.sleep(for: .milliseconds(800))
                drawn.append(snapshot("\(stem)-zoomed", out: out))
                page.key(.actualSize)
                try? await Task.sleep(for: .milliseconds(800))
                drawn.append(snapshot("\(stem)-1to1", out: out))
                page.key(.fit)
                _ = await until(3) { abs(table.viewport.zoom - 1) < 0.005 }
                page.key(.rail)
                try? await Task.sleep(for: .milliseconds(800))
                drawn.append(snapshot("\(stem)-rail-closed", out: out))
                page.key(.rail)
                page.key(.click)
                try? await Task.sleep(for: .milliseconds(600))
                drawn.append(snapshot("\(stem)-click-tool", out: out))
                page.key(.drag)
                page.setAdding(true)
                try? await Task.sleep(for: .milliseconds(800))
                drawn.append(snapshot("\(stem)-add-page", out: out))
                page.setAdding(false)
                try? await Task.sleep(for: .milliseconds(400))
                if let view = tableView(in: window?.rootViewController?.view), let menu = view.contextMenu as? MacLightTableMenu,
                   let id = table.model.order.first, let box = table.screenBox(id) {
                    drawMenu(flatten(menu.menu(at: CGPoint(x: box.midX, y: box.midY))), out: out, name: "\(stem)-menu")
                    drawn.append(["file": "\(stem)-menu.png", "note": "the menu's items as built, drawn here (AppKit's menu is not in the window)"])
                }
            }
        }
        Language.shared.choose(startLanguage)
        restoreWindow()
        r.step("7: the pictures", ms(since: t0), ["files": drawn, "window_mac_points": windows])
        var json = r.json
        json["written"] = ISO8601DateFormatter().string(from: Date())
        return json
    }

    // MARK: - parts

    /// A tool run to its end (Catalyst has no `Process`): its exit status.
    private static func spawn(_ path: String, _ args: [String]) -> Int32 {
        var pid: pid_t = 0
        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { for a in argv { free(a) } }
        guard posix_spawn(&pid, path, nil, nil, argv, environ) == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status >> 8) & 0xff
    }

    /// A page with room for one film, put in the window for a moment: ⌘A keeps one.
    private static func roomCheck(_ model: AppServices, takes: [UUID]) async -> (kept: Int, trimmed: Bool) {
        guard let window else { return (0, false) }
        MacLightTableAddPage.shown = nil
        let host = UIHostingController(rootView: MacLightTableAddPage(onTable: [], room: 1, tableLine: "", layDown: { _ in }, cancel: {})
            .appEnvironment(model))
        host.view.frame = window.bounds
        host.view.alpha = 0.02
        window.addSubview(host.view)
        defer { host.view.removeFromSuperview() }
        _ = await until(5) { MacLightTableAddPage.shown != nil }
        try? await Task.sleep(for: .milliseconds(300))
        MacLightTableAddPage.shown?.selectAll(takes.compactMap { model.library.frame($0) }.map { CatalogSourcesStore.row($0, source: CatalogSourcesStore.appLibraryID) })
        try? await Task.sleep(for: .milliseconds(400))
        return (MacLightTableAddPage.shown?.selection.count ?? -1, MacLightTableAddPage.wasTrimmed)
    }

    /// The menu's items in order, a separator ("") before an inline section.
    private static func flatten(_ menu: UIMenu?) -> [(title: String, command: UIMenuElement?)] {
        guard let menu else { return [] }
        var out: [(title: String, command: UIMenuElement?)] = []
        func title(_ e: UIMenuElement) -> String { (e as? UICommand)?.title ?? (e as? UIAction)?.title ?? "?" }
        for e in menu.children {
            if let sub = e as? UIMenu, sub.options.contains(.displayInline) {
                if !out.isEmpty { out.append((title: "", command: nil)) }
                out += sub.children.map { (title: title($0), command: $0) }
            } else {
                out.append((title: title(e), command: e))
            }
        }
        return out
    }

    private static func keyName(_ k: UIKeyCommand) -> String {
        (k.modifierFlags.contains(.shift) ? "⇧" : "") + (k.input == UIKeyCommand.inputDelete ? "⌫" : (k.input ?? "").uppercased())
    }

    /// The menu's items drawn as the Mac draws a menu (the real one is AppKit's, outside the window).
    private static func drawMenu(_ items: [(title: String, command: UIMenuElement?)], out: URL, name: String) {
        let width: CGFloat = 220, row: CGFloat = 24
        let height = CGFloat(items.count) * row + 10
        let picture = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            UIColor(white: 0.17, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 7).fill()
            var y: CGFloat = 5
            for item in items {
                if item.title.isEmpty {
                    UIColor(white: 1, alpha: 0.15).setFill()
                    ctx.fill(CGRect(x: 10, y: y + row / 2, width: width - 20, height: 1))
                } else {
                    let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.white]
                    (item.title as NSString).draw(at: CGPoint(x: 14, y: y + 4), withAttributes: a)
                    if let k = item.command as? UIKeyCommand {
                        let key = keyName(k)
                        let ka: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor(white: 1, alpha: 0.5)]
                        let s = (key as NSString).size(withAttributes: ka)
                        (key as NSString).draw(at: CGPoint(x: width - 14 - s.width, y: y + 4), withAttributes: ka)
                    }
                }
                y += row
            }
        }
        try? picture.pngData()?.write(to: out.appending(path: "\(name).png"))
    }

    /// Every key command the window's responders hold (SwiftUI's `keyboardShortcut`s among them): "r", "⇧r", "⌫".
    private static func keyCommands() -> [String] {
        var out: Set<String> = []
        func add(_ ks: [UIKeyCommand]?) {
            for k in ks ?? [] {
                let input = k.input == UIKeyCommand.inputDelete ? "⌫" : (k.input ?? "")
                out.insert((k.modifierFlags.contains(.shift) ? "⇧" : "") + input)
            }
        }
        func walk(_ vc: UIViewController?) {
            guard let vc else { return }
            add(vc.keyCommands)
            for c in vc.children { walk(c) }
            walk(vc.presentedViewController)
        }
        walk(window?.rootViewController)
        func views(_ v: UIView) { add(v.keyCommands); for s in v.subviews { views(s) } }
        if let root = window?.rootViewController?.view { views(root) }
        return out.sorted()
    }

    /// The table's printed millimetre scale along a row of the picture: the ink's dark lines between `x0` and
    /// `x1`, their centres, and the pitch of a straight line fitted through them (pixels a millimetre).
    private static func ticks(_ image: CGImage, y: Double, x0: Double, x1: Double) -> (count: Int, pitch: Double, residual: Double) {
        let w = image.width, h = image.height
        let row = Int(y.rounded())
        guard row >= 0, row < h else { return (0, 0, 0) }
        guard let ctx = CGContext(data: nil, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        // the picture's row `row` (from the top) onto the one-pixel context
        ctx.draw(image, in: CGRect(x: 0, y: -(h - 1 - row), width: w, height: h))
        guard let data = ctx.data else { return (0, 0, 0) }
        let px = data.bindMemory(to: UInt8.self, capacity: w * 4)
        let a = max(0, Int(x0) + 2), b = min(w - 1, Int(x1) - 2)
        guard b > a else { return (0, 0, 0) }
        var lum = [Double](repeating: 0, count: w)
        for x in a...b { lum[x] = 0.2126 * Double(px[4 * x]) + 0.7152 * Double(px[4 * x + 1]) + 0.0722 * Double(px[4 * x + 2]) }
        let lit = lum[a...b].sorted()[Int(Double(b - a) * 0.9)]
        let threshold = lit * 0.82
        var centres: [Double] = []
        var x = a
        while x <= b {
            if lum[x] < threshold {
                var sw = 0.0, sx = 0.0
                while x <= b && lum[x] < threshold { let k = threshold - lum[x]; sw += k; sx += k * Double(x); x += 1 }
                if sw > 0 { centres.append(sx / sw) }
            } else { x += 1 }
        }
        guard centres.count > 10 else { return (centres.count, 0, 0) }
        // centre = c0 + i·pitch, i the millimetre each centre is nearest, by least squares
        let guess = (centres.last! - centres.first!) / Double(centres.count - 1)
        let idx = centres.map { (($0 - centres[0]) / guess).rounded() }
        let n = Double(centres.count), si = idx.reduce(0, +), sc = centres.reduce(0, +)
        let sii = idx.reduce(0) { $0 + $1 * $1 }, sic = zip(idx, centres).reduce(0) { $0 + $1.0 * $1.1 }
        let pitch = (n * sic - si * sc) / (n * sii - si * si)
        let c0 = (sc - pitch * si) / n
        let residual = zip(idx, centres).map { abs($0.1 - (c0 + $0.0 * pitch)) }.max() ?? 0
        return (centres.count, pitch, residual)
    }
}
#endif
