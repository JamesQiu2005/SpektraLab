//  ExportService.swift — taking pictures out: one job per frame, through the scheduler.
//
//  Export develops again from the original, at the size the recipe names
//  (E1, E2). Each frame is one `.export` job: full tier, the original decoded
//  first, in whatever mode the scheduler finds memory for — and if it finds
//  none, the job waits and the sheet says why. It keeps going when the sheet
//  is closed; Exporting shows the engine's own stages (Decode, Film, Print,
//  Scan, Save).
//
//  **An export ends in a file** (2026-10-08; the owner: "real export must
//  happen"). What a frame's job is made of is worked out first (`ExportPlan`):
//  how large the original is decoded for the size the recipe names, what the
//  host cuts of it, what the engine renders. The engine's host then takes the
//  render into the recipe's colour space, at the file's depth, and writes it
//  (`EngineHost.deliver`, `ExportWriter`) into a folder of the batch's own
//  under the app's temporary files; and from there the file goes where the
//  recipe sends it — added to Photos here, handed to the system's own sheet
//  for Files and for Share when the batch ends (`ExportingSheet`).
//
//  - **The size on the sheet is the file's.** `outputSize` is the plan's, and
//    once a file is written the item carries the size read back from it.
//  - **A frame whose original cannot be read goes out at its preview copy's
//    size, named as that** (`exportsPreview`): an original that is away.
//    Never called full (AGENTS.md).
//  - **An original that stays in Photos is brought here first** (`Originals`,
//    the working copies): as its frame's turn comes, not for the whole batch
//    at once, so a batch holds one original at a time. One that cannot be
//    brought is not saved, and its row says why.
//  - **Nothing is said to be saved that was not.** A file that could not be
//    written is `notSaved`, with why.
//
//  Over the simulated engine — the drawings' own library — an export keeps
//  the measured engine's time and walks its stages, with no pixels to save;
//  the sheet says so (`wroteFiles`).

import Foundation
import Observation
import os

@MainActor
@Observable
final class ExportService {
    struct Item: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case waiting(WaitReason)
            case running(RenderProgress)
            /// Developed, and — where files are written — the file is where
            /// the recipe sends it, or ready for the system's sheet to take.
            case done
            case stopped
            /// The develop itself failed.
            case failed(String)
            /// Developed, and no file where it was to go: why, in the page's words.
            case notSaved(String)
        }
        let id: LibraryFrame.ID
        var fileName: String
        var size: PixelSize
        var picture: PictureRef
        var state: State = .waiting(.queued)
        /// The frame's full size was larger than this device develops: the file
        /// says the size it was made at, and is never called full.
        var cappedFrom: PixelSize?
        /// What held it there: free's 12 MP, or this device's memory.
        var limit: Limit? = nil
        /// The file, once written, while it is still the app's to hand on
        /// (Files, Share). Nil once Photos has taken it.
        var file: URL?
    }

    struct Batch: Equatable, Sendable {
        var recipe: ExportRecipe
        var items: [Item]
        var index = 0
        /// Where this batch's files are written. Nil for a batch that writes
        /// none (the snapshot harness's, the simulation's).
        var folder: URL? = nil
        var current: Item? { items.indices.contains(index) ? items[index] : nil }
        /// "1 of 1".
        var countText: String { L("\(min(index + 1, items.count)) of \(items.count)") }
        var finished: Bool { items.allSatisfy { if case .waiting = $0.state { false } else if case .running = $0.state { false } else { true } } }
        /// The files still the app's to hand on: what Files or Share takes.
        var files: [URL] { items.compactMap { $0.state == .done ? $0.file : nil } }
    }

    /// A frame's film edge, as an export needs it: the cut, the turn, and the
    /// film's canvas round a framing of any size. The app's model answers, as
    /// it owns the film's layout (`AppServices.exportFilm`).
    struct Film {
        var ask: ExportPlan.Ask.Film
        var canvas: (PixelSize) -> PixelSize?
    }

    /// What one frame's export is made of.
    struct Prepared {
        var plan: ExportPlan
        /// The recipe's size, or the preview copy's where that is all there is.
        var size: ExportRecipe.Size
        /// The file to decode; nil where there is none to read.
        var source: URL?
        var isRAW: Bool
        var fromPreview: Bool
    }

    @ObservationIgnored private let library: FrameCatalog
    @ObservationIgnored private let scheduler: RenderQueue
    @ObservationIgnored private let darkroom: EngineRouter?
    @ObservationIgnored private var jobs: [UUID: LibraryFrame.ID] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var planned: (frame: LibraryFrame, size: ExportRecipe.Size, cap: Double, cropIsFrame: Bool, made: Prepared)?
    /// Settings' *Crop re-maps the frame* (`AppSettings.cropRemapsFrame`), set by the app's model: the
    /// film's size the plan follows the cut from is the one the develop page was sent
    /// (`FrameEdit.wireFilmFormatMM`), so an export is at the page's pitch.
    @ObservationIgnored var cropIsFrame: () -> Bool = { false }
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "export")

    private(set) var batch: Batch?
    /// Whether an export here ends in a file: where the engine makes pictures.
    var wroteFiles: Bool { scheduler.engine.makesPictures }

    /// `darkroom` nil is a service with no engine to hand anything to (a test).
    init(library: FrameCatalog, scheduler: RenderQueue, darkroom: EngineRouter? = nil) {
        self.library = library
        self.scheduler = scheduler
        self.darkroom = darkroom
        // Whatever an earlier launch left: a batch's files are its own, for as long as its sheet is.
        let folder = Self.folder
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    var isExporting: Bool { batch.map { !$0.finished } ?? false }

    /// Where every batch's folder is.
    nonisolated static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true) }

    /// The film a frame is exported in, when it wears a film edge. Set by the
    /// app's model.
    @ObservationIgnored var film: (LibraryFrame) -> Film? = { _ in nil }

    // MARK: what an export will make

    /// A frame the app can only export from its preview copy: its original is
    /// away. (One that stays in Photos is not away: it is brought into the
    /// working copies as its export begins, `run`.)
    func exportsPreview(_ frame: LibraryFrame) -> Bool {
        !frame.original.isAvailable
    }

    /// The frame whose original an export is reading now: its working copy is
    /// not cleared from under it (`WorkingCopies.inUse`).
    var reading: LibraryFrame.ID? { isExporting ? batch?.current?.id : nil }

    /// What `recipe` makes of `frame` on this device, worked out before
    /// anything is decoded.
    func prepared(_ frame: LibraryFrame, _ recipe: ExportRecipe, ceiling: Double? = nil) -> Prepared {
        let fromPreview = exportsPreview(frame)
        let size = fromPreview ? ExportRecipe.Size.preview : recipe.size
        // This device's ceiling: a long or short edge is held to it.
        let cap = ceiling ?? DevicePolicy.current.developCapMegapixels
        let cropIsFrame = self.cropIsFrame()
        if let planned, planned.frame == frame, planned.size == size, planned.cap == cap, planned.cropIsFrame == cropIsFrame { return planned.made }
        let filmFormatMM = frame.isPair ? frame.edit.params.filmFormatMM
            : frame.edit.wireFilmFormatMM(photo: frame.originalSize, cropIsFrame: cropIsFrame)
        var ask = ExportPlan.Ask(source: fromPreview ? frame.previewSize : frame.originalSize, photo: frame.edit.geometry,
                                 filmFormatMM: filmFormatMM, size: size,
                                 capMegapixels: cap)
        // Edit's crop of the finished picture; a pair's is its own page's, and has none.
        if !frame.isPair { ask.printCrop = frame.edit.printCrop }
        var canvas: (PixelSize) -> PixelSize? = { _ in nil }
        if let film = film(frame) {
            ask.film = film.ask
            canvas = film.canvas
        }
        // A pair is exported from its two frames' own files (`EngineRouter.exportSource`); a photograph
        // from its original — a Photos frame's working copy, where that has been brought (`run`) —
        // or, while the original is away, from the picture the frame keeps.
        let source = frame.isPair ? darkroom?.exportSource(frame)
            : frame.isDemo ? nil : (fromPreview ? nil : frame.developSource) ?? frame.picture.fileURL
        let made = Prepared(plan: ExportPlan.make(ask, canvas: canvas), size: size,
                            source: source.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
                            isRAW: fromPreview ? false : frame.developsFromRAW, fromPreview: fromPreview)
        planned = (frame, size, cap, cropIsFrame, made)
        return made
    }

    /// The size a recipe makes from a frame on this device: the file's
    /// pixels. A frame in its film exports the film: the border is part of
    /// the file.
    func outputSize(_ frame: LibraryFrame, _ recipe: ExportRecipe) -> PixelSize { prepared(frame, recipe).plan.output }

    /// This device's cap, not the recipe, sets the file's size.
    func isCapped(_ frame: LibraryFrame, _ recipe: ExportRecipe) -> Bool { prepared(frame, recipe).plan.isCapped }

    /// What held the file under the size the recipe names, where something did:
    /// this device's memory.
    enum Limit { case device }
    func limit(_ frame: LibraryFrame, _ recipe: ExportRecipe) -> Limit? {
        isCapped(frame, recipe) ? .device : nil
    }

    // MARK: running

    func start(_ frameIDs: [LibraryFrame.ID], recipe: ExportRecipe) {
        guard !frameIDs.isEmpty else { return }
        stop()
        discardFiles()
        var taken = Set<String>()
        let items: [Item] = frameIDs.compactMap { id in
            guard let f = library.frame(id) else { return nil }
            let made = prepared(f, recipe)
            // An original that cannot be read exports at the preview size, named as such.
            var r = recipe
            r.size = made.size
            return Item(id: id, fileName: Self.free(r.fileName(stem: f.stem), among: &taken), size: made.plan.output, picture: f.picture,
                        cappedFrom: made.plan.isCapped ? f.originalSize : nil, limit: limit(f, r))
        }
        guard !items.isEmpty else { return }
        batch = Batch(recipe: recipe, items: items,
                      folder: wroteFiles ? Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true) : nil)
        worker = Task { [weak self] in await self?.run() }
    }

    /// Two frames of one name in a batch are two files: "IMG_0001.jpg", "IMG_0001-2.jpg".
    private static func free(_ name: String, among taken: inout Set<String>) -> String {
        var candidate = name, n = 1
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while !taken.insert(candidate.lowercased()).inserted {
            n += 1
            candidate = "\(stem)-\(n)" + (ext.isEmpty ? "" : "." + ext)
        }
        return candidate
    }

    /// Stop: the frame under way is cancelled and the rest are not started.
    func stop() {
        worker?.cancel(); worker = nil
        for id in jobs.keys { scheduler.cancel(id) }
        jobs = [:]
        guard var b = batch else { return }
        for i in b.items.indices {
            switch b.items[i].state {
            case .waiting, .running: b.items[i].state = .stopped
            default: break
            }
        }
        batch = b
    }

    /// The sheet is done with the batch: its files, wherever they have not
    /// been taken, go with it.
    func clear() {
        guard !isExporting else { return }
        discardFiles()
        batch = nil
    }

    private func discardFiles() {
        guard let folder = batch?.folder else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    private func run() async {
        guard let count = batch?.items.count, let recipe = batch?.recipe else { return }
        let folder = batch?.folder
        for i in 0..<count {
            guard !Task.isCancelled, let item = batch?.items[i], var frame = library.frame(item.id) else { return }
            batch?.index = i
            let began = Date()
            var fetched: Double?
            // An original that stays in Photos is brought here before its export is planned from it.
            if let darkroom, darkroom.isAway(frame) {
                let brought = await darkroom.bring(frame, asked: true)
                guard !Task.isCancelled else { return }
                fetched = Date().timeIntervalSince(began)
                guard brought == .here, let now = library.frame(item.id) else {
                    set(i, .notSaved(brought.words))
                    Log.exported(frame, recipe: recipe, made: nil, outcome: "not saved", why: brought.words,
                                 seconds: Date().timeIntervalSince(began), brought: fetched)
                    continue
                }
                frame = now
            }
            // A RAW is held to its file before its export is planned from it. A frame a build
            // before 2026-10-12 took for its embedded preview's size was written at that size —
            // 1,616 x 1,080 of a 33 MP file — while the whole RAW was decoded with a plan for the
            // small one, 4 GB where half a gigabyte was planned (`Originals.holdToItsFile`).
            if let darkroom, await darkroom.holdToItsFile(frame) {
                guard !Task.isCancelled else { return }
                if let now = library.frame(item.id) { frame = now }
            }
            // Planned afresh: what the sheet planned may be of a file that was not here then.
            planned = nil
            let made = prepared(frame, recipe)
            // The log's line for this item, once it has ended.
            func noted(_ outcome: String, _ why: String? = nil, file: URL? = nil) {
                Log.exported(frame, recipe: recipe, made: made, outcome: outcome, why: why,
                             seconds: Date().timeIntervalSince(began), file: file, brought: fetched)
            }
            // A frame the host cuts renders in bands like any other; one whose
            // cut is left to the engine is one piece: planned whole, or it waits.
            // A pair whose frames print as their own is that many prints more of the same negative.
            let job = RenderJob(frameID: item.id, kind: .export, tier: made.fromPreview ? .preview : .full,
                                canvas: made.plan.engineCanvas, what: item.fileName, decodesOriginal: true,
                                bandable: !made.plan.engineCuts, original: made.plan.decoded,
                                printLayers: darkroom?.printLayers(frame, edit: frame.edit) ?? 0)
            if let folder {
                guard let source = made.source, let darkroom else {
                    // A pair with an empty hole, or one whose frame has left the library, is
                    // not exported (the desktop's answer B9), and says which it is.
                    let why = frame.pair.flatMap { PairWords.exportRefusal($0) { [library] in library.frame($0.frame) != nil } }
                    set(i, .notSaved(why ?? "Nothing to develop it from"))
                    noted("not saved", why ?? "Nothing to develop it from")
                    continue
                }
                // Every export bakes Edit's Light, Curve and Colour (design/v5 §3.5): the frame's layer as it stands.
                let order = ExportOrder(format: recipe.format, colour: recipe.colour, quality: recipe.quality,
                                        url: folder.appendingPathComponent(item.fileName), metadataFrom: source,
                                        adjustments: frame.edit.adjustments.isActive ? frame.edit.adjustments : nil,
                                        printCrop: made.plan.printCrop)
                darkroom.prepareExport(job, frame: frame, source: source, isRAW: made.isRAW, plan: made.plan, order: order)
            }
            jobs[job.id] = item.id
            let watcher = Task { [weak self] in
                // The scheduler's view of the job, mirrored into the sheet.
                while !Task.isCancelled {
                    if let s = self?.scheduler.snapshots.first(where: { $0.id == job.id }) {
                        switch s.state {
                        case .running(let p): self?.set(i, .running(p))
                        case .waiting(let why): self?.set(i, .waiting(why))
                        case .queued: self?.set(i, .waiting(.queued))
                        default: break
                        }
                    }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
            }
            scheduler.submit(job)
            let outcome = await scheduler.outcome(of: job.id)
            watcher.cancel()
            jobs[job.id] = nil
            let file = darkroom?.takeExport(job.id)
            darkroom?.forget(job.id)
            switch outcome {
            case .finished:
                guard folder != nil else { set(i, .done); continue }       // the simulation: its time, and no file
                switch file {
                case .written(let written):
                    batch?.items[i].size = written.size
                    batch?.items[i].file = written.url
                    // Files and Share are the system's own sheets, shown over Exporting when the batch
                    // has ended, so the file waits in the batch's folder.
                    set(i, .done)
                    noted("saved", file: written.url)
                case .failed(let why):
                    set(i, .notSaved(why))
                    noted("not saved", why)
                case nil:
                    set(i, .notSaved("The file was not written"))
                    noted("not saved", "The file was not written")
                }
            case .cancelled:
                if let written = file, case .written(let w) = written { try? FileManager.default.removeItem(at: w.url) }
                set(i, .stopped)
                noted("stopped")
                return
            case .failed(let message):
                // The engine's words may name a profile: they go to the log, not to the page.
                log.error("the export of \(item.fileName, privacy: .public) failed: \(message, privacy: .public)")
                set(i, .failed(""))
                noted("failed", message)
            }
        }
        // Nothing of the batch is being read any more: the working copies go back within their limit.
        darkroom?.originals?.copies.trim()
    }

    private func set(_ i: Int, _ state: Item.State) {
        guard var b = batch, b.items.indices.contains(i), b.items[i].state != state else { return }
        b.items[i].state = state
        batch = b
    }
}
