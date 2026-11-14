//  AppServices.swift — the app's parts, made once and handed to every page.
//
//  One engine, one scheduler in front of it, and the stores the pages read.
//  Every render in the app — a canvas edit, a shot, an import, an export —
//  goes through `scheduler`; nothing calls the engine directly.
//
//  Which engine it is, is `EngineRouter`'s to say: the engine itself for a library
//  of the user's own pictures, where this build links it; the simulation for
//  the drawings' own library, and wherever the engine is not linked.

import Observation
import SwiftUI
import os

@MainActor
@Observable
final class AppServices {
    let presets: PresetStore
    /// The app's side of the engine: which one runs, and what a job hands it.
    let darkroom: EngineRouter
    let engine: any DevelopEngine
    let scheduler: RenderQueue
    let library: FrameCatalog
    let settings: AppSettings
    /// The saved export recipes (`export-recipes.json`, beside the library's file).
    let recipes: ExportRecipeStore
    /// Originals that stay in Photos, brought here while they are worked on,
    /// and no more of them than the limit (`Originals`, `WorkingCopies`).
    let originals: Originals
    let exporter: ExportService
    /// The pictures on Develop's film and paper cards (`StockPreviews`).
    let stockPreviews: StockPreviews
    /// The app's own log, who may have it, and its sending (`Diagnostics`).
    let diagnostics: Diagnostics
    let router: AppRouter
    /// The window's size and the layout it gets (`WindowLayout.swift`): the host's pages, the
    /// stack or the column. Set by `RootView`.
    let window = WindowShape()
    /// The Mac's library data (Mac change, 2026-10-23: `Sources/Mac/Library/CatalogSourcesStore.swift`,
    /// `MAC-LIBRARY-DATA.md`): sources, collections, rows and facets for the Mac's library views.
    /// Nothing runs — no helper, no file read — until a view calls `start()`.
    @ObservationIgnored private(set) lazy var macLibrary = CatalogSourcesStore(model: self)
    #if SPK_ENGINE
    /// The Mac's full-size renders around what is looked at (2026-10-24, `Sources/Mac/Render/`): the develop
    /// page's neighbours made ahead, and the Light Table's films made where nothing of them is kept.
    @ObservationIgnored private(set) lazy var renderCache = MacRenderCache(model: self)
    #endif
    /// Where a film's geometry comes from: the port of the engine's layout
    /// until the engine is linked and answers itself (`FilmLayout.swift`).
    let filmGeometry: any FilmGeometrySource = PortedFilmGeometry()
    /// True inside the snapshot harness.
    let isSnapshot: Bool
    /// Where the model's own settings are kept: the app's domain, or a check's suite (`init`).
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var filmEdges: [FilmEdgeKey: ResolvedFilmEdge?] = [:]
    /// Each frame's last `finishedLayers`, by what it was made of: a page asks on every redraw, and a layer's key is
    /// an encoding and a hash.
    @ObservationIgnored private var finishedMade: [LibraryFrame.ID: (of: FinishedLayersOf, made: FinishedLayers?)] = [:]
    @ObservationIgnored private(set) var signals: SchedulerSignals?
    /// The develop pages that are open, by frame: where a canvas's picture goes.
    @ObservationIgnored private var sessions: [LibraryFrame.ID: WeakSession] = [:]
    /// Every frame's edit history (PRD-F): `EditHistory/history.sqlite` beside the library where a library is
    /// kept on disk, in memory otherwise (the drawings' own, the snapshot harness, a test). Every session reads
    /// and writes it through this one line, and so does every change made with no page open (`recordStep`).
    @ObservationIgnored let history: EditHistoryLine
    /// Frames whose own develop reads an original that stays in Photos, in
    /// the order they were asked for: one at a time has its original brought
    /// and is developed (`awaitOriginal`).
    @ObservationIgnored private var queuedDevelops: [(id: LibraryFrame.ID, kind: JobKind)] = []
    @ObservationIgnored private var bringer: Task<Void, Never>?
    /// The frames that one's develop is reading now.
    @ObservationIgnored private var reading: Set<LibraryFrame.ID> = []
    /// The launch's one reading of every RAW frame's size from its file (`holdRAWsToTheirFiles`).
    @ObservationIgnored private var sizing: Task<Void, Never>?
    /// The launch's catch-up of the camera's crop for frames made before it was read (`holdCameraCrops`).
    @ObservationIgnored private var cameraCrops: Task<Void, Never>?
    /// Jobs the log has been told have begun, until it is told they ended.
    @ObservationIgnored private var begun: Set<UUID> = []
    /// The library as the log last had it, so it is told again only of another.
    @ObservationIgnored private var libraryNoted = ""

    /// `pinnedNow` fixes the clock (the snapshot harness: the drawings' own
    /// day). `persists` false keeps nothing in UserDefaults. `realLibrary`
    /// reads the library kept on disk, and keeps it (a host). `defaults` is where the model's own settings
    /// are kept: the app's domain, or a check's suite (`--defaults-suite`, AGENTS.md trap 24).
    init(scenario: DemoLibrary.Scenario = .home, pinnedNow: Date? = nil, persists: Bool = true,
         isSnapshot: Bool = false, engineSpeed: Double = 1, realLibrary: Bool = false, defaults: UserDefaults = .standard) {
        // The user's own library is developed by the engine. The drawings' own
        // never is: its pictures are SpektraLab's prints already.
        let darkroom = EngineRouter(wantsEngine: realLibrary && !isSnapshot, simulatedSpeed: engineSpeed)
        self.darkroom = darkroom
        engine = darkroom.engine
        #if SPK_ENGINE
        GamutProof.shared.darkroom = darkroom   // the numbers a page's proof into a smaller space uses
        #endif
        self.isSnapshot = isSnapshot
        self.defaults = defaults
        scheduler = RenderQueue(engine: darkroom.engine, defaults: persists ? defaults : nil)
        // The window's profile of the budget where the app runs on one (`BudgetTuning.window`).
        scheduler.tuning = .forThisDevice
        // Nothing develops while a camera session runs (the owner, 2026-10-08). The app
        // runs none; the scheduler keeps the rule.
        scheduler.developsBesideCamera = false
        library = FrameCatalog(DemoLibrary.seed(scenario, now: pinnedNow))
        presets = PresetStore(url: realLibrary && persists ? ImportService.root.appendingPathComponent("look-presets.json") : nil)
        settings = AppSettings(defaults: persists ? defaults : nil)
        // Kept only where the library is: the drawings' own library, and a test, save nothing.
        recipes = ExportRecipeStore(url: realLibrary && persists ? ImportService.root.appendingPathComponent(ExportRecipeStore.fileName) : nil,
                                    defaults: realLibrary && persists ? defaults : nil)
        // Working copies are kept only where the library is.
        originals = Originals(library: library, folder: realLibrary && persists ? ImportService.workingCopies : nil,
                              limit: settings.workingCopiesLimit)
        exporter = ExportService(library: library, scheduler: scheduler, darkroom: darkroom)
        // Cards are kept on disk where the library is; the drawings' own library makes none.
        stockPreviews = StockPreviews(scheduler: scheduler, darkroom: darkroom, library: library,
                                      folder: realLibrary && persists ? StorageTidy.cardsFolder(in: ImportService.previews) : nil)
        // A log is kept where a library is: never the drawings' own, never the snapshot harness's.
        // Sent only from a build with the sending compiled (`SPK_LOG_UPLOAD`): any other keeps it.
        #if SPK_LOG_UPLOAD
        diagnostics = Diagnostics(folder: realLibrary && persists && !isSnapshot ? ImportService.logs : nil,
                                  endpoint: .launch(), defaults: persists ? defaults : nil)
        #else
        diagnostics = Diagnostics(folder: realLibrary && persists && !isSnapshot ? ImportService.logs : nil)
        #endif
        router = AppRouter()
        // Opened on its first call, on the store's actor: nothing of it runs at launch on the main thread.
        let keepsHistory = realLibrary && persists && !isSnapshot
        history = EditHistoryLine(store: keepsHistory ? SQLiteEditHistoryStore(url: SQLiteEditHistoryStore.file(in: ImportService.root))
                                                      : InMemoryEditHistoryStore())
        // 镜头校正's lens database and Core Image's verdicts (`LensResolver`): opened on their first ask, off the main
        // thread. A test or a snapshot library keeps none: no database lens is resolved there.
        LensResolver.configure(database: keepsHistory ? LensDatabase(url: LensDatabase.file(in: ImportService.root)) : nil)
        exporter.film = { [weak self] frame in self?.exportFilm(frame) }
        LensLibrary.shared.changed = { [weak self] in self?.lensDatabaseChanged() }
        exporter.finishedLayers = { [weak self] frame in self?.finishedLayers(frame) }
        exporter.cropIsFrame = { [settings] in settings.cropRemapsFrame }
        exporter.variantNumber = { [weak self] id in self?.macLibrary.variantNumber(of: id) }
        darkroom.originals = originals
        // The page's zoom renders a frame as its export at Full would (`FullRender`), so that export is made of it.
        darkroom.fullPlan = { [weak exporter] frame in
            // At this device's own ceiling: seeing a frame whole is not exporting it.
            guard let made = exporter?.prepared(frame, ExportRecipe(), ceiling: DevicePolicy.current.developCapMegapixels),
                  !made.fromPreview, let source = made.source else { return nil }
            return (made.plan, source, made.isRAW)
        }
        originals.copies.inUse = { [weak self] in self?.originalsInUse() ?? [] }
        // A RAW's proxy is of a file and its decode, not of a frame (PRD-G §5): the book asks which frames name one.
        originals.copies.proxyNames = { [weak self] ids in
            guard let self else { return [] }
            let frames = ids.map { $0.compactMap { self.library.frame($0) } } ?? self.library.frames
            return self.darkroom.proxyNames(of: frames)
        }
        // The full-size renders' own limit, and the ones being shown, read or made (`WorkingCopies.fullLimit`).
        originals.copies.fullLimit = settings.fullRenderCacheLimit
        originals.copies.fullInUse = { [weak self] in self?.fullRendersInUse() ?? [] }
        originals.copies.onChange = { [weak library] in library?.measureStorage() }
        originals.previewLongEdge = { [settings] in settings.previewLongEdge }
        originals.onResized = { [weak self] id in self?.resized(id) }
        if realLibrary {
            // The limits as they were last set (F5): the drawings' own library keeps the drawing's.
            library.storage.workingCopiesLimit = settings.workingCopiesLimit
            library.storage.previewCopiesLimit = settings.previewCopiesLimit
        }

        // The scheduler's news reaches the frames; a memory warning empties
        // the frontend's own caches before the engine is asked for anything.
        scheduler.onUpdate = { [weak self, weak library] snapshot in
            library?.apply(snapshot)
            // A frame's preview develop that ended while a newer one of it is held (asked again while it
            // ran: a second paste onto it, 2026-11-05) is still waiting, not done: the scheduler drops the
            // ended job's snapshot before it tells, so any it still holds is the newer.
            if let self, snapshot.job.kind == .importDevelop, snapshot.job.tier != .full {
                switch snapshot.state {
                case .done, .cancelled, .failed:
                    if self.scheduler.snapshot(frameID: snapshot.job.frameID, where: { $0.kind == .importDevelop && $0.tier != .full }) != nil {
                        library?.update(snapshot.job.frameID) { $0.develop = .queued }
                    }
                default: break
                }
            }
            self?.noteJob(snapshot)
        }
        stockPreviews.onNeedsSource = { [weak self] frame in
            self?.openSession(frame)?.refillStripSource() ?? false
        }
        scheduler.onTrimCaches = { [weak self, weak stockPreviews] in
            ThumbnailStore.shared.trim()
            stockPreviews?.trim()
            self?.releaseFullSize()
            // The rest of what can be drawn again (`MemoryRelease`): the pages' develops between edits, Edit's
            // copies, the gamut proofs, the rail's pictures, the canvas's corrected pictures.
            MemoryRelease.post()
        }
        // A job someone waits on cannot fit: more goes than on a warning (`RenderQueue.reclaim`).
        scheduler.onReclaim = {
            NotificationCenter.default.post(name: .spkReclaim, object: nil)
        }
        // What the engine hands back: a develop page's picture, a frame's kept
        // develop, a RAW's own white balance.
        darkroom.onCanvas = { [weak self] frame, image, stamp in self?.sessions[frame]?.session?.landed(image, stamp: stamp) }
        // Enable HDR's curve of that picture's session: the page's to draw its HDR with (`OpenFrameSession.hdr`).
        darkroom.onHDRCurve = { [weak self] frame, answer, stamp in self?.sessions[frame]?.session?.hdrLanded(answer, stamp: stamp) }
        darkroom.onKept = { [weak self] frame, picture in self?.kept(frame, picture) }
        darkroom.onAsShot = { [weak self] frame, temperature, tint in self?.readAsShot(frame, temperature, tint) }
        darkroom.onRawExposure = { [weak self] frame, facts in self?.readRawExposure(frame, facts) }
        darkroom.onMetered = { [weak self] pair, index, ev, key in self?.metered(pair, index, ev, key) }
        // A double exposure's exposure metered alone (RFC-048 §4): kept in the double, under what it was
        // read for, so it is read once (`meteredDouble`, DoubleKeeping.swift).
        darkroom.onDoubleMetered = { [weak self] id, position, ev, key in self?.meteredDouble(id, position.rawValue, ev, key) }
        // What a double exposure's open decodes, for the scheduler's price of the job (RFC-048 §5).
        scheduler.composition = { [weak darkroom] job in darkroom?.composition(of: job.id) }
        // Where a pair's two frames are on the strip its page has just developed: the page's to know.
        darkroom.onGates = { [weak self] pair, rects in self?.openSession(pair)?.located(rects) }
        darkroom.bodySeed = { [settings] in settings.bodySeed }
        darkroom.cropIsFrame = { [settings] in settings.cropRemapsFrame }
        darkroom.frames = { [library] id in library.frame(id) }
        if realLibrary {
            // The found masks' files (PRD-E, RFC-052 §8.2): the library's own `Masks/`, beside `library.json` and
            // `layers.json`, read by every bake of a found part on every surface (`MaskStore.foundPicture`). Set before
            // anything can develop; a demo library has none, so a found part there fails loudly.
            FoundMaskFiles.shared.use(FoundMaskFiles.folder(in: ImportService.root))
            library.load(from: LibraryPersistence())
            ImportService(model: self).adoptOrphans()
            // The double exposures held to the library as it was read: what an older build did meanwhile
            // (`LibraryShelf`) -- a photograph removed, a guide swept -- mended before the tidy keeps what
            // the library names.
            holdDoublesToTheLibrary()
            // What the app keeps on disk, held to the library as it was read: files
            // of frames that are gone go, and what Photos no longer has is marked.
            tidyStorage()
            // Frames read in place from Photos (a window's) keep their originals in the app: any whose
            // working copy is here moves in before the rest are marked missing.
            keepPhotosOriginals()
            originals.reconcile()
            holdPairsToTheirFrames()
            holdRAWsToTheirFiles(keeping: persists)
            holdCameraCrops()
            // The edited copies the library's pages draw (Layer 2): made when the app holds nothing
            // else — no job, no camera — and kept with the library.
            Layer2Copies.shared.canRun = { [weak scheduler] in
                guard let scheduler else { return false }
                return scheduler.isIdle && !scheduler.frontend.cameraLive
            }
            Layer2Copies.shared.finishedLayers = { [weak self] frame in self?.finishedLayers(frame) }
            Layer2Copies.shared.watch(library)
            // The log: which build on which reference device, then the library in numbers once what the
            // app keeps has been measured (at launch the figures are not in yet), and again
            // as the app is left if it is another library by then.
            LogScrub.stockNames = Dictionary(StockCatalog.shared.stocks.map { ($0.id, $0.name) }) { first, _ in first }
            Log.launched(self)
            diagnostics.summary = { [weak self] in self?.logSummary() ?? [:] }
            diagnostics.beforeLeaving = { [weak self] in self?.noteLibrary() }
            library.onMeasured = { [weak self] in
                guard let self else { return }
                if self.libraryNoted.isEmpty { self.noteLibrary() }
            }
            // Over the engine a debug build keeps every job's record, to be read off a host.
            if darkroom.makesPictures { JobDiagnostics.keep(scheduler) }
            // And every build notes each in its log, beside whatever a debug build keeps.
            let kept = scheduler.onRecord
            scheduler.onRecord = { record in
                kept?(record)
                // A strip's cards are logged as the strip's run (`Log.stripEnded`), not a line each.
                if record.kind != JobKind.stockPreview.rawValue { Log.ended(record) }
            }
            if !isSnapshot {
                diagnostics.begin()
                // The app's memory as it runs, beside what it was doing (`MemoryLog`).
                let memory = MemoryLog()
                Log.memory = memory
                memory.begin { [router, scheduler] in (router.top, scheduler.frontend.cameraText) }
            }
        }
        #if SPK_ENGINE
        // The Mac's renders around what is looked at: its hooks on the page's zoom and the renders' reads.
        if realLibrary && !isSnapshot { _ = renderCache }
        #endif
        if !isSnapshot {
            signals = SchedulerSignals(scheduler: scheduler)
            // The drawings show a frame part-way through its develop. In the
            // running app that has to be a develop the queue is really doing,
            // or its ring would never move.
            for frame in library.frames where frame.develop.isBusy { develop(frame.id, cause: .sweep) }
            if darkroom.makesPictures {
                // The pair new frames develop with, set up before the first waits on it;
                // and every frame whose kept develop is missing or of another edit or engine.
                let stocks = settings.newFrameStocks
                darkroom.warmUp(film: stocks.film, paper: stocks.paper)
                developStale()
                checkWire()
            }
        }
    }

    /// The model for a normal launch. On a host the library is the real one,
    /// kept on disk (empty at the first run: B1); the simulator opens the demo
    /// library. `--first-run` opens an empty library that keeps nothing;
    /// `--demo importing|offline|empty|home` opens that drawing's state.
    /// `--library real` gives a simulator a library of its own on disk, and
    /// `--import <paths>` copies files into it (the engine's frames there).
    static func launch(arguments: [String] = CommandLine.arguments) -> AppServices {
        // Before anything says a word: the language this run is in. A launch with a `--` argument
        // (a snapshot, a tour, a harness) is English unless it names another (`Language.start`).
        Language.shared.start(arguments: arguments)
        // HDR is offered only while a screen can show it (`FeatureFlags.screenShowsHDR`): what the panels say, read
        // again whenever a screen changes (`HDRDisplays`, D5: a Mac's screens come and go, so once at launch is not enough).
        HDRDisplays.shared.start()
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        let onPhone = false
        #else
        let onPhone = true
        #endif
        var scenario = DemoLibrary.Scenario.home
        var real = true   // the Mac app keeps the user's own library; `--demo <scenario>` still shows a demo
        if arguments.contains("--first-run") { scenario = .empty; real = false }
        if let i = arguments.firstIndex(of: "--demo"), i + 1 < arguments.count,
           let named = DemoLibrary.Scenario(rawValue: arguments[i + 1]) { scenario = named; real = false }
        // `--library real`: the simulator keeps a library of its own on disk, as a
        // host does, so the engine has frames of the user's to develop there.
        if let i = arguments.firstIndex(of: "--library"), i + 1 < arguments.count, arguments[i + 1] == "real" { real = true }
        if real { scenario = .empty }
        var defaults = UserDefaults.standard
        #if DEBUG
        // `--defaults-suite <name>`: a check's launch keeps the model's settings in a suite of its own, never the
        // app's domain, which `CFFIXED_USER_HOME` does not move (`tools/history_check.sh`; AGENTS.md trap 24).
        if let i = arguments.firstIndex(of: "--defaults-suite"), i + 1 < arguments.count,
           let suite = UserDefaults(suiteName: arguments[i + 1]) { defaults = suite }
        #endif
        let model = AppServices(scenario: scenario, realLibrary: real, defaults: defaults)
        #if SPK_LOG_UPLOAD
        // The ask to share the log is the user's to see: a launch with arguments is a check's.
        model.diagnostics.asksByItself = arguments.count <= 1 || arguments.contains("--ask-diagnostics")
        #endif
        #if DEBUG && SPK_LOG_UPLOAD
        // `--ask-diagnostics`: the ask as a first launch shows it, whatever was answered before.
        if arguments.contains("--ask-diagnostics") { model.diagnostics.forgetAnswer() }
        #endif
        // `--import <file or folder> …`: copied in at launch, as Copy files in does
        // (a simulator reads the Mac's files; a host has none at these paths).
        if real, let i = arguments.firstIndex(of: "--import") {
            let paths = arguments[(i + 1)...].prefix { !$0.hasPrefix("--") }
            let urls = paths.flatMap { path -> [URL] in
                let url = URL(fileURLWithPath: path)
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return [] }
                guard isFolder.boolValue else { return [url] }
                return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            // Only what the library does not hold already, by name: a second launch adds nothing.
            let held = Set(model.library.frames.map(\.fileName))
            let fresh = urls.filter { !held.contains($0.lastPathComponent) }
            if !fresh.isEmpty { Task { await ImportService(model: model).copyIn(fresh) } }
        }
        #if DEBUG
        if real { FolderHarness.run(model, arguments: arguments) }   // `--link-folder`, `--reconnect-folder` (FolderHarness.swift)
        // `--double-check [--frames BOTTOM TOP] [--out DIR]`: a double exposure walked on the engine (`DoubleHarness`).
        if real { DoubleHarness.run(model, arguments: arguments) }
        if real { MacLayersCheck.run(model, arguments: arguments) }
        #if SPK_ENGINE
        // `--finished-layers-check [--out DIR]`: PRD-E's 成片 layers on the page, the histogram, the zoom, a tile and the export.
        if real { MacFinishedLayersCheck.run(model, arguments: arguments) }
        // `--masks-check OUT [--masks-check-relaunch RUN1]`: a photograph's mask layers in the window (M1a).
        if real { MacMasksCheck.run(model, arguments: arguments) }
        // `--lens-check OUT [--lens-check-relaunch RUN1]`: 镜头校正's panel, popup and Settings row (tools/lens_check.sh).
        if real { MacLensCheck.run(model, arguments: arguments) }
        #endif
        #endif
        // `--settings-recipes`: Settings open on its Recipes page (a drive's way in).
        if arguments.contains("--settings-recipes") {
            SettingsRequest.next = .recipe
            model.router.show(.settings)
        }
        // `--settings`: Settings open on their first page.
        if arguments.contains("--settings") { model.router.show(.settings) }
        // `--develop` opens the develop page on the library's frame; `--crop`
        // and `--film-edge` the Crop page and the Film Edge flow's Frame step
        // over it (a simulator driven from a Mac, to put a finger on them).
        // `--print-crop` opens Edit's crop instead; `--frame <name>` picks the frame by its
        // file's name (a library of a RAW and a JPEG, to put a finger on each).
        if let i = arguments.firstIndex(of: "--frame"), i + 1 < arguments.count,
           let picked = model.library.frames.first(where: { $0.fileName.hasPrefix(arguments[i + 1]) }) {
            model.library.selectedID = picked.id
        }
        if let id = model.library.selected?.id {
            if ["--develop", "--crop", "--print-crop", "--film-edge"].contains(where: arguments.contains) { model.router.open(.develop(id)) }
            if arguments.contains("--crop") { model.router.show(.crop(id)) }
            if arguments.contains("--print-crop") { model.router.show(.printCrop(id)) }
            if arguments.contains("--film-edge") { model.router.show(.filmEdge(id, .frame)) }
        }
        #if DEBUG
        // `--agent-access`: Settings › General › Agents turned on, and kept, for a check's launch, which has
        // no hand to tick the box. Kept where every setting is: in the bundle id's own domain, which a
        // `CFFIXED_USER_HOME` does not move (measured 2026-11-09: the plist was the real home's) -- so a check
        // run under a bundle id of its own (`gen_project.py --bundle-id`) never turns it on for anyone else.
        if arguments.contains("--agent-access") { model.settings.agentAccess = true }
        #endif
        // The agents' socket (ARCHITECTURE.md §7.16): listened on from launch, whatever the switch says —
        // the switch is read at each call. Never for the snapshot harness, which leaves at once, nor the
        // drawings' own library, which is not the person's.
        if real, !arguments.contains("--snapshot") {
            AgentServer.shared.start { [weak model] tool, args in
                guard let model else { return ["ok": false, "refused": false, "error": "SpektraLab is closing."] }
                return await AgentExecutor(model: model).reply(tool, args)
            }
            NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                AgentServer.shared.stop()
            }
        }
        // The step-naming table is made once, at launch, not inside the first step's 1 ms (PRD-F §5).
        _ = HistoryFields.table.count
        // **At quit** the library is written as it stands and the edit history's line run out, for at most half a
        // second. Measured on this Mac (2026-11-13, `tools/history_check.sh`'s quits, every notification logged from
        // `NSApplication terminate:` on): a Catalyst quit posts `didEnterBackground` and `UISceneDidDisconnect` within
        // ~0.1 s on the main thread, and then nothing — no `willTerminate`, no `applicationWillTerminate`, with
        // sudden termination held off or not — and the process is gone about 5 s later, its main queue not run
        // meanwhile: a library save waiting out its second and the steps in the history's line were lost. So the
        // writing is done on entering the background, which a quit always passes through (and a hidden app too, where
        // writing early costs nothing). `willTerminate` is kept for a quit that does post it.
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak model] _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { model?.settleForQuit() }
            }
        }
        return model
    }

    // MARK: the log

    /// A job has begun to run, said once and before it ends: the session the operating system
    /// ends in the middle of one names it.
    private func noteJob(_ snapshot: JobSnapshot) {
        // A strip's cards are noted as the strip's run (`Log.stripBegan`).
        guard snapshot.job.kind != .stockPreview else { return }
        switch snapshot.state {
        case .running:
            if begun.insert(snapshot.id).inserted { Log.began(snapshot.job, mode: snapshot.mode) }
        case .done, .cancelled, .failed:
            if begun.remove(snapshot.id) != nil { Log.memory?.tell(job: nil) }
            // A develop of a page's that has ended is the foreground decode's
            // turn taken: the strip's cards stop waiting for it and decode for
            // themselves again (`StockPreviews.foregroundDeveloped`). Failure
            // also ends the hold so the cards can report their own error;
            // cancellation leaves the hold to the replacement canvas job.
            if snapshot.job.kind.isCanvas {
                switch snapshot.state {
                case .done, .failed:
                    stockPreviews.foregroundDeveloped(snapshot.job.frameID)
                default: break
                }
            }
        case .queued, .waiting:
            break
        }
    }

    /// The library in numbers, when it is another than the log last had.
    private func noteLibrary() {
        let s = library.storage
        let now = "\(library.frames.count) \(s.total) \(library.frames.reduce(0) { $0 &+ $1.edit.params.filmStock.hashValue })"
        guard now != libraryNoted else { return }
        libraryNoted = now
        Log.library(self)
    }

    /// What the zip's summary says of the app as it stands.
    private func logSummary() -> [String: Any] {
        let build = diagnostics.build
        let s = library.storage
        return [
            "app": build.version, "build": build.build, "commit": build.commit, "configuration": build.configuration,
            "machine": Log.machine, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": engine.makesPictures ? engine.name : "simulated", "engine_sources": darkroom.commit,
            "frames": library.frames.filter { !$0.isDemo }.count,
            "storage_mb": ["originals": Int(s.copiedInOriginals / 1_048_576), "working_copies": Int(s.workingCopies / 1_048_576),
                           "previews": Int(s.previewCopies / 1_048_576), "cache": Int(s.cache / 1_048_576)],
            "settings": ["preview_px": settings.previewLongEdge,
                         "pro_control": settings.proControl, "recipe": Log.recipe(settings.recipe)] as [String: Any],
        ]
    }

    /// Which engine this build runs, as Settings says it. A simulated engine
    /// is named as one: it keeps time and makes no picture. An engine that
    /// should be running and is not says so.
    var engineText: String {
        if let failure = darkroom.failure { return L(shown: failure) }
        return engine.makesPictures ? L("SpektraLab engine") : L("Simulated: this build develops no picture")
    }

    /// Settings' note under "This build": what this build does and does not
    /// do, so that nobody waits for what will not come. Over the simulation,
    /// that it develops no picture; over the engine, when a frame is developed
    /// and at what size.
    var buildNote: String {
        guard engine.makesPictures else {
            return L("This build develops no picture: a frame keeps its camera's own preview, "
                + "and the bundled demo frames are the ones SpektraLab developed.")
        }
        return L("A frame is developed at preview size for the page, and again from its original for an export.")
    }

    /// A frame's film edge under an edit, resolved once per distinct ask: the
    /// layout sets type through CoreText, and a page asks on every redraw.
    /// `forcing` lays it out with the switch off (the flow's own preview).
    func filmEdge(for frame: LibraryFrame, edit: FrameEdit? = nil, forcing: Bool = false) -> ResolvedFilmEdge? {
        let e = edit ?? frame.edit
        guard FeatureFlags.filmEdge, e.filmEdge.active || forcing else { return nil }
        let key = FilmEdgeKey(frame: frame.id, size: frame.originalSize, edge: e.filmEdge, date: e.dateBack,
                              photo: e.geometry, stock: e.params.filmStock, frameSeed: e.frameSeed,
                              body: settings.bodySeed, capture: frame.captureDate, exposure: frame.exposure, forcing: forcing)
        if let hit = filmEdges[key] { return hit }
        let made = FilmEdgeResolver.resolve(frame: frame, edit: e, bodySeed: settings.bodySeed, source: filmGeometry, forcing: forcing)
        if filmEdges.count > 96 { filmEdges.removeAll(keepingCapacity: true) }
        filmEdges[key] = made
        return made
    }

    /// **A frame's 成片 layers for Edit's pass** (PRD-E, RFC-052 §3, §7): the ones that act, with the finished canvas
    /// → S (`MaskFrame.finished`: the picture's cut, and under a film edge the gate's place on the film's canvas, the
    /// numbers the guide is drawn from, `FilmGeometry.pictureBox`). The same value for the page, the zoom, a tile's copy
    /// and the export: each surface composes it with its own place (`FinishedLayers.matrix(turnsAfter:)`), and Edit's
    /// crop, made after the pass on every surface, is in none of them. Nil where none acts or Edit is off; for a piece
    /// made of frames (M1 is single photographs, PRD-E §3); and under a film edge whose layout is not to be had — the
    /// layers stand down rather than land off their subject.
    func finishedLayers(_ frame: LibraryFrame, edit: FrameEdit? = nil) -> FinishedLayers? {
        let e = edit ?? frame.edit
        guard !frame.isComposite, e.adjustments.enabled, let layers = e.layers, !layers.active(.finished).isEmpty else { return nil }
        guard let (picture, film) = finishedPlace(frame, e) else { return nil }
        let of = FinishedLayersOf(layers: layers, enabled: e.adjustments.enabled, picture: picture, film: film, source: frame.originalSize)
        if let kept = finishedMade[frame.id], kept.of == of { return kept.made }
        let made = FinishedLayers.of(layers, adjustments: e.adjustments, source: frame.originalSize,
                                     toSource: MaskFrame.finished(picture: picture, source: CGSize(width: frame.originalSize.width,
                                                                                                   height: frame.originalSize.height), film: film))
        if finishedMade.count > 64 { finishedMade.removeAll(keepingCapacity: true) }
        finishedMade[frame.id] = (of, made)
        return made
    }

    /// The picture's cut and, under a film edge, the gate's place on the film's canvas: what `MaskFrame.finished` is
    /// made of for this frame and edit. Nil under a film edge whose layout is not to be had.
    private func finishedPlace(_ frame: LibraryFrame, _ e: FrameEdit) -> (Geometry, MaskFrame.FilmBox?)? {
        let picture = e.pictureGeometry(source: frame.originalSize)
        var film: MaskFrame.FilmBox?
        if e.filmEdge.effective {
            guard let resolved = filmEdge(for: frame, edit: e) else { return nil }
            let g = resolved.geometry, (box, tilt, centre) = g.pictureBox
            film = MaskFrame.FilmBox(canvasMM: g.canvasMM, box: box, tilt: tilt, centre: centre)
        }
        return (picture, film)
    }

    /// **The finished canvas → S for a frame and an edit** (`MaskFrame.finished`): the matrix Edit's pass is handed
    /// (`finishedLayers`), and the one the page's mask tools compose with the view's own place (`MaskStage`, through
    /// `MaskFrame.view`). One function, so the overlay and the pass cannot disagree. Nil for a piece made of frames, and
    /// under a film edge whose layout is not to be had.
    func finishedToSource(_ frame: LibraryFrame, edit: FrameEdit? = nil) -> MaskMatrix? {
        let e = edit ?? frame.edit
        guard !frame.isComposite, let (picture, film) = finishedPlace(frame, e) else { return nil }
        return MaskFrame.finished(picture: picture, source: CGSize(width: frame.originalSize.width, height: frame.originalSize.height), film: film)
    }

    /// What `finishedLayers` is made of, for its memo.
    struct FinishedLayersOf: Equatable {
        var layers: LocalLayers
        var enabled: Bool
        var picture: Geometry
        var film: MaskFrame.FilmBox?
        var source: PixelSize
    }

    /// A frame's film edge as an export needs it: the host's cut and turn of
    /// the picture, and the film's canvas round a framing of any size — the
    /// same layout the page's film is drawn from, asked at the export's own
    /// size and not at the page's film budget (an export is planned by the
    /// device's cap and its memory, `ExportPlan`, `RenderQueue`).
    func exportFilm(_ frame: LibraryFrame) -> ExportService.Film? {
        let edit = frame.edit
        if let pair = frame.pair {
            // A pair on its strip: nothing is cut or turned by the host — the piece is
            // whole — and the film round it is priced by the pair's own estimate. The
            // file's size is read back from the file (`ExportService`).
            guard pair.wearsFilmEdge else { return nil }
            return ExportService.Film(ask: ExportPlan.Ask.Film(framing: .default, hostCut: .default, hostTurns: 0),
                                      canvas: { piece in pair.canvas(piece: piece, look: edit) })
        }
        guard edit.filmEdge.effective, let cut = edit.hostCut(source: frame.originalSize),
              let resolved = FilmEdgeResolver.resolve(frame: frame, edit: edit, bodySeed: settings.bodySeed, source: filmGeometry,
                                                      budgetMP: .greatestFiniteMagnitude) else { return nil }
        let request = resolved.request, layout = filmGeometry
        return ExportService.Film(
            ask: ExportPlan.Ask.Film(framing: edit.pictureGeometry(source: frame.originalSize), hostCut: cut,
                                     hostTurns: edit.hostTurns(source: frame.originalSize)),
            canvas: { framing in
                var asked = request
                asked.frame = framing
                return layout.geometry(asked)?.out
            })
    }

    /// The develop session on a frame: **one, for as long as a page holds it**
    /// (`OpenFrameSession.enter`). The develop page makes it; the Film Edge flow
    /// presented over that page is handed the same one, so its edits are the
    /// page's own and the engine's pictures keep arriving where they are shown.
    ///
    /// It used to be a new session at every call, each taking the frame's
    /// place in `sessions` — which is where the engine's canvas pictures are
    /// delivered. After the Film Edge flow, Crop's Done or Copy Settings the
    /// develop page's own session was no longer the one registered: every
    /// later edit developed, the Latitude card re-measured, the line said
    /// Developed, and the picture on the page never changed (seen in the
    /// simulator, 2026-10-07: a 0.44 s develop for a new stock, the same
    /// picture after it; the owner's "the film edge is never truly rendered").
    func session(for frameID: LibraryFrame.ID) -> OpenFrameSession {
        if let held = heldSession(frameID) { return held }
        let session = OpenFrameSession(frameID: frameID, library: library, scheduler: scheduler, settings: settings,
                                     darkroom: darkroom)
        // Edit's 成片 layers, with the finished canvas's matrix (PRD-E): the page's pass and its histogram carry them.
        session.finishedLayers = { [weak self] frame, edit in self?.finishedLayers(frame, edit: edit) }
        // A layer act waits while an export batch reads this frame (AGENTS.md trap 34), as Go to This Step does.
        session.exportHolds = { [weak self] in self?.historyRefusal(frameID) != nil }
        // The page leaves a picture that is not of the edit as it stands: this one frame's develop, asked.
        session.onStale = { [weak self] in self?.develop(frameID) }
        session.onRestoreRevision = { [weak self, weak session] revision in
            guard let self, let session else { return }
            var changedSources: [UUID] = []
            var before: [UUID: DecodeSettings] = [:]
            for (id, decode) in revision.sourceDecodes where self.library.frame(id)?.edit.decode != decode {
                guard let was = self.library.frame(id) else { continue }
                before[id] = was.edit.decode
                self.library.update(id) { $0.edit.decode = decode }
                changedSources.append(id)
            }
            if let pair = revision.pair {
                self.changePair(frameID) { piece, look in piece = pair; look = revision.edit }
            } else if let double = revision.double {
                // A double exposure's piece and look together, as one edit (RFC-050 §3); its photographs'
                // decodes are back above, and `changeDouble` reads them into the piece again.
                self.changeDouble(frameID) { piece, look in piece = double; look = revision.edit }
            } else {
                session.change { $0 = revision.edit }
            }
            for id in changedSources { self.develop(id) }
            // An Undo of the piece that put a photograph's decode back is a step of that photograph's own.
            if !changedSources.isEmpty { self.recordMembers(of: frameID, before: before) }
        }
        // A step of the piece that moved a photograph's decode is that photograph's too (PRD-F §3.3).
        session.onMembersChanged = { [weak self] before in self?.recordMembers(of: frameID, before: before) }
        // The frame's history, from the store: what the page undoes, across pages and launches (PRD-F §3.2).
        session.attachHistory(history)
        sessions = sessions.filter { $0.value.session != nil }
        sessions[frameID] = WeakSession(session: session)
        return session
    }

    /// Everything unsaved written now: `library.json` (its save waits a second after a change) and the history's line
    /// run out, capped (`EditHistoryLine.drainAtQuit`). On entering the background, which a quit passes through.
    func settleForQuit() {
        library.flush()
        history.drainAtQuit(within: 0.5)
    }

    // MARK: the edit history's one door (PRD-F §3.3)

    /// A frame's history state as it stands: its page's snapshot where a page is open, the library's otherwise.
    func historyRevision(_ frameID: LibraryFrame.ID) -> DevelopRevision? {
        if let held = heldSession(frameID) { return held.historySnapshot() }
        return library.frame(frameID).map { OpenFrameSession.revision(of: $0, darkroom: darkroom) }
    }

    /// **A person's change to a frame's edit made with no page open on it**: one step in that frame's history,
    /// from `before` (the frame's state just before the change, `historyRevision`) to the frame as it is now. The
    /// store reconciles `before` with what it holds first (`HistoryAppend.Before.reconciles`). A frame with a page
    /// open records through its session instead, as every control does.
    /// `label` nil: named from what changed (`HistoryLabels.develop`), as a step of the page is.
    func recordStep(_ frameID: LibraryFrame.ID, before: DevelopRevision, origin: HistoryOrigin, label: HistoryLabel?) {
        guard !replayingStep, heldSession(frameID) == nil, let after = historyRevision(frameID), after != before else { return }
        let step = HistoryAppend(before: before, after: after, origin: origin,
                                 label: label ?? HistoryLabels.develop(from: before.keepingReports(from: after), to: after), at: Date(), mode: .reconciles)
        history.send("append") { try await $0.append(frameID, step) }
    }

    /// A step of the history being put back on a frame with no page open (`goToStep`): what that writes is the
    /// cursor's move, never a step of its own.
    @ObservationIgnored private var replayingStep = false

    /// Why a step of this frame's history cannot be gone to now, or nil: an export is reading it (AGENTS.md trap 34 —
    /// the frame's edit must not move under the file being written). A batch's frames are held for the whole batch.
    func historyRefusal(_ frameID: LibraryFrame.ID) -> String? {
        guard exporter.isExporting, exporter.batch?.items.contains(where: { $0.id == frameID }) == true else { return nil }
        return L("This picture is being exported. Go to This Step waits until the export is done.")
    }

    /// **Go to This Step** (PRD-F §4, the history page): the frame's edit put back to step `seq` and the cursor moved
    /// there — no step, the redo tail kept until the next edit, the same as that many ⌘Z or ⇧⌘Z. With the frame open
    /// in Develop it is the page's session's (`OpenFrameSession.goTo`: the canvas follows). With none, the state is
    /// read from the store and written to the library as the session's Undo writes it (`onRestoreRevision`: the
    /// members' decodes, a pair's or a double's piece and look together), the members whose decode it moved given
    /// their own step (PRD-F §3.3), and the frame's preview developed, as a paste's is (`DevelopCause.asked`).
    /// False where it was refused (`historyRefusal`) or the history holds no such step.
    @discardableResult
    func goToStep(_ frameID: LibraryFrame.ID, _ seq: Int) async -> Bool {
        guard historyRefusal(frameID) == nil else { return false }
        if let session = heldSession(frameID) { return session.goTo(seq) }
        // The history held to the library's edit first, as a page's opening holds it (the store's guard, PRD-F §3.2):
        // an edit changed where no step was kept (an older build, a restored backup) becomes a step of its own before
        // the library's edit is overwritten, so the jump never loses it. Where that step took the place of the redo
        // tail and `seq` with it, there is no such step any more: refused, not guessed (the page reads the history
        // again and shows the new step).
        guard let current = historyRevision(frameID) else { return false }
        let read = try? await history.ask("go", writes: true) { store -> DevelopRevision? in
            _ = try await store.open(frameID, current: current, radius: 0, at: Date())
            return try await store.state(frameID, seq: seq)
        }
        guard let saved = read ?? nil else { return false }
        // While it was read, a page may have opened on the frame or an export begun: theirs, then.
        guard historyRefusal(frameID) == nil else { return false }
        if let session = heldSession(frameID) { return session.goTo(seq) }
        guard let now = historyRevision(frameID), let item = library.frame(frameID) else { return false }
        let revision = saved.keepingReports(from: now)
        replayingStep = true
        defer { replayingStep = false }
        var before: [UUID: DecodeSettings] = [:]
        for (id, decode) in revision.sourceDecodes where id != frameID {
            guard let was = library.frame(id), was.edit.decode != decode else { continue }
            before[id] = was.edit.decode
            library.update(id) { $0.edit.decode = decode }
        }
        if let pair = revision.pair, item.pair != nil {
            changePair(frameID) { piece, look in piece = pair; look = revision.edit }
        } else if let double = revision.double, item.double != nil {
            changeDouble(frameID) { piece, look in piece = double; look = revision.edit }
        } else {
            library.update(frameID) { $0.edit = revision.edit }
            develop(frameID)
        }
        history.send("move") { try await $0.move(frameID, to: seq) }
        for id in before.keys { develop(id) }
        if !before.isEmpty { recordMembers(of: frameID, before: before) }
        return true
    }

    /// **Clear History** (PRD-F §4), once asked: the frame's edit as it stands is its history's base, *Original*, and
    /// nothing else is kept. Through the page's session where one is open (its Undo forgets with it), the store's
    /// otherwise.
    func clearHistory(_ frameID: LibraryFrame.ID) {
        if let session = heldSession(frameID) { session.clearHistory(); return }
        guard let now = historyRevision(frameID) else { return }
        history.send("clear") { try await $0.clear(frameID, keeping: now) }
    }

    /// Settings › Storage's *Clear All…* (PRD-F §4): every frame's history, gone; an open page's frame keeps its edit
    /// as it stands as its new Original.
    func clearAllHistory() {
        // A page's session numbers its steps as the store does: its frame is cleared as Clear History clears it (the
        // cursor's state kept as the base, at its number), not emptied under it.
        let open = Set(sessions.compactMap { id, weak in weak.session?.isHeld == true ? id : nil })
        for id in open { heldSession(id)?.clearHistory() }
        history.send("clear all") { try await $0.clearAll(except: open) }
    }

    /// A pair's or a double's step moved its photographs' decodes: one `composite` step on each photograph, named
    /// with the piece's name (PRD-F §3.3). `before` is each photograph's decode before it.
    private func recordMembers(of compositeID: LibraryFrame.ID, before: [UUID: DecodeSettings]) {
        let name = library.frame(compositeID)?.fileName ?? ""
        // A photograph is never on a page of its own while its piece's page is open (one develop page at a time),
        // so the step is the door's.
        for (id, decode) in before where id != compositeID {
            guard heldSession(id) == nil, let now = historyRevision(id) else { continue }
            var was = now
            was.edit.decode = decode
            let step = HistoryAppend(before: was, after: now, origin: .composite, label: .composite(name), at: Date(), mode: .reconciles)
            history.send("append") { try await $0.append(id, step) }
        }
    }

    /// The session a page has open on this frame, if one has: for the app's
    /// own extensions (`PairKeeping.swift`).
    func openSession(_ frameID: LibraryFrame.ID) -> OpenFrameSession? { heldSession(frameID) }

    /// The session a page has open on this frame, if one has.
    private func heldSession(_ frameID: LibraryFrame.ID) -> OpenFrameSession? {
        guard let session = sessions[frameID]?.session, session.isHeld else { return nil }
        return session
    }

    /// A change to a frame's edit made by a page that is not its develop page
    /// (Crop's Done). Through the develop page's session when that page is
    /// open under it — one develop is asked for, as when a film-side control
    /// is released, and its picture lands on that page. With no page open the
    /// edit goes into the library and the frame's kept develop is made again.
    /// Either way it is one step of the frame's history, of `origin` and `label` (PRD-F §3.3).
    func change(_ frameID: LibraryFrame.ID, as origin: HistoryOrigin, _ label: HistoryLabel, _ mutate: (inout FrameEdit) -> Void) {
        change(frameID, cause: .asked, as: origin, label, mutate)
    }

    /// `change`, saying why: a setting held over the library is a `sweep`, which on the Mac develops nothing
    /// (`DevelopCause`).
    private func change(_ frameID: LibraryFrame.ID, cause: DevelopCause, as origin: HistoryOrigin, _ label: HistoryLabel,
                        _ mutate: (inout FrameEdit) -> Void) {
        if let session = heldSession(frameID) {
            session.recording(origin, label) {
                session.began(.shoot)
                session.change(mutate)
                session.ended()
            }
        } else {
            guard let before = library.frame(frameID)?.edit, let was = historyRevision(frameID) else { return }
            var after = before
            mutate(&after)
            guard after != before else { return }
            library.update(frameID) { $0.edit = after }
            recordStep(frameID, before: was, origin: origin, label: label)
            // Edit's layer alone (Light, Curve, Colour) is the same develop: its edited copy follows instead.
            var beside = after
            beside.adjustments = before.adjustments
            // Enable HDR: the same picture, a map in its file — but a slide's is developed again, stretched
            // (`HDRGain.sdrWire`). The stored choice, not `hdr`.
            if HDRGain.sdrWire(for: after) == HDRGain.sdrWire(for: before) { beside.hdrChoice = before.hdrChoice }
            if beside != before { develop(frameID, cause: cause) }
        }
    }

    /// *Copy into Spek*, of frames read in place from Photos: each one's original is brought (from iCloud
    /// if need be) and kept in the app as its own (`Originals.keepInApp`), so the photo may be deleted
    /// from Photos. A frame being read just now is given a copy rather than its working copy moved, so a
    /// job holding the old path still reads it. How many are kept.
    @discardableResult
    func copyIntoSpek(_ ids: [LibraryFrame.ID]) async -> Int {
        var kept = 0
        for id in ids {
            guard let frame = library.frame(id), frame.readsFromPhotos else { continue }
            guard await originals.bring(frame, asked: true) == .here else { continue }
            if originals.keepInApp([id], evenInUse: true) == 1 { kept += 1 }
        }
        originals.copies.trim()
        return kept
    }

    /// Settings › Sources › *Keep Originals in Spek*, at launch and when it is
    /// turned on: every frame read in place from Photos whose working copy is
    /// here keeps it as its own original (`Originals.keepInApp`); one whose copy
    /// is away moves the next time it is brought. How many moved.
    @discardableResult
    func keepPhotosOriginals() -> Int {
        originals.keepInApp(library.frames.filter(\.readsFromPhotos).map(\.id))
    }

    /// The camera's crop (`CameraCrop`, 2026-11-05) for the frames made before it was read: 2.1.3 made
    /// every frame of a Leica Q3 DNG uncropped, and only a new frame takes it as it is made. At launch,
    /// once for each frame: a DNG frame whose crops are as they were made (`CameraCrop.owing`) has its
    /// header read off the main thread and takes the camera's crop, if there is one; a frame whose crop
    /// was edited keeps it; either is then marked (`LibraryFrame.cameraCropRead`) and never asked again,
    /// so a Reset to the whole picture after this stays. A file that cannot be read now (away, on a disk
    /// not mounted) is left unmarked and read at a later launch. A frame open on a develop page meanwhile
    /// is not changed under it (and is asked at the next launch). The develop that follows is a `sweep`:
    /// on the Mac nothing is developed until the picture is opened or exported (`develop`). How many were
    /// owed a read.
    @discardableResult
    func holdCameraCrops() -> Int {
        var owed: [(id: LibraryFrame.ID, url: URL)] = []
        library.batch {
            for f in library.frames {
                switch CameraCrop.owing(fileName: f.fileName, isPair: f.isPair, isDemo: f.isDemo, read: f.cameraCropRead, edit: f.edit) {
                case .nothing: continue
                case .settled: library.update(f.id) { $0.cameraCropRead = true }
                // The original — tried even when the library last found it missing (it may be back; an
                // unreadable one just stays owed); never a Photos frame's preview copy, which is not the DNG.
                case .read: if let url = f.developSource ?? (f.readsFromPhotos ? nil : f.picture.fileURL) { owed.append((f.id, url)) }
                }
            }
        }
        guard !owed.isEmpty else { return 0 }
        cameraCrops?.cancel()
        cameraCrops = Task { [weak self] in
            let urls = owed.map(\.url)
            let readings = await Task.detached(priority: .utility) { urls.map { CameraCrop.reading($0) } }.value
            guard let self, !Task.isCancelled else { return }
            var took = 0, away = 0, open = 0
            var redevelop: [LibraryFrame.ID] = []
            self.library.batch {
                for (item, reading) in zip(owed, readings) {
                    // As it is now: an edit or a page since the list was made wins.
                    guard let f = self.library.frame(item.id),
                          CameraCrop.owing(fileName: f.fileName, isPair: f.isPair, isDemo: f.isDemo, read: f.cameraCropRead, edit: f.edit) == .read
                    else { continue }
                    guard self.heldSession(item.id) == nil else { open += 1; continue }
                    let caught = CameraCrop.caughtUp(f.edit, reading: reading, size: f.originalSize)
                    guard caught.read else { away += 1; continue }
                    let cropped = caught.geometry != f.edit.geometry
                    self.library.update(item.id) { $0.edit.geometry = caught.geometry; $0.cameraCropRead = true }
                    if cropped { took += 1; if !f.develop.isBusy { redevelop.append(item.id) } }
                }
            }
            for id in redevelop { self.develop(id, cause: .sweep) }
            Log.note(.library, "camera crops caught up", ["owed": owed.count, "cropped": took, "away": away, "open": open])
        }
        return owed.count
    }

    /// Settings › Develop › *Crop re-maps the frame* moved: a frame's develop page that is open is
    /// developed again at once, where its crop makes the film another size (v1.3.3: "switching it
    /// re-develops the open frame at once"). Nothing else is queued: every other develop, card and
    /// export reads the setting when its wire is made (`EngineRouter.cropIsFrame`), and a kept picture's
    /// stamp says which it was made with.
    /// The lens database changed (Settings' install, add or remove; the popup's Add .lcp File…): every kept resolution is
    /// forgotten and every open photograph resolved again (`OpenFrameSession.resolveLens`), so one the change corrects
    /// now, or no longer, is developed again. A frame with no page open is resolved when it is next opened.
    func lensDatabaseChanged() {
        LensResolver.forgetAll()
        for case let session? in sessions.values.map(\.session) where session.isHeld { session.resolveLens() }
        Log.note(.library, "lens database changed", ["lenses": LensLibrary.shared.lensCount])
    }

    func cropRemapsFrameChanged() {
        for case let session? in sessions.values.map(\.session) { session.filmSizeRuleChanged() }
        Log.note(.library, "crop re-maps the frame", ["on": settings.cropRemapsFrame])
    }

    /// Copy Settings (C7): the frame's settings as they stand — on its develop
    /// page when that is open, in the library otherwise — with the groups ticked.
    func copySettings(of frameID: LibraryFrame.ID, groups: Set<ClipboardGroup>) {
        if let session = heldSession(frameID) { session.copy(groups: groups); return }
        guard let frame = library.frame(frameID) else { return }
        library.clipboard = SettingsClip(groups: groups, settings: frame.edit, sourceName: frame.fileName,
                                         sourceAspect: SettingsClip.shownAspect(frame.originalSize, quarterTurns: frame.edit.geometry.quarterTurns))
    }

    /// Queue a frame's own develop — a shot or an import — at preview size, in
    /// the one queue. Its picture is kept (`DevelopedPicture`), and is what the
    /// library shows. The small decode is priced by the original's size
    /// (`RenderJob.original`): a decoder may hold the whole original while it
    /// makes the small frame.
    ///
    /// **On the Mac only a person's act on this one frame develops it** (`DevelopCause.asked`; the owner,
    /// 2026-10-24: "adding into the .spkcatalog or .spksession does not mean automatic calculation, it's
    /// triggered on user behaviour"). A frame that arrives (`ImportService.arrive`: every frame the Mac's
    /// library makes for an export, a carry into Develop or the Light Table), the launch's catch-up
    /// (`developStale`) and a setting held over the library (`resized`) queue
    /// nothing there: such a frame shows its file's own preview (`FrameView`) until it is opened in
    /// Develop — whose page develops it and leaves its picture behind as the frame's (`OpenFrameSession.close`)
    /// — or exported, which develops from the original anyway. Until 2026-10-24 exporting or carrying 500
    /// pictures also queued 500 develops nobody asked for. The window and the reference device are as they were.
    func develop(_ frameID: LibraryFrame.ID, kind: JobKind = .importDevelop, cause: DevelopCause = .asked) {
        guard cause == .asked else { return }
        guard let frame = library.frame(frameID) else { return }
        // A develop that reads an original which stays in Photos takes its turn
        // to have it brought (`awaitOriginal`); any other is queued now.
        if darkroom.makesPictures, darkroom.sources(of: frame).contains(where: { $0.readsFromPhotos && $0.original.isAvailable }) {
            awaitOriginal(frameID, kind: kind)
        } else {
            queueDevelop(frame, kind: kind)
        }
    }

    /// The frame's own develop, queued: its job's id, or nil when there is
    /// nothing to develop it from and nothing was queued.
    @discardableResult
    private func queueDevelop(_ frame: LibraryFrame, kind: JobKind) -> UUID? {
        let job = RenderJob(frameID: frame.id, kind: kind, tier: .preview, canvas: frame.canvas(frame.edit),
                            what: StockCatalog.shared.pairText(frame.edit.params),
                            decodesOriginal: true, original: darkroom.openSize(frame, edit: frame.edit),
                            printLayers: darkroom.printLayers(frame, edit: frame.edit),
                            // A cropped frame's decode is larger than its canvas (`previewDevelopLongEdge`).
                            opens: frame.previewDevelopOpens(frame.edit),
                            rawDecode: darkroom.decodesRAW(frame, edit: frame.edit),
                            scenePlanes: frame.isComposite ? 0 : SceneLayerWire.priced(frame.edit.layers, source: frame.originalSize).planes,
                            scenePlaneBytes: frame.isComposite ? 0 : SceneLayerWire.priced(frame.edit.layers, source: frame.originalSize).bytes)
        // The frame's file, its decode and its whole wire, as they are now. A
        // frame the engine has nothing to develop from — a demo picture, an
        // original that is away — is not queued: it keeps the picture it has.
        guard darkroom.prepare(job, frame: frame, edit: frame.edit, purpose: .keep,
                               longEdge: frame.previewDevelopLongEdge(frame.edit)) else { return nil }
        library.update(frame.id) { $0.develop = .queued }
        let id = scheduler.submit(job)
        Task { [weak self] in
            _ = await self?.scheduler.outcome(of: id)
            self?.darkroom.forget(id)
        }
        return id
    }

    // MARK: originals that stay in Photos

    /// A frame whose develop reads an original that stays in Photos joins the
    /// line: **one at a time** has its original brought into the working
    /// copies, is developed, and lets it go before the next is brought. A
    /// library of such frames developed again at launch, or three hundred
    /// picked at once, would otherwise hold every original here together —
    /// each kept from being cleared by the job waiting to read it — and the
    /// limit would mean nothing. Its tile carries the queue's ring meanwhile.
    private func awaitOriginal(_ frameID: LibraryFrame.ID, kind: JobKind) {
        if !queuedDevelops.contains(where: { $0.id == frameID }) { queuedDevelops.append((frameID, kind)) }
        library.update(frameID) { $0.develop = .queued }
        guard bringer == nil else { return }
        bringer = Task { [weak self] in
            while let self, let next = self.queuedDevelops.first {
                self.queuedDevelops.removeFirst()
                await self.developQueuedFrame(next.id, kind: next.kind)
            }
            self?.bringer = nil
        }
    }

    /// Every preview develop still to run or running, taken out (the Mac's Stop, 2026-11-05): from the
    /// scheduler's own list and the line of Photos originals, not from the tiles' states, which a develop
    /// asked again while it ran can show done. The page's and its neighbours' full-size renders stay.
    func stopPreviewDevelops() {
        let waiting = queuedDevelops.map(\.id)
        queuedDevelops.removeAll()
        let ids = Set(scheduler.snapshots.filter { $0.job.kind == .importDevelop && $0.job.tier != .full }.map(\.job.frameID)).union(waiting)
        for id in ids {
            scheduler.cancelAll(frameID: id) { $0.kind == .importDevelop && $0.tier != .full }
            library.update(id) { if $0.develop.isBusy { $0.develop = .developed } }
        }
    }

    private func developQueuedFrame(_ frameID: LibraryFrame.ID, kind: JobKind) async {
        /// Nothing was queued for it after all: the ring comes off its tile.
        func rest() { library.update(frameID) { if $0.develop == .queued { $0.develop = .developed } } }
        // A page that has the frame open develops it itself, and leaves its
        // develop behind when it closes (`OpenFrameSession.close`).
        guard let frame = library.frame(frameID), heldSession(frameID) == nil else { return rest() }
        reading = Set(darkroom.sources(of: frame).map(\.id)).union([frameID])
        defer {
            reading = []
            // Read, and kept in the app before the limit could clear its copy.
            originals.keepInApp(Array(darkroom.sources(of: frame).map(\.id)) + [frameID])
            originals.copies.trim()
        }
        // A RAW whose proxy is here develops from it: the original stays where it is.
        if darkroom.needsBringing(frame, edit: frame.edit) {
            guard await darkroom.bring(frame, asked: false) == .here else { return rest() }
        }
        guard let now = library.frame(frameID), heldSession(frameID) == nil,
              let job = queueDevelop(now, kind: kind) else { return rest() }
        _ = await scheduler.outcome(of: job)
    }

    /// The frames whose originals are being read now — by the queue's develop
    /// under way, by an open develop page, by an export — and, for a
    /// half-frame pair among them, the frames on it: their working copies are
    /// not cleared (`WorkingCopies.inUse`).
    private func originalsInUse() -> Set<LibraryFrame.ID> {
        var ids = reading
        // A session a page holds: one no page holds has closed, and reads nothing.
        for (id, kept) in sessions where kept.session?.isHeld == true { ids.insert(id) }
        if let exporting = exporter.reading { ids.insert(exporting) }
        for id in ids {
            guard let frame = library.frame(id) else { continue }
            if frame.isPair { ids.formUnion(darkroom.sources(of: frame).map(\.id)) }
            // A double exposure's photographs, as its piece names them (`composedOf`).
            else if frame.isDouble { ids.formUnion(frame.composedOf) }
        }
        return ids
    }

    /// Frames leave the library, and what the app kept of them goes with
    /// them: their queued work, their own copies and preview copies, their
    /// kept develops and their working copies. Never an original in Photos or
    /// in a linked folder.
    ///
    /// **A double exposure's photograph removed leaves its layer empty** (RFC-047 §5, `emptyDoubles`), and
    /// one left with no exposure goes with its last photograph; a double exposure removed leaves both.
    func remove(_ asked: Set<LibraryFrame.ID>) {
        let ids = asked.union(doublesLeftEmpty(by: asked))
        let frames = ids.compactMap { library.frame($0) }
        // The proxies they name, asked while they are still frames: those no frame left names go with them.
        let proxies = darkroom.proxyNames(of: frames)
        for id in ids { scheduler.cancelAll(frameID: id) }
        queuedDevelops.removeAll { ids.contains($0.id) }
        library.remove(ids)
        emptyDoubles(holding: ids)
        // Their found masks' folders, each file another frame still names handed to it first (RFC-052 §8.2).
        let remaining = Dictionary(library.frames.map { ($0.id, $0.edit) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .utility) { await FoundMaskKeeping.framesRemoved(ids, remaining: remaining) }
        // Their histories go with them (PRD-F §3.3); a file that moved keeps its frame, and so its history.
        history.send("remove") { try await $0.remove(ids) }
        // The library is written before the files go: one that still named
        // them after the app was ended would come back with frames of nothing.
        library.flush()
        originals.copies.remove(ids, proxies: proxies)
        stockPreviews.discard(Array(ids))
        Task.detached(priority: .utility) { ImportService.discard(frames) }
        LibraryPreviews.forget(ids)
        // A pair's file in the app's storage, and its row in the Mac library (`MacPairRows.swift`).
        macLibrary.pairsRemoved(frames)
        // A double exposure's recipe and its row, the same way (`MacDoubleRows.swift`).
        macLibrary.doublesRemoved(frames)
    }

    /// Whether a develop that reads an original in Photos is waiting its turn
    /// or under way (`awaitOriginal`): the queue is not idle while one is,
    /// though the scheduler may be between two of them.
    var isBringingOriginals: Bool { bringer != nil }

    /// F5's limit for the working copies: kept, and held at once — the oldest
    /// go until what is left fits.
    func setWorkingCopiesLimit(_ bytes: Int64) {
        library.storage.workingCopiesLimit = bytes
        settings.workingCopiesLimit = bytes
        originals.copies.limit = bytes
    }

    /// The full-size renders' own budget (`AppSettings.fullRenderCacheLimit`): kept, and held at once —
    /// lowered, the renders used longest ago go until what is left fits, never one shown or being made
    /// (`WorkingCopies.fullLimit`).
    func setFullRenderCacheLimit(_ bytes: Int64) {
        settings.fullRenderCacheLimit = bytes
        originals.copies.fullLimit = bytes
        originals.copies.trimFull()
        library.measureStorage()
    }

    /// The full renders the limit may not take now, by file name: the one each open develop page shows or
    /// is making, every full render's job queued or under way, the renders of the frame an export is
    /// reading, and on the Mac the current Develop frame's and the Light Table's (`MacRenderCache.pinned`).
    private func fullRendersInUse() -> Set<String> {
        var names = Set<String>()
        #if SPK_ENGINE
        names.formUnion(FullRenderJobs.names)
        for (_, kept) in sessions {
            if let s = kept.session, s.isHeld, let n = s.fullView.pinnedName { names.insert(n) }
        }
        names.formUnion(renderCache.pinned)
        #endif
        if let exporting = exporter.reading {
            names.formUnion(originals.copies.fulls.keys.filter { WorkingCopies.proxyFrame($0) == exporting })
        }
        return names
    }

    /// A memory warning (`RenderQueue.onTrimCaches`): the full-size pictures held in memory and not on
    /// screen go first — a develop page's detail of its render where no page holds it now, the Light
    /// Table's films out of view (`spkReleaseFullSize`). What is shown stays.
    func releaseFullSize() {
        #if SPK_ENGINE
        for (_, kept) in sessions {
            guard let s = kept.session, !s.isHeld else { continue }
            s.fullView.releaseDetail()
        }
        #endif
        NotificationCenter.default.post(name: .spkReleaseFullSize, object: nil)
    }

    /// F5's limit for everything under `Previews`: held at once by Develop's
    /// cards, which go first and alone (`StorageTidy.holdCards(sharing:)`). No
    /// render is cleared by it: how a tile whose preview has gone gets it back
    /// is not decided.
    func setPreviewCopiesLimit(_ bytes: Int64) {
        library.storage.previewCopiesLimit = bytes
        settings.previewCopiesLimit = bytes
        Task.detached(priority: .utility) { StorageTidy.holdCards(sharing: ImportService.previews, limit: bytes) }
    }

    /// F5's *Clear Working Copies*: every working copy but those being read
    /// now, and every full-size render but those shown or being made. They
    /// come back when a frame needs them.
    func clearWorkingCopies() {
        guard originals.copies.folder != nil else {
            library.storage.workingCopies = 0       // the drawings' own library: its figure is the drawing's
            return
        }
        originals.copies.clear()
        library.measureStorage()
    }

    /// At launch: a half-frame pair's own size is its two frames' — the piece
    /// at the size neither picture is enlarged in (`HalfFramePair.pieceSize`).
    /// A pair with a photo in Photos on it, made before 2026-10-10, was laid
    /// out from that frame's preview copy's size, which is what such a frame
    /// was developed from then (`LibraryFrame.developSize`): it is laid out
    /// again from the original's. Its stamp moves with that, so it is
    /// developed again in the queue. No other pair is touched.
    private func holdPairsToTheirFrames() {
        for item in library.frames {
            guard let pair = item.pair else { continue }
            let frames = darkroom.held(by: pair)
            guard frames.values.contains(where: \.readsFromPhotos) else { continue }
            let own = pair.pieceSize(frames, longEdge: nil)
            guard own.width > 0, own.height > 0, own != item.originalSize else { continue }
            library.update(item.id) { f in
                f.originalSize = own
                f.previewSize = own.scaled(toLongEdge: settings.previewLongEdge)
            }
        }
    }

    /// At launch, once for a library: every RAW frame whose file is here is
    /// held to that file (`Originals.holdToItsFile`) — its size read again by
    /// the decoder that will open it. A build before 2026-10-12 took a RAW's
    /// size from the file's first image, which in a Sony ARW, a Fuji RAF and
    /// an Adobe-laid DNG is its embedded preview or thumbnail
    /// (`ImportService.probe`): the testers' libraries have such frames,
    /// developed from 1,616 or 252 pixels. One whose size moves is developed
    /// again (`resized`). Off the main thread, a file at a time; what a
    /// library costs is a twentieth of a second a RAW frame, once.
    ///
    /// Kept as done only when it has gone through them all, and with it the
    /// frames whose file was not there to read: a camera's RAW in a linked
    /// folder is on a card or a disk, which is the likeliest file to be away
    /// at that one launch. Those are asked again at each launch after it
    /// (`holdRAWsStillOwed`) until they have been read or have left the
    /// library. A frame read in place from Photos is not among them: its
    /// working copy is read whenever it is fetched (`Originals.fetch`). And
    /// any frame is held before its export is planned (`ExportService`).
    private func holdRAWsToTheirFiles(keeping: Bool) {
        guard keeping else { return }
        if defaults.bool(forKey: Self.rawSizesHeldKey) { holdRAWsStillOwed() } else { holdRAWsToTheirFiles() }
    }

    /// A later launch's part: the frames the library's one reading found
    /// away, asked again.
    func holdRAWsStillOwed() {
        let owed = Set((defaults.stringArray(forKey: Self.rawSizesOwedKey) ?? []).compactMap { UUID(uuidString: $0) })
        if !owed.isEmpty { holdRAWsToTheirFiles(only: owed) }
    }

    /// The reading itself, whatever is kept of an earlier one (a check's way
    /// in): of every RAW frame, or of `only` these.
    func holdRAWsToTheirFiles(only: Set<LibraryFrame.ID>? = nil) {
        let ids = library.frames.filter { $0.isRAW && !$0.isPair && !$0.isDemo && (only?.contains($0.id) ?? true) }.map(\.id)
        sizing?.cancel()
        sizing = Task { [weak self] in
            var owed: [String] = []
            for id in ids {
                guard let self, !Task.isCancelled else { return }
                await self.originals.holdToItsFile(id)
                if !self.originals.isHeld(id), self.library.frame(id)?.readsFromPhotos == false { owed.append(id.uuidString) }
            }
            guard !Task.isCancelled else { return }
            self?.defaults.set(true, forKey: Self.rawSizesHeldKey)
            self?.defaults.set(owed, forKey: Self.rawSizesOwedKey)
        }
    }
    private static let rawSizesHeldKey = "library.rawSizesHeld"
    static let rawSizesOwedKey = "library.rawSizesOwed"

    /// A frame's size was corrected from its file (`Originals.take`). A
    /// half-frame pair it is on was laid out from the old size and is laid
    /// out again; and the frame's kept develop is of the smaller picture, so
    /// it joins the queue — unless a develop of it is already on its way (the
    /// fetch that found the size out is one) or a page has it open, which
    /// develops it itself.
    private func resized(_ id: LibraryFrame.ID) {
        for item in library.frames {
            guard let pair = item.pair else { continue }
            let frames = darkroom.held(by: pair)
            guard frames.values.contains(where: { $0.id == id }) else { continue }
            let own = pair.pieceSize(frames, longEdge: nil)
            guard own.width > 0, own.height > 0, own != item.originalSize else { continue }
            library.update(item.id) { f in
                f.originalSize = own
                f.previewSize = own.scaled(toLongEdge: settings.previewLongEdge)
            }
            if library.frame(item.id)?.develop.isBusy == false, heldSession(item.id) == nil { develop(item.id, cause: .sweep) }
        }
        // A double exposure holding it is sized again too (RFC-048 §5).
        resizedDoubles(holding: id)
        guard let frame = library.frame(id), !frame.develop.isBusy, heldSession(id) == nil else { return }
        develop(id, cause: .sweep)
    }

    /// At launch: what the app keeps on disk, held to the library as it was
    /// just read. A working copy, a kept develop, a preview copy or a pair's
    /// guide whose frame is no longer in the library goes; so does what an
    /// import the app was ended in the middle of left in the temporary files.
    /// Before a build of 2026-10-10 a removed frame's kept develop stayed
    /// behind for good.
    func tidyStorage() {
        originals.copies.sweep(known: Set(library.frames.filter(\.readsFromPhotos).map(\.id)),
                               library: Set(library.frames.map(\.id)))
        let kept = Set(library.frames.flatMap { [$0.picture, $0.developed?.picture, $0.originalPicture] }
            .compactMap { $0?.fileURL?.lastPathComponent })
        let frames = Set(library.frames.map(\.id))
        let limit = library.storage.previewCopiesLimit
        // The found masks' folders of frames the library no longer has (a frame `layers.json` still names is kept).
        let edits = Dictionary(library.frames.map { ($0.id, $0.edit) }, uniquingKeysWith: { a, _ in a })
        let shelf = library.persistence?.layersURL
        Task.detached(priority: .utility) { await FoundMaskKeeping.launchTidy(edits: edits, layersFile: shelf) }
        // A develop kept in a catalog's or a session's previews (`LibraryPreviews`, 2026-11-05) is of that
        // library until the frame is carried from another: read from the paths alone, no disk is asked.
        LibraryPreviews.remember(library.frames.compactMap { f in f.developed?.picture.fileURL.map { (f.id, $0) } })
        Task.detached(priority: .utility) {
            let swept = ImportService.sweepPreviews(keeping: kept)
            // Develop's cards: a frame that is gone takes its folder; all of them held to what the renders leave.
            let cards = StorageTidy.cardsFolder(in: ImportService.previews)
            StorageTidy.sweepCards(cards, keepingFrames: frames)
            StorageTidy.holdCards(sharing: ImportService.previews, limit: limit)
            if swept.files > 0 {
                Logger(subsystem: "com.spektralab.mac", category: "originals")
                    .info("\(swept.files) files under Previews belonged to no frame and went: \(swept.bytes) bytes")
            }
        }
    }

    /// Every frame whose kept develop is missing, or was made from something
    /// else — another edit, another engine, another way of decoding — joins
    /// the queue, behind anything a page asks for. At launch; and it is what
    /// brings a library made before the engine was linked up to date.
    /// On the Mac nothing (`DevelopCause.sweep`): a frame there is developed when a person opens it.
    func developStale() {}

    /// A frame's develop has been written: it is the frame's picture from now
    /// on, and the one it replaces goes.
    private func kept(_ frameID: LibraryFrame.ID, _ picture: DevelopedPicture) {
        guard let frame = library.frame(frameID) else {
            Task.detached(priority: .utility) { ImportService.discard(picture) }    // its frame was removed meanwhile
            return
        }
        let old = frame.developed
        library.update(frameID) { $0.developed = picture }
        if let old, old.picture != picture.picture {
            Task.detached(priority: .utility) { ImportService.discard(old) }
        }
        library.measureStorage()
    }

    /// The camera's own white balance, read from a RAW at its first decode:
    /// what As Shot means for this frame, and what White Balance's ↺ returns
    /// to. Kept only while the frame is As Shot, and it is not an edit — the
    /// decode it describes is the one just made.
    private func readAsShot(_ frameID: LibraryFrame.ID, _ temperature: Double, _ tint: Double) {
        guard let frame = library.frame(frameID), frame.edit.decode.whiteBalance == .asShot,
              frame.edit.decode.temperature != temperature || frame.edit.decode.tint != tint else { return }
        library.update(frameID) { $0.edit.decode.temperature = temperature; $0.edit.decode.tint = tint }
        sessions[frameID]?.session?.readAsShot(temperature, tint)
    }

    /// Provenance from the decode just performed, not a setting or another
    /// exposure. A late callback from a replaced source/treatment is ignored.
    private func readRawExposure(_ frameID: LibraryFrame.ID, _ facts: RawExposureFacts) {
        guard let frame = library.frame(frameID),
              frame.developSource?.standardizedFileURL.path == facts.sourcePath,
              frame.edit.decode.rawExposureTreatment == facts.treatment,
              frame.edit.rawExposureFacts != facts else { return }
        library.update(frameID) { $0.edit.rawExposureFacts = facts }
        sessions[frameID]?.session?.readRawExposure(facts)
    }

    /// The engine's meter has read one picture of a half-frame pair alone
    /// (`EngineHost.Delivery.metered`): the reading is kept in the pair, for
    /// the hole it was read for, so that picture is read once. Not an edit —
    /// the develop that read it is already of it — so nothing is asked for.
    private func metered(_ pairID: LibraryFrame.ID, _ index: Int, _ ev: Double, _ key: String) {
        guard let frame = library.frame(pairID), frame.pair != nil else { return }
        library.update(pairID) { $0.pair?.keep(reading: ev, of: index, for: key, method: frame.edit.params.autoExposureMethod) }
    }

    /// The wire this app sends, held once against the engine's own schema: a
    /// name the engine does not know fails a whole open, so it is found here,
    /// at launch, and written to the log — not on the first frame.
    private func checkWire() {
        var edit = FrameEdit.default
        edit.params.autoExposureMethod = edit.params.autoExposureMethod ?? "balanced"
        // With a film edge and a date on, so their fields are held against the schema too.
        edit.filmEdge.active = true
        edit.dateBack.active = true
        let wire = edit.engineWire(previewLongEdge: settings.previewLongEdge,
                                   film: FilmWire(edgeText: "SPEKTRA 400", fNumber: 2.8, dateText: "'26 10 7",
                                                  bodySeed: settings.bodySeed))
        // A slide film is scanned, never printed (`StockCatalog.wire`). Held
        // here against the wire this build sends, for every slide in the
        // bundle's catalogue, as a build before 2026-10-09 kept such a frame:
        // the film set, the print left on.
        let printed = StockCatalog.shared.films.filter(\.isPositive).filter { film in
            var kept = FrameEdit.default
            kept.params.filmStock = film.id
            kept.params.scanFilm = false
            return kept.engineWire(previewLongEdge: settings.previewLongEdge)["scan_film"] != .bool(true)
        }.map { "\($0.id): a slide film is sent to be printed" }
        // A black-and-white film on its paper sends what no colour frame does
        // (`StockCatalog.silver`): the paper's filter pack. Held against the
        // schema for every such film in the bundle's catalogue, as a frame
        // that came from a colour paper has it — and each must arrive on a
        // silver paper, with its grain as one layer.
        var silverWires: [(String, [String: ParamValue])] = []
        var unsilvered: [String] = []
        for film in StockCatalog.shared.films where film.isMonochrome {
            var kept = FrameEdit.default
            kept.params.filmStock = film.id
            let sent = kept.engineWire(previewLongEdge: settings.previewLongEdge)
            silverWires.append((film.id, sent))
            if case .string(let paper)? = sent["print_stock"], StockCatalog.shared.isMonochrome(paper),
               sent["y_filter_neutral"] != nil, sent["grain_sublayers_active"] == .bool(false) { continue }
            unsilvered.append("\(film.id): a black-and-white film is not sent as one, on its paper with its filter pack")
        }
        // A half-frame pair's own rows — on its strip, a date in each frame — in the same way:
        // `overscan_pair` and `date_imprint_text_b` are sent for nothing else.
        var strip = HalfFramePair()
        strip.onStrip = true
        var look = HalfFramePair.look(from: edit)
        look.dateBack.active = true
        let pairWire = look.pairWire(strip, previewLongEdge: settings.previewLongEdge,
                                     film: FilmWire(edgeText: "SPEKTRA 400", fNumber: 2.8, dateText: "'26 10 7", bodySeed: settings.bodySeed),
                                     secondDate: "'26 10 8")
        let unsaid = ["overscan_pair", "date_imprint_text_b"].filter { pairWire[$0] == nil }.map { "\($0): not on a pair's wire" }
        Task { [darkroom] in
            let ofPair = await darkroom.wireProblems(pairWire).map { "a pair's " + $0 }
            var ofSilver: [String] = []
            for (film, sent) in silverWires { ofSilver += await darkroom.wireProblems(sent).map { "\(film)'s " + $0 } }
            var problems = await darkroom.wireProblems(wire)
            problems += printed
            problems += ofPair
            problems += unsaid
            problems += ofSilver
            problems += unsilvered
            let log = Logger(subsystem: "com.spektralab.mac", category: "engine")
            if problems.isEmpty { log.info("the wire holds against the engine's schema: \(wire.count) fields") }
            for p in problems { log.error("wire: \(p, privacy: .public)") }
            EngineDiagnostics.wireProblems = problems
        }
    }
}

/// Why a frame's own develop is asked for (`AppServices.develop`): on the Mac only `asked` queues one.
enum DevelopCause: Sendable {
    /// A person's act on this one frame: its page left with a picture that is not of its edit, a change
    /// made to it from another page, a paste onto it.
    case asked
    /// It has just arrived: an import, a shot, a frame the Mac's library made.
    case arrival
    /// The library caught up as a whole: the launch's catch-up, a setting held over every frame, a size
    /// read again from its file.
    case sweep
}

extension Notification.Name {
    /// A memory warning: whatever full-size picture is held in memory and not on screen goes
    /// (`AppServices.releaseFullSize`). The Light Table listens.
    static let spkReleaseFullSize = Notification.Name("spk.releaseFullSize")
}

/// An open develop page's session, held weakly: the page owns it.
private struct WeakSession {
    weak var session: OpenFrameSession?
}

/// What the engine's start left for whoever is reading the host from a Mac.
enum EngineDiagnostics {
    @MainActor static var wireProblems: [String] = []
}

/// Everything a film edge's layout depends on.
private struct FilmEdgeKey: Hashable {
    var frame: LibraryFrame.ID
    var size: PixelSize
    var edge: FilmEdgeSettings
    var date: DateBackSettings
    var photo: Geometry
    var stock: String
    var frameSeed: Int
    var body: Int
    var capture: Date
    var exposure: String?
    var forcing: Bool

    static func == (a: FilmEdgeKey, b: FilmEdgeKey) -> Bool {
        a.frame == b.frame && a.size == b.size && a.edge == b.edge && a.date == b.date && a.photo == b.photo
            && a.stock == b.stock && a.frameSeed == b.frameSeed && a.body == b.body && a.capture == b.capture
            && a.exposure == b.exposure && a.forcing == b.forcing
    }

    /// The cheap parts; equality settles the rest.
    func hash(into hasher: inout Hasher) {
        hasher.combine(frame)
        hasher.combine(edge.format)
        hasher.combine(edge.turn)
        hasher.combine(edge.mode)
        hasher.combine(stock)
        hasher.combine(body)
        hasher.combine(forcing)
    }
}

extension View {
    /// Hand a page everything it reads.
    @MainActor
    func appEnvironment(_ model: AppServices) -> some View {
        environment(model)
            .environment(model.router)
            .environment(model.library)
            .environment(model.scheduler)
            .environment(model.settings)
            .environment(model.recipes)
            .environment(model.exporter)
            .environment(model.diagnostics)
            .environment(model.window)
            .environment(\.isSnapshot, model.isSnapshot)
            .modifier(LanguageHost())
    }
}

/// The app's language, for what the system formats and sets by itself under these pages: a date, a
/// number, the direction and breaking of a line. The pages' own words do not come from here — each
/// is looked up with `L` — but a page that reads the locale is drawn again with them when the
/// language is changed in Settings.
private struct LanguageHost: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, Language.shared.current.locale)
    }
}
