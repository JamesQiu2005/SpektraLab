//  MacExportCheck.swift — a debug build's proof of the Mac's Export page, in the running app.
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --export-check <dir> \
//          [--export-check-pictures <folder> …] [--export-check-exit]
//
//  Drives the page the owner asked for (`MacExportPage`, `MacExportRun`) with real RAWs and writes
//  `<dir>/report.json`, every step timed, with what each file read back as (ImageIO, not the app's writer):
//
//  A. **A batch from the library**: five pictures copied into a scratch folder, linked as a Finder folder
//     source; one deleted before the page opens (never a frame: left out, and said), one deleted after its
//     frame was made (its original cannot be read: said on its line); the library's own Export page
//     presented over it (`MacLibraryBrowser.exportAsked`) and **its own Export pressed**, into a folder that
//     already holds a file of the first picture's name. The three that can go must each be in the folder
//     at the recipe's format, pixel size and colour space, the clash named "-2" and the old file untouched;
//     and one after another: never two of the batch's jobs under way at once (the scheduler's own view,
//     sampled), each ending before the next begins.
//  B. **Stop half way**: a 16-bit TIFF batch of three, stopped while the second is under way. The first
//     must be in its folder whole; nothing else, and no part of a file, may be.
//  C. **Develop's one picture**: the file the old path made (the service's batch, as the window's Exporting
//     sheet handed it to the system's Files browser) against the file Develop's Export now makes (the
//     router's `.export`, which on the Mac is this page), pressed with the same recipe: same container,
//     pixels and space, and the pixels compared.
//
//  The page is drawn to `<dir>/page-*.png` at each step (its own view, as the window holds it: a presented
//  page is not in `--capture-window`'s picture). Pictures are only read from where they are; every file
//  written is under `<dir>`. Not in a release build.

#if DEBUG
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
enum MacExportCheck {
    // MARK: the page's hooks

    /// How many pictures each Export page that appeared had, in order.
    private(set) static var pagesShown: [Int] = []
    /// The page in front's own Export button: a recipe and a folder pressed into it.
    private static var press: ((ExportRecipe, URL?) -> Void)?

    static func pageShown(_ count: Int) { pagesShown.append(count) }
    static func attach(_ press: @escaping (ExportRecipe, URL?) -> Void) { self.press = press }
    /// The driver's `export.go` (`MacDriver`): the page in front's Export pressed, with the last recipe,
    /// into `<home>/Exported` (made if it is not there). False with no page to press.
    static func pressFront(recipe: ExportRecipe) -> Bool {
        guard let press else { return false }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Exported")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var r = recipe
        r.destination = .files
        press(r, folder)
        return true
    }

    // MARK: running

    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        // The folder is a path: anything else after `--export-check` is not this check's.
        guard let i = arguments.firstIndex(of: "--export-check"), i + 1 < arguments.count,
              arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--export-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        if pictures.isEmpty {
            guard let root = ProcessInfo.processInfo.environment["SPK_TEST_IMAGES"], !root.isEmpty else {
                print("export-check: supply --export-check-pictures or SPK_TEST_IMAGES; no fixtures were run")
                if arguments.contains("--export-check-exit") { exit(2) }
                return
            }
            pictures = [URL(fileURLWithPath: root + "/Nikon Z7ii"), URL(fileURLWithPath: root + "/A7m3")]
        }
        let exits = arguments.contains("--export-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let report = await run(model, out: out, pictures: pictures)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("export-check: wrote \(out.appending(path: "report.json").path)")
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
            print("export-check: \(name) \(Int(ms)) ms \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append(what); print("export-check: FAIL \(what)") }
        }
    }

    private static func ms(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Waits for `done`, at most `seconds`; whether it came.
    private static func until(_ seconds: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(ms))
        }
        return done()
    }

    /// The scheduler's export jobs, sampled while a batch runs: how many were under way at once at the
    /// most, and when each was first and last seen under way, in the order they began.
    @MainActor private final class JobWatch {
        var most = 0
        var seen: [UUID: (first: Date, last: Date, what: String)] = [:]
        var order: [UUID] = []
        func sample(_ scheduler: RenderQueue) {
            let now = Date()
            let running = scheduler.snapshots.filter { s in
                guard s.job.kind == .export else { return false }
                if case .running = s.state { return true }
                return false
            }
            most = max(most, running.count)
            for s in running {
                if let had = seen[s.id] { seen[s.id] = (had.first, now, had.what) } else {
                    seen[s.id] = (now, now, s.job.what)
                    order.append(s.id)
                }
            }
        }
        /// When the first job was seen under way: the batch's time zero.
        var firstSeen: Date { order.first.flatMap { seen[$0]?.first } ?? Date() }
        /// Each job seen under way began after the one before it was last seen under way.
        var inTurn: Bool {
            zip(order, order.dropFirst()).allSatisfy { a, b in (seen[b]?.first ?? .distantPast) >= (seen[a]?.last ?? .distantFuture) }
        }
        var facts: [[String: Any]] {
            let t0 = order.first.flatMap { seen[$0]?.first } ?? Date()
            return order.compactMap { id in
                seen[id].map { ["file": $0.what, "from_s": round3($0.first.timeIntervalSince(t0)), "to_s": round3($0.last.timeIntervalSince(t0))] }
            }
        }
    }

    /// Runs `batch` to its end while the scheduler is sampled every 10 ms.
    private static func watched(_ model: AppServices, seconds: Double = 600, stopWhen: (() -> Bool)? = nil) async -> JobWatch {
        let watch = JobWatch()
        let run = MacExportRun.shared
        let end = Date().addingTimeInterval(seconds)
        var stopped = false
        while Date() < end, run.isRunning {
            watch.sample(model.scheduler)
            if !stopped, let stopWhen, stopWhen() {
                stopped = true
                run.stop()          // the page's Stop: `MacExportScreen.footer`
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return watch
    }

    static func run(_ model: AppServices, out: URL, pictures: [URL]) async -> [String: Any] {
        let r = Report()
        let fm = FileManager.default
        let store = model.macLibrary
        let browser = MacLibraryBrowser.shared
        let run = MacExportRun.shared
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        for name in ["exports-A", "exports-B", "exports-C", "old-path"] { try? fm.removeItem(at: out.appending(path: name)) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        r.step("start", 0, ["home": NSHomeDirectory(), "engine_writes_files": model.exporter.wroteFiles])
        r.check(model.exporter.wroteFiles, "the engine writes files (a real engine, not the simulation)")

        // The pictures: three Z 7II NEFs and both α7 III ARWs, copied (never moved) into a scratch folder.
        let raws = pictures.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["nef", "arw"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let nefs = raws.filter { $0.pathExtension.lowercased() == "nef" }, arws = raws.filter { $0.pathExtension.lowercased() == "arw" }
        guard nefs.count >= 3, arws.count >= 2 else {
            r.check(false, "three NEFs and two ARWs to export (found \(nefs.count) and \(arws.count))")
            return ["steps": r.steps, "failures": r.failures]
        }
        // In the batch's order: NEF, ARW, NEF (its file goes after its frame is made), ARW, NEF (its file
        // goes before the page opens).
        let chosen = [nefs[0], arws[0], nefs[1], arws[1], nefs[2]]
        let card = work.appending(path: "Card")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for u in chosen { try? fm.copyItem(at: u, to: card.appending(path: u.lastPathComponent)) }
        let unreadable = chosen[2].lastPathComponent, away = chosen[4].lastPathComponent

        await store.start()
        var t0 = ContinuousClock.now
        do { _ = try await store.open(card) } catch { r.check(false, "the scratch folder links: \(error.localizedDescription)") }
        await store.loadAll()
        let rows = chosen.compactMap { u in store.images.first { $0.fileName == u.lastPathComponent } }
        r.step("A: link a folder of five RAWs", ms(since: t0), ["listed": store.images.count, "rows": rows.map(\.fileName)])
        r.check(rows.count == 5, "the folder lists its five pictures (\(rows.count))")
        guard rows.count == 5 else { return ["steps": r.steps, "failures": r.failures] }

        // One goes before the page opens: it never becomes a frame.
        try? fm.removeItem(at: card.appending(path: away))

        // ---- A. The library's Export page, its own button. ----
        t0 = ContinuousClock.now
        browser.selection = Set(rows.map(\.id))
        let shownBefore = pagesShown.count
        browser.exportAsked = true
        let appeared = await until(60) { pagesShown.count > shownBefore && press != nil }
        try? await Task.sleep(for: .milliseconds(600))
        snapshot("page-library", out: out)
        r.step("A: the library's Export page", ms(since: t0), ["appeared": appeared, "pictures": pagesShown.last ?? -1])
        r.check(appeared && pagesShown.last == 5, "the library's Export page opens with the five chosen pictures")

        let frameOf = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            model.library.frames.first { $0.picture.fileURL?.lastPathComponent == row.fileName }.map { (row.fileName, $0) }
        })
        r.check(frameOf[away] == nil, "the picture whose file went before the page is not made a frame")
        r.check(frameOf.count == 4, "the other four are frames (\(frameOf.count))")

        // One goes after its frame is made: its original cannot be read when its turn comes.
        try? fm.removeItem(at: card.appending(path: unreadable))

        var recipeA = ExportRecipe(format: .jpeg, size: .longEdge(2048), colour: .displayP3, destination: .files)
        recipeA.quality = 90
        let folderA = out.appending(path: "exports-A")
        try? fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        // A file of the first picture's name is in the folder already: it must be neither written over nor lost.
        let clash = folderA.appending(path: recipeA.fileName(stem: (chosen[0].lastPathComponent as NSString).deletingPathExtension))
        let clashBytes = Data("the user's own file, not SpektraLab's".utf8)
        try? clashBytes.write(to: clash)
        let expectA = Dictionary(uniqueKeysWithValues: frameOf.map { ($0.key, model.exporter.outputSize($0.value, recipeA)) })

        t0 = ContinuousClock.now
        press?(recipeA, folderA)
        r.check(run.isRunning, "the page's Export begins a batch")
        // Sampled from the press: one of these exports takes about half a second.
        var drewRunning = false
        let watchA = await watched(model) {
            if !drewRunning, run.lines.count > 1, case .running = run.lines[1].state {
                drewRunning = true
                snapshot("page-running", out: out)
            }
            return false
        }
        let batchA = ms(since: t0)
        try? await Task.sleep(for: .milliseconds(400))
        snapshot("page-finished", out: out)

        var filesA: [[String: Any]] = []
        for line in run.lines {
            var f: [String: Any] = ["name": line.name, "state": "\(line.state)"]
            if let b = line.began, let e = line.ended { f["began_s"] = round3(b.timeIntervalSince(watchA.firstSeen)); f["ended_s"] = round3(e.timeIntervalSince(watchA.firstSeen)) }
            if case .saved(let url) = line.state {
                let back = readBack(url)
                f["file"] = url.lastPathComponent
                f["read_back"] = back
                let source = chosen.first { (line.name as NSString).deletingPathExtension == ($0.lastPathComponent as NSString).deletingPathExtension }?.lastPathComponent ?? ""
                if let want = expectA[source] {
                    f["planned"] = [want.width, want.height]
                    r.check(back["width"] as? Int == want.width && back["height"] as? Int == want.height,
                            "A: \(url.lastPathComponent) is the planned \(want.width) × \(want.height) (read \(back["width"] ?? "?") × \(back["height"] ?? "?"))")
                }
                r.check(max(back["width"] as? Int ?? 0, back["height"] as? Int ?? 0) == 2048, "A: \(url.lastPathComponent) is 2,048 px on its long edge")
                r.check(back["type"] as? String == UTType.jpeg.identifier, "A: \(url.lastPathComponent) is a JPEG")
                r.check(back["depth"] as? Int == 8, "A: \(url.lastPathComponent) is 8 bits a channel")
                r.check((back["profile"] as? String)?.contains("P3") == true, "A: \(url.lastPathComponent) carries Display P3 (\(back["profile"] ?? "none"))")
                r.check(back["complete"] as? Bool == true, "A: \(url.lastPathComponent) is whole")
                r.check(url.deletingLastPathComponent().standardizedFileURL.path == folderA.standardizedFileURL.path, "A: \(url.lastPathComponent) is in the chosen folder")
            }
            filesA.append(f)
        }
        let listedA = ((try? fm.contentsOfDirectory(atPath: folderA.path)) ?? []).sorted()
        r.step("A: five chosen, exported one at a time into a folder", batchA, [
            "recipe": "JPEG · Display P3 · 2048 long edge · q90", "lines": filesA, "folder": listedA,
            "jobs_at_once_most": watchA.most, "jobs_in_turn": watchA.facts, "run_most_at_once": run.mostAtOnce,
            "summary": "saved \(run.saved) of \(run.lines.count); problems: \(run.problems.map { "\($0.name): \($0.problem ?? "")" })",
        ])
        r.check(run.saved == 3, "A: the three readable pictures are saved (\(run.saved))")
        r.check(run.lines.count == 5, "A: every chosen picture has its line (\(run.lines.count))")
        r.check(run.lines.first { $0.name == away }.map { if case .leftOut = $0.state { true } else { false } } == true,
                "A: the picture whose file went before the page is said (left out)")
        let unreadableLine = run.lines.first { ($0.name as NSString).deletingPathExtension == (unreadable as NSString).deletingPathExtension }
        r.check(unreadableLine.map { if case .failed = $0.state { true } else { false } } == true,
                "A: the picture whose original went after its frame is said, not saved (\(unreadableLine.map { "\($0.state)" } ?? "no line"))")
        r.check(watchA.most == 1, "A: never two of the batch's jobs under way at once (\(watchA.most))")
        r.check(watchA.order.count >= 3 && watchA.inTurn, "A: each job ends before the next begins (\(watchA.order.count) seen)")
        let went = run.lines.filter { $0.frameID != nil }
        let timed = went.compactMap { l in l.began.flatMap { b in l.ended.map { (b, $0) } } }
        r.check(timed.count >= 3 && zip(timed, timed.dropFirst()).allSatisfy { $0.1 <= $1.0 },
                "A: each picture ended before the next began (\(timed.count) timed)")
        r.check((try? Data(contentsOf: clash)) == clashBytes, "A: the file already in the folder is untouched")
        let firstStem = (chosen[0].lastPathComponent as NSString).deletingPathExtension
        r.check(listedA.contains("\(firstStem)-2.jpg"), "A: the clashing name is saved as \(firstStem)-2.jpg")
        r.check(!listedA.contains { $0.hasSuffix(".spkpart") }, "A: no part of a file is left in the folder")
        r.check(listedA.count == 4, "A: the folder holds the old file and three exports (\(listedA.count))")

        // ---- B. Stop half way. ----
        let readable = [chosen[0], chosen[1], chosen[3]].compactMap { frameOf[$0.lastPathComponent]?.id }
        let recipeB = ExportRecipe(format: .tiff, size: .longEdge(3000), colour: .proPhoto, destination: .files)
        let folderB = out.appending(path: "exports-B")
        try? fm.createDirectory(at: folderB, withIntermediateDirectories: true)
        t0 = ContinuousClock.now
        let begunB = run.start(readable, recipe: recipeB, folder: folderB, exporter: model.exporter)   // what the page's Export calls
        r.check(begunB, "B: a batch of three begins")
        var atStop = ""
        let watchB = await watched(model) {
            guard run.lines.count == 3, case .saved = run.lines[0].state, case .running(let p) = run.lines[1].state, p.fraction > 0.05 else { return false }
            atStop = "first saved; second under way at \(Int(p.fraction * 100)) %"
            return true
        }
        let listedB = ((try? fm.contentsOfDirectory(atPath: folderB.path)) ?? []).sorted()
        var backB: [String: Any] = [:]
        if case .saved(let url)? = run.lines.first?.state { backB = readBack(url) }
        r.step("B: a 16-bit TIFF batch of three, stopped half way", ms(since: t0), [
            "stopped_when": atStop, "lines": run.lines.map { "\($0.name): \($0.state)" }, "folder": listedB,
            "first_read_back": backB, "jobs_at_once_most": watchB.most,
        ])
        r.check(!atStop.isEmpty, "B: Stop was pressed while the second picture was under way")
        r.check(run.saved == 1 && run.lines.dropFirst().allSatisfy { $0.state == .stopped }, "B: one saved, the rest stopped")
        r.check(listedB.count == 1, "B: the folder holds only the finished picture (\(listedB))")
        r.check(backB["complete"] as? Bool == true && backB["depth"] as? Int == 16, "B: the finished picture is whole, 16 bits a channel")
        r.check(backB["type"] as? String == UTType.tiff.identifier, "B: it is a TIFF")
        r.check((backB["profile"] as? String).map { $0.contains("ROMM") || $0.contains("ProPhoto") } == true, "B: it carries ProPhoto (\(backB["profile"] ?? "none"))")
        r.check(max(backB["width"] as? Int ?? 0, backB["height"] as? Int ?? 0) == 3000, "B: it is 3,000 px on its long edge")

        // ---- C. Develop's one picture: the old path, then the page. ----
        browser.exportAsked = false
        try? await Task.sleep(for: .seconds(1))
        guard let develop = frameOf[chosen[1].lastPathComponent] else { return ["steps": r.steps, "failures": r.failures] }
        let recipeC = ExportRecipe(format: .jpeg, size: .megapixels(12), colour: .sRGB, destination: .files)
        // The old path: the service's batch, whose file the window's Exporting sheet hands to the system's browser.
        t0 = ContinuousClock.now
        model.exporter.start([develop.id], recipe: recipeC)
        _ = await until(300) { !model.exporter.isExporting }
        let oldFolder = out.appending(path: "old-path")
        try? fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        var oldFile: URL?
        if let made = model.exporter.batch?.items.first?.file {
            let kept = oldFolder.appending(path: made.lastPathComponent)
            try? fm.copyItem(at: made, to: kept)
            oldFile = kept
        }
        let oldMS = ms(since: t0)
        model.exporter.clear()
        // The new path: Develop's Export button asks the router for `.export([id])`, the page answers.
        let shownC = pagesShown.count
        model.router.present(.export([develop.id]))
        let appearedC = await until(30) { pagesShown.count > shownC }
        try? await Task.sleep(for: .milliseconds(600))
        snapshot("page-develop", out: out)
        r.check(appearedC && pagesShown.last == 1, "C: Develop's Export opens the Mac page with its one picture")
        let folderC = out.appending(path: "exports-C")
        try? fm.createDirectory(at: folderC, withIntermediateDirectories: true)
        t0 = ContinuousClock.now
        press?(recipeC, folderC)
        _ = await until(5, every: 20) { run.isRunning }
        _ = await watched(model)
        var newFile: URL?
        if case .saved(let url)? = run.lines.first?.state { newFile = url }
        let newMS = ms(since: t0)
        var compare: [String: Any] = [:]
        if let oldFile, let newFile {
            let a = readBack(oldFile), b = readBack(newFile)
            compare = ["old": a, "new": b, "same_bytes": (try? Data(contentsOf: oldFile)) == (try? Data(contentsOf: newFile))]
            let diff = pixelDifference(oldFile, newFile)
            compare["pixels"] = diff
            for key in ["type", "width", "height", "depth", "profile"] {
                r.check(String(describing: a[key] ?? "") == String(describing: b[key] ?? ""), "C: old and new agree on \(key) (\(a[key] ?? "?") / \(b[key] ?? "?"))")
            }
            r.check(diff["max"] as? Int == 0, "C: old and new have the same pixels (max difference \(diff["max"] ?? "?"))")
            r.check(oldFile.lastPathComponent == newFile.lastPathComponent, "C: the same file name (\(oldFile.lastPathComponent) / \(newFile.lastPathComponent))")
        } else {
            r.check(false, "C: both paths made a file (old \(oldFile != nil), new \(newFile != nil))")
        }
        r.step("C: Develop's one picture, old path and page", oldMS + newMS, ["old_ms": round3(oldMS), "page_ms": round3(newMS), "compare": compare])
        model.router.dismissAllSheets()
        try? await Task.sleep(for: .milliseconds(500))

        r.step("pages", 0, ["shown": pagesShown])
        return ["steps": r.steps, "failures": r.failures, "passed": r.failures.isEmpty,
                "written": ISO8601DateFormatter().string(from: Date())]
    }

    // MARK: reading back

    nonisolated private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// A file as ImageIO reads it: its kind, pixels, depth, profile, and whether it decodes whole.
    static func readBack(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ["readable": false] }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        let bytes = image?.dataProvider?.data.map { CFDataGetLength($0) } ?? 0
        let needed = image.map { $0.bytesPerRow * $0.height } ?? Int.max
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ["type": CGImageSourceGetType(src) as String? ?? "", "width": w, "height": h,
                "depth": props[kCGImagePropertyDepth] as? Int ?? 0, "profile": props[kCGImagePropertyProfileName] as? String ?? "",
                "complete": CGImageSourceGetStatus(src) == .statusComplete && image != nil && bytes >= needed,
                "bytes": size]
    }

    /// Two pictures of one size drawn into the same 8-bit RGBA space: how far apart their numbers are.
    static func pixelDifference(_ a: URL, _ b: URL) -> [String: Any] {
        func pixels(_ url: URL) -> (Int, Int, [UInt8])? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = data.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return drawn ? (w, h, data) : nil
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return ["error": "not readable"] }
        guard pa.0 == pb.0, pa.1 == pb.1 else { return ["error": "sizes differ"] }
        var most = 0, differing = 0
        for i in pa.2.indices {
            let d = abs(Int(pa.2[i]) - Int(pb.2[i]))
            if d > 0 { differing += 1; most = max(most, d) }
        }
        return ["max": most, "values_differing": differing, "values": pa.2.count]
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
