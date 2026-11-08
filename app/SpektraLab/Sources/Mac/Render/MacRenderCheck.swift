//  MacRenderCheck.swift — a debug build's proof, in the running app, of what the Mac renders and what it keeps.
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --render-check <dir> [--render-check-exit]
//          [--render-check-pictures <folder> …] [--render-check-volume <folder>]
//      CFFIXED_USER_HOME=<same>/home  SpektraLab --render-check <dir2> --render-check-relaunch <dir> [--render-check-exit]
//
//  Writes `<dir>/report.json`, every step timed. What is counted is read from the scheduler itself — its
//  jobs as it shows them (`snapshots`, sampled every 10 ms) and its records (`records`) — never from a
//  counter kept beside it. Pictures are read where they are or copied into `<dir>/work`; the scratch home
//  holds the library. The steps (the brief of 2026-10-24):
//
//  1. **Export with no frames**: five RAWs a Finder folder holds, exported (JPEG, 2,048 px) through the
//     Mac's export run: the five frames are made, and **no `importDevelop` job** is seen, only the five
//     exports. Then the control: one `model.develop` asked by hand must be seen, or the watch is blind.
//  2. **Frames for a few hundred pictures, by reference** (an external fixture folder, 200 of them): no job
//     of any kind; their tiles fall back to the file's own preview (`ThumbnailStore`).
//  3. **Develop**: the five, in a strip, opened on the first; its zoom makes its full render (a `fullView`
//     job); the neighbours are made after it, one at a time, as `importDevelop` jobs at the full tier
//     (priority 5 against the page's 3); a step to a made one reuses it with no job; a prefetch held behind
//     an export and not started is cancelled by the next step; a frame not made is made when zoomed.
//  5. **The Light Table** (before 4, which trims the renders): a film whose kept develop is large enough
//     reads it, no job; a film shown larger than its kept develop reads its full render, no job; a film
//     with nothing kept makes exactly one job, wearing the ring meanwhile; a 5,000 px A6 contact sheet
//     reads a 6 × 17 strip at no less than its pixel size (the ceiling, `LightTableSizing.sourceCeiling`).
//  6. **A memory warning** on the table zoomed in on one film: the films out of view let go of their
//     textures, the one in view keeps its own; the app's footprint before and after.
//  4. **The renders' limit** (`setFullRenderCacheLimit`): lowered, the renders used longest ago go first,
//     by bytes, until under it, at once; the current frame's never; the order is written for the relaunch.
//  R. **The relaunch** (`--render-check-relaunch <dir>`): the renders and their order as the first run left
//     them, and no develop queued at launch for the 200 frames and more that have none.
//
//  Not in a release build.

#if DEBUG
import Foundation
import ImageIO
import UIKit

extension Notification.Name {
    /// A step along the develop page's strip (`DevelopWindowContent`), as ← → are: `object` the step.
    static let spkCheckStep = Notification.Name("spk.check.step")
}

@MainActor
enum MacRenderCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--render-check"), i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        func value(_ flag: String) -> String? {
            guard let j = arguments.firstIndex(of: flag), j + 1 < arguments.count else { return nil }
            return arguments[j + 1]
        }
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--render-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        if pictures.isEmpty {
            guard let root = ProcessInfo.processInfo.environment["SPK_TEST_IMAGES"], !root.isEmpty else {
                print("render-check: supply --render-check-pictures or SPK_TEST_IMAGES; no fixtures were run")
                if arguments.contains("--render-check-exit") { exit(2) }
                return
            }
            pictures = [URL(fileURLWithPath: root + "/Nikon Z7ii"), URL(fileURLWithPath: root + "/A7m3")]
        }
        let relaunch = value("--render-check-relaunch").map { URL(fileURLWithPath: $0) }
        let volumePath = value("--render-check-volume") ?? ProcessInfo.processInfo.environment["SPK_TEST_DISK"]
        guard relaunch != nil || volumePath?.isEmpty == false else {
            print("render-check: supply --render-check-volume or SPK_TEST_DISK; no fixtures were run")
            if arguments.contains("--render-check-exit") { exit(2) }
            return
        }
        let volume = URL(fileURLWithPath: volumePath ?? out.path)
        let exits = arguments.contains("--render-check-exit")
        setvbuf(stdout, nil, _IOLBF, 0)        // each line as it is printed, for whoever watches the log
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            #if SPK_ENGINE
            let report: [String: Any]
            if let relaunch { report = await runRelaunch(model, out: out, previous: relaunch) }
            else { report = await run(model, out: out, pictures: pictures, volume: volume) }
            #else
            let report: [String: Any] = ["failures": ["this build has no engine"]]
            #endif
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("render-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    #if SPK_ENGINE
    // MARK: - the report

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var checks = 0
        func step(_ name: String, _ ms: Double, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            s["ms"] = (ms * 10).rounded() / 10
            steps.append(s)
            print("render-check: \(name) \(Int(ms)) ms \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what); print("render-check: FAIL \(what)") } else { print("render-check: ok \(what)") }
        }
        var json: [String: Any] { ["steps": steps, "failures": failures, "checks": checks] }
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

    private static func mb(_ b: Int64) -> Double { (Double(b) / 1_048_576 * 10).rounded() / 10 }
    private static func mb(_ b: Int) -> Double { mb(Int64(b)) }
    private static func mb(_ b: UInt64) -> Double { mb(Int64(b)) }

    /// The scheduler's jobs as it shows them, sampled every 10 ms, and its records as they come: every
    /// job seen, by its id, with its kind, tier and frame, and how each one ended where a record says.
    @MainActor private final class JobWatch {
        struct Seen { var kind: JobKind; var tier: RenderTier; var frame: UUID; var first: Date; var running = false; var outcome: String? }
        private(set) var jobs: [UUID: Seen] = [:]
        private(set) var order: [UUID] = []
        private var task: Task<Void, Never>?
        private var recordsBefore: Set<UUID>

        init(_ scheduler: RenderQueue) {
            recordsBefore = Set(scheduler.records.map(\.jobID))
            task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.sample(scheduler)
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }

        func sample(_ scheduler: RenderQueue) {
            for s in scheduler.snapshots {
                if jobs[s.id] == nil {
                    jobs[s.id] = Seen(kind: s.job.kind, tier: s.job.tier, frame: s.job.frameID, first: Date())
                    order.append(s.id)
                }
                if case .running = s.state { jobs[s.id]?.running = true }
            }
            for r in scheduler.records where !recordsBefore.contains(r.jobID) {
                if jobs[r.jobID] == nil, let kind = JobKind(rawValue: r.kind), let tier = RenderTier(rawValue: r.tier) {
                    jobs[r.jobID] = Seen(kind: kind, tier: tier, frame: UUID(), first: r.at)
                    order.append(r.jobID)
                }
                jobs[r.jobID]?.outcome = r.outcome
                jobs[r.jobID]?.running = true          // a record is made only for a job that started
            }
        }

        func stop(_ scheduler: RenderQueue) { sample(scheduler); task?.cancel() }
        func count(_ kind: JobKind) -> Int { jobs.values.filter { $0.kind == kind }.count }
        func of(_ frame: UUID) -> [Seen] { order.compactMap { jobs[$0] }.filter { $0.frame == frame } }
        var kinds: [String: Int] { Dictionary(grouping: jobs.values, by: { $0.kind.rawValue }).mapValues(\.count) }
        var facts: [[String: Any]] {
            order.compactMap { id in jobs[id].map { ["kind": $0.kind.rawValue, "tier": $0.tier.rawValue, "ran": $0.running, "outcome": $0.outcome ?? "-"] } }
        }
    }

    private struct Kept { let name: String; let frame: UUID?; let bytes: Int64; let used: Date }

    /// The renders' book as it stands: each render's name, frame, bytes and when it was last used, oldest first.
    private static func book(_ model: AppServices) -> [Kept] {
        model.originals.copies.fulls.map { Kept(name: $0.key, frame: WorkingCopies.proxyFrame($0.key), bytes: $0.value.bytes, used: $0.value.used) }
            .sorted { $0.used != $1.used ? $0.used < $1.used : $0.name < $1.name }
    }

    private static func name(_ model: AppServices, _ id: UUID) -> String { model.library.frame(id)?.fileName ?? id.uuidString }
    private static func describe(_ s: [JobWatch.Seen]) -> [String] { s.map { "\($0.kind.rawValue) \($0.tier.rawValue) \($0.outcome ?? "")" } }

    // MARK: - the run

    static func run(_ model: AppServices, out: URL, pictures: [URL], volume: URL) async -> [String: Any] {
        let r = Report()
        let fm = FileManager.default
        let store = model.macLibrary
        let scheduler = model.scheduler
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        r.step("start", 0, ["home": NSHomeDirectory(), "engine": model.darkroom.makesPictures, "frames": model.library.frames.count,
                            "full_limit_mb": mb(model.originals.copies.fullLimit), "ceiling_px": LightTableSizing.sourceCeiling])
        r.check(model.darkroom.makesPictures, "a real engine (not the simulation)")
        r.check(model.library.frames.isEmpty, "a fresh library in the scratch home (\(model.library.frames.count) frames)")
        r.check(LightTableSteps.steps.last == LightTableSizing.sourceCeiling, "the table's top step is the ceiling (\(LightTableSteps.steps))")

        // The pictures: three Z 7II NEFs (45 MP) and two α7 III ARWs (24 MP), copied into a scratch folder.
        let raws = pictures.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["nef", "arw"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let nefs = raws.filter { $0.pathExtension.lowercased() == "nef" }, arws = raws.filter { $0.pathExtension.lowercased() == "arw" }
        guard nefs.count >= 3, arws.count >= 2 else {
            r.check(false, "three NEFs and two ARWs (found \(nefs.count) and \(arws.count))")
            return r.json
        }
        let chosen = [nefs[0], arws[0], nefs[1], arws[1], nefs[2]]
        let card = work.appending(path: "Card")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for u in chosen { try? fm.copyItem(at: u, to: card.appending(path: u.lastPathComponent)) }

        await store.start()
        do { _ = try await store.open(card) } catch { r.check(false, "the scratch folder links: \(error.localizedDescription)") }
        await store.loadAll()
        let rows = chosen.compactMap { u in store.images.first { $0.fileName == u.lastPathComponent } }
        r.check(rows.count == 5, "the folder lists its five pictures (\(rows.count))")
        guard rows.count == 5 else { return r.json }

        // ---- 1. Export five pictures that had no frame. ----
        var t0 = ContinuousClock.now
        let watch1 = JobWatch(scheduler)
        let made: [MacImage.ID: LibraryFrame.ID]
        do { made = try await store.frames(for: rows.map(\.id)).frames } catch {
            r.check(false, "1: frames made for the five: \(error.localizedDescription)")
            return r.json
        }
        let ids = rows.compactMap { made[$0.id] }
        r.check(ids.count == 5, "1: the five pictures are made frames (\(ids.count))")
        guard ids.count == 5 else { return r.json }
        var recipe = ExportRecipe(format: .jpeg, size: .longEdge(2048), colour: .displayP3, destination: .files)
        recipe.quality = 85
        let folder1 = out.appending(path: "exports-1")
        try? fm.removeItem(at: folder1)
        try? fm.createDirectory(at: folder1, withIntermediateDirectories: true)
        let run = MacExportRun.shared
        run.reset()
        let started = run.start(ids, recipe: recipe, folder: folder1, exporter: model.exporter)
        r.check(started, "1: the export run starts")
        _ = await until(600, every: 20) { !run.isRunning }
        try? await Task.sleep(for: .milliseconds(300))
        watch1.stop(scheduler)
        let files1 = ((try? fm.contentsOfDirectory(atPath: folder1.path)) ?? []).filter { $0.hasSuffix(".jpg") }
        r.step("1: export five pictures with no frame", ms(since: t0), [
            "frames_made": ids.count, "files": files1.sorted(), "jobs_by_kind": watch1.kinds, "jobs": watch1.facts,
        ])
        r.check(watch1.count(.importDevelop) == 0, "1: no importDevelop job queued by making five frames and exporting them (\(watch1.count(.importDevelop)))")
        r.check(watch1.count(.export) == 5, "1: the five exports (\(watch1.count(.export)))")
        r.check(watch1.jobs.values.allSatisfy { $0.kind == .export }, "1: no job but the exports (\(watch1.kinds))")
        r.check(files1.count == 5, "1: five files written (\(files1.count))")
        r.check(ids.allSatisfy { model.library.frame($0)?.developed == nil }, "1: none of the five has a kept develop")
        // The control: a develop asked by hand is seen, so the watch can see one.
        let control = JobWatch(scheduler)
        model.develop(ids[4])
        _ = await until(60) { scheduler.isIdle && model.library.frame(ids[4])?.developed != nil }
        control.stop(scheduler)
        r.step("1: control, one develop asked by hand", 0, ["jobs_by_kind": control.kinds])
        r.check(control.count(.importDevelop) == 1, "1: control: the one develop asked is seen (\(control.count(.importDevelop)))")
        r.check(model.library.frame(ids[4])?.developed != nil, "1: control: it is kept as the frame's develop")
        model.library.update(ids[4]) { $0.developed = nil }   // E has nothing kept again (its picture file stays until the sweep)

        // ---- 2. Frames for 200 pictures, by reference. ----
        if fm.fileExists(atPath: volume.path) {
            t0 = ContinuousClock.now
            do { _ = try await store.open(volume) } catch { r.check(false, "2: \(volume.path) links: \(error.localizedDescription)") }
            await store.loadAll()
            let some = Array(store.images.filter { !$0.isOffline }.prefix(200))
            let opened = ms(since: t0)
            t0 = ContinuousClock.now
            let watch2 = JobWatch(scheduler)
            let made2 = (try? await store.frames(for: some.map(\.id)).frames) ?? [:]
            try? await Task.sleep(for: .seconds(2))
            watch2.stop(scheduler)
            let volumeFrames = some.compactMap { made2[$0.id] }
            // Their tiles: the file's own preview, read as a tile reads it.
            var fallbacks: [[String: Any]] = []
            for id in volumeFrames.prefix(5) {
                guard let f = model.library.frame(id) else { continue }
                let image = await ThumbnailStore.shared.image(f.picture, maxPixel: 256)
                fallbacks.append(["file": f.fileName, "developed": f.developed != nil, "picture_is_the_file": f.picture.fileURL?.path.hasPrefix(volume.path) ?? false,
                                  "tile_px": image.map { [Int($0.size.width * $0.scale), Int($0.size.height * $0.scale)] } ?? []])
            }
            r.step("2: frames made for 200 pictures by reference", ms(since: t0), [
                "volume": volume.path, "listed": store.images.count, "link_ms": (opened * 10).rounded() / 10, "frames_made": volumeFrames.count,
                "jobs_by_kind": watch2.kinds, "tiles": fallbacks,
            ])
            r.check(volumeFrames.count >= 190, "2: about 200 frames made (\(volumeFrames.count))")
            r.check(watch2.jobs.isEmpty, "2: no job of any kind queued for them (\(watch2.kinds))")
            r.check(fallbacks.count == 5 && fallbacks.allSatisfy { ($0["tile_px"] as? [Int])?.isEmpty == false && $0["developed"] as? Bool == false
                                                                    && $0["picture_is_the_file"] as? Bool == true },
                    "2: their tiles are the file's own preview, none developed")
        } else {
            r.step("2: skipped", 0, ["volume": volume.path, "why": "not mounted"])
            r.check(false, "2: \(volume.path) is there to read")
        }

        // ---- 3. Develop: the page's render, the neighbours made ahead, a step that reuses one. ----
        // A 6 × 9 strip on each (so the Light Table takes them later); the edit is the library's, no develop asked.
        // The store carries the rows of the source it shows: the folder of the five again.
        do { _ = try await store.open(card) } catch { r.check(false, "3: the scratch folder shows again: \(error.localizedDescription)") }
        await store.loadAll()
        for id in ids { model.library.update(id) { $0.edit.filmEdge.active = true; $0.edit.filmEdge.format = .f6x9; $0.edit.filmEdge.mode = .strip } }
        model.originals.copies.clear()
        let cache = model.renderCache
        let watch3 = JobWatch(scheduler)
        t0 = ContinuousClock.now
        // The strip is the first four: E stays out of it, so nothing makes E's render ahead of the Light Table (5).
        do { try await store.openInDevelop(Array(rows.prefix(4)).map(\.id), focus: rows[0].id) } catch { r.check(false, "3: Develop opens: \(error)") }
        let a = ids[0], b = ids[1], c = ids[2], d = ids[3], e = ids[4]
        let pageA = await until(90) { model.openSession(a)?.developed != nil }
        r.check(pageA, "3: the develop page opens on the first and shows its develop")
        guard let sessionA = model.openSession(a) else { return r.json }
        sessionA.fullView.want()                                    // the canvas zoomed past its preview
        let readyA = await until(300) { sessionA.fullView.state == .ready || sessionA.fullView.state == .failed }
        let aReadyAt = Date()
        r.check(readyA && sessionA.fullView.state == .ready, "3: zoomed, the first frame's full render is made (\(sessionA.fullView.state))")
        watch3.sample(scheduler)
        r.step("3: the first frame zoomed", ms(since: t0), ["frame": name(model, a), "jobs": describe(watch3.of(a))])
        r.check(watch3.of(a).filter { $0.kind == .fullView }.count == 1, "3: by one fullView job (\(describe(watch3.of(a))))")
        // The neighbours, after it, below it, one at a time: B then C (A is first in the strip).
        let anyAhead = await until(30) { cache.events.contains { $0.what == "prefetch submitted" } }
        guard anyAhead else {
            r.check(false, "3: a prefetch is submitted once the first frame's render is here")
            r.step("3: no prefetch", ms(since: t0), ["events": cache.events.map { ["what": $0.what, "frame": $0.frame.map { name(model, $0) } ?? ""] },
                                                    "current": cache.current.map { name(model, $0) } ?? "none", "inspecting": cache.inspecting,
                                                    "diagnosis": cache.diagnosis()])
            return r.json
        }
        let prefetchedB = await until(300) { cache.events.contains { $0.what == "prefetch made" && $0.frame == b } }
        let prefetchedC = await until(300) { cache.events.contains { $0.what == "prefetch made" && $0.frame == c } }
        watch3.sample(scheduler)
        let submitted = cache.events.filter { $0.what == "prefetch submitted" }
        let jobB = watch3.of(b), jobC = watch3.of(c)
        r.step("3: the neighbours made ahead", ms(since: t0), [
            "events": cache.events.map { ["what": $0.what, "frame": $0.frame.map { name(model, $0) } ?? "", "after_s": (($0.at.timeIntervalSince(aReadyAt)) * 1000).rounded() / 1000] },
            "b_jobs": describe(jobB), "c_jobs": describe(jobC),
        ])
        r.check(prefetchedB && prefetchedC, "3: the two neighbours' full renders are made ahead (\(prefetchedB), \(prefetchedC))")
        r.check(submitted.first?.frame == b && submitted.dropFirst().first?.frame == c, "3: nearest first: B, then C")
        r.check(submitted.allSatisfy { $0.at >= aReadyAt.addingTimeInterval(-0.1) }, "3: no prefetch before the current frame's own render was here")
        r.check(!jobB.isEmpty && jobB.allSatisfy { $0.kind == .importDevelop && $0.tier == .full },
                "3: a prefetch is an importDevelop at the full tier (\(describe(jobB)))")
        r.check(JobKind.importDevelop.priority > JobKind.fullView.priority,
                "3: below the page's own render (priority \(JobKind.importDevelop.priority) against \(JobKind.fullView.priority))")
        let spans = submitted.compactMap { ev in ev.job.flatMap { j in cache.events.first { $0.job == j && $0.what.hasPrefix("prefetch made") }.map { (ev.at, $0.at) } } }
        r.check(spans.count >= 2 && zip(spans, spans.dropFirst()).allSatisfy { $0.1 <= $1.0 }, "3: one at a time: each submitted after the last was made")

        // A step to B: its render is here, so the zoom runs no job.
        t0 = ContinuousClock.now
        let watchStep = JobWatch(scheduler)
        let run3 = MacExportRun.shared
        run3.reset()
        let folder3 = out.appending(path: "exports-3")
        try? fm.removeItem(at: folder3); try? fm.createDirectory(at: folder3, withIntermediateDirectories: true)
        let tiff = ExportRecipe(format: .tiff, size: .full, colour: .proPhoto, destination: .files)
        NotificationCenter.default.post(name: .spkCheckStep, object: 1)
        let pageB = await until(90) { model.openSession(b)?.developed != nil && !scheduler.snapshots.contains { $0.job.kind.isCanvas } }
        r.check(pageB, "3: a step to the next frame opens its page")
        // Hold the queue with an export of E (nothing of it kept), so the prefetch B's zoom brings waits.
        _ = run3.start([e], recipe: tiff, folder: folder3, exporter: model.exporter)
        _ = await until(30) { scheduler.snapshots.contains { $0.job.kind == .export } }
        let jobsBefore = watchStep.of(b).filter { $0.tier == .full }.count
        model.openSession(b)?.fullView.want()
        let readyB = await until(10) { model.openSession(b)?.fullView.state == .ready }
        try? await Task.sleep(for: .milliseconds(300))
        watchStep.sample(scheduler)
        r.check(readyB, "3: on the next frame the zoom shows its kept render (\(String(describing: model.openSession(b)?.fullView.state)))")
        r.check(watchStep.of(b).filter { $0.tier == .full }.count == jobsBefore, "3: with no job of its own (\(describe(watchStep.of(b))))")
        // The prefetch the zoom brings (D, +2: C and A are kept) is queued behind the export, not started.
        let queuedD = await until(10) { cache.prefetch?.frame == d }
        let jobD = cache.prefetch?.job
        let dWaiting = jobD.map { j in scheduler.snapshots.first { $0.id == j }.map { s in if case .running = s.state { false } else { true } } ?? false } ?? false
        r.check(queuedD && dWaiting, "3: the next prefetch (D) waits behind the export (\(queuedD), \(dWaiting))")
        // Moving on before it started: it goes.
        NotificationCenter.default.post(name: .spkCheckStep, object: 1)
        let pageC = await until(90) { model.openSession(c)?.developed != nil }
        r.check(pageC, "3: a step to C opens its page")
        watchStep.sample(scheduler)
        let dCancelled = cache.events.contains { $0.job == jobD && $0.what.hasPrefix("prefetch cancelled") }
        let dRan = jobD.flatMap { watchStep.jobs[$0]?.running } ?? false
        r.check(dCancelled && !dRan, "3: moving on cancels the prefetch that had not started (cancelled \(dCancelled), ran \(dRan))")
        // C was made ahead: its zoom runs nothing.
        model.openSession(c)?.fullView.want()
        let readyC = await until(10) { model.openSession(c)?.fullView.state == .ready }
        watchStep.sample(scheduler)
        r.check(readyC && watchStep.of(c).filter { $0.kind == .fullView }.isEmpty, "3: C's zoom reuses its kept render, no job")
        _ = await until(600) { !run3.isRunning }
        // D: asked again ahead from C (its first prefetch went), or made by its own page when zoomed.
        NotificationCenter.default.post(name: .spkCheckStep, object: 1)
        _ = await until(90) { model.openSession(d)?.developed != nil }
        model.openSession(d)?.fullView.want()
        let readyD = await until(300) { model.openSession(d)?.fullView.state == .ready }
        watchStep.stop(scheduler)
        r.check(readyD, "3: D's full render is there when zoomed (\(describe(watchStep.of(d))))")
        r.check(watchStep.of(d).filter { $0.tier == .full && $0.outcome?.hasPrefix("done") == true }.count == 1, "3: D's render was made once (\(describe(watchStep.of(d))))")
        r.step("3: steps through the strip", ms(since: t0), ["jobs": watchStep.facts,
            "book": book(model).map { ["file": $0.frame.map { name(model, $0) } ?? "?", "mb": mb($0.bytes)] },
            "events": cache.events.map { ["what": $0.what, "frame": $0.frame.map { name(model, $0) } ?? ""] }])
        let afterD = await until(300) { cache.prefetch == nil && scheduler.isIdle }
        r.check(afterD, "3: the queue settles")
        watch3.stop(scheduler)

        // ---- 5. The Light Table. ----
        // E is laid as a 6 × 17 strip: the largest film any format makes.
        model.library.update(e) { $0.edit.filmEdge.format = .f6x17 }
        t0 = ContinuousClock.now
        let watch5 = JobWatch(scheduler)
        let tableRows = [rows[0], rows[3], rows[4]]          // A (its kept develop and render), D (the same), E (nothing)
        do { try await store.putOnLightTable(tableRows.map(\.id)) } catch { r.check(false, "5: the Light Table takes the three: \(error)") }
        let opened = await until(30) { LightTableCheckHook.table?.model.pile.count == 3 }
        r.check(opened, "5: the table opens with the three films")
        guard let table = LightTableCheckHook.table else { return r.json }
        _ = await until(20) { table.textureFacts(a).from != nil }
        r.check(model.library.frame(a)?.developed != nil, "5: A has its kept develop (its page left it behind)")
        let factsA = table.textureFacts(a)
        watch5.sample(scheduler)
        r.check(factsA.from == "kept develop" && watch5.of(a).isEmpty, "5 (1): A's kept develop is large enough: read, no job (\(factsA.from ?? "nothing"), \(watch5.of(a).count) jobs)")
        // E, with nothing kept: exactly one job, the ring meanwhile.
        let ringed = await until(30, every: 20) { table.making[e] != nil }
        let doneE = await until(300) { table.textureFacts(e).from == "full render" }
        try? await Task.sleep(for: .seconds(1))
        table.requestTextures()
        try? await Task.sleep(for: .seconds(1))
        watch5.sample(scheduler)
        let jobsE = watch5.of(e)
        r.check(ringed, "5 (3): E wears the develop ring while its render is made")
        r.check(jobsE.count == 1 && jobsE.first?.kind == .fullView, "5 (3): E, cached nowhere, makes exactly one job (\(describe(jobsE)))")
        r.check(doneE, "5 (3): then E is read from its render (\(table.textureFacts(e).from ?? "nothing"))")
        r.check(table.making.isEmpty, "5 (3): the ring comes off")
        // A shown larger than its kept develop: read from its render, no job. Zoomed all the way in on A.
        let watch5b = JobWatch(scheduler)
        if let box = table.screenBox(a) { table.zoom(to: LightTable.zoomMax, around: CGPoint(x: box.midX, y: box.midY)) }
        try? await Task.sleep(for: .milliseconds(800))
        table.requestTextures()
        let fullA = await until(60) { table.textureFacts(a).from == "full render" && table.texturesSettled }
        watch5b.stop(scheduler)
        let factsA2 = table.textureFacts(a)
        let keptA = model.library.frame(a)?.developed?.size.longEdge ?? 0
        r.check(fullA && watch5b.jobs.isEmpty, "5 (2): A shown past its kept develop reads its render, no job (\(factsA2.from ?? "nothing") at \(factsA2.edge ?? 0) px, \(watch5b.kinds))")
        r.check((factsA2.edge ?? 0) > keptA, "5 (2): at a step past the kept develop's \(keptA) px (\(factsA2.edge ?? 0))")
        r.step("5: the Light Table's three films", ms(since: t0), [
            "A": ["fitted": factsA.from ?? "", "fitted_step": factsA.edge ?? 0, "zoomed": factsA2.from ?? "", "zoomed_step": factsA2.edge ?? 0,
                  "texture_px": factsA2.width ?? 0, "kept_develop_px": keptA],
            "E_jobs": describe(jobsE), "jobs_by_kind": watch5.kinds,
        ])

        // ---- 6. A memory warning, zoomed in on A: the films out of view go, A stays. ----
        try? await Task.sleep(for: .seconds(1))
        let before = table.textureFilms
        let footprintBefore = MemoryProbe.footprint()
        let bytesBefore = table.textureBytes.now
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try? await Task.sleep(for: .seconds(2.5))
        let after = table.textureFilms
        let footprintAfter = MemoryProbe.footprint()
        let bytesAfter = table.textureBytes.now
        r.step("6: a memory warning", 0, [
            "visible": before.visible.map { name(model, $0) }, "held_before": before.held.map { name(model, $0) }, "held_after": after.held.map { name(model, $0) },
            "texture_mb_before": mb(bytesBefore), "texture_mb_after": mb(bytesAfter),
            "footprint_mb_before": mb(footprintBefore), "footprint_mb_after": mb(footprintAfter),
        ])
        r.check(before.held.count > after.held.count, "6: textures of films out of view are let go of (\(before.held.count) → \(after.held.count))")
        r.check(!before.visible.isEmpty && before.visible.isSubset(of: after.held), "6: the films in view keep theirs")
        r.check(bytesAfter < bytesBefore, "6: the table holds less (\(mb(bytesBefore)) → \(mb(bytesAfter)) MB)")

        // ---- 5. (end) A 5,000 px contact sheet on A6, E a 6 × 17 strip. ----
        table.fit()
        _ = table.setTable(paper: .a6, portrait: false)
        try? await Task.sleep(for: .milliseconds(800))
        var choice = LightTableExportChoice()
        choice.kind = .contactSheet
        choice.style = .layoutOnly
        choice.format = .jpg
        choice.shortEdge = LightTableExportPlan.shortEdges.upperBound
        t0 = ContinuousClock.now
        let watch5c = JobWatch(scheduler)
        let sheet = LightTableExportPlan.sheet(half: table.model.half, style: choice.style, shortEdge: choice.shortEdge)
        let itemE = table.model.item(e)
        let needE = itemE.map { max($0.w, $0.h) * sheet.k } ?? 0
        let exported = try? await LightTableExport.run(choice, table: table, cancel: LightTableExportCancel(), progress: { _ in })
        watch5c.stop(scheduler)
        let pile = table.model.pile.map(\.id)
        let reads = exported?.report?.filmReads ?? []
        let readE = pile.firstIndex(of: e).flatMap { reads.indices.contains($0) ? reads[$0] : nil }
        let ceiling = LightTableSizing.sourceCeiling
        // Never enlarged: a film is read at most at its render's own size.
        let ownE = model.library.frame(e).flatMap { cache.fullRef($0)?.longEdge } ?? 0
        let wantE = min(Int(needE.rounded(.down)), ownE)
        let expected = Int((LightTableSizing.largestFilmMM * Double(LightTableExportPlan.shortEdges.upperBound) / 105).rounded(.up))
        r.step("5: a 5,000 px A6 contact sheet", ms(since: t0), [
            "sheet": [sheet.width, sheet.height], "px_per_mm": (sheet.k * 100).rounded() / 100, "E_mm": itemE.map { [$0.w, $0.h] } ?? [],
            "E_needs_px": needE.rounded(), "E_render_px": ownE, "E_read": readE.map { ["px": $0.edge, "from": $0.from] as [String: Any] } ?? [:],
            "reads": zip(pile, reads).map { ["film": name(model, $0.0), "px": $0.1.edge, "from": $0.1.from] as [String: Any] },
            "ceiling_px": ceiling, "largest_film_mm": LightTableSizing.largestFilmMM, "jobs_by_kind": watch5c.kinds,
            "file": exported?.url.lastPathComponent ?? "none", "footprint_peak_mb": exported?.report.map { mb($0.footprintPeak) } ?? 0,
            "texture_peak_mb": exported?.report.map { mb($0.texturePeak) } ?? 0,
        ])
        r.check(ceiling == expected && ceiling == 8224, "5: the ceiling is the 6 × 17 strip on A6 at 5,000 px (\(ceiling); 172.7 mm × 5,000 / 105 = \(expected))")
        r.check(abs(Double(sheet.k) - 5000.0 / 105) < 0.01, "5: the sheet is 5,000 px on A6's short side (\(sheet.k) px a mm)")
        r.check(needE > 8000 && needE <= Double(ceiling), "5: E, a 6 × 17 strip, is \(Int(needE)) px long in the file: under the ceiling")
        r.check(ownE > 0 && (readE?.edge ?? 0) >= wantE,
                "5: E is read at no less than its size in the file, or its render's own where that is smaller (\(readE?.edge ?? 0) for \(Int(needE)), render \(ownE))")
        r.check(readE?.from == "full render", "5: E is read from its full render")
        model.router.back()
        try? await Task.sleep(for: .seconds(1))

        // ---- 4. The renders' limit. ----
        // Back in Develop on D, which is then pinned.
        do { try await store.openInDevelop(rows.map(\.id), focus: rows[3].id) } catch { r.check(false, "4: Develop opens on D: \(error)") }
        _ = await until(90) { model.openSession(d)?.developed != nil }
        model.openSession(d)?.fullView.want()
        _ = await until(60) { model.openSession(d)?.fullView.state == .ready }
        _ = await until(300) { scheduler.isIdle && cache.prefetch == nil }
        let pinned = model.openSession(d)?.fullView.pinnedName
        let full = book(model)
        let total = full.reduce(Int64(0)) { $0 + $1.bytes }
        let pinnedBytes = full.first { $0.name == pinned }?.bytes ?? 0
        // A limit that holds D and the one used most recently beside it, and no more.
        let others = full.filter { $0.name != pinned }
        let newest = others.last
        let limit = pinnedBytes + (newest?.bytes ?? 0) + 1
        t0 = ContinuousClock.now
        model.setFullRenderCacheLimit(limit)
        let trimMS = ms(since: t0)
        let left = book(model)
        let gone = full.filter { f in !left.contains { $0.name == f.name } }
        let leftTotal = left.reduce(Int64(0)) { $0 + $1.bytes }
        let keptOthers = left.filter { $0.name != pinned }
        r.step("4: the limit lowered", trimMS, [
            "before": full.map { ["file": $0.frame.map { name(model, $0) } ?? "?", "mb": mb($0.bytes), "used": $0.used.timeIntervalSince1970] as [String: Any] },
            "limit_mb": mb(limit), "after": left.map { ["file": $0.frame.map { name(model, $0) } ?? "?", "mb": mb($0.bytes)] as [String: Any] },
            "gone": gone.map { $0.frame.map { name(model, $0) } ?? "?" }, "pinned": pinned ?? "none", "total_mb_before": mb(total), "total_mb_after": mb(leftTotal),
        ])
        r.check(full.count >= 4, "4: four renders or more to trim (\(full.count))")
        r.check(leftTotal <= limit, "4: at once under the limit (\(mb(leftTotal)) of \(mb(limit)) MB, \(Int(trimMS)) ms)")
        r.check(pinned.map { n in left.contains { $0.name == n } } ?? false, "4: the current frame's render stays")
        r.check(keptOthers.map(\.name) == [newest?.name].compactMap { $0 }, "4: the one used most recently stays, the older go")
        r.check(gone.allSatisfy { g in keptOthers.allSatisfy { g.used <= $0.used } }, "4: the oldest go first")
        r.check(gone.allSatisfy { g in !fm.fileExists(atPath: model.originals.copies.proxyFolder!.appending(path: g.name).path) }, "4: their files are gone from the disk")
        // By bytes, whatever one weighs: under a limit of one byte the pinned one alone stays.
        model.setFullRenderCacheLimit(1)
        let alone = book(model)
        r.check(alone.count == 1 && alone.first?.name == pinned, "4: under a limit smaller than any render, only the pinned one stays (\(alone.count))")
        // The order for the relaunch: made again with the limit back, renders in a known order.
        model.setFullRenderCacheLimit(8 << 30)
        for (step, frame) in [(-1, c), (-1, b)] {
            NotificationCenter.default.post(name: .spkCheckStep, object: step)
            _ = await until(90) { model.openSession(frame)?.developed != nil }
            model.openSession(frame)?.fullView.want()
            _ = await until(300) { model.openSession(frame)?.fullView.state == .ready }
        }
        _ = await until(300) { scheduler.isIdle && cache.prefetch == nil }
        let order = book(model)
        let orderFile = out.appending(path: "lru-order.json")
        let orderJSON = order.map { ["name": $0.name, "bytes": $0.bytes, "used": $0.used.timeIntervalSince1970] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: orderJSON, options: [.prettyPrinted]) { try? data.write(to: orderFile) }
        r.step("4: the order kept for the relaunch", 0, ["order": order.map { ["file": $0.frame.map { name(model, $0) } ?? "?", "mb": mb($0.bytes)] as [String: Any] },
                                                         "file": orderFile.path])
        r.check(order.count >= 3, "4: three renders or more kept for the relaunch (\(order.count))")
        model.router.back()
        try? await Task.sleep(for: .seconds(1))
        r.step("end", 0, ["frames": model.library.frames.count, "footprint_mb": mb(MemoryProbe.footprint())])
        return r.json
    }

    // MARK: - the relaunch

    static func runRelaunch(_ model: AppServices, out: URL, previous: URL) async -> [String: Any] {
        let r = Report()
        let scheduler = model.scheduler
        // What the launch queued: what the scheduler has done so far, and ten seconds more of it.
        let recordsAtStart = scheduler.records.map(\.kind)
        let watch = JobWatch(scheduler)
        try? await Task.sleep(for: .seconds(10))
        watch.stop(scheduler)
        let undeveloped = model.library.frames.filter { $0.developed == nil }.count
        r.step("R: launch", 0, ["frames": model.library.frames.count, "without_a_develop": undeveloped, "jobs_by_kind": watch.kinds,
                                "records_at_start": recordsAtStart])
        r.check(undeveloped >= 200, "R: the library has 200 frames or more with no develop (\(undeveloped))")
        r.check(watch.jobs.isEmpty && !recordsAtStart.contains(JobKind.importDevelop.rawValue), "R: launch queues no develop for them (\(watch.kinds))")
        let data = (try? Data(contentsOf: previous.appending(path: "lru-order.json"))) ?? Data()
        let kept = ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
        let then = kept.compactMap { $0["name"] as? String }
        let now = book(model)
        var usedThen: [String: Double] = [:]
        for k in kept { if let n = k["name"] as? String, let u = k["used"] as? Double { usedThen[n] = u } }
        r.step("R: the renders as the last run left them", 0, ["then": then, "now": now.map(\.name),
            "used_drift_s": now.compactMap { n in usedThen[n.name].map { abs($0 - n.used.timeIntervalSince1970) } }.max() ?? -1])
        r.check(!then.isEmpty, "R: the first run's order was read (\(then.count))")
        r.check(now.map(\.name) == then, "R: the same renders in the same order after the relaunch")
        r.check(now.allSatisfy { n in usedThen[n.name].map { abs($0 - n.used.timeIntervalSince1970) < 1 } ?? false }, "R: each one's last use is its file's date, kept")
        return r.json
    }
    #endif
}
#endif
