//  RenderQueue.swift — the one door every render goes through.
//
//  RFC-036, phase 1: the scheduler in the app, with no engine change. Before
//  each job it reads the host's memory, computes a budget, and picks the
//  fastest mode that fits — whole, bands, smaller bands — or makes the job
//  wait and say why. It knows what the frontend is doing, because that is
//  where the memory goes.
//
//  What phase 1 is, and what it leaves to phase 2 (which needs engine hooks
//  E1-E4, none of which exist yet):
//
//  | | phase 1 (here) | phase 2 |
//  |---|---|---|
//  | the budget | before every job | before every band |
//  | a job that must give way (an export under a canvas edit, a job the camera or the background now forbids) | cancelled, and run again from the start when it may | paused at a band boundary and resumed |
//  | critical memory pressure | the job is cancelled and run again in a smaller mode | the band is, from the same row |
//
//  The rules it holds (RFC-036 §3.1):
//
//  - **G1 never killed.** A job that cannot fit waits; it does not gamble.
//  - **G2 the newest intent first.** Canvas jobs are coalesced: at most one
//    queued per frame, latest wins, and a running one is cancelled once the
//    newer one has waited a reprint's time. Superseded work is cancelled, not
//    finished.
//  - **G3 full quality, always.** The mode changes how long, never what.
//  - **G4 the camera never waits for the darkroom.** Nothing starts while a
//    photo is in flight, and a full-size job stops for one; an export waits
//    while the camera is live. A shot's own develop, at preview size, goes on
//    under a photo (`captureRule`): shooting and developing run together —
//    where the host lets them (`developsBesideCamera`). **This app does not**
//    (the owner, 2026-10-08): its darkroom is closed for as long as a camera
//    session runs, and what it holds is given back when one starts
//    (`cameraOpened`). The open flow is the bench's, where it was measured.
//  - **G5 the state is visible.** Every job has a snapshot the page can show,
//    and a waiting job carries its reason.
//
//  **One GPU job runs at a time** (§6.9): the engine is not re-entrant per
//  session, and two jobs would double the peak.
//
//  All of it runs on the main actor. The bookkeeping is a few dictionary
//  lookups per event; the render itself is awaited off it.

import Foundation
import Observation
import os

extension Notification.Name {
    /// The app gives back what it holds for a job someone waits on (`RenderQueue.onReclaim`):
    /// whatever can be drawn again listens.
    static let spkReclaim = Notification.Name("spk.reclaim")
}

enum JobOutcome: Equatable, Sendable {
    case finished(RenderResult)
    case cancelled
    case failed(String)
}

@MainActor
@Observable
final class RenderQueue {
    enum Pressure: Sendable { case warning, critical }

    // MARK: what the pages read

    /// Every job that has not finished, queued or running.
    private(set) var snapshots: [JobSnapshot] = []
    /// The last plan made: the budget, the mode, the prediction. Diagnostics.
    private(set) var lastPlan: RenderPlan?
    /// R8: the last 200 jobs, each with its mode, budget, prediction and measurement.
    private(set) var records: [JobRecord] = []

    /// What the frontend is doing. Any change re-plans.
    var frontend = FrontendState() {
        didSet {
            guard frontend != oldValue else { return }
            // A photo has landed when a capture in flight is one fewer. The camera set up
            // differently, or stopped, is a session that has yet to deliver its first.
            if frontend.camera != oldValue.camera { lastPhotoLanded = nil }
            else if frontend.cameraLive, frontend.capturesInFlight < oldValue.capturesInFlight { lastPhotoLanded = Date() }
            frontendChanged()
            if frontend.cameraLive, !oldValue.cameraLive { cameraOpened() }
            if frontend.scene != .active, oldValue.scene == .active { leftFront() }
        }
    }

    // MARK: what a host may set

    @ObservationIgnored var tuning = BudgetTuning()
    /// Injectable, so a test can put the host in any state.
    @ObservationIgnored var readMemory: @MainActor () -> MemoryReading = { MemoryProbe.read() }
    /// The frontend's own caches — thumbnails, textures of pictures off screen —
    /// dropped on a memory warning, before the engine is asked for anything.
    @ObservationIgnored var onTrimCaches: (@MainActor () -> Void)?
    /// The first rung of `reclaim`: everything the frontend holds that can be drawn again — more than
    /// `onTrimCaches` (Edit's working copies of the picture, the cards' decode). The host sets it.
    @ObservationIgnored var onReclaim: (@MainActor () -> Void)?
    /// **Reclaim before waiting** (the owner, 2026-10-21: "How the app asks for memory must be really
    /// really aggressive"). False keeps RFC-036's G1 as it was: a job that cannot fit waits.
    @ObservationIgnored var reclaimsForAsked = true
    /// How long a job someone waits on waits for memory, after everything has been given back, before
    /// it starts in its smallest mode against the app's allowance alone, the watch on it.
    @ObservationIgnored var forceAfter = 1.5
    /// Every change to a job, for whoever keeps the frames' states.
    @ObservationIgnored var onUpdate: (@MainActor (JobSnapshot) -> Void)?
    /// R8: every record as it is made, for whoever writes them to a file
    /// (`JobLogFile`). `records` keeps only the last 200, in memory.
    @ObservationIgnored var onRecord: (@MainActor (JobRecord) -> Void)?
    /// An export gives way to a canvas edit only if it has longer than this left.
    @ObservationIgnored var yieldThreshold = 0.4
    /// How long a waiting queue goes before it looks again by itself. Signals
    /// re-plan at once; this is the fallback.
    @ObservationIgnored var replanInterval = 0.5
    /// What a photo in flight does to a develop below the full tier
    /// (`CaptureRule`). A full-size job always stops for one.
    ///
    /// `holds`, by the owner's flow (2026-10-03: photos are taken and developed
    /// at the same time, at preview size) and by the reference device — EngineBench's
    /// `shoot`, six 12 MP photos one after another, each developed at 2,400 px
    /// as it landed, twice under each rule in each of three runs:
    ///
    /// | | a photo | its preview, after it landed | all six previews, after the first shutter | develops thrown away |
    /// |---|---|---|---|---|
    /// | `stops` | 298-366 ms | 1.9-2.3 s | 4.0-4.4 s | 5 of 6 |
    /// | `holds` | 350-421 ms | 0.44-1.43 s | 3.2-3.7 s | none |
    /// | `shares` | 359-482 ms | 0.35-0.66 s | 2.8-3.3 s | none |
    ///
    /// `stops` is RFC-036 §6.7 as first written: with photos coming one after
    /// another, nothing is developed until the last has landed. `shares` is
    /// quickest to a preview and costs each photo the most. `holds` keeps the
    /// camera first — no develop starts while a photo is in flight — and the
    /// queue still moves. During a develop the host's headroom never fell
    /// below 1.7 GB under any of them at 12 MP, nor below 1.4 GB at 48 MP.
    @ObservationIgnored var captureRule = CaptureRule.holds
    /// Whether anything develops beside a live camera at all. True is the
    /// flow above, as the reference device ran it in the bench: a shot's own develop,
    /// at preview size, behind the viewfinder, under `captureRule`.
    ///
    /// **False closes the darkroom for as long as a camera session runs**:
    /// nothing but a thumbnail starts, a job under way gives way when the
    /// camera goes live — and the camera says so when it is asked for, before
    /// its session has started (`CameraService.start`) — and the queue runs
    /// once the session has stopped and the budget reads its memory back.
    /// Shots land in the library all the while; they are developed after.
    ///
    /// **The app sets it false, and that is decided** (the owner, 2026-10-08:
    /// "I'm wondering if we really need that shooting while processing
    /// scheduler as it really fucks the RAM up. Let's make that sacrifice and
    /// keep the behavior as-is, but some RAM scheduling is still needed").
    /// There is no live render and a frame develops in well under a second
    /// once the camera is put down — on the owner's reference device, 0.12-0.54 s a
    /// canvas develop (the job log of 2026-10-08) — while the budget beside a
    /// camera at 48 MP on that host, with its other apps open, was 178 MB.
    /// True stays the default for the bench, whose runs measured the open flow
    /// (`captureRule`, the camera's reserve in `MemoryBudget`): none of that
    /// is reached in the app.
    @ObservationIgnored var developsBesideCamera = true
    /// A job that waits for memory first has the engine's own idle pool given
    /// back. Off only to show what that is worth: on the reference device an export
    /// that gave way to a canvas edit waited 8 s for memory while the engine
    /// held 1,568 MB of its cancelled planes idle (EngineBench, 2026-10-03).
    @ObservationIgnored var trimsWhenWaiting = true
    /// After a critical pressure event a job's budget is cut to 60 %, so its
    /// next plan is a smaller mode even if the host reports the same numbers.
    /// The cut is not permanent — pressure passes — and is given back evenly
    /// over this many seconds. A guess, to be calibrated with the budget (B7).
    @ObservationIgnored var pressureRecovery = 10.0
    /// Develop's strips (`JobKind.stockPreview`) never delay the page's own
    /// develop, nor anything else. Three rules, each with its switch so the
    /// self-test can show what it is worth; the app never turns one off:
    ///
    /// - **a running card gives way at once** to any job submitted — not after
    ///   the 0.4 s a small job is otherwise left to finish (`yieldThreshold`):
    ///   a card is a few tenths of a second, and the page's develop would wait
    ///   that long. It runs again from the start after;
    /// - **a card starts only when nothing else is queued**, waiting or not:
    ///   one that fits beside a job that waits for memory would take what that
    ///   job is waiting for, and its time;
    /// - **a newer card for the same slot replaces the older** (`RenderJob.slot`),
    ///   queued or running: an edit that moves every card's key asks again.
    @ObservationIgnored var previewsGiveWayAtOnce = true
    @ObservationIgnored var previewsWaitForTheQueue = true
    @ObservationIgnored var previewsCoalesce = true

    let engine: any DevelopEngine
    @ObservationIgnored private(set) var costModel: CostModel
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "scheduler")

    // MARK: state

    private enum CancelReason { case user, superseded, yielded, pressure }

    private struct Running {
        let job: RenderJob
        let plan: RenderPlan
        let started: Date
        /// The host as the plan read it, for the job's record.
        let reading: MemoryReading
        var reason: CancelReason?
    }

    @ObservationIgnored private var queue: [RenderJob] = []
    @ObservationIgnored private var running: Running?
    @ObservationIgnored private var waits: [UUID: [WaitReason]] = [:]
    @ObservationIgnored private var derate: [UUID: (factor: Double, at: Date)] = [:]
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<JobOutcome, Never>]] = [:]
    @ObservationIgnored private var outcomes: [UUID: JobOutcome] = [:]
    @ObservationIgnored private var outcomeOrder: [UUID] = []
    @ObservationIgnored private var replanTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastReprintStart: Date?
    /// The pool has been given back since a job last started: once per wait.
    @ObservationIgnored private var trimmedForWait = false
    /// How far the app has gone in giving back its own memory for the job someone waits on
    /// (`reclaim`): 0 nothing yet, 1 the frontend's caches, 2 the engine's session and pool. Back to
    /// 0 whenever a job starts.
    @ObservationIgnored private var reclaimed = 0
    @ObservationIgnored private var reclaimedAt: Date?
    /// Since when each job someone waits on has waited for memory.
    @ObservationIgnored private var waitingForMemorySince: [UUID: Date] = [:]
    /// A job that was started past the host's headroom and stopped by the watch: not again for a while.
    @ObservationIgnored private var forcedStoppedAt: [UUID: Date] = [:]
    /// When the camera, as it is set now, last delivered a photo.
    @ObservationIgnored private var lastPhotoLanded: Date?

    /// The session has delivered a photo lately: the next one grows the
    /// camera's memory by much less than its first did (`BudgetTuning`).
    private var cameraWarm: Bool {
        guard frontend.cameraLive, let landed = lastPhotoLanded else { return false }
        return Date().timeIntervalSince(landed) <= tuning.cameraWarmSeconds
    }

    /// `defaults` keeps the cost model's corrections across launches; nil keeps
    /// nothing (tests, the snapshot harness).
    init(engine: any DevelopEngine, policy: DevicePolicy = .current, defaults: UserDefaults? = .standard) {
        self.engine = engine
        self.defaults = defaults
        costModel = defaults.map { CostModel.load(from: $0, policy: policy) } ?? CostModel(policy: policy)
    }

    // MARK: - asking for a render

    @discardableResult
    func submit(_ job: RenderJob) -> UUID {
        if job.kind.isCanvas {
            // Latest wins: an older canvas job for this frame that has not
            // started is dropped, not finished.
            for old in queue where old.kind.isCanvas && old.frameID == job.frameID {
                finish(old, .cancelled)
            }
            queue.removeAll { $0.kind.isCanvas && $0.frameID == job.frameID }
            // One already running is given a reprint's time to finish.
            if let r = running, r.job.kind.isCanvas, r.job.frameID == job.frameID {
                supersede(r.job.id, after: costModel.estimate(job, mode: .whole).seconds)
            }
        }
        if job.kind == .importDevelop {
            // A frame's own develop, asked again before the first has started (the launch's sweep and
            // a setting held over the library both asking, 2026-10-21: 85 develops of 40 frames on the
            // owner's reference device): the newer is of the newer edit, and the older goes unfinished. Of the same
            // size only (2026-11-05): the Mac's full-size prefetch of Develop's neighbour is an importDevelop
            // too, and it cancelled the frame's preview develop a paste had asked — the tile then read
            // developed and kept the picture of the old edit.
            func same(_ old: RenderJob) -> Bool { old.kind == .importDevelop && old.frameID == job.frameID && old.tier == job.tier }
            for old in queue where same(old) { finish(old, .cancelled) }
            queue.removeAll(where: same)
        }
        if job.kind == .stockPreview, previewsCoalesce, let slot = job.slot {
            // The newer card for a slot is the one wanted: the older, queued, is dropped, and one
            // running is stopped now — it is a few tenths of a second, not a reprint's wait.
            func same(_ old: RenderJob) -> Bool { old.kind == .stockPreview && old.frameID == job.frameID && old.slot == slot }
            for old in queue where same(old) { finish(old, .cancelled) }
            queue.removeAll(where: same)
            if let r = running, same(r.job), r.reason == nil {
                running?.reason = .superseded
                engine.cancel(r.job.id)
            }
        }
        queue.append(job)
        let snapshot = JobSnapshot(id: job.id, job: job, state: .queued, mode: nil)
        snapshots.append(snapshot)
        onUpdate?(snapshot)
        // Anything more urgent than what is running: the running job gives way — a strip's card at once.
        // (A card does not stop the library's develop under way: it is next, and that develop is a moment.)
        if let r = running, r.job.kind.priority > job.kind.priority, !(job.kind == .stockPreview && r.job.kind == .importDevelop) {
            yield(r, to: "a more urgent job", force: r.job.kind == .stockPreview && previewsGiveWayAtOnce)
        }
        pump()
        return job.id
    }

    /// The job's end, whenever it comes. Safe to call before or after it ends.
    func outcome(of id: UUID) async -> JobOutcome {
        if let done = outcomes[id] { return done }
        guard snapshots.contains(where: { $0.id == id }) else { return .cancelled }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func cancel(_ id: UUID) {
        if let job = queue.first(where: { $0.id == id }) {
            queue.removeAll { $0.id == id }
            finish(job, .cancelled)
            pump()
        } else if running?.job.id == id {
            running?.reason = .user
            engine.cancel(id)
        }
    }

    /// Every job for a frame: it was deleted, or its page closed.
    func cancelAll(frameID: UUID, where matches: (RenderJob) -> Bool = { _ in true }) {
        for job in queue where job.frameID == frameID && matches(job) { cancel(job.id) }
        if let r = running, r.job.frameID == frameID, matches(r.job) { cancel(r.job.id) }
    }

    /// The job a frame's page should show: the one running, else the first waiting.
    func snapshot(frameID: UUID, where matches: (RenderJob) -> Bool = { _ in true }) -> JobSnapshot? {
        let mine = snapshots.filter { $0.job.frameID == frameID && matches($0.job) }
        return mine.first { if case .running = $0.state { true } else { false } } ?? mine.first
    }

    var isIdle: Bool { running == nil && queue.isEmpty }

    /// The budget a job would be given this instant, and the reading it was
    /// made from. For a page that shows the scheduler's view of the host
    /// (Settings): the constants behind it are RFC-036's starting values, so
    /// the number on a real host is the first thing to look at.
    func budgetNow() -> (budget: MemoryBudget, reading: MemoryReading) {
        let reading = readMemory()
        return (MemoryBudget.compute(reading, frontend: frontend, tuning: tuning, cameraWarm: cameraWarm), reading)
    }

    // MARK: - signals

    /// `DispatchSource.makeMemoryPressureSource`, `didReceiveMemoryWarning`, or
    /// the watch below.
    func memoryPressure(_ level: Pressure) {
        log.notice("memory pressure: \(level == .critical ? "critical" : "warning", privacy: .public)")
        onTrimCaches?()
        let engine = self.engine
        Task { await engine.trim() }
        // Only a full-size job is cancelled to run again smaller; the page's picture is one piece, and a
        // retry would take the same again (see `start`): the caches and the pool above are what it gives.
        if level == .critical, var r = running, r.reason == nil, r.job.tier == .full {
            // Cancel, trim, re-plan, and run the same job again, smaller.
            r.reason = .pressure
            running = r
            engine.cancel(r.job.id)
        } else {
            replan()
        }
    }

    private func frontendChanged() {
        // A job that the frontend's new state forbids gives way: an export when
        // the camera goes live, anything when the app leaves the foreground,
        // and under a photo in flight whatever the capture rule says.
        if let r = running, r.reason == nil, let why = mustStop(r) { yield(r, to: why.text, force: true) }
        replan()
    }

    /// A camera session has started where the darkroom is closed to one: what
    /// the darkroom holds and cannot use until the session stops goes back to
    /// the host now, while the camera is taking its own — the frontend's
    /// caches, and the engine's idle pool once whatever was running has given
    /// way (the pool of a job still unwinding is not idle yet: the queue's own
    /// trim takes it when that job is waiting). The first 48 MP photo of a
    /// session took 713-725 MB from the host (`BudgetTuning`).
    private func cameraOpened() {
        guard !developsBesideCamera else { return }
        onTrimCaches?()
        let engine = self.engine
        Task { await engine.trim() }
    }

    /// The app has left the front: nothing renders there, and the operating system ends the apps in the background
    /// that hold the most first (141 background memory-pressure exits in the testers' MetricKit,
    /// 2026-10-21) — so what the darkroom holds goes back: the frontend's caches, then the engine's
    /// editing session and pool. The page opens its session again when the app is back.
    private func leftFront() {
        guard reclaimsForAsked else { return }
        onTrimCaches?()
        onReclaim?()
        let engine = self.engine
        Task { [weak self] in
            let freed = await engine.reclaim(keeping: nil)
            self?.log.notice("left the front: the engine gave back \(freed.megabytes, format: .fixed(precision: 0)) MB")
        }
    }

    /// Why a running job may not go on in the frontend's new state, or nil.
    private func mustStop(_ r: Running) -> WaitReason? {
        guard let why = Planner.gate(r.job, frontend: frontend, policy: costModel.policy, captures: .stops,
                                     besideCamera: developsBesideCamera) else { return nil }
        guard why == .capture, r.job.tier != .full, captureRule != .stops else { return why }
        // Below the full tier a develop goes on under as many captures as its
        // budget kept aside — one more than were in flight when it was planned
        // — and gives way to the next.
        let taken = tuning.cameraGrowth(photoMegapixels: frontend.cameraPhotoMegapixels, warm: cameraWarm)
            * UInt64(max(0, frontend.capturesInFlight))
        return taken > r.plan.budget.cameraReserve ? .capture : nil
    }

    private func replan() {
        replanTask?.cancel()
        replanTask = nil
        pump()
    }

    // MARK: - the loop

    private func pump() {
        guard running == nil else { return }
        guard !queue.isEmpty else { idle(); return }
        let reading = readMemory()
        let budget = MemoryBudget.compute(reading, frontend: frontend, tuning: tuning, cameraWarm: cameraWarm)
        let askedBudget = reclaimsForAsked
            ? MemoryBudget.compute(reading, frontend: frontend, tuning: tuning, cameraWarm: cameraWarm, asked: true) : budget
        // In front, every job asks the host as hard as one someone waits on (the owner, 2026-10-21:
        // "ask the system more aggressively for available RAM when in the front"); only the giving back
        // and the forced start below are for the jobs someone waits on.
        let inFront = reclaimsForAsked && frontend.scene == .active
        // Priority, then age.
        let ordered = queue.sorted {
            $0.kind.priority != $1.kind.priority ? $0.kind.priority < $1.kind.priority : $0.submitted < $1.submitted
        }
        var soonest: Double?
        // A strip's card is the last of all: it waits for every other job, running or waiting.
        // Not the library's own develops of other frames, nor thumbnails: those come after the page's cards.
        let othersQueued = queue.contains { $0.kind != .stockPreview && $0.kind != .importDevelop && $0.kind != .thumbnail }
        for job in ordered {
            // A hot host lowers cadence, never the effects (S6).
            if job.kind == .canvasReprint, let hold = cadenceHold() {
                soonest = min(soonest ?? hold, hold)
                continue
            }
            if job.kind == .stockPreview, othersQueued, previewsWaitForTheQueue {
                if waits[job.id]?.last != .queued { waits[job.id, default: []].append(.queued) }
                update(job.id) { $0.state = .waiting(.queued); $0.mode = nil }
                continue
            }
            let plan = Planner.plan(job, budget: job.kind.isAsked || inFront ? askedBudget : budget, frontend: frontend, model: costModel,
                                    derate: currentDerate(job.id), captures: captureRule,
                                    besideCamera: developsBesideCamera)
            lastPlan = plan
            if case .wait(let why) = plan.mode {
                if waits[job.id]?.last != why { waits[job.id, default: []].append(why) }
                update(job.id) { $0.state = .waiting(why); $0.mode = plan.mode }
                if why == .memory, job.kind.isAsked, waitingForMemorySince[job.id] == nil { waitingForMemorySince[job.id] = Date() }
                continue   // a smaller job further down may still fit
            }
            start(job, plan, reading)
            return
        }
        // A job someone waits on cannot fit: the app gives back its own memory, one rung at a time,
        // and looks again within a moment (the footprint lags a release by up to ~2 s); with nothing
        // left to give, it starts in its smallest mode under the watch rather than wait.
        if reclaimsForAsked, let asked = ordered.first(where: { $0.kind.isAsked && waits[$0.id]?.last == .memory }) {
            if reclaimed < 2 {
                reclaim(for: asked)
                return
            }
            if let since = waitingForMemorySince[asked.id], Date().timeIntervalSince(since) >= forceAfter,
               forcedStoppedAt[asked.id].map({ Date().timeIntervalSince($0) > 10 }) ?? true,
               let plan = forcedPlan(asked, budget: askedBudget) {
                log.notice("\(asked.kind.rawValue, privacy: .public) has waited \(Date().timeIntervalSince(since), format: .fixed(precision: 1)) s for memory with nothing left to give back: it starts in \(plan.mode.name, privacy: .public), the watch on it")
                forced.insert(asked.id)
                start(asked, plan, reading)
                return
            }
        }
        // Nothing could start. If memory is why, the engine's own idle pool is
        // the first place to find some: it keeps the planes of the job that
        // last ran (a banded engine gives them back by itself only when its
        // last session closes, and a frame being edited keeps one open). Only
        // buffers that are free and idle go, and nothing is running here.
        if trimsWhenWaiting, !trimmedForWait, queue.contains(where: { job in
            switch waits[job.id]?.last { case .memory, .camera, .background: true; default: false }
        }) {
            trimmedForWait = true
            let engine = self.engine
            Task { [weak self] in
                let freed = await engine.trim()
                guard freed > 0 else { return }
                self?.log.info("a job waits for memory: \(freed.megabytes, format: .fixed(precision: 0)) MB of idle pool given back")
                self?.replan()
            }
        }
        // Signals re-plan at once; otherwise look again soon — sooner while what was given back is
        // still arriving, or while a job someone waits on is counting down to its start.
        let recently = reclaimedAt.map { Date().timeIntervalSince($0) < 2 } ?? false
        let delay = soonest ?? (recently || !waitingForMemorySince.isEmpty ? min(replanInterval, 0.15) : replanInterval)
        replanTask?.cancel()
        replanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.replanTask = nil
            self?.pump()
        }
    }

    /// How much of the budget a job is trusted with: 1, or less for a while
    /// after pressure cancelled it.
    private func currentDerate(_ id: UUID) -> Double {
        guard let cut = derate[id] else { return 1 }
        let back = Date().timeIntervalSince(cut.at) / max(pressureRecovery, 0.001)
        return min(1, cut.factor + (1 - cut.factor) * back)
    }

    /// Print-side updates at most 8 a second on a `serious` host and 4 on a
    /// `critical` one (§6.7). The seconds still to hold, or nil to go.
    private func cadenceHold() -> Double? {
        let interval: Double
        switch frontend.thermal {
        case .nominal, .fair: return nil
        case .serious: interval = 1.0 / 8
        case .critical: interval = 1.0 / 4
        }
        guard let last = lastReprintStart else { return nil }
        let since = Date().timeIntervalSince(last)
        return since >= interval ? nil : interval - since
    }

    private func start(_ job: RenderJob, _ plan: RenderPlan, _ reading: MemoryReading) {
        queue.removeAll { $0.id == job.id }
        trimmedForWait = false
        reclaimed = 0
        waitingForMemorySince[job.id] = nil
        let first: RenderStage = job.decodesOriginal ? .decode : (job.isReprint ? .print : .film)
        update(job.id) { $0.state = .running(RenderProgress(stage: first, fraction: 0)); $0.mode = plan.mode }
        if job.kind == .canvasReprint { lastReprintStart = Date() }
        let started = Date()
        running = Running(job: job, plan: plan, started: started, reading: reading, reason: nil)
        let predictedMB = plan.estimate.peakBytes.megabytes, budgetMB = plan.budget.bytes.megabytes
        log.info("start \(job.kind.rawValue, privacy: .public) \(job.canvas.megapixels, format: .fixed(precision: 1)) MP in \(plan.mode.name, privacy: .public): predicted \(predictedMB, format: .fixed(precision: 0)) MB of \(budgetMB, format: .fixed(precision: 0)) MB, \(plan.estimate.seconds, format: .fixed(precision: 2)) s")
        let engine = self.engine
        // The scheduler lives as long as the app; the task holds it for one job.
        Task {
            let result: Result<RenderResult, Error>
            do {
                result = .success(try await engine.run(job, mode: plan.mode) { p in
                    Task { @MainActor in self.progressed(job.id, p) }
                })
            } catch {
                result = .failure(error)
            }
            self.ended(job, plan, started, reading, result)
        }
        // Full-size jobs only. The page's own picture is never stopped by the watch: a RAW's open dips the
        // host's headroom for a moment past any line, and a canvas job cancelled there is started again into
        // the same dip — the preview that never landed on the owner's reference device, 2026-10-21, when this watched
        // every job someone waits on. A canvas job is one piece whatever its budget, so cancelling it frees
        // nothing a retry would not take again.
        if job.tier == .full { watch(asked: job.kind.isAsked && reclaimsForAsked && !frontend.cameraLive && frontend.scene == .active) }
    }

    /// Jobs started past the host's headroom (`forcedPlan`): the watch stops them, and they wait.
    /// (Their records say "done" as any other; the system log says how they started.)
    @ObservationIgnored private var forced: Set<UUID> = []

    /// One rung of giving back what the app holds, for `job`, which someone waits on:
    /// 1. the frontend's caches (`onTrimCaches`, `onReclaim`): thumbnails, cards, Edit's copies;
    /// 2. the engine's editing session — unless the job is a canvas job of that very frame — and its pool.
    /// Then the queue is planned again.
    private func reclaim(for job: RenderJob) {
        reclaimed += 1
        reclaimedAt = Date()
        let before = readMemory()
        switch reclaimed {
        case 1:
            onTrimCaches?()
            onReclaim?()
            log.notice("\(job.kind.rawValue, privacy: .public) waits for memory: the frontend's caches go")
            replanSoon()
        default:
            let engine = self.engine
            let keeping = job.kind.isCanvas ? job.frameID : nil
            Task { [weak self] in
                let freed = await engine.reclaim(keeping: keeping)
                guard let self else { return }
                self.log.notice("\(job.kind.rawValue, privacy: .public) waits for memory: the engine gave back \(freed.megabytes, format: .fixed(precision: 0)) MB (headroom was \(before.phoneHeadroom.megabytes, format: .fixed(precision: 0)) MB)")
                self.replanSoon()
            }
        }
    }

    private func replanSoon() {
        replanTask?.cancel()
        replanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            self?.replanTask = nil
            self?.pump()
        }
    }

    /// The last resort for a job someone waits on: its smallest mode, held to the app's own allowance
    /// only — which the operating system ends the app past — and not to the host's headroom, which the operating system makes more of by
    /// ending other apps. Nil where even that does not fit the allowance, or the frontend forbids it.
    private func forcedPlan(_ job: RenderJob, budget: MemoryBudget) -> RenderPlan? {
        guard Planner.gate(job, frontend: frontend, policy: costModel.policy, captures: captureRule,
                           besideCamera: developsBesideCamera) == nil else { return nil }
        let mode = Planner.ladder(for: job).last ?? .whole
        let cost = costModel.estimate(job, mode: mode)
        guard Double(cost.peakBytes) <= Double(budget.appBytes) * currentDerate(job.id) else { return nil }
        return RenderPlan(mode: mode, estimate: cost, budget: budget)
    }

    private func progressed(_ id: UUID, _ p: RenderProgress) {
        guard running?.job.id == id else { return }
        update(id) { $0.state = .running(p) }
    }

    private func ended(_ job: RenderJob, _ plan: RenderPlan, _ started: Date, _ reading: MemoryReading,
                       _ result: Result<RenderResult, Error>) {
        let reason = running?.job.id == job.id ? running?.reason : nil
        if running?.job.id == job.id { running = nil }
        let wasForced = forced.remove(job.id) != nil
        watchTask?.cancel(); watchTask = nil
        switch result {
        case .success(let r):
            // Learned only from the job that was priced. One that opened or rendered more
            // pixels than its canvas is another job's cost, and says so in its record.
            if !job.isOverAsked(r.size), !(r.measured?.opened.map { job.tier != .full && job.isOverOpened($0) } ?? false) {
                costModel.learn(job, mode: plan.mode, measuredPeakBytes: r.peakBytes, measuredSeconds: r.seconds)
                if let defaults { costModel.save(to: defaults) }
            }
            record(job, plan, reading, outcome: "done", measured: r)
            if wasForced { log.notice("\(job.kind.rawValue, privacy: .public), started past the phone's headroom, finished") }
            finish(job, .finished(r))
        case .failure(let error):
            if let e = error as? EngineError, e == .cancelled {
                switch reason {
                case .yielded, .pressure:
                    // It runs again from the start (phase 1). After a pressure
                    // event the same reading is trusted less, so the next plan
                    // is a smaller mode even if the host reports the same.
                    if reason == .pressure { derate[job.id] = (currentDerate(job.id) * 0.6, Date()) }
                    record(job, plan, reading, outcome: reason == .pressure ? "cancelled: pressure, runs again smaller"
                                                                   : "cancelled: gave way, runs again", measured: nil)
                    queue.append(job)
                    update(job.id) { $0.state = .queued; $0.mode = nil }
                case .superseded:
                    record(job, plan, reading, outcome: "cancelled: superseded", measured: nil)
                    finish(job, .cancelled)
                case .user, .none:
                    record(job, plan, reading, outcome: "cancelled", measured: nil)
                    finish(job, .cancelled)
                }
            } else {
                let message: String
                if let e = error as? EngineError {
                    switch e {
                    case .resource(let m), .failed(let m): message = m
                    case .cancelled: message = "cancelled"
                    }
                } else { message = "\(error)" }
                record(job, plan, reading, outcome: "failed: \(message)", measured: nil)
                finish(job, .failed(message))
            }
        }
        pump()
    }

    // MARK: - giving way

    /// A running job gives way: an export to a canvas edit, anything to a state
    /// that forbids it. Cancelled and queued again (phase 1). Short jobs are
    /// left to finish unless they must stop (`force`).
    private func yield(_ r: Running, to what: String, force: Bool = false) {
        guard running?.job.id == r.job.id, running?.reason == nil else { return }
        let left = r.plan.estimate.seconds - Date().timeIntervalSince(r.started)
        guard force || left > yieldThreshold else { return }
        log.info("\(r.job.kind.rawValue, privacy: .public) gives way to \(what, privacy: .public)")
        running?.reason = .yielded
        engine.cancel(r.job.id)
    }

    /// A running canvas job is cancelled once the newer one has waited a
    /// reprint's time (§6.9).
    private func supersede(_ id: UUID, after seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.02) * 1_000_000_000))
            guard let self, self.running?.job.id == id, self.running?.reason == nil else { return }
            self.running?.reason = .superseded
            self.engine.cancel(id)
        }
    }

    /// The host's headroom, every 50 ms while a full-size job runs (§6.2). A
    /// memory warning does not arrive in time to rescue an excessive peak, so
    /// the scheduler looks for itself — at three quarters of the floor, which
    /// is 450 MB: below where the operating system itself calls it critical (623 MB, measured)
    /// and above where it ended the app (308 MB).
    ///
    /// `asked`: a job someone waits on, planned against more of the host, is stopped lower down
    /// (`BudgetTuning.askedWatchFloor`) — and its allowance watched with room to spare.
    private func watch(asked: Bool = false) {
        watchTask?.cancel()
        let floor = asked ? tuning.askedWatchFloor : tuning.floorReserve / 4 * 3
        let allowance: UInt64 = asked ? 160 << 20 : 64 << 20
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled, self.running != nil else { return }
                let reading = self.readMemory()
                if reading.phoneHeadroom < floor || reading.appAvailable < allowance {
                    if let id = self.running?.job.id, self.forced.contains(id) { self.forcedStoppedAt[id] = Date() }
                    self.memoryPressure(.critical)
                    return
                }
            }
        }
    }

    /// Nothing queued and nothing running: release gives everything back. A
    /// banded engine holds 0 MB after release, and the footprint returns within
    /// 2 s (RFC-035 §11).
    private func idle() {
        replanTask?.cancel(); replanTask = nil
        let engine = self.engine
        Task { await engine.trim() }
    }

    // MARK: - bookkeeping

    private func update(_ id: UUID, _ change: (inout JobSnapshot) -> Void) {
        guard let i = snapshots.firstIndex(where: { $0.id == id }) else { return }
        var s = snapshots[i]
        change(&s)
        guard s != snapshots[i] else { return }
        snapshots[i] = s
        onUpdate?(s)
    }

    private func finish(_ job: RenderJob, _ outcome: JobOutcome) {
        if let i = snapshots.firstIndex(where: { $0.id == job.id }) {
            var s = snapshots.remove(at: i)
            switch outcome {
            case .finished: s.state = .done
            case .cancelled: s.state = .cancelled
            case .failed(let m): s.state = .failed(m)
            }
            onUpdate?(s)
        }
        waits[job.id] = nil
        derate[job.id] = nil
        waitingForMemorySince[job.id] = nil
        forcedStoppedAt[job.id] = nil
        outcomes[job.id] = outcome
        outcomeOrder.append(job.id)
        if outcomeOrder.count > 100 { outcomes[outcomeOrder.removeFirst()] = nil }
        for c in waiters.removeValue(forKey: job.id) ?? [] { c.resume(returning: outcome) }
    }

    private func record(_ job: RenderJob, _ plan: RenderPlan, _ reading: MemoryReading, outcome: String,
                        measured: RenderResult?) {
        // What the engine did, beside what was asked. A real engine that
        // reports no bands rendered the frame whole.
        let ran = measured.flatMap { m in
            m.bands.map { "bands(\($0.rows)) x \($0.count), halo \($0.halo)" } ?? (m.measured != nil ? "whole" : nil)
        }
        let r = JobRecord(jobID: job.id, kind: job.kind.rawValue, tier: job.tier.rawValue,
                          megapixels: job.canvas.megapixels, mode: plan.mode.name,
                          budgetBytes: plan.budget.bytes, predictedPeakBytes: plan.estimate.peakBytes,
                          predictedPhoneBytes: plan.estimate.phoneBytes,
                          measuredPeakBytes: measured.map(\.peakBytes).flatMap { $0 > 0 ? $0 : nil },
                          predictedSeconds: plan.estimate.seconds, measuredSeconds: measured?.seconds,
                          waits: (waits[job.id] ?? []).map(\.rawValue), outcome: outcome, at: Date(),
                          ran: ran, appSideBytes: plan.budget.appSide, phoneSideBytes: plan.budget.phoneSide,
                          binding: plan.budget.binding.rawValue, cameraReserveBytes: plan.budget.cameraReserve,
                          reading: reading, frontend: frontend.text + (cameraWarm ? "; the camera has taken a photo" : ""),
                          measurement: measured?.measured,
                          renderedInstead: measured.flatMap { job.renderedInstead($0.size) },
                          openedInstead: job.tier == .full ? nil : measured?.measured?.opened.flatMap { job.openedInstead($0) })
        if let m = measured, job.isOverAsked(m.size) {
            // The picture is larger than the one that was priced: the host handed the engine a
            // frame larger than the job's canvas, and the engine rendered its own tier.
            log.error("\(job.kind.rawValue, privacy: .public) was asked and priced at \(job.canvas.width) x \(job.canvas.height) and the engine rendered \(m.size.width) x \(m.size.height)")
        }
        if job.tier != .full, let o = measured?.measured?.opened, job.isOverOpened(o) {
            // The open is the cost: a 48 MP photo opened whole for a 2,400 px preview took
            // 1.1 GB where 0.5 was predicted, and 0.8-1.5 GB from the host.
            log.error("\(job.kind.rawValue, privacy: .public) was priced at \(job.canvas.width) x \(job.canvas.height) and was handed a frame of \(o.width) x \(o.height) to open")
        }
        if case .bands = plan.mode, let m = measured, m.measured != nil, m.bands == nil {
            // The plan and the render parted ways: the peak that was budgeted is not
            // the peak that was taken. A job the engine cannot band must say so
            // (`RenderJob.bandable`), so that it is planned whole, or waits.
            log.error("\(job.kind.rawValue, privacy: .public) was planned in \(plan.mode.name, privacy: .public) and the engine rendered it whole")
        }
        records.append(r)
        onRecord?(r)
        if records.count > 200 { records.removeFirst(records.count - 200) }
        log.info("\(job.kind.rawValue, privacy: .public) \(outcome, privacy: .public): \(plan.mode.name, privacy: .public), \(measured?.seconds ?? 0, format: .fixed(precision: 2)) s against \(plan.estimate.seconds, format: .fixed(precision: 2)) s predicted")
    }
}
