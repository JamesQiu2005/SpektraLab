//  MacRenderCache.swift — the Mac's full-size renders around what a person is looking at.
//
//  The owner, 2026-10-24: "the desktop scheduler is solid enough; minimum or no change at all should be made
//  to it. What changes is the external cache system around it, and what is put into the scheduler." So this
//  file decides only **what is submitted, and when**; the scheduler orders it (`JobKind`'s priorities) and
//  the renders' book keeps it (`WorkingCopies.fullLimit`, an LRU by bytes on disk). Nothing here renders.
//
//  **The develop page's neighbours, made ahead** (`developing`). While a person inspects a frame at full
//  size in Develop — its page has asked for its full render (`FullView`) — the filmstrip's frames beside it
//  are rendered too, so that stepping to one and zooming shows it at once, and its export reads it
//  (`EngineHost.cached`):
//
//  - **after the current one, never before**: a prefetch is submitted only once the current frame's own
//    render is on disk (or it has none to have), and **one at a time**: the next when the last has ended;
//  - **below the current one**: as an `importDevelop` (priority 5), where the page's edits are 1, its zoom
//    and exports 3 and its cards 4 — so a running prefetch gives way to any of them (the scheduler's own
//    `yield`) and a queued one waits for them;
//  - **the nearest first**, in the way the person is going: +1, −1, +2, −2 (or the other way round after a
//    step back), two each side;
//  - **cancelled when the person moves on** (`developing` with another frame): a prefetch that has not
//    started goes, and so does one under way for a frame no longer beside the current one; one for the
//    frame stepped to is left, and is that page's when it asks (`FullRenderJobs.promote`: taken over
//    under way, asked again at the page's standing if it has not started);
//  - **within the renders' limit**: a neighbour is not made where its render would not fit beside the
//    current one's and the neighbours' already kept (`fits`) — a prefetch that pushed out the render it
//    was made beside would be work thrown away;
//  - **only while inspecting**: a person who never zooms past the preview pays for nothing.
//
//  **The Light Table's films** (`attach`): a film shown larger than its kept develop, or with none, is read
//  from its full render where one is kept (`fullRef`), and otherwise one `fullView` job is asked for it,
//  once (`tableWants`); a frame with no more to it than its preview and nothing kept has its preview
//  develop asked instead. The film wears the develop ring meanwhile (`LightTableController.making`). A film
//  taken off, or the table closed, cancels its job if it has not started (`tableLetsGo`).
//
//  **What the renders' limit may not take** (`pinned`): the current Develop frame's render.

#if SPK_ENGINE
import Foundation
import os

@MainActor
final class MacRenderCache {
    private weak var model: AppServices?
    private let log = Logger(subsystem: "com.spektralab.mac", category: "rendercache")

    // MARK: Develop

    /// The frame on the develop page, and the filmstrip it is in.
    private(set) var current: LibraryFrame.ID?
    /// The filmstrip as the page has it now (read when it is needed: the strip is filled after the page appears).
    private var stripOf: () -> [LibraryFrame.ID] = { [] }
    private var strip: [LibraryFrame.ID] { stripOf() }
    /// +1 after a step forward, −1 after a step back.
    private var direction = 1
    /// The person has zoomed past the preview during this visit to Develop.
    private(set) var inspecting = false
    /// The one prefetch under way or queued.
    private(set) var prefetch: (frame: LibraryFrame.ID, job: UUID)?
    /// How far each side the neighbours are made.
    var reach = 2

    /// What was decided, for the check (`MacRenderCheck`) and the log.
    struct Event: Sendable {
        let at: Date
        let what: String
        let frame: LibraryFrame.ID?
        let job: UUID?
    }
    private(set) var events: [Event] = []

    // MARK: the Light Table

    private weak var table: LightTableController?
    /// Each film's job asked by the table, by frame.
    private(set) var tableJobs: [LibraryFrame.ID: UUID] = [:]
    /// Films whose preview develop the table asked for (no full render to be had).
    private var tableDevelops: Set<LibraryFrame.ID> = []
    /// Renders asked for and not made (failed, or cancelled): not asked again while the table is open.
    private var tableGaveUp: Set<String> = []
    private var ringWatch: Task<Void, Never>?
    /// The pass that reads a kept render for the table (`FullDetail.shared`).
    private(set) var pass: FullDetail?
    private var ended: NSObjectProtocol?

    init(model: AppServices) {
        self.model = model
        FullView.onState = { [weak self] frame, state in self?.pageRender(frame, state) }
        LightTableFullRead.onRead = { [weak model] url, bytes in model?.originals.copies.noteFull(url, bytes: bytes) }
        ended = NotificationCenter.default.addObserver(forName: .spkFullRenderEnded, object: nil, queue: .main) { [weak self] note in
            guard let frame = note.userInfo?["frame"] as? UUID, let name = note.userInfo?["name"] as? String else { return }
            let made = note.userInfo?["made"] as? Bool ?? false
            MainActor.assumeIsolated { self?.renderEnded(frame, name: name, made: made) }
        }
    }

    private func event(_ what: String, _ frame: LibraryFrame.ID? = nil, job: UUID? = nil) {
        events.append(Event(at: Date(), what: what, frame: frame, job: job))
        if events.count > 400 { events.removeFirst(events.count - 400) }
        log.info("\(what, privacy: .public)")
    }

    private func made(_ id: LibraryFrame.ID) -> (LibraryFrame, FullRenderJobs.Made)? {
        guard let model, let f = model.library.frame(id), let m = FullRenderJobs.made(f, darkroom: model.darkroom) else { return nil }
        return (f, m)
    }

    /// The full renders the limit may not take now (`AppServices.fullRendersInUse`): the current Develop
    /// frame's, as it stands.
    var pinned: Set<String> {
        guard let current, let (_, m) = made(current) else { return [] }
        return [m.ask.url.lastPathComponent]
    }

    // MARK: - Develop

    /// The page host that last said what it shows: a host that goes after another has come says nothing.
    private var host: UUID?

    /// The develop page shows `id` (nil: Develop has closed), in the filmstrip `strip`. `host` is the page's
    /// host: a host's going (`id` nil) is heard only from the host that spoke last — SwiftUI may bring the
    /// next one before the last one has gone.
    func developing(_ id: LibraryFrame.ID?, strip: @escaping () -> [LibraryFrame.ID], host: UUID? = nil) {
        if let host {
            if id == nil, self.host != nil, self.host != host { return }
            self.host = id == nil ? nil : host
        }
        guard let id else {
            if let p = prefetch { cancelPrefetch(p, why: "Develop closed") }
            if current != nil { event("Develop closed", current) }
            current = nil
            inspecting = false
            stripOf = { [] }
            return
        }
        stripOf = strip
        guard id != current else { consider(); return }
        let ids = strip()
        if let old = current, let i = ids.firstIndex(of: old), let j = ids.firstIndex(of: id) { direction = j >= i ? 1 : -1 }
        current = id
        event("the develop page is on a frame (a strip of \(ids.count))", id)
        // Moving on: a prefetch that has not started goes, and one under way for a frame no longer beside.
        // One for the frame stepped to is its page's now, started or not (`FullRenderJobs.promote`).
        if let p = prefetch, p.frame != id, let model {
            let running = FullRenderJobs.isRunning(p.job, in: model.scheduler)
            if !running || !neighbours(of: id).contains(p.frame) {
                cancelPrefetch(p, why: running ? "moved away from it" : "moved on before it started")
            }
        }
        consider()
    }

    /// The frames beside `id` in the strip, nearest first, the way the person is going first.
    func neighbours(of id: LibraryFrame.ID) -> [LibraryFrame.ID] {
        guard let i = strip.firstIndex(of: id) else { return [] }
        var out: [LibraryFrame.ID] = []
        for k in 1...max(reach, 1) {
            for d in [direction * k, -direction * k] where strip.indices.contains(i + d) { out.append(strip[i + d]) }
        }
        return out
    }

    /// A page's full render changed state: zoomed, the visit is an inspection; here, the neighbours follow.
    private func pageRender(_ frame: LibraryFrame.ID, _ state: FullView.State) {
        guard frame == current else { return }
        switch state {
        case .rendering, .waiting:
            if !inspecting { event("inspecting at full size", frame) }
            inspecting = true
        case .ready:
            if !inspecting { event("inspecting at full size", frame) }
            inspecting = true
            consider()
        case .off, .failed:
            break
        }
    }

    private func cancelPrefetch(_ p: (frame: LibraryFrame.ID, job: UUID), why: String) {
        guard let model else { return }
        prefetch = nil
        model.scheduler.cancel(p.job)
        event("prefetch cancelled: \(why)", p.frame, job: p.job)
    }

    /// Whether a render of `bytes` fits in the renders' limit beside the current one's and the
    /// neighbours' already kept.
    private func fits(_ bytes: Int64, beside: [LibraryFrame.ID]) -> Bool {
        guard let model else { return false }
        let copies = model.originals.copies
        var kept: Int64 = 0
        for id in beside {
            guard let (_, m) = made(id) else { continue }
            kept += copies.fulls[m.ask.url.lastPathComponent]?.bytes ?? 0
        }
        return kept + bytes <= copies.fullLimit
    }

    /// The next prefetch, if one is due: inspecting, nothing under way, the current frame's own render here.
    func consider() {
        guard let model, inspecting, prefetch == nil, let current, model.darkroom.makesPictures else { return }
        if let (_, m) = made(current), FullRenderJobs.reader(m) == nil { return }      // the current one first
        let around = neighbours(of: current)
        for id in around {
            guard let (f, m) = made(id) else { continue }
            if FullRenderJobs.reader(m) != nil || FullRenderJobs.flight(m.ask) != nil { continue }
            guard fits(m.estimatedBytes, beside: [current] + around) else {
                event("prefetch skipped: no room in the renders' limit", id)
                continue
            }
            guard let job = FullRenderJobs.submit(f, m, kind: .importDevelop, asker: .prefetch,
                                                  scheduler: model.scheduler, darkroom: model.darkroom) else { continue }
            prefetch = (id, job)
            event("prefetch submitted", id, job: job)
            return
        }
    }

    /// Why no prefetch is under way, for the check and the log.
    func diagnosis() -> [String: Any] {
        guard let model, let current else { return ["current": "none"] }
        var out: [String: Any] = ["inspecting": inspecting, "strip": strip.count, "prefetch": prefetch != nil]
        if let (_, m) = made(current) {
            out["current_made"] = m.ask.url.lastPathComponent
            out["current_on_disk"] = FullRenderJobs.reader(m) != nil
            out["current_file_exists"] = FileManager.default.fileExists(atPath: m.ask.url.path)
        } else { out["current_made"] = "none" }
        out["neighbours"] = neighbours(of: current).map { id -> [String: Any] in
            guard let (_, m) = made(id) else { return ["made": "none", "frame": model.library.frame(id)?.fileName ?? "?"] }
            return ["frame": model.library.frame(id)?.fileName ?? "?", "on_disk": FullRenderJobs.reader(m) != nil,
                    "in_flight": FullRenderJobs.flight(m.ask) != nil, "mb": m.estimatedBytes >> 20]
        }
        out["files"] = model.originals.copies.fulls.keys.sorted()
        out["carried"] = MacDevelopCarry.shared.frames.count
        out["carried_has_current"] = MacDevelopCarry.shared.frames.contains(current)
        return out
    }

    private func renderEnded(_ frame: LibraryFrame.ID, name: String, made: Bool) {
        if let p = prefetch, p.frame == frame, FullRenderJobs.flight(for: p.job) == nil {
            prefetch = nil
            event(made ? "prefetch made" : "prefetch ended unmade", frame, job: p.job)
            consider()
        }
        if tableJobs[frame] != nil {
            tableJobs[frame] = nil
            if !made { tableGaveUp.insert(name) }
            event(made ? "table render made" : "table render ended unmade", frame)
            table?.rendersChanged()
            updateRings()
        }
    }

    // MARK: - the Light Table

    /// The table's page opened: its films read what is kept, and ask for what is not.
    func attach(_ c: LightTableController) {
        table = c
        tableGaveUp = []
        c.canMakeFull = { [weak self] f in self?.model.map { FullRenderJobs.made(f, darkroom: $0.darkroom) != nil } ?? false }
        c.fullRender = { [weak self] f in self?.fullRef(f) }
        c.wantsFull = { [weak self] ids in self?.tableWants(ids) }
        c.letsGo = { [weak self] ids in self?.tableLetsGo(ids) }
        c.makesFullForExport = { [weak self] ids in await self?.makeAndWait(ids) }
        if pass == nil, let model {
            Task { [weak self, weak c] in
                guard let made = try? await FullDetail.shared(model.darkroom) else { return }
                self?.pass = made
                c?.rendersChanged()
            }
        }
    }

    /// A frame's full render kept on disk, as the table reads it; nil where there is none, or before the
    /// pass that reads it is made.
    func fullRef(_ f: LibraryFrame) -> LightTableFullRef? {
        guard let pass, let model, let m = FullRenderJobs.made(f, darkroom: model.darkroom), let reader = FullRenderJobs.reader(m) else { return nil }
        let finished = reader.header.finished
        return LightTableFullRef(url: m.ask.url, stamp: m.ask.stamp, adjustments: f.edit.adjustments,
                                 bytes: Int64(reader.header.fileBytes), longEdge: max(finished.width, finished.height), pass: pass)
    }

    /// Films on the table with nothing kept as large as they are shown: one job each, the first time.
    func tableWants(_ ids: Set<LibraryFrame.ID>) {
        guard let model, model.darkroom.makesPictures else { return }
        var asked = false
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard tableJobs[id] == nil, let f = model.library.frame(id) else { continue }
            if let m = FullRenderJobs.made(f, darkroom: model.darkroom) {
                let name = m.ask.url.lastPathComponent
                if FullRenderJobs.reader(m) != nil { table?.rendersChanged(); continue }      // kept meanwhile
                if tableGaveUp.contains(name) { continue }
                guard let job = FullRenderJobs.submit(f, m, kind: .fullView, asker: .table,
                                                      scheduler: model.scheduler, darkroom: model.darkroom) else {
                    tableGaveUp.insert(name)
                    continue
                }
                tableJobs[id] = job
                event("table render asked", id, job: job)
                asked = true
            } else if !f.develop.isBusy, !tableDevelops.contains(id), model.openSession(id) == nil,
                      model.darkroom.needsDevelop(f) {
                // No more to it than its preview, and nothing kept (or a develop whose file is missing,
                // `DevelopedPicture.isMissing`, or one of an edit it no longer has: a paste onto it, the
                // stale test Export uses since 2026-11-05): its own develop, asked for this one frame.
                tableDevelops.insert(id)
                model.develop(id)
                event("table develop asked", id)
                asked = true
            }
        }
        if asked { updateRings() }
    }

    /// Films off the table, or the table closed: their jobs that have not started go.
    func tableLetsGo(_ ids: Set<LibraryFrame.ID>) {
        guard let model else { return }
        for id in ids {
            guard let job = tableJobs[id], !FullRenderJobs.isRunning(job, in: model.scheduler) else { continue }
            tableJobs[id] = nil
            model.scheduler.cancel(job)
            event("table render cancelled: off the table before it started", id, job: job)
        }
        tableDevelops.subtract(ids)
        updateRings()
    }

    /// Before a contact sheet: the films it lacks, made, and waited for.
    func makeAndWait(_ ids: Set<LibraryFrame.ID>) async {
        tableWants(ids)
        guard let model else { return }
        for id in ids {
            if let job = tableJobs[id] { _ = await model.scheduler.outcome(of: job) }
        }
        // A preview develop asked: until it has landed (a minute at most).
        let end = Date().addingTimeInterval(60)
        while Date() < end, ids.contains(where: { model.library.frame($0)?.develop.isBusy == true }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The rings: each film's job, how far it is, read from the scheduler while any is under way.
    private func updateRings() {
        ringWatch?.cancel()
        ringWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let model = self.model else { return }
                var making: [LibraryFrame.ID: Double] = [:]
                for (frame, job) in self.tableJobs {
                    let s = model.scheduler.snapshots.first { $0.id == job }
                    if case .running(let p)? = s?.state { making[frame] = p.fraction } else { making[frame] = -1 }
                }
                for frame in self.tableDevelops {
                    switch model.library.frame(frame)?.develop {
                    case .developing(let p)?: making[frame] = p
                    case .queued?, .waiting?: making[frame] = -1
                    default: break
                    }
                }
                self.table?.setMaking(making)
                if making.isEmpty { self.tableDevelops = []; return }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}
#endif
