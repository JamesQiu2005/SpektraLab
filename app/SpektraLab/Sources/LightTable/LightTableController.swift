//  LightTableController.swift — the light table's intents, and what is shown between them.
//
//  The one thing a page talks to (RFC-045, "Module boundary"). The designed controls — not part of
//  this round — call the intents below; nothing here draws a control or decides a gesture. What it
//  owns:
//
//  - **The table** (`LightTableModel`): which frames lie on it, where, in what pile; and the view
//    onto it (`LightTableViewport`).
//  - **What is shown between where things were and where they are to be** (`LightTableShown`, the
//    website's `animate`): a film eases to its place and angle, fades onto the light once its
//    picture is on the GPU and off it when it is taken away, rises under a finger. The zoom eases
//    over 260 ms. The lamp's gloss follows an eye that drifts for 20 s after the last touch and then
//    rests, so an idle table draws nothing (the website's loop, `frame`). Reduce Motion: every step
//    lands at once and the eye does not drift.
//  - **The pictures** (`LightTableTextures`): which film needs which size, from where it is and
//    how large it is shown — and, where nothing large enough of a film is kept, one job for it asked of
//    whoever keeps the renders (`wantsFull`; the Mac's `MacRenderCache`), the film wearing the develop
//    ring meanwhile (`making`), and let go of when the film comes off or the table closes (`letsGo`).
//  - **What is kept** (`LightTableStore`) and **the share picture** (`LightTableShare`).
//
//  Intents (RFC-045's list, and those a gesture needs between its start and end): `add`, `remove`,
//  `move`, `turn`, `turnQuarter`, `bringToTop`, `select`, `zoom(to:around:)`, `fit`, `loupe(at:)`,
//  `tidyUp`, `random`, `scatter`, `share`; `setTable(paper:portrait:)` (the table's size and which way it is
//  turned, the page's choice: the pad and the films glide there together, `TableGlide`); `beginHold`/`hold`/`endHold` (the view under fingers),
//  `beginCarry`/`carry`/`endCarry` (a film under them), `fingers(down:)`, `press`. None of them
//  needs a long press.
//
//  Main thread only. The view (`LightTableView`) calls `advance` before each picture and draws
//  only while something is still on its way, or while fingers are on the table (`needsFrames`): then
//  at the display's own rate, 120 Hz on a ProMotion screen.

import CoreGraphics
import Foundation
import Metal
import Observation
import QuartzCore
import UIKit

@MainActor
@Observable
final class LightTableController {
    // MARK: what a page reads

    private(set) var model = LightTableModel()
    private(set) var viewport = LightTableViewport()
    /// The film chosen: the one a turn or a removal from the page's controls applies to.
    private(set) var selected: UUID?
    /// The loupe is up (or on its way up).
    private(set) var loupeOn = false
    /// The angle of the film being turned, as a person reads it, while it is turned (`showAngle`).
    private(set) var turningAngle: String?
    /// What was last said for a reader (`say`): a film placed, taken off, turned.
    private(set) var announcement = ""
    /// Points a millimetre on the screen the table is on, where it is known: a window in the
    /// `ActualSize` table, on its own screen. Nil on the host, and wherever 1:1 is not offered.
    private(set) var pointsPerMM: Double?
    /// The table at its real size (the window's Actual Size, 1:1): `pointsPerMM` points a millimetre,
    /// kept through a window's resize and a turn; a pinch, Fit, a double tap, a zoom to a film or a
    /// change of the table's size leaves it.
    private(set) var isActualSize = false

    // MARK: what the table keeps between pictures

    @ObservationIgnored private var shown: [UUID: LightTableShown] = [:]
    /// The draw order: the pile, with films on their way off still in their places.
    @ObservationIgnored private var drawn: [UUID] = []
    @ObservationIgnored private var frames: [UUID: LibraryFrame] = [:]
    @ObservationIgnored private var sources: [UUID: LightTableSource] = [:]
    /// Each film's full-size render kept on disk, where there is one (`fullRender`).
    @ObservationIgnored private var fulls: [UUID: LightTableFullRef] = [:]
    @ObservationIgnored private let bodySeed: Int
    @ObservationIgnored private let store: LightTableStore
    @ObservationIgnored let renderer: LightTableRenderer?
    @ObservationIgnored private(set) var textures: LightTableTextures?
    @ObservationIgnored private var reduce = UIAccessibility.isReduceMotionEnabled
    /// The screen's pixels a point.
    @ObservationIgnored private(set) var scale = 3.0
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var texturesStale = true
    @ObservationIgnored private var last = CACurrentMediaTime()
    @ObservationIgnored private var lastTouch = CACurrentMediaTime()
    @ObservationIgnored private var sheen = SIMD3<Double>(0, 0, 0.075)
    @ObservationIgnored private var sheenSet = false
    @ObservationIgnored private var zoomTween: (from: Double, to: Double, t0: Double, at: CGPoint?)?
    /// A zoom that also carries a table point to the middle of the room (`zoomToFilm`): where the
    /// middle looked when it began, and where it is to look.
    @ObservationIgnored private var zoomCarry: (from: CGPoint, to: CGPoint)?
    /// The view easing back within its limits after fingers let go of it past them (the rubber
    /// band's way back): where it began, and where it is going.
    @ObservationIgnored private var viewTween: (zoom: Double, cx: Double, cy: Double, to: LightTableViewport, t0: Double)?
    /// The table changing size or turning (`setTable`, an Undo of it): under way, and the pad's half
    /// size drawn this moment.
    @ObservationIgnored private var glide: TableGlide?
    @ObservationIgnored private var drawnHalf: CGSize?
    /// The view gliding to its fit in a new shape (the host turned, `layout`): where it began,
    /// where it is going, on `TableGlide`'s spring.
    @ObservationIgnored private var turnTween: (zoom: Double, cx: Double, cy: Double, to: LightTableViewport, t0: Double)?
    @ObservationIgnored private var loupeA = 0.0
    /// Where the finger the loupe follows is, points; the lens sits clear of it (`loupePlace`).
    @ObservationIgnored private var loupePoint = CGPoint.zero
    @ObservationIgnored private var loupePlace = LightTableLoupePlace()
    @ObservationIgnored private var memoryWatch: NSObjectProtocol?
    /// Asks the view for pictures again: something changed, or is on its way.
    @ObservationIgnored var onChange: (() -> Void)?

    // The renders kept for the frames (2026-10-24): set by whoever keeps them — the Mac's
    // `MacRenderCache.attach` — and nil elsewhere, where the table reads what the library has, as it did.

    /// A frame's full-size render kept on disk, where there is one.
    @ObservationIgnored var fullRender: ((LibraryFrame) -> LightTableFullRef?)?
    /// Whether a full-size render of a frame can be made at all (`FullView.hasMore`).
    @ObservationIgnored var canMakeFull: ((LibraryFrame) -> Bool)?
    /// Films on the table with nothing kept as large as they are shown: one job each, asked.
    @ObservationIgnored var wantsFull: ((Set<UUID>) -> Void)?
    /// Films that came off the table, or the table closed: their jobs that have not started go.
    @ObservationIgnored var letsGo: ((Set<UUID>) -> Void)?
    /// Before a contact sheet is drawn: the films it will read larger than anything kept of them are made,
    /// and waited for (`LightTableExport.run`).
    @ObservationIgnored var makesFullForExport: ((Set<UUID>) async -> Void)?
    /// The films whose picture is being made, and how far (0…1; below 0, waiting its turn): each drawn
    /// with the develop ring, as a developing tile is (`LightTableMetalView`).
    /// Observed (2026-10-24): the Mac's rail draws the same ring on its tiles.
    private(set) var making: [UUID: Double] = [:]
    /// Counts each time the films' pictures are read again from what is kept (a render landed, the library
    /// changed): the Mac's rail reads its tiles again.
    private(set) var picturesChanged = 0
    /// Mac (2026-10-24): the film the Click tool has picked up, following the pointer until a click puts it
    /// down (`pickUp`, `follow`, `putDown`); and where it lay when picked up, for Escape.
    private(set) var held: UUID?
    @ObservationIgnored private var heldFrom: CGPoint?
    /// Mac: the lens is centred on the pointer (a mouse's loupe, the website's), not held clear of a finger.
    @ObservationIgnored var lensOnPointer = false
    /// The eye's drift is off: a still picture (the snapshot harness), or Reduce Motion.
    @ObservationIgnored var still = false
    /// The desk under the pad on the screen: the app's black (the page), or the website's white
    /// (the harness's stills, held against the website's). The share picture is always white.
    @ObservationIgnored var darkDesk = true

    // A gesture under way: the view held by fingers, or a film carried by them (`turns`: two
    // fingers turned it; it is kept on the light only when they let go).
    @ObservationIgnored private var fingers: LightTableFingers?
    @ObservationIgnored private var carrying: (id: UUID, carry: LightTableCarry, turns: Bool)?
    /// Fingers are on the table: the view draws at the display's rate until they lift.
    @ObservationIgnored private var fingersDown = false
    @ObservationIgnored private var pressTimer: Task<Void, Never>?

    init(frames: [LibraryFrame], bodySeed: Int, store: LightTableStore, renderer: LightTableRenderer? = LightTableRenderer.shared) {
        self.bodySeed = bodySeed
        self.store = store
        self.renderer = renderer
        if let renderer {
            let t = LightTableTextures(renderer: renderer)
            t.onLoaded = { [weak self] in self?.texturesLanded() }
            textures = t
        }
        for f in frames { self.frames[f.id] = f }
        // What was kept, laid out again; a frame the library no longer has is left out.
        if let kept = store.load() {
            // at the size and the way up it was kept: a file from before there were sizes is A4
            model = kept.model(portrait: kept.portrait) { [frames = self.frames] id in
                frames[id].map { LightTableFrames.size(of: $0, bodySeed: bodySeed) }
            }
            for it in model.pile { shown[it.id] = .placed(it, kept: true) }
            drawn = model.order
        } else {
            // A new table: A4, portrait, as the host is held (design/lighttable). From here on its
            // size and its way up are the person's (`setTable`).
            model.orient(portrait: true)
        }
        refreshSources()
        textures?.onAsks = { [weak self] ids in self?.lacking(ids) }
        watchMemory()
    }

    /// A memory warning, from UIKit or from the scheduler's own reading (`spkReleaseFullSize`).
    private func watchMemory() {
        guard memoryWatch == nil else { return }
        memoryWatch = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.memoryWarning() }
        }
        pressureWatch = NotificationCenter.default.addObserver(forName: .spkReleaseFullSize, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.memoryWarning() }
        }
    }
    @ObservationIgnored private var pressureWatch: NSObjectProtocol?

    /// The table closed: what is kept is written now, every texture goes.
    func close() {
        store.saveNow(model)
        textures?.empty()
        renderer?.release()
        for id in shown.keys { shown[id]?.ready = false }
        texturesStale = true
        if let memoryWatch { NotificationCenter.default.removeObserver(memoryWatch) }
        if let pressureWatch { NotificationCenter.default.removeObserver(pressureWatch) }
        memoryWatch = nil
        pressureWatch = nil
        letsGo?(Set(model.items.map(\.id)))
    }

    /// The page in front again after `close` (a develop pushed over it and gone back from): the
    /// library read again, the memory watched again; the pictures are read again as they are drawn.
    func reopen(_ frames: [LibraryFrame]) {
        watchMemory()
        sync(frames)
    }

    /// The films out of view let go of their textures; those in view keep theirs — what is shown stays
    /// (2026-10-24; until then every texture went). The bytes let go of, for the log and the checks.
    @discardableResult
    func memoryWarning() -> Int {
        let freed = textures?.releaseHidden() ?? 0
        for id in shown.keys { shown[id]?.ready = textures?.texture(id) != nil }
        kick()
        return freed
    }

    /// How many films hold a texture now, and which are in view: what a memory warning keeps.
    var textureFilms: (count: Int, visible: Set<UUID>, held: Set<UUID>) {
        (textures?.entries.count ?? 0, textures?.visible ?? [], Set(textures?.entries.keys.map { $0 } ?? []))
    }
    /// Where each film's picture was last read from (`LightTableTextures.origin`), and its texture's long edge.
    func textureFacts(_ id: UUID) -> (from: String?, edge: Int?, width: Int?) {
        (textures?.readFrom[id], textures?.entries[id]?.edge, textures?.entries[id].map { max($0.texture.width, $0.texture.height) })
    }

    // MARK: the renders kept for the films

    /// Films with nothing kept as large as they are drawn: those on the table are asked for.
    private func lacking(_ ids: Set<UUID>) {
        let on = ids.filter { model.item($0)?.on == true }
        if !on.isEmpty { wantsFull?(on) }
    }

    /// A film's picture is being made (and how far), or is no longer: its ring.
    func setMaking(_ next: [UUID: Double]) {
        guard next != making else { return }
        making = next
        kick()
    }

    /// A render landed or went: every film's picture is read again from what is kept now.
    func rendersChanged() {
        refreshSources()
        picturesChanged += 1
        changed(textures: true)
    }

    /// Where a film's picture is read from at `edge` pixels, by the table's own rule (`LightTableTextures.effective`:
    /// its kept develop, its full render kept, or what the frame gives meanwhile), and never a job asked: the
    /// Mac's rail draws its tiles from the same pictures as the table.
    func pictureSource(_ id: UUID, edge: Int) -> LightTableSource {
        guard let f = frames[id] else { return .none }
        let want = LightTableTextures.Want(id: id, source: sources[id] ?? .none, pixels: Double(edge), visible: true, aspect: 1,
                                           full: fulls[id], keptEdge: LightTableFrames.keptEdge(of: f), hasMore: canMakeFull?(f) ?? false)
        return LightTableTextures.effective(want, edge: edge).0
    }

    /// The films the next contact sheet reads larger than anything kept of them, for `sheetK` pixels a
    /// millimetre: the ones a job is to be asked for before it is drawn.
    func lackingForExport(pixelsPerMM sheetK: Double) -> Set<UUID> {
        var out: Set<UUID> = []
        for it in model.pile {
            guard let f = frames[it.id] else { continue }
            let step = LightTableExportPlan.filmStep(for: max(it.w, it.h) * sheetK)
            let choice = LightTableSteps.choose(step: step, keptEdge: LightTableFrames.keptEdge(of: f),
                                                hasMore: canMakeFull?(f) ?? false, fullKept: fulls[it.id] != nil)
            if choice.asks { out.insert(it.id) }
        }
        return out
    }

    /// Where one film's picture is read from: what the library gives, and its full render kept.
    private func read(_ id: UUID, _ f: LibraryFrame) {
        sources[id] = LightTableFrames.source(of: f, bodySeed: bodySeed)
        fulls[id] = fullRender?(f)
    }

    // MARK: the library

    /// The library as it is now: a frame it let go of drops off the table, and every film's size
    /// and picture is read again from its frame (a format changed, a develop landed).
    func sync(_ frames: [LibraryFrame]) {
        var next: [UUID: LibraryFrame] = [:]
        for f in frames { next[f.id] = f }
        for it in model.items where next[it.id] == nil {
            model.forget(it.id)
            shown[it.id] = nil
            drawn.removeAll { $0 == it.id }
            if selected == it.id { selected = nil }
        }
        for it in model.items {
            guard let f = next[it.id], f != self.frames[it.id] else { continue }
            model.setSize(it.id, LightTableFrames.size(of: f, bodySeed: bodySeed))
        }
        self.frames = next
        refreshSources()
        picturesChanged += 1
        store.save(model)
        changed(textures: true)
    }

    private func refreshSources() {
        sources = [:]
        fulls = [:]
        for it in model.items { if let f = frames[it.id] { read(it.id, f) } }
    }

    func frame(_ id: UUID) -> LibraryFrame? { frames[id] }

    // MARK: the view

    /// The view laid out: its size in points, the room the page's controls leave, its pixels a
    /// point (`measureStage`). The website turns its table to portrait in a tall window; on the host
    /// the view's shape never turns the table (the owner, 2026-10-19: "selection-based only"), the
    /// person does (`setTable`).
    ///
    /// **The view changing shape** (the host turned, 2026-10-19: "the table itself also rotates and
    /// zooms in / out accordingly"): what fingers held is let go of first — a carried film is set
    /// down where it is, a held view let go — so a turn in the middle of a gesture leaves nothing
    /// half done, and a table changing size glides to its end. Then the view starts at the scale it
    /// had, the same table point in its middle, and glides on `TableGlide`'s spring to its fit in
    /// the new shape (or to the zoom it had, within the new limits); at once under Reduce Motion. The
    /// loupe keeps looking at the table point it looked at.
    func layout(size: CGSize, inset: LightTableViewport.Insets, scale: Double) {
        self.scale = scale
        let reshaped = viewport.measured && size.width >= 1 && size.height >= 1
            && (abs(size.width - viewport.size.width) > 0.5 || abs(size.height - viewport.size.height) > 0.5)
        var before: LightTableViewport?
        var lens: CGPoint?
        if reshaped {
            letGoForTurn()
            before = viewport
            if loupeOn { lens = viewport.toWorld(loupePoint) }
        }
        if viewport.measure(size: size, inset: inset, half: drawnHalf ?? model.half) || !sheenSet {
            // At Actual Size the window's new shape changes what the view holds, not the scale.
            if isActualSize { holdActualSize() }
            if let before { beginTurnGlide(from: before) }
            if let lens { loupePoint = viewport.toScreen(lens); loupePlace.reset() }
            if !sheenSet {
                sheen = SIMD3(viewport.cx - size.width / viewport.s * 0.16, viewport.cy + size.height / viewport.s * 0.2, 0.075)
                sheenSet = true
            }
            changed(textures: true)
        }
    }

    // MARK: intents

    /// Frames onto the table, in order, each at the free spot nearest `at` (the view's middle when
    /// none is given): `place`. A frame already on it comes to the top; one on its way off is put
    /// back where it was. The last one placed is chosen. The count placed: the table holds 99.
    @discardableResult
    func add(_ ids: [UUID], at: CGPoint? = nil) -> Int {
        var placed = 0
        let where_ = at ?? CGPoint(x: viewport.cx, y: viewport.cy)
        for id in ids {
            guard let f = frames[id] else { continue }
            let size = LightTableFrames.size(of: f, bodySeed: bodySeed)
            if var s = shown[id], s.leaving, let it = model.item(id) {
                guard model.place(id, size: size, kept: .init(x: it.x, y: it.y, rot: it.rot, portrait: model.portrait, paper: model.paper))
                else { break }
                s.leaving = false
                s.lift = 0
                shown[id] = s
            } else {
                let was = model.order.contains(id)
                guard model.place(id, size: size, at: where_) else { break }
                if !was, let it = model.item(id) {
                    var s = LightTableShown.placed(it, kept: false)
                    s.ready = textures?.texture(id) != nil
                    shown[id] = s
                }
            }
            read(id, f)
            placed += 1
            selected = id
        }
        // One sentence for a reader, however many were laid down (design/lighttable, VoiceOver).
        if placed == 1, let id = selected, let it = model.item(id) { say(L("\(caption(id)) is on the table, \(sizeText(it)).")) }
        else if placed > 1 { say(L("Laid down \(placed)")) }
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
        return placed
    }

    /// Off the table (`takeOff`): it fades off, lifted, and waits to be put back.
    func remove(_ id: UUID) {
        guard model.item(id)?.on == true else { return }
        model.takeOff(id)
        shown[id]?.leaving = true
        shown[id]?.lift = 0.8
        shown[id]?.held = false
        if selected == id { selected = nil }
        letsGo?([id])
        say(L("\(caption(id)) is off the table."))
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Moved by so many millimetres, kept on the light, to the top.
    func move(_ id: UUID, by d: CGVector) {
        guard model.item(id)?.on == true else { return }
        model.toFront(id)
        model.move(id, by: d)
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Turned by so many radians, counter-clockwise on the table. Within a two-finger turn the
    /// turn counts from where it began, and settles square within 7° (`settle`, `SNAP_TOUCH`);
    /// alone, it settles within 4°.
    func turn(_ id: UUID, byRadians r: Double) {
        guard let it = model.item(id), it.on, carrying?.id != id else { return }
        model.toFront(id)
        setTurn(id, LightTable.settle(it.rot + r))
        model.keepOn(id)
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// A quarter turn to the right (`dir` −1), or to the left (1): the website's Rotate 90°.
    func turnQuarter(_ id: UUID, dir: Int = -1) {
        guard model.item(id)?.on == true else { return }
        model.turnQuarter(id, dir: dir)
        if let it = model.item(id) { say(L("\(caption(id)), at \(LightTable.degrees(it.rot)).")) }
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Turned to an angle, radians counter-clockwise, exactly: the Turn ruler, whose own detent at
    /// square is the only settling (design/lighttable L6). Kept on the light, to the top.
    func setAngle(_ id: UUID, radians r: Double) {
        guard model.item(id)?.on == true else { return }
        model.toFront(id)
        setTurn(id, r)
        model.keepOn(id)
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Every film off the table at once (`···` › Take All Off): they fade off, and wait.
    func removeAll() {
        guard !model.order.isEmpty else { return }
        let n = model.order.count
        for id in model.order {
            model.takeOff(id)
            shown[id]?.leaving = true
            shown[id]?.lift = 0.8
            shown[id]?.held = false
        }
        selected = nil
        letsGo?(Set(model.items.map(\.id)))
        say(L("Taken all off, \(n)"))
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Every film square, in rows, in the order given (`···` › Tidy Up, `LightTableModel.tidy`);
    /// fanned over each other, evenly, when they do not all fit.
    func tidyUp(_ ids: [UUID]) {
        guard !model.order.isEmpty else { return }
        model.tidy(ids)
        say(L("Tidied up"))
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Every film scattered over the light at random, a little turned (`···` › Scatter, 打乱,
    /// `LightTableModel.scatter`), from a new seed each time. The films glide there together on the
    /// table's spring, lifted on the way and set down (`TableGlide`).
    func scatter() {
        guard !model.order.isEmpty else { return }
        model.scatter(seed: UInt64.random(in: .min ... .max))
        say(L("Scattered"))
        rearranged()
    }

    /// Every film laid square at random, as films are first put down (`···` › Random, 随机,
    /// `LightTableModel.random`), from a new seed each time, gliding there as `scatter` does.
    func random() {
        guard !model.order.isEmpty else { return }
        model.random(seed: UInt64.random(in: .min ... .max))
        say(L("Laid at random"))
        rearranged()
    }

    /// The films moved all at once (Scatter, Random): they glide to their places on the table's
    /// spring, the view to fit, the table itself unchanged.
    private func rearranged() {
        rebuildDrawn()
        beginGlide(from: drawnHalf ?? model.half)
        store.save(model)
        changed(textures: true)
    }

    /// The table at a size and a way up, the page's Size and Orientation (`LightTableModel.relayout`):
    /// every film carried in proportion and kept on the light, a tidied table tidied again, none
    /// left out. The pad, the films and the view glide there together (`TableGlide`); at once under
    /// Reduce Motion. False when it already was.
    @discardableResult
    func setTable(paper: LightTablePaper, portrait: Bool) -> Bool {
        guard paper != model.paper || portrait != model.portrait else { return false }
        let from = drawnHalf ?? model.half
        model.relayout(paper: paper, portrait: portrait)
        beginGlide(from: from)
        say(paper.name + ", " + (portrait ? L("Portrait") : L("Landscape")))
        store.save(model)
        changed(textures: true)
        return true
    }

    /// The glide from a pad of half size `from` to the table as it now is: each film from where it
    /// is shown this moment, the view from its zoom to fit. A glide already under way is taken up
    /// from where it is, so a second tap in the middle of one does not jump.
    private func beginGlide(from: CGSize) {
        isActualSize = false
        zoomTween = nil
        zoomCarry = nil
        viewTween = nil
        if reduce || still || !viewport.measured {
            glide = nil
            drawnHalf = nil
            if viewport.measured { viewport.measure(size: viewport.size, inset: viewport.inset, half: model.half) }
            viewport.zoomAt(1, world: .zero, screen: viewport.middle)
            return
        }
        var films: [UUID: TableGlide.Pose] = [:]
        for (id, s) in shown { films[id] = .init(x: s.px, y: s.py, angle: s.angle) }
        glide = TableGlide(from: from, to: model.half, films: films, zoom: viewport.zoom, centre: viewport.toWorld(viewport.middle),
                           t0: CACurrentMediaTime())
        drawnHalf = from
    }

    /// The glide brought to its end at once: fingers landed on the table in the middle of it.
    private func finishGlide() {
        guard glide != nil else { return }
        glide = nil
        drawnHalf = nil
        viewport.measure(size: viewport.size, inset: viewport.inset, half: model.half)
        viewport.zoomAt(1, world: .zero, screen: viewport.middle)
        for id in drawn {
            guard let it = model.item(id), it.on else { continue }
            shown[id]?.px = it.x; shown[id]?.py = it.y; shown[id]?.angle = it.rot; shown[id]?.lift = 0
        }
        texturesStale = true
    }

    /// Before the view changes shape: whatever fingers or a tween were doing is brought to rest.
    private func letGoForTurn() {
        if carrying != nil { endCarry() }
        fingers = nil
        fingersDown = false
        press(nil)
        finishGlide()
        // A zoom asked and still on its way (Fit, then the Mac's rail put away at once) lands where it was going,
        // rather than being dropped half way.
        if let z = zoomTween, zoomCarry == nil { viewport.setZoom(z.to, at: z.at) }
        zoomTween = nil
        zoomCarry = nil
        viewTween = nil
        turnTween = nil
    }

    /// The view from the scale and middle it had in its old shape (`before`) to where it settles
    /// in the new one, which `measure` has just laid out.
    private func beginTurnGlide(from before: LightTableViewport) {
        let to = viewport
        guard !(reduce || still), before.s > 0, to.sFit > 0 else { return }
        let zoom = before.s / to.sFit
        // nothing to glide: the same scale and the same middle
        if abs(log(zoom / to.zoom)) < 1e-3 && abs(before.cx - to.cx) * to.s < 0.5 && abs(before.cy - to.cy) * to.s < 0.5 { return }
        viewport.put(zoom: zoom, cx: before.cx, cy: before.cy)
        turnTween = (zoom, before.cx, before.cy, to, CACurrentMediaTime())
    }

    /// The table as it is, to be put back by `restore` (the page's Undo).
    func snapshot() -> LightTableModel { model }

    /// The table put back as it was (the page's Undo of a take-off, Tidy Up or Take All Off): the
    /// films on it then come back to their places — easing there from where they are, or fading
    /// in where they had already gone — and the films put down since fade off. A frame the library
    /// has let go of meanwhile stays off.
    func restore(_ kept: LightTableModel) {
        let before = Set(model.order)
        var next = kept
        for it in kept.items where frames[it.id] == nil { next.forget(it.id) }
        // the table's size or its way up coming back too: the pad and the films glide back together
        let from = drawnHalf ?? model.half
        model = next
        for it in model.pile {
            if var s = shown[it.id] {
                s.leaving = false
                s.lift = 0
                shown[it.id] = s
            } else {
                var s = LightTableShown.placed(it, kept: true)
                s.ready = textures?.texture(it.id) != nil
                shown[it.id] = s
            }
            if let f = frames[it.id] { read(it.id, f) }
        }
        for id in before where !model.order.contains(id) {
            shown[id]?.leaving = true
            shown[id]?.lift = 0.8
            shown[id]?.held = false
        }
        if let s = selected, !model.order.contains(s) { selected = nil }
        if from != model.half { beginGlide(from: from) }
        say(L("Put back"))
        rebuildDrawn()
        store.save(model)
        changed(textures: true)
    }

    /// Zoomed so the film fills the room the controls leave, carried to its middle (a double tap
    /// on a film, VoiceOver's *Zoom to Film*); back to fit when it already does.
    func zoomToFilm(_ id: UUID) {
        guard let it = model.item(id), it.on else { return }
        let e = it.extent, vp = viewport
        let room = CGSize(width: vp.size.width - vp.inset.left - vp.inset.right, height: vp.size.height - vp.inset.top - vp.inset.bottom)
        let z = LightTableModel.clamp(0.85 * min(room.width / (e.width * vp.sFit), room.height / (e.height * vp.sFit)), 1, LightTable.zoomMax)
        if vp.isZoomed && abs(vp.zoom - z) < 0.05 { fit(); return }
        isActualSize = false
        let from = vp.toWorld(vp.middle)
        if reduce || still {
            viewport.zoomAt(z, world: it.centre, screen: vp.middle)
            changed(textures: true)
            return
        }
        zoomTween = (viewport.zoom, z, CACurrentMediaTime(), nil)
        zoomCarry = (from, it.centre)
        changed(textures: false)
    }

    func bringToTop(_ id: UUID) {
        model.toFront(id)
        rebuildDrawn()
        store.save(model)
        changed(textures: false)
    }

    /// Chosen, or none. A film off the table cannot be chosen.
    func select(_ id: UUID?) {
        selected = id.flatMap { model.item($0)?.on == true ? $0 : nil }
        changed(textures: false)
    }

    /// Zoomed to `z` (1–8×) about a view point, eased over 260 ms (`zoomTo`); the middle of the room
    /// the controls leave when none is given.
    func zoom(to z: Double, around p: CGPoint? = nil) {
        zoom(to: z, around: p, actual: false)
    }

    private func zoom(to z: Double, around p: CGPoint?, actual: Bool) {
        isActualSize = actual
        zoomCarry = nil
        if reduce || still {
            viewport.setZoom(z, at: p)
            changed(textures: true)
            return
        }
        zoomTween = (viewport.zoom, LightTableModel.clamp(z, viewport.zoomFloor, viewport.zoomCeiling), CACurrentMediaTime(), p)
        changed(textures: false)
    }

    // MARK: Actual Size (1:1), the window's

    /// The screen the table is on, in points a millimetre (`ActualSize.pointsPerMM`), told by the
    /// view as it is laid out. Gone (another screen, a model not in the table): Actual Size is left.
    func setPointsPerMM(_ value: Double?) {
        guard value != pointsPerMM else { return }
        pointsPerMM = value
        guard isActualSize else { return }
        if value == nil { fit() } else { holdActualSize(); changed(textures: true) }
    }

    /// The zoom that puts the table at its real size in the view as it is now.
    private var actualZoom: Double? {
        guard let p = pointsPerMM, viewport.sFit > 0 else { return nil }
        return p / viewport.sFit
    }

    /// The zoom's limits made to hold the real size, which may lie under fit (a small table in a large
    /// window) or past 8x; back to 1-8x once the view is at rest and not at Actual Size.
    private func widenLimits(for z: Double) {
        viewport.zoomFloor = min(1, z)
        viewport.zoomCeiling = max(LightTable.zoomMax, z)
    }

    /// 1:1 about the middle of the view, eased as every zoom is; a second call goes back to fit.
    func actualSize() {
        if isActualSize { fit(); return }
        guard let z = actualZoom else { return }
        finishGlide()
        widenLimits(for: z)
        zoom(to: z, around: nil, actual: true)
        say(L("Actual Size"))
    }

    /// At Actual Size, the zoom set again for the view's new fit: the same points a millimetre,
    /// the same table point in the middle.
    private func holdActualSize() {
        guard let z = actualZoom else { isActualSize = false; return }
        widenLimits(for: z)
        zoomTween = nil
        zoomCarry = nil
        viewport.zoomAt(z, world: viewport.toWorld(viewport.middle), screen: viewport.middle)
    }

    /// The limits back to 1-8x when nothing needs them wider, and the view brought within them.
    private func narrowLimitsAtRest() {
        guard !isActualSize, viewport.zoomFloor != 1 || viewport.zoomCeiling != LightTable.zoomMax,
              zoomTween == nil, glide == nil, viewTween == nil, turnTween == nil, fingers == nil, carrying == nil else { return }
        viewport.zoomFloor = 1
        viewport.zoomCeiling = LightTable.zoomMax
        settleView(about: viewport.middle)
    }

    func fit() { zoom(to: 1) }

    /// The loupe under a view point, following it, the lens clear of the finger above it (the
    /// website's touch loupe); nil puts it away. It magnifies what the view shows, three times.
    func loupe(at p: CGPoint?) {
        if let p { loupePoint = p }
        if p != nil && !loupeOn && loupeA < 0.003 { loupePlace.reset() }
        loupeOn = p != nil
        changed(textures: true)
    }

    /// A finger resting on a film: after 110 ms it rises towards the eye (the press's pop), until
    /// it lifts or the touch becomes a gesture. A look only; nothing opens.
    func press(_ id: UUID?) {
        pressTimer?.cancel()
        for k in shown.keys where shown[k]?.pressed == true { shown[k]?.pressed = false }
        if let id {
            pressTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled, let self else { return }
                self.shown[id]?.pressed = true
                self.changed(textures: false)
            }
        }
        changed(textures: false)
    }

    // MARK: gestures, between their start and end

    /// The film under a view point, top first. A film smaller than a finger on the screen (under
    /// 44 points across) is also hit within a 44-point box about its centre, the pile deciding
    /// where boxes overlap (design/lighttable, "Small films", `lighttable_targets.svg`).
    func film(at p: CGPoint) -> UUID? {
        if let id = model.hit(viewport.toWorld(p), shown: { [shown] id in
            shown[id].map { (CGPoint(x: $0.px, y: $0.py), $0.angle, CGSize(width: $0.sw, height: $0.sh)) }
        }) { return id }
        let s = viewport.s, half = 22.0
        for id in model.order.reversed() {
            guard let v = shown[id], !v.leaving, min(v.sw, v.sh) * s < 2 * half else { continue }
            let c = viewport.toScreen(CGPoint(x: v.px, y: v.py))
            if abs(p.x - c.x) <= half && abs(p.y - c.y) <= half { return id }
        }
        return nil
    }

    /// Fingers came down on the table, or the last one lifted. While they are down the view draws
    /// at the display's rate (`needsFrames`), so a pinch or a carry is drawn on every frame the
    /// screen shows, 120 a second on a ProMotion screen. A finger landing stops whatever the view
    /// was doing on its own (a double tap's zoom, the rubber band's way back) where it is, so the
    /// fingers take it from there; the last one lifting with the view still past its limits (a tap
    /// that stopped the way back) sends it back.
    func fingers(down: Bool) {
        if down {
            finishGlide()
            zoomTween = nil
            zoomCarry = nil
            viewTween = nil
            turnTween = nil         // stopped where it is: the fingers take it from there
        } else if fingers == nil && carrying == nil && zoomTween == nil && turnTween == nil && !viewport.isSettled {
            settleView(about: viewport.middle)
        }
        fingersDown = down
        touched()
        changed(textures: false)
    }

    /// The view taken hold of by fingers at these view points (`LightTableFingers`): one pans it,
    /// two or more pan and zoom it, about their middle.
    func beginHold(_ points: [CGPoint]) {
        finishGlide()
        press(nil)
        zoomTween = nil
        zoomCarry = nil
        viewTween = nil
        turnTween = nil
        fingers = LightTableFingers(points, viewport)
        loupe(at: nil)
        touched()
    }

    /// The fingers holding the view are now at these points: it follows them. A finger more or less
    /// takes the hold again, and nothing moves on that step.
    func hold(_ points: [CGPoint]) {
        guard var f = fingers else { return }
        f.move(points, &viewport)
        fingers = f
        // A pinch leaves Actual Size; a pan keeps it.
        if isActualSize, let z = actualZoom, abs(viewport.zoom / z - 1) > 0.005 { isActualSize = false }
        fingersDown = true
        touched()
        changed(textures: false)
    }

    /// The fingers let go of the view, their middle last at `p`: past a limit, it eases back.
    func endHold(about p: CGPoint) {
        guard fingers != nil else { return }
        fingers = nil
        if !isActualSize { viewport.zoomFloor = 1; viewport.zoomCeiling = LightTable.zoomMax }
        settleView(about: p)
        changed(textures: true)
    }

    /// Back within 1–8× and the table, eased over 300 ms (at once with Reduce Motion).
    private func settleView(about p: CGPoint) {
        guard !viewport.isSettled else { return }
        let to = viewport.settled(about: p)
        if reduce || still { viewport = to; changed(textures: true); return }
        viewTween = (viewport.zoom, viewport.cx, viewport.cy, to, CACurrentMediaTime())
        changed(textures: false)
    }

    /// A film taken up by fingers at these view points: it rises, comes to the top and is chosen.
    /// One finger carries it; `turns`, two fingers on the chosen film, also turn it, settling square
    /// within 7°, and it is kept on the light only when they let go (the website's twist).
    func beginCarry(_ id: UUID, _ points: [CGPoint], turns: Bool) {
        finishGlide()
        guard let it = model.item(id), it.on, !points.isEmpty else { return }
        press(nil)
        endCarry()
        zoomTween = nil
        zoomCarry = nil
        carrying = (id, LightTableCarry(points, viewport, centre: it.centre, turn: it.rot), turns)
        model.toFront(id)
        shown[id]?.held = true
        selected = id
        loupe(at: nil)
        touched()
        rebuildDrawn()
        changed(textures: false)
    }

    /// The fingers carrying the film are now at these points: it follows them at once (no easing
    /// under a finger); a finger more or less takes the hold again from where it lies.
    func carry(_ points: [CGPoint]) {
        guard var c = carrying, let it = model.item(c.id) else { return }
        let to = c.carry.move(points, viewport, centre: it.centre)
        carrying = c
        fingersDown = true
        guard let to else { return }
        model.moveTo(c.id, to.centre, keepOn: !c.turns)
        if c.turns { setTurn(c.id, LightTable.settle(to.turn, snap: LightTable.snapTouch)) }
        if let it = model.item(c.id) {
            shown[c.id]?.px = it.x; shown[c.id]?.py = it.y
            if c.turns { shown[c.id]?.angle = it.rot; turningAngle = LightTable.degrees(it.rot) }
        }
        touched()
        changed(textures: false)
    }

    /// The film let go of: on the light, kept; a turn said.
    func endCarry() {
        guard let c = carrying else { return }
        carrying = nil
        turningAngle = nil
        shown[c.id]?.held = false
        model.keepOn(c.id)
        if c.turns, let it = model.item(c.id) { say(L("\(caption(c.id)), at \(LightTable.degrees(it.rot)).")) }
        store.save(model)
        changed(textures: true)
    }

    /// A tap: the film under it chosen, or none (`select(g.under)`).
    func tap(at p: CGPoint) { select(film(at: p)); touched() }

    /// A double tap off a film: zoomed to 2.5× about it, or back to fit (`dblclick`). On a film
    /// (the host's, Photos' double tap to content): zoomed so the film fills the view, or back.
    func doubleTap(at p: CGPoint) {
        if let id = film(at: p) {
            if viewport.isZoomed { fit() } else { zoomToFilm(id) }
        } else {
            zoom(to: viewport.isZoomed ? 1 : 2.5, around: p)
        }
        touched()
    }

    // MARK: the Mac's Click tool and its free turn (2026-10-24, the website's)

    /// The Click tool: a click on a film picks it up (lifted, to the top, chosen) at view point `p`; it follows
    /// the pointer (`follow`) until the next click puts it down (`putDown`).
    func pickUp(_ id: UUID, at p: CGPoint) {
        guard model.item(id)?.on == true else { return }
        if held != nil { putDown() }
        heldFrom = model.item(id)?.centre
        beginCarry(id, [p], turns: false)
        held = id
    }

    /// The pointer moved with a film in hand: the film with it, kept on the light.
    func follow(_ p: CGPoint) {
        guard held != nil else { return }
        carry([p])
    }

    /// The film in hand put down where it is, or (`back`, Escape) where it was picked up. The film put down.
    @discardableResult
    func putDown(back: Bool = false) -> UUID? {
        guard let id = held else { return nil }
        held = nil
        if back, let from = heldFrom { model.moveTo(id, from, keepOn: true) }
        heldFrom = nil
        endCarry()
        fingers(down: false)
        rebuildDrawn()
        changed(textures: true)
        return id
    }

    /// A free turn begins (the Click tool, from just outside a corner, or two fingers on a trackpad): the film
    /// chosen, to the top, a little lifted, its angle said while it turns.
    func beginTurn(_ id: UUID) {
        guard model.item(id)?.on == true else { return }
        finishGlide()
        press(nil)
        model.toFront(id)
        shown[id]?.turning = true
        selected = id
        if let it = model.item(id) { turningAngle = LightTable.degrees(it.rot) }
        rebuildDrawn()
        touched()
        changed(textures: false)
    }

    /// The film at an angle, radians counter-clockwise, as the turn has settled it.
    func turnFreely(_ id: UUID, to rot: Double) {
        guard model.item(id)?.on == true else { return }
        setTurn(id, rot)
        shown[id]?.angle = rot
        turningAngle = LightTable.degrees(rot)
        fingersDown = true
        touched()
        changed(textures: false)
    }

    /// The turn let go of: kept on the light, kept, and said.
    func endTurn(_ id: UUID) {
        shown[id]?.turning = false
        turningAngle = nil
        model.keepOn(id)
        fingersDown = false
        if let it = model.item(id) { say(L("\(caption(id)), at \(LightTable.degrees(it.rot)).")) }
        store.save(model)
        changed(textures: true)
    }

    // MARK: the share picture

    /// The whole table as one picture with the mark and the code (`LightTableShare`). The films
    /// are read first at the size the picture shows them, the pile is drawn at rest, the gloss
    /// where it rests when the page opens. Nil without the GPU.
    func share() async -> CGImage? {
        guard let renderer, let textures else { return nil }
        let half = model.half
        let poster = LightTableExportPlan.poster(half: half)
        let k = LightTableShare.long / max(poster.width, poster.height)          // px a mm
        textures.update(model.pile.map { it in
            LightTableTextures.Want(id: it.id, source: sources[it.id] ?? .none, pixels: max(it.w, it.h) * k, visible: true,
                                    aspect: it.w / max(it.h, 1e-6))
        })
        // The reads land one at a time; the picture waits for them, five seconds at most.
        for _ in 0..<100 where !textures.isIdle { try? await Task.sleep(for: .milliseconds(50)) }
        let films = model.pile.map { it -> LightTableRenderer.Film in
            let s = LightTableShown.atRest(it, ready: textures.texture(it.id) != nil)
            return LightTableRenderer.Film(centre: it.centre, angle: it.rot, size: it.size, presence: s.presence, shadow: s.shadow,
                                           texture: textures.texture(it.id))
        }
        let scene = LightTableRenderer.Scene(half: half, films: films,
                                             sheen: SIMD3(Float(-0.3 * half.width), Float(0.45 * half.height), 0.075))
        let image = LightTableShare.poster(half: half) { x0, y0, x1, y1, px in renderer.picture(scene, x0: x0, y0: y0, x1: x1, y1: y1, px: px) }
        changed(textures: true)
        return image
    }

    /// The pile at rest, bottom first, and each film's picture: what an export draws, off the main
    /// thread (`LightTableExport`).
    func exportFilms() -> [LightTableExporter.Film] {
        model.pile.map { it in
            let f = frames[it.id]
            return LightTableExporter.Film(item: it, source: sources[it.id] ?? .none, full: fulls[it.id],
                                           keptEdge: f.flatMap(LightTableFrames.keptEdge(of:)),
                                           hasMore: f.map { canMakeFull?($0) ?? false } ?? false)
        }
    }

    // MARK: each picture

    /// Something changed: a picture is due, and — `textures` — the films' sizes may want reading again.
    private func changed(textures t: Bool) {
        dirty = true
        if t { texturesStale = true }
        onChange?()
    }

    private func kick() { changed(textures: false) }
    private func touched() { lastTouch = CACurrentMediaTime() }

    private func texturesLanded() {
        for id in shown.keys { shown[id]?.ready = textures?.texture(id) != nil }
        changed(textures: false)
    }

    /// True while something is on its way, or the eye drifts: the view keeps drawing.
    private(set) var needsFrames = false

    /// One step of everything towards where it is going (`frame`, `animate`), and the picture to
    /// draw. Nil when nothing has changed since the last one.
    func advance(now: CFTimeInterval = CACurrentMediaTime()) -> (scene: LightTableRenderer.Scene, loupe: LightTableRenderer.Loupe?)? {
        reduce = UIAccessibility.isReduceMotionEnabled
        let dt = min(0.05, max(0, now - last))
        last = now
        var busy = false
        // the films
        for id in drawn {
            guard var s = shown[id] else { continue }
            s.chosen = id == selected && !loupeOn
            let target = model.item(id) ?? LightTableItem(id: id, size: CGSize(width: s.sw, height: s.sh), x: s.px, y: s.py, rot: s.angle)
            if s.step(towards: target, dt: dt, reduce: reduce) { busy = true }
            shown[id] = s
        }
        // the table changing size or turning: the pad, every film and the view on one curve
        if let g = glide {
            let f = TableGlide.share(now - g.t0)
            let half = g.half(at: f)
            drawnHalf = half
            viewport.measure(size: viewport.size, inset: viewport.inset, half: half)
            viewport.zoomAt(exp(log(g.zoom) * (1 - f)), world: CGPoint(x: g.centre.x * (1 - f), y: g.centre.y * (1 - f)),
                            screen: viewport.middle)
            for id in drawn {
                guard let it = model.item(id), it.on, var s = shown[id], let p = g.pose(it, at: f) else { continue }
                s.px = p.pose.x; s.py = p.pose.y; s.angle = f >= 1 ? it.rot : p.pose.angle
                s.lift = max(s.lift, p.lift)
                shown[id] = s
            }
            if f >= 1 { glide = nil; drawnHalf = nil; texturesStale = true } else { busy = true }
        }
        // gone: off the table for good, until it is put back
        let gone = drawn.filter { shown[$0]?.leaving == true && shown[$0]?.presence == 0 }
        if !gone.isEmpty {
            drawn.removeAll { gone.contains($0) }
            for id in gone { shown[id] = nil }
            texturesStale = true
        }
        // the view easing back within its limits
        if let t = viewTween {
            let f = min(1, (now - t.t0) / 0.3), e = 1 - pow(1 - f, 3)
            viewport.put(zoom: exp(log(t.zoom) + (log(t.to.zoom) - log(t.zoom)) * e),
                         cx: t.cx + (t.to.cx - t.cx) * e, cy: t.cy + (t.to.cy - t.cy) * e)
            if f >= 1 { viewport = t.to; viewTween = nil; texturesStale = true } else { busy = true }
        }
        // the view gliding to its fit after the host turned
        if let t = turnTween {
            let f = TableGlide.share(now - t.t0)
            viewport.put(zoom: exp(log(t.zoom) + (log(t.to.zoom) - log(t.zoom)) * f),
                         cx: t.cx + (t.to.cx - t.cx) * f, cy: t.cy + (t.to.cy - t.cy) * f)
            if f >= 1 { viewport = t.to; turnTween = nil; texturesStale = true } else { busy = true }
        }
        // the zoom
        if let z = zoomTween {
            let f = min(1, (now - z.t0) / 0.26), e = 1 - pow(1 - f, 3)
            if let c = zoomCarry {
                let w = CGPoint(x: c.from.x + (c.to.x - c.from.x) * e, y: c.from.y + (c.to.y - c.from.y) * e)
                viewport.zoomAt(z.from + (z.to - z.from) * e, world: w, screen: viewport.middle)
            } else {
                viewport.setZoom(z.from + (z.to - z.from) * e, at: z.at)
            }
            if f >= 1 { zoomTween = nil; zoomCarry = nil; texturesStale = true } else { busy = true }
        }
        // past Actual Size, the zoom's limits back to 1-8x (and the view eased within them)
        narrowLimitsAtRest()
        if viewTween != nil { busy = true }
        // the loupe
        let la = loupeA, on = loupeOn ? 1.0 : 0
        loupeA = reduce ? on : loupeA + (on - loupeA) * (1 - exp(-dt / 0.07))
        if abs(loupeA - on) < 0.004 { loupeA = on }
        if loupeA != la { dirty = true }
        if loupeA != on { busy = true }
        // the lens going round the finger, near an edge
        if loupeA > 0.003, !lensOnPointer, loupePlace.step(finger: loupePoint, view: viewport.size, radius: viewport.lensRadius,
                                            rim: viewport.lensRim, dt: dt, reduce: reduce) {
            busy = true
        }

        // the gloss: a lamp over the top left of the table reflects half way between itself and the
        // eye, which the finger under the loupe stands in for; with no finger the eye drifts, slowly,
        // and then rests, so an idle table draws nothing
        let size = viewport.size, s = viewport.s
        var e = viewport.toWorld(CGPoint(x: size.width / 2, y: size.height / 2))
        var drift = false
        let pointer = loupeOn
        if pointer { e = viewport.toWorld(loupePoint) }
        else if !reduce && !still && now - lastTouch < 20 {
            e.x += sin(now * 0.21) * size.width / s * 0.3
            e.y += cos(now * 0.17) * size.height / s * 0.25
            drift = true
        }
        let l0 = viewport.toWorld(CGPoint(x: size.width * 0.18, y: size.height * 0.1))
        let resting = !pointer && !drift
        let tx = resting ? sheen.x : (l0.x + e.x) / 2, ty = resting ? sheen.y : (l0.y + e.y) / 2
        let gain = pointer ? 0.11 : 0.075
        let k = reduce ? 1 : 1 - exp(-dt / (pointer ? 0.09 : 0.6))
        sheen.x += (tx - sheen.x) * k; sheen.y += (ty - sheen.y) * k; sheen.z += (gain - sheen.z) * k
        let off = abs(tx - sheen.x) + abs(ty - sheen.y) + 100 * abs(gain - sheen.z)
        if off > 0.02 || drift { dirty = true }
        if off > 0.02 && !drift { busy = true }

        if busy { dirty = true }
        if texturesStale && !busy { refreshTextures() }
        // Fingers down keep the display link running; one that has not moved for 3 s no longer
        // does (a lift the recognisers never told would otherwise keep it ticking for nothing).
        if fingersDown && now - lastTouch > 3 { fingersDown = false }
        needsFrames = busy || drift || fingersDown
        guard dirty else { return nil }
        dirty = false
        return (scene(), loupeDraw())
    }

    private func scene() -> LightTableRenderer.Scene {
        var films: [LightTableRenderer.Film] = []
        films.reserveCapacity(drawn.count)
        for id in drawn {
            guard let s = shown[id] else { continue }
            films.append(LightTableRenderer.Film(centre: CGPoint(x: s.px, y: s.py), angle: s.angle, size: s.drawnSize,
                                                 presence: s.presence, shadow: s.shadow, texture: textures?.texture(id)))
        }
        return LightTableRenderer.Scene(half: drawnHalf ?? model.half, films: films, sheen: SIMD3(Float(sheen.x), Float(sheen.y), Float(sheen.z)),
                                        darkDesk: darkDesk)
    }

    /// The lens: grown with its fade, round the finger and clear of it, inside the view
    /// (`LightTableLoupePlace`: above where it can be, beside or below near the top, eased round).
    private func loupeDraw() -> LightTableRenderer.Loupe? {
        guard loupeA > 0.003 else { return nil }
        let R = viewport.lensRadius, rim = viewport.lensRim
        let grow = reduce ? 1 : 0.86 + 0.14 * loupeA
        let out = R + rim + 2
        let at = lensOnPointer
            ? CGPoint(x: LightTableModel.clamp(loupePoint.x, out, max(out, viewport.size.width - out)),
                      y: LightTableModel.clamp(loupePoint.y, out, max(out, viewport.size.height - out)))
            : loupePlace.centre(finger: loupePoint, view: viewport.size, radius: R, rim: rim)
        return LightTableRenderer.Loupe(at: at, looks: viewport.toWorld(loupePoint), radius: R * grow,
                                        rim: rim * grow, targetRadius: R, alpha: loupeA)
    }

    /// Which film needs which size now: its long edge on the screen, three times that under the
    /// loupe; a film out of the view at the size it has in the fitted view.
    private func refreshTextures() {
        texturesStale = false
        textures?.update(wants())
    }

    private func wants() -> [LightTableTextures.Want] {
        let size = viewport.size, s = viewport.s
        let a = viewport.toWorld(.zero), b = viewport.toWorld(CGPoint(x: size.width, y: size.height))
        let view = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        var lens: CGRect?
        if loupeOn {
            let c = viewport.toWorld(loupePoint), r = LightTable.lensPad * viewport.lensRadius / (s * LightTable.mag)
            lens = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
        var wants: [LightTableTextures.Want] = []
        wants.reserveCapacity(drawn.count)
        for id in drawn {
            guard let it = model.item(id), it.on || shown[id]?.leaving == true else { continue }
            let e = it.extent
            let box = CGRect(x: it.x - e.width / 2, y: it.y - e.height / 2, width: e.width, height: e.height)
            let long = max(it.w, it.h)
            var px = long * viewport.sFit * scale
            let inView = box.intersects(view)
            if inView { px = long * s * scale }
            if let lens, box.intersects(lens) { px = long * s * LightTable.mag * scale }
            let f = frames[id]
            wants.append(.init(id: id, source: sources[id] ?? .none, pixels: px, visible: inView, aspect: it.w / max(it.h, 1e-6),
                               full: fulls[id], keptEdge: f.flatMap(LightTableFrames.keptEdge(of:)),
                               hasMore: f.map { canMakeFull?($0) ?? false } ?? false))
        }
        return wants
    }

    // MARK: the chosen film's ring, words

    /// The chosen film's outline on the screen (the website's keyboard ring, `placeRing`): its
    /// centre, its size with 4 points round it, and its angle on the screen (clockwise).
    var ring: (centre: CGPoint, size: CGSize, angle: Double)? {
        guard let id = selected, let s = shown[id], model.item(id)?.on == true else { return nil }
        let c = viewport.toScreen(CGPoint(x: s.px, y: s.py))
        return (c, CGSize(width: s.sw * viewport.s + 8, height: s.sh * viewport.s + 8), -s.angle)
    }

    /// The develop rings of the films whose picture is being made: each at its film's middle on the
    /// screen this moment, with how far it is (below 0: waiting its turn). Not under the loupe.
    var makingRings: [(id: UUID, centre: CGPoint, progress: Double)] {
        guard !loupeOn else { return [] }
        return making.compactMap { id, p in
            guard let s = shown[id], model.item(id)?.on == true else { return nil }
            return (id, viewport.toScreen(CGPoint(x: s.px, y: s.py)), p)
        }
    }

    /// A film's box on the screen, points: the bounds of its turned outline as drawn now
    /// (VoiceOver's frame for it).
    func screenBox(_ id: UUID) -> CGRect? {
        guard let s = shown[id], model.item(id)?.on == true else { return nil }
        let c = abs(cos(s.angle)), n = abs(sin(s.angle))
        let w = (c * s.sw + n * s.sh) * viewport.s, h = (n * s.sw + c * s.sh) * viewport.s
        let p = viewport.toScreen(CGPoint(x: s.px, y: s.py))
        return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
    }

    func caption(_ id: UUID) -> String {
        frames[id].map(LightTableFrames.caption(of:)) ?? ""
    }

    private func sizeText(_ it: LightTableItem) -> String {
        let l = it.lying
        return "\(LightTable.mm(l.width)) × \(LightTable.mm(l.height)) mm"
    }

    private func say(_ text: String) {
        announcement = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func setTurn(_ id: UUID, _ rot: Double) { model.setRotation(id, rot) }

    /// The draw order: the pile, each film on its way off kept at its place in the order before.
    private func rebuildDrawn() {
        let leaving = drawn.enumerated().filter { shown[$0.element]?.leaving == true && !model.order.contains($0.element) }
        var next = model.order
        for (i, id) in leaving { next.insert(id, at: min(i, next.count)) }
        drawn = next
    }

    // MARK: for the harness and the checks

    /// Everything at rest at once: the films where they are going, the zoom where it is going.
    func settleNow() {
        for id in drawn {
            guard var s = shown[id], let it = model.item(id) else { continue }
            s.held = false; s.pressed = false; s.turning = false
            s.px = it.x; s.py = it.y; s.angle = it.rot; s.sw = it.w; s.sh = it.h; s.lift = 0; s.pop = 0
            s.presence = s.ready ? 1 : 0
            shown[id] = s
        }
        drawn.removeAll { shown[$0]?.leaving == true }
        if let z = zoomTween { viewport.setZoom(z.to, at: z.at); zoomTween = nil }
        if let t = viewTween { viewport = t.to; viewTween = nil }
        if let t = turnTween { viewport = t.to; turnTween = nil }
        finishGlide()
        loupeA = loupeOn ? 1 : 0
        dirty = true
        texturesStale = true
    }

    /// The table's textures now, bytes, and the most they have held.
    var textureBytes: (now: Int, peak: Int, budget: Int) {
        (textures?.bytes ?? 0, textures?.peakBytes ?? 0, textures?.budget ?? 0)
    }

    /// Asks for the films' pictures at the sizes the view needs now (the harness, before it waits).
    func requestTextures() { refreshTextures() }

    /// The same, read at once on this thread: a check's still picture, never a page's.
    func requestTexturesNow() {
        texturesStale = false
        textures?.updateNow(wants())
        for id in shown.keys { shown[id]?.ready = textures?.texture(id) != nil }
    }

    /// Every film's picture has landed at the size asked.
    var texturesSettled: Bool {
        guard let textures else { return true }
        return model.pile.allSatisfy { sources[$0.id] == LightTableSource.none || textures.entries[$0.id] != nil } && textures.isIdle
    }
}
