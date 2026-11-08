//  StockPreviews.swift — the pictures on Develop's film and paper cards.
//
//  design/v4 §2 and §6 (V5's Develop, step 1): each film card is the frame
//  developed through that film on the paper it was made for, each paper card
//  the frame through the chosen film on that paper. Which cards, and what each
//  is rendered from, are `StockPreviewRules`; this makes them, safely on a
//  host's memory, for the page's builder to draw:
//
//  - **Through the one scheduler, as the last of its jobs** (`JobKind.stockPreview`):
//    a card starts only when nothing else is queued, gives way at once to the
//    page's develop or anything else, and is budgeted like any job — one that
//    cannot fit waits. Nothing runs while the camera is open (the scheduler's
//    hold, and this service asks for nothing then).
//  - **One card in the scheduler at a time**, the next asked for when the last
//    has ended, from the cards on screen in the order they are shown — so a
//    card scrolled away is never asked for, the one running when it leaves is
//    cancelled, and each job is priced for exactly what it does.
//  - **The strip's picture is decoded once** (`StripSource`), at the meter's
//    size (`EngineRouter.cardPlan`) — and where it can be, not decoded at all: the
//    page's own develop decodes the same pixels, and that decode is made the
//    strip's size on the host as it passes (`EngineRouter.feedStrip`). A 48 MP
//    ProRAW's own decode for a strip took 6.2 s in the simulator, and a decode
//    under way cannot be stopped for the page's develop. Kept for as long as
//    the strip is (29 MB for 1,600 × 1,200, float32): an edit's cards are
//    opened from it, not from the file again. A card that has to decode is
//    priced for it; the rest for an open of what is already decoded. It goes
//    when the page leaves, and on a memory warning or a camera opening.
//  - **Each card is the live tier at its smallest** (800 px), made the size that
//    covers the card at 3× (`StockPreviewSize`). Every effect the frame has is
//    in it; what it leaves out by name is the film's edge and the date, which
//    are Format's (`StockPreviewRules`).
//  - **Cached by its key** (`StockPreviewKey`: the whole wire, the decode, the
//    file, the engine): in memory up to 12 MB, the card shown longest ago going
//    first, emptied on a memory warning and when a camera session starts; and
//    on disk beside the frame's previews (`Previews/Stocks`, `StorageTidy`'s
//    rules: 32 MB, with the frame, and a frame's cards of another source go).
//    Film Exposure is in the key and so is every setting that reaches the
//    engine; Edit's adjustments after the print are not on the wire and not in
//    it. A key that has moved shows the card's last picture under the ring
//    until the new one lands: never blank.
//  - **The log**: one record a strip's run, as a job's (`job` `start`, `end`,
//    kind `stockStrip`): how many cards, from where, each card's time, the
//    footprint, the budget. The cards' own records stay in the scheduler's
//    (and a debug build's `scheduler-log.jsonl`), not one log line each.
//
//  Not seen on a host: the times and the footprint are the simulator's
//  (README, "Develop's strips").

import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers
import os

/// What a card shows.
enum StockPreviewState: Equatable {
    /// Not made yet for the frame as it stands: the stock's swatch and the
    /// ring — over the card's last picture, where it has one.
    case rendering(previous: UIImage?)
    case ready(UIImage)
    /// Nothing to make it from here — no engine, an
    /// original that cannot be read — or the engine failed: the swatch.
    case failed

    var image: UIImage? {
        switch self {
        case .ready(let image): image
        case .rendering(let previous): previous
        case .failed: nil
        }
    }
    var isRendering: Bool { if case .rendering = self { true } else { false } }
}

/// One frame's two strips, as its page shows them.
@MainActor
@Observable
final class StockStrip {
    let frameID: LibraryFrame.ID
    /// The edit the cards are of: the page's, as it stands. Every setting that
    /// reaches the engine is in a card's key, so a change asks for the cards on
    /// screen again — the newest replacing what was asked before.
    var edit: FrameEdit {
        didSet {
            var before = oldValue
            before.adjustments = edit.adjustments
            if edit != before { owner?.editChanged(self) }
        }
    }
    /// What each card shows, by its id.
    private(set) var states: [String: StockPreviewState] = [:]
    /// The cards on screen, in the order they are shown.
    private(set) var shown: [StockPreviewCard] = []
    @ObservationIgnored weak var owner: StockPreviews?
    /// Each shown card's plan for the edit as it stands (`EngineRouter.cardPlan`); nil: none can be made.
    @ObservationIgnored fileprivate var plans: [String: EngineRouter.CardPlan?] = [:]
    @ObservationIgnored fileprivate var lastShown = Date.distantPast
    @ObservationIgnored fileprivate var settling: Task<Void, Never>?
    @ObservationIgnored fileprivate var editPending = false

    init(frameID: LibraryFrame.ID, edit: FrameEdit) {
        self.frameID = frameID
        self.edit = edit
    }

    /// The film strip: every film, each on the paper it was made for.
    var filmCards: [StockPreviewCard] { StockPreviewRules.filmStrip() }
    /// The paper strip under the chosen film: none under a slide, the silver
    /// paper alone under a black-and-white film.
    var paperCards: [StockPreviewCard] { StockPreviewRules.paperStrip(under: edit.params.filmStock) }

    func state(_ card: StockPreviewCard) -> StockPreviewState { states[card.id] ?? .rendering(previous: nil) }

    /// How far the card being made is, where it is the one: for the ring.
    func progress(_ card: StockPreviewCard) -> Double? { owner?.progress(self, card) }

    /// The cards on screen now, in the order they are shown: they are made
    /// first, and one scrolled away is not — the one being made is cancelled.
    func show(_ cards: [StockPreviewCard]) {
        // The same cards again — the page back from the camera, a scroll that moved nothing: whatever is owed is asked for.
        guard cards.map(\.id) != shown.map(\.id) else { owner?.resume(); return }
        shown = cards
        forgetUnshown()
        lastShown = Date()
        owner?.shownChanged(self)
    }

    /// The page has gone: nothing of it is made any more.
    func leave() { owner?.leave(self) }

    /// Ask again for what could not be made: the original has come from Photos.
    func refresh() {
        plans = [:]
        for (id, state) in states where state == .failed { states[id] = .rendering(previous: nil) }
        owner?.retry(self)
    }

    fileprivate func set(_ card: StockPreviewCard, _ state: StockPreviewState) {
        if states[card.id] != state { states[card.id] = state }
    }

    /// Every card not on screen forgets its picture.
    fileprivate func forgetUnshown() {
        let on = Set(shown.map(\.id))
        for id in states.keys where !on.contains(id) { states[id] = nil }
    }
}

@MainActor
@Observable
final class StockPreviews {
    /// Decoded pixels kept in memory: 72 cards of a 4:3 frame (336 × 252 × 4 B),
    /// both of a frame's strips and the paper strips of a few films after them.
    /// 12 MB (36 cards) until 2026-10-17 held less than one frame's two strips,
    /// so a film change pushed the film strip out to make the paper strip.
    static let memoryLimit = 24 << 20

    @ObservationIgnored private let scheduler: RenderQueue
    @ObservationIgnored private let darkroom: EngineRouter
    @ObservationIgnored private let library: FrameCatalog
    /// `Previews/Stocks`; nil keeps nothing on disk (the drawings' library, a test).
    @ObservationIgnored let folder: URL?
    @ObservationIgnored private var strips: [LibraryFrame.ID: StockStrip] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "strips")

    // memory
    private struct Kept { var image: UIImage; var bytes: Int; var used: UInt64 }
    @ObservationIgnored private var memory: [String: Kept] = [:]
    @ObservationIgnored private(set) var memoryBytes = 0
    @ObservationIgnored private var uses: UInt64 = 0
    // disk
    @ObservationIgnored private var reading: Set<String> = []
    @ObservationIgnored private var notOnDisk: Set<String> = []
    @ObservationIgnored private var sourcesWritten: Set<String> = []
    // the card being made
    private struct InFlight {
        var job: UUID
        var frame: LibraryFrame.ID
        var card: StockPreviewCard
        var key: String
        var source: String
    }
    @ObservationIgnored private var inFlight: InFlight?
    /// Cards whose make failed, by memory key: not asked for again until their key moves.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored let source = StripSource()
    // After pressure, RAW pixels are refilled by a priced foreground canvas
    // job before background cards resume. Their previous images stay visible.
    @ObservationIgnored private var awaitsForegroundRAW = false
    @ObservationIgnored private var sourceRefillRequested = false
    /// A visible RAW strip lost its shared decode. Refill through the page's
    /// priced foreground job, rather than leaving the cards waiting for an
    /// edit that the user may never make, or decoding in an unpriced task.
    @ObservationIgnored var onNeedsSource: ((LibraryFrame.ID) -> Bool)?
    @ObservationIgnored private var run: Run?

    init(scheduler: RenderQueue, darkroom: EngineRouter, library: FrameCatalog, folder: URL?) {
        self.scheduler = scheduler
        self.darkroom = darkroom
        self.library = library
        self.folder = folder
        source.whenReady { [weak self] in
            Task { @MainActor [weak self] in self?.pump() }
        }
        observeFrontend()
    }

    /// A strip can appear before the old camera session relinquishes its
    /// hold. Lifting that hold must wake the producer as well as the queue;
    /// there may be no card job queued yet, and no later scroll to wake it.
    private func observeFrontend() {
        withObservationTracking {
            _ = scheduler.frontend
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrontend()
                self?.pump()
            }
        }
    }

    /// The frame's strips; the same object for as long as a page holds it.
    func strip(for frameID: LibraryFrame.ID) -> StockStrip {
        if let s = strips[frameID] { return s }
        let s = StockStrip(frameID: frameID, edit: library.frame(frameID)?.edit ?? .default)
        s.owner = self
        strips[frameID] = s
        feed(s)
        return s
    }

    /// The page's develop decodes the frame anyway: the strip takes that
    /// decode, made its size (`EngineRouter.feedStrip`), when the pixels are the
    /// same. Told whenever what the cards are opened from may have moved.
    private func feed(_ strip: StockStrip) {
        guard let frame = library.frame(strip.frameID) else { return }
        darkroom.feedStrip(source, frame: frame.id, plan: darkroom.cardPlan(frame, edit: strip.edit))
    }

    // MARK: what the strips tell

    fileprivate func shownChanged(_ strip: StockStrip) {
        if let f = inFlight, f.frame == strip.frameID, !strip.shown.contains(f.card) {
            scheduler.cancel(f.job)                       // scrolled away
        }
        pump()
    }

    fileprivate func resume() { pump() }

    fileprivate func retry(_ strip: StockStrip) {
        let prefix = strip.frameID.uuidString + "|"
        failed = Set(failed.filter { !$0.hasPrefix(prefix) })
        feed(strip)
        shownChanged(strip)
    }

    fileprivate func editChanged(_ strip: StockStrip) {
        strip.plans = [:]
        strip.editPending = true
        strip.settling?.cancel()
        // The canvas gets the first turn. Moving a dial does not price and
        // prepare a new set of material pairs for every intermediate value.
        if let f = inFlight, f.frame == strip.frameID { scheduler.cancel(f.job) }
        strip.settling = Task { [weak self, weak strip] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, let strip, self.strips[strip.frameID] === strip else { return }
            strip.editPending = false; strip.settling = nil
            self.feed(strip)
            self.pump()
        }
    }

    fileprivate func leave(_ strip: StockStrip) {
        guard strips[strip.frameID] === strip else { return }
        strip.settling?.cancel(); strip.settling = nil; strip.editPending = false
        strips[strip.frameID] = nil
        darkroom.feedStrip(nil, frame: strip.frameID, plan: nil)
        if let f = inFlight, f.frame == strip.frameID { scheduler.cancel(f.job) }
        if run?.frame == strip.frameID { endRun("left") }
        if strips.isEmpty { source.drop() }
        hold(sparing: nil)
    }

    fileprivate func progress(_ strip: StockStrip, _ card: StockPreviewCard) -> Double? {
        guard let f = inFlight, f.frame == strip.frameID, f.card == card,
              let snapshot = scheduler.snapshots.first(where: { $0.id == f.job }),
              case .running(let p) = snapshot.state else { return nil }
        return p.fraction
    }

    /// A memory warning, or a camera session starting: what is in memory goes —
    /// the cache, the strip's decode, the pictures of cards not on screen — and
    /// the card being made is cancelled. With the camera open nothing more is
    /// asked for; otherwise the cards on screen are asked for again.
    func trim() {
        memory = [:]
        memoryBytes = 0
        source.drop()
        awaitsForegroundRAW = true
        sourceRefillRequested = false
        for strip in strips.values { strip.forgetUnshown() }
        if let f = inFlight { scheduler.cancel(f.job) }
        if !scheduler.frontend.cameraLive { pump() }
    }

    /// The page's own develop of `frame` has ended: the foreground decode the
    /// cards were waiting for has had its turn. Where it left the strip no
    /// pixels (`source`), the wait is over — a card decodes for itself again,
    /// priced and last of the queue as always. Without this the posture set by
    /// `trim()` never ended, and a RAW frame's cards waited for a decode that
    /// never came: never rendered at all (the owner's reference device, 2026-10-15 —
    /// a session of strip runs, no card made, the posture on since the
    /// launch's own camera).
    func foregroundDeveloped(_ frame: LibraryFrame.ID) {
        guard awaitsForegroundRAW, strips[frame] != nil else { return }
        awaitsForegroundRAW = false
        sourceRefillRequested = false
        pump()
    }

    /// Frames that left the library: their cards go, from memory and disk.
    func discard(_ frames: [LibraryFrame.ID]) {
        let gone = Set(frames.map(\.uuidString))
        for key in memory.keys where gone.contains(String(key.prefix(36))) {
            memoryBytes -= memory[key]?.bytes ?? 0
            memory[key] = nil
        }
        for id in frames {
            if let s = strips[id] { leave(s) }
        }
        guard let folder else { return }
        Task.detached(priority: .utility) { StorageTidy.discardCards(of: frames, in: folder) }
    }

    // MARK: the work

    /// The next card to make, or to read back: from the strips shown last, in
    /// the order their cards are on screen. One card in the scheduler at a time.
    private func pump() {
        guard inFlight == nil, !scheduler.frontend.cameraLive, scheduler.frontend.scene == .active else { return }
        for strip in strips.values.sorted(by: { $0.lastShown > $1.lastShown }) {
            guard !strip.editPending, let frame = library.frame(strip.frameID) else { continue }
            for card in strip.shown {
                let plan: EngineRouter.CardPlan?
                if let known = strip.plans[card.id] { plan = known } else {
                    plan = darkroom.cardPlan(frame, edit: StockPreviewRules.edit(card, from: strip.edit))
                    strip.plans[card.id] = plan
                }
                guard let plan else { strip.set(card, .failed); continue }
                let id = Self.memoryKey(frame.id, plan.key)
                if let kept = memory[id] {
                    uses += 1
                    memory[id]?.used = uses
                    if strip.state(card) != .ready(kept.image) { run?.fromMemory += 1 }
                    strip.set(card, .ready(kept.image))
                    continue
                }
                if failed.contains(id) { strip.set(card, .failed); continue }
                // Not this card's picture: the last one under the ring until it is.
                if case .ready(let old) = strip.state(card) { strip.set(card, .rendering(previous: old)) }
                if reading.contains(id) { continue }
                if let folder, !notOnDisk.contains(id) {
                    let file = StorageTidy.cardFile(frame: frame.id, source: plan.source, key: plan.key, in: folder)
                    if FileManager.default.fileExists(atPath: file.path) {
                        beginRun(frame.id, strip: strip, canvas: plan.canvas)
                        read(file, id: id)
                        continue
                    }
                    notOnDisk.insert(id)
                }
                // An original in Photos that is not here yet: the page's own develop brings it.
                if darkroom.needsBringing(frame, edit: strip.edit) { continue }
                let containsRAW = frame.developsFromRAW || (plan.piece?.pictures.contains(where: \.isRAW) ?? false)
                // A RAW whose proxy is here is opened from it: there is no foreground decode to wait for.
                if awaitsForegroundRAW, containsRAW, !source.holds(plan.strip),
                   !(plan.piece == nil && darkroom.hasProxy(frame, decode: strip.edit.decode)) {
                    if !sourceRefillRequested {
                        sourceRefillRequested = onNeedsSource?(frame.id) ?? false
                    }
                    continue
                }
                if make(card, of: frame, strip: strip, plan: plan) { return }
                strip.set(card, .failed)
            }
        }
        // Nothing left to make: the run is over.
        if run != nil, reading.isEmpty { endRun("done") }
    }

    private func make(_ card: StockPreviewCard, of frame: LibraryFrame, strip: StockStrip, plan: EngineRouter.CardPlan) -> Bool {
        let decodes = !source.holds(plan.strip)
        let edit = StockPreviewRules.edit(card, from: strip.edit)
        let job = RenderJob(frameID: frame.id, kind: .stockPreview, tier: .live, canvas: plan.canvas,
                            what: StockCatalog.shared.pairText(edit.params), decodesOriginal: decodes, bandable: false,
                            original: decodes ? darkroom.openSize(frame, edit: edit) : nil, printLayers: plan.layers.count,
                            opens: plan.opens, slot: card.slot)
        guard darkroom.prepareCard(job, frame: frame, edit: edit, plan: plan, strip: source, decodes: decodes) else { return false }
        beginRun(frame.id, strip: strip, canvas: plan.canvas)
        let id = scheduler.submit(job)
        inFlight = InFlight(job: id, frame: frame.id, card: card, key: plan.key, source: plan.source)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.scheduler.outcome(of: id)
            self.ended(id, outcome)
        }
        return true
    }

    private func ended(_ id: UUID, _ outcome: JobOutcome) {
        guard let f = inFlight, f.job == id else { darkroom.forget(id); return }
        inFlight = nil
        let image = darkroom.takeCard(id)
        darkroom.forget(id)
        let records = scheduler.records.filter { $0.jobID == id }
        run?.add(records)
        let memoryID = Self.memoryKey(f.frame, f.key)
        switch outcome {
        case .finished:
            if let image {
                landed(UIImage(cgImage: image), id: memoryID, frame: f.frame, key: f.key, source: f.source, cg: image)
                run?.rendered += 1
            } else {
                failed.insert(memoryID)
                run?.failed += 1
                log.error("a card was made and its picture was not")
            }
        case .failed(let message):
            if message == StripSource.givenBack {
                // Priced as an open of a decode that has since been given back: asked again, priced to decode.
                run?.askedAgain += 1
            } else {
                failed.insert(memoryID)
                run?.failed += 1
                run?.lastFailure = message
            }
        case .cancelled:
            run?.cancelled += 1
        }
        pump()
    }

    /// A card's picture: into memory, onto every strip whose card it is, and to disk.
    private func landed(_ image: UIImage, id: String, frame: LibraryFrame.ID, key: String, source: String, cg: CGImage?) {
        remember(image, id: id)
        for strip in strips.values where strip.frameID == frame {
            for card in strip.shown where strip.plans[card.id]??.key == key { strip.set(card, .ready(image)) }
        }
        guard let cg, let folder else { return }
        let file = StorageTidy.cardFile(frame: frame, source: source, key: key, in: folder)
        notOnDisk.remove(id)
        let firstOfSource = sourcesWritten.insert(frame.uuidString + source).inserted
        Task.detached(priority: .utility) {
            Self.write(cg, to: file, in: folder)
            // Another file, size or decode of this frame is another picture: its cards go.
            if firstOfSource { StorageTidy.dropCards(of: frame, otherThan: source, in: folder) }
        }
    }

    private func remember(_ image: UIImage, id: String) {
        let bytes = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        uses += 1
        if let old = memory[id] { memoryBytes -= old.bytes }
        memory[id] = Kept(image: image, bytes: bytes, used: uses)
        memoryBytes += bytes
        // The card used longest ago goes first.
        while memoryBytes > Self.memoryLimit, let oldest = memory.min(by: { $0.value.used < $1.value.used }) {
            memoryBytes -= oldest.value.bytes
            memory[oldest.key] = nil
        }
    }

    private func read(_ file: URL, id: String) {
        reading.insert(id)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { Self.load(file) }.value
            guard let self else { return }
            self.reading.remove(id)
            if let image {
                self.remember(image, id: id)
                self.run?.fromDisk += 1
            } else {
                self.notOnDisk.insert(id)
            }
            self.pump()
        }
    }

    /// A strip's run begins with its first card made or read back.
    private func beginRun(_ frame: LibraryFrame.ID, strip: StockStrip, canvas: PixelSize) {
        if let r = run, r.frame == frame { return }
        if run != nil { endRun("done") }
        let r = Run(frame: frame, asked: strip.shown.count, canvas: canvas)
        run = r
        Log.stripBegan(r.id, frame: frame, cards: r.asked, canvas: canvas)
    }

    /// The cards on disk held to what the renders leave of the previews' limit,
    /// sparing the frame on the page.
    private func hold(sparing frame: LibraryFrame.ID?) {
        guard let folder else { return }
        let previews = folder.deletingLastPathComponent(), limit = library.storage.previewCopiesLimit
        Task.detached(priority: .utility) { StorageTidy.holdCards(sharing: previews, limit: limit, sparing: frame) }
    }

    private func endRun(_ outcome: String) {
        guard var r = run else { return }
        run = nil
        r.outcome = outcome
        let fields = r.fields(memoryBytes: memoryBytes)
        if r.rendered + r.fromDisk + r.cancelled + r.failed > 0 { Log.stripEnded(r.id, outcome: outcome, fields: fields) }
        hold(sparing: r.frame)
    }

    static func memoryKey(_ frame: LibraryFrame.ID, _ key: String) -> String { frame.uuidString + "|" + key }

    // MARK: files (any thread)

    nonisolated private static func write(_ image: CGImage, to file: URL, in folder: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var dir = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true        // made again whenever it is wanted
        try? dir.setResourceValues(values)
        // Written whole in the temporary files and moved in: a card is never read half written, and
        // one the app was ended in the middle of is the system's to clear.
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("card-" + UUID().uuidString + ".jpg")
        guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: partial, to: file)
        } else {
            try? FileManager.default.removeItem(at: partial)
        }
    }

    /// A card from disk; its file is dated now, which is what the limit reads.
    nonisolated private static func load(_ file: URL) -> UIImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return UIImage(cgImage: image)
        }
    }
}

/// A strip's run: from its first card asked for to the last made, for the log.
private struct Run {
    let id = UUID()
    let frame: LibraryFrame.ID
    let asked: Int
    let canvas: PixelSize
    let began = Date()
    let footprintBefore = MemoryProbe.footprint()
    var outcome = ""
    var rendered = 0, fromMemory = 0, fromDisk = 0, cancelled = 0, failed = 0, askedAgain = 0, gaveWay = 0
    var seconds: [Double] = []
    var decodeSeconds: Double?
    var peakFootprint: UInt64 = 0
    var predictedPeak: UInt64 = 0
    var budget: UInt64?
    var waits: [String] = []
    var meterEV: [Double] = []
    var opened: PixelSize?
    /// Why the last card that failed did, in the engine's or the host's words.
    var lastFailure: String?
    /// How the cards' frame was opened ("proxy RAW 8 [...]", "the strip's decode").
    var decodedBy: String?

    init(frame: LibraryFrame.ID, asked: Int, canvas: PixelSize) {
        self.frame = frame
        self.asked = asked
        self.canvas = canvas
    }

    mutating func add(_ records: [JobRecord]) {
        for r in records {
            if r.outcome.contains("gave way") { gaveWay += 1 }
            predictedPeak = max(predictedPeak, r.predictedPeakBytes)
            budget = min(budget ?? r.budgetBytes, r.budgetBytes)
            for w in r.waits where !waits.contains(w) { waits.append(w) }
            guard r.outcome == "done" else { continue }
            if let s = r.measuredSeconds { seconds.append(s) }
            if let m = r.measurement {
                peakFootprint = max(peakFootprint, m.peakFootprint)
                if m.decodedBy != "the strip's decode", m.decodeSeconds > 0 { decodeSeconds = (decodeSeconds ?? 0) + m.decodeSeconds }
                if let ev = m.autoExposureEV { meterEV.append(ev) }
                if let o = m.opened { opened = o }
                if let by = m.decodedBy, by != "the strip's decode" { decodedBy = by }
            }
        }
    }

    func fields(memoryBytes: Int) -> [String: Any] {
        let sorted = seconds.sorted()
        func ms(_ s: Double?) -> Int? { s.map { Int(($0 * 1000).rounded()) } }
        var job: [String: Any] = [
            "measuredSeconds": seconds.reduce(0, +), "megapixels": canvas.megapixels, "waits": waits, "predictedPeakBytes": predictedPeak,
        ]
        if let budget { job["budgetBytes"] = budget }
        if peakFootprint > footprintBefore { job["measuredPeakBytes"] = peakFootprint - footprintBefore }
        var f: [String: Any] = [
            "frame": Log.frame(frame), "cards": asked, "made": rendered, "from_memory": fromMemory, "from_disk": fromDisk,
            "cancelled": cancelled, "failed": failed, "gave_way": gaveWay, "asked_again": askedAgain,
            "seconds": (Date().timeIntervalSince(began) * 1000).rounded() / 1000,
            "footprint_before_mb": Int(footprintBefore >> 20), "memory_cache_kb": memoryBytes >> 10, "job": job,
        ]
        if let lastFailure { f["last_failure"] = String(lastFailure.prefix(240)) }
        if let decodedBy { f["decoded_by"] = decodedBy }
        if !sorted.isEmpty {
            f["card_ms"] = ["min": ms(sorted.first)!, "median": ms(sorted[sorted.count / 2])!, "max": ms(sorted.last)!]
        }
        if peakFootprint > 0 { f["footprint_peak_mb"] = Int(peakFootprint >> 20) }
        if let d = decodeSeconds { f["decode_ms"] = ms(d) }
        if let o = opened { f["opened"] = "\(o.width)x\(o.height)" }
        if let lo = meterEV.min(), let hi = meterEV.max() { f["meter_ev"] = [lo, hi].map { ($0 * 1000).rounded() / 1000 } }
        return f
    }
}
