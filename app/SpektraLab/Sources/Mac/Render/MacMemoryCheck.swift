//  MacMemoryCheck.swift — a debug build's measurement, in the running app, of what browsing fresh RAWs, a
//  full-size inspection and a memory-pressure event cost (DIAG-2026-11-13 Part 2, item 5: "the proof").
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --library real --defaults-suite <name> --memory-check <dir>
//          --memory-check-pictures <folder> [--memory-check-exit]
//
//  `--memory-check-browse-only` stops after step 1 (a preview size's own cost, `tools/memory_check.sh --preview-edge`);
//  `--memory-check-keep` copies each browsed frame's kept develop into `<dir>/developed` and, past step 2, the
//  inspected frame's full render into `<dir>/full` (2.4.0's 3,840 px preview against its full render, the sharpness);
//  `--memory-check-no-grain` develops every frame with its grain and glare off (both drawn afresh at each size, they
//  would hide the scene's own detail in that comparison: AGENTS.md trap 1).
//
//  Writes `<dir>/report.json`. Everything memory is this process's `phys_footprint` (`MemoryProbe.footprint`,
//  the number `footprint -p` prints; never RSS, which cannot see the Metal pool), sampled every 10 ms on the
//  main actor, and the scheduler's own records of the same jobs (`openPeakFootprint − footprintBefore`, the
//  figure the DIAG's table is made of). The pictures are copied into `<dir>/work` first (a develop writes a
//  sidecar), and the scratch home holds the library, so every RAW opens with no proxy: a first open.
//
//  1. **Browse**: the copies opened in Develop on the first, and stepped through one by one as → does, each
//     page's develop waited for and the queue let settle before the next step.
//  2. **Inspect at full size**, two steps back from the last (←): its zoom's full render, then the neighbours the prefetch makes
//     (`MacRenderCache`), until the queue settles. The physical memory the prefetch is planned for is the
//     machine's, or `SPK_SIMULATE_RAM_GB` (a debug build's; `PrefetchPolicy`).
//  3. **A memory-pressure warning**, delivered where the operating system's is (`SchedulerSignals`): the
//     footprint and the engine's pool settled before and after.
//
//  **It runs only in a defaults suite of its own** (`--defaults-suite <name>`, as `tools/history_check.sh` launches
//  `MacHistoryCheck`; AGENTS.md trap 24). `CFFIXED_USER_HOME` moves the library, the caches and Application Support
//  into the scratch home, but `UserDefaults` goes through cfprefsd and stays in `~/Library/Preferences/<bundle
//  id>.plist` — a Debug build's `com.spektralab.mac.local`, shared with every other Debug build on the Mac (found
//  2026-11-13). The cost model's corrections (`scheduler.costCorrections.v1`) learn from every job, and the
//  settings it reads (the preview's size, lens correction) are the model's defaults: with a suite they are the
//  suite's, and the run starts from the suite's empty settings, not the person's. Without one it refuses, and
//  there is no flag to run it in the app's domain.
//
//  Not in a release build.

#if DEBUG
import Foundation
import ImageIO
import UIKit

@MainActor
enum MacMemoryCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--memory-check"), i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        guard let p = arguments.firstIndex(of: "--memory-check-pictures"), p + 1 < arguments.count else {
            print("memory-check: supply --memory-check-pictures <folder>; nothing was run")
            if arguments.contains("--memory-check-exit") { exit(2) }
            return
        }
        // The suite the launch keeps the model's settings in (`--defaults-suite`, read in `AppServices.launch`): the
        // model's own defaults must be it, never the app's domain, or nothing is run.
        guard arguments.contains("--defaults-suite"), model.defaults !== UserDefaults.standard else {
            print("memory-check: refused: pass --defaults-suite <name> (the scratch home does not hold UserDefaults, and this run writes the model's settings and the cost model's corrections); nothing was run")
            if arguments.contains("--memory-check-exit") { exit(2) }
            return
        }
        print("memory-check: settings in the defaults suite \(arguments[arguments.firstIndex(of: "--defaults-suite")! + 1])")
        let pictures = URL(fileURLWithPath: arguments[p + 1])
        let exits = arguments.contains("--memory-check-exit")
        let browseOnly = arguments.contains("--memory-check-browse-only"), keeps = arguments.contains("--memory-check-keep")
        let noGrain = arguments.contains("--memory-check-no-grain")
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            #if SPK_ENGINE
            let report = await run(model, out: out, pictures: pictures, browseOnly: browseOnly, keeps: keeps, noGrain: noGrain)
            #else
            let report: [String: Any] = ["failures": ["no engine in this build"]]
            #endif
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("memory-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    #if SPK_ENGINE
    private static func mb(_ b: UInt64) -> Double { (Double(b) / 1_048_576).rounded() }

    /// The footprint every 10 ms: the highest since `mark`, and the lowest of the last second (a settled reading).
    @MainActor private final class Sampler {
        private(set) var high: UInt64 = 0
        private var recent: [(Date, UInt64)] = []
        private var task: Task<Void, Never>?
        init() {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample()
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        func sample() {
            let f = MemoryProbe.footprint()
            high = max(high, f)
            let now = Date()
            recent.append((now, f))
            recent.removeAll { now.timeIntervalSince($0.0) > 1 }
        }
        func mark() { sample(); high = MemoryProbe.footprint() }
        var settled: UInt64 { recent.map(\.1).min() ?? MemoryProbe.footprint() }
        func stop() { task?.cancel() }
    }

    /// The kernel's own highest `phys_footprint` of this process's life (`ledger_phys_footprint_peak`): what a
    /// 10 ms sampler might miss, read beside it.
    private static func kernelPeak() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? UInt64(info.ledger_phys_footprint_peak) : 0
    }

    private static func until(_ seconds: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(ms))
        }
        return done()
    }

    /// Two seconds with the queue idle: the footprint has had its time to come back (it lags a release by up to ~2 s).
    private static func settle(_ scheduler: RenderQueue, _ sampler: Sampler) async {
        _ = await until(120) { scheduler.isIdle }
        try? await Task.sleep(for: .seconds(2.5))
        sampler.sample()
    }

    private static func record(_ r: JobRecord) -> [String: Any] {
        var out: [String: Any] = ["kind": r.kind, "tier": r.tier, "mp": (r.megapixels * 10).rounded() / 10, "outcome": r.outcome,
                                  "predicted_mb": mb(r.predictedPeakBytes), "budget_mb": mb(r.budgetBytes)]
        if let m = r.measuredPeakBytes { out["measured_peak_mb"] = mb(m) }
        if let m = r.measurement {
            out["open_added_mb"] = mb(m.openPeakFootprint > m.footprintBefore ? m.openPeakFootprint - m.footprintBefore : 0)
            out["peak_over_before_mb"] = mb(m.peakFootprint > m.footprintBefore ? m.peakFootprint - m.footprintBefore : 0)
            out["footprint_before_mb"] = mb(m.footprintBefore)
            out["decoded_by"] = m.decodedBy ?? ""
            out["decode_s"] = (m.decodeSeconds * 1000).rounded() / 1000
            out["pool_high_water_mb"] = mb(m.poolHighWater)
            out["lowest_headroom_mb"] = mb(m.lowestPhoneHeadroom)
            if let o = m.opened { out["opened"] = "\(o.width)x\(o.height)" }
        }
        return out
    }

    /// `url` copied into `folder` (made if need be) as `name`: what `--memory-check-keep` leaves for a look.
    private static func keep(_ url: URL?, in folder: URL, as name: String) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let to = folder.appending(path: name)
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.copyItem(at: url, to: to)
    }

    static func run(_ model: AppServices, out: URL, pictures: URL, browseOnly: Bool = false, keeps: Bool = false,
                    noGrain: Bool = false) async -> [String: Any] {
        var report: [String: Any] = [:]
        var failures: [String] = []
        let fm = FileManager.default
        let store = model.macLibrary
        let scheduler = model.scheduler
        let sampler = Sampler()
        defer { sampler.stop() }
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let rawExtensions: Set<String> = ["arw", "nef", "rw2", "orf", "raf", "dng", "cr3", "cr2"]
        let raws = ((try? fm.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? [])
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let card = work.appending(path: "Card")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for u in raws { try? fm.copyItem(at: u, to: card.appending(path: u.lastPathComponent)) }
        report["start"] = ["home": NSHomeDirectory(), "engine": model.darkroom.makesPictures, "frames_before": model.library.frames.count,
                           "physical_mb": mb(ProcessInfo.processInfo.physicalMemory), "pictures": raws.map(\.lastPathComponent),
                           "simulated_ram_gb": ProcessInfo.processInfo.environment["SPK_SIMULATE_RAM_GB"] ?? "",
                           "footprint_mb": mb(MemoryProbe.footprint())]
        guard model.darkroom.makesPictures, model.library.frames.isEmpty, raws.count >= 2 else {
            report["failures"] = ["a real engine, a fresh library and two RAWs at least (\(raws.count))"]
            return report
        }
        await store.start()
        do { _ = try await store.open(card) } catch { failures.append("the folder links: \(error.localizedDescription)") }
        await store.loadAll()
        let rows = raws.compactMap { u in store.images.first { $0.fileName == u.lastPathComponent } }
        guard rows.count == raws.count else {
            report["failures"] = failures + ["the folder lists its pictures (\(rows.count) of \(raws.count))"]
            return report
        }
        let made = (try? await store.frames(for: rows.map(\.id)).frames) ?? [:]
        let ids = rows.compactMap { made[$0.id] }
        guard ids.count == rows.count else {
            report["failures"] = failures + ["a frame for each picture (\(ids.count))"]
            return report
        }
        if noGrain {
            for id in ids { model.library.update(id) { $0.edit.params.grainActive = false; $0.edit.params.glareActive = false } }
        }
        await settle(scheduler, sampler)
        let proxiesBefore = model.originals.copies.proxies.count

        // ---- 1. Browse the fresh RAWs in Develop. ----
        let recordsBefore = Set(scheduler.records.map(\.jobID))
        let browseBase = sampler.settled
        sampler.mark()
        var perFrame: [[String: Any]] = []
        do { try await store.openInDevelop(rows.map(\.id), focus: rows[0].id) } catch { failures.append("Develop opens: \(error)") }
        for (k, id) in ids.enumerated() {
            if k > 0 { NotificationCenter.default.post(name: .spkCheckStep, object: 1) }
            let frameBase = sampler.settled
            let seenBefore = Set(scheduler.records.map(\.jobID))
            sampler.mark()
            let t0 = Date()
            let shown = await until(120) { model.openSession(id)?.developed != nil }
            let shownAfter = Date().timeIntervalSince(t0)
            _ = await until(120) { scheduler.isIdle }
            let high = sampler.high
            let jobs = scheduler.records.filter { !recordsBefore.contains($0.jobID) && !seenBefore.contains($0.jobID) }
            perFrame.append(["file": model.library.frame(id)?.fileName ?? "?", "shown": shown, "shown_s": (shownAfter * 100).rounded() / 100,
                             "footprint_before_mb": mb(frameBase), "peak_mb": mb(high), "peak_over_before_mb": mb(high > frameBase ? high - frameBase : 0),
                             "kernel_lifetime_peak_mb": mb(kernelPeak()),
                             "decode_edge": model.library.frame(id).map { $0.previewDevelopLongEdge($0.edit) } ?? 0,
                             "preview": model.library.frame(id).map { "\($0.previewSize.width)x\($0.previewSize.height)" } ?? "",
                             "developed": model.openSession(id)?.developed.map { "\($0.size.width)x\($0.size.height)" } ?? "",
                             "decode": model.library.frame(id).map { "\($0.edit.decode)" } ?? "",
                             "geometry_identity": model.library.frame(id)?.edit.geometry.isIdentity ?? true,
                             "jobs": jobs.map(record)])
            if !shown { failures.append("1: \(model.library.frame(id)?.fileName ?? "?") shows its develop") }
            if keeps, let image = model.openSession(id)?.developedCGImage {
                // The page's own picture, as drawn (a PNG: no second lossy pass over the kept HEIF's).
                let folder = out.appending(path: "developed")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = (model.library.frame(id)?.fileName ?? id.uuidString) + "-\(image.width)x\(image.height).png"
                if let dest = CGImageDestinationCreateWithURL(folder.appending(path: name) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
            try? await Task.sleep(for: .seconds(2.5))
            sampler.sample()
        }
        let browsePeak = sampler.high
        report["browse"] = ["footprint_before_mb": mb(browseBase), "frames": perFrame, "proxies_before": proxiesBefore,
                            "proxies_after": model.originals.copies.proxies.count]
        _ = browsePeak
        if browseOnly {
            report["failures"] = failures
            return report
        }

        // MEMCHECK-AFTER-BEGIN
        // The pool is the pressure step's to give back, not the idle spell's (`RenderQueue.idleTrimAfter`): step 4
        // shows the idle spell on its own.
        scheduler.idleTrimAfter = 600
        // MEMCHECK-AFTER-END
        // ---- 2. Two steps back (←, as a person going back would), and that frame inspected at full size; the
        // prefetch follows, the way the person is going first. ----
        let inspected = ids[max(ids.count - 3, 0)]
        for _ in 0..<min(2, ids.count - 1) {
            NotificationCenter.default.post(name: .spkCheckStep, object: -1)
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = await until(120) { model.openSession(inspected)?.developed != nil }
        await settle(scheduler, sampler)
        let cache = model.renderCache
        let eventsBefore = cache.events.count
        let fullRecordsBefore = Set(scheduler.records.map(\.jobID))
        let inspectBase = sampler.settled
        sampler.mark()
        let t0 = Date()
        report["inspected"] = model.library.frame(inspected)?.fileName ?? "?"
        if let s = model.openSession(inspected) {
            s.fullView.want()
            let ready = await until(300) { s.fullView.state == .ready || s.fullView.state == .failed }
            if !ready || s.fullView.state != .ready { failures.append("2: the inspected frame's full render is made (\(s.fullView.state))") }
            if keeps, let frame = model.library.frame(inspected), let made = FullRenderJobs.made(frame, darkroom: model.darkroom) {
                keep(made.ask.url, in: out.appending(path: "full"), as: frame.fileName + FullRender.suffix)
            }
        } else { failures.append("2: the inspected frame's page is open") }
        // The prefetch: until nothing is under way and the queue is idle for 3 s (or two minutes).
        var quietSince: Date?
        let end = Date().addingTimeInterval(240)
        while Date() < end {
            if cache.prefetch == nil, scheduler.isIdle {
                if quietSince == nil { quietSince = Date() }
                if Date().timeIntervalSince(quietSince!) > 3 { break }
            } else { quietSince = nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let inspectHigh = sampler.high
        let events = cache.events.dropFirst(eventsBefore).map { e -> [String: Any] in
            ["what": e.what, "frame": e.frame.flatMap { model.library.frame($0)?.fileName } ?? "", "after_s": ((e.at.timeIntervalSince(t0)) * 100).rounded() / 100]
        }
        let fullJobs = scheduler.records.filter { !fullRecordsBefore.contains($0.jobID) }
        report["inspect"] = ["footprint_before_mb": mb(inspectBase), "peak_mb": mb(inspectHigh), "kernel_lifetime_peak_mb": mb(kernelPeak()),
                             "peak_over_before_mb": mb(inspectHigh > inspectBase ? inspectHigh - inspectBase : 0),
                             "seconds": (Date().timeIntervalSince(t0) * 10).rounded() / 10,
                             "prefetch_submitted": cache.events.dropFirst(eventsBefore).filter { $0.what == "prefetch submitted" }.count,
                             "events": Array(events), "jobs": fullJobs.map(record)]

        // ---- 3. A memory-pressure warning, settled before and after. ----
        await settle(scheduler, sampler)
        let heldBefore = await scheduler.engine.heldBytes()
        let pressureBase = sampler.settled
        var pressure: [String: Any] = ["footprint_before_mb": mb(pressureBase), "engine_held_before_mb": mb(heldBefore)]
        // MEMCHECK-AFTER-BEGIN
        pressure["caches_before"] = MemoryRelease.counts()
        model.signals?.deliver(.warning)
        // MEMCHECK-AFTER-END
        // MEMCHECK-BEFORE-LINE model.scheduler.memoryPressure(.warning)
        try? await Task.sleep(for: .seconds(3))
        sampler.sample()
        try? await Task.sleep(for: .seconds(1.1))
        let heldAfter = await scheduler.engine.heldBytes()
        pressure["footprint_after_mb"] = mb(sampler.settled)
        pressure["engine_held_after_mb"] = mb(heldAfter)
        // MEMCHECK-AFTER-BEGIN
        pressure["caches_after"] = MemoryRelease.counts()
        // MEMCHECK-AFTER-END
        report["pressure"] = pressure

        // ---- 4. The queue idle after a develop: what the engine still holds 7 s on. ----
        // MEMCHECK-AFTER-BEGIN
        scheduler.idleTrimAfter = 5
        // MEMCHECK-AFTER-END
        NotificationCenter.default.post(name: .spkCheckStep, object: 1)
        _ = await until(60) { scheduler.isIdle && model.openSession(ids[min(ids.count - 2, ids.count - 1)])?.developed != nil }
        _ = await until(60) { scheduler.isIdle }
        try? await Task.sleep(for: .seconds(1))
        let idleHeldBefore = await scheduler.engine.heldBytes()
        let idleBase = sampler.settled
        try? await Task.sleep(for: .seconds(7))
        sampler.sample()
        try? await Task.sleep(for: .seconds(1.1))
        report["idle"] = ["engine_held_1s_mb": mb(idleHeldBefore), "engine_held_8s_mb": mb(await scheduler.engine.heldBytes()),
                          "footprint_1s_mb": mb(idleBase), "footprint_8s_mb": mb(sampler.settled)]
        report["failures"] = failures
        return report
    }
    #endif
}
#endif
