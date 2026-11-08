//  FullRenderJobs.swift — the one door a full-size render's job goes through, and the jobs under way.
//
//  A frame's full render (`FullRender`, kept on disk with its own limit, `WorkingCopies.fullLimit`) is
//  asked for from three places since 2026-10-24: the develop page's zoom (`FullView`), the Light Table
//  for a film shown larger than its kept develop, or with none (`LightTableTextures`), and — on the
//  Mac — the develop page's neighbours in the filmstrip, made ahead (`MacRenderCache`). The same render
//  must never be made twice, so each is submitted here, once for its file: an ask for a render already
//  under way is handed that job. When one ends the app is told (`.spkFullRenderEnded`).
//
//  **What it is asked as says when it runs, not what it makes.** Every one is planned and priced as an
//  export at Full (`EngineRouter.prepareFullView`) and written by the engine's host (`EngineHost.deliver`):
//
//  | who | `JobKind` | priority | |
//  |---|---|---|---|
//  | the page's zoom, the Light Table | `fullView` | 3 | someone is looking for it (`isAsked`) |
//  | a prefetch | `importDevelop` | 5 | below the page's edits (1), exports (3) and its cards (4); a running one gives way to any of them |
//
//  So "the photo the user needs now before background prefetch" is the scheduler's own order, with
//  nothing of the scheduler changed (the owner, 2026-10-24: "minimum or no change at all should be made
//  to it"). A prefetch the page then asks for (`FullView.want`) is taken over where it is under way and
//  asked again as the page's where it has not started (`promote`).

#if SPK_ENGINE
import Foundation

extension Notification.Name {
    /// A full render's job ended: `userInfo["frame"]` (UUID), `["name"]` (its file's name), `["made"]` (Bool).
    static let spkFullRenderEnded = Notification.Name("spk.fullRenderEnded")
}

@MainActor
enum FullRenderJobs {
    /// What a full render of a frame is: its plan (an export at Full on this device) and its file.
    struct Made {
        let plan: ExportPlan
        let source: URL
        let isRAW: Bool
        let ask: FullRender.Ask
        /// About what its file will weigh: 8 bytes a pixel, a quarter more for the half size.
        var estimatedBytes: Int64 {
            Int64(plan.engineCanvas.width) * Int64(plan.engineCanvas.height) * 10 + Int64(FullRender.dataStart)
        }
    }

    /// Who asked for one, for the log and the checks.
    enum Asker: String, Sendable { case page, table, prefetch }

    struct Flight {
        let id: UUID
        let frame: UUID
        let ask: FullRender.Ask
        let kind: JobKind
        let asker: Asker
    }

    /// The jobs under way or queued, by their file's name.
    private(set) static var flights: [String: Flight] = [:]

    /// The full render a frame would have now — nil for a frame with no more to show than its preview
    /// (`FullView.hasMore`), a pair, an original that is not here, or no engine.
    static func made(_ frame: LibraryFrame, darkroom: EngineRouter?) -> Made? {
        guard let darkroom, darkroom.makesPictures, FullView.hasMore(frame), frame.original.isAvailable,
              let made = darkroom.fullPlan?(frame),
              let ask = darkroom.fullAsk(frame, plan: made.plan, source: made.source, isRAW: made.isRAW) else { return nil }
        return Made(plan: made.plan, source: made.source, isRAW: made.isRAW, ask: ask)
    }

    /// The frame's full render, where it is on disk whole and of the frame as it stands.
    static func reader(_ made: Made) -> FullRender.Reader? { FullRender.Reader(made.ask.url, stamp: made.ask.stamp) }

    static func flight(_ ask: FullRender.Ask) -> Flight? {
        guard let f = flights[ask.url.lastPathComponent], f.ask == ask else { return nil }
        return f
    }

    /// The flight of a job, by its id: nil once it has ended.
    static func flight(for job: UUID) -> Flight? { flights.values.first { $0.id == job } }

    /// The names of the renders being made: never cleared from the disk meanwhile (`WorkingCopies.fullInUse`).
    static var names: Set<String> { Set(flights.keys) }

    /// Whether the job is running now (not queued, not waiting).
    static func isRunning(_ id: UUID, in scheduler: RenderQueue) -> Bool {
        guard let s = scheduler.snapshots.first(where: { $0.id == id }) else { return false }
        if case .running = s.state { return true }
        return false
    }

    /// The frame's full render asked for: the job already making it, or a new one. Nil where it cannot
    /// be made from here (an original away, nothing for the engine to read).
    static func submit(_ frame: LibraryFrame, _ made: Made, kind: JobKind, asker: Asker,
                       scheduler: RenderQueue, darkroom: EngineRouter) -> UUID? {
        let name = made.ask.url.lastPathComponent
        if let f = flights[name], f.ask == made.ask { return f.id }
        guard !darkroom.isAway(frame) else { return nil }
        let job = RenderJob(frameID: frame.id, kind: kind, tier: .full, canvas: made.plan.engineCanvas,
                            what: L("Full size"), decodesOriginal: true, bandable: !made.plan.engineCuts,
                            original: made.plan.decoded, printLayers: 0)
        guard darkroom.prepareFullView(job, frame: frame, plan: made.plan, source: made.source, isRAW: made.isRAW, ask: made.ask) else {
            return nil
        }
        let id = scheduler.submit(job)
        flights[name] = Flight(id: id, frame: frame.id, ask: made.ask, kind: kind, asker: asker)
        Task { @MainActor in
            let outcome = await scheduler.outcome(of: id)
            darkroom.forget(id)
            if flights[name]?.id == id { flights[name] = nil }
            var finished = false
            if case .finished = outcome { finished = true }
            NotificationCenter.default.post(name: .spkFullRenderEnded, object: nil,
                                            userInfo: ["frame": frame.id, "name": name, "made": finished])
        }
        return id
    }

    /// A prefetch the page now waits on: under way, it is the page's as it is; queued, it is asked again
    /// at the page's standing (`fullView`) and the prefetch goes. The job to wait on.
    static func promote(_ frame: LibraryFrame, _ made: Made, scheduler: RenderQueue, darkroom: EngineRouter) -> UUID? {
        let name = made.ask.url.lastPathComponent
        if let f = flights[name], f.ask == made.ask {
            if f.kind == .fullView || isRunning(f.id, in: scheduler) { return f.id }
            flights[name] = nil
            scheduler.cancel(f.id)
        }
        return submit(frame, made, kind: .fullView, asker: .page, scheduler: scheduler, darkroom: darkroom)
    }

    /// The job goes: queued, it is dropped; under way, it stops (the render is not kept).
    static func cancel(_ id: UUID, scheduler: RenderQueue) {
        scheduler.cancel(id)
    }
}
#endif
