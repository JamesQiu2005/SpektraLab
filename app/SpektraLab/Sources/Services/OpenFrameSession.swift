//  OpenFrameSession.swift — one frame on the develop page: its edit, and when it renders.
//
//  The desktop's `RenderQueue` idea (what the engine *has* against what the
//  user *wants*, one render for the whole difference), under RFC-036's rules:
//
//  - **There is no live render.** A control's binding follows the finger, so
//    the number beside it is live; a render is a scheduled job.
//  - **Print-side edits** (paper, brightness, filtration, pre-flash) are a
//    reprint from the cached negative — 53-57 ms on the reference device at 2,560 px —
//    so they are asked for as the finger moves, coalesced: one in flight, the
//    latest wins (§3.5, R6).
//  - **Film-side edits** (stock, exposure, placement, effects, white balance,
//    crop) develop the negative again — 203-216 ms — so they are asked for when
//    the finger pauses for 150 ms, or lifts.
//
//  The picture on the page is always the last finished develop: never blank,
//  never half drawn. The status line says what is catching up.
//
//  The edit itself is saved the moment it changes — it is the user's intent,
//  whether or not a render has landed.
//
//  **The Latitude card's reading is this session's too** (`latitude`). It is
//  the engine's own measurement of the frame against its film and paper
//  (`spk_scene_latitude`), asked of the engine's session on this frame once a
//  develop of the page's has landed, and again — a quarter of a second after
//  the last one, so a drag is followed by one reading, not by one a step —
//  whenever a later develop or reprint has. The reading on the card stays
//  while a newer one is on its way, so the card does not blink at every edit.
//
//  **Scene Placement goes through the Fit, always** (RFC-023 §8.3). The two
//  pull-backs are what the user dragged and never reach the wire; the curve
//  the engine renders is what the Fit solved from them, on this frame, against
//  this film and paper. A paper change does not fit again: nothing is
//  re-derived behind the user's back.
//
//  **A ruler's step is solved here, at once** (`placeScene`, 2026-10-07; the
//  desktop's fix of 1.3.2). Each step used to ask the engine for its Fit, and
//  that call waits its turn behind whatever develop is running — the one the
//  step before it started — so the answer came a render late; and a ruler
//  offered every value, though the Fit takes a window of them, and on many
//  frames none at all on the shadow side. The solve is arithmetic on the
//  engine's last measurement of the frame (`ScenePlacement.swift`, held to the
//  engine's own fits by the self-test), so a step lands on a pull-back the Fit
//  takes, its curve is committed in the same call, and the Latitude card
//  follows the finger. **The picture still develops when the finger rests**:
//  a solve is not a render.
//
//  So the edit on the page is always a placement the Fit takes, and the
//  library keeps the edit as it is. The exception is a placement the engine
//  has not solved yet — pasted from another frame, or kept by a build with no
//  engine (`placementNeedsFit`): that one the engine itself solves once the
//  page's develop has landed, and a refusal turns it off with the reason on
//  the panel.
//
//  **Edit's Light, Curve and Colour are not a render** (design/v5 §2, 2026-10-15).
//  They are Layer 2 (`FrameEdit.adjustments`): a pass on the GPU over the
//  picture the page already has (`layer2`, `Layer2Live`), at the display's
//  rate, with no job and nothing asked of the scheduler — their changes owe
//  the picture no develop (`ChangeDescriber.layers` does not see them). They
//  are saved the moment they change, like any edit, and every export bakes
//  them. `beganEdit`, `changeEdit` and `endedEdit` are the rulers' contract
//  without the render; the page is on one of two surfaces (`surface`), and
//  the visit's line in the log says how long it spent on each.

import CoreGraphics
import Foundation
import Observation
import UIKit
import os

/// A page revision includes source-owned decode changes made from a pair.
struct DevelopRevision: Equatable {
    var edit: FrameEdit
    var pair: HalfFramePair?
    var sourceDecodes: [UUID: DecodeSettings]

    /// Meter and As Shot readback are observations, not undoable controls.
    /// Pair meter keys still gate reuse if a restored exposure intent differs.
    func keepingReports(from current: DevelopRevision) -> DevelopRevision {
        var copy = self
        func decode(_ saved: DecodeSettings, _ now: DecodeSettings) -> DecodeSettings {
            var value = saved
            if saved.whiteBalance == .asShot, now.whiteBalance == .asShot {
                value.temperature = now.temperature; value.tint = now.tint
            }
            return value
        }
        copy.edit.solvedEV = current.edit.solvedEV
        copy.edit.decode = decode(copy.edit.decode, current.edit.decode)
        for side in HalfFramePair.Side.allCases {
            if var saved = copy.pair?[side], let now = current.pair?[side], saved.frame == now.frame {
                saved.meteredEV = now.meteredEV; saved.meteredFor = now.meteredFor
                saved.decode = decode(saved.decode, now.decode)
                copy.pair?[side] = saved
            }
        }
        for (id, saved) in copy.sourceDecodes {
            if let now = current.sourceDecodes[id] { copy.sourceDecodes[id] = decode(saved, now) }
        }
        return copy
    }
}

@MainActor
@Observable
final class OpenFrameSession {
    let frameID: LibraryFrame.ID
    @ObservationIgnored private let library: FrameCatalog
    @ObservationIgnored private let scheduler: RenderQueue
    @ObservationIgnored private let settings: AppSettings
    /// The app's side of the engine; nil in a test that has none.
    @ObservationIgnored private let darkroom: EngineRouter?
    /// The page left an edit its last picture is not of: the frame's kept
    /// develop is to be made again (`AppServices.develop`).
    @ObservationIgnored var onStale: (() -> Void)?
    @ObservationIgnored var onRestoreRevision: ((DevelopRevision) -> Void)?
    private var history = EditHistory<DevelopRevision>()
    private var historyBefore: DevelopRevision?
    @ObservationIgnored private var replayingHistory = false

    /// What the controls bind to. Set it through `change`, so the session sees it.
    private(set) var edit: FrameEdit
    /// What the last finished render was made from.
    @ObservationIgnored private var rendered: FrameEdit
    /// A half-frame pair: the piece the last finished render was made from.
    /// The piece is the library's (`LibraryFrame.pair`), changed through
    /// `AppServices.changePair`; what a change of it owes the picture is told
    /// from this (`HalfFramePair.changes`).
    @ObservationIgnored private var renderedPair: HalfFramePair?
    /// A half-frame pair: the layer the page's controls are about — the film,
    /// or one of its frames (`pick`). The desktop's `Session.pairLayer`.
    private(set) var layer = HalfFramePair.Layer.film
    /// A half-frame pair on its strip: where the engine put each frame's gate
    /// on the canvas of the develop that last landed (`frameRects`).
    private var gates: [HalfFramePair.Side: CGRect]?
    /// Process (the developed picture) or Original (the frame as decoded).
    var showsOriginal = false
    /// The page's own develop: the last one the engine finished for it, in
    /// memory. Nil until the first lands — the page shows the frame's kept
    /// develop until then — and with an engine that makes no picture.
    private(set) var developed: DevelopedPicture?
    @ObservationIgnored private var developedImage: UIImage?
    @ObservationIgnored private var opened = false

    /// What the Latitude card draws: the engine's measurement of this frame
    /// against its film and paper. In the drawings' own library — whose frames
    /// no engine develops — it is the drawing's reading.
    private(set) var latitude: LatitudeReading
    @ObservationIgnored private var measuring: Task<Void, Never>?
    /// How long after a develop the card is measured again: a drag lands a
    /// render a step, and the reading only has to follow the one that settles
    /// (the desktop's own quarter second).
    static let latitudePause = 0.25

    /// The engine's last measurement of this frame, and the edit it is of with
    /// its placement taken out: Scene Placement moves neither what the film and
    /// paper hold nor where the scene sits (the engine probes the one with the
    /// curve off and reads the other before it), so a ruler's step is solved on
    /// this for as long as nothing else of the picture has changed.
    private var measured: (reply: SceneLatitudeReply, of: FrameEdit, piece: HalfFramePair?)?
    /// The ruler last under a finger on this page: whose end the panel's line
    /// speaks of first (`ScenePlacement.panel`).
    private var placementMoved: PlacementSide?
    /// Why the engine refused a pasted placement; said until a ruler moves.
    private var pastedNote: PlacementNote?
    /// The engine's Fit of a pasted placement, on its way.
    @ObservationIgnored private var fitting: Task<Void, Never>?
    /// Counts the edits that changed the picture under the placement: a reply
    /// that was out across one is not of the picture it was asked of.
    @ObservationIgnored private var turns = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "placement")

    @ObservationIgnored private var pause: Task<Void, Never>?
    @ObservationIgnored private var dragging: ParamLayer?
    /// The job on its way, and the edit it is of. The same edit is not asked
    /// for twice: a finger that lifts while the develop its pause started is
    /// still running would otherwise submit that develop again, and the
    /// scheduler would cancel the one in flight for it — the same picture,
    /// twice the wait (seen in the simulator, 2026-10-05: a develop 0.37 s in,
    /// cancelled and run again from the start).
    @ObservationIgnored private var asked: (id: UUID, target: FrameEdit, piece: HalfFramePair?)?
    /// What the pixels of the last job asked for start from, and of the last
    /// one that finished (`EngineRouter.sourceKey`). A job whose own differs —
    /// another cut for a film edge, another white balance of a RAW — opens
    /// the frame again in the engine, and is priced as a job that decodes.
    /// Both are held because neither says what the engine has: a job that
    /// gave way may or may not have opened its frame first. A job is priced
    /// as opening unless both agree with it.
    @ObservationIgnored private var askedSource: String?
    @ObservationIgnored private var renderedSource: String?
    /// How long a finger must rest before a film-side edit develops (§3.5).
    static let filmSidePause = 0.15
    /// The pages working through this session: the develop page, and the Film
    /// Edge flow when it is presented over it. The last to leave closes it.
    @ObservationIgnored private var holders = 0
    /// The frame's original stays in Photos and is being brought here: the
    /// page's picture is asked for when it has come (`bring`).
    private var bringing: Task<Void, Never>?
    /// Layer 2 on this page: the picture with Edit's Light, Curve and Colour,
    /// and the histogram the Curve draws behind it.
    @ObservationIgnored let layer2 = Layer2Live()
    #if SPK_ENGINE
    /// The page zoomed past its preview: the frame's render at full size (`FullDetail.swift`).
    @ObservationIgnored let fullView: FullView
    #endif
    /// Which surface the page shows: the top bar's Develop | Edit (design/v5 §1).
    var pageNavigation = DevelopPageNavigation()
    var surface: DevelopSurface { pageNavigation.surface }
    /// A finger is on one of Edit's Light, Curve or Colour controls.
    @ObservationIgnored private var editing = false
    /// Why the original could not be brought, for the line under the picture.
    private var notBrought: String?

    init(frameID: LibraryFrame.ID, library: FrameCatalog, scheduler: RenderQueue, settings: AppSettings,
         darkroom: EngineRouter? = nil) {
        self.frameID = frameID
        self.library = library
        self.scheduler = scheduler
        self.settings = settings
        self.darkroom = darkroom
        #if SPK_ENGINE
        fullView = FullView(frameID: frameID, library: library, scheduler: scheduler, darkroom: darkroom)
        #endif
        // The edit as the page takes it: a slide scanned, and the film's long
        // edge the one this photograph makes — a frame kept by a build before
        // 2026-10-09 carries 36 mm whatever its shape, and its page's size
        // cards would say otherwise. (The library's read leaves that length
        // alone: every host photograph is 4:3, and all of them would develop
        // again at launch.)
        let kept = library.frame(frameID)
        var current = (kept?.edit ?? .default).held(to: kept?.originalSize ?? PixelSize(width: 0, height: 0))
        // A half-frame pair's look has no cut and no film edge of a frame's own (`FrameEdit.asPairLook`),
        // and is held to its piece: where the second frame begins, and a placement shown that is
        // of a frame that is there (`HalfFramePair.hold`).
        if let pair = kept?.pair {
            current = current.asPairLook
            pair.hold(&current.params)
            // A hole still empty is what the page is about first: it asks for its frame.
            if pair.isFilled || (pair.left == nil && pair.right == nil) { layer = .film }
            else { layer = pair.left == nil ? .left : .right }
        }
        edit = current
        rendered = current
        renderedPair = kept?.pair
        latitude = Self.unmeasured(darkroom)
        layer2.show(adjustments: current.adjustments)
        layer2.show(picture: Layer2Live.picture(for: kept, developed: nil, edit: current))
        let placement = current.params.sceneLatitude
        // Pull-backs that were never solved — dragged in a build with no engine,
        // which kept them as numbers — wait for this frame's Fit, as pasted ones do.
        if darkroom?.makesPictures == true, !placement.active,
           placement.highlightPullBack > 0 || placement.shadowPullBack > 0 {
            edit.placementNeedsFit = true
        }
    }

    /// Whether the card's reading is the engine's measurement of this frame.
    /// False in the drawings' own library, where it is the drawing's.
    var measuresLatitude: Bool { darkroom?.makesPictures ?? false }

    /// The card before anything has been measured: waiting for the page's
    /// develop where the engine runs; the drawing's reading in the drawings'
    /// own library; and where the engine should be running and is not, nothing
    /// — a drawing is not passed off as this frame's measurement.
    private static func unmeasured(_ darkroom: EngineRouter?) -> LatitudeReading {
        guard let darkroom else { return .measured(.developDemo) }
        if darkroom.makesPictures { return .waiting }
        return darkroom.failure == nil ? .measured(.developDemo) : .unavailable(L("Not measured"))
    }

    var frame: LibraryFrame? { library.frame(frameID) }

    // MARK: who holds it

    /// A page holds this session: `AppServices.session(for:)` hands the same one
    /// to the next page that asks for this frame.
    var isHeld: Bool { holders > 0 }

    /// A page has taken the session up.
    func enter() {
        if holders == 0 {
            let now = Date()
            visit = Visit(began: now, edit: edit, settled: edit, pair: pair, settledPair: pair, clock: SurfaceClock(on: surface, at: now))
            // A page taken up again: the layer is drawn on what the page shows until its develop lands.
            layer2.show(adjustments: edit.adjustments)
            layer2.show(picture: Layer2Live.picture(for: frame, developed: developed, edit: edit))
        }
        holders += 1
    }

    /// A page has left. The last one out closes it: nothing of the frame's
    /// canvas work stays queued and the engine's session on it is given back.
    func leave() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0 else { return }
        visit?.settling?.cancel()
        endHistoryTransaction()
        settle()
        if let visit {
            // The log's line for the visit: how long, what of the edit it touched, what it left changed,
            // and how long it spent on each surface.
            let now = Date()
            Log.developVisit(frame, from: visit.edit, to: edit, pairFrom: visit.pair, pairTo: pair, touched: visit.touched,
                             picked: visit.picked, seconds: now.timeIntervalSince(visit.began), pictures: visit.pictures,
                             surfaces: visit.clock.logged(at: now), endedOn: visit.clock.surface)
        }
        visit = nil
        close()
    }

    /// A visit to the page, for the log: when it began, the edit it began
    /// with, how many pictures the engine has made for it, and the settings
    /// it has touched so far — the edit as it stood at the last pause, and
    /// what has differed from one pause to the next. On a half-frame pair,
    /// the piece beside its look (what a frame has for itself is the piece's),
    /// and the layers the visit picked.
    private struct Visit {
        var began: Date
        var edit: FrameEdit
        var pictures = 0
        var settled: FrameEdit
        var touched: Set<String> = []
        var settling: Task<Void, Never>?
        var pair: HalfFramePair?
        var settledPair: HalfFramePair?
        var picked: Set<String> = []
        /// The surfaces it has been on, and for how long.
        var clock: SurfaceClock
    }
    @ObservationIgnored private var visit: Visit?

    /// The edit has changed: half a second after the last change of a run,
    /// what differs from the pause before is added to what the visit touched.
    /// A setting moved and put back is still one the visit touched; a ruler
    /// dragged is one note, not one a frame.
    private func touched() {
        guard visit != nil else { return }
        visit?.settling?.cancel()
        visit?.settling = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        guard var v = visit else { return }
        let piece = pair
        if v.settled != edit || v.settledPair != piece {
            v.touched.formUnion(Log.editChanges(from: v.settled, to: edit, ofPair: piece != nil))
            v.touched.formUnion(Log.pairChanges(from: v.settledPair, to: piece))
            v.settled = edit
            v.settledPair = piece
        }
        v.settling = nil
        visit = v
    }

    /// The line under the picture.
    var status: DevelopStatus {
        guard let frame else { return DevelopStatus(text: "", busy: false, progress: nil) }
        // An original that stays in Photos, on its way here or not come.
        if bringing != nil { return DevelopStatus(text: L("Reading the original from Photos"), busy: true, progress: nil) }
        if let notBrought { return DevelopStatus(text: L(shown: notBrought), busy: false, progress: nil) }
        let snapshot = scheduler.snapshot(frameID: frameID) { $0.kind.isCanvas }
        let base = DevelopStatus.of(snapshot, frame: frame, thermal: scheduler.frontend.thermal,
                                    engineIsSimulated: !scheduler.engine.makesPictures,
                                    hasDevelop: developed != nil || frame.shownDevelop != nil,
                                    engineFailure: darkroom?.failure)
        if case .failed = snapshot?.state { return base }
        return Self.edited(base, tools: editedTools, on: surface)
    }

    /// The line at rest, with Edit's tools in it (design/v5 §3.1): on Edit,
    /// "Edited · Light · Curve"; on Develop, the line as it was and "· edited".
    /// A line that says something is under way says that alone.
    static func edited(_ base: DevelopStatus, tools: [Adjustments.Tool], on surface: DevelopSurface) -> DevelopStatus {
        guard !tools.isEmpty, !base.busy else { return base }
        switch surface {
        case .edit:
            return DevelopStatus(text: ([L("Edited")] + tools.map(\.title)).joined(separator: Fmt.dot), busy: false, progress: nil)
        case .develop:
            return DevelopStatus(text: base.text + Fmt.dot + L("edited"), busy: false, progress: nil)
        }
    }

    // MARK: the picture

    /// The page appeared. With an engine that makes pictures its canvas
    /// develops once, now: the engine's session on this frame is then open,
    /// and the edits that follow are reprints from its negative (55 ms on the
    /// reference device) or develop it again (0.24 s) instead of each opening the
    /// frame (0.5 s). Priced as what it is: a develop that decodes first.
    func open() {
        guard !opened, let darkroom, darkroom.makesPictures, let frame else { return }
        opened = true
        // Nothing to develop from (an original that is away): nothing to measure.
        latitude = frame.developSource == nil ? .unavailable(L("Not measured")) : .waiting
        // A develop the queue still owes this frame is the page's now: what
        // the page leaves behind is kept as the frame's (`close`), or asked
        // for again there. Left queued it was the same picture developed
        // twice, and its run stood between the page's first picture and the
        // card's reading of it (the simulator, 2026-10-07: a reading 1.35 s
        // after its develop, behind the queue's 0.9 s).
        if frame.developSource != nil {
            scheduler.cancelAll(frameID: frameID) { !$0.kind.isCanvas && $0.tier != .full }
        }
        submit(frame, target: edit, layers: [], opening: true)
    }

    /// A memory/camera trim gave the visible stock strip's decode back. Its
    /// refill is foreground work with the same admission and cancellation as
    /// opening this page. No look/history changes and no parallel RAW decode.
    @discardableResult
    func refillStripSource() -> Bool {
        guard opened, isHeld, let frame else { return false }
        if scheduler.snapshot(frameID: frameID, where: { $0.kind.isCanvas }) != nil { return true }
        submit(frame, target: edit, layers: [], opening: true)
        return true
    }

    /// The camera's own white balance was read at the decode: the page's edit
    /// takes it too, without asking for a develop — the picture is already of it.
    func readAsShot(_ temperature: Double, _ tint: Double) {
        guard edit.decode.whiteBalance == .asShot else { return }
        edit.decode.temperature = temperature
        edit.decode.tint = tint
        rendered.decode.temperature = temperature
        rendered.decode.tint = tint
        // Read, not set by a hand: no change of the visit's.
        visit?.edit.decode.temperature = temperature
        visit?.edit.decode.tint = tint
        visit?.settled.decode.temperature = temperature
        visit?.settled.decode.tint = tint
    }

    /// Decode provenance is readback, not a hand edit or a new render.
    func readRawExposure(_ facts: RawExposureFacts) {
        guard edit.decode.rawExposureTreatment == facts.treatment else { return }
        edit.rawExposureFacts = facts
        rendered.rawExposureFacts = facts
        visit?.edit.rawExposureFacts = facts
        visit?.settled.rawExposureFacts = facts
    }

    /// The engine finished a develop of this page's.
    func landed(_ image: UIImage, stamp: String) {
        let old = developed
        developed = DevelopedPicture(picture: RenderedPictures.shared.put(image),
                                     size: PixelSize(width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale)),
                                     stamp: stamp)
        developedImage = image
        RenderedPictures.shared.remove(old?.picture)
        visit?.pictures += 1
        layer2.show(picture: Layer2Live.picture(for: frame, developed: developed, edit: edit))
    }

    /// True while the edit on the page is ahead of the picture on it: something
    /// a render would show has changed since the last one landed.
    var isCatchingUp: Bool { !owed(to: edit).isEmpty }

    /// What the picture on the page owes `target`: the layers its settings
    /// have moved on, and — for a half-frame pair — what its piece has
    /// (`HalfFramePair.changes`: other pixels and what the film is told of a
    /// frame develop again; a frame's own print alone prints again).
    private func owed(to target: FrameEdit) -> Set<ParamLayer> {
        var layers = ChangeDescriber.layers(from: rendered, to: target)
        if let now = frame?.pair, let moved = renderedPair.map(now.changes(from:)) {
            if moved.contains(.pixels) || moved.contains(.film) { layers.insert(.shoot) }
            if moved.contains(.print) { layers.insert(.print) }
        }
        return layers
    }

    /// Whether `piece` is the piece as it stands, for a develop: nothing of
    /// its pixels, its dates or its frames' prints has moved since.
    private func isCurrent(_ piece: HalfFramePair?) -> Bool {
        guard let now = frame?.pair else { return true }
        return piece.map { now.changes(from: $0).isEmpty } ?? false
    }

    // MARK: the controls

    /// A finger landed on a control of this layer.
    func began(_ layer: ParamLayer) {
        beginHistoryTransaction()
        dragging = layer
        scheduler.frontend.interaction = .dragging(layer)
    }

    /// A control moved, or was tapped.
    func change(_ mutate: (inout FrameEdit) -> Void) {
        let before = historySnapshot()
        var next = edit
        mutate(&next)
        commit(next, pieceMoved: false)
        recordHistory(from: before)
    }

    private func changeWithoutHistory(_ mutate: (inout FrameEdit) -> Void) {
        var next = edit
        mutate(&next)
        commit(next, pieceMoved: false)
    }

    /// A kept edit may be a user's Crop Done, or only decoder/meter
    /// readback. The latter updates controls without consuming an undo step.
    func acceptKeptEdit(_ wanted: FrameEdit) {
        var comparable = edit
        comparable.solvedEV = wanted.solvedEV
        if comparable.decode.whiteBalance == .asShot, wanted.decode.whiteBalance == .asShot {
            comparable.decode.temperature = wanted.decode.temperature
            comparable.decode.tint = wanted.decode.tint
        }
        if comparable == wanted { commit(wanted, pieceMoved: false) }
        else { change { $0 = wanted } }
    }

    var canUndo: Bool { historyBefore == nil && history.canUndo }
    var canRedo: Bool { historyBefore == nil && history.canRedo }

    func historySnapshot() -> DevelopRevision {
        var decodes: [UUID: DecodeSettings] = [:]
        if let pair, let darkroom {
            for source in darkroom.held(by: pair).values { decodes[source.id] = source.edit.decode }
        }
        return DevelopRevision(edit: edit, pair: pair, sourceDecodes: decodes)
    }

    /// Returns whether this caller owns the group, so nested transactions
    /// cannot finish a gesture's history entry early.
    @discardableResult func beginHistoryTransaction() -> Bool {
        guard !replayingHistory, historyBefore == nil else { return false }
        historyBefore = historySnapshot()
        return true
    }
    func endHistoryTransaction() {
        guard let before = historyBefore else { return }
        historyBefore = nil
        recordHistory(from: before)
    }
    func recordHistory(from before: DevelopRevision) {
        guard !replayingHistory, historyBefore == nil else { return }
        let after = historySnapshot()
        history.record(from: before.keepingReports(from: after), to: after)
    }
    @discardableResult func undo() -> Bool {
        guard canUndo, let revision = history.undo() else { return false }
        restore(revision); return true
    }
    @discardableResult func redo() -> Bool {
        guard canRedo, let revision = history.redo() else { return false }
        restore(revision); return true
    }
    private func restore(_ saved: DevelopRevision) {
        var revision = saved.keepingReports(from: historySnapshot())
        if let pair = revision.pair, let side = pair.pickedSide(layer) {
            HalfFramePair.show(placementOf: side, in: &revision.edit.params)
        }
        replayingHistory = true
        defer { replayingHistory = false }
        if let onRestoreRevision { onRestoreRevision(revision) }
        else { commit(revision.edit, pieceMoved: false) }
    }

    /// The one place an edit lands. `pieceMoved`: a half-frame pair's piece
    /// was changed with it (`pieceChanged`), so there is something to ask for
    /// even where the look is as it was.
    private func commit(_ wanted: FrameEdit, pieceMoved: Bool) {
        // Whatever wrote it — a card, a paste, another page, ↺ — a slide film
        // is scanned, not printed (`Stock.swift`, "the film decides"), and the
        // film's long edge is this photograph's (`FilmParams.heldToItsPhoto`).
        var next = wanted.held(to: frame?.originalSize ?? PixelSize(width: 0, height: 0))
        if let pair = frame?.pair {
            next = next.asPairLook
            pair.hold(&next.params)
        }
        guard next != edit || pieceMoved else { return }
        // The picture under the placement moves on: a measurement that is out
        // is of another (`measure`).
        if pieceMoved || !ChangeDescriber.layers(from: edit.withoutPlacement, to: next.withoutPlacement).isEmpty { turns &+= 1 }
        let placementMoves = next.params.sceneLatitude != edit.params.sceneLatitude
        #if SPK_ENGINE
        // The full render is of everything but Edit's layer and Edit's crop, which are made after it.
        var same = edit
        same.adjustments = next.adjustments
        same.printCrop = next.printCrop
        if same != next || pieceMoved { fullView.editChanged() }
        #endif
        edit = next
        touched()
        library.update(frameID) { $0.edit = next }
        // Layer 2 follows the edit at once: it is the GPU's pass, not a render.
        layer2.show(adjustments: next.adjustments)
        layer2.show(picture: Layer2Live.picture(for: frame, developed: developed, edit: next))
        // The Latitude card follows the placement, not the develop: a solve is
        // not a render.
        if placementMoves { draw() }
        // A placement the engine has not solved (pasted onto this frame) and no
        // develop to wait for: its Fit is asked for now.
        if next.placementNeedsFit { fitPasted() }
        let layers = owed(to: next)
        guard !layers.isEmpty else { return }
        if dragging == nil {
            request()                                   // a tap: a card, a chip, a switch
        } else if !layers.contains(.shoot) {
            request()                                   // print-side: follows the finger
        } else {
            pause?.cancel()                             // film-side: when the finger rests
            pause = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.filmSidePause * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.request()
            }
        }
    }

    // MARK: a half-frame pair

    // A pair's page is about one layer at a time — the film, or one of its
    // frames — as the desktop's is (`Session.pairLayer`): a touch on a frame
    // of the piece picks it, and every tab is then about that frame. What is
    // a frame's own: its exposure on the film and its meter, its picture
    // under the hole, whether the back printed on it, its print, and its
    // Scene Placement, which is fitted on that frame alone (`region`) and
    // sent as that frame's curve (`FilmParams.pairPlacementWire`).

    /// The pair this page is of, as the library has it; nil for a photograph.
    var pair: HalfFramePair? { frame?.pair }

    /// Where each frame of the pair is on the picture the page shows,
    /// normalised with a top-left origin: the piece's two holes — or, on its
    /// strip, the engine's own gates of the develop that last landed
    /// (`located`), and nil until one has. What a touch on the picture is held
    /// against, and never a second copy of the film's arithmetic: on a strip
    /// only the engine knows where it put the gates.
    var frameRects: [HalfFramePair.Side: CGRect]? {
        guard let pair else { return nil }
        return pair.wearsFilmEdge ? gates : pair.holeRects
    }

    /// The engine has said where the gates of the strip it has just developed
    /// for this page are (`spk_overscan_geometry`): the first frame's first.
    func located(_ rects: [CGRect]) {
        guard pair != nil, rects.count == 2 else { return }
        gates = [.left: rects[0], .right: rects[1]]
    }

    /// The frame Scene Placement and the Latitude card are about: the picked
    /// one, or with the film picked the one picked last (the desktop's
    /// `Session.focusSide`). Nil for a photograph, and for a piece with no frame.
    var placementSide: HalfFramePair.Side? { pair?.placementSide(edit.params) }

    /// That frame as the engine's `region` of the piece; nil reads the whole frame.
    private var region: [Double]? {
        guard let pair, let side = pair.placementSide(edit.params) else { return nil }
        return pair.fitRegion(side)
    }

    /// Pick a layer. A frame that is there becomes the one Scene Placement is
    /// about: the two placements trade places, which moves nothing on the wire
    /// and asks for no develop (`HalfFramePair.show`); the card is measured
    /// again, on that frame.
    func pick(_ picked: HalfFramePair.Layer) {
        guard let pair, picked != layer else { return }
        layer = picked
        visit?.picked.insert(picked == .film ? "film" : picked == .left ? "left" : "right")
        guard let side = pair.pickedSide(picked), side != placementSide else { return }
        changeWithoutHistory { HalfFramePair.show(placementOf: side, in: &$0.params) }
        refocus()
    }

    /// The reading on the page is of another frame, or of a piece that has
    /// moved on: the rulers wait, and the card is measured again.
    private func refocus() {
        turns &+= 1
        measured = nil
        placementMoved = nil
        pastedNote = nil
        measureSoon(after: 0)
    }

    /// The frame's pixels are others, with no edit of its settings to say so:
    /// one of a pair's own frames was edited by itself — its white balance,
    /// its crop — or the pair's strip went on or off. The picture is asked
    /// for again, as a develop that opens its frame.
    func sourceChanged() {
        guard opened, let frame, darkroom?.makesPictures == true else { return }
        turns &+= 1
        measured = nil
        submit(frame, target: edit, layers: [.shoot], opening: true)
    }

    /// What the film's size is made of changed with no edit to say so: Settings' *Crop re-maps the
    /// frame* (`AppServices.cropRemapsFrameChanged`). The picture is asked for again as a develop of the
    /// film, where the crop makes the wire's `film_format_mm` another number; a frame with no crop,
    /// under a film edge or a pair sends the same wire, and develops nothing.
    func filmSizeRuleChanged() {
        guard opened, let frame, !frame.isPair, edit.appliesFilm, darkroom?.makesPictures == true else { return }
        guard edit.wireFilmFormatMM(photo: frame.originalSize, cropIsFrame: true) != edit.params.filmFormatMM else { return }
        submit(frame, target: edit, layers: [.shoot], opening: false)
    }

    /// A half-frame pair's piece was changed (`AppServices.changePair`: the
    /// library has it already), with its look as that change left it — a
    /// frame's exposure applied to the film as well moves the film's print.
    /// What is asked for is what moved: the piece composed again for other
    /// pixels, the film developed again for a frame's date, a reprint for a
    /// frame's own print — under a finger, on the same rule as any control
    /// (`commit`).
    func pieceChanged(look: FrameEdit) {
        // The picked layer stays on something that is there to pick.
        if let pair, let side = layer.side, pair[side] == nil, pair[side.other] == nil { layer = .film }
        let moved = renderedPair.flatMap { was in pair.map { $0.changes(from: was) } } ?? [.pixels]
        // Another picture under the placement, or another exposure of it: the reading is of the
        // last — and a strip laid out again has its gates where the next develop says.
        if moved.contains(.pixels) {
            measured = nil
            gates = nil
        }
        commit(look, pieceMoved: true)
    }

    /// The finger lifted: whatever is outstanding is asked for now.
    func ended() {
        dragging = nil
        scheduler.frontend.interaction = .idle
        pause?.cancel(); pause = nil
        request()
        endHistoryTransaction()
    }

    /// Back to what a new frame starts with — the stocks kept, the picture's
    /// own decode and seed kept.
    func reset() {
        change { $0.resetDevelop() }
    }

    // MARK: Edit — Layer 2

    /// Show `next`: the top bar's Develop | Edit. The visit's clock follows it.
    func show(_ next: DevelopSurface) {
        guard next != surface else { return }
        pageNavigation.show(next)
        visit?.clock.show(next, at: Date())
    }

    /// Edit's Light, Curve and Colour as they stand.
    var adjustments: Adjustments { edit.adjustments }

    /// The tools of Layer 2 that apply something, in the tool row's order: what
    /// the status line names. None while the layer is switched off.
    var editedTools: [Adjustments.Tool] { edit.adjustments.isActive ? edit.adjustments.changedTools : [] }

    /// Whether the frame carries an edit after the print.
    var isEdited: Bool { !editedTools.isEmpty }

    /// A finger landed on a Light, Curve or Colour control. Nothing is asked
    /// of the scheduler: what moves is the GPU's pass on the picture the page
    /// has. The library's edited copy waits until the finger lifts.
    func beganEdit() {
        guard !editing else { return }
        beginHistoryTransaction()
        editing = true
        Layer2Copies.shared.hold(frameID)
    }

    /// A Light, Curve or Colour control moved, or was tapped (a double-tap back
    /// to zero). Saved at once, drawn at once; never a develop.
    func changeEdit(_ mutate: (inout Adjustments) -> Void) {
        change { mutate(&$0.adjustments) }
    }

    /// The finger lifted: the library's edited copy is made, a moment later.
    func endedEdit() {
        guard editing else { return }
        editing = false
        Layer2Copies.shared.release(frameID)
        endHistoryTransaction()
    }

    /// One tool back to zero (a double-tap on its name in the band); the others as they are.
    func resetEdit(_ tool: Adjustments.Tool) {
        changeEdit { $0.reset(tool) }
    }

    /// All of Edit's three tools back to zero: the frame as the darkroom made it.
    func resetEdit() {
        changeEdit { a in for tool in Adjustments.Tool.allCases { a.reset(tool) } }
    }

    /// The selected pair frame's transferable values, with piece-owned fields
    /// kept on the piece. The source file/crop/placement never travel.
    var transferableSettings: FrameEdit {
        var value = edit
        guard let pair else { return value }
        value.params = pair.trim(on: layer, look: edit.params).applied(to: value.params)
        if let side = pair.pickedSide(layer), let hole = pair[side] {
            value.params.exposureCompensationEV = hole.exposureEV
            value.params.autoExposure = hole.autoExposure
            value.params.autoExposureMethod = hole.meterMethod ?? edit.params.autoExposureMethod
        }
        if let side = pair.pickedSide(layer) ?? placementSide, let hole = pair[side], let source = library.frame(hole.frame) {
            value.decode = source.edit.decode
        }
        return value
    }

    /// Copy Settings (C7): this frame's settings, with the groups ticked.
    func copy(groups: Set<ClipboardGroup>) {
        library.clipboard = clip(groups: groups, sourceName: frame?.fileName ?? "")
    }

    /// This frame's settings as a clip: the copy's and a preset's, with the picture's shape as turned,
    /// which its film edge's turn is a choice against (`SettingsClip.sourceAspect`).
    func clip(groups: Set<ClipboardGroup>, sourceName: String) -> SettingsClip {
        SettingsClip(groups: groups, settings: transferableSettings, sourceName: sourceName,
                     sourceAspect: frame.map { SettingsClip.shownAspect($0.originalSize, quarterTurns: edit.geometry.quarterTurns) })
    }

    /// Leaving the page: nothing of this frame's canvas work is left queued,
    /// the engine's session on the frame is given back, and what the page
    /// leaves behind is the frame's kept develop — its last picture when that
    /// is of the edit as it stands, a develop in the queue when it is not.
    private func close() {
        pause?.cancel()
        dragging = nil
        scheduler.frontend.interaction = .idle
        scheduler.cancelAll(frameID: frameID) { $0.kind.isCanvas }
        bringing?.cancel(); bringing = nil
        notBrought = nil
        asked = nil
        askedSource = nil
        renderedSource = nil
        measuring?.cancel(); measuring = nil
        fitting?.cancel(); fitting = nil
        measured = nil
        placementMoved = nil
        pastedNote = nil
        layer2.close()
        #if SPK_ENGINE
        fullView.close()
        #endif
        if editing { editing = false; Layer2Copies.shared.release(frameID) }
        guard let darkroom, darkroom.makesPictures else { return }
        latitude = .waiting
        darkroom.closeEditing(frameID)
        if let frame, let want = darkroom.stamp(frame, edit: frame.edit, longEdge: frame.previewSize.longEdge),
           frame.developed?.stamp != want {
            if let developed, developed.stamp == want, let developedImage {
                darkroom.keep(developedImage, frameID: frameID, stamp: want)
            } else {
                onStale?()
            }
        }
        RenderedPictures.shared.remove(developed?.picture)
        developed = nil
        developedImage = nil
        opened = false
    }

    // MARK: asking for the render

    private func request() {
        guard let frame else { return }
        let target = edit
        let layers = owed(to: target)
        guard !layers.isEmpty else { return }
        // Already on its way.
        if let asked, ChangeDescriber.layers(from: asked.target, to: target).isEmpty, isCurrent(asked.piece) { return }
        submit(frame, target: target, layers: layers, opening: false)
    }

    /// A develop of the page's is asked for. Where it would read an original
    /// that stays in Photos and is not here — the frame's own, or one of a
    /// pair's frames' — that is brought first, and the page's picture asked
    /// for when it has come.
    private func submit(_ frame: LibraryFrame, target: FrameEdit, layers: Set<ParamLayer>, opening: Bool) {
        // A RAW's proxy stands for an original that is away: only an export needs the file itself.
        if let darkroom, darkroom.needsBringing(frame, edit: target) { return bring(frame) }
        ask(frame, target: target, layers: layers, opening: opening)
    }

    /// The original is fetched into the working copies (`Originals`), once
    /// however many edits are made meanwhile; then one develop that opens the
    /// frame, of the edit as it stands by then. One that cannot be brought
    /// leaves the page with the picture it has, and the line says why.
    private func bring(_ frame: LibraryFrame, again: Int = 0) {
        guard bringing == nil, let darkroom else { return }
        notBrought = nil
        bringing = Task { [weak self] in
            let brought = await darkroom.bring(frame, asked: true)
            guard let self, !Task.isCancelled else { return }
            self.bringing = nil
            guard self.opened, let frame = self.frame else { return }
            if brought != .here {
                self.notBrought = brought.words
                self.latitude = .unavailable(L("Not measured"))
            } else if darkroom.isAway(frame), again < 2 {
                // What the frame reads changed meanwhile — a pair given another frame: that is brought too.
                self.bring(frame, again: again + 1)
            } else {
                self.ask(frame, target: self.edit, layers: [], opening: true)
            }
        }
    }

    private func ask(_ frame: LibraryFrame, target: FrameEdit, layers: Set<ParamLayer>, opening: Bool) {
        // With a film edge the canvas is the film, not the picture, and is
        // priced as that (`FrameEdit.canvas`; a pair's piece, `LibraryFrame.canvas`).
        let canvas = frame.canvas(target)
        // The page's first develop opens the frame: its decode is part of the
        // job, priced by the original's size (`RenderJob.original`). So does
        // a develop from other pixels than the one before it.
        let source = darkroom?.sourceKey(frame, edit: target, longEdge: frame.previewSize.longEdge)
        let opens = opening || (source != nil && (source != askedSource || source != renderedSource))
        let job = RenderJob(frameID: frameID,
                            kind: opens || layers.contains(.shoot) ? .canvasDevelop : .canvasReprint,
                            tier: .live, canvas: canvas, layers: layers,
                            what: opening ? StockCatalog.shared.pairText(target.params)
                                          : ChangeDescriber.what(from: rendered, to: target),
                            decodesOriginal: opens, original: opens ? (darkroom?.openSize(frame, edit: target) ?? frame.originalSize) : nil,
                            // A half-frame pair's frames that print as their own: each a reprint
                            // of the same negative, cut in along its hole (`PrintLayers.swift`).
                            printLayers: darkroom?.printLayers(frame, edit: target) ?? 0)
        // The frame's file, its decode and its whole wire, as they are now: the
        // engine asks for them on its own queue. A frame with nothing to develop
        // from (a demo picture, an original that is away) is not submitted.
        if let darkroom, !darkroom.prepare(job, frame: frame, edit: target, purpose: .canvas,
                                           longEdge: frame.previewSize.longEdge) { return }
        let id = scheduler.submit(job)
        let piece = frame.pair
        asked = (id, target, piece)
        askedSource = source
        if !opening {
            settings.lastFilm = target.params.filmStock
            settings.lastPaper = target.params.printStock
        }
        Task { [weak self] in
            guard let self else { return }
            var finished = false
            if case .finished = await self.scheduler.outcome(of: id) {
                finished = true
                self.rendered = target
                self.renderedPair = piece
                self.renderedSource = source
                // The page's first picture is measured at once; an edit's when it settles.
                self.measureSoon(after: opening ? 0 : Self.latitudePause)
                // A placement the engine has not solved — pasted from another frame, or
                // kept by a build with no engine — is solved now that the engine has
                // the frame as it stands (RFC-027 §4.1).
                self.fitPasted()
            }
            self.darkroom?.forget(id)
            if self.asked?.id == id { self.asked = nil }
            // What has landed may not be the edit as it stands, with no later job
            // asked for it: a ruler taken out and brought back within one develop
            // asks for nothing at the time, the edit being the last picture's
            // again. The page then showed the develop that was out, under
            // controls that said otherwise, until the next edit (the Scene
            // Placement work found it in the simulator, 2026-10-07: Film Exposure
            // out to +0.5 and back, the dial at 0.0 and the picture at +0.5). So
            // whatever is still owed is asked for now.
            if finished { self.request() }
        }
    }

    // MARK: the latitude reading

    private func measureSoon(after seconds: Double) {
        guard measuresLatitude, opened else { return }
        measuring?.cancel()
        measuring = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.measure()
        }
    }

    /// The edit the engine's session on this frame is of, with its placement
    /// taken out — where that is certain: the last render that landed is of
    /// the picture as the page has it, and none of another picture is on its
    /// way. Nil while the page is catching up with anything but a placement.
    private var settled: FrameEdit? {
        let base = rendered.withoutPlacement
        guard ChangeDescriber.layers(from: base, to: edit.withoutPlacement).isEmpty, isCurrent(renderedPair) else { return nil }
        if let asked, !ChangeDescriber.layers(from: base, to: asked.target.withoutPlacement).isEmpty { return nil }
        return base
    }

    /// Ask the engine's session on this frame for its reading: what this film
    /// and paper hold, where the scene sits, and the engine's own Fit of the
    /// frame's placement as it stands. The reading is what the rulers' steps
    /// are solved on until the next one (`ground`).
    private func measure() async {
        // GPU work is refused in the background; the next develop asks again.
        guard let darkroom, opened, scheduler.frontend.scene == .active else { return }
        // A placement the engine has not solved is not the frame's yet: as metered.
        let settings = edit.placementNeedsFit ? edit.params.sceneLatitude.withoutPlacement : edit.params.sceneLatitude
        // What the reply will be of, where that is certain, and whether the
        // picture moves on while it is out.
        let of = settled, turn = turns, piece = frame?.pair
        // A half-frame pair: the frame the placement is of, measured by itself.
        var request = settings.request
        request.region = region
        guard let answer = await darkroom.sceneLatitude(frameID, request: request),
              opened, !Task.isCancelled else { return }
        switch answer {
        case .success(let reply):
            if let of, turn == turns, settled != nil {
                measured = (reply, of, piece)
                draw()
            } else {
                // Of a picture the page has moved on from: a reading for the card
                // until the next, and nothing a ruler is solved on.
                latitude = .measured(LatitudeReadout(reply))
            }
            // The engine stays the judge: its Fit of these pull-backs against the
            // solve made here, on the measurement it has just made.
            if let apart = reply.disagreement(with: settings) {
                log.error("scene placement: the app's solve is not the engine's on this frame: \(apart, privacy: .public)")
            }
        case .failure(.failed(let message)), .failure(.resource(let message)): latitude = .refusal(message)
        case .failure(.cancelled): break
        }
    }

    /// The card, from the engine's last measurement and the frame's placement
    /// as it stands: the engine's own Fit where its reply is of exactly these
    /// pull-backs, and the same solve made here where a ruler has moved since.
    /// So the card follows the finger, and the engine's own drawing replaces
    /// it when the picture has developed and been measured again.
    private func draw() {
        guard let ground else { return }
        let settings = edit.placementNeedsFit ? edit.params.sceneLatitude.withoutPlacement : edit.params.sceneLatitude
        let same = ground.fit.highlight.pullBack == settings.highlightPullBack
            && ground.fit.shadow.pullBack == settings.shadowPullBack
        let reading = LatitudeReading.measured(LatitudeReadout(same ? ground : ground.placed(settings)))
        if latitude != reading { latitude = reading }
    }

    // MARK: Scene Placement

    /// The measurement a ruler's step is solved on: the engine's last, for as
    /// long as it is of the picture on the page — nothing but the placement has
    /// changed since. Nil until the page's first develop has been measured, and
    /// from any other edit until its develop has been: the rulers wait.
    private var ground: SceneLatitudeReply? {
        guard let measured, ChangeDescriber.layers(from: measured.of, to: edit.withoutPlacement).isEmpty else { return nil }
        // A half-frame pair: and the piece is the one that was measured — the same pictures, exposed the same.
        if let now = frame?.pair {
            guard let was = measured.piece, !now.changes(from: was).contains(.pixels) else { return nil }
        }
        return measured.reply
    }

    /// Scene Placement as the Scene tab shows it: what each ruler offers on
    /// this frame, and the line under the two.
    var placement: PlacementPanel {
        let settings = edit.params.sceneLatitude
        // The drawings' own library, and a build whose engine is not running:
        // nothing measures the frame, and the rulers are numbers.
        guard measuresLatitude else { return .numbers(settings) }
        // A pasted placement waits for the engine's Fit, and a page for its
        // first measurement: the rulers wait with them.
        guard !edit.placementNeedsFit, let measured else { return .waiting(settings, note: pastedNote) }
        var panel = ScenePlacement.panel(settings, on: measured.reply, moved: placementMoved)
        if let pastedNote { panel.note = pastedNote }
        if ground == nil {
            // Another edit's develop has not been measured yet. The rulers wait
            // on the scales they had, rather than slide to plain ones and back.
            panel.highlight.enabled = false
            panel.shadow.enabled = false
            panel.note = pastedNote
        }
        return panel
    }

    /// A ruler's `onEditingChanged`: a finger landing on Scene Placement's
    /// `side`, and lifting. The line under the rulers speaks of that ruler's
    /// end from here on.
    func placing(_ side: PlacementSide) -> (Bool) -> Void {
        { [weak self] down in
            guard let self else { return }
            if down {
                if self.placementMoved != side { self.placementMoved = side }
                if self.pastedNote != nil { self.pastedNote = nil }
                self.began(.shoot)
            } else {
                self.ended()
            }
        }
    }

    /// A step of one of the two rulers: `side` asked for `asked` stops. Solved
    /// here and now, on the engine's last measurement of the frame, and
    /// committed with its curve in the same call — the pull-back the Fit takes
    /// nearest to what was asked (`ScenePlacement.place`). Nothing is asked of
    /// the engine, so nothing waits behind a develop; the change itself is an
    /// edit like any other, and develops when the finger rests.
    func placeScene(_ asked: Double, moving side: PlacementSide) {
        guard measuresLatitude else {
            change { $0.params.sceneLatitude[side] = max(0, asked) }
            return
        }
        // Not measured as it stands: the rulers wait, and the page does not offer them.
        guard !edit.placementNeedsFit, let ground else { return }
        let settings = edit.params.sceneLatitude
        // A ruler under a finger publishes its stop again and again: only a
        // change of pull-back is a step.
        guard max(0, asked) != settings[side] else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        // Nil: the Fit takes nothing on this side as things stand. The panel says why.
        guard let placed = ScenePlacement.place(asked, moving: side, in: settings, on: ground), placed != settings else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        change { $0.params.sceneLatitude = placed }
        log.info("scene placement: \(side.name, privacy: .public) asked \(asked, format: .fixed(precision: 2)), placed \(placed[side], format: .fixed(precision: 2)) beside \(placed[side.other], format: .fixed(precision: 2)); highlight knee \(placed.highlightKnee, format: .fixed(precision: 3)) room \(placed.highlightRoom, format: .fixed(precision: 3)), shadow knee \(placed.shadowKnee, format: .fixed(precision: 3)) room \(placed.shadowRoom, format: .fixed(precision: 3)); solved here in \(ms, format: .fixed(precision: 3)) ms")
    }

    /// A placement the engine has not solved — pasted from another frame, or
    /// kept as numbers by a build with no engine — is the engine's own to
    /// solve, on this frame as it last developed it (RFC-027 §4.1). Taken: it
    /// is committed, a change like any other. Refused: it is turned off, and
    /// the panel says why. The rulers wait meanwhile.
    private func fitPasted() {
        guard edit.placementNeedsFit, opened, fitting == nil, let darkroom, darkroom.makesPictures else { return }
        // The engine solves on the picture it last developed, which has to be
        // this one: a develop still on its way asks again when it lands.
        guard let of = settled else { return }
        let want = edit.params.sceneLatitude, turn = turns, frameID = frameID
        var request = want.request
        request.region = region
        fitting = Task { [weak self] in
            let answer = await darkroom.sceneLatitude(frameID, request: request)
            guard let self, !Task.isCancelled else { return }
            self.fitting = nil
            guard self.opened else { return }
            // The frame moved on while the Fit was out: asked again, now or
            // when its develop lands.
            guard self.edit.placementNeedsFit, self.edit.params.sceneLatitude == want, turn == self.turns,
                  self.settled != nil else { self.fitPasted(); return }
            self.take(answer, of: of)
        }
    }

    /// The engine's answer to a pasted placement: the one place one lands.
    private func take(_ answer: Result<SceneLatitudeReply, EngineError>?, of base: FrameEdit) {
        switch answer {
        case .success(let reply):
            // The reply measures the frame as well: the rulers have their ground at once.
            measured = (reply, base, frame?.pair)
            pastedNote = reply.fit.valid ? nil : reply.fit.note
            changeWithoutHistory { e in
                if !e.params.sceneLatitude.apply(reply.fit) {
                    // This frame cannot take it: off, with the reason on the panel.
                    e.params.sceneLatitude.highlightPullBack = 0
                    e.params.sceneLatitude.shadowPullBack = 0
                }
                e.placementNeedsFit = false
            }
        case .failure(let error):
            // The frame could not be measured at all; the card says why, and the
            // placement waits for a develop the engine can measure.
            pastedNote = PlacementNote(text: L("That placement cannot be solved on this frame."), refused: true)
            if case .failed(let message) = error { latitude = .refusal(message) }
        case nil:
            break       // No session on this frame yet: asked again when a develop lands.
        }
    }
}

private extension FrameEdit {
    /// This edit as a measurement sees it: the placement taken out — Scene
    /// Placement moves neither what the film and paper hold nor where the
    /// scene sits — and, under As Shot, the camera's own white balance left
    /// unsaid: the decode reads it, and the page's edit only learns of it
    /// afterwards (`OpenFrameSession.readAsShot`).
    var withoutPlacement: FrameEdit {
        var e = self
        e.params.sceneLatitude = params.sceneLatitude.withoutPlacement
        e.placementNeedsFit = false
        if e.decode.whiteBalance == .asShot {
            e.decode.temperature = 0
            e.decode.tint = 0
        }
        return e
    }
}
