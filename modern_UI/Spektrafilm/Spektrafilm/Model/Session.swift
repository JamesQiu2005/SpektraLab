//  Session.swift — all application state, on the main actor.
//
//  One `Session` per app. It owns the library, the current frame's sidecar,
//  the renderer, the service client and the scheduler, and it is the only
//  thing views bind to. The flows worth knowing:
//
//    select(frame)  →  decode (Core Image, off main)  →  the display decode on canvas
//
//  Opening stops at the decode. The develop is the slow half of the path —
//  the *linear* decode rendered for the engine and the `open` that borrows
//  it — and it happens when someone asks for the print, not when they ask to
//  look at the frame. The display decode never reaches the engine:
//
//    Solve          →  linear decode → EngineFrame     →  engine open
//                   →  solve(exposure)                 →  the Exp. Comp. baseline
//                   →  solve(both)                     →  the enlarger filter pack
//                   →  reprint(live)                   →  print on canvas
//    params edit    →  the develop if the engine does not hold the frame yet,
//                      else scheduler.request         →  reprint/preview_render
//    adjustments    →  renderer.layer2 (no service)    →  redraw
//    decode edit    →  re-decode (both looks)          →  reopen
//    an edit settles→  reprint(preview resolution)      →  the full render follows
//    open(folder)   →  Browse, nothing rendered        →  select() enters Print

import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class Session: CanvasHost {
    // MARK: library
    private(set) var frames: [Frame] = []
    private(set) var frameStates: [URL: FrameState] = [:]
    var selection: URL?

    /// The picked frames, as a set. `selectedFrames` is the read side.
    ///
    /// `private(set)` on purpose. Only selection operations may move it:
    /// `click` and `selectAllFrames`, which are the person; `open(urls:)`,
    /// where a new folder is a new set; `remove(_:)`, where a frame that goes takes its membership
    /// with it; and `select(_:)`'s callers are deliberately *not* among them —
    /// putting a frame on the canvas is not picking it, which is the whole
    /// reason the export run can walk a batch without eating it. Writable from
    /// a view, this would be a fifth notion of "selected".
    private(set) var picked: Set<URL> = []

    /// Every picked frame, **in display order**.
    ///
    /// One property, so the filmstrip, the Browse grid and the export page
    /// cannot disagree about which photographs "the selected images" are —
    /// `notes.md` says "the export setting is applied to all the selected
    /// images", and RFC-017 §8 Q2 wants apply-to-all to take "the selection
    /// when there is one, the folder otherwise". When that lands this is its
    /// input; today the export page's batch is its only reader.
    ///
    /// Deliberately *not* `selection`. That one is what is on the canvas, and
    /// ⌘-click must be able to grow this set without moving it (`notes.md`:
    /// "the viewed image stays as the one the user is previously on").
    var selectedFrames: [URL] { frames.map(\.id).filter(picked.contains) }

    /// Membership alone. The export page's grids want this and not `framing`:
    /// they draw every chosen frame the same way (`notes.md`) rather than
    /// distinguishing the one on the canvas.
    func isPicked(_ url: URL) -> Bool { picked.contains(url) }

    /// How a cell is framed, from the one place that knows.
    ///
    /// Both surfaces ask this, so "the filmstrip and Browse agree" is a
    /// property of the code rather than a convention two files keep in step
    /// by hand — which is what the two of them have failed to do before.
    func framing(of url: URL) -> FrameFraming {
        if url == selection { return .open }
        return picked.contains(url) ? .picked : .none
    }

    var libraryTitle: String = ""

    // MARK: the current frame
    var sidecar = Sidecar()
    /// The half-frame pair on the canvas, when the open item is one (its file
    /// is `selection`), and the layer its section is showing.
    private(set) var pair: HalfFramePair?
    var pairLayer = PairLayer.film { didSet { if pairLayer != oldValue { pairLayerChanged() } } }
    /// The right hole's frame's EXIF: its date, for the strip's second imprint.
    private(set) var pairRightExif: EXIFReadout?
    @ObservationIgnored private var pairExposureTask: Task<Void, Never>?
    /// `openInService` calls in flight, and what `busy` was before the first.
    @ObservationIgnored private var openDepth = 0
    /// The engine's last print of the pair and the generation it landed with:
    /// what a frame's print or grade is composed over again.
    @ObservationIgnored private var pairLastRender: (outcome: RenderOutcome, generation: Int)?
    @ObservationIgnored private var pairComposeTask: Task<Void, Never>?
    /// Whether the canvas is showing a picture cut together from the frames'
    /// own prints (already graded), rather than the engine's one print.
    @ObservationIgnored private var pairShowsComposite = false
    @ObservationIgnored private var busyBeforeOpen = false
    /// Placement mode on a pair, the drag in flight, and where the engine put
    /// the gates on the strip (normalised to the canvas).
    var pairPlacing = false
    /// The hole whose Add Frame picker is open on the canvas.
    var pairPicker: HalfFramePair.Side?
    private(set) var pairDrag: PairDrag?
    @ObservationIgnored private var draggedFrameBox: URL?
    /// The wheel's, the pinch's and a slider's change to a placement is one
    /// gesture: shown as it goes, written once it stops.
    @ObservationIgnored private var pairPlacementTask: Task<Void, Never>?
    private(set) var pairGates: [CGRect] = []
    var params: FilmParams {
        get { sidecar.params }
        set { guard newValue != sidecar.params else { return }
              pushUndo()
              // The film edge takes the crop into its gate and gives it back
              // (`Session+FilmEdge.swift`); the geometry moves before the
              // params land, so the develop below cuts the new framing.
              filmEdgeWillChange(from: sidecar.params, to: newValue)
              sidecar.params = newValue
              renderer.geometry = canvasGeometry
              requestPrint(); markStale(); scheduleSave() }
    }
    var adjustments: Adjustments {
        get { sidecar.adjustments }
        set { guard newValue != sidecar.adjustments else { return }
              pushUndo()
              // A pair's grade is in the picture it composes, frame by frame;
              // the canvas draws that picture with none of its own.
              if pair != nil {
                  sidecar.adjustments = newValue
                  scheduleSave()
                  recomposePair()
                  renderer.needsDraw?()
                  return
              }
              let curvesChanged = newValue.curves != sidecar.adjustments.curves
              sidecar.adjustments = newValue
              renderer.layer2 = newValue.uniforms
              if curvesChanged { renderer.setCurves(newValue.curves) } else { renderer.needsDraw?() }
              scheduleSave() }
    }
    var decode: DecodeSettings {
        get { focusHole?.decode ?? sidecar.decode }
        set { // On a pair the white balance and lens correction are the
              // picked frame's own, written to that frame.
              if pair != nil { setFocusDecode(newValue); return }
              guard newValue != sidecar.decode else { return }
              pushUndo()
              sidecar.decode = newValue; scheduleSave(); scheduleReopen() }
    }
    /// Crop, straighten, quarter turns and flips. Every mutation goes
    /// through `Geometry`'s own fitted-by-construction methods, so nothing
    /// assigned here can put a corner outside the frame.
    var geometry: Geometry {
        get { sidecar.geometry }
        set { guard newValue != sidecar.geometry else { return }
              pushUndo()
              sidecar.geometry = newValue
              // Before the canvas is told: whether the engine's frame is cut
              // by this geometry is resolved from it (`dateBack.framing`).
              resolveFilmEdge()
              renderer.geometry = canvasGeometry
              // A crop changes the physical scale only if the user has said
              // it should (`physicalAspect`). Off — the default — this is a
              // no-op, and the check is here rather than inside so that the
              // common case does not walk the arithmetic on every drag event.
              // Not under a film edge: the engine sizes the film from the
              // gate then and ignores `film_format_mm` (API-SPEC §13).
              if Session.recalculateEffectsAfterCrop && !sidecar.params.filmEdge.effective {
                  recomputeFilmFormat()
              }
              // With a film edge, or the date alone, the crop is in the
              // negative: a new one is a develop — once, when the crop tool
              // lets go of it.
              if geometryIsInTheNegative && tool != .crop { requestPrint(); markStale() }
              scheduleSave() }
    }
    /// The live tier's pixel size, which is what the geometry is normalised
    /// against. Zero before the first image lands.
    ///
    /// While the canvas shows a film edge the renderer's frame is the film
    /// canvas, which the geometry knows nothing about: the crop is still the
    /// photograph's, so it is measured against the photograph.
    var sourceImageSize: CGSize {
        if filmEdgeShowsFilm, let native = nativeSourceSize { return native }
        return renderer.sourceSize ?? .zero
    }

    /// The frame's **own** pixels, whatever tier is on the canvas, or nil
    /// before a decode has landed.
    ///
    /// `renderer.sourceSize` is the size the viewport is expressed against,
    /// and since D4 that is the native frame: "100 %" has to mean one native
    /// pixel per device pixel while a 1600 px live tier of a 6000 px frame is
    /// on screen, not one *texture* pixel. A nil means "the frame's size is
    /// not known yet", and the callers pass it as "leave the size alone".
    var nativeSourceSize: CGSize? { decoded?.pixelSize ?? displaySourceSize }

    // MARK: masks (蒙版) — Layer 2, local
    //
    // A mask is a region plus its own adjustments (`Model/Mask.swift`), so it
    // runs in the same kernel the right panel does and reaches no service.
    // Everything here is one write path: change the list, repack, redraw.

    var masks: [EditMask] {
        get { sidecar.masks }
        set { guard newValue != sidecar.masks else { return }
              pushUndo()
              sidecar.masks = newValue
              syncMasks()
              scheduleSave() }
    }
    /// The mask being edited. Its region is tinted red on the canvas (unless
    /// the overlay is off) and its handles are draggable.
    var selectedMaskID: UUID? { didSet { guard oldValue != selectedMaskID else { return }; syncMasks() } }
    /// The red coverage tint. Every editor has one and every editor's users
    /// turn it off, so it is a toggle rather than a mode.
    var maskOverlayVisible = true { didSet { guard oldValue != maskOverlayVisible else { return }; syncMasks() } }
    /// The colour-range component waiting for an eyedropper click, if any.
    var maskColorPick: UUID?

    var selectedMask: EditMask? {
        get { masks.first { $0.id == selectedMaskID } }
        set {
            guard let newValue, let i = masks.firstIndex(where: { $0.id == newValue.id }) else { return }
            var list = masks; list[i] = newValue; masks = list
        }
    }

    /// Repack for the kernel. Disabled and empty masks are dropped here
    /// rather than branched on per pixel, so the shader's loop is only over
    /// masks that can actually do something.
    private func syncMasks() {
        // `FeatureFlags.masks` is off while the user redesigns the system.
        // The sidecar still carries whatever masks it had — nothing is
        // deleted — but none of them reaches a pixel, so a frame saved with
        // masks looks the same as one saved without while the feature is
        // withdrawn. That is the difference between hiding a feature and
        // hiding its effect, and only the second one is honest.
        guard FeatureFlags.masks else {
            guard !renderer.masks.isEmpty || renderer.maskOverlay >= 0 else { return }
            renderer.masks = []
            renderer.maskOverlay = -1
            renderer.needsDraw?()
            return
        }
        let live = masks.filter { $0.enabled && !$0.isEmpty }.prefix(EditMask.maxCount)
        renderer.masks = live.map { $0.uniform() }
        renderer.maskOverlay = maskOverlayVisible
            ? Int32(live.firstIndex { $0.id == selectedMaskID }.map(Int32.init) ?? -1)
            : -1
        renderer.needsDraw?()
    }

    /// The draggable grips on the selected mask's geometry, in
    /// source-normalised coordinates. `CanvasNSView` hit-tests these and
    /// `MaskOverlay` draws them, so the two cannot disagree about where a
    /// grip is.
    var maskHandles: [MaskHandle] {
        guard FeatureFlags.masks else { return [] }
        guard let m = selectedMask, m.enabled, sourceImageSize.width > 1 else { return [] }
        let size = sourceImageSize
        return m.components.flatMap { c -> [MaskHandle] in
            switch c.kind {
            case .linearGradient:
                [MaskHandle(component: c.id, role: .a, position: c.a),
                 MaskHandle(component: c.id, role: .b, position: c.b)]
            case .radialGradient:
                [MaskHandle(component: c.id, role: .centre, position: c.a),
                 MaskHandle(component: c.id, role: .radiusX, position: MaskGeometry.point(on: c, at: 0, imageSize: size)),
                 MaskHandle(component: c.id, role: .radiusY, position: MaskGeometry.point(on: c, at: .pi / 2, imageSize: size)),
                 MaskHandle(component: c.id, role: .rotate, position: MaskGeometry.point(on: c, at: 0, scale: 1.3, imageSize: size))]
            default: []
            }
        }
    }

    /// Apply a grip drag. `n` is where the pointer is, source-normalised.
    func maskHandleDragged(_ h: MaskHandle, to n: CGPoint) {
        guard var m = selectedMask, let i = m.components.firstIndex(where: { $0.id == h.component }) else { return }
        var c = m.components[i]
        let size = sourceImageSize
        // Long-edge units, matching `toLongEdge` in the shader — the radii
        // are in them, so the arithmetic has to be too or a drag on a 3:2
        // frame resizes the wrong axis.
        let long = max(size.width, size.height)
        let sx = size.width / long, sy = size.height / long
        switch h.role {
        case .a: c.a = n
        case .b: c.b = n
        case .centre:
            let d = CGSize(width: n.x - c.a.x, height: n.y - c.a.y)
            c.a = n
            // A linear component in the same mask does not move with a
            // radial's centre, but a radial's own geometry is its centre, so
            // there is nothing else to carry.
            _ = d
        case .radiusX, .radiusY, .rotate:
            let dx = (n.x - c.a.x) * sx, dy = (n.y - c.a.y) * sy
            if h.role == .rotate {
                c.angle = atan2(dy, dx) * 180 / .pi
            } else {
                let a = c.angle * .pi / 180
                let ex = dx * cos(a) + dy * sin(a)
                let ey = -dx * sin(a) + dy * cos(a)
                if h.role == .radiusX { c.radii.width = max(abs(ex), 0.01) }
                else { c.radii.height = max(abs(ey), 0.01) }
            }
        }
        m.components[i] = c
        selectedMask = m
    }

    func addMask(_ kind: MaskComponentKind) {
        guard masks.count < EditMask.maxCount else {
            lastError = "Eight masks is the limit."
            return
        }
        var m = EditMask.make(kind)
        // Names repeat in Lightroom too, but a number is worth more than a
        // second "Radial Gradient" in the list.
        let n = masks.filter { $0.name.hasPrefix(kind.label) }.count
        if n > 0 { m.name = "\(kind.label) \(n + 1)" }
        masks.append(m)
        selectedMaskID = m.id
    }

    func deleteMask(_ id: UUID) {
        masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = masks.last?.id }
    }

    func duplicateMask(_ id: UUID) {
        guard masks.count < EditMask.maxCount, var m = masks.first(where: { $0.id == id }) else { return }
        m.id = UUID()
        m.name += " copy"
        m.components = m.components.map { var c = $0; c.id = UUID(); return c }
        masks.append(m)
        selectedMaskID = m.id
    }
    private let decodeResidency: DecodeResidency
    var decoded: DecodedImage? { decodeResidency.image }
    /// The source's native long edge. The escalation decision is about the
    /// *file's* resolution, not the live tier's 1600 px: a 45 MP frame needs a
    /// real render long before a 2 MP one does.
    private(set) var sourceLongEdge: CGFloat = 0
    private(set) var exif: EXIFReadout?

    // MARK: ui state
    //
    // Keys are namespaced. The previous version of this app shipped under the
    // same bundle identifier and left its own `leftCollapsed`,
    // `filmstripCollapsed`, `dock.*` and `panel.*` values behind, so an
    // unprefixed key is not this app's state — it is whatever that build last
    // wrote, and it opened this one with both panels and the filmstrip folded
    // away for no reason the user could see.
    nonisolated static let uiKey = "ui2."
    // **The two rails always open expanded**, and are deliberately not
    // restored from the last session.
    //
    // A fresh install already opened expanded — `bool(forKey:)` is `false` for
    // a key that was never written — so this is not about the default value.
    // It is about *persistence*: folding a rail is a momentary thing you do to
    // see the picture, and writing it to disk means one such moment decides
    // how the app looks every time it is opened afterwards. The comment above
    // describes the previous build shipping exactly that bug from stale keys;
    // restoring our own is the same outcome by a tidier route.
    //
    // They still fold, and the fold still lasts as long as the window does.
    // It just does not outlive it.
    var leftCollapsed = false
    var rightCollapsed = false
    var topCollapsed = UserDefaults.standard.bool(forKey: Session.uiKey + "topCollapsed") { didSet { UserDefaults.standard.set(topCollapsed, forKey: Session.uiKey + "topCollapsed") } }
    var filmstripCollapsed = UserDefaults.standard.bool(forKey: Session.uiKey + "filmstripCollapsed") { didSet { UserDefaults.standard.set(filmstripCollapsed, forKey: Session.uiKey + "filmstripCollapsed") } }
    /// Snapshot mode only: hold both rails at `PanelWidthRange.standard`.
    ///
    /// A rail's width is the user's and persists, so a rail dragged wide in
    /// some earlier session would be what every capture measured — the same
    /// defect the collapse flags had, which cost a round of "the layout
    /// drifted" before anyone noticed a card was simply absent. A capture is
    /// a check against the drawing, and the drawing's width is `standard`.
    var snapshotPanelWidths = false

    var tool: CanvasTool = .select {
        didSet {
            guard oldValue != tool else { return }
            // A pair has no crop: the tool's button and key are its placement
            // mode, where each picture is moved under its own hole.
            if tool == .crop, pair != nil { tool = oldValue; togglePairPlacing(); return }
            // Entering the crop tool shows the whole frame; leaving it fits
            // the crop. The renderer does both from this one flag.
            renderer.editingCrop = tool == .crop
            // Entering the tool pivots on the crop's centre without moving
            // anything, so no viewport change announces it — take the mirror
            // straight from the renderer.
            cropPivot = renderer.cropPivot
            // What Esc goes back to. Taken on the way *in*, so a crop the user
            // spent a minute on is not lost by leaving the tool with the
            // mouse and coming back — only Esc discards, and only back to
            // where this session of the tool started.
            cropEntryGeometry = tool == .crop ? geometry : nil
            // With a film edge, or the date alone, the crop tool frames the
            // picture over the undeveloped decode, and leaving it develops
            // the framing.
            if geometryIsInTheNegative {
                renderer.showOriginal = showingOriginal || filmEdgeFraming
                renderer.geometry = canvasGeometry
                // The viewport follows what is shown: the photograph while
                // framing, the film canvas after.
                if let live = renderer.live {
                    renderer.setLive(live, logical: filmEdgeFraming ? nativeSourceSize
                                     : filmCanvasLogicalSize(for: live, frame: nativeSourceSize))
                }
                if oldValue == .crop { requestPrint(); markStale() }
            }
            renderer.needsDraw?()
        }
    }
    /// The crop as it was when the crop tool was entered. See `cancelCrop`.
    private var cropEntryGeometry: Geometry?

    /// Zoom and pan are the crop tool's business while it is up: the view
    /// there is fitted to the whole (turned) photograph and the user cannot
    /// move it — see `Renderer.fitRotatedPhoto`. Every control that would
    /// move it is disabled and greyed rather than left to no-op, so the
    /// toolbar says why nothing happens.
    var zoomLocked: Bool { tool == .crop }

    /// Return: keep what is on screen and leave the tool.
    func commitCrop() {
        guard tool == .crop else { return }
        cropEntryGeometry = nil
        tool = .select
    }

    /// Esc: put the crop back to where the tool was entered and leave.
    ///
    /// Not an undo step of its own — `geometry`'s setter already pushes one —
    /// so ⌘Z after an Esc reaches the edit before the crop, which is what
    /// "cancel" is supposed to have left behind.
    func cancelCrop() {
        guard tool == .crop else { return }
        if let g = cropEntryGeometry, g != geometry { geometry = g }
        cropEntryGeometry = nil
        tool = .select
    }
    /// An observable mirror of the renderer's viewport, so `CropOverlay` can
    /// draw handles in view coordinates. The renderer is not `@Observable`
    /// and should not become so — it is touched per draw.
    private(set) var viewportSnapshot = ViewportState()
    /// The Latitude section's measurement and Scene Placement's refusals
    /// (`Model/Latitude.swift`).
    let latitude = LatitudeModel()
    /// The crop tool's pivot, mirrored from the renderer for the same reason
    /// and the same audience: the overlay draws in edit space, which is a
    /// rotation about this point. The renderer owns it — it feeds the uniform
    /// and carries the re-pivot rule — and every change it makes to it is
    /// accompanied by a viewport change, so this stays current through
    /// `viewportChanged` (plus the tool's own entry, which moves nothing).
    private(set) var cropPivot = CGPoint(x: 0.5, y: 0.5)
    /// The ⌘-drag straighten line, while one is being drawn.
    private(set) var straightenPreview: StraightenLine?
    /// Which executor the service is rendering with, once `open` has said.
    /// Shown in the status bar: "it feels slow" is not diagnosable without
    /// it, and the app ran a whole session on the CPU core because nothing
    /// asked.
    private(set) var backend: Capabilities.Backend?
    var renderCore: String? { backend?.renderCore }
    var curvePickerActive = false
    var wbPickerActive = false
    var pickerActive: Bool { curvePickerActive || wbPickerActive || maskColorPick != nil }
    var zoomPercent = 100
    var isFit = true
    /// Mirrors `Renderer.showOriginal` so the canvas badge can react: the
    /// renderer is a plain class, not `@Observable`.
    var showingOriginal = false

    /// The status badges in the canvas's top-right corner, top to bottom.
    ///
    /// One list rather than conditions written into the view, because two
    /// things need it: the badge stack draws it, and `CompareOverlay` moves
    /// its "After" label out from under it — at 200 % the picture fills the
    /// canvas, its top-right corner *is* the canvas's, and "After" and "full"
    /// were drawn on top of each other.
    var canvasBadges: [String] {
        var badges: [String] = []
        // Space is a decode-vs-print comparison, and the spec's "show
        // original" was ambiguous about which; the label says which
        // (HANDOFF §6) — and that the decode is Apple's rendering of it.
        if showingOriginal { badges.append("original · decode") }
        if fullPending {
            badges.append("full resolution…")
        } else if renderer.showsFullRender {
            badges.append("full")
        }
        if previewSoft && selection != nil { badges.append("preview") }
        // RFC-016 §11.5: "a refusal is a visible event, not a log line". Both
        // of these ride the badge stack that `EditorWindow` already draws —
        // the existing surface, not a second one — and both clear when the
        // frame they are about changes.
        if let refusal { badges.append(refusal.badge) }
        if memoryWarning != nil { badges.append("low memory headroom") }
        return badges
    }

    /// A frame the app declined to render, and why (§11.5). Set from
    /// `EngineMessage`'s classification rather than by matching text here, so
    /// the badge, the sentence in the status bar and the `error` record cannot
    /// disagree about what happened.
    private(set) var refusal: Refusal?
    struct Refusal: Equatable, Sendable {
        var badge: String
        var message: String
        var kind: EngineMessage.Kind
    }

    /// A projected peak that does not fit (§11.5): a warning the user can
    /// override, not a refusal. Nil when the last forecast fitted.
    private(set) var memoryWarning: String?
    /// True while the frame on screen is over the reserve and the user has not
    /// said to go ahead anyway.
    var canOverrideMemoryWarning: Bool { memoryWarning != nil }

    /// "Proceed anyway" (§11.5). The warning stays a *warning*: nothing was
    /// ever blocked, so the override is a dismissal plus a record — and the
    /// log keeps the fact that the user was told and chose to continue.
    func overrideMemoryWarning() {
        guard let warning = memoryWarning else { return }
        memoryWarning = nil
        diagnostics.allowOverReserve = true
        log.info(.memory, "memory warning overridden by the user", [
            .init("warning", warning), .init("frame", selection?.lastPathComponent ?? "-"),
        ])
    }

    /// Dismiss without granting the standing override.
    func dismissMemoryWarning() {
        guard memoryWarning != nil else { return }
        memoryWarning = nil
    }

    // MARK: before / after
    //
    // Capture One's split: the decoded frame on the left of a draggable line,
    // the print on its right, both through the same crop. The shader does the
    // pixels (`canvasFragment`); `Canvas/CompareOverlay.swift` does the line,
    // the handle and the two labels, because a one-point line drawn into the
    // image would be resampled with it.
    //
    // These mirror the renderer, which is not `@Observable` — the same
    // arrangement `viewportSnapshot` uses and for the same reason.

    var comparing = false {
        didSet {
            guard oldValue != comparing else { return }
            if comparing { leaveCropTool(); requestNativeOriginal(trigger: "comparing") }
            renderer.compareSplit = comparing
        }
    }
    /// 0…1 across the output. Stored here so the overlay can bind to it.
    var comparePosition: Double = 0.5 {
        didSet {
            let clamped = comparePosition.clamped(to: 0...1)
            if clamped != comparePosition { comparePosition = clamped; return }
            renderer.comparePosition = Float(comparePosition)
        }
    }
    /// There has to be something to compare against: the decode preview, which
    /// arrives with the frame.
    /// Not while the canvas shows a film edge: the original is the bare
    /// photograph and the print is the film around a cut of it, so a split
    /// would set two different framings side by side (the gate's place in
    /// the canvas needs `spk_overscan_geometry`).
    var canCompare: Bool { selection != nil && renderer.canCompare && !filmEdgeShowsFilm }
    var histogram: [Float] = Array(repeating: 0, count: 1024)
    var hoverValue: SIMD3<Float>?      // encoded RGB under the cursor, for the curve readout
    var status = "Open a folder or an image to begin."
    var busy = false
    var previewSoft = false            // the canvas shows a stale/interpolated print
    /// Whether the canvas holds the frame at its **own** resolution with
    /// nothing pending — no interpolated print, no render on its way, and no
    /// deferred native original. What the snapshot harness waits on before it
    /// captures.
    var canvasIsSettled: Bool {
        !fullPending && !nativeOriginalInFlight && (!wantsFullRender || renderer.showsFullRender)
    }
    var serviceReady = false
    var lastError: String?
    var exportProgress: Double?
    /// A batch export is walking the picked set (`ExportPage.run`).
    ///
    /// The exporter writes **whatever frame is open**, and the run opens each
    /// frame in turn with `select`. While this is set, every *person's* way of
    /// changing the open frame or the set — `click`, `open(_:)`, `togglePick`,
    /// `open(urls:)`, the arrow keys through `click` — is a no-op, so a click
    /// mid-batch cannot put a different frame under the file being written.
    /// `select` itself is not gated: it is the run's own door.
    var batchExporting = false

    /// Every library frame's geometry as last saved, for the thumbnails that
    /// mask each frame's crop (`CropMaskedThumbnail`). Read from the sidecars
    /// `open(urls:)` already loads, and kept by `flushSave` and
    /// `refreshState`. The open frame is not read from here — see
    /// `thumbnailGeometry(for:)`.
    private(set) var savedGeometry: [URL: Geometry] = [:]
    /// The frames whose prints are film canvases: their thumbnails are drawn
    /// whole, since the crop is already inside them. Read with `savedGeometry`.
    private(set) var filmEdgeThumbnails: Set<URL> = []

    /// The geometry a frame's thumbnail is drawn with: the live one for the
    /// frame on the canvas, so a crop drag shows in the strip as it happens,
    /// and the saved one for every other.
    func thumbnailGeometry(for url: URL) -> Geometry {
        url == selection ? canvasGeometry
            : (filmEdgeThumbnails.contains(url) ? .default : (savedGeometry[url] ?? .default))
    }
    var lastRenderMs: Double = 0
    private var statusBase: String?
    var stockWarning: String?
    var showExport = false

    // MARK: - colour

    /// The space the engine develops into **and the space the canvas draws in**,
    /// as the *engine* named it (RFC-018 §5.1).
    ///
    /// One name where there used to be two. It is read from every open reply
    /// rather than assumed — `spk_open`'s convention is ProPhoto RGB, but an
    /// explicit `io.output_color_space` in the delta wins — and it is now the
    /// only colour fact on this line, because the canvas is *tagged* with this
    /// space and ColorSync converts for the display. There is no display space
    /// for the app to name.
    private(set) var workingSpaceName = Session.defaultWorkingSpace
    /// What a session renders into when the engine has not said otherwise.
    /// The engine's own default, spelled once here so the two can be compared
    /// rather than silently agreed with.
    static let defaultWorkingSpace = "ProPhoto RGB"

    // MARK: - the fast stock flip

    /// Print stocks with a shipped preview LUT, and what each was baked
    /// against. Read from the engine once the wire is agreed; empty when
    /// none are bundled, which is what hides the feature rather than letting
    /// it fail when pressed.
    private(set) var printLUTStocks: [String: PrintLUTEntry] = [:]

    /// Show the baked print LUT the instant a paper is picked, and let the
    /// real reprint replace it.
    ///
    /// **Off by default, and not out of caution.** The table bakes the whole
    /// print+scan chain at the *bake's* settings, so the user's print
    /// exposure, filter pack and preflash do not reach it, and neither does
    /// glare. On an ungraded frame that is a free look at the paper; on a
    /// graded one it is a flash of somebody else's grade before the real
    /// render lands. Which of those a given user wants is theirs to say, so
    /// it is a switch with the caveat written next to it.
    var fastStockPreview: Bool = UserDefaults.standard.bool(forKey: "fastStockPreview") {
        didSet { UserDefaults.standard.set(fastStockPreview, forKey: "fastStockPreview") }
    }

    /// Bumped by every render that reaches the canvas. A stock preview that
    /// resolves *after* the real print has landed must not overwrite it, and
    /// comparing this before and after the await is how that is known —
    /// `serviceGeneration` does not move for a print-layer edit.
    private(set) var rendersLanded = 0
    /// The frame whose film canvas (the engine's own cut: a film edge, a date
    /// under a crop) is on the canvas. While that frame is decoded again its
    /// film stays up until the new print lands (`holdsFilmCanvas`).
    @ObservationIgnored private var filmCanvasOn: URL?
    /// The decode is not put over a film canvas that a develop is about to
    /// replace: it is the same frame without its film and of another shape,
    /// so for the length of a re-render the bare photograph stood where the
    /// film was — correct at every instant and plainly wrong to look at.
    private var holdsFilmCanvas: Bool {
        filmEdgeShowsFilm && wantsDevelop && renderer.live != nil && filmCanvasOn != nil && filmCanvasOn == selection
    }

    // The Browse grid is gone (2026-09-17). Opening a folder no longer
    // switches the window to a separate worklist page: the frames land in the
    // filmstrip and the editor stays on screen with nothing selected.
    //
    // What the grid was *for* is kept, and it is the part that matters — a
    // folder still renders **nothing** until a frame is chosen, so opening
    // one does not spend seven seconds and 363 MB developing whichever frame
    // sorts first (HANDOFF-FRONTEND-POLISH §2). That guarantee never needed a
    // page of its own; it needed `selection` to stay nil, which is what
    // `unloadSelection()` below does.

    // MARK: - the preview resolution, and the original image
    //
    // Two states, not a ladder (the product decision of 2026-09-12):
    //
    //   1. **the preview resolution.** One of four settable long edges
    //      (3840, 2560, 1920 or 1080; 2560 by default) and what every
    //      interactive edit renders at. It is the engine's `live` tier: the
    //      *name* is the wire's (contract §1.2.3, the three tier names are
    //      load-bearing), while the chosen size is the user's
    //      (`io.preview_long_edge`).
    //   2. **the original image.** A render at the frame's own resolution,
    //      started once the edit stops moving, and what the canvas shows when
    //      it lands.
    //
    // Zoom selects neither. It used to: `wantedTier` escalated live → preview
    // → full as the zoom passed each tier's native scale and the sharper
    // render replaced the one on screen when it landed. That ladder is gone —
    // one working resolution plus the finished picture is Capture One's model
    // (预览图像), and it is what the user asked for. The zoom readout still
    // means native pixels and the viewport is still expressed against the
    // frame (D4); the canvas is simply soft above the preview resolution until
    // the original lands, which is what `previewSoft` reports.
    //
    // What the sizes cost, measured on the 45 MP Nikon Z7 II frame
    // (8256×5504, grain and glare off) on the GPU core — a live reprint:
    //
    //   | long edge     | reprint |
    //   |---------------|---------|
    //   | 1600 (before) |  6.2 ms |
    //   | 2560 (default)| 13.7 ms |
    //   | 8192 (native) | 121.7 ms|
    //
    // So the interactive render is 7 ms a frame more expensive than it was and
    // still far inside a drag; the native render is 0.12 s and runs once per
    // settled edit rather than on every zoom step. The memory argument that
    // shaped the old two-step escalation is unchanged, and is now the reason
    // there is exactly *one* native render alive at a time: 360 MB at 45 MP,
    // 1.2 GB at 151 MP.

    /// Long edges offered by the preview picker. These are deliberately
    /// discrete: a preview size is a small set of predictable memory/render
    /// costs, not a value that benefits from pixel-by-pixel tuning.
    nonisolated static let previewEdgeChoices = [3840, 2560, 1920, 1080]
    /// Kept as a coarse compatibility range for callers that only need the
    /// bounds. Settings and persistence use `previewEdgeChoices` as the
    /// actual constraint.
    nonisolated static let previewEdgeRange = 1080...3840
    /// A fresh install's preview resolution — Capture One's own default for
    /// its preview image, and 2.56× the pixels of the 1600 it replaces.
    nonisolated static let defaultPreviewEdge = 2560
    nonisolated static let previewEdgeKey = Session.uiKey + "previewLongEdge"
    /// How long the edit must be still before the native render is committed
    /// to. It cannot be cancelled once the engine has started it, so some
    /// wait is right; 400 ms is a slider release and one breath.
    nonisolated static let fullRenderDebounceMs = 400

    /// The long edge every interactive edit renders at — the engine's `live`
    /// tier, and what the app sends as `preview_long_edge`.
    private(set) var previewLongEdge: Int = Session.previewEdge(in: .standard)

    /// The rule, as a function of a defaults object.
    ///
    /// Split out so it can be tested on a **throwaway suite**, the way
    /// `PanelWidthStore` is. That is not a style preference: the obvious test
    /// — put the value in the argument domain, build a `Session`, check it —
    /// cannot be undone. `removeVolatileDomain(forName: UserDefaults
    /// .argumentDomain)` does not take, so the value stays for the rest of the
    /// process and every later `Session()` in the same test run reads it. That
    /// is not hypothetical: it happened here, and it surfaced three tests away
    /// as `the canvas is holding the frame itself` in
    /// `FrontendPolicyTests.testTheZoomLabelIsMeasuredAgainstTheNativeFrame`,
    /// whose canvas had been quietly raised to 8192.
    nonisolated static func previewEdge(in defaults: UserDefaults) -> Int {
        (defaults.object(forKey: previewEdgeKey) as? Int)
            .map { nearestPreviewEdge($0) } ?? defaultPreviewEdge
    }

    /// Map values persisted by older builds (or supplied through launch
    /// arguments) to the nearest supported picker value.
    nonisolated static func nearestPreviewEdge(_ edge: Int) -> Int {
        previewEdgeChoices.min { lhs, rhs in
            let leftDistance = abs(lhs - edge)
            let rightDistance = abs(rhs - edge)
            return leftDistance == rightDistance ? lhs < rhs : leftDistance < rightDistance
        } ?? defaultPreviewEdge
    }

    /// Set it. A build-layer field: the engine rebuilds its pipeline and drops
    /// the live tier's cached image and negative (`spk_set_params`), so the
    /// reprint that follows is made at the new size. Nothing else moves — the
    /// decode, the sidecar and the export are unaffected — and the native
    /// render that follows picks the change up for free.
    func setPreviewLongEdge(_ edge: Int) {
        let clamped = Session.nearestPreviewEdge(edge)
        guard clamped != previewLongEdge else { return }
        previewLongEdge = clamped
        UserDefaults.standard.set(clamped, forKey: Session.previewEdgeKey)
        guard let sid = serviceSessionID, selection != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.call(.setParams,
                SetParamsRequest(sessionID: sid,
                                 paramsDelta: ["preview_long_edge": .double(Double(clamped))]),
                as: SetParamsResponse.self)
            guard self.serviceSessionID == sid, self.selection != nil else { return }
            if let rr = try? await self.client.render(.reprint, RenderRequest(sessionID: sid)) {
                self.applyRender(rr, generation: self.serviceGeneration)
            }
        }
    }

    /// The native render in flight, and whether the canvas is waiting on one.
    private(set) var fullPending = false
    private var fullTask: Task<Void, Never>?
    private var fullGeneration = 0

    /// The settings clipboard (RFC-027): what ⇧⌘C took, with the groups it was
    /// taken with. In memory; a relaunch starts empty.
    private(set) var clipboard: SettingsClip?

    /// The Settings Clipboard section's seven boxes: which groups the *next*
    /// copy or sync takes. Persisted, and all seven by default, which is what ⇧⌘V
    /// copied before the groups existed.
    @ObservationIgnored private let clipboardDefaults: UserDefaults
    var clipboardGroups: Set<ClipboardGroup> {
        didSet {
            clipboardDefaults.set(clipboardGroups.map(\.rawValue).sorted(),
                                      forKey: Self.clipboardGroupsKey)
        }
    }

    nonisolated static let clipboardGroupsKey = uiKey + "clipboard.groups"

    private static func storedClipboardGroups(in defaults: UserDefaults) -> Set<ClipboardGroup> {
        guard let raw = defaults.stringArray(forKey: clipboardGroupsKey)
        else { return Set(ClipboardGroup.allCases) }
        return Set(raw.compactMap(ClipboardGroup.init(rawValue:)))
    }

    // MARK: undo and the work clock

    private var undoStack: [Sidecar] = []
    /// The piece each snapshot was taken with, in step with `undoStack`: a
    /// pair's own edits (its frames, their crops, the spacing) undo with the
    /// look. Nil for a frame.
    private var undoPairs: [(url: URL, pair: HalfFramePair)?] = []
    private var lastUndoAt = Date.distantPast
    private(set) var workSeconds: Double = 0
    private var workStarted: Date?
    private var workClock: Task<Void, Never>?
    /// Anything that holds the service or the user's attention. Drives the
    /// elapsed-time readout in the top bar; the service cannot report real
    /// progress over a blocking stdio transport (see `startClock`).
    var working: Bool { busy || fullPending || exportProgress != nil }

    // MARK: engine
    let renderer: Renderer
    let client: EngineClient
    let scheduler: RenderScheduler
    /// The app's diagnostics model (RFC-016). One object rather than a
    /// singleton reached for directly, so a test can hand in a session whose
    /// samples and records go to a directory of its own — but the app's is
    /// `.shared`, which is also what the Settings page binds to, so the memory
    /// numbers the page shows and the ones this session records are the same
    /// numbers from the same sampler (§8.5).
    let diagnostics: Diagnostics
    /// The display-only disk cache. It is separate from `DecodeResidency`
    /// because a cached RGBA preview cannot satisfy white-balance sampling or
    /// the engine's linear frame input.
    private let diskCache: DiskCacheStore?
    private let printWriteback: PrintWriteback?
    /// What the disk cache currently holds, for the Settings readout. Sampled
    /// on demand rather than maintained: the store is the one that knows, and
    /// a running total kept here would be a second source of truth that drifts
    /// every time an eviction happens without the app asking.
    private(set) var diskCacheBytes: UInt64 = 0
    /// Nil when the cache could not be opened at all — the readout says so
    /// rather than showing a confident 0.
    var hasDiskCache: Bool { diskCache != nil }
    /// The record's door. `diagnostics.log` and not `Log.shared` for the same
    /// reason: a test that injects a `Diagnostics` gets its records too.
    var log: Log { diagnostics.log }
    let catalog = StockCatalog.shared
    private var serviceSessionID: String?
    /// What `isDigitalIntermediate` last answered for a print of the frame on
    /// the canvas, by texture; weak, so it holds nothing alive.
    private let knownPrints = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()
    /// The film-edge framing the engine's frame was cut with (`framingKey`),
    /// or nil for the whole decode. Compared with `wantedEngineFraming` on
    /// every request: a different cut is a different frame (`requestPrint`).
    private(set) var engineFraming: String?
    private var engineArenaHandle: MemoryArena.Handle?
    /// Approximate engine session footprint for a 45 MP frame (PRD/IMPL-RFC-019-memory.md §3.2);
    /// this is an accounting estimate, not a live measurement.
    private static let engineArenaEstimateBytes = 1_200_000_000
    var serviceSessionIDForExport: String? { serviceSessionID }
    private var serviceGeneration = 0

    // MARK: the develop, on request
    //
    // A frame opens onto its *decode* — the display decode, Apple's own
    // rendering of the RAW (`DecodedImage.display`). It is what the user asked
    // to look at, it lands in a few hundred milliseconds, and it is the
    // picture the frame actually is. The develop — the linear decode rendered
    // for the engine, `open`, the solve and the first print, about half a
    // second at 45 MP — happens when someone asks for the *print*: Solve, an
    // edit, an export, a capture. `wantsDevelop` is that request, and it
    // survives a re-decode because a white-balance change is also a request
    // to see the result.

    /// Whether this frame's develop has been asked for.
    private var wantsDevelop = false
    /// Tests only: called after the develop's `open` delta is built and before
    /// it is sent, which is the one point where an edit lands on a session the
    /// engine is being handed without it (RFC-027 §5.1).
    @ObservationIgnored var afterOpenDeltaForTesting: (() -> Void)?
    /// What each of RFC-015 §2.3's four intents would choose for the frame on
    /// screen, as the last develop's `solve` reported them.
    ///
    /// Per frame and not persisted, like the decode itself: the numbers are a
    /// property of *this* frame's pixels, and a stale map would put another
    /// frame's exposure under this one's Tone pill. It exists so the Exp.
    /// Comp. sublabel can stay true across a Tone change without waiting for
    /// the develop's round trip — which is the reason `solve` reports all four
    /// at once.
    private var exposureEvByMethod: [String: Double]?
    /// Whether `decoded` has been superseded by a re-decode that has not
    /// landed yet.
    ///
    /// The reopen window is the one moment `decoded` is a frame the engine
    /// must not be handed: the white balance has changed, the new decode is
    /// still in flight, and `decoded` is the *previous* one. A develop asked
    /// for in that window would open the engine on a frame the user has
    /// already changed away from — and worse, `load`'s own tail calls
    /// `ensureDeveloped` and would find that session waiting for it, which is
    /// how a white-balance change came to do nothing at all (RFC-015 §1.1).
    ///
    /// It is a flag rather than `decoded = nil` because the white-balance
    /// panel reads `decoded` (`setWhiteBalance`, `pickNeutral`): clearing it
    /// for the length of a re-decode would blank and refill the panel on every
    /// drag.
    private var decodeIsStale = false
    /// The develop in flight, if any. Anything that needs the engine to hold
    /// the frame awaits it rather than starting a second one — which is what
    /// Solve pressed while the decode is still landing turns into.
    private var developTask: Task<String?, Never>?
    /// The decode in flight. `ensureDeveloped` waits on it; a reopen replaces it.
    private var loadTask: Task<Void, Never>?
    /// The single-flight frame pipeline (IMP §3, step 1). Every heavy stage of
    /// a load — RAW decode, preview render, native original — runs on its one
    /// serial queue under a generation that a frame switch supersedes.
    /// Detached tasks inherit no cancellation, which is how five stale jobs
    /// used to run to completion per click; a stale job here stops at its
    /// first checkpoint, and the blocking Metal wait runs off the cooperative
    /// pool.
    private let pipeline = FramePipeline()
    /// The open path's clock for the frame being loaded (RFC-016 §3). Set by
    /// `load`, so a develop that joins the open in flight reports the open's
    /// whole path — the decode and the preview texture included — rather than
    /// starting its own record at the engine.
    private var openClock: LoadClock?
    /// The largest texture side this app's device will make, from the engine's
    /// capabilities. Metal publishes no such property (D1), and over it
    /// `MTLTextureDescriptor` asserts rather than returning nil, so the app
    /// must stay inside it. Nil until capabilities land.
    private(set) var maxTextureEdge: Int?
    /// The background render of the *native* original (D3). One per selected
    /// frame: it is a full-resolution texture (363 MB at 45 MP, 1.2 GB at
    /// 151 MP), so it is replaced rather than accumulated, and the preview
    /// cache that makes switching frames instant stays at the live tier.
    private var nativeOriginalTask: Task<Void, Never>?
    /// The schedule key, count and delay state are read by the tests that pin
    /// one deferred native original per (frame, decode).
    private(set) var nativeOriginalKey: (URL, Int)?
    private(set) var nativeOriginalScheduleCount = 0
    private(set) var nativeOriginalPendingDelay = false
    /// True from the moment a native-original task is scheduled until it lands
    /// or is cancelled; `canvasIsSettled` and the snapshot harness wait on it.
    private(set) var nativeOriginalInFlight = false
    private var nativeOriginalToken = 0
    private var decodedGeneration = 0
    private var displaySourceSize: CGSize?
    /// Testable counters for the two paths Q5 separates. A display-cache hit
    /// must leave `decodeCount` unchanged.
    private(set) var displayCacheHitCount = 0
    private(set) var decodeCount = 0
    /// Why the last display-cache lookup did not answer, or nil if it did.
    /// Cleared on a hit, so it always describes the most recent lookup rather
    /// than the worst one ever seen. A test that expects a hit reads this to
    /// say *which* step failed instead of only that the open decoded.
    private(set) var lastDisplayCacheMiss: CacheMissReason?
    private var wasPastPreview = false
    private var saveTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var printWritebackTask: Task<Void, Never>?
    // Renamed with the product. The old `com.hanze.spektrafilm` and
    // `com.hanze.filmify` directories are simply orphaned: this holds
    // decoded-TIFF caches, which rebuild on demand, so nothing needs
    // migrating and nothing is lost but disk.
    nonisolated static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.hanze.spektralab")
    nonisolated static var diskCacheRoot: URL { cacheRoot.appending(path: "store") }

    init(renderer: Renderer? = nil, diagnostics: Diagnostics = .shared,
         diskCache: DiskCacheStore? = nil, clipboardDefaults: UserDefaults = .standard) {
        self.clipboardDefaults = clipboardDefaults
        self.clipboardGroups = Self.storedClipboardGroups(in: clipboardDefaults)
        guard let renderer = renderer ?? Renderer(arena: diagnostics.arena) else {
            fatalError("Metal is required")
        }
        precondition(renderer.arena === diagnostics.arena,
                     "Session.renderer and Diagnostics must share one MemoryArena")
        self.renderer = renderer
        self.diagnostics = diagnostics
        self.decodeResidency = DecodeResidency(arena: diagnostics.arena)
        let cache = diskCache ?? (try? DiskCacheStore(root: Self.diskCacheRoot,
                                                     capBytes: diagnostics.diskCacheCapBytes))
        self.diskCache = cache
        self.printWriteback = cache.map { PrintWriteback(store: $0) }
        // The engine is in this process now (RFC-014): no subprocess, no
        // workspace directory, and no walking up to a checkout's `.venv`. It
        // gets the canvas's own `MTLDevice`, so a render lands in a texture
        // the canvas can draw without a copy.
        client = EngineClient(device: renderer.device, log: diagnostics.log)
        scheduler = RenderScheduler(client: client, log: diagnostics.log)
        scheduler.onResult = { [weak self] r, gen in self?.applyRender(r, generation: gen) }
        scheduler.onError = { [weak self] error in
            // Three, deliberately: the status line gets something a user can
            // act on, the canvas trace keeps the engine's own words, and the
            // log gets both plus what produced it (RFC-016 §3 `error`).
            self?.noteFailure(error, operation: "render")
        }
        scheduler.onBusy = { [weak self] b in
            guard let self else { return }
            self.busy = b
            if b { self.startClock() }
        }
        renderer.onHistogram = { [weak self] h in self?.histogram = h }
        renderer.onViewportChanged = { [weak self] in self?.viewportChanged() }
        // RFC-028: a Digital Intermediate's pixels are Cineon codes. The
        // canvas, Post-Dev and every rendered export read them through the DI
        // view (`CineonLUT`); only the Digital Intermediate export writes the
        // codes themselves.
        renderer.layer2DecodesCineon = { [weak self] texture in
            self?.isDigitalIntermediate(texture) ?? false
        }
        renderer.layer2 = sidecar.adjustments.uniforms
        Session.removeLegacyLinearCache()
        if let cache {
            Task.detached(priority: .utility) {
                try? await cache.garbageCollect()
                try? await cache.trimToCap()
            }
            // The Settings row and the store, joined here because this is the
            // object that has both. A cap changed while the app is running is
            // applied at once, not at the next launch: lowering it is how a
            // person asks for the disk back.
            diagnostics.onDiskCacheCapChanged = { bytes in
                Task.detached(priority: .utility) { try? await cache.setCapBytes(bytes) }
            }
            Task { [weak self] in
                let bytes = (try? await cache.totalBytes()) ?? 0
                await MainActor.run { self?.diskCacheBytes = bytes }
            }
        }
        Task { await client.set(onTermination: { [weak self] reason in
            Task { @MainActor in self?.serviceReady = false; self?.status = reason; self?.lastError = reason }
        }) }
        bootTask = warmUp()
    }

    /// Start the service and pay for its imports before anyone asks it to do
    /// something.
    ///
    /// `call` starts the process lazily, so the first request of the session
    /// was always `open` — and it carried ~1.9 s of Python interpreter start
    /// and module import (numpy, mlx, colour-science) on its back. Measured
    /// through the app: `service.open` 4.5 s cold against 2.6 s for the same
    /// call in a warm process. The app knows at launch that it is going to
    /// need the service, so it should not make the user's first frame pay for
    /// finding that out.
    ///
    /// `capabilities` is the request to warm with: it touches the import path
    /// and the Metal device, and it is how the client learns which executor
    /// it got — so the status bar can say "Metal" before a frame is open
    /// rather than after the first render.
    /// Awaited by the first `open` (see `bootTask`), so warm-up is a *gate*
    /// rather than a race. `ServiceClient` is an actor and serialises calls in
    /// submission order, so `capabilities` normally landed first anyway — but
    /// "normally" is not a guarantee: a frame restored at launch can submit
    /// `open` first, and then the first `open` carries the whole interpreter
    /// start on its back, which is the bug this method exists to prevent.
    @discardableResult
    private func warmUp() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                let caps: Capabilities = try await self.client.call(.capabilities, as: Capabilities.self)
                self.accept(caps)
                canvasLog("service warm · core=\(caps.backend?.renderCore ?? "?") · engine \(caps.engine)")
                // §1.1: "which engine am I actually running?" — a whole day
                // went to an app rendering on an engine nobody had chosen, so
                // this is one record at startup carrying the version, the
                // resources directory, the render core and both size limits.
                let bundled = await self.client.resourcesAreBundled
                let resourcesPath = self.client.resources.path
                if let json = await self.client.capabilitiesJSON {
                    self.diagnostics.noteCapabilities(json: json, version: caps.engine)
                }
                self.log.info(.engine, "capabilities", [
                    .init("version", caps.version),
                    .init("engine", caps.engine),
                    .init("render_core", caps.backend?.renderCore ?? "unreported"),
                    .init("backend", caps.backend?.label ?? "unreported"),
                    .init("gpu", caps.backend?.gpu ?? ""),
                    .init("precision", caps.backend?.workingPrecision ?? ""),
                    .init("max_mp", caps.maxMP),
                    .init("max_texture_dimension_2d", caps.maxTextureDimension2D ?? 0),
                    .init("transport", caps.transportVersion),
                    .init("schema", caps.schemaVersion),
                    .init("tiers", caps.tiers.keys.sorted().joined(separator: ",")),
                    .init("resources", bundled ? "bundle" : resourcesPath),
                ])
            } catch {
                // Deliberately not swallowed. This used to be `try?`, so a
                // capabilities block the client could not decode looked
                // exactly like a service that had not started yet — and the
                // first symptom would have been the *next* thing to fail,
                // several seconds later, somewhere else.
                canvasLog("warm-up failed: \(error)")
                self.serviceBlocked = Session.capabilitiesFailure(error)
                // The boot window must not trap the user in it. A service we
                // cannot talk to is a thing to say in the editor, where the
                // blocking panel and its restart button already live.
                self.bootPhase = .failed(Session.capabilitiesFailure(error))
                return
            }
            self.bootPhase = .warming
            await self.payFirstFrameSetup()
            self.bootPhase = .ready
        }
    }

    /// `warm_up` (RFC-013 §3): build the profile pair and its pipeline before
    /// the first `open` asks for them.
    ///
    /// This is not the same saving as `capabilities`. That one pays the
    /// interpreter start and the imports; this one pays the *pipeline
    /// construction* for a stock pair — the filming `tc_lut`, the enlarger and
    /// scanner LUTs, the fused kernel constants. Measured by the backend at
    /// ~130 ms, removing 124 ms from a 1 MP first open and 169–502 ms from a
    /// 45 MP one.
    ///
    /// It is warmed with the **sidecar's** stocks, not the defaults: the engine
    /// builds a pipeline for the pair it is handed, so warming
    /// `portra_400 / supra_endura` when the restored frame wants
    /// `provia_100f / 2383` pays the cost twice and saves nothing.
    ///
    /// A failed step is not fatal — the work is simply paid again inside
    /// `open` — so this logs and returns rather than blocking the app.
    private func payFirstFrameSetup() async {
        let p = sidecar.params
        do {
            let r: WarmUpResponse = try await client.call(
                .warmUp, WarmUpRequest(filmStock: p.filmStock, printStock: p.printStock),
                as: WarmUpResponse.self)
            warmUpMs = r.totalMs
            let failed = r.failedSteps
            canvasLog("warm_up: \(Int(r.totalMs ?? 0)) ms · core=\(r.renderCore ?? "?")"
                      + (r.alreadyWarm == true ? " · already warm" : "")
                      + (failed.isEmpty ? "" : " · FAILED: \(failed.joined(separator: ", "))"))
            // §3 `engine`: every `warm_up` with its elapsed time. A step that
            // failed is not fatal — it is paid again inside `open` — so this is
            // a `warn` rather than an `error` when it happens.
            log.log(failed.isEmpty ? .info : .warn, .engine, "warm_up", [
                .init("ms", r.totalMs ?? 0),
                .init("core", r.renderCore ?? "?"),
                .init("already_warm", r.alreadyWarm ?? false),
                .init("failed", failed.joined(separator: ",")),
            ])
        } catch {
            // Older services do not have the method at all, which is fine:
            // the wire addition is optional and a client that skips it behaves
            // exactly as it did before (handoff §"Wire").
            canvasLog("warm_up unavailable or failed: \(error)")
            log.warn(.engine, "warm_up unavailable", [.init("error", "\(error)")])
        }
    }

    /// Awaited before the first `open`. Nil once boot has been paid.
    private var bootTask: Task<Void, Never>?
    /// What `warm_up` cost, for the open-path log.
    private var warmUpMs: Double?

    // MARK: - boot
    //
    // RFC-012 §6 and RFC-013 §3: the app has a fixed amount of setup to do
    // before it can render anything, and it should do it while the user is
    // looking at something that says so — the way Photoshop and Capture One
    // start with a small window before their main one.
    //
    // The rule that keeps this from being a slow app with a logo: **the boot
    // window must cover work the app has to do anyway.** Nothing here sleeps,
    // nothing is padded, and if the engine is already warm the window is on
    // screen for a few frames and gone. What it buys is not time — it is that
    // the ~1.3 s of interpreter start and pipeline construction happens
    // somewhere the user can see a reason for it, instead of inside their
    // first photograph.

    enum BootPhase: Equatable, Sendable {
        case starting            // spawning the process, paying imports
        case warming             // building the pipeline for the sidecar's stocks
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .starting: "Starting the render engine…"
            case .warming: "Preparing the film pipeline…"
            case .ready: "Ready"
            case .failed(let why): why
            }
        }
    }

    private(set) var bootPhase: BootPhase = .starting
    /// True once the app is fit to show its main window.
    var booted: Bool { if case .ready = bootPhase { true } else { false } }

    /// Why the app will not render, or nil. Contract §2: "FE refuses to start
    /// against a transport version it does not know, with a visible error
    /// rather than a blank canvas."
    private(set) var serviceBlocked: String?

    /// Take a capabilities block and decide whether we can talk to it.
    private func accept(_ caps: Capabilities) {
        if let why = caps.unsupportedTransport {
            serviceBlocked = why
            serviceReady = false
            return
        }
        serviceBlocked = nil
        backend = caps.backend
        serviceReady = true
        // Metal publishes no maximum-texture property, so this comes from the
        // engine, which probes the device (`capabilities.max_texture_dimension_2d`).
        // Nil from an engine that does not report it.
        if let edge = caps.maxTextureDimension2D, edge > 0 { maxTextureEdge = Int(edge) }
        if let why = caps.schemaMismatch { stockWarning = why }
        Task { [client] in
            let catalog = (try? await client.printLUTCatalog()) ?? [:]
            await MainActor.run { self.printLUTStocks = catalog }
        }
    }

    /// A decoding failure against `capabilities` is a wire problem, and the
    /// message has to say so — `keyNotFound(CodingKeys(stringValue:
    /// "transport_version"))` is true and useless.
    static func capabilitiesFailure(_ error: Error) -> String {
        guard let d = error as? DecodingError else {
            return "The render service did not answer `capabilities`: \(error)"
        }
        let field: String
        switch d {
        case .keyNotFound(let key, _): field = key.stringValue
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            field = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        default: field = "?"
        }
        return "The render service's `capabilities` block is missing or malformed "
             + "at `\(field)`. The app cannot tell which wire it is speaking, so it "
             + "will not render. See CONTRACT-frontend-backend.md §2."
    }

    // MARK: - library

    func open(urls: [URL]) {
        guard !batchExporting else { status = "An export is running."; return }
        // A pair opened by its own file: its folder's filmstrip, with the pair
        // on the canvas.
        if let pairURL = urls.first(where: HalfFramePair.isPair), let p = HalfFramePair.load(pairURL) {
            open(urls: [URL(fileURLWithPath: p.folder)])
            if let listed = frames.first(where: { $0.id.standardizedFileURL == pairURL.standardizedFileURL }) {
                click(listed.id)
            }
            return
        }
        let files = Library.frames(from: urls)
        guard !files.isEmpty else { status = "Nothing openable in the selection."; return }
        let new = FrameOrder.applied(to: Self.withPairs(files))
        if let selection, !new.contains(where: { $0.id == selection }) {
            enqueuePrintWriteback(for: selection)
        }
        ThumbnailCache.shared.clear()
        frames = new
        // One read per frame, for both things the library shows of it.
        let saved = new.map { ($0.id, Sidecar.load(for: $0.id)) }
        frameStates = Dictionary(uniqueKeysWithValues: saved.map { ($0.0, $0.1?.state ?? .unprocessed) })
        savedGeometry = Dictionary(uniqueKeysWithValues: saved.map { ($0.0, $0.1?.geometry ?? .default) })
        filmEdgeThumbnails = Set(saved.filter { $0.1?.params.cutsFrame == true }.map(\.0))
        libraryTitle = urls.count == 1 ? urls[0].lastPathComponent : "\(files.count) files"
        renderer.store.removeAll()
        // A new folder is a new set: whatever was picked belongs to the
        // library that was open, and carrying it across would leave the batch
        // holding frames that are no longer in `frames` — which is exactly
        // what `selectedFrames` maps over, so they would vanish silently and
        // the count would disagree with the set. Dropped here, at the one
        // point where `frames` is replaced.
        picked = []
        // One file is a handoff — Finder's "Open With", a Capture One "Edit
        // With", a single drop — and it means "develop this". A folder or a
        // multi-file selection is a session to look through, and the old build
        // rendered the alphabetically-first frame there, spending seven seconds
        // and 363 MB on a guess (HANDOFF §2). Now it renders nothing until a
        // frame is chosen.
        if files.count == 1 {
            click(files[0].id)
        } else {
            unloadSelection()
        }
    }

    /// Put the session down to nothing selected, keeping `frames`.
    ///
    /// This was `enterBrowse()` and it is the same teardown; only the page it
    /// used to switch to has gone. The name says what it does rather than
    /// where it went, because it is also what `remove(_:)` calls when the
    /// open frame is the one dropped.
    private func unloadSelection() {
        if let selection { enqueuePrintWriteback(for: selection) }
        selection = nil
        pair = nil
        pairRightExif = nil
        renderer.store.dropIdleScratch()
        decodeResidency.clear()
        displaySourceSize = nil
        decodeIsStale = false
        exposureEvByMethod = nil
        wantsDevelop = false
        developTask?.cancel(); developTask = nil
        sourceLongEdge = 0
        exif = nil
        stockWarning = nil
        previewSoft = false
        refusal = nil
        memoryWarning = nil
        fullPending = false
        fullTask?.cancel(); fullTask = nil
        fullGeneration += 1
        loadTask?.cancel()
        pipeline.supersede()
        renderer.dropFullRender()
        renderer.setLive(nil)
        renderer.original = nil
        cancelNativeOriginal()
        decodedGeneration = 0
        scheduler.invalidate()
        releaseEngineAccounting()
        serviceSessionID = nil
        engineFraming = nil
        status = "\(frames.count) frames · pick one in the filmstrip to develop."
    }

    func openPanel() { let urls = Library.chooseFilesOrFolder(); if !urls.isEmpty { open(urls: urls) } }

    /// Re-read a frame's sidecar state — used after a reset from the grid.
    func refreshState(for url: URL) {
        let saved = Sidecar.load(for: url)
        frameStates[url] = saved?.state ?? .unprocessed
        savedGeometry[url] = saved?.geometry ?? .default
        if url == selection { sidecar = Sidecar.load(for: url) ?? Sidecar() }
    }

    /// Drop a frame from the session. Never touches the file.
    ///
    /// It leaves the picked set with it: `selectedFrames` maps over `frames`,
    /// so a url left in the set would be invisible — the batch would be short
    /// by one with nothing on screen to say which one.
    func remove(_ url: URL) {
        if selection == url { enqueuePrintWriteback(for: url) }
        frames.removeAll { $0.id == url }
        frameStates[url] = nil
        picked.remove(url)
        renderer.store.invalidatePrint(for: url)
        if frames.isEmpty {
            selection = nil
            renderer.setLive(nil)
            status = "Open a folder or an image to begin."
        } else if selection == url {
            unloadSelection()
        }
    }

    /// A chevron or an arrow key: the same act as a plain click on the
    /// neighbouring frame, and it collapses the set for the same reason.
    func selectRelative(_ delta: Int) {
        guard let selection, let i = frames.firstIndex(where: { $0.id == selection }) else { return }
        let j = (i + delta).clamped(to: 0...(frames.count - 1))
        if j != i { click(frames[j].id) }
    }

    /// A left click on a thumbnail — the only thing the person can do that
    /// adds to or removes from the picked set.
    ///
    /// `command` is the ⌘ modifier. A plain click picks exactly this frame,
    /// collapsing whatever set there was, and opens it; ⌘-click toggles one
    /// frame's membership and **leaves the canvas where it is**, which is what
    /// `notes.md` asks for ("the viewed image stays as the one the user is
    /// previously on"). There is no ⇧-click and no range extension: the two
    /// modifiers this app has are the two that change one frame at a time, so
    /// a stray ⇧-click does nothing rather than silently adding a range.
    ///
    /// The modifier is a parameter and not read off `NSEvent` in here, so that
    /// what a ⌘-click does is testable without synthesising one — the reading
    /// itself stays in the gesture, once, at each call site.
    func click(_ url: URL, command: Bool = false) {
        guard !batchExporting else { return }
        guard command else {
            picked = [url]
            select(url)
            return
        }
        togglePick(url)
    }

    var canSelectAllFrames: Bool { !batchExporting && !frames.isEmpty }

    /// Keep the current frame as the sync source. A folder with no open frame
    /// starts with the first in display order; only that frame is loaded.
    func selectAllFrames() {
        guard canSelectAllFrames else { return }
        picked = Set(frames.map(\.id))
        if selection == nil, let first = frames.first { select(first.id) }
    }

    /// One frame in or out of the set, canvas unmoved.
    ///
    /// The open frame cannot leave it. A batch that excludes the photograph on
    /// the canvas is a state with nothing to read off it — the export page
    /// proves the frame it is about to write, so a set without that frame in
    /// it is a proof of something the run will not produce — and it is
    /// reachable by a single ⌘-click, which is how a person loses a selection
    /// they never meant to lose. ⌘-clicking the open frame is therefore a
    /// no-op rather than an unselect, and the way to drop it is to open
    /// another frame.
    func togglePick(_ url: URL) {
        guard !batchExporting else { return }
        guard picked.contains(url) else { picked.insert(url); return }
        guard url != selection else { return }
        picked.remove(url)
    }

    /// Put a frame on the canvas without touching the picked set.
    ///
    /// Not `click`: a plain click collapses the set, which is right in the
    /// filmstrip (the set is invisible there) and wrong on the export page,
    /// where the set *is* the page's content. Not `select` either: `select` is
    /// the internal load, and the export run calls it deliberately for that
    /// reason. This is the person's gesture on a page whose list is the batch.
    func open(_ url: URL) {
        guard !batchExporting, picked.contains(url) else { return }
        select(url)
    }

    func select(_ url: URL) {
        guard url != selection || decoded == nil else { return }
        flushSave()
        renderer.store.dropIdleScratch()
        if let leaving = selection, leaving != url {
            enqueuePrintWriteback(for: leaving)
        }
        loadTask?.cancel()
        selection = url
        filmCanvasOn = nil
        latitude.clear()
        previewSoft = false
        sourceLongEdge = 0
        // A new frame invalidates the previous frame's native render; the
        // print that lands for *this* one asks for its own.
        fullPending = false
        fullTask?.cancel(); fullTask = nil
        fullGeneration += 1
        // A new frame has asked for nothing yet: it opens onto its decode, and
        // the develop waits for Solve or an edit (see `wantsDevelop`).
        wantsDevelop = false
        developTask?.cancel(); developTask = nil
        renderer.dropFullRender()
        sidecar = Sidecar.load(for: url) ?? Sidecar()
        // Except a frame with an edit the engine has not rendered — a paste
        // made while another frame was on the canvas (RFC-027 §4). That edit
        // asked for a develop as surely as a slider does, and without one the
        // frame would open onto its bare decode. Nothing else saves `.stale`.
        if sidecar.state == .stale { wantsDevelop = true }
        adoptPair(for: url)
        exif = EXIFReadout.read(pair?.left?.url ?? url)
        seedFilmEdge(for: url)
        resolveFilmEdge()
        pushLayer2(sidecar.adjustments)
        renderer.geometry = canvasGeometry
        selectedMaskID = sidecar.masks.first?.id
        syncMasks()
        decodeResidency.clear()
        displaySourceSize = nil
        decodeIsStale = false
        exposureEvByMethod = nil
        openClock = nil
        stockWarning = nil
        // Both belong to the frame that is going away (§11.5): a refusal and a
        // memory warning are statements about *that* frame's pixels, and
        // carrying them to the next one would be the app crying wolf.
        refusal = nil
        memoryWarning = nil
        // Show the last print of this frame instantly if it is resident. The
        // viewport is expressed against the *native* frame (D4), which is not
        // known until this frame decodes — so until then it is expressed
        // against what is on screen, and `load` corrects it when the decode
        // lands (`refreshLogicalSize` refits, because the view was fitted).
        if let cached = renderer.store.print(for: url) {
            renderer.setLive(cached, logical: printLogicalSize(for: cached, params: sidecar.params, frame: nativeSourceSize)
                             ?? CGSize(width: cached.width, height: cached.height)); previewSoft = true
        } else if let src = renderer.store.source(for: url) {
            renderer.setLive(src, logical: nativeSourceSize ?? CGSize(width: src.width, height: src.height)); previewSoft = true
        } else {
            renderer.setLive(nil)
        }
        renderer.original = renderer.store.source(for: url)
        cancelNativeOriginal()
        decodedGeneration = 0
        scheduler.invalidate()
        releaseEngineAccounting()
        serviceSessionID = nil
        engineFraming = nil
        // A memory boundary (§3): what switching frames costs is the question
        // behind "switching frames is slow".
        sampleMemory("frame_switch")
        let gen = pipeline.supersede()
        loadTask = Task { await load(url, generation: gen) }
        // `prefetchNeighbours(of:)` was deleted here (IMPL-decode-pipeline §4).
        // It had three defects and no measurement behind it: its entries were
        // never removed and never cancelled — not on a frame change, not in
        // `open(urls:)`, not on completion — so a 200-frame folder accumulated
        // 200 retained tasks and full decodes; the `prefetch[f.id] == nil`
        // guard meant a frame prefetched once was never prefetched again, even
        // after `TextureStore`'s LRU (capacity 8) had evicted its texture, so
        // the cache it existed to fill went cold and stayed cold; and
        // `.background` plus a blocking `waitUntilCompleted` is the worst case
        // for the cooperative pool. Rebuild it — same pipeline, strictly below
        // the foreground job, entries removed on completion and cancelled on
        // frame change — only if a measurement with step 1 and then the decode
        // cache in place says the misses matter. None was ever taken.
    }

    // MARK: - the load pipeline

    /// Wall-clock for one stage of the open path, logged under
    /// `SPEKTRAFILM_CANVAS_LOG=1`.
    ///
    /// This exists because "opening a frame takes eight seconds" is not
    /// actionable and points at the wrong half of the app. The render service
    /// is the visible, instrumented part — it reports `elapsed_ms` and the
    /// status bar shows it — so a slow open reads as a slow *render*. It was
    /// not: with the GPU-native core a live reprint is ~20 ms and the eight
    /// seconds are the client's own RAW decode and the 363 MB TIFF it writes
    /// to hand the frame over. One line per stage is the difference between
    /// knowing that and guessing it.
    /// A **class**, not a struct, and that is load-bearing: one open is one
    /// instrument, and a develop that joins an open already in flight (Solve
    /// pressed while the decode is still landing) has to report *that* open's
    /// stages. Handed by value, the second caller starts from zero and the
    /// `open` record describes half the path it is supposed to describe — which
    /// is exactly what RFC-016 §3 asks a record to fix.
    final class LoadClock {
        private var last = Date()
        private var total = Date()
        private var parts: [String] = []
        /// The same laps, as record fields (RFC-016 §3 `open`: "carrying the
        /// LoadClock stages as fields rather than a prose line"). Milliseconds
        /// as a `Double`, not the integer the stderr line rounds to — a 1 MP
        /// frame's `preview-texture` is under a millisecond often enough that
        /// rounding it to 0 would make the field a lie.
        private(set) var stages: [LogField] = []

        func lap(_ name: String) {
            let now = Date()
            let ms = now.timeIntervalSince(last) * 1000
            parts.append("\(name) \(Int(ms))")
            stages.append(.init(LoadClock.fieldName(name), ms))
            last = now
        }

        func summary() -> String {
            "open path (ms): " + parts.joined(separator: " · ") +
            " · TOTAL \(Int(Date().timeIntervalSince(total) * 1000))"
        }

        func totalMs() -> Double { Date().timeIntervalSince(total) * 1000 }

        /// Session setup a cold frame has to pay again before a print can be
        /// restored or recomputed.
        var setupMs: Double {
            let wanted = Set([
                Self.fieldName("decode"),
                Self.fieldName("frame"),
                Self.fieldName("engine.open"),
                Self.fieldName("solve"),
            ])
            return stages.filter { wanted.contains($0.name) }.reduce(0) { total, field in
                switch field.value {
                case .double(let value): total + value
                case .int(let value): total + Double(value)
                case .string, .bool: total
                }
            }
        }

        /// `engine.open` → `engine_open_ms`. The log's keys are snake_case and
        /// greppable; the stderr line keeps the engine's own spelling, because
        /// `AGENTS.md` documents it and people grep for it.
        static func fieldName(_ stage: String) -> String {
            stage.replacingOccurrences(of: "-", with: "_")
                 .replacingOccurrences(of: ".", with: "_") + "_ms"
        }
    }

    /// Cancel the task keyed to the current frame/decode and invalidate its
    /// token so a late cancellation cannot clear a newer task's state.
    private func cancelNativeOriginal() {
        nativeOriginalTask?.cancel()
        nativeOriginalTask = nil
        nativeOriginalPendingDelay = false
        nativeOriginalToken &+= 1
        nativeOriginalInFlight = false
        nativeOriginalKey = nil
        wasPastPreview = false
    }

    private func requestNativeOriginal(trigger: String) {
        guard let url = selection else { return }
        guard let d = decoded else {
            Task {
                guard await ensureDecoded() != nil, selection == url else { return }
                requestNativeOriginal(trigger: trigger)
            }
            return
        }
        // Zoom is already mirrored through viewportChanged; no new canvas
        // plumbing is needed. If that mirror is ever removed, keep this hook
        // as the place to instrument the zoom-past-preview trigger.
        guard trigger == "comparing" || trigger == "idle_delay" || wantsFullRender else { return }
        let key = (url, decodedGeneration)
        if let existing = nativeOriginalKey, existing == key {
            // One render per (frame, decode). The idle delay is still
            // interruptible by a person asking for the original now; an
            // in-flight or landed render is not asked for again.
            let preemptsDelay = nativeOriginalPendingDelay
                && (trigger == "comparing" || trigger == "zoom_past_preview")
            guard preemptsDelay else { return }
        }
        log.info(.canvas, "native original trigger", [.init("trigger", trigger),
                                                       .init("frame", url.lastPathComponent)])
        // This optional native-size decode is asked through the cache rule: it
        // is skippable, even though the texture is pinned once it lands. A
        // pinned registration itself is never refused (RFC-019 §1 rule 2);
        // this is the check the old debt comment pointed at.
        let allocationBytes = nativeOriginalAllocationBytes(d)
        // Best-effort cache preflight only: this sample prediction is not a
        // reservation, and the pinned original below remains user-owned.
        guard diagnostics.arena.wouldAdmitCache(bytes: allocationBytes) else {
            log.info(.canvas, "native original skipped", [
                .init("trigger", trigger),
                .init("frame", url.lastPathComponent),
                .init("bytes", allocationBytes),
                .init("reason", "memory_admission"),
            ])
            return
        }
        scheduleNativeOriginal(d, for: url, settings: sidecar.decode,
                               generation: decodedGeneration,
                               delayMs: trigger == "idle_delay" ? Session.fullRenderDebounceMs : 0)
    }

    /// Bytes for the native original after applying the same max-edge clamp
    /// `scheduleNativeOriginal` uses. The allocation never exceeds the frame's
    /// own aspect ratio or the engine-published texture edge.
    private func nativeOriginalAllocationBytes(_ d: DecodedImage) -> Int {
        let source = d.pixelSize
        let sourceEdge = max(source.width, source.height)
        guard sourceEdge > 0 else { return 0 }
        let edge = min(Int(sourceEdge), maxTextureEdge ?? previewLongEdge)
        let scale = min(1, Double(edge) / Double(sourceEdge))
        let width = max(1, Int((source.width * scale).rounded(.up)))
        let height = max(1, Int((source.height * scale).rounded(.up)))
        return width * height * 8
    }

    /// Render the *display* decode at the frame's own size and hand it to the
    /// canvas as the original.
    ///
    /// The same picture the live-tier preview is — Core Image's rendering of
    /// the RAW, not a second interpretation of it — at the size of the frame.
    /// `makePreviewTexture` with the native long edge resamples nothing: the
    /// scale comes out 1, and the only cost is the texture.
    ///
    /// Dropped rather than shown if anything has moved on by the time it
    /// lands: another frame selected, or a different decode (a white balance
    /// change) started. It is not kept in `renderer.store`, which is the
    /// small-texture cache the instant frame switch depends on.
    private func scheduleNativeOriginal(_ d: DecodedImage, for url: URL, settings: DecodeSettings,
                                        generation: Int, delayMs: Int = 0) {
        nativeOriginalTask?.cancel()
        nativeOriginalToken &+= 1
        let token = nativeOriginalToken
        nativeOriginalKey = (url, generation)
        nativeOriginalPendingDelay = delayMs > 0
        nativeOriginalInFlight = true
        nativeOriginalScheduleCount += 1
        let device = renderer.device
        // The frame's own size, capped at the largest texture the device will
        // make: past that the descriptor *asserts* and takes the process with
        // it, which is the case the engine refuses the frame for in the first
        // place. Falling back to the live tier keeps an older engine (one that
        // reports no limit) from crashing the app.
        let longEdge = min(Int(max(d.pixelSize.width, d.pixelSize.height)),
                           maxTextureEdge ?? previewLongEdge)
        let started = Date()
        let pipeline = self.pipeline
        nativeOriginalTask = Task { [weak self] in
            defer {
                if let self, self.nativeOriginalToken == token {
                    self.nativeOriginalInFlight = false
                }
            }
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
                if let self, self.nativeOriginalToken == token {
                    self.nativeOriginalPendingDelay = false
                }
            }
            guard let self, !Task.isCancelled else { return }
            let box: TextureBox
            if FeatureFlags.framePipeline {
                box = (try? await pipeline.run(generation: generation) { checkpoint in
                    TextureBox(try ImageDecoder.makePreviewTexture(d, device: device, maxEdge: longEdge, checkpoint: checkpoint))
                }) ?? TextureBox(nil)
            } else {
                box = TextureBox(ImageDecoder.makePreviewTexture(d, device: device, maxEdge: longEdge))
            }
            guard !Task.isCancelled, self.selection == url,
                  self.sidecar.decode == settings, let tex = box.texture else { return }
            self.renderer.original = tex
            // And onto the canvas, while the canvas is still the decode. Since
            // D4 the viewport is expressed against the *frame*, so a 1600 px
            // preview stretched into it claimed the frame's size while showing
            // a smaller picture — and the Original button, which showed the
            // native decode, then looked sharper than the thing it is the
            // original of. The same texture object, so this costs nothing, and
            // the store is left alone: it holds small textures for the instant
            // frame switch, and a native one there would fill it.
            //
            // Never over a print: a develop that lands first owns the canvas.
            // `previewSoft` is the direct question — is the canvas showing
            // something other than the print — and the store lookup is the
            // same answer from the cache, which an eviction could lose.
            // A reopen (a white balance change) and a frame switch both go
            // through `load`, which puts the small preview up first — the open
            // stays as fast as it was — and this replaces it when it lands.
            // `previewSoft` stays true either way: this is still not a print.
            if self.previewSoft, self.renderer.store.print(for: url) == nil, !self.holdsFilmCanvas {
                self.renderer.setLive(tex, logical: d.pixelSize)
                self.previewSoft = true
            }
            canvasLog("original \(url.lastPathComponent) at \(tex.width)x\(tex.height) "
                      + "landed in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            self.renderer.needsDraw?()
        }
    }

    /// Everything that rides with an `open`, in one place.
    ///
    /// **This is the frontend's half of the open contract.** It is a named,
    /// tested function rather than six lines in the middle of `load` because
    /// the panels that feed it are being rebuilt, and two of the three entries
    /// below are decisions the engine cannot re-derive if a rework drops them:
    ///
    ///  - `fullDelta` is the frame's own settings, from the sidecar.
    ///  - `preview_long_edge` is a *session* setting, not a frame parameter,
    ///    which is why it is added here rather than living in the sidecar: a
    ///    frame copied to another library must not carry the resolution its
    ///    author happened to be using.
    ///  - `product_defaults` asks the engine for SpektraLab's defaults rather
    ///    than the reference's — today, that Camera Exp. Comp. moves the
    ///    finished print's brightness instead of only the negative's placement
    ///    on the film curve. The engine used to infer this from the presence
    ///    of `preview_long_edge`, so moving the preview resolution to a
    ///    `set_params` after open would have silently changed every print.
    ///    `FrontendPolicyTests` pins both keys for that reason.
    nonisolated static func openDelta(sidecar: Sidecar, previewLongEdge: Int) -> [String: ParamValue] {
        var delta = sidecar.params.fullDelta
        delta["preview_long_edge"] = .double(Double(previewLongEdge))
        delta["product_defaults"] = .bool(true)
        return delta
    }

    nonisolated static func displayCacheKey(url: URL, settings: DecodeSettings,
                                            previewLongEdge: Int,
                                            engineVersion: String) -> CacheKey {
        CacheKey(
            kind: .decode,
            sourceIdentity: CacheKey.sourceIdentity(for: url),
            configuration: CacheKey.encodedConfiguration(settings),
            previewLongEdge: previewLongEdge,
            engineVersion: engineVersion
        )
    }

    nonisolated static func printCacheKey(url: URL, params: FilmParams, tier: CacheTier,
                                          previewLongEdge: Int,
                                          engineVersion: String) -> CacheKey {
        CacheKey(
            kind: tier == .live ? .printLive : .printFull,
            sourceIdentity: CacheKey.sourceIdentity(for: url),
            configuration: printStamp(params),
            tier: tier,
            previewLongEdge: tier == .live ? previewLongEdge : nil,
            engineVersion: engineVersion
        )
    }

    /// Resolve a finished print from disk without decoding or opening the
    /// engine. Layer 2 and geometry are applied at draw time, so the stored
    /// bytes are the same live/full engine output the canvas would otherwise
    /// wait to recompute.
    private func cachedPrint(for url: URL) async -> (texture: MTLTexture, sourceSize: CGSize,
                                                      costMs: Double, key: CacheKey)? {
        guard let diskCache else { return nil }
        let key = Self.printCacheKey(
            url: url,
            params: sidecar.params,
            tier: .live,
            previewLongEdge: previewLongEdge,
            engineVersion: diagnostics.engineVersion ?? "unknown"
        )
        guard let payload = try? await diskCache.load(key),
              payload.kind == .printLive,
              payload.format == "rgba16Unorm",
              let texture = renderer.store.uploadRGBA16(
                  data: payload.data, width: payload.width, height: payload.height
              ) else { return nil }
        return (texture,
                CGSize(width: payload.sourceWidth, height: payload.sourceHeight),
                payload.costMs,
                key)
    }

    /// Resolve a display picture without constructing a `DecodedImage`.
    ///
    /// The disk entry is deliberately RGBA-only. It may be drawn and compared,
    /// but it is not allowed to satisfy `decoded`, the engine input, or the
    /// white-balance sampler.
    func displayPicture(for url: URL, settings: DecodeSettings) async -> DisplayPicture? {
        let key = DecodeKey(url: url, settings: settings)
        if decodeResidency.contains(key), let d = decoded,
           let texture = renderer.store.source(for: url) {
            return DisplayPicture(texture: texture, sourceSize: d.pixelSize, costMs: 0)
        }
        guard let diskCache else { return noteDisplayMiss(.noStore, url: url) }
        guard let engineVersion = diagnostics.engineVersion else {
            return noteDisplayMiss(.engineUnknown, url: url)
        }
        let cacheKey = Self.displayCacheKey(
            url: url,
            settings: settings,
            previewLongEdge: previewLongEdge,
            engineVersion: engineVersion
        )
        let started = Date()
        let payload: DiskCachePayload?
        do { payload = try await diskCache.load(cacheKey) }
        catch { return noteDisplayMiss(.lookupFailed, url: url, error: error) }
        guard let payload else { return noteDisplayMiss(.noEntry, url: url) }
        guard payload.kind == .decode else { return noteDisplayMiss(.wrongKind, url: url) }
        guard payload.format == "rgba16Unorm" else { return noteDisplayMiss(.wrongFormat, url: url) }
        guard let texture = renderer.store.uploadRGBA16(
            data: payload.data, width: payload.width, height: payload.height
        ) else { return noteDisplayMiss(.uploadFailed, url: url) }
        lastDisplayCacheMiss = nil
        return DisplayPicture(
            texture: texture,
            sourceSize: CGSize(width: payload.sourceWidth, height: payload.sourceHeight),
            costMs: Date().timeIntervalSince(started) * 1000
        )
    }

    /// Record why the display cache did not answer, and return the `nil` the
    /// caller was going to return anyway.
    ///
    /// `noEntry` is logged at `debug` because a cold cache is the normal state
    /// of a frame nobody has opened. Everything else is `info`: something was
    /// stored and could not be used, and the user is about to pay for a decode
    /// that should not have been necessary.
    @discardableResult
    private func noteDisplayMiss(_ reason: CacheMissReason, url: URL,
                                 error: Error? = nil) -> DisplayPicture? {
        lastDisplayCacheMiss = reason
        var fields: [LogField] = [.init("reason", reason.rawValue)]
        if diagnostics.includeFileNamesInBundle { fields.append(.init("file", url.lastPathComponent)) }
        if let error { fields.append(.init("error", String(describing: error))) }
        if reason == .noEntry {
            log.debug(.open, "display-cache miss", fields)
        } else {
            log.info(.open, "display-cache miss", fields)
        }
        return nil
    }

    private func load(_ url: URL, generation: Int, requiresDecode: Bool = false) async {
        status = requiresDecode ? "Decoding \(url.lastPathComponent)…"
                                : "Opening \(url.lastPathComponent)…"
        // Kept on the session as well as in this scope: a develop asked for
        // from outside (`Solve` while the decode is landing, an export) joins
        // *this* open and must report its laps, not an empty clock of its own.
        let clock = LoadClock()
        openClock = clock
        // Before the first cache key is built, not merely before the engine is
        // called: the key carries `diagnostics.engineVersion`, and warm-up is
        // what publishes it. See `awaitBoot`.
        await awaitBoot(clock)
        guard !Task.isCancelled, selection == url else { return }
        let settings = sidecar.decode
        let device = renderer.device
        let edge = previewLongEdge
        // The two cache shortcuts end the open at a picture. A frame that has
        // already asked for its develop (a paste made while it was off the
        // canvas, RFC-027 §4) needs the decode anyway, so it skips them —
        // otherwise it would stop at the cached picture and never develop.
        if !requiresDecode, !wantsDevelop, let picture = await cachedPrint(for: url) {
            guard !Task.isCancelled, selection == url else { return }
            sourceLongEdge = max(picture.sourceSize.width, picture.sourceSize.height)
            displaySourceSize = picture.sourceSize
            renderer.store.setPrint(
                picture.texture, stamp: Self.printStamp(sidecar.params), for: url,
                costMs: picture.costMs, cacheKey: picture.key,
                sourceWidth: Int(picture.sourceSize.width.rounded()),
                sourceHeight: Int(picture.sourceSize.height.rounded())
            )
            renderer.setLive(picture.texture, logical: printLogicalSize(for: picture.texture, params: sidecar.params,
                                                                        frame: picture.sourceSize))
            previewSoft = false
            clock.lap("print-cache")
            noteOpen(clock, url: url, mode: "print-cache", pixels: picture.sourceSize)
            status = "\(url.lastPathComponent)  ·  restored print"
            return
        }
        if !requiresDecode, !wantsDevelop, let picture = await displayPicture(for: url, settings: settings) {
            guard !Task.isCancelled, selection == url else { return }
            displayCacheHitCount += 1
            sourceLongEdge = max(picture.sourceSize.width, picture.sourceSize.height)
            displaySourceSize = picture.sourceSize
            renderer.store.setSource(picture.texture, for: url, costMs: picture.costMs)
            renderer.original = picture.texture
            if renderer.store.print(for: url) == nil, !holdsFilmCanvas {
                renderer.setLive(picture.texture, logical: picture.sourceSize)
                previewSoft = true
            }
            clock.lap("display-cache")
            noteOpen(clock, url: url, mode: "display-cache", pixels: picture.sourceSize)
            status = "\(url.lastPathComponent)  ·  cached preview"
            return
        }
        // Decode and preview, and then the frame is *on the canvas* — that is
        // the whole of an open. The develop is `develop(_:_:clock:)`, below,
        // and it runs only if it has been asked for (`wantsDevelop`).
        let decodedImage: DecodedImage?
        decodeCount += 1
        if FeatureFlags.framePipeline {
            decodedImage = try? await pipeline.run(generation: generation) { checkpoint in
                try ImageDecoder.decode(url, settings: settings, checkpoint: checkpoint)
            }
        } else {
            decodedImage = try? ImageDecoder.decode(url, settings: settings)
        }
        clock.lap("decode")
        guard !Task.isCancelled, selection == url, let d = decodedImage else {
            // A load that *failed* rather than being superseded must not leave
            // `decodeIsStale` set: every later `ensureDeveloped` would refuse
            // to develop this frame, and the frame would be undevelopable for
            // the rest of the session. A superseded load was cancelled by the
            // reopen that replaced it, and that one set the flag again for its
            // own decode.
            if !Task.isCancelled { decodeIsStale = false }
            // One record per click that did not land on the canvas: a
            // superseded or cancelled decode used to drop silently, which is
            // how the log showed frame switches and no decodes (IMP §3.6).
            noteOpen(clock, url: url, mode: "superseded", pixels: nil)
            return
        }
        let lease = DecodeLease(d)
        let preview: TextureBox
        if FeatureFlags.framePipeline {
            preview = (try? await withTaskCancellationHandler {
                try await pipeline.run(generation: generation) { checkpoint in
                    try checkpoint()
                    guard let image = lease.take() else { throw CancellationError() }
                    return TextureBox(try ImageDecoder.makePreviewTexture(
                        image, device: device, maxEdge: edge,
                        storageMode: .shared, checkpoint: checkpoint))
                }
            } onCancel: {
                lease.release()
            }) ?? TextureBox(nil)
        } else {
            preview = TextureBox(ImageDecoder.makePreviewTexture(
                d, device: device, maxEdge: edge, storageMode: .shared
            ))
            lease.release()
        }
        clock.lap("preview-texture")
        guard !Task.isCancelled, selection == url else {
            noteOpen(clock, url: url, mode: "superseded", pixels: nil)
            return
        }
        if sidecar.decode.whiteBalance == .asShot, let t = d.asShotTemperature,
           let tn = d.asShotTint,
           (sidecar.decode.temperature != t || sidecar.decode.tint != tn) {
            sidecar.decode.temperature = t
            sidecar.decode.tint = tn
        }
        let key = DecodeKey(url: url, settings: sidecar.decode)
        decodeResidency.adopt(d, for: key)
        decodedGeneration = generation
        decodeIsStale = false
        sourceLongEdge = max(d.pixelSize.width, d.pixelSize.height)
        displaySourceSize = d.pixelSize
        // The physical frame's long edge is half the user's description and
        // half this photograph's shape (`physicalAspect`), so it cannot be
        // settled until a decode has landed — a sidecar restored on launch
        // carries the description and a `film_format_mm` computed against
        // whatever the *last* frame's aspect was.
        recomputeFilmFormat(beforeOpen: true)
        sampleMemory("decode")
        var diskWrite: (key: CacheKey, data: Data, width: Int, height: Int,
                        sourceWidth: Int, sourceHeight: Int, costMs: Double)?
        if let tex = preview.texture, !Task.isCancelled, selection == url {
            renderer.store.setSource(tex, for: url, costMs: clock.totalMs())
            renderer.original = tex
            if renderer.store.print(for: url) == nil, !holdsFilmCanvas {
                renderer.setLive(tex, logical: d.pixelSize)
                previewSoft = true
            }
            if diskCache != nil {
                let cacheKey = Self.displayCacheKey(
                    url: url,
                    settings: sidecar.decode,
                    previewLongEdge: edge,
                    engineVersion: diagnostics.engineVersion ?? "unknown"
                )
                diskWrite = (cacheKey, tex.rgba16Bytes(), tex.width, tex.height,
                             Int(d.pixelSize.width.rounded()),
                             Int(d.pixelSize.height.rounded()), clock.totalMs())
            }
        }
        // Native original is deferred until evidence says it is useful: this
        // idle trigger is the baseline against which compare and zoom fires
        // are measured. The texture and clamp remain exactly the old path.
        requestNativeOriginal(trigger: "idle_delay")
        if let diskCache, let diskWrite {
            try? await diskCache.store(
                key: diskWrite.key,
                data: diskWrite.data,
                width: diskWrite.width,
                height: diskWrite.height,
                sourceWidth: diskWrite.sourceWidth,
                sourceHeight: diskWrite.sourceHeight,
                format: "rgba16Unorm",
                costMs: diskWrite.costMs
            )
        }
        guard wantsDevelop else {
            clock.lap("decode-only")
            canvasLog(clock.summary()
                      + "  ·  \(url.lastPathComponent) on the canvas as the decode"
                      + " — no develop until it is asked for")
            noteOpen(clock, url: url, mode: "decode", pixels: d.pixelSize)
            // A frame whose print is still resident comes back showing it —
            // that cache is what makes switching frames instant — and calling
            // that "decoded" would be describing a picture the user is not
            // looking at.
            status = renderer.store.print(for: url) == nil
                ? "\(url.lastPathComponent)  ·  decoded — press Solve to develop it."
                : "\(url.lastPathComponent)  ·  showing its last print."
            return
        }
        // Handed the clock so the develop continues the same line: the decode
        // and the preview it lapped are the first half of *this* open, and a
        // summary that starts at `frame` would hide them.
        await ensureDeveloped(clock: clock)
    }

    /// The develop: the *linear* decode rendered for the engine, the engine's
    /// session for the frame, and the print that replaces the decode on the
    /// canvas. The display decode on the canvas plays no part in it.
    ///
    /// This is the slow half of the open path and it is deliberately not on
    /// it.
    @discardableResult
    private func develop(_ url: URL, _ d: DecodedImage, clock: LoadClock) async -> String? {
        await openInService(d, for: url, clock: clock)
    }

    /// Resolve the linear decode on demand.
    ///
    /// A display-cache open deliberately stops with `decoded == nil`. The
    /// first operation that needs scene-linear pixels — develop, white-balance
    /// sampling, neutral picking, export — comes through here and turns the
    /// preview-only landing into a real decode.
    func ensureDecoded() async -> DecodedImage? {
        guard let url = selection else { return nil }

        while true {
            if !decodeIsStale, decodeResidency.key?.url == url, let image = decoded {
                return image
            }
            guard let load = loadTask else { break }
            await load.value
            guard selection == url else { return nil }
            if !decodeIsStale, decodeResidency.key?.url == url, let image = decoded {
                return image
            }
            // If a newer reopen replaced this task, await that one too. If
            // this is still the newest task, it completed as a display-only
            // load or failed; either way, stop waiting and try a linear decode.
            if loadTask != load { continue }
            break
        }

        let generation = pipeline.supersede()
        let task = Task { await load(url, generation: generation, requiresDecode: true) }
        loadTask = task
        await task.value
        guard selection == url, !decodeIsStale,
              decodeResidency.key?.url == url else { return nil }
        return decoded
    }

    /// The develop, as something every caller can await.
    ///
    /// Two callers must not develop the same frame twice, and the second one is
    /// not rare — Solve pressed while the decode is still landing, an export
    /// started the moment a frame was picked. So this waits for a decode that
    /// has not landed yet and joins a develop already in flight, rather than
    /// starting another. Returns the engine's session id, or nil if the frame
    /// did not land.
    @discardableResult
    func ensureDeveloped(clock: LoadClock = LoadClock()) async -> String? {
        // `load` is what produces a decodable frame, so waiting for it is what
        // makes Solve during an open mean the same thing as Solve a moment
        // later. It is a no-op once the frame is on the canvas, and `load`'s
        // own tail comes back through here with the decode already in hand, so
        // the two cannot wait on each other.
        //
        // A *stale* decode is the other half of that wait. `decoded` is still
        // the frame the reopen is replacing, so developing now would open the
        // engine on the old white balance — and `load`'s tail would then come
        // back through here, find that session waiting, and keep it.
        //
        // Waiting once is not enough: a drag on the Kelvin slider supersedes
        // one load with another, and the load this call first waited on is
        // then cancelled with the frame still stale. Giving up there is what
        // made Solve, Export and a slider release do *nothing* while the drag
        // was settling, so the loop follows to whichever load is newest and
        // waits for that one instead. It terminates because a load is only
        // superseded by a newer load — which this then waits on — and every
        // iteration awaits a task that is already cancelled or will finish.
        guard await ensureDecoded() != nil else { return nil }
        if let sid = serviceSessionID { return sid }
        if let task = developTask { return await task.value }
        guard let url = selection, let d = decoded else { return nil }
        // The open's clock when there is one (see `openClock`): a develop
        // joining an open in flight continues that path's record.
        let clock = openClock ?? clock
        let task = Task { [weak self] in await self?.develop(url, d, clock: clock) }
        developTask = task
        let sid = await task.value
        developTask = nil
        return sid
    }

    /// Ask for the print of the frame on screen.
    ///
    /// Two cases, and the difference between them is the shape of the open
    /// path: the engine already holds the frame, so the delta goes to the
    /// scheduler; or it does not, and this *is* the request to develop.
    /// Everything that wants a picture rather than a decode comes through
    /// here — a parameter edit, an undo, a paste, an export, a capture.
    func requestPrint() {
        wantsDevelop = true
        resolveFilmEdge()
        // A film edge changes which frame the engine holds (the decode cut by
        // the crop), and that is an open, not a delta.
        if serviceSessionID != nil, engineFraming != wantedEngineFraming { releaseEngineFrame() }
        guard serviceSessionID == nil else { scheduler.request(params); return }
        Task { await ensureDeveloped() }
    }

    /// The warm-up gate, not a race (RFC-013 §2.2). Costs nothing once boot has
    /// been paid, and on the path that matters — a frame restored at launch
    /// submitting `open` before `capabilities` has landed — it is the
    /// difference between the user's first frame paying the interpreter start
    /// and it having been paid already.
    ///
    /// **It also settles `diagnostics.engineVersion`, which every disk-cache
    /// key is built from.** That is why the gate is now at the top of `load`
    /// and not only here. `warmUp` publishes the version from a detached task,
    /// so before it lands `engineVersion` is nil and a key is built from the
    /// literal `"unknown"` — a key nothing was ever stored under, and one that
    /// a later *write* would never reuse. Every lookup in that window missed,
    /// and the open silently paid for a decode it had already cached. The
    /// suite saw this as `SessionDisplayCacheTests` failing only when enough
    /// earlier tests had warmed the engine to make `capabilities` return
    /// before the lookup rather than after it.
    private func awaitBoot(_ clock: LoadClock?) async {
        guard let boot = bootTask else { return }
        await boot.value
        bootTask = nil
        clock?.lap("warm-up")
    }

    private func openInService(_ d: DecodedImage, for url: URL, clock: LoadClock) async -> String? {
        let clock = clock
        await awaitBoot(clock)
        if serviceBlocked != nil { status = serviceBlocked!; return nil }
        // §11.5, before the engine takes the frame on: what this is expected to
        // cost, measured against what is free. A forecast that does not fit is
        // said out loud in the window and written down either way — the app may
        // not sail into a swap storm silently.
        resolveFilmEdge()
        noteProjection(pixels: developForecastPixels(d.pixelSize), operation: "develop")
        // Overscan renders whole-frame only (the striped executor refuses
        // it), so a film too wide for one texture is refused here, in words,
        // before the engine is asked.
        if let tooLarge = filmEdgeRefusal(d.pixelSize) {
            noteFailure(tooLarge, operation: "develop", frame: url.lastPathComponent,
                        pixels: developForecastPixels(d.pixelSize))
            return nil
        }
        status = "Developing…"
        // Preserved rather than cleared: Solve sets it around the develop *and*
        // the solve that follows, and clearing it here would open a window in
        // which the button looks ready while the engine is still working.
        // Counted, not saved-and-restored per call: a develop that starts while
        // a cancelled one is still unwinding saw `busy` already true, and the
        // two restores then left it true for good -- the clock counted with
        // the engine idle (a pair with Film Edge switched on, 2026-10-03).
        if openDepth == 0 { busyBeforeOpen = busy }
        openDepth += 1
        busy = true
        startClock()
        defer {
            openDepth -= 1
            if openDepth == 0 { busy = busyBeforeOpen }
        }
        do {
            let r: OpenResponse
            var framing: String?
            // What the open actually carries. The scheduler is reset to *this*,
            // not to the sidecar after the await: an edit made while the engine
            // was being handed the frame is not on the engine, and recording it
            // as sent is how a paste showed the new film over the old print
            // (RFC-027 §5.1). The `request` at the end of the develop sends it.
            var opened = sidecar.params
            do {
                // Its own scope, so the 727 MB buffer is gone before the solve
                // and the first render run — at -Onone too, where a value is
                // otherwise kept to the end of the function. The engine keeps
                // nothing of it (`spk_open_device` borrows for the call).
                let device = renderer.device
                // A pair: each hole exposed as the meter would expose it alone.
                let stops = await pairExposure(d, for: url)
                let layout = pairLayout(for: d.pixelSize)
                guard selection == url, !Task.isCancelled else { return nil }
                let cut = filmEdgeCut
                framing = wantedEngineFraming
                let frame = try await Task.detached(priority: .userInitiated) {
                    var image = Session.engineImage(d.linear, size: d.pixelSize, cut: cut)
                    if let stops, let layout { image = PairComposer.exposed(image, layout: layout, stops: stops) }
                    return try ImageDecoder.engineFrame(from: image, device: device)
                }.value
                clock.lap("frame")
                guard selection == url, !Task.isCancelled else { return nil }
                opened = sidecar.params
                let delta = Self.openDelta(sidecar: sidecar, previewLongEdge: previewLongEdge)
                afterOpenDeltaForTesting?()
                r = try await client.open(frame, paramsDelta: delta)
            }
            // The client holds one session; open replaces it. The handle follows
            // the session, not the develop, so an open only ever replaces this
            // accounted residency and a rejected develop leaves it intact.
            releaseEngineAccounting()
            engineArenaHandle = diagnostics.arena.registerPinned(bytes: Self.engineArenaEstimateBytes,
                                                                  kind: "engine")
            clock.lap("engine.open")
            sampleMemory("engine.open")
            // `open` echoes the whole block, so the check happens here too:
            // a service can be restarted under a running app.
            if let caps = r.capabilities {
                accept(caps)
                if let why = serviceBlocked { status = why; return nil }
            }
            guard selection == url, !Task.isCancelled else { return nil }
            serviceReady = true
            serviceSessionID = r.sessionID
            engineFraming = framing
            // Before the first render can reach the canvas, so nothing is ever
            // drawn in a space the layer cannot show. §5.1: the space comes
            // from the reply, because an explicit `io.output_color_space` in a
            // delta overrides the convention and this is the only place the
            // app can find out which one it got.
            noteWorkingSpace(r.params["output_color_space"]?.stringValue
                             ?? Self.defaultWorkingSpace)
            serviceGeneration = scheduler.reset(sessionID: r.sessionID, params: opened)
            // What the engine's own auto-exposure chose for this frame. The
            // Exp. Comp. slider is an offset from it, so the UI has to know
            // the baseline to show it (HANDOFF §4). `solve(target:"exposure")`
            // measures and reports without touching the session, so it belongs
            // here; the filter pack is `solveNow`'s half, because it is what
            // the Solve pill means.
            if let solved = try? await client.call(.solve, SolveRequest(sessionID: r.sessionID, target: "exposure"), as: SolveResponse.self),
               let ev = solved.solvedParams["exposure_compensation_ev"] {
                sidecar.solvedEV = ev
                // And what the *other* three intents would have chosen, from
                // the same sample. Kept for the Tone pill: switching intent is
                // a shoot-layer edit, so the label would otherwise be a film
                // render behind (RFC-015 §3).
                exposureEvByMethod = solved.exposureEvByMethod
                scheduleSave()
            }
            clock.lap("solve")
            let rr = try await client.render(.reprint, RenderRequest(sessionID: r.sessionID))
            clock.lap("reprint")
            canvasLog(clock.summary()
                      + (warmUpMs.map { "  ·  warm_up \(Int($0)) ms" } ?? "")
                      + "  ·  core=\(renderCore ?? "?")"
                      + (backend?.sessionCache.map { "  ·  \($0.summary)" } ?? ""))
            guard selection == url else { return nil }
            applyRender(rr, generation: serviceGeneration)
            noteOpen(clock, url: url, mode: "develop",
                     pixels: CGSize(width: r.meta.width, height: r.meta.height))
            // What the status line names is the working space and the space on
            // screen. It used to name the *input* space — a third thing again,
            // so the bar read "ProPhoto RGB" under a Display P3 picture
            // (RFC-018 §4.1). `detectedInput` still carries the input space
            // for anyone who asks; it is just no longer presented as either of
            // the two this line is about.
            statusBase = "\(url.lastPathComponent)  ·  \(r.meta.width)×\(r.meta.height)  ·  \(colourSummary)"
            if let b = backend, b.isSlowPath {
                // Loud, because the symptom is otherwise just "slow" and the
                // cause is usually that the engine is not in this checkout.
                stockWarning = "Rendering on the \(b.label) path, not the GPU core — see HANDOFF-GPU-WIRING.md."
            }
            status = "\(statusBase!)  ·  \(rr.response.reprint ? "reprint" : "render") \(Int(rr.response.elapsedMs)) ms"
            // The user may have moved a slider while the film side was running.
            scheduler.request(sidecar.params)
            return r.sessionID
        } catch {
            noteFailure(error, operation: "develop", frame: url.lastPathComponent,
                        pixels: Int(d.pixelSize.width * d.pixelSize.height))
            // The status line keeps the *raw* text here, as it did before the
            // record existed: this is the one place a developer watching the
            // window wants the engine's own words, and `noteFailure` has
            // already put the user-facing sentence in `lastError`.
            status = "\(error)"
            if case EngineClient.ClientError.noResources = error { serviceReady = false }
            return nil
        }
    }

    // MARK: - colour

    /// What the status line says about colour: **one space**, the one the
    /// picture is in and the one the canvas is tagged with.
    ///
    /// It used to read `ProPhoto RGB → Display P3`, and before that it named
    /// the *input* space under a picture in another one (RFC-018 §4.1). Neither
    /// is true now: ColorSync converts the tagged canvas for whatever display
    /// this is, so there is no second space for the app to name — and the user
    /// asked for less of this in the interface rather than more ("there's not
    /// much need to actually explaining that much, right?").
    private var colourSummary: String { workingSpaceName }

    /// Record the space the engine resolved for this session.
    ///
    /// Nothing is installed and nothing is fetched: the canvas draws this space
    /// and is tagged with it, and the engine's colour numbers are fetched only
    /// when an export or a proof actually needs to convert to a destination
    /// (`ColourManagement`, from `Exporter` and `SoftProof`).
    private func noteWorkingSpace(_ source: String) {
        workingSpaceName = source
        log.info(.engine, "working_space", [.init("space", source)])
    }

    private func applyRender(_ outcome: RenderOutcome, generation: Int, composed: Bool = false) {
        // A pair's print is cut together from its frames' own prints first
        // (`composePairRender`), and comes back here as `composed`.
        if pair != nil, !composed {
            pairLastRender = (outcome, generation)
            if pairIsLayered {
                Task { await composePairRender(outcome, generation: generation) }
                return
            }
            // One print for the whole piece: nothing to cut together.
            pairShowsComposite = false
        }
        rendersLanded += 1
        let r = outcome.response
        guard generation == serviceGeneration else {
            noteRenderOutcome(r, generation: generation, outcome: "superseded")
            canvasLog("applyRender dropped: generation \(generation) != \(serviceGeneration)"); return
        }
        guard let url = selection else { canvasLog("applyRender dropped: no selection"); return }
        guard let tex = outcome.texture, let w = r.width, let h = r.height else {
            noteRenderOutcome(r, generation: generation, outcome: "no_pixels")
            canvasLog("applyRender dropped: the engine returned no texture"); return
        }
        noteRenderOutcome(r, generation: generation, outcome: "applied")
        canvasLog("applyRender uploaded \(w)x\(h)")
        // Before the store takes it: whether this is the frame's first print
        // decides whether it is a memory boundary (§3).
        let firstPrint = renderer.store.print(for: url) == nil
        let sourceSize = decoded?.pixelSize
        let printKey = Self.printCacheKey(
            url: url, params: scheduler.sent, tier: .live,
            previewLongEdge: previewLongEdge,
            engineVersion: diagnostics.engineVersion ?? "unknown"
        )
        renderer.store.setPrint(
            tex, stamp: Self.printStamp(scheduler.sent), for: url,
            costMs: r.elapsedMs + (openClock?.setupMs ?? 0),
            cacheKey: printKey,
            sourceWidth: sourceSize.map { Int($0.width.rounded()) },
            sourceHeight: sourceSize.map { Int($0.height.rounded()) }
        )
        // The frame's own size, and only when it is known: passing nil leaves
        // whatever the decode established (D4).
        renderer.setLive(tex, logical: scheduler.sent.cutsFrame
                         ? filmCanvasLogicalSize(for: tex, frame: nativeSourceSize) : nativeSourceSize)
        filmCanvasOn = scheduler.sent.cutsFrame ? url : nil
        // This print is at the **preview resolution**. For a frame bigger than
        // that it is interpolated at 100 %, so it is not the finished picture
        // yet — the native render that follows is, and this flag is what says
        // so. It is also what the export harness waits on, which is the other
        // reason it must not clear until the native render lands.
        previewSoft = wantsFullRender
        lastRenderMs = r.elapsedMs
        if pair != nil { refreshPairGates(); placementLanded() }
        if let base = statusBase { status = "\(base)  ·  \(r.reprint ? "reprint" : "render") \(Int(r.elapsedMs)) ms" }
        frameStates[url] = .processed
        sidecar.state = .processed
        scheduleSave()
        updateThumbnail(url, from: tex)
        scheduleLatitudeRefresh()
        resolvePendingPlacement()
        if firstPrint { sampleMemory("first_print") }
        // The native render is the next step. A resident one made from
        // *different* parameters is no longer the print on screen, and showing
        // it would be showing a different film; one made from these parameters
        // is still the truth, so an undo — or a slider dragged back to where
        // it started — shows it again instead of re-rendering.
        if !wantsFullRender {
            // Nothing a native render could add: after the crop the frame is
            // no bigger than the preview resolution, so what is on the canvas
            // already is the frame's own pixels.
            fullTask?.cancel(); fullTask = nil
            fullPending = false
            renderer.dropFullRender()
            renderer.store.dropFullRender()
            previewSoft = false
        } else if let resident = renderer.store.fullRender(for: url, stamp: printStamp) {
            fullTask?.cancel(); fullTask = nil
            fullPending = false
            renderer.setFullRender(resident)
            previewSoft = false
        } else {
            renderer.dropFullRender()
            renderer.store.dropFullRender()
            scheduleFullRender()
        }
    }

    /// The app's half of §3 `render`. The engine's record says what a render
    /// cost (`EngineClient.noteRender`); this one says what became of it —
    /// applied, superseded, or dropped because the engine returned no pixels —
    /// and which generation it belonged to.
    ///
    /// `debug`, because it answers a second question ("did the render I am
    /// looking at actually land?"), asked while diagnosing rather than in
    /// general. The `info` record is the one that is always exactly one per
    /// render; a superseded render has no `applied` line beside it, which is
    /// itself the answer.
    private func noteRenderOutcome(_ r: RenderResponse, generation: Int, outcome: String) {
        log.debug(.render, "outcome", [
            .init("outcome", outcome),
            .init("generation", generation),
            .init("service_generation", serviceGeneration),
            .init("renders_landed", rendersLanded),
            .init("tier", r.tier),
            .init("px", (r.width ?? 0) * (r.height ?? 0)),
            .init("ms", r.elapsedMs),
            .init("frame", selection?.lastPathComponent ?? "-"),
        ])
    }

    private func markStale() {
        guard let url = selection, frameStates[url] == .processed else { return }
        // The service will catch up within a reprint; only the *thumbnail*
        // goes stale, and it clears when the next render lands.
        frameStates[url] = .stale
    }

    private func updateThumbnail(_ url: URL, from tex: MTLTexture) {
        let maxEdge = 320
        let long = max(tex.width, tex.height)
        var source: MTLTexture
        if long > maxEdge {
            let scale = Double(maxEdge) / Double(long)
            let w = max(1, Int((Double(tex.width) * scale).rounded()))
            let h = max(1, Int((Double(tex.height) * scale).rounded()))
            guard let small = renderer.applyResize(tex, width: w, height: h) else { return }
            source = small
        } else {
            source = tex
        }
        // RFC-028: a DI's texture holds Cineon codes. The thumbnail and the
        // Navigator show what the canvas shows, through the same table.
        if digitalIntermediateActive {
            var viewOnly = Layer2Uniforms(); viewOnly.enabled = 0
            if let decoded = renderer.applyLayer2(to: source, uniforms: viewOnly) { source = decoded }
        }
        let box = TextureBox(source)
        Task.detached(priority: .utility) {
            guard let cg = box.texture?.makeCGImage() else { return }
            let s = Double(maxEdge) / Double(max(cg.width, cg.height))
            let w = max(1, Int(Double(cg.width) * s)), h = max(1, Int(Double(cg.height) * s))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ImageDecoder.displayP3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let small = ctx.makeImage() { ThumbnailCache.shared.store(small, for: url) }
            await MainActor.run { NotificationCenter.default.post(name: .thumbnailUpdated, object: url) }
        }
    }

    // MARK: - the retired decode cache

    /// Where the linear-TIFF handoff cache used to live.
    nonisolated static var legacyLinearCache: URL { cacheRoot.appending(path: "linear") }

    /// Delete what the linear-TIFF cache left behind.
    ///
    /// The cache existed because the engine once lived in another process and
    /// took a file. Since RFC-014 it has taken pixels, so every entry was a
    /// file this process wrote only to read back, at 6.4–7.1 s per 45 MP
    /// frame; the frame now goes to the engine straight from the decode, and
    /// nothing reads these files. They were up to 4 GB (a 4 GB LRU, 363 MB an
    /// entry), which is the user's disk, not ours to keep. Off the main
    /// thread, and quiet on failure: a directory that is already gone is the
    /// normal case after the first launch.
    /// Re-read what the store holds. Called by the Settings page on the timer
    /// it already runs; nothing else needs the number.
    func refreshDiskCacheUsage() {
        guard let diskCache else { return }
        Task { [weak self] in
            let bytes = (try? await diskCache.totalBytes()) ?? 0
            await MainActor.run { self?.diskCacheBytes = bytes }
        }
    }

    /// Empty it. Everything here can be remade from the original files, which
    /// is why this needs no confirmation and why the caption says so.
    func clearDiskCacheNow() {
        guard let diskCache else { return }
        Task { [weak self] in
            try? await diskCache.clearAll()
            let bytes = (try? await diskCache.totalBytes()) ?? 0
            await MainActor.run { self?.diskCacheBytes = bytes }
        }
    }

    nonisolated static func removeLegacyLinearCache() {
        let dir = legacyLinearCache
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Drop the engine's frame and keep the decode: the next request opens
    /// the engine again on the frame as it now has to be cut (a film edge
    /// switched, or its framing moved). `scheduleReopen` without the decode.
    func releaseEngineFrame() {
        developTask?.cancel(); developTask = nil
        scheduler.invalidate()
        releaseEngineAccounting()
        serviceSessionID = nil
        engineFraming = nil
        fullPending = false
        fullTask?.cancel(); fullTask = nil
        fullGeneration += 1
        renderer.dropFullRender()
        renderer.store.dropFullRender()
    }

    /// The canvas's own grade: the frame's, or none for a pair (its picture
    /// is already graded frame by frame).
    private func pushLayer2(_ adjustments: Adjustments) {
        let shown = pairIsLayered ? Adjustments() : adjustments
        renderer.layer2 = shown.uniforms
        renderer.setCurves(shown.curves)
    }

    /// Whether the piece on the canvas is of an older pair than the one written.
    var pairDecodeIsStale: Bool { decodeIsStale }

    /// `scheduleReopen` for the pair's own writes (`updatePair`).
    func schedulePairReopen() { scheduleReopen() }

    /// The frame a filmstrip drag is carrying, from the moment it leaves its
    /// cell. The window's own file drop reads it: a thumbnail let go over the
    /// window is not a file handed to the app, and must not open as one.
    var draggedFrame: URL? {
        get { draggedFrameBox }
        set { draggedFrameBox = newValue }
    }

    /// Move `id` to where `target` is in the filmstrip: before it when moving
    /// left, after it when moving right — the dragged cell takes the place of
    /// the cell it is over, as the strip shows it while the drag is in flight.
    func moveFrame(_ id: URL, onto target: URL) {
        guard id != target, !batchExporting,
              let from = frames.firstIndex(where: { $0.id == id }),
              let to = frames.firstIndex(where: { $0.id == target }) else { return }
        let frame = frames.remove(at: from)
        frames.insert(frame, at: to)
    }

    /// The drag ended on the strip: its order is the folder's from now on.
    func frameOrderChanged() {
        draggedFrame = nil
        FrameOrder.save(frames.map(\.id))
    }

    /// Files let go over the window. Dropped from outside they are opened, as
    /// ever — one file is "edit this". A frame of the open set is not opened
    /// again (that replaced the whole folder with the one frame): the strip's
    /// own thumbnail is ignored, and the same file from Finder goes on the
    /// canvas with its folder still around it.
    func dropped(files urls: [URL]) {
        let own = draggedFrame
        draggedFrame = nil
        guard !urls.isEmpty else { return }
        let listed = Set(frames.map { $0.id.standardizedFileURL })
        let known = urls.filter { listed.contains($0.standardizedFileURL) }
        guard known.count == urls.count else { open(urls: urls); return }
        if let own, urls.count == 1, urls[0].standardizedFileURL == own.standardizedFileURL { return }
        if urls.count == 1, let frame = frames.first(where: { $0.id.standardizedFileURL == urls[0].standardizedFileURL }) {
            click(frame.id)
        }
    }

    /// Put a new item in the filmstrip (a pair made in this session).
    func insertFrame(_ frame: Frame, at index: Int) {
        guard !frames.contains(where: { $0.id == frame.id }) else { return }
        frames.insert(frame, at: min(max(index, 0), frames.count))
        frameStates[frame.id] = .stale
    }

    private func scheduleReopen() {
        reopenTask?.cancel()
        reopenTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let url = selection else { return }
            loadTask?.cancel()
            // A develop of the *previous* decode is not the develop of this
            // one: it would open the engine on a TIFF that is already
            // superseded. `wantsDevelop` is left alone, so a frame that was
            // never developed is re-decoded and nothing more.
            developTask?.cancel(); developTask = nil
            renderer.store.invalidatePrint(for: url)
            previewSoft = true
            // The four intents' EVs belong to the decode being replaced, so
            // they go with it: the label would otherwise be quoting the old
            // exposure while the new decode is on its way. The develop that
            // follows is what refills them.
            exposureEvByMethod = nil
            // The engine keeps the frame the *previous* decode made, and it
            // has no idea a decode happened after it. Without this, `load`'s
            // tail would find that session already there, decide the frame was
            // developed, and reprint from the old decode — a white-balance
            // change that changes nothing the user can see. Dropping the
            // session is what `select` and `unloadSelection` do on a frame change;
            // a re-decode is a frame change as far as the engine is concerned
            // (RFC-015 §1.1).
            scheduler.invalidate()
            releaseEngineAccounting()
        serviceSessionID = nil
        engineFraming = nil
            // The native render is made from the engine's frame too, so it
            // would otherwise keep the old white balance. Both copies have to
            // go: the renderer's is the one on screen now, and the store's is
            // the one `applyRender` would find and show again.
            //
            // The store's copy is the subtle one. The slot is stamped with
            // `printStamp`, which is the *film* params — a white balance is a
            // decode setting and does not appear in it, so the resident render
            // still matches its own stamp and the cache serves it back as if
            // it were current, which puts the old colour on screen.
            fullPending = false
            fullTask?.cancel(); fullTask = nil
            fullGeneration += 1
            renderer.dropFullRender()
            renderer.store.dropFullRender()
            cancelNativeOriginal()
            decodedGeneration = 0
            // `decoded` is still the frame the user has just changed *away*
            // from, and it stays there until the new decode lands — the panel
            // reads it (`setWhiteBalance`, `pickNeutral`) and clearing it
            // would blank and refill the white-balance controls on every drag.
            // So the develop is told instead: until the new decode is in hand,
            // a develop would open the engine on the old frame, and `load`'s
            // tail would then keep that session as if it were the new one.
            decodeIsStale = true
            let gen = pipeline.supersede()
            loadTask = Task { await load(url, generation: gen) }
        }
    }

    // MARK: - sidecar

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let url = selection else { return }
        try? sidecar.save(for: url)
        savedGeometry[url] = sidecar.geometry
        if sidecar.params.cutsFrame { filmEdgeThumbnails.insert(url) } else { filmEdgeThumbnails.remove(url) }
    }

    // MARK: - white balance

    /// The camera's own white balance for the frame on screen, or nil until a
    /// decode has landed. Ticking an "As Shot" box means pinning to these, so
    /// with nothing to pin to the boxes are disabled (`WhiteBalanceBoxes`).
    var asShotWhiteBalance: WhiteBalanceBoxes.AsShot? {
        guard let d = decoded, let t = d.asShotTemperature, let tn = d.asShotTint else { return nil }
        return (t, tn)
    }

    /// What the two "As Shot" boxes read right now.
    var whiteBalanceBoxes: WhiteBalanceBoxes {
        WhiteBalanceBoxes(decode, asShot: asShotWhiteBalance)
    }

    func setTempAsShot(_ on: Bool) {
        decode = whiteBalanceBoxes.applying(temp: on, tint: nil, to: decode, asShot: asShotWhiteBalance)
    }

    func setTintAsShot(_ on: Bool) {
        decode = whiteBalanceBoxes.applying(temp: nil, tint: on, to: decode, asShot: asShotWhiteBalance)
    }

    /// Dragging the temperature slider. The axis is no longer the camera's, so
    /// the decode becomes `.custom` at the value shown — and whether the
    /// "As Shot" box then reads ticked is `WhiteBalanceBoxes`' question, not
    /// this one's: dragging onto the camera's own value is the same picture as
    /// `.asShot` and reads the same way.
    func setTemperature(_ kelvin: Double) {
        var d = decode
        d.temperature = kelvin
        d.whiteBalance = .custom
        decode = d
    }

    func setTint(_ tint: Double) {
        var d = decode
        d.tint = tint
        d.whiteBalance = .custom
        decode = d
    }

    func setWhiteBalance(_ mode: DecodeSettings.WhiteBalance) {
        var d = decode
        d.whiteBalance = mode
        if let k = mode.kelvin { d.temperature = k; d.tint = 0 }
        else if mode == .asShot, let dec = decoded, let t = dec.asShotTemperature, let tn = dec.asShotTint { d.temperature = t; d.tint = tn }
        decode = d
    }

    func pickNeutral(at n: CGPoint) {
        // The point is on the film canvas, not on the photograph, while a
        // film edge is shown; where the picture sits in it is the engine's
        // to say (`spk_overscan_geometry`), so the picker does not guess.
        guard let url = selection, !filmEdgeShowsFilm else { return }
        Task {
            guard let dec = await ensureDecoded(), dec.isRAW else { return }
            let result = await Task.detached(priority: .userInitiated) {
                ImageDecoder.neutral(at: n, in: url)
            }.value
            guard let r = result, selection == url else { return }
            var d = decode
            d.whiteBalance = .custom; d.temperature = r.temperature; d.tint = r.tint
            decode = d
        }
    }

    // MARK: - CanvasHost

    func viewportChanged() {
        viewportSnapshot = renderer.viewport
        // Every re-pivot compensates the viewport, so this funnel is where
        // the mirror catches up: the two cannot disagree while both are read
        // from the renderer at the same moment.
        cropPivot = renderer.cropPivot
        guard renderer.base != nil else { zoomPercent = 0; isFit = true; return }
        zoomPercent = renderer.viewport.zoomPercent
        if croppedLongEdge > 0 {
            // The zoom at which the drawn frame outgrows the preview tier's
            // texture. The trigger is the crossing, not the state: a pan,
            // resize or magnify while already past it must not ask again.
            let threshold = 100 * Double(previewLongEdge) / Double(croppedLongEdge)
            let pastPreview = wantsFullRender && Double(zoomPercent) > threshold
            if pastPreview && !wasPastPreview {
                requestNativeOriginal(trigger: "zoom_past_preview")
            }
            wasPastPreview = pastPreview
        } else {
            wasPastPreview = false
        }
        // While the crop tool is up the view is fitted to the whole
        // photograph rather than to the frame, so its scale is no longer
        // `fitScale` — but it is fitted, and the pill should say so.
        isFit = renderer.viewport.isFit || renderer.editingCrop
    }
    func picked(normalised n: CGPoint) {
        if wbPickerActive { wbPickerActive = false; pickNeutral(at: n) }
        else if curvePickerActive { curvePickerActive = false; addCurvePoint(at: n) }
        else if let id = maskColorPick { maskColorPick = nil; pickMaskColor(id, at: n) }
    }

    /// Sample the print under the cursor into a colour-range component. Read
    /// from the *base* texture — the print before Layer 2 — because that is
    /// what the shader's coverage test compares against.
    private func pickMaskColor(_ component: UUID, at n: CGPoint) {
        guard let base = renderer.base, let rgb = Session.sample(base, at: n),
              var m = selectedMask, let i = m.components.firstIndex(where: { $0.id == component }) else { return }
        m.components[i].color = SIMD3<Double>(Double(rgb.x), Double(rgb.y), Double(rgb.z))
        selectedMask = m
    }
    /// Pick a paper. The one place print stock is chosen, so the fast flip
    /// has one place to hook into.
    ///
    /// The preview is started **before** the parameter is set, and that
    /// ordering is the whole of why it is fast: `EngineClient` is an actor,
    /// so a table lookup queued behind the reprint the setter schedules
    /// would arrive after the thing it was meant to precede.
    /// Whether the chosen film is a reversal (slide) stock — Provia, Velvia,
    /// Ektachrome, Kodachrome.
    ///
    /// A positive is already a viewable image, so the paper stage has nothing
    /// to interpret: the print list greys out and the frame is scanned rather
    /// than printed. The catalogue has carried `type` since it was generated
    /// and nothing read it until now.
    var filmIsPositive: Bool { catalog.stock(params.filmStock)?.isPositive ?? false }

    /// RFC-028: whether this frame renders as a Digital Intermediate.
    var digitalIntermediateActive: Bool {
        params.digitalIntermediateActive(filmIsPositive: filmIsPositive)
    }

    /// Whether `texture` holds Cineon codes: a question about the print it
    /// is, not about the settings. The settings move before a print does and
    /// stay moved if the print fails, and the canvas goes on showing the one
    /// it has — so a print of this frame answers from the parameters it was
    /// made with (its stamp in the store), the decode and a paper preview are
    /// never a DI, and anything else is a render just made from the settings
    /// (an export's own).
    func isDigitalIntermediate(_ texture: MTLTexture) -> Bool {
        if let url = selection {
            let stamp: String?
            if let full = renderer.store.fullEntry(for: url), full.texture === texture { stamp = full.stamp }
            else if let print = renderer.store.printEntry(for: url), print.texture === texture { stamp = print.stamp }
            else { stamp = nil }
            if let stamp {
                let answer = Self.stampIsDigitalIntermediate(stamp, catalog: catalog)
                knownPrints.setObject(NSNumber(value: answer), forKey: texture)
                return answer
            }
        }
        // A print the store has let go of while the canvas still shows it.
        if let known = knownPrints.object(forKey: texture) { return known.boolValue }
        if texture === renderer.live || texture === renderer.fullRender { return false }
        return digitalIntermediateActive
    }

    /// `FilmParams.digitalIntermediateActive`, read back off a print's stamp.
    nonisolated static func stampIsDigitalIntermediate(_ stamp: String, catalog: StockCatalog) -> Bool {
        var fields: [Substring: Substring] = [:]
        for field in stamp.split(separator: ";") {
            guard let eq = field.firstIndex(of: "=") else { continue }
            fields[field[..<eq]] = field[field.index(after: eq)...]
        }
        guard fields["digital_intermediate"] == "true", fields["scan_film"] != "true" else { return false }
        return !(catalog.stock(String(fields["film_stock"] ?? ""))?.isPositive ?? false)
    }

    /// Choose the Digital Intermediate in the print list. Like "No Print
    /// Profile" it leaves the paper where it was, so choosing a paper again
    /// comes back to it.
    func selectDigitalIntermediate() {
        guard !filmIsPositive else { return }
        var p = params
        p.digitalIntermediate = true
        p.scanFilm = false
        params = p
    }

    /// Settings ▸ Rendering: the DI's optional blue-sector compensation. An
    /// app setting (`FilmParams.diBlueCompensation`), so the open frame is
    /// pushed and reprinted here; every other frame reads it at open.
    var diBlueCompensation: Bool {
        get { FilmParams.diBlueCompensation }
        set {
            guard newValue != FilmParams.diBlueCompensation else { return }
            UserDefaults.standard.set(newValue, forKey: FilmParams.diBlueCompensationKey)
            diBlueCompensationRevision += 1
            guard digitalIntermediateActive, let sid = serviceSessionID, selection != nil else { return }
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.client.call(.setParams,
                    SetParamsRequest(sessionID: sid,
                                     paramsDelta: ["digital_intermediate_blue_compensation": .bool(newValue)]),
                    as: SetParamsResponse.self)
                guard self.serviceSessionID == sid, self.selection != nil else { return }
                if let rr = try? await self.client.render(.reprint, RenderRequest(sessionID: sid)) {
                    self.applyRender(rr, generation: self.serviceGeneration)
                }
            }
        }
    }
    /// Observation hook for the Settings toggle; the value lives in defaults.
    private(set) var diBlueCompensationRevision = 0

    func selectPrintStock(_ stock: String) {
        // The one gate. `PrintProfileSection` greys the rows so the interface
        // says why, but the rule lives here so that a menu item, a sidecar or
        // a future caller cannot route around it.
        guard !filmIsPositive else { return }
        if fastStockPreview, printLUTStocks[stock] != nil { startStockPreview(stock) }
        var p = params
        p.printStock = stock
        p.scanFilm = false
        p.digitalIntermediate = false
        params = p
    }

    /// Choosing a film also follows its **declared** paper, unless the user
    /// has already made a pairing of their own. The film list's rule, here so
    /// the agent layer (RFC-026) chooses a film exactly as a click does.
    func selectFilmStock(_ id: String) {
        var p = params
        p.filmStock = id
        if let target = catalog.stock(id)?.targetPrint,
           catalog.stock(target) != nil,
           !catalog.isDeclaredPairing(film: p.filmStock, paper: p.printStock) {
            p.printStock = target
        }
        params = p
        // A slide film has no print stage. A positive declares no
        // `targetPrint`, so the branch above leaves `printStock` where it
        // was — which is the point: coming back to a negative restores the
        // paper rather than landing on a default.
        applyFilmStageRule()
    }

    /// Choosing a film decides whether there is a print stage at all.
    ///
    /// Called by the film list. A positive is scanned, and `printStock` is
    /// deliberately **left alone** while that is true: `scanFilm` is a
    /// separate field from the paper for exactly this reason, so going back
    /// to a negative restores the paper that was chosen before rather than
    /// landing on a default.
    func applyFilmStageRule() {
        guard filmIsPositive, !params.scanFilm else { return }
        var p = params; p.scanFilm = true; params = p
    }

    /// The Camera section's Tone pill: which exposure intent the engine meters
    /// with (RFC-015 §2.3).
    ///
    /// A shoot-layer edit, so it re-renders the negative — and the Exp. Comp.
    /// sublabel ("auto +x EV") is a *report* of what the meter chose, so it has
    /// to be the new intent's number the moment the pill moves rather than a
    /// film render later. `retargetSolvedEV` is that, and it is a separate
    /// method because the pill is not the only thing that can change the Tone:
    /// so can a paste, which replaces `params` whole.
    ///
    /// `params`' setter is what pushes undo, requests the print and schedules
    /// the save, so this must go through it rather than around it.
    // MARK: - AE Method, Film Exposure, Lens Correction and the physical frame
    //
    // The Camera and Film sections of the 2026-09-17 drawing, wired. Every one
    // of these goes through an **existing** schema field: `auto_exposure`,
    // `auto_exposure_method`, `exposure_compensation_ev`, `film_format_mm` on
    // the engine side, and `CIRAWFilter` on the decode side. No route and no
    // parameter was added for any of it.

    /// The AE Method pill: the four metering intents plus `Custom`, which is
    /// the meter switched off (`AEMethod`).
    var aeMethod: AEMethod {
        get {
            // On a pair: the picked frame's own meter.
            if let hole = focusHole {
                var p = FilmParams.default
                p.autoExposure = hole.autoExposure
                p.autoExposureMethod = hole.meterMethod ?? sidecar.params.autoExposureMethod
                return AEMethod.of(p)
            }
            return AEMethod.of(params)
        }
        set {
            guard newValue != aeMethod else { return }
            if let side = focusSide, pair != nil {
                var p = FilmParams.default
                p.autoExposureMethod = pair?[side]?.meterMethod ?? sidecar.params.autoExposureMethod
                newValue.apply(to: &p)
                updatePair(redecode: false) { $0[side]?.autoExposure = p.autoExposure; $0[side]?.meterMethod = p.autoExposureMethod }
                return
            }
            var p = params
            newValue.apply(to: &p)
            params = p
            retargetSolvedEV()
        }
    }

    /// The "As Shot" box under Film Exposure.
    ///
    /// It reads ticked when the frame is on the **linearized baseline**: the
    /// meter off and no compensation, which is the photograph exposed exactly
    /// as the camera recorded it. That is a *derived* state, like the two
    /// white-balance boxes beside it — it is ticked whenever the pair of
    /// values says so, not because a box was clicked.
    var filmExposureIsAsShot: Bool {
        if let hole = focusHole { return !hole.autoExposure && hole.exposureEV == 0 }
        return !params.autoExposure && params.exposureCompensationEV == 0
    }

    /// Ticking it: "+0.0 baseline (also `As Shot`, clicking this automatically
    /// switches AE method to custom)" — the PRD's own sentence, and both
    /// halves of it, because either one alone leaves the frame somewhere else.
    ///
    /// Unticking is deliberately a no-op. The box is a statement about two
    /// numbers, and "not the baseline" does not say *which* other exposure to
    /// go to; the way off it is to drag the slider or choose a method, which
    /// is also how the box came to be ticked.
    func setFilmExposureAsShot(_ on: Bool) {
        guard on, !filmExposureIsAsShot else { return }
        if let side = focusSide, pair != nil {
            updatePair(redecode: false) { $0[side]?.autoExposure = false; $0[side]?.exposureEV = 0 }
            return
        }
        var p = params
        p.autoExposure = false
        p.exposureCompensationEV = 0
        params = p
        retargetSolvedEV()
    }

    /// Whether the Lens Correction row can be used at all, and why not.
    ///
    /// The PRD's two rules, in the order it states them: only RAW can be
    /// corrected, and a RAW that does not carry the manufacturer's correction
    /// has nothing to switch — Core Image is already doing the standard thing
    /// from EXIF. Both come back as a greyed row rather than as a control that
    /// looks live and changes nothing.
    var lensCorrectionEnabled: Bool {
        guard let d = decoded else { return false }
        return d.isRAW && d.lensCorrectionSupported
    }

    var lensCorrectionReason: String {
        guard let d = decoded else { return "Open a frame to correct its lens." }
        if !d.isRAW { return "Lens correction applies to RAW input only." }
        if !d.lensCorrectionSupported {
            return "This RAW carries no lens correction. Core Image is already applying the standard EXIF correction."
        }
        return ""
    }

    func setLensCorrection(_ on: Bool) {
        var d = decode
        d.lensCorrection = on
        decode = d
    }

    // MARK: the physical frame

    var filmFrame: FilmFrame { FilmFrame.named(params.filmFrame) }
    var filmSide: FilmSide { FilmSide(rawValue: params.filmSide) ?? .short }

    func setFilmFrame(_ frame: FilmFrame) {
        var p = params
        p.filmFrame = frame.id
        // A preset **shows its own** side length; only Custom keeps the
        // user's. That is the PRD's "shows the actual Side length if
        // non-custom film type is selected".
        if frame.id != FilmFrame.custom.id {
            p.sideLengthMM = frame.side(filmSide)
        }
        p.filmFormatMM = derivedFilmFormatMM(side: filmSide, sideLengthMM: p.sideLengthMM)
        params = p
    }

    func setFilmSide(_ side: FilmSide) {
        var p = params
        p.filmSide = side.rawValue
        if p.filmFrame != FilmFrame.custom.id {
            p.sideLengthMM = FilmFrame.named(p.filmFrame).side(side)
        }
        p.filmFormatMM = derivedFilmFormatMM(side: side, sideLengthMM: p.sideLengthMM)
        params = p
    }

    /// Side Length, in millimetres. Only Custom may be typed into, which the
    /// view enforces by greying the field; this clamps anyway, because a
    /// number arriving from a pasted sidecar has not been through the view.
    func setSideLengthMM(_ mm: Double) {
        var p = params
        p.filmFrame = FilmFrame.custom.id
        p.sideLengthMM = mm.clamped(to: 1...500)
        p.filmFormatMM = derivedFilmFormatMM(side: filmSide, sideLengthMM: p.sideLengthMM)
        params = p
    }

    /// Re-derive `film_format_mm` from the frame the user described and the
    /// photograph's own shape. Called whenever either half can have changed:
    /// a decode landing, and a crop while the setting below is on.
    ///
    /// **`beforeOpen` is not an optimisation.** On the open path this runs
    /// between the decode landing and the engine's `open`, and going through
    /// the `params` setter there would `requestPrint()` — which is a develop,
    /// during an open that is contracted to stop at the decode
    /// (`OpenPathTests.testAnOpenStopsAtTheDecode`, which is how this was
    /// found). The value still reaches the engine, because `openDelta` is
    /// built from the sidecar a moment later and now carries it.
    func recomputeFilmFormat(beforeOpen: Bool = false) {
        let mm = derivedFilmFormatMM(side: filmSide, sideLengthMM: params.sideLengthMM)
        guard abs(mm - params.filmFormatMM) > 0.001 else { return }
        if beforeOpen {
            sidecar.params.filmFormatMM = mm
            scheduleSave()
        } else {
            var p = params
            p.filmFormatMM = mm
            params = p
        }
    }

    /// long ÷ short of the photograph, as the physical scale sees it.
    ///
    /// **Whether a crop counts is the user's decision** (PRD: "if a crop
    /// happens, user can decide in settings if the effects are
    /// recalculated"), and the default is that it does not. Off is also the
    /// physically true answer: cropping a negative does not make its grain
    /// coarser, it shows you less of the same negative. On means the opposite
    /// statement — that the cropped rectangle *is* the frame, re-mapped — and
    /// it is what someone shooting a 6×17 out of a 3:2 file wants.
    var physicalAspect: Double {
        let (w, h) = physicalFrame
        guard w > 0, h > 0 else { return 3.0 / 2.0 }
        return max(w, h) / min(w, h)
    }

    /// How many times the frame's long edge the crop's long edge is, when the
    /// crop is the frame; 1 when it is not.
    ///
    /// The engine never sees the crop — it develops the whole source and the
    /// crop is cut afterwards — and it derives the pixel pitch from the
    /// **source's** long edge (`pipeline.cpp`, `preprocess.crop_rescale`).
    /// So "the crop is a 36 mm frame" has to be said as "the source is
    /// 36 mm × this": the crop's own pixels at the crop's own pitch. Without
    /// it only the crop's *shape* reached the engine, so a crop to half the
    /// frame at the same ratio changed nothing at all, and a full-height 1:1
    /// out of a 3:2 135 frame — a 24 × 24 mm square of the same negative,
    /// whose grain should not change — came out 1.5× coarser.
    var cropScale: Double {
        guard Session.recalculateEffectsAfterCrop,
              let size = decoded?.pixelSize, size.width > 0, size.height > 0 else { return 1 }
        let (w, h) = physicalFrame
        guard w > 0, h > 0 else { return 1 }
        return max(Double(size.width), Double(size.height)) / max(w, h)
    }

    /// The frame the physical scale is measured on, in pixels: the source,
    /// or the crop when the setting says the crop is the frame. The crop's
    /// size in pixels is the same at any straighten angle.
    private var physicalFrame: (Double, Double) {
        guard let size = decoded?.pixelSize, size.width > 0, size.height > 0 else { return (0, 0) }
        var w = Double(size.width), h = Double(size.height)
        if Session.recalculateEffectsAfterCrop {
            let c = sidecar.geometry.crop
            w *= c.width; h *= c.height
        }
        return (w, h)
    }

    /// `film_format_mm` for this frame, from the user's side and length.
    func derivedFilmFormatMM(side: FilmSide, sideLengthMM: Double) -> Double {
        // On a pair Film Format describes **one frame** (24 x 18 by default).
        // The engine is handed the whole piece, two frames and the gap along
        // its long edge, so its long edge is that many of the frame's.
        if let p = pair {
            let frame = Self.filmFormatMM(side: side, sideLengthMM: sideLengthMM, aspect: 24.0 / 18.0)
            return ((36 + p.effectiveSpacingMM) * frame / 24).clamped(to: 4...200)
        }
        return Self.filmFormatMM(side: side, sideLengthMM: sideLengthMM,
                          aspect: physicalAspect, cropScale: cropScale)
    }

    /// The engine's number, from the user's. It wants the frame's **long
    /// edge**; Side = Short means the length describes the other one, so the
    /// aspect is what closes the gap. `cropScale` carries a crop's physical
    /// frame out to the source's long edge (see `cropScale`).
    ///
    /// Clamped to the service's own 4…200: an extreme aspect with a 56 mm
    /// short side is arithmetic the engine would refuse, and a refused
    /// `set_params` is a render that does not happen rather than a frame that
    /// looks wrong. It is also where the crop-is-the-frame mode stops: a crop
    /// under about a fifth of a 135 frame's long edge asks for more than
    /// 200 mm, and its grain stops growing there.
    nonisolated static func filmFormatMM(side: FilmSide, sideLengthMM: Double,
                                         aspect: Double, cropScale: Double = 1) -> Double {
        let long = side == .long ? sideLengthMM : sideLengthMM * max(aspect, 1)
        return (long * max(cropScale, 1)).clamped(to: 4...200)
    }

    /// "Recalculate film effects after a crop" — `physicalAspect`'s switch,
    /// and a Settings toggle rather than a control on the rail: it is a
    /// statement about what a crop *means* in this app, not a per-frame edit.
    nonisolated static let cropRecalcKey = Session.uiKey + "recalculateEffectsAfterCrop"
    static var recalculateEffectsAfterCrop: Bool {
        get { UserDefaults.standard.bool(forKey: cropRecalcKey) }
        set { UserDefaults.standard.set(newValue, forKey: cropRecalcKey) }
    }

    /// RFC-025's *Decouple effects*: whether the Film section shows a strength
    /// for each effect beside its switch. A view preference, not an edit --
    /// `FilmParams.effects` is on the wire either way, so turning this off
    /// hides the sliders and never changes a picture. Read with `@AppStorage`
    /// under this key where a view has to follow it.
    nonisolated static let decoupleEffectsKey = Session.uiKey + "decoupleEffects"

    func setAutoExposureMethod(_ method: String?) {
        guard method != params.autoExposureMethod else { return }
        var p = params
        p.autoExposureMethod = method
        params = p
        retargetSolvedEV()
    }

    /// Put the EV the meter *would* report for the current Tone under the Exp.
    /// Comp. sublabel, from the map the last develop's `solve` left behind —
    /// which is why `solve` reports all four intents at once.
    ///
    /// Called by everything that changes the Tone: the pill above and
    /// `pasteSettings`, whose clip carries one. A method the map does not carry
    /// — a legacy sidecar's `nil`, or a frame that has never been developed —
    /// leaves the label alone for the develop to fill in.
    ///
    /// Undo needs no equivalent: it restores the whole `Sidecar`, `solvedEV`
    /// included, so the label comes back with the parameters that produced it.
    private func retargetSolvedEV() {
        guard let ev = sidecar.params.autoExposureMethod.flatMap({ exposureEvByMethod?[$0] })
        else { return }
        sidecar.solvedEV = ev
        scheduleSave()
    }

    private func startStockPreview(_ stock: String) {
        guard let url = selection, serviceSessionID != nil else { return }
        let landed = rendersLanded
        Task { [weak self, client] in
            guard let outcome = try? await client.previewStockLUT(stock, tier: "live"),
                  let texture = outcome.texture else { return }
            await MainActor.run {
                guard let self, self.selection == url, self.rendersLanded == landed,
                      self.params.printStock == stock, !self.params.scanFilm,
                      !self.params.digitalIntermediate else { return }
                // Not `store.setPrint`: this is not the print, and caching it
                // as one would hand it back on the next frame switch as
                // though the pipeline had produced it. It goes on the canvas
                // and is replaced by the render that is already on its way.
                self.renderer.setLive(texture)
                self.previewSoft = true
                let ms = String(format: "%.1f", outcome.meta.applyMs)
                self.status = "\(stock) from the baked print LUT in \(ms) ms — "
                            + "no glare, and not your print grade; the real print is rendering."
            }
        }
    }

    func geometryChanged(_ g: Geometry) { geometry = g }
    func straightenPreview(_ line: StraightenLine?) { straightenPreview = line }
    func stepFrame(_ delta: Int) { selectRelative(delta) }
    func toggledOriginal(_ on: Bool) {
        // Not over a film edge, for the reason `canCompare` gives.
        if on && filmEdgeShowsFilm { return }
        if on { leaveCropTool() }
        renderer.showOriginal = on || filmEdgeFraming
        showingOriginal = on
    }

    /// Showing the original and cropping are two different questions about
    /// the frame, and the answers are drawn on top of one another: the crop
    /// handles, the thirds grid and the straighten line all sit over a
    /// picture that is no longer the one being cropped, and the before/after
    /// split's slider runs through the middle of them. The user asked for the
    /// simple resolution rather than a layering rule — "simply quit crop when
    /// show original is enabled" — so this is that, in the one place both
    /// entry points go through.
    ///
    /// It does not restore the crop tool afterwards. Coming back to the crop
    /// is a decision, and a tool that reappears under the pointer because a
    /// comparison ended is a tool nobody asked for.
    private func leaveCropTool() {
        guard tool == .crop else { return }
        tool = .select
    }

    func hovered(normalised n: CGPoint?) {
        guard let n, let base = renderer.base else { hoverValue = nil; return }
        hoverValue = Session.sample(base, at: n)
    }
    func contextMenu() -> NSMenu? {
        if pair != nil { return pairContextMenu() }
        let m = NSMenu()
        let fit = m.addItem(withTitle: "Zoom to Fit", action: #selector(zoomFit), keyEquivalent: "")
        fit.target = self; fit.isEnabled = !zoomLocked
        let hundred = m.addItem(withTitle: "Zoom to 100 %", action: #selector(zoomHundred), keyEquivalent: "")
        hundred.target = self; hundred.isEnabled = !zoomLocked
        m.addItem(.separator())
        let copy = m.addItem(withTitle: "Copy Settings", action: #selector(copyMenu), keyEquivalent: "")
        copy.target = self; copy.isEnabled = canCopySettings
        let paste = m.addItem(withTitle: "Paste Settings", action: #selector(pasteMenu), keyEquivalent: "")
        paste.target = self; paste.isEnabled = canPasteSettings
        m.addItem(.separator())
        m.addItem(withTitle: "Reset Crop", action: #selector(resetCrop), keyEquivalent: "").target = self
        m.addItem(withTitle: "Export…", action: #selector(exportMenu), keyEquivalent: "").target = self
        return m
    }
    @objc private func zoomFit() { zoomToFit() }
    @objc private func zoomHundred() { zoomTo(fraction: 1) }
    @objc private func copyMenu() { copySettings() }
    @objc private func pasteMenu() { pasteSettings() }
    @objc private func resetCrop() { geometry = .default }
    @objc private func exportMenu() { showExport = true }

    /// What the engine's auto-exposure solved for this frame. The Exp. Comp.
    /// slider is an offset from it, so the UI has to say what the zero means
    /// (HANDOFF §4). The value comes from `solve(target:"exposure")` after
    /// `open` and is stored in the sidecar.
    var solvedEVLabel: String? {
        guard let ev = sidecar.solvedEV else { return nil }
        return String(format: "auto %+.1f EV", ev)
    }

    func zoomToFit() {
        guard !zoomLocked else { return }
        renderer.viewport.fit(); viewportChanged(); renderer.needsDraw?()
    }
    /// The navigator's click and drag: put the frame's normalised point `n` at
    /// the centre of the canvas, at the current zoom. The one clamp still
    /// applies, so near an edge the view stops at the edge rather than showing
    /// the surround. Nothing to do at fit, where there is nowhere to go.
    func centreView(onNormalised n: CGPoint) {
        guard !zoomLocked else { return }
        var v = renderer.viewport
        guard !v.isFit else { return }
        v.offset = CGPoint(x: v.viewport.width / 2 - n.x * v.image.width * v.scale,
                           y: v.viewport.height / 2 - n.y * v.image.height * v.scale)
        v.clamp()
        renderer.viewport = v
        viewportChanged(); renderer.needsDraw?()
    }
    func zoomTo(fraction: CGFloat) {
        guard !zoomLocked else { return }
        let v = renderer.viewport
        renderer.viewport.setScale(fraction * v.hundredScale, about: CGPoint(x: v.viewport.width / 2, y: v.viewport.height / 2))
        viewportChanged(); renderer.needsDraw?()
    }
    func zoomStep(_ dir: Int) {
        guard !zoomLocked else { return }
        let v = renderer.viewport
        renderer.viewport.stepZoom(dir, about: CGPoint(x: v.viewport.width / 2, y: v.viewport.height / 2))
        viewportChanged(); renderer.needsDraw?()
    }

    /// The Straighten slider's write. A scrub is a stream of writes and the
    /// view must not rescale under it, so this holds the refit until the
    /// end of the gesture — `ScrubSlider.onCommit`, which fires on release
    /// and on a typed value — instead of letting every degree refit the
    /// canvas. Every other angle entry point writes `geometry` directly and
    /// refits at once: the menu, "Straighten to 0°", an undo and the canvas
    /// gestures are all single writes.
    func scrubStraighten(to degrees: Double) {
        renderer.beginRotation()
        geometry = geometry.straightened(to: degrees, in: sourceImageSize)
    }

    /// The end of a Straighten scrub: refit the crop tool's view, once.
    func straightenScrubEnded() { renderer.endRotation() }

    private func addCurvePoint(at n: CGPoint) {
        guard let base = renderer.base, let v = Session.sample(base, at: n) else { return }
        var a = adjustments
        let l = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
        var c = a.curves[.rgb]
        let x = CGFloat(l)
        c.insert(CGPoint(x: x, y: c.evaluate(x)))
        a.curves[.rgb] = c
        adjustments = a
    }

    /// Read one pixel of an rgba16Unorm texture (shared storage).
    nonisolated static func sample(_ tex: MTLTexture, at n: CGPoint) -> SIMD3<Float>? {
        guard tex.storageMode == .shared || tex.storageMode == .managed else { return nil }
        let x = Int(n.x * CGFloat(tex.width - 1)), y = Int(n.y * CGFloat(tex.height - 1))
        var px = [UInt16](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return SIMD3(Float(px[0]) / 65535, Float(px[1]) / 65535, Float(px[2]) / 65535)
    }

    // MARK: - the native render
    //
    // The model is at the top of the file, next to its state (search for "the
    // preview resolution, and the original image"). What lives here is the
    // machinery the zoom ladder used to own and the two-state model still
    // needs: when to start the native render, and whether this frame is worth
    // one at all.

    /// The Layer 1 parameters a print was made from, as a comparable string.
    /// This is what stamps a native render, so whether a resident texture is
    /// still the truth is a question about *data* rather than about which
    /// callback happened to run last.
    nonisolated static func printStamp(_ p: FilmParams) -> String {
        let stamp = p.wire.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
        // With a film edge the crop is in the negative (`Session+FilmEdge`),
        // so the print is a different picture for every framing. Off, the
        // stamp is exactly what it always was.
        if p.filmEdge.effective { return stamp + ";overscan_framing=\(p.filmEdge.framing)" }
        return p.cutsFrame ? stamp + ";date_framing=\(p.dateBack.framing)" : stamp
    }

    /// What the *service* currently holds — not `sidecar.params`, which may
    /// already be a slider ahead of it. The live print on screen was made
    /// from `sent`, so stamping the native render with anything else would
    /// let the two disagree about which film they are showing.
    private var printStamp: String { Session.printStamp(scheduler.sent) }

    /// The long edge of what is actually on screen, in source pixels. A 20 %
    /// crop of a 45 MP frame has a 1651 px long edge, which the preview
    /// resolution may already cover — a native render would spend 360 MB on
    /// detail the crop threw away.
    private var croppedLongEdge: CGFloat {
        // With a film edge the engine's frame *is* the crop.
        if let size = decoded?.pixelSize, filmEdgeCut != nil {
            let picture = enginePictureSize(size)
            return max(picture.width, picture.height)
        }
        guard let live = renderer.sourceSize, max(live.width, live.height) > 0 else { return sourceLongEdge }
        let out = renderer.geometry.outputSize(for: live)
        return sourceLongEdge * max(out.width, out.height) / max(live.width, live.height)
    }

    /// Whether a frame of this size — after the crop — has anything a native
    /// render would add at this preview resolution. A pure decision, so the
    /// policy is testable without a frame, a session or a GPU.
    nonisolated static func wantsFullRender(frameLongEdge: CGFloat, previewEdge: Int) -> Bool {
        frameLongEdge > CGFloat(previewEdge)
    }

    /// Whether *this* frame has anything a native render would add.
    private var wantsFullRender: Bool {
        sourceLongEdge > 0 && Session.wantsFullRender(frameLongEdge: croppedLongEdge,
                                                      previewEdge: previewLongEdge)
    }

    /// Ask for the frame at its own resolution, once the edit has settled.
    ///
    /// Called when a print lands (`applyRender`) — the moment the canvas holds
    /// the current parameters at the preview resolution. The debounce is what
    /// keeps a dragged slider from starting one per step; the generation is
    /// what keeps a slow render from landing on a frame or a grade the user
    /// has moved on from.
    private func scheduleFullRender() {
        fullTask?.cancel()
        fullTask = nil
        fullPending = false
        guard wantsFullRender, let url = selection, let sid = serviceSessionID else { return }
        fullGeneration += 1
        let gen = fullGeneration
        fullTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Session.fullRenderDebounceMs))
            guard let self, !Task.isCancelled, gen == self.fullGeneration else { return }
            await self.renderFullRender(for: url, sessionID: sid, generation: gen)
        }
    }

    /// Hand a frame's finished print textures to the bounded disk writer.
    /// This runs on leaving a frame; the current frame's live tier stays in
    /// RAM because restoring it would cost more than its warm reprint.
    private func enqueuePrintWriteback(for url: URL) {
        guard let printWriteback else { return }
        let live = renderer.store.printEntry(for: url)
        let full = renderer.store.fullEntry(for: url)
        Task {
            if let live, let key = live.cacheKey {
                await printWriteback.enqueue(StagedPrint(
                    key: key,
                    texture: live.texture,
                    sourceWidth: live.sourceWidth,
                    sourceHeight: live.sourceHeight,
                    costMs: live.costMs
                ))
            }
            if let full, let key = full.cacheKey {
                await printWriteback.enqueue(StagedPrint(
                    key: key,
                    texture: full.texture,
                    sourceWidth: full.sourceWidth,
                    sourceHeight: full.sourceHeight,
                    costMs: full.costMs
                ))
            }
        }
        schedulePrintWriteback()
    }

    /// Drain only when the current frame is settled. New work reschedules
    /// itself; a backlog can never compete with a live edit.
    private func schedulePrintWriteback() {
        printWritebackTask?.cancel()
        guard printWriteback != nil else { return }
        printWritebackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Session.fullRenderDebounceMs))
            guard let self else { return }
            while !Task.isCancelled {
                if !busy && !fullPending && !scheduler.pending {
                    await printWriteback?.drain()
                    if await printWriteback?.isEmpty == true { return }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func renderFullRender(for url: URL, sessionID sid: String, generation gen: Int) async {
        // The transport is single-flight, so this sits in front of the user's
        // next slider release. The rule is the one the ladder used: never
        // start one while an edit is owed a render — wait for the scheduler to
        // go idle and ask again, rather than dropping it.
        guard !busy, !scheduler.pending, selection == url, serviceSessionID == sid,
              gen == fullGeneration, wantsFullRender else {
            if selection == url, serviceSessionID == sid { scheduleFullRender() }
            return
        }
        fullPending = true
        startClock()
        // Stamped here, before the call, from what the service holds. The
        // guard above has just established that no edit is owed a render, so
        // `sent` is exactly what this reprint will be made from.
        let stamp = printStamp
        // The peak §11.5 is about — 7.6 GB at 45 MP and the largest single
        // allocation the app ever asks for. The frame is already open, so this
        // is the last cheap moment to say so; the crop only ever makes it
        // smaller, which is why the forecast uses the frame's own pixels.
        if let size = decoded?.pixelSize {
            noteProjection(pixels: developForecastPixels(size), operation: "full")
        }
        canvasLog("full render requested for \(url.lastPathComponent)")
        defer { fullPending = false }
        do {
            let outcome = try await client.render(.reprint,
                RenderRequest(sessionID: sid, tier: "full"))
            let r = outcome.response
            // A render already committed to the engine outlives a cancelled
            // `fullTask`, and a reopen (a white-balance change) moves neither
            // the generation nor the selection. What it does move is the
            // session: a render made from any session but the one on screen is
            // a different decode, and storing it under a stamp that still
            // matches would serve the old colour on the next edit.
            guard gen == fullGeneration, selection == url, sid == serviceSessionID,
                  var tex = outcome.texture, let w = r.width, let h = r.height else { return }
            // A pair at its own resolution: the same cut of the same prints.
            if pair != nil {
                if let layered = await pairLayered(base: tex, tier: "full") { tex = layered }
                guard gen == fullGeneration, selection == url, sid == serviceSessionID else { return }
            }
            let sourceSize = decoded?.pixelSize
            let key = Self.printCacheKey(
                url: url, params: scheduler.sent, tier: .full,
                previewLongEdge: previewLongEdge,
                engineVersion: diagnostics.engineVersion ?? "unknown"
            )
            renderer.store.setFullRender(
                tex, stamp: stamp, costMs: r.elapsedMs + (openClock?.setupMs ?? 0),
                cacheKey: key,
                sourceWidth: sourceSize.map { Int($0.width.rounded()) },
                sourceHeight: sourceSize.map { Int($0.height.rounded()) },
                for: url
            )
            renderer.setFullRender(tex)
            // The canvas is the frame at its own resolution now, which is the
            // whole point: nothing on screen is interpolated any more.
            previewSoft = false
            canvasLog("full render \(w)x\(h) landed in \(Int(r.elapsedMs)) ms")
            sampleMemory("full_render")
            if let base = statusBase { status = base }
            schedulePrintWriteback()
        } catch {
            noteFailure(error, operation: "full_render", frame: url.lastPathComponent)
        }
    }

    // MARK: - editing history, clipboard, service

    /// Snapshot before a mutation, coalesced. A slider drag sets its value
    /// dozens of times and only the state before the drag is worth keeping.
    private func pushUndo() {
        let now = Date()
        guard now.timeIntervalSince(lastUndoAt) > 0.5 else { return }
        lastUndoAt = now
        undoStack.append(sidecar)
        undoPairs.append(pair.flatMap { p in selection.map { ($0, p) } })
        if undoStack.count > 60 { undoStack.removeFirst(); undoPairs.removeFirst() }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Undo is a deterministic re-render from a snapshot: the params are tiny,
    /// the service never needs to know, and grain is baked into its cached
    /// negative so a reprint is stable (HANDOFF §5).
    func undo() {
        guard !batchExporting, selection != nil, let previous = undoStack.popLast() else { return }
        let current = sidecar
        let piece = undoPairs.popLast() ?? nil
        sidecar = previous
        pushLayer2(previous.adjustments)
        renderer.geometry = canvasGeometry
        selectedMaskID = previous.masks.first { $0.id == selectedMaskID }?.id ?? previous.masks.last?.id
        syncMasks()
        // The piece as it was, if this step changed it: its file goes back and
        // the pair is laid out again.
        if let piece, let url = selection, piece.url == url, let now = pair, now != piece.pair {
            try? piece.pair.save(to: url)
            // A crop gesture's picture is of the piece this step takes back.
            pairPlacementTask?.cancel()
            pairDrag = nil
            pair = piece.pair
            pairRightExif = piece.pair.right.flatMap { EXIFReadout.read($0.url) }
            exif = EXIFReadout.read(piece.pair.left?.url ?? url)
            renderer.store.invalidatePrint(for: url)
            refreshPairThumbnail(url)
            wantsDevelop = true
            decodeIsStale = true
            scheduleReopen()
            markStale()
            scheduleSave()
            lastUndoAt = .distantPast
            status = "Undo — \(undoStack.count) step\(undoStack.count == 1 ? "" : "s") left."
            return
        }
        if current.decode != previous.decode {
            previewSoft = true
            scheduleReopen()
        } else {
            requestPrint()
        }
        markStale()
        scheduleSave()
        lastUndoAt = .distantPast
        status = "Undo — \(undoStack.count) step\(undoStack.count == 1 ? "" : "s") left."
    }

    var canCopySettings: Bool { selection != nil && !clipboardGroups.isEmpty }
    var canPasteSettings: Bool { clipboard != nil && selection != nil && !batchExporting }

    var syncTargets: [URL] { selectedFrames.filter { $0 != selection } }
    var canSyncSettings: Bool {
        !batchExporting && selection != nil && !clipboardGroups.isEmpty && !syncTargets.isEmpty
    }

    /// Sync takes a fresh snapshot, never the older clipboard. The source is
    /// left alone (in particular its fitted Scene Placement and undo history).
    /// Offline targets use the same sidecar/cache path as a settings paste.
    func syncSettings() {
        guard canSyncSettings, let source = selection else { return }
        let clip = SettingsClip(groups: clipboardGroups, settings: sidecar,
                                sourceName: source.lastPathComponent)
        var written = 0, failed = 0
        for url in syncTargets {
            switch pasteOffline(clip, to: url) {
            case .written: written += 1
            case .failed: failed += 1
            case .unchanged: break
            }
        }
        status = failed > 0 ? String(format: L(.clipSyncResult), written, failed)
            : written > 0 ? String(format: L(.clipSyncDone), written)
            : L(.clipSyncNothing)
    }

    /// Where a paste goes: every picked frame, which always includes the one
    /// on the canvas (`togglePick`), or that frame alone.
    var pasteTargets: [URL] {
        let picked = selectedFrames
        if !picked.isEmpty { return picked }
        return selection.map { [$0] } ?? []
    }

    /// Take the ticked groups from the frame on the canvas (RFC-027 §3).
    func copySettings() {
        guard let url = selection, !clipboardGroups.isEmpty else { return }
        clipboard = SettingsClip(groups: clipboardGroups, settings: sidecar,
                                 sourceName: url.lastPathComponent)
        status = "Copied \(clipboardGroups.count) of \(ClipboardGroup.allCases.count) groups from \(url.lastPathComponent)."
    }

    /// Write what the clipboard holds onto every paste target (RFC-027 §4).
    /// The frame on the canvas takes it live and undoably; the others take it
    /// on disk and develop with it when they are opened.
    func pasteSettings() {
        guard let clip = clipboard, let open = selection, !batchExporting else { return }
        let targets = pasteTargets
        var written = 0
        for url in targets where url != open {
            if pasteOffline(clip, to: url) == .written { written += 1 }
        }
        if targets.contains(open), pasteLive(clip) { written += 1 }
        status = written == 0
            ? "Nothing to paste — the frames already have these settings."
            : "Pasted \(clip.groups.count) group\(clip.groups.count == 1 ? "" : "s") onto \(written) frame\(written == 1 ? "" : "s")."
    }

    /// The paste on the frame on the canvas: one undo step, then each side
    /// effect the individual setters would have had.
    @discardableResult
    private func pasteLive(_ clip: SettingsClip) -> Bool {
        let next = clip.applied(to: sidecar)
        guard next != sidecar else { return false }
        pushUndo()
        let decodeChanged = next.decode != sidecar.decode
        sidecar = next
        if clip.groups.contains(.filmEffects) { recomputeFilmFormat(beforeOpen: true) }
        // The clip carries a Tone, so the label follows the paste the same way
        // it follows the pill.
        if clip.groups.contains(.exposure) { retargetSolvedEV() }
        if clip.groups.contains(.masks) {
            selectedMaskID = sidecar.masks.first?.id
            syncMasks()
        }
        if decodeChanged {
            previewSoft = true
            scheduleReopen()
        } else {
            requestPrint()
        }
        markStale()
        scheduleSave()
        // A developed frame can fit at once; one that is not yet will when its
        // first render lands (`applyRender`).
        resolvePendingPlacement()
        return true
    }

    /// The Fit that completes a pasted Scene Placement (`resolvePendingPlacement`).
    ///
    /// Written straight to the sidecar with **no undo step**: it is the second
    /// half of the paste, not an edit of its own. The undo snapshot the paste
    /// pushed has the flag clear, so ⌘Z goes back past both halves at once and
    /// can never land on a state that fits again.
    func finishPastedPlacement(_ placement: SceneLatitudeSettings) {
        sidecar.params.sceneLatitude = placement
        sidecar.placementNeedsFit = false
        requestPrint()
        markStale()
        scheduleSave()
    }

    /// The paste on a frame that is not on the canvas: written to its sidecar
    /// now, rendered when it is next opened. Its resident print is the old
    /// look and `select` would show it first, so it goes (PRD R2).
    private enum SettingsWriteResult { case unchanged, written, failed }

    private func pasteOffline(_ clip: SettingsClip, to url: URL) -> SettingsWriteResult {
        let current = Sidecar.load(for: url) ?? Sidecar()
        var next = clip.applied(to: current)
        guard next != current else { return .unchanged }
        next.state = .stale
        do {
            try next.save(for: url)
        } catch {
            noteFailure(error, operation: "paste", frame: url.lastPathComponent)
            return .failed
        }
        renderer.store.setPrint(nil, for: url)
        frameStates[url] = .stale
        return .written
    }

    // MARK: - solve, and looking at the original

    /// Solve needs the engine, a frame, and nothing already in flight. It does
    /// **not** need the frame to be in the engine yet: on a frame that is
    /// still only decoded, pressing it *is* the develop, and the solve lands
    /// on top of the session that develop made.
    var canSolve: Bool {
        serviceReady && serviceBlocked == nil && selection != nil && !busy
    }

    /// Ask the engine to solve this frame: auto-exposure **and** the enlarger
    /// filter pack for the paper that is selected.
    ///
    /// The develop already ran `solve(target: "exposure")`, which measures and
    /// reports the baseline the Exp. Comp. slider is an offset from. This is
    /// `target: "both"` — the same measurement plus the filter pack — and it is
    /// a button rather than something that happens on open because it is the
    /// user saying "print this frame".
    ///
    /// The Y/M filter shifts are offsets from the solved neutrals, so they go
    /// back to zero here — leaving a shift on top of a freshly solved pack
    /// means "solve" would visibly not solve.
    func solveNow() {
        guard serviceReady, selection != nil else {
            status = "The render service is not running."; return
        }
        guard !busy else { return }
        wantsDevelop = true
        busy = true
        startClock()
        status = "Solving…"
        Task {
            defer { busy = false }
            do {
                // On a frame that is still only decoded, Solve is also the
                // develop — and the session it returns is the one to solve.
                guard let sid = await ensureDeveloped(), serviceSessionID == sid else { return }
                try await solveFilterPack(sessionID: sid)
                guard serviceSessionID == sid else { return }
                let rr = try await client.render(.reprint, RenderRequest(sessionID: sid))
                guard serviceSessionID == sid else { return }
                applyRender(rr, generation: serviceGeneration)
                status = "Solved  ·  reprint \(Int(rr.response.elapsedMs)) ms"
                scheduleSave()
            } catch {
                noteFailure(error, operation: "solve", frame: selection?.lastPathComponent)
                status = "\(error)"
            }
        }
    }

    /// `solve(target: "both")`: the auto-exposure the develop already reported
    /// plus the enlarger filter pack for the paper on the session.
    ///
    /// Zeroing the Y/M shifts is part of it — they are offsets from the solved
    /// neutrals, and a shift left on top of a freshly solved pack means Solve
    /// visibly did not solve. The scheduler's `sent` no longer describes the
    /// session once the pack has been re-solved, so its generation is reopened
    /// rather than trusted.
    private func solveFilterPack(sessionID sid: String) async throws {
        _ = try await client.call(.solve, SolveRequest(sessionID: sid, target: "both"),
                                  as: SolveResponse.self)
        guard serviceSessionID == sid else { return }
        var p = params
        p.yFilterShift = 0
        p.mFilterShift = 0
        params = p
        scheduler.invalidate()
        serviceGeneration = scheduler.reset(sessionID: sid, params: p)
    }

    /// The Python process can die; `ServiceClient.start()` is idempotent, so a
    /// restart is a stop and a reload from the sidecar (HANDOFF §5).
    func restartService() {
        loadTask?.cancel()
        // A develop in flight belongs to the engine that is being stopped.
        developTask?.cancel(); developTask = nil
        Task {
            await client.stop()
            serviceReady = false
            releaseEngineAccounting()
        serviceSessionID = nil
        engineFraming = nil
            scheduler.invalidate()
            renderer.dropFullRender()
            renderer.store.dropFullRender()
            cancelNativeOriginal()
            decodedGeneration = 0
            guard let url = selection else { status = "Render service stopped."; return }
            status = "Restarting the render service…"
            let gen = pipeline.supersede()
            loadTask = Task { await load(url, generation: gen) }
        }
    }

    // MARK: - diagnostics (RFC-016)

    /// The one place a failure becomes three things: a sentence for the user,
    /// an `error` record with the engine's own words beside it (§3), and — for
    /// the classes that are refusals rather than breakage — a badge in the
    /// window (§11.5: "a refusal is a visible event, not just a log line").
    ///
    /// The classification comes from `EngineMessage`, so the sentence the user
    /// reads and the `kind` in the record cannot disagree.
    func noteFailure(_ error: Error, operation: String, frame: String? = nil, pixels: Int? = nil) {
        let raw = EngineMessage.technical(error)
        let kind = EngineMessage.kind(error)
        let message = EngineMessage.userFacing(error)
        var fields: [LogField] = [
            .init("op", operation), .init("kind", kind.rawValue),
            .init("raw", raw), .init("user", message),
        ]
        if let frame { fields.append(.init("frame", frame)) }
        if let pixels { fields.append(.init("px", pixels)) }
        log.error(.error, "\(operation) failed", fields)
        canvasLog("\(operation) failed: \(raw)")
        diagnostics.noteError(message)
        lastError = message
        status = message
        if kind.isRefusal, let badge = kind.badge {
            refusal = Refusal(badge: badge, message: message, kind: kind)
        }
    }

    /// A `memory` boundary sample (§3): after the decode, after `engine.open`,
    /// after the first print, **after a full render**, after an export, on a
    /// frame switch.
    ///
    /// The full-tier one was missing until 2026-09-20, and its absence was the
    /// reason a user could not check RFC-020's own numbers on their own
    /// machine. Every boundary here was a moment somebody had asked about
    /// except the one the memory work is *about*: the full render is where the
    /// engine holds nine planes at once, it is the 15.6 GB in RFC-020 §1.1,
    /// and nothing sampled it. `peakBytes` is a running maximum, so what the
    /// Settings page called "Session peak" was the highest of the *other*
    /// boundaries — a number that could only under-report, and did, unless the
    /// Settings page happened to be open with its own 2 s timer running.
    ///
    /// Taken after the texture has landed rather than during the render: the
    /// pool is not returned at `end_frame` (RFC-020 §3.1), so the high-water
    /// is still charged to the process here. That is the same place §1.1's
    /// table takes its "render full" row, which is what makes the app's
    /// number and the RFC's comparable at all.
    ///
    /// Through the session's own `Diagnostics`, so the record and the Settings
    /// page's readout are the same sample — one sampler, one number (§8.5).
    func sampleMemory(_ reason: String) {
        diagnostics.sampler.sample(reason, frame: selection?.lastPathComponent)
    }

    private func releaseEngineAccounting() {
        if let handle = engineArenaHandle { diagnostics.arena.release(handle); engineArenaHandle = nil }
    }

    /// Forecast what this frame will cost before the engine takes it on, and
    /// record the answer either way (§11.5).
    ///
    /// The message is not a refusal: nothing here blocks. What it buys is that
    /// the app cannot sail into a swap storm *silently* — the user is told, the
    /// log says so, and `overrideMemoryWarning` is the door out.
    @discardableResult
    private func noteProjection(pixels: Int, operation: String) -> Diagnostics.MemoryProjection {
        let projection = diagnostics.noteProjection(pixels: pixels, operation: operation,
                                                    frame: selection?.lastPathComponent)
        if let message = projection.message { memoryWarning = message }
        return projection
    }

    /// §3 `open`: one record per frame open, the `LoadClock` stages as fields
    /// rather than the prose line the stderr summary is, plus the frame's own
    /// pixels and whether this was a develop or a decode and nothing more.
    private func noteOpen(_ clock: LoadClock, url: URL, mode: String, pixels: CGSize?) {
        var fields = clock.stages
        fields.append(.init("mode", mode))
        fields.append(.init("frame", url.lastPathComponent))
        fields.append(.init("total_ms", clock.totalMs()))
        if let pixels, pixels.width > 0, pixels.height > 0 {
            fields.append(.init("w", Int(pixels.width)))
            fields.append(.init("h", Int(pixels.height)))
            fields.append(.init("px", Int(pixels.width * pixels.height)))
        }
        if let core = renderCore { fields.append(.init("core", core)) }
        log.info(.open, mode, fields)
    }

    /// Elapsed time for the current piece of work. The service cannot report
    /// real progress: `reprint` does not return until the render is finished,
    /// and the transport is single-flight, so `progress` can never be polled
    /// while a render is in flight. Elapsed time is the honest substitute.
    private func startClock() {
        guard workClock == nil else { return }
        workStarted = Date()
        workSeconds = 0
        workClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if let start = self.workStarted { self.workSeconds = Date().timeIntervalSince(start) }
                if !self.working { break }
            }
            self?.workClock = nil
            self?.workStarted = nil
            self?.workSeconds = 0
        }
    }

    // MARK: - reset helpers

    func resetParams() { params = .default }
    func resetAdjustments() { adjustments = Adjustments(enabled: adjustments.enabled) }
}

/// Metal textures are thread-safe to hand across; the protocol just is not
/// marked Sendable. The box states the intent in one place.
struct TextureBox: @unchecked Sendable { let texture: MTLTexture?; init(_ t: MTLTexture?) { texture = t } }

/// A disk-cache hit is a display picture, not a decode. Carrying the source
/// dimensions separately keeps the viewport honest without pretending the
/// linear `DecodedImage` exists.
struct DisplayPicture: @unchecked Sendable {
    let texture: MTLTexture
    let sourceSize: CGSize
    let costMs: Double
}

/// Why a disk-cache lookup did not produce a picture.
///
/// The lookup used to be one `guard … else { return nil }` chain, which made
/// every step below indistinguishable from "nothing was stored". That is the
/// wrong shape for a cache: a cold cache and a *broken* one then look
/// identical from the outside, and the only visible symptom of either is that
/// the open quietly costs a full decode. RFC-019's display cache is worth
/// ~0.5 s and a decode's worth of memory per open, so a cache that has
/// stopped working has to be able to say so.
///
/// `noEntry` is the ordinary cold miss and is not interesting. The other four
/// all mean something was stored and could not be used, which is a defect
/// somewhere — a stale format, a key that moved, or a device that would not
/// give us a texture.
enum CacheMissReason: String, Sendable {
    /// No disk cache is attached to this session at all.
    case noStore
    /// Warm-up has not published an engine version, so any key built here
    /// would carry the literal `"unknown"` — a namespace nothing is stored
    /// under and nothing useful would ever be stored under. Reachable only
    /// when warm-up *failed*, since `load` now gates on it; the engine is
    /// blocked in that case and the frame is not going to render anyway.
    case engineUnknown
    /// The store threw. A miss that is really an error, and the `try?` that
    /// used to swallow it is the reason this enum exists.
    case lookupFailed
    /// Nothing under this key. The ordinary cold miss.
    case noEntry
    /// An entry under this key, but for a different kind of payload.
    case wrongKind
    /// An entry in a format this build cannot upload.
    case wrongFormat
    /// The bytes were there and the texture was not: `makeTexture` returned
    /// nil, which at this size means the device refused the allocation.
    case uploadFailed
}

/// Shares `SPEKTRAFILM_CANVAS_LOG=1` with `Renderer`: the canvas being blank
/// is a whole-pipeline symptom, so both ends of it log under one switch.
///
/// Since RFC-016 §9 step 2 the call sites are unchanged and every line is also
/// a `debug` record in the `canvas` category (§3): at Normal it reaches the
/// ring and not the file, so a canvas trace is available in a diagnostic
/// bundle without having had the switch on — which is the whole reason the
/// ring exists. The stderr behaviour is untouched, verbatim, including the
/// `session: ` prefix and `Renderer.logDraws`' gate: `AGENTS.md` documents
/// that line and people grep for it.
@MainActor
func canvasLog(_ message: @autoclosure () -> String) {
    if Renderer.logDraws {
        let text = message()
        Log.shared.debug(.canvas, text)
        FileHandle.standardError.write(Data("session: \(text)\n".utf8))
    } else {
        // Not evaluated unless a sink takes it (§5.3): a draw happens sixty
        // times a second and its message is a `String(format:)`.
        Log.shared.debug(.canvas, message())
    }
}

extension Notification.Name { static let thumbnailUpdated = Notification.Name("thumbnailUpdated") }

extension EngineClient {
    func set(onTermination: @escaping @Sendable (String) -> Void) { self.onTermination = onTermination }
}

/// ISO / shutter / aperture for the histogram caption, via ImageIO.
struct EXIFReadout: Sendable {
    var iso: String?, shutter: String?, aperture: String?
    /// What the date back and the film edge may print (`ShootingData`).
    var shooting = ShootingData()
    static func read(_ url: URL) -> EXIFReadout? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        var r = EXIFReadout()
        r.shooting = ShootingData(exif: exif)
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { r.iso = "ISO \(iso)" }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            r.shutter = t >= 1 ? String(format: "%.0f s", t) : "1/\(Int((1 / t).rounded())) s"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { r.aperture = String(format: "f/%g", f) }
        return r
    }
}

extension Session {
    /// The service session id an export needs, developing the frame first if
    /// it is still only decoded. An export is a request for the picture, so it
    /// is also a request for the develop.
    func currentServiceSession() async -> String? { await ensureDeveloped() }
}

// MARK: - the half-frame pair
//
// A pair is a filmstrip item whose file is a `HalfFramePair` and whose decode
// is both pictures on one piece of film (`PairComposer`). The session opens
// it as it opens a frame; what is here is the part a frame does not have:
// which frame is in which hole, where each picture sits, and how each hole is
// exposed.

/// The pair's layers (the design's Film / Left hole / Right hole): which one
/// the Half-Frame Pair section is showing the controls of.
enum PairLayer: String, CaseIterable, Sendable {
    case film, left, right
    var side: HalfFramePair.Side? { self == .left ? .left : self == .right ? .right : nil }
}

extension Session {
    /// Frames, with each folder's pairs put after their left frame (answer
    /// B8); a pair with no left frame goes at the end.
    nonisolated static func withPairs(_ files: [Frame]) -> [Frame] {
        var out = files
        var seen = Set<String>()
        for folder in files.map({ $0.id.deletingLastPathComponent() }) where seen.insert(folder.path).inserted {
            for (url, pair) in HalfFramePair.pairs(in: folder) {
                let after = pair.left.flatMap { hole in out.firstIndex { $0.id.standardizedFileURL.path == hole.path } }
                out.insert(Frame(id: url), at: after.map { $0 + 1 } ?? out.count)
            }
        }
        return out
    }

    /// Take up the pair at `url`, or put the last one down. Called by
    /// `select` once the pair's own sidecar is loaded.
    func adoptPair(for url: URL) {
        pairExposureTask?.cancel()
        guard var p = HalfFramePair.load(url) else {
            pair = nil
            pairRightExif = nil
            pairPlacing = false
            pairDrag = nil
            pairGates = []
            return
        }
        // The shot stays the frame's: its white balance and lens correction
        // are read from its own sidecar every time the pair is opened.
        var changed = false
        for side in HalfFramePair.Side.allCases {
            guard var hole = p[side] else { continue }
            let own = Sidecar.load(for: hole.url)
            let decode = own?.decode ?? DecodeSettings(), geometry = own?.geometry ?? .default
            if decode != hole.decode || geometry != hole.geometry {
                hole.decode = decode; hole.geometry = geometry
                p[side] = hole; changed = true
            }
        }
        let strip = sidecar.params.filmEdge.active
        if p.onStrip != strip { p.onStrip = strip; changed = true }
        if changed {
            try? p.save(to: url)
            renderer.store.invalidatePrint(for: url)
            wantsDevelop = true
        }
        pair = p
        pairLayer = .film
        pairPlacing = false
        pairDrag = nil
        pairGates = []
        pairPicker = nil
        pairRightExif = p.right.flatMap { EXIFReadout.read($0.url) }
        // One strip, one meter reading per hole (`pairExposure`): the engine's
        // own meter would read both pictures and the gap as one scene.
        sidecar.params.autoExposure = false
        sidecar.geometry = .default
        sidecar.heldCrop = nil
        // Film Format describes one frame of the pair. A pair made before it
        // did was left with the stock 135 (a 36 x 24 frame), which read as a
        // half frame a third larger than it is: 24 x 18, as a new pair has.
        let stock = FilmParams.default
        if sidecar.params.filmFrame == stock.filmFrame, sidecar.params.filmSide == stock.filmSide,
           sidecar.params.sideLengthMM == stock.sideLengthMM {
            sidecar.params.filmFrame = FilmFrame.custom.id
            sidecar.params.filmSide = FilmSide.long.rawValue
            sidecar.params.sideLengthMM = 24
            scheduleSave()
        }
    }

    var canMakePair: Bool { !batchExporting && frames.contains { !HalfFramePair.isPair($0.id) } }

    /// New Half-Frame Pair (⌘J): the picked frames fill the holes in the
    /// filmstrip's order — two fill both, one fills Left, none leaves both
    /// empty. The pair's look starts as its first frame's.
    func newPair() {
        guard canMakePair else { return }
        let picks = Array(selectedFrames.filter { !HalfFramePair.isPair($0) }.prefix(2))
        let own = picks.first.flatMap { $0 == selection ? sidecar : Sidecar.load(for: $0) }
        // A landscape first frame is the camera turned: the holes are stacked.
        let size = picks.first.flatMap(Self.pixelSize(of:)) ?? .zero
        makePair(first: picks.first, second: picks.count > 1 ? picks[1] : nil, look: own,
                 turned: size.width > size.height)
    }

    nonisolated static func hole(for frame: URL) -> HalfFramePair.Hole {
        var hole = HalfFramePair.Hole(url: frame)
        let own = Sidecar.load(for: frame)
        hole.decode = own?.decode ?? DecodeSettings()
        hole.geometry = own?.geometry ?? .default
        return hole
    }

    /// Delete a pair: its file and its own settings. The frames it showed
    /// are untouched — a pair references frames, it does not own them.
    func deletePair(_ url: URL) {
        guard HalfFramePair.isPair(url), !batchExporting else { return }
        remove(url)
        if pair != nil, selection == nil { pair = nil }
        try? FileManager.default.removeItem(at: url)
        Sidecar.remove(for: url)
    }

    /// The filmstrip's picture of the pair, from its frames' own previews,
    /// until a render replaces it.
    func refreshPairThumbnail(_ url: URL) {
        Task.detached(priority: .utility) {
            guard let image = PairComposer.thumbnail(url, maxPixel: 320) else { return }
            ThumbnailCache.shared.store(image, for: url)
            await MainActor.run { NotificationCenter.default.post(name: .thumbnailUpdated, object: url) }
        }
    }

    /// The frames a hole can take: the open folder's, never a pair.
    var pairCandidates: [Frame] { frames.filter { !HalfFramePair.isPair($0.id) } }

    /// One write path for the piece: save the file, drop what was rendered
    /// from the old one, and decode again (`redecode`) or only expose again.
    func updatePair(redecode: Bool = true, rerender: Bool = true, step: Bool = false,
                    _ change: (inout HalfFramePair) -> Void) {
        guard var p = pair, let url = selection, !batchExporting else { return }
        change(&p)
        guard p != pair else { return }
        // A slider drag is one undo step (`pushUndo` coalesces); adding,
        // removing or swapping a frame is a step of its own however fast it
        // follows the last.
        if step { lastUndoAt = .distantPast }
        pushUndo()
        do { try p.save(to: url) } catch {
            noteFailure(error, operation: "pair", frame: url.lastPathComponent)
            return
        }
        pair = p
        pairRightExif = p.right.flatMap { EXIFReadout.read($0.url) }
        exif = EXIFReadout.read(p.left?.url ?? url)
        refreshPairThumbnail(url)
        renderer.store.invalidatePrint(for: url)
        // A frame's own print or grade: the negative stands, and the caller
        // composes the picture again.
        guard rerender else { scheduleSave(); return }
        wantsDevelop = true
        sidecar.state = .stale
        frameStates[url] = .stale
        scheduleSave()
        if redecode {
            // Nothing may develop the old piece meanwhile: its shape may be
            // one the engine refuses now.
            decodeIsStale = true
            schedulePairReopen()
        } else {
            pairExposureTask?.cancel()
            pairExposureTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, selection == url else { return }
                releaseEngineFrame()
                requestPrint()
            }
        }
    }

    func setHole(_ side: HalfFramePair.Side, to frame: URL?) {
        updatePair(step: true) { $0[side] = frame.map(Self.hole(for:)) }
        resetPlacement(of: side)
        if frame != nil { pairLayer = side == .left ? .left : .right }
    }

    func swapHoles() {
        updatePair(step: true) { let l = $0.left; $0.left = $0.right; $0.right = l }
        // Each placement goes with its frame.
        sidecar.params.placementIsRight.toggle()
        pairLayerChanged()
    }

    func setPlacement(_ side: HalfFramePair.Side, _ change: (inout HalfFramePair.Placement) -> Void) {
        updatePair { p in
            guard var hole = p[side] else { return }
            change(&hole.placement)
            hole.placement.scale = hole.placement.scale.clamped(to: HalfFramePair.Placement.scaleRange)
            hole.placement.x = hole.placement.x.clamped(to: -1...1)
            hole.placement.y = hole.placement.y.clamped(to: -1...1)
            p[side] = hole
        }
    }

    func setHoleExposure(_ side: HalfFramePair.Side, _ ev: Double) {
        let was = pair?[side]?.exposureEV ?? 0
        let now = ev.clamped(to: -5...5)
        // + Film: the film's print brightness moves by the same stops, so the
        // rebate follows the frame (answer B3). It is set first, without a
        // render of its own: the develop this exposure asks for carries it.
        if pair?[side]?.exposureScope == .film, now != was {
            let film = HalfFramePair.PrintTrim(sidecar.params)
            for s in HalfFramePair.Side.allCases where pair?[s] != nil && pair?[s]?.print == nil {
                updatePair(redecode: false, rerender: false) { $0[s]?.print = film }
            }
            sidecar.params.printBrightnessStops = (sidecar.params.printBrightnessStops + (now - was)).clamped(to: -3...3)
        }
        updatePair(redecode: false) { $0[side]?.exposureEV = now }
    }

    func setPairSpacing(_ mm: Double) {
        updatePair { $0.spacingMM = mm.clamped(to: HalfFramePair.spacingRange) }
    }

    /// Film Edge went on or off on a pair: on a strip the camera decides the
    /// gap, so the piece is laid out again when that changes it.
    func pairFilmEdgeChanged(to on: Bool) {
        guard var p = pair, p.onStrip != on, let url = selection else { return }
        let before = p.effectiveSpacingMM
        p.onStrip = on
        if p.effectiveSpacingMM != before {
            updatePair { $0.onStrip = on }
        } else {
            // The same piece: only the note of it changes. The `params` setter
            // that called this asks for the develop itself; asking again here
            // ran two at once.
            try? p.save(to: url)
            pair = p
        }
    }

    /// The piece's layout for a decode of it.
    func pairLayout(for decodedSize: CGSize) -> HalfFramePair.Layout? {
        guard let p = pair else { return nil }
        return HalfFramePair.layout(holeHeight: Int(p.turned ? decodedSize.width : decodedSize.height),
                                    spacingMM: p.effectiveSpacingMM, turned: p.turned)
    }

    /// Each hole's exposure on the strip, in stops: what the engine's meter
    /// chooses for that picture alone, plus the hole's own setting. A hole is
    /// metered once (for its frame, decode and intent) and the reading is
    /// kept in the pair's file.
    func pairExposure(_ d: DecodedImage, for url: URL) async -> [HalfFramePair.Side: Double]? {
        guard var p = pair, let layout = pairLayout(for: d.pixelSize) else { return nil }
        let pairMethod = sidecar.params.autoExposureMethod
        var stops: [HalfFramePair.Side: Double] = [:]
        var metered = false
        for side in HalfFramePair.Side.allCases {
            guard var hole = p[side], hole.exists else { continue }
            // The meter off (Custom) is the frame as it was shot: no gain.
            guard hole.autoExposure else { stops[side] = hole.exposureEV; continue }
            let method = hole.meterMethod ?? pairMethod
            let key = HalfFramePair.meterKey(hole: hole, method: method ?? "legacy")
            if hole.meteredFor != key || hole.meteredEV == nil {
                let device = renderer.device
                let image = PairComposer.meterImage(d.linear, layout: layout, side: side)
                var alone = sidecar
                alone.params.autoExposure = true
                alone.params.autoExposureMethod = method
                alone.params.exposureCompensationEV = 0
                alone.params.filmEdge.active = false
                alone.params.dateBack.active = false
                alone.params.filmFormatMM = 24
                let delta = Self.openDelta(sidecar: alone, previewLongEdge: previewLongEdge)
                guard let frame = try? await Task.detached(priority: .userInitiated, operation: {
                          try ImageDecoder.engineFrame(from: image, device: device)
                      }).value,
                      let r = try? await client.open(frame, paramsDelta: delta),
                      let solved = try? await client.call(.solve, SolveRequest(sessionID: r.sessionID, target: "exposure"),
                                                          as: SolveResponse.self),
                      let ev = solved.solvedParams["exposure_compensation_ev"]
                else { continue }
                guard selection == url, !Task.isCancelled else { return nil }
                hole.meteredEV = ev
                hole.meteredFor = key
                p[side] = hole
                metered = true
            }
            stops[side] = (hole.meteredEV ?? 0) + hole.exposureEV
        }
        if metered, selection == url {
            // The reading, not an edit: carried over onto whatever the user
            // changed while the meter ran.
            var live = pair ?? p
            for side in HalfFramePair.Side.allCases where live[side]?.path == p[side]?.path {
                live[side]?.meteredEV = p[side]?.meteredEV
                live[side]?.meteredFor = p[side]?.meteredFor
            }
            try? live.save(to: url)
            pair = live
        }
        return stops
    }
}

// MARK: - the pair on the canvas: picking a hole, placing its picture

extension Session {
    /// Where the holes are on the canvas, normalised with y down. Without a
    /// film edge the piece is the canvas, so they are the layout's; on a strip
    /// they are the engine's gates (`refreshPairGates`).
    var pairHoleRects: [HalfFramePair.Side: CGRect] {
        guard let p = pair else { return [:] }
        if sidecar.params.filmEdge.effective {
            guard pairGates.count == 2 else { return [:] }
            let sorted = pairGates.sorted { p.turned ? $0.minY < $1.minY : $0.minX < $1.minX }
            return [.left: sorted[0], .right: sorted[1]]
        }
        let l = HalfFramePair.layout(holeHeight: 2400, spacingMM: p.effectiveSpacingMM, turned: p.turned)
        return Dictionary(uniqueKeysWithValues: HalfFramePair.Side.allCases.map { ($0, l.normalisedRect($0)) })
    }

    /// Ask the engine where it put the gates, after a strip render.
    func refreshPairGates() {
        guard pair != nil, sidecar.params.filmEdge.effective, let url = selection else { pairGates = []; return }
        Task {
            let gates = (try? await client.overscanGates()) ?? []
            guard selection == url else { return }
            pairGates = gates
        }
    }

    /// A click on the canvas: the hole under it becomes the picked layer, and
    /// anywhere else on the piece picks the film.
    func clicked(normalised: CGPoint?) {
        guard pair != nil, let n = normalised else { return }
        let hit = pairHoleRects.first { $0.value.contains(n) }?.key
        pairLayer = hit == .left ? .left : hit == .right ? .right : .film
    }

    /// Placement mode (the crop tool's button and key, on a pair): the picked
    /// hole's picture moves under the fixed hole.
    func togglePairPlacing() {
        guard let p = pair else { pairPlacing = false; return }
        if pairPlacing { pairPlacing = false; return }
        // The picked frame, or the first hole that has one; nothing to crop in
        // an empty pair.
        if pairLayer.side.flatMap({ p[$0] }) == nil {
            guard let filled = HalfFramePair.Side.allCases.first(where: { p[$0] != nil }) else { return }
            pairLayer = filled == .left ? .left : .right
        }
        pairPlacing = true
        // The gesture's picture, ready before the first notch of the wheel.
        if let hole = pairLayer.side.flatMap({ p[$0] }) {
            Task.detached(priority: .userInitiated) { _ = PairComposer.framedPreview(hole) }
        }
    }

    func endPlacement() -> Bool {
        guard pairPlacing else { return false }
        // A zoom still in flight is kept, not thrown away with the mode.
        commitPlacement()
        pairPlacing = false
        return true
    }

    /// The frame's pixel size as ImageIO reports it (turned by its EXIF
    /// orientation), for how far a drag moves the picture.
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        let turned = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// `origin` after the picture is dragged by `d` — a fraction of the hole,
    /// x right and y down. The picture follows the pointer, so the rectangle
    /// cut from the source moves the other way.
    nonisolated static func placement(_ origin: HalfFramePair.Placement, draggedBy d: CGSize,
                                      source: CGSize, aspect: Double = 0.75) -> HalfFramePair.Placement {
        let turned = HalfFramePair.turned(source, by: origin)
        let cut = HalfFramePair.sourceRect(for: origin, source: turned, aspect: aspect)
        var p = origin
        let slackX = (turned.width - cut.width) / 2, slackY = (turned.height - cut.height) / 2
        if slackX > 0.5 { p.x = (origin.x - Double(d.width * cut.width / slackX)).clamped(to: -1...1) }
        if slackY > 0.5 { p.y = (origin.y - Double(d.height * cut.height / slackY)).clamped(to: -1...1) }
        return p
    }

    /// `origin` zoomed by `factor` about `anchor` — a point of the hole, 0…1
    /// each way, y down. What is under the anchor stays under it for as long
    /// as the picture still covers the hole; at the picture's edge the edge
    /// wins.
    nonisolated static func placement(_ origin: HalfFramePair.Placement, zoomedBy factor: Double,
                                      about anchor: CGPoint, source: CGSize,
                                      aspect: Double = 0.75) -> HalfFramePair.Placement {
        let turned = HalfFramePair.turned(source, by: origin)
        let was = HalfFramePair.sourceRect(for: origin, source: turned, aspect: aspect)
        var p = origin
        let from = origin.scale.clamped(to: HalfFramePair.Placement.scaleRange)
        p.scale = (from * factor).clamped(to: HalfFramePair.Placement.scaleRange)
        guard p.scale != from, was.width > 0, was.height > 0 else { return origin }
        let w = was.width * from / p.scale, h = was.height * from / p.scale
        // The source point under the anchor, and the cut that keeps it there.
        let cx = was.minX + anchor.x * was.width - anchor.x * w + w / 2
        let cy = was.minY + anchor.y * was.height - anchor.y * h + h / 2
        let slackX = (turned.width - w) / 2, slackY = (turned.height - h) / 2
        p.x = slackX > 0.5 ? Double((cx - turned.width / 2) / slackX).clamped(to: -1...1) : 0
        p.y = slackY > 0.5 ? Double((cy - turned.height / 2) / slackY).clamped(to: -1...1) : 0
        return p
    }

    /// The placement a hole is shown at: the gesture's while one is in
    /// flight or its develop is still to land, the written one otherwise.
    func shownPlacement(_ side: HalfFramePair.Side) -> HalfFramePair.Placement? {
        if let drag = pairDrag, drag.side == side { return drag.live }
        return pair?[side]?.placement
    }

    /// The gesture on `side`: the one in flight, or a new one from the
    /// written placement.
    private func placementGesture(_ side: HalfFramePair.Side, at n: CGPoint) -> PairDrag? {
        // Not across a turn made meanwhile (the Turn button writes at once).
        if var drag = pairDrag, drag.side == side,
           drag.live.quarterTurns == pair?[side]?.placement.quarterTurns { drag.settling = false; return drag }
        guard let hole = pair?[side], hole.exists, let whole = Self.pixelSize(of: hole.url) else { return nil }
        return PairDrag(side: side, start: n, origin: hole.placement,
                        source: hole.geometry.outputSize(for: whole), live: hole.placement)
    }

    func placementBegan(at n: CGPoint) -> Bool {
        guard pairPlacing, let side = pairLayer.side,
              let rect = pairHoleRects[side], rect.contains(n),
              var drag = placementGesture(side, at: n) else { return false }
        // A drag that follows a zoom carries on from where the zoom has it.
        pairPlacementTask?.cancel()
        drag = PairDrag(side: side, start: n, origin: drag.live, source: drag.source, live: drag.live)
        pairDrag = drag
        return true
    }

    func placementMoved(to n: CGPoint) {
        guard var drag = pairDrag, !drag.settling,
              let rect = pairHoleRects[drag.side], rect.width > 0, rect.height > 0 else { return }
        let d = CGSize(width: (n.x - drag.start.x) / rect.width, height: (n.y - drag.start.y) / rect.height)
        drag.live = Self.placement(drag.origin, draggedBy: d, source: drag.source, aspect: pair?.holeAspect ?? 0.75)
        pairDrag = drag
    }

    func placementEnded() { commitPlacement() }

    /// The wheel or the pinch, in the crop mode: the picked frame's picture
    /// is scaled under its hole about the pointer (about the hole's middle
    /// when the pointer is off it). Every scroll in the mode is this — the
    /// canvas's own pan would move the piece away from the hole being cut.
    func placementZoomed(by factor: Double, at n: CGPoint) -> Bool {
        guard pairPlacing, let side = pairLayer.side, factor.isFinite, factor > 0,
              var drag = placementGesture(side, at: n) else { return false }
        var anchor = CGPoint(x: 0.5, y: 0.5)
        if let rect = pairHoleRects[side], rect.width > 0, rect.height > 0, rect.contains(n) {
            anchor = CGPoint(x: (n.x - rect.minX) / rect.width, y: (n.y - rect.minY) / rect.height)
        }
        drag.live = Self.placement(drag.live, zoomedBy: factor, about: anchor, source: drag.source,
                                   aspect: pair?.holeAspect ?? 0.75)
        pairDrag = drag
        schedulePlacementCommit()
        return true
    }

    /// A slider's change to a placement: shown at once, written when the
    /// slider rests.
    func previewPlacement(_ side: HalfFramePair.Side, _ change: (inout HalfFramePair.Placement) -> Void) {
        guard var drag = placementGesture(side, at: .zero) else { return }
        change(&drag.live)
        drag.live.scale = drag.live.scale.clamped(to: HalfFramePair.Placement.scaleRange)
        drag.live.x = drag.live.x.clamped(to: -1...1)
        drag.live.y = drag.live.y.clamped(to: -1...1)
        pairDrag = drag
        schedulePlacementCommit()
    }

    private func schedulePlacementCommit() {
        pairPlacementTask?.cancel()
        pairPlacementTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            commitPlacement()
        }
    }

    /// Write the gesture: one undo step, one save, one develop. Its picture
    /// stays on the hole until that develop lands (`placementLanded`), so the
    /// hole does not fall back to the old crop in between.
    func commitPlacement() {
        pairPlacementTask?.cancel()
        guard var drag = pairDrag, !drag.settling else { return }
        guard pair?[drag.side]?.placement != drag.live else { pairDrag = nil; return }
        drag.settling = true
        pairDrag = drag
        lastUndoAt = .distantPast
        setPlacement(drag.side) { $0 = drag.live }
        // Never left up for good: a develop that fails says so elsewhere.
        pairPlacementTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, pairDrag?.settling == true else { return }
            pairDrag = nil
        }
    }

    /// The pair's print landed: a gesture that was waiting for it is done.
    func placementLanded() {
        guard pairDrag?.settling == true, !pairDecodeIsStale else { return }
        pairPlacementTask?.cancel()
        pairDrag = nil
    }
}

/// A placement drag in flight: where it started and what it has made so far.
struct PairDrag: Equatable, Sendable {
    let side: HalfFramePair.Side
    let start: CGPoint
    let origin: HalfFramePair.Placement
    let source: CGSize
    var live: HalfFramePair.Placement
    /// Written, and waiting for its develop: no longer the pointer's.
    var settling = false
}

// MARK: - entering a pair from a half frame, and the hole's own menu

extension Session {
    /// A half frame with its Film Edge format on "Half" can become the first
    /// frame of a pair: this is what the row under Format offers.
    var canEnterPair: Bool {
        guard pair == nil, let url = selection, !HalfFramePair.isPair(url), !batchExporting else { return false }
        return sidecar.params.filmEdge.format == .f135Half
    }

    /// Enter Half-Frame Pair: the frame on the canvas becomes the first hole
    /// of a new piece, cut as its half-frame crop cut it; the second hole is
    /// empty, with a + on it. The piece takes the frame's look, film edge
    /// included, and its orientation (a landscape half frame is the camera
    /// turned, so the holes are stacked).
    func enterPair() {
        guard canEnterPair, let frame = selection else { return }
        flushSave()
        let size = nativeSourceSize ?? Self.pixelSize(of: frame) ?? .zero
        let cut = sidecar.geometry.outputSize(for: size)
        makePair(first: frame, second: nil, look: sidecar,
                 turned: sidecar.params.filmEdge.effective ? cut.width > cut.height : size.width > size.height,
                 placement: sidecar.params.filmEdge.effective ? sidecar.geometry : nil, source: size,
                 keepFilmEdge: true)
    }

    /// The one place a pair is made: its file, its own settings, its place in
    /// the filmstrip, and then it is on the canvas.
    func makePair(first: URL?, second: URL?, look own: Sidecar?, turned: Bool,
                  placement: Geometry? = nil, source: CGSize = .zero, keepFilmEdge: Bool = false) {
        guard !batchExporting,
              let anchor = first ?? frames.first(where: { !HalfFramePair.isPair($0.id) })?.id else { return }
        let folder = anchor.deletingLastPathComponent()
        var p = HalfFramePair(folder: folder.standardizedFileURL.path)
        p.turned = turned
        if let first {
            // The frame's own crop and turn come with it (`Hole.geometry`),
            // so a half frame entered from its Film Edge crop sits under the
            // hole exactly as it was framed.
            p.left = Self.hole(for: first)
        }
        p.right = second.map(Self.hole(for:))
        var look = Sidecar()
        if let own { look.params = own.params }
        look.params.autoExposure = false
        look.params.exposureCompensationEV = 0
        look.params.filmFrame = FilmFrame.custom.id
        look.params.filmSide = FilmSide.long.rawValue
        look.params.sideLengthMM = 24
        if keepFilmEdge {
            look.params.filmEdge.format = .f135Half
        } else {
            look.params.filmEdge = FilmEdgeSettings()
        }
        look.params.dateBack.textB = ""
        p.onStrip = look.params.filmEdge.active
        look.state = .stale
        let url = HalfFramePair.newURL(in: folder)
        do {
            try p.save(to: url)
            try look.save(for: url)
        } catch {
            noteFailure(error, operation: "pair", frame: url.lastPathComponent)
            return
        }
        let after = first.flatMap { f in frames.firstIndex { $0.id == f } }
        insertFrame(Frame(id: url), at: after.map { $0 + 1 } ?? frames.count)
        click(url)
        if p.left != nil, p.right == nil { pairLayer = .right }
        status = L("Half-frame pair: add the second frame with the + on the empty hole.",
                   zh: "半格拼接：点击空格上的 + 添加第二张照片。")
    }

    /// A frame's crop as a placement under a hole of `aspect`: the same
    /// rectangle where the crop is level and unflipped, the middle otherwise.
    nonisolated static func placement(from g: Geometry, source: CGSize, aspect: Double) -> HalfFramePair.Placement {
        var p = HalfFramePair.Placement()
        guard source.width > 0, source.height > 0, g.quarterTurns % 4 == 0, !g.flipH, !g.flipV,
              abs(g.angle) < 0.01, !g.crop.isFull else {
            p.quarterTurns = ((g.quarterTurns % 4) + 4) % 4
            return p
        }
        let fit = HalfFramePair.sourceRect(for: p, source: source, aspect: aspect)
        let ch = g.crop.height * source.height, cw = ch * aspect
        p.scale = (fit.height / max(ch, 1)).clamped(to: HalfFramePair.Placement.scaleRange)
        let cut = HalfFramePair.sourceRect(for: p, source: source, aspect: aspect)
        let cx = (g.crop.x + g.crop.width / 2) * source.width, cy = (g.crop.y + g.crop.height / 2) * source.height
        let slackX = (source.width - cut.width) / 2, slackY = (source.height - cut.height) / 2
        _ = cw
        if slackX > 0.5 { p.x = Double((cx - source.width / 2) / slackX).clamped(to: -1...1) }
        if slackY > 0.5 { p.y = Double((cy - source.height / 2) / slackY).clamped(to: -1...1) }
        return p
    }

    /// A frame dropped on the canvas: into the hole under the pointer, or the
    /// first empty one, or — both full and dropped on the gap — nowhere.
    @discardableResult
    func dropFrame(_ url: URL, atNormalised n: CGPoint?) -> Bool {
        guard let p = pair, !batchExporting,
              let listed = pairCandidates.first(where: { $0.id.standardizedFileURL == url.standardizedFileURL })
        else { return false }
        let under = n.flatMap { point in pairHoleRects.first { $0.value.contains(point) }?.key }
        guard let side = under ?? HalfFramePair.Side.allCases.first(where: { p[$0] == nil }) else { return false }
        setHole(side, to: listed.id)
        return true
    }

    /// The picked frame's Scene Placement is the one the section shows:
    /// `params.sceneLatitude` and `sceneLatitudeOther` trade places when the
    /// other frame is picked. The wire is the same before and after, so this
    /// renders nothing; the Latitude readout is measured again for the frame.
    func pairLayerChanged() {
        guard pair != nil, let side = pairLayer.side else { return }
        let wantRight = side == .right
        guard sidecar.params.placementIsRight != wantRight else { return }
        let shown = sidecar.params.sceneLatitude
        sidecar.params.sceneLatitude = sidecar.params.sceneLatitudeOther
        sidecar.params.sceneLatitudeOther = shown
        sidecar.params.placementIsRight = wantRight
        scheduleSave()
        scheduleLatitudeRefresh()
    }

    /// The frame the Scene Placement section is about, as the Fit's region:
    /// the picked one, or the one last picked while the film is.
    var pairFitRegion: [Double]? {
        guard let p = pair else { return nil }
        let l = HalfFramePair.layout(holeHeight: 2400, spacingMM: p.effectiveSpacingMM, turned: p.turned)
        let r = l.normalisedRect(sidecar.params.placementIsRight ? .right : .left)
        return [Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)]
    }

    /// A frame put into, or taken out of, a hole starts with no placement:
    /// the curve was fitted to the scene that was there.
    func resetPlacement(of side: HalfFramePair.Side) {
        let isShown = (side == .right) == sidecar.params.placementIsRight
        if isShown { sidecar.params.sceneLatitude = SceneLatitudeSettings() }
        else { sidecar.params.sceneLatitudeOther = SceneLatitudeSettings() }
    }

    /// Held level (side by side) or turned (one above the other).
    func setPairTurned(_ turned: Bool) {
        updatePair(step: true) { $0.turned = turned }
    }

    /// Leave the pair for one of its frames, opened by itself.
    func openHoleAlone(_ side: HalfFramePair.Side) {
        guard let hole = pair?[side], hole.exists,
              let listed = frames.first(where: { $0.id.standardizedFileURL.path == hole.path }) else { return }
        click(listed.id)
    }

    /// The menu of the hole under the pointer (a right click picks it first).
    func pairContextMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = m.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
        }
        m.autoenablesItems = false
        if let side = pairLayer.side {
            if let hole = pair?[side] {
                add(L("Replace Frame…", zh: "替换照片…"), #selector(pairMenuPick))
                add(pairPlacing ? L("Done Cropping", zh: "完成裁剪") : L("Crop This Frame", zh: "裁剪这一格"),
                    #selector(pairMenuPlace), enabled: hole.exists)
                add(L("Turn Picture 90°", zh: "画面旋转 90°"), #selector(pairMenuTurnPicture))
                add(L("Reset Crop", zh: "重置裁剪"), #selector(pairMenuResetPlacement),
                    enabled: hole.placement != HalfFramePair.Placement())
                add(L("Remove Frame", zh: "移除照片"), #selector(pairMenuRemove))
                m.addItem(.separator())
                add(L("Open Frame Alone", zh: "单独打开照片"), #selector(pairMenuOpenAlone), enabled: hole.exists)
            } else {
                add(L("Add Frame…", zh: "添加照片…"), #selector(pairMenuPick))
            }
            m.addItem(.separator())
        }
        add(L("Swap the Two Frames", zh: "两格对调"), #selector(pairMenuSwap),
            enabled: pair?.left != nil || pair?.right != nil)
        add(pair?.turned == true ? L("Hold the Camera Level (Side by Side)", zh: "相机横持（左右并排）")
                                 : L("Turn the Camera (One Above the Other)", zh: "相机竖持（上下排列）"),
            #selector(pairMenuTurnCamera))
        m.addItem(.separator())
        add("Zoom to Fit", #selector(pairMenuFit), enabled: !zoomLocked)
        add("Export…", #selector(pairMenuExport), enabled: pair?.isComplete == true)
        return m
    }

    @objc private func pairMenuPick() { pairPicker = pairLayer.side }
    @objc private func pairMenuPlace() { togglePairPlacing() }
    @objc private func pairMenuTurnPicture() {
        if let s = pairLayer.side { setPlacement(s) { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } }
    }
    @objc private func pairMenuResetPlacement() {
        if let s = pairLayer.side { setPlacement(s) { $0 = HalfFramePair.Placement() } }
    }
    @objc private func pairMenuRemove() { if let s = pairLayer.side { setHole(s, to: nil) } }
    @objc private func pairMenuOpenAlone() { if let s = pairLayer.side { openHoleAlone(s) } }
    @objc private func pairMenuSwap() { swapHoles() }
    @objc private func pairMenuTurnCamera() { setPairTurned(!(pair?.turned ?? false)) }
    @objc private func pairMenuFit() { zoomToFit() }
    @objc private func pairMenuExport() { showExport = true }
}

// MARK: - a pair's frames, each with its own print and grade
//
// One negative, printed up to three times: the film's own print (the pair's
// settings), and each frame's where it differs. The three are graded — the
// film's Post-Dev, or the frame's own — and cut together along the frames'
// rectangles (`Renderer.compositePair`). The canvas draws the result with no
// grade of its own, and the export writes the same picture.

/// The enlarger's values a frame may have for itself.
enum EnlargerField: Sendable {
    case brightness, yellow, magenta, preflash
}

extension Session {
    private func value(_ f: EnlargerField, of t: HalfFramePair.PrintTrim) -> Double {
        switch f {
        case .brightness: t.brightnessStops
        case .yellow: t.yFilterShift
        case .magenta: t.mFilterShift
        case .preflash: t.preflashExposure
        }
    }

    private func set(_ f: EnlargerField, _ v: Double, in t: inout HalfFramePair.PrintTrim) {
        switch f {
        case .brightness: t.brightnessStops = v
        case .yellow: t.yFilterShift = v
        case .magenta: t.mFilterShift = v
        case .preflash: t.preflashExposure = v
        }
    }

    /// The film's own print: the pair's settings (a frame's, for a frame).
    private var filmPrint: HalfFramePair.PrintTrim { HalfFramePair.PrintTrim(sidecar.params) }

    /// The frame of a pair the right rail is about — its meter, its exposure,
    /// its white balance, its Scene Placement: the picked one, or with the
    /// film picked the one picked last. Nil for a frame, or an empty pair.
    var focusSide: HalfFramePair.Side? {
        guard let p = pair else { return nil }
        let wanted = pairLayer.side ?? (sidecar.params.placementIsRight ? .right : .left)
        if p[wanted] != nil { return wanted }
        return HalfFramePair.Side.allCases.first { p[$0] != nil }
    }

    var focusHole: HalfFramePair.Hole? { focusSide.flatMap { pair?[$0] } }

    /// Film Exposure as the Input / Camera section shows it: a frame's own
    /// (`exposure_compensation_ev`), or on a pair the picked frame's.
    var filmExposure: Double {
        get { focusHole?.exposureEV ?? params.exposureCompensationEV }
        set {
            if let side = focusSide, pair != nil { setHoleExposure(side, newValue); return }
            var p = params
            p.exposureCompensationEV = newValue
            params = p
        }
    }

    /// The picked frame's white balance or lens correction: written to the
    /// frame itself (the shot stays the frame's — it is the same shot in
    /// every pair and by itself), then the piece is laid out again.
    func setFocusDecode(_ decode: DecodeSettings) {
        guard let side = focusSide, let hole = pair?[side], decode != hole.decode else { return }
        var own = Sidecar.load(for: hole.url) ?? Sidecar()
        own.decode = decode
        if own.state == .processed { own.state = .stale }
        do { try own.save(for: hole.url) } catch {
            noteFailure(error, operation: "pair", frame: hole.url.lastPathComponent)
            return
        }
        renderer.store.invalidatePrint(for: hole.url)
        if frameStates[hole.url] == .processed { frameStates[hole.url] = .stale }
        updatePair { $0[side]?.decode = decode }
    }

    /// Whether any frame of the pair prints or grades differently from the
    /// film. When none does the piece is one print, drawn as a frame's is.
    var pairIsLayered: Bool {
        guard let p = pair else { return false }
        let film = HalfFramePair.PrintTrim(sidecar.params)
        return HalfFramePair.Side.allCases.contains { side in
            guard let hole = p[side] else { return false }
            return (hole.print != nil && hole.print != film)
                || (hole.adjustments != nil && hole.adjustments != sidecar.adjustments)
        }
    }

    /// The picked frame of a pair, when the rails are showing one.
    var pickedHole: HalfFramePair.Side? {
        guard let p = pair, let side = pairLayer.side, p[side] != nil else { return nil }
        return side
    }

    /// What the Enlarger shows: the picked frame's value, else the film's.
    func enlargerValue(_ f: EnlargerField) -> Double {
        if let side = pickedHole, let own = pair?[side]?.print { return value(f, of: own) }
        return value(f, of: filmPrint)
    }

    /// An Enlarger edit. On a frame of a pair it is that frame's; with the
    /// scope on *+ Film* the film's print moves by the same amount (answer
    /// B3), so the frame and the film around it stay as far apart as they
    /// were. Anywhere else it is the one print there is.
    func setEnlarger(_ f: EnlargerField, _ v: Double) {
        guard let side = pickedHole else {
            var t = filmPrint
            set(f, v, in: &t)
            // The first edit of the film's print with frames that follow it
            // moves them too: until a frame is given a print of its own the
            // piece prints as one.
            params = t.applied(to: params)
            return
        }
        let was = enlargerValue(f)
        guard v != was else { return }
        let scope = pair?[side]?.printScope ?? .film
        let film = filmPrint
        updatePair(redecode: false, rerender: false) { p in
            // Both frames get a print of their own first, so the other one
            // does not ride along with the film.
            for s in HalfFramePair.Side.allCases where p[s] != nil && p[s]?.print == nil { p[s]?.print = film }
            guard var own = p[side]?.print else { return }
            self.set(f, v, in: &own)
            p[side]?.print = own
        }
        if scope == .film {
            var t = film
            var moved = value(f, of: film) + (v - was)
            if f == .preflash { moved = moved.clamped(to: 0...0.03) }
            set(f, moved, in: &t)
            params = t.applied(to: params)          // renders, and the frames follow
        } else {
            recomposePair()
        }
    }

    /// Reset Enlarger: the picked frame's print back to neutral, else the film's.
    func resetEnlarger() {
        if let side = pickedHole {
            let film = filmPrint
            updatePair(redecode: false, rerender: false, step: true) { p in
                for s in HalfFramePair.Side.allCases where p[s] != nil && p[s]?.print == nil { p[s]?.print = film }
                p[side]?.print = HalfFramePair.PrintTrim()
            }
            recomposePair()
        } else {
            params = HalfFramePair.PrintTrim().applied(to: params)
        }
    }

    var enlargerScope: HalfFramePair.Scope {
        get { pickedHole.flatMap { pair?[$0]?.printScope } ?? .film }
        set { if let side = pickedHole { updatePair(redecode: false, rerender: false) { $0[side]?.printScope = newValue } } }
    }

    var exposureScope: HalfFramePair.Scope {
        get { focusHole?.exposureScope ?? .frame }
        set { if let side = focusSide { updatePair(redecode: false, rerender: false) { $0[side]?.exposureScope = newValue } } }
    }

    /// The grade the Post-Dev rail is editing: the picked frame's own (the
    /// film's until it is given one), else the film's.
    var layerAdjustments: Adjustments {
        get { pickedHole.flatMap { pair?[$0]?.adjustments } ?? sidecar.adjustments }
        set {
            guard let side = pickedHole else { adjustments = newValue; return }
            guard newValue != layerAdjustments else { return }
            updatePair(redecode: false, rerender: false) { $0[side]?.adjustments = newValue }
            recomposePair()
        }
    }

    /// The grade the export applies after the engine: none on a pair, whose
    /// frames are already graded in the picture it is handed.
    var exportAdjustments: Adjustments { pairIsLayered ? Adjustments() : adjustments }

    /// The pair's picture at `tier`, from the engine's print of it: each
    /// frame printed and graded as its own, cut together. Nil when it could
    /// not be made, and the caller keeps the print it has.
    func pairLayered(base: MTLTexture, tier: String) async -> MTLTexture? {
        guard let p = pair, pairIsLayered, let sid = serviceSessionID, let url = selection else { return nil }
        let film = scheduler.sent
        var deltas: [[String: ParamValue]] = [], sides: [HalfFramePair.Side] = []
        var restore: [String: ParamValue] = [:]
        for side in HalfFramePair.Side.allCases {
            guard let own = p[side]?.print, own != HalfFramePair.PrintTrim(film) else { continue }
            let printed = own.applied(to: film)
            deltas.append(printed.delta(from: film).delta)
            restore.merge(film.delta(from: printed).delta) { a, _ in a }
            sides.append(side)
        }
        var prints: [HalfFramePair.Side: MTLTexture] = [:]
        if !deltas.isEmpty {
            // Each delta is from the film's print, so each layer is set from
            // the film's values: put them back between layers too.
            var layers: [[String: ParamValue]] = []
            for d in deltas { layers.append(restore.merging(d) { _, new in new }) }
            guard let textures = try? await client.renderLayers(sessionID: sid, tier: tier, layers: layers,
                                                                restore: restore) else { return nil }
            for (side, t) in zip(sides, textures) { if let texture = t.texture { prints[side] = texture } }
        }
        guard selection == url, pair != nil else { return nil }
        var rects = pairHoleRects
        if sidecar.params.filmEdge.effective {
            let gates = (try? await client.overscanGates()) ?? []
            guard selection == url else { return nil }
            pairGates = gates
            rects = pairHoleRects
        }
        guard let ra = rects[.left], let rb = rects[.right] else { return nil }
        // Grade: the film's own, and each frame's where it has one (or a
        // print of its own to grade).
        let filmGrade = sidecar.adjustments
        guard let graded = renderer.applyAdjustments(filmGrade, to: base) else { return nil }
        func layer(_ side: HalfFramePair.Side) -> MTLTexture? {
            let own = p[side]?.adjustments
            guard prints[side] != nil || (own != nil && own != filmGrade) else { return nil }
            return renderer.applyAdjustments(own ?? filmGrade, to: prints[side] ?? base)
        }
        return renderer.compositePair(base: graded, first: layer(.left), firstRect: ra,
                                      second: layer(.right), secondRect: rb)
    }

    /// The print on the canvas made again from the engine's last one: a
    /// frame's print or grade changed and the negative did not.
    func recomposePair() {
        // The canvas grades the piece itself while it is one print, and
        // leaves a cut-together picture alone.
        pushLayer2(sidecar.adjustments)
        guard pair != nil, let last = pairLastRender else { requestPrint(); return }
        guard pairIsLayered else {
            // Back to one print: the engine's own, if a composite is showing.
            pairComposeTask?.cancel()
            if pairShowsComposite { applyRender(last.outcome, generation: last.generation, composed: true) }
            pairShowsComposite = false
            return
        }
        pairComposeTask?.cancel()
        pairComposeTask = Task {
            // A drag sets the value dozens of times; one print per pause.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await composePairRender(last.outcome, generation: last.generation)
        }
    }

    /// An engine print of a pair, on its way to the canvas.
    func composePairRender(_ outcome: RenderOutcome, generation: Int) async {
        guard let base = outcome.texture, generation == serviceGeneration else {
            applyRender(outcome, generation: generation, composed: true)
            return
        }
        pairLastRender = (outcome, generation)
        let composite = await pairLayered(base: base, tier: outcome.response.tier)
        guard generation == serviceGeneration, pair != nil else { return }
        pairShowsComposite = composite != nil
        applyRender(RenderOutcome(response: outcome.response, texture: composite ?? base,
                                  progress: outcome.progress),
                    generation: generation, composed: true)
    }
}
