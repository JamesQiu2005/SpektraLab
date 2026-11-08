//  CropScreen.swift — Crop: the operating system Photos' crop, in SpektraLab's own parts (2026-10-20).
//
//  The owner: "The crop page should also take inspiration directly from how
//  the app system library behaves, we copy its UX but not its UI"
//  (`the operating system_system_library_crop_reference/`: IMG_6817, IMG_6818, and Capture One
//  for the guides). What is Photos' here is the behaviour:
//
//  - **The crop stays level and in the middle; the picture moves under it.**
//    A finger inside the crop pans the picture, two fingers zoom it, a corner
//    or an edge sizes the crop — and when that finger lifts, the crop grows
//    back to fill the room and the picture glides with it (`StageMapping`).
//  - **Cancel and Done at the top**; under them Flip and Rotate (a quarter turn
//    to the left), Reset in the middle when there is something to reset, and
//    the ratio on the right. **There is no Auto**: the owner's rule, in bold,
//    "There should never be auto crop feature". Nothing on this page looks at
//    the picture to decide anything.
//  - **The dials**: Straighten, and on a RAW in Develop's crop Vertical and
//    Horizontal (Photos' own names for its two perspective dials) — round
//    buttons that pick what the dial under them turns, the value inside the
//    picked one, a tap on a picked one that is turned sends it home.
//  - **The ratio** (IMG_6818): Original, Freeform, Square and the ratios,
//    and the orientation as two shapes. A locked ratio shows a lock on the
//    crop when the page is back on the dials — tap it to set the crop free.
//  - **The guides** (参考线, Capture One's keystone, a RAW in Develop only):
//    drawn out of their own drawer — two horizontals that should be
//    parallel, two verticals, or the four corners of what should be a
//    rectangle — each point a circle round the point that turns into a loupe
//    of the picture under it while it moves; once a line has moved, Apply
//    appears in the middle of the picture and corrects the perspective
//    (`CropGuides`).
//
//  **Two entries, one page, two records** (the owner: "the develop crop
//  manoeuvres the image itself, and the edit crop manage the edited image").
//  Develop's crop (`.source`) cuts the picture before the film —
//  `FrameEdit.geometry`, which the engine meters after; Edit's (`.finished`)
//  cuts the finished picture, in its film edge if it has one —
//  `FrameEdit.printCrop`, which nothing develops. Each page edits a copy of
//  its own record and nothing else: **Cancel leaves the frame exactly as it
//  was** (nothing was written), Done writes that one record, and the other
//  crop is never touched. Under a film edge Develop's crop box is held; on the Mac the film's
//  gate stands in its place and the picture is placed under it (`filmStage`, 2026-10-25).
//
//  What is SpektraLab's is the look: the page's black, its card colour, the
//  accent Done and dial mark (`Theme`), its tick dial (`TickRuler`), its
//  chips, and Apple's own symbols.
//
//  Nothing renders while anything here moves: the picture is the one the frame
//  already has, drawn through the map. Done writes the record; the develop
//  page's session takes it and asks for one develop (Develop's crop) or none
//  (Edit's, which the pages draw through).

import SwiftUI

/// Which crop the page makes.
enum CropTarget: Sendable, Equatable, Hashable {
    /// Develop's: the picture before the film (`FrameEdit.geometry`).
    case source
    /// Edit's: the finished picture, film edge and all (`FrameEdit.printCrop`).
    case finished
}

struct CropScreen: View {
    let frameID: LibraryFrame.ID
    var target: CropTarget = .source
    /// The crop the page opens with, in place of the frame's own. Snapshot
    /// harness only (the drawing's 4:5).
    var snapshotGeometry: Geometry? = nil
    /// the crop made in the develop page, laid over
    /// it as `CropPlacement` says (`InlineCrop`); nil for the page of its own (a cover).
    var inline: CropPlacement? = nil
    /// Inline: the header's Crop pressed while the crop is open; each one finishes it as Done does.
    var finishes = 0

    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router

    init(frameID: LibraryFrame.ID, target: CropTarget = .source, snapshotGeometry: Geometry? = nil,
         inline: CropPlacement? = nil, finishes: Int = 0) {
        self.frameID = frameID
        self.target = target
        self.snapshotGeometry = snapshotGeometry
        self.inline = inline
        self.finishes = finishes
    }

    var body: some View {
        if let inline {
            // In the develop page: no ground of its own, the page's is under it.
            if let frame = library.frame(frameID) { page(frame, inline: inline) { router.inlineCrop = nil } }
        } else {
            ZStack {
                Theme.background.ignoresSafeArea()
                if let frame = library.frame(frameID) { page(frame, inline: nil) { router.dismissCover() } }
            }
        }
    }

    private func page(_ frame: LibraryFrame, inline: CropPlacement?, close: @escaping () -> Void) -> some View {
        let size = imageSize(frame)
        return CropPage(frame: frame, target: target, imageSize: size,
                        opened: snapshotGeometry ?? (target == .source ? frame.edit.geometry : frame.edit.printCrop.onFinished(size)),
                        inline: inline, finishes: finishes, close: close)
    }

    /// The picture the crop is made in, in its own units: the source's pixels,
    /// or the finished picture's (its develop's, or a size of its shape).
    private func imageSize(_ frame: LibraryFrame) -> CGSize {
        switch target {
        case .source: CGSize(width: frame.originalSize.width, height: frame.originalSize.height)
        case .finished:
            // The develop page's own develop where it is open: it is ahead of the frame's kept one.
            DevelopedFrameView.finishedSize(frame: frame, edit: frame.edit, model: model,
                                            developed: model.openSession(frame.id)?.developed)
        }
    }
}

// MARK: - the page

private struct CropPage: View {
    let frame: LibraryFrame
    let target: CropTarget
    let imageSize: CGSize
    /// The record as it was when the page opened: what Cancel leaves.
    let opened: Geometry
    /// laid in the develop page (`CropScreen.inline`); nil on a page of its own.
    let inline: CropPlacement?
    /// Inline: the header's Crop pressed while open, each a Done.
    let finishes: Int
    /// Cancel's and Done's way out: the cover dismissed, or the develop page's crop closed.
    let close: () -> Void

    enum Dial: CaseIterable, Identifiable { case straighten, vertical, horizontal; var id: Self { self } }

    /// What a finger is doing on the picture.
    private enum Drag {
        /// Sizing the crop by a corner or an edge; the map is held still meanwhile.
        case handle(CropHandle, base: Geometry, start: CGPoint)
        /// Moving the picture under the crop.
        case pan(base: Geometry, mapping: StageMapping)
        /// Moving a guide's point; `from` is where it was, on the screen.
        case point(Int, from: CGPoint)
        /// Mac: ⌘ held at the press — a reference line drawn from `from`, levelled when it lifts.
        case line(from: CGPoint)
    }

    @State private var geometry: Geometry
    /// The quarter turns as this page has counted them — never reduced, so a
    /// turn glides the short way.
    @State private var turns: Int
    @State private var frozen: StageMapping?
    @State private var drag: Drag?
    @State private var pinchBase: Geometry?
    /// Mac: the crop and the stage's map when a scroll zoom began.
    @State private var scrollBase: (geometry: Geometry, mapping: StageMapping)?
    /// The scroll's travel already applied (`scrollZoom`): each step zooms the crop as it is now.
    @State private var scrollApplied: CGFloat = 0
    /// Two fingers were down during this drag: the one left down moves nothing.
    @State private var pinched = false
    @State private var dial: Dial = .straighten
    @State private var dialing = false
    @State private var touching = false
    // The guides (参考线).
    /// The mode whose lines are out; nil while none is.
    @State private var guideMode: CropGuides.Mode?
    /// Its four points: two lines' two each, or the rectangle's corners.
    @State private var points: [CGPoint] = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 4)
    @State private var guidesMoved = false
    /// Counts the drawer's pulls, so a line taken away late does not take a newer one.
    @State private var pulls = 0
    @State private var held: Int?
    /// Mac: the page's own Undo and Redo (`MacFlowHistory`).
    @State private var macHistory: MacFlowHistory<Step>
    /// Mac: the ⌘-drag's reference line, on the screen, while it is drawn.
    @State private var refLine: RefLine?
    /// Mac: the crosshair is up because ⌘ is held over the picture.
    @State private var crossCursor = false
    // Mac, under a film edge: the gate in the crop box's place (`filmStage`).
    /// The framing when a drag began, and how far the pointer had already travelled then.
    @State private var placeBase: (framing: Geometry, travelled: CGSize)?
    /// The framing when a pinch or a scroll zoom began.
    @State private var enlargeBase: Geometry?
    /// The picture carried past the end of its cut's travel, in points (the Frame step's rubber band).
    @State private var nudge = CGSize.zero
    /// The picture's place under the film's gate (`FilmEdgeSettings.framing`), as this page has it:
    /// what the film-edge flow's Frame step wrote, placed here on the Mac (`heldByFilm`).
    @State private var framing: Geometry?

    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var calm

    init(frame: LibraryFrame, target: CropTarget, imageSize: CGSize, opened: Geometry,
         inline: CropPlacement? = nil, finishes: Int = 0, close: @escaping () -> Void) {
        self.frame = frame
        self.target = target
        self.imageSize = imageSize
        self.opened = opened
        self.inline = inline
        self.finishes = finishes
        self.close = close
        _geometry = State(initialValue: opened)
        _turns = State(initialValue: ((opened.quarterTurns % 4) + 4) % 4)
        let kept = target == .source ? frame.edit.filmEdge.framing : nil
        _framing = State(initialValue: kept)
        _macHistory = State(initialValue: MacFlowHistory(Step(geometry: opened, turns: ((opened.quarterTurns % 4) + 4) % 4,
                                                              framing: kept)))
    }

    /// Vertical and Horizontal: a RAW, in Develop's crop (the owner: "enabled
    /// for the RAW image only"; "No pan / tilt in the edit crop").
    private var allowsPerspective: Bool { target == .source && frame.isRAW }
    /// Develop's crop box is held while a film edge frames the picture (its straighten, keystone, turns and
    /// flips are not: they apply to the picture in the gate, 2026-10-25). The crop box is then replaced by
    /// the film's gate, and the picture is placed under it here — the Frame step's hand, brought into the
    /// crop (the owner, 2026-10-25: "the crop frame is replaced by the film overscan frames (as selected),
    /// note that this does not affect the edit crop frame"). Edit's crop (`.finished`) is never this.
    private var heldByFilm: Bool { target == .source && frame.edit.filmEdge.effective }
    private var dials: [Dial] { allowsPerspective ? Dial.allCases : [.straighten] }
    private var glide: Animation? { calm ? nil : .spring(response: 0.38, dampingFraction: 0.86) }

    var body: some View {
        Group {
            // Mac (the owner, 2026-10-25): the controls are an inspector, every part out at once.
            if let inline { inlinePage(inline) } else { macCoverPage }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        // Inline: the header's Crop finishes the crop, as Done does.
        .onChange(of: finishes) { _, _ in done() }
        .onChange(of: Step(geometry: geometry, turns: turns, framing: framing)) { _, now in macHistory.observe(now) }
        .onChange(of: touching || dialing || scrollBase != nil || enlargeBase != nil) { _, now in macHistory.busy = now }
        // ⌘Z and ⇧⌘Z in the menu bar's Edit menu are this page's while it is in front.
        .macFlowUndo(undo: { macUndo() }, redo: { macRedo() })
        #if DEBUG
        // MacDriver's `crop.rotate`: Rotate pressed, for a check without a mouse.
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.cropRotate)) { _ in
            withAnimation(glide) { geometry = geometry.turned(by: -1); turns -= 1 }
        }
        // `crop.flip`: Flip pressed.
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.cropFlip)) { _ in
            withAnimation(glide) { geometry.flipH.toggle() }
        }
        #endif
    }

    /// the crop in the develop page. "We don't
    /// need another page that pops up, they simply replace the assets temporarily resting in the previous
    /// left side bar with the crop related settings … and we squeeze it a bit more so that there's not
    /// much space between them." The page's controls one under another at the top of the column, under
    /// its header, in the order the column page had them — Cancel ↺ ↶ ↷ Done, the tools and the name, the
    /// size, the dials — with no room spread between; the crop itself where the picture was. The page
    /// covers the develop page whole and draws only those two parts (`CropPlacement`).
    private func inlinePage(_ p: CropPlacement) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                sideControls
                    .frame(width: p.columnWidth, height: max(h - p.columnTop, 0), alignment: .top)
                    .background(Theme.background)
                    .padding(.top, p.columnTop)
                stage(CGSize(width: max(w - p.columnWidth - 1, 0), height: max(h - p.pictureTop, 0)))
                    .padding(.leading, p.columnWidth + 1)
                    .padding(.top, p.pictureTop)
            }
        }
    }

    /// The column's controls: the Mac's inspector, else the page's own, close together.
    @ViewBuilder private var sideControls: some View {
        macInspector
    }

    // MARK: top: Cancel, the page's name, Done

    private static let barHeight: CGFloat = MacFlowBar.height

    /// The state Undo and Redo walk on the Mac: the crop and the page's count of quarter turns.
    struct Step: Equatable {
        var geometry: Geometry
        var turns: Int
        /// Under a film edge on the Mac, the picture's place under the gate: one more state Undo walks.
        var framing: Geometry? = nil
    }

    @ViewBuilder private var topBar: some View {
        // Mac (the owner, 2026-10-23): Cancel · ↺ ↶ ↷ · Done, the name in the tool row under it.
        GeometryReader { geo in
            MacFlowBar(width: geo.size.width, title: nil, cancel: { close() },
                       canReset: changed, reset: { reset() },
                       canUndo: macHistory.canUndo, undo: { macUndo() },
                       canRedo: macHistory.canRedo, redo: { macRedo() },
                       action: L("Done"), actionID: "crop.done") { done() }
        }
    }

    private func macUndo() {
        guard let s = macHistory.undo() else { return }
        #if DEBUG
        if MacScrollZoom.logs { NSLog("macflow crop undo to width %.4f centre %.4f,%.4f turns %d", s.geometry.crop.width, s.geometry.centre.x, s.geometry.centre.y, s.turns) }
        #endif
        withAnimation(glide) { geometry = s.geometry; turns = s.turns; framing = s.framing }
    }

    private func macRedo() {
        guard let s = macHistory.redo() else { return }
        #if DEBUG
        if MacScrollZoom.logs { NSLog("macflow crop redo to width %.4f centre %.4f,%.4f turns %d", s.geometry.crop.width, s.geometry.centre.x, s.geometry.centre.y, s.turns) }
        #endif
        withAnimation(glide) { geometry = s.geometry; turns = s.turns; framing = s.framing }
    }

    /// The two crops of this frame, as one control: the pre-film crop (`FrameEdit.geometry`, what the film
    /// and the meter see) and the finished picture's (`printCrop`). One click apart, in the crop page's
    /// name both in the inspector and in the narrow window's bar (the owner, 2026-10-26: "Pre-film always;
    /// Edit keeps its own"). What is under way is not carried across — each is the crop it names.
    private var cropTargetSwitch: some View {
        HStack(spacing: 0) {
            ForEach([CropTarget.source, .finished], id: \.self) { side in
                Button { switchCrop(to: side) } label: {
                    Text(side == .source ? L("The picture, before the film") : L("The finished picture"))
                        .font(Theme.Font.ui(12, target == side ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(target == side ? Theme.onSelection : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background { if target == side { Capsule().fill(Theme.selection) } }
                        .padding(.horizontal, 2)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(target == side ? .isSelected : [])
                .accessibilityIdentifier("crop.target.\(side == .source ? "source" : "finished")")
            }
        }
        .background { Capsule().fill(Theme.card).frame(height: 30) }
        .fixedSize()
    }

    /// The other crop of this frame (`cropTargetSwitch`): a wide develop page takes it in place, anywhere
    /// else it is the cover (`AppRouter.show`).
    private func switchCrop(to side: CropTarget) {
        guard side != target else { return }
        router.show(side == .source ? .crop(frame.id) : .printCrop(frame.id))
    }

    /// Whether Reset has anything to take back.
    private var changed: Bool { !geometry.isIdentity || geometry.aspect != .free || (heldByFilm && framing != nil) }

    private func reset() {
        withAnimation(glide) {
            geometry = .default
            // Under the gate: the largest cut about the middle, as a film edge starts.
            if heldByFilm { framing = nil }
            // Home by the short way round.
            turns = Int((Double(turns) / 4).rounded()) * 4
            guideMode = nil; guidesMoved = false
        }
    }

    // MARK: the picture, and the crop over it

    /// The crop's room: the stage less a margin for the corners' grip.
    private func room(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 22)
    }

    private func rest(_ size: CGSize) -> StageMapping {
        // Mac (the owner, 2026-11-05): Capture One's crop — the whole picture fitted in the stage and
        // the crop moved over it, never the crop filling the stage with the picture past its edges.
        StageMapping.whole(geometry, imageSize: imageSize, room: room(size), turns: turns)
    }

    private var guidesShown: Bool {
        // Mac: no drawer to pull them out of; a mode picked in the inspector puts its lines out.
        guideMode != nil
    }

    /// The crop box over the picture; on the Mac under a film edge, the film's gate in its place.
    @ViewBuilder private func stage(_ size: CGSize) -> some View {
        if heldByFilm, let film { filmStage(film, size: size) } else { cropStage(size) }
    }

    private func cropStage(_ size: CGSize) -> some View {
        let mapping = frozen ?? rest(size)
        let state = StageState(mapping: mapping, crop: geometry.crop, angle: geometry.angle,
                               vertical: geometry.vertical, horizontal: geometry.horizontal,
                               points: points, pointScale: guidesShown ? 1 : 0, loupe: held == nil ? 0 : 1)
        let box = mapping.box(geometry, imageSize: imageSize)
        return ZStack(alignment: .topLeading) {
            CropStageView(state: state, base: geometry, imageSize: imageSize, area: size,
                          dim: touching || dialing ? 0.42 : 0.62,
                          grid: dialing && dial == .straighten ? 2 : (touching || dialing ? 1 : 0),
                          lines: guidesShown ? visibleLines : [], held: held) { long in
                picture(long)
            }
            if geometry.aspect != .free, !guidesShown {
                lockBadge.position(x: box.maxX - 20, y: box.minY + 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if guidesShown, guidesMoved, held == nil, !visibleLines.isEmpty {
                applyPill.position(x: size.width / 2, y: size.height / 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            if let refLine { RefLineView(line: refLine).allowsHitTesting(false) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        // Mac: a wheel or a two-finger scroll zooms the picture under the crop about the pointer
        // (Sources/Mac/MacScrollZoom.swift), as two fingers do about their middle.
        .macScrollZoom { phase, dy, at in scrollZoom(phase, travel: dy, at: at, size: size) }
        // Mac: ⌘ held over the picture is the ⌘-drag's crosshair (set at each move: UIKit sets its own).
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if MacKeys.command { MacCursor.crosshair(); crossCursor = true }
                else if crossCursor { MacCursor.arrow(); crossCursor = false }
            case .ended:
                if crossCursor, drag == nil { MacCursor.arrow(); crossCursor = false }
            }
        }
        #if DEBUG
        // MacDriver's `crop.line.<deg>`: a ⌘-drag's line through the stage's middle at that angle on the
        // screen, shown for 2 s, then levelled through the same function the drag's release calls.
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.cropLine)) { n in
            guard let deg = n.object as? Double else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) * 0.35, t = deg * .pi / 180
            let line = RefLine(a: CGPoint(x: c.x - r * cos(t), y: c.y - r * sin(t)), b: CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t)))
            refLine = line
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refLine = nil; level(line, size: size) }
        }
        #endif
        .gesture(stageDrag(size).simultaneously(with: pinch(size)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: guidesMoved)
        .animation(.easeOut(duration: 0.2), value: geometry.aspect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Crop, ") + sizeText)
    }

    /// The whole picture the crop is made in: the source before the film, or
    /// the finished picture without Edit's crop.
    @ViewBuilder private func picture(_ points: CGFloat) -> some View {
        switch target {
        case .source:
            FramePicture(picture: frame.picture, pointSize: points, contentMode: .fit)
        case .finished:
            // As the develop page's canvas has it: the page's own develop, which is ahead
            // of the frame's kept one, with Edit's layer laid on live where it has one.
            let session = model.openSession(frame.id)
            let base = DevelopedFrameView(frame: frame, edit: session?.edit, pointSize: points,
                                          developed: session?.developed, cropsPrint: false)
            if let session, session.edit.adjustments.isActive, session.layer2.picture != nil {
                Layer2Picture(live: session.layer2, pointSize: points) { base }
            } else {
                base
            }
        }
    }

    private var lockBadge: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { geometry.aspect = .free }
        } label: {
            Image(systemName: "lock.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)       // on the dark disc over the picture, in Light Mode too
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.55)))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(L("Ratio locked") + ", " + ratioName(geometry.aspect))
        .accessibilityHint(L("Unlock the ratio"))
        .accessibilityIdentifier("crop.lock")
    }

    private var applyPill: some View {
        Button { apply() } label: {
            Text(L("Apply", as: "the guides")).font(Theme.Font.ui(15, .semibold))
                .foregroundStyle(Theme.onSelection)
                .padding(.horizontal, 22).frame(height: 38)
                .background(Capsule().fill(Theme.accent))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .frame(minHeight: 44).contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier("crop.apply")
    }

    // MARK: between the screen and the picture

    private var keystone: Keystone { geometry.keystone(in: imageSize) }

    /// A screen point, in the corrected frame, normalised.
    private func corrected(_ screen: CGPoint, _ m: StageMapping) -> CGPoint {
        let p = m.corrected(screen)
        return CGPoint(x: p.x / max(imageSize.width, 1), y: p.y / max(imageSize.height, 1))
    }

    /// A guide's point (on the source, normalised) on the screen.
    private func screen(guide p: CGPoint, _ m: StageMapping) -> CGPoint {
        m.screen(keystone.corrected(CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)))
    }

    /// A screen point as a guide's point: on the source, normalised, kept on it.
    private func guide(screen s: CGPoint, _ m: StageMapping) -> CGPoint {
        let p = keystone.source(m.corrected(s))
        return CGPoint(x: (p.x / max(imageSize.width, 1)).clamped(to: 0...1),
                       y: (p.y / max(imageSize.height, 1)).clamped(to: 0...1))
    }

    // MARK: gestures

    /// A guide's point, a corner or an edge, or the picture under the crop.
    private func stageDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard pinchBase == nil, !pinched else { return }
                let m = rest(size)
                if drag == nil {
                    // Mac (the owner, 2026-10-25): "cmd + drag for a quick reference line on what should
                    // be horizontal" — ⌘ at the press draws a line instead of taking the crop or the picture.
                    drag = MacKeys.command ? .line(from: v.startLocation) : grab(v.startLocation, m)
                    #if DEBUG
                    if MacScrollZoom.logs { NSLog("maccrop press, ⌘ %d", MacKeys.command ? 1 : 0) }
                    #endif
                    guard let drag else { return }
                    switch drag {
                    case .line:
                        MacCursor.crosshair(); crossCursor = true
                    case .point(let i, _):
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { held = i }
                    case .handle:
                        frozen = m
                        withAnimation(.easeOut(duration: 0.15)) { touching = true }
                    case .pan:
                        withAnimation(.easeOut(duration: 0.15)) { touching = true }
                    }
                }
                guard let drag else { return }
                let t = v.translation
                switch drag {
                case .line(let from):
                    refLine = RefLine(a: from, b: v.location)
                    MacCursor.crosshair()
                case .point(let i, let from):
                    // The point moves with the finger, wherever on its circle it was taken.
                    points[i] = guide(screen: CGPoint(x: from.x + t.width, y: from.y + t.height), m)
                    // Apply comes up once a line has moved — in its own moment, so the
                    // point under the finger is not carried along by its animation.
                    if !guidesMoved { DispatchQueue.main.async { guidesMoved = true } }
                case .handle(let handle, let base, let start):
                    guard let held = frozen else { return }
                    let now = corrected(v.location, held)
                    // The handle keeps its offset from the finger, in the crop's own unrotated frame.
                    let a = base.unrotated(start, in: imageSize), b = base.unrotated(now, in: imageSize)
                    let c = base.crop, pos = handle.position
                    let target = CGPoint(x: c.x + pos.x * c.width + (b.x - a.x), y: c.y + pos.y * c.height + (b.y - a.y))
                    geometry = base.resized(handle: handle, to: target, in: imageSize)
                    #if DEBUG
                    if MacScrollZoom.logs {
                        let c = geometry.crop
                        NSLog("maccrop %@ crop x %.4f…%.4f y %.4f…%.4f", handle.rawValue, c.x, c.x + c.width, c.y, c.y + c.height)
                    }
                    #endif
                case .pan(let base, let held):
                    let a = corrected(v.startLocation, held), b = corrected(v.location, held)
                    // Mac: the picture stays put and the crop follows the pointer over it.
                    geometry = base.moved(by: CGSize(width: b.x - a.x, height: b.y - a.y), in: imageSize)
                }
            }
            .onEnded { _ in pinched = false; finishDrag(size) }
    }

    private func finishDrag(_ size: CGSize) {
        defer { drag = nil }
        guard let drag else { return }
        switch drag {
        case .line:
            if let line = refLine { level(line, size: size) }
            refLine = nil
            if !MacKeys.command { MacCursor.arrow(); crossCursor = false }
        case .point:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { held = nil }
        case .handle, .pan:
            // The crop grows back to fill the room, the picture with it.
            withAnimation(glide) { frozen = nil; touching = false }
        }
    }

    /// What a finger landing at `p` takes: a guide's point first (while the
    /// drawer is out), then a corner or an edge, then the picture inside the crop.
    private func grab(_ p: CGPoint, _ m: StageMapping) -> Drag? {
        if guidesShown {
            let near = visiblePointIndices
                .map { ($0, screen(guide: points[$0], m)) }
                .filter { hypot($0.1.x - p.x, $0.1.y - p.y) <= 30 }
                .min { hypot($0.1.x - p.x, $0.1.y - p.y) < hypot($1.1.x - p.x, $1.1.y - p.y) }
            if let near { return .point(near.0, from: near.1) }
        }
        let c = corrected(p, m)
        // The grab is ±22 pt round a corner, whatever the picture's scale.
        guard let handle = geometry.handle(at: c, in: imageSize, tolerance: 22 / max(m.scale, 0.0001)) else { return nil }
        if handle == .body { return .pan(base: geometry, mapping: m) }
        return .handle(handle, base: geometry, start: c)
    }

    /// Two fingers zoom the picture under the crop: the crop is made smaller
    /// on the picture by as much, about its middle, keeping its shape.
    private func pinch(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil {
                    if drag != nil { finishDrag(size) }
                    pinchBase = geometry; pinched = true; frozen = nil; held = nil
                    withAnimation(.easeOut(duration: 0.15)) { touching = true }
                }
                guard let base = pinchBase else { return }
                var g = base
                // Mac: the picture stays put, so spreading the fingers makes the crop larger on it.
                let m = 1 / max(v.magnification, 0.05)
                let minW = Geometry.minSide / max(imageSize.width, 1), minH = Geometry.minSide / max(imageSize.height, 1)
                let w = max(base.crop.width / m, minW), h = max(base.crop.height / m, minH)
                let c = base.centre
                g.crop = CropRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
                g = g.fitted(in: imageSize)
                // Zooming is the user sizing the crop: remembered, as a resize is.
                g.intendedSize = CGSize(width: g.crop.width, height: g.crop.height)
                geometry = g
            }
            .onEnded { _ in
                pinchBase = nil
                withAnimation(.easeOut(duration: 0.2)) { touching = false }
            }
    }

    /// Mac: a scroll zooms as the pinch does — the crop made smaller on the picture by as much,
    /// keeping its shape — but about the pointer: the point of the picture under it stays under
    /// it. 100 pt of travel is ×1.8, as on the develop page. Step by step, from the crop as it is
    /// (2026-11-05): from the session's start, travel spent against the smallest or the largest crop
    /// had to be paid back before a turn the other way did anything, and a session could not grow
    /// the crop more than 20 times.
    private func scrollZoom(_ phase: MacScrollZoom.Phase, travel: CGFloat, at p: CGPoint, size: CGSize) {
        switch phase {
        case .began, .changed:
            if scrollBase == nil {
                guard drag == nil, pinchBase == nil else { return }
                scrollBase = (geometry, rest(size))
                scrollApplied = 0
                frozen = nil; held = nil
                withAnimation(.easeOut(duration: 0.15)) { touching = true }
            }
            guard let base = scrollBase else { return }
            let step = travel - scrollApplied
            scrollApplied = travel
            guard step != 0 else { return }
            // The picture stays put (`StageMapping.whole`): the scroll that zooms the develop page's
            // picture in makes the crop larger on it, about the pointer.
            geometry = Self.zoomed(geometry, by: exp(-step * 0.006), about: corrected(p, base.mapping), in: imageSize)
            #if DEBUG
            if MacScrollZoom.logs { NSLog("macscroll crop width %.4f centre %.4f,%.4f", geometry.crop.width, geometry.centre.x, geometry.centre.y) }
            #endif
        case .ended:
            guard scrollBase != nil else { return }
            scrollBase = nil
            withAnimation(.easeOut(duration: 0.2)) { touching = false }
        }
    }

    /// `base` zoomed `m` times about `p` (corrected frame, normalised): `Geometry.zoomed`.
    static func zoomed(_ base: Geometry, by m: CGFloat, about p: CGPoint, in imageSize: CGSize) -> Geometry {
        base.zoomed(by: m, about: p, in: imageSize)
    }

    // MARK: under the picture: its size

    /// "3,200 × 4,000  ·  12.8 MP": the cut of the original, as it will
    /// develop. Edit's crop is of a picture whose exported size is the
    /// recipe's: it says how much of the finished picture it keeps.
    private var sizeText: String {
        switch target {
        case .source:
            let out = geometry.outputSize(for: imageSize)
            let px = PixelSize(width: Int(out.width), height: Int(out.height))
            return px.text + Fmt.dot + Fmt.megapixels(px.megapixels)
        case .finished:
            let kept = Int((geometry.crop.width * geometry.crop.height * 100).rounded())
            return String(format: L("%d%% of the finished picture"), kept)
        }
    }

    // MARK: the panel: the dials, the ratio, or the guides

    // The dials

    private func value(_ d: Dial) -> Double {
        switch d {
        case .straighten: geometry.angle
        case .vertical: geometry.vertical
        case .horizontal: geometry.horizontal
        }
    }

    private func set(_ d: Dial, _ v: Double) {
        switch d {
        case .straighten: geometry = geometry.straightened(to: v, in: imageSize)
        case .vertical: geometry = geometry.perspective(vertical: v, horizontal: geometry.horizontal)
        case .horizontal: geometry = geometry.perspective(vertical: geometry.vertical, horizontal: v)
        }
    }

    // The ratio (IMG_6818)

    /// Photos' order: the picture's own, free, square, then the ratios.
    private static let ratios: [CropAspect] = [.original, .free, .square, .r16x9, .r5x4, .r7x5, .r4x3, .r3x2]

    /// The output is upright (what the screen shows, after the turns).
    private var portraitOutput: Bool {
        let out = geometry.outputSize(for: imageSize)
        return out.height > out.width
    }

    private var quarterTurned: Bool { ((geometry.quarterTurns % 4) + 4) % 2 == 1 }

    /// A ratio as the screen should show it: the member of its pair whose
    /// output is upright or not, as asked.
    private func oriented(_ a: CropAspect, portrait: Bool) -> CropAspect {
        guard a.hasOrientation, let r = a.ratio(sourceAspect: imageSize.width / max(imageSize.height, 1)), r != 1 else { return a }
        // A crop's ratio is in the source's axes; a quarter turn stands it on end.
        let uprightOut = (r < 1) != quarterTurned
        return uprightOut == portrait ? a : a.transposed
    }

    private func ratioName(_ a: CropAspect) -> String {
        switch a.canonical {
        case .original: return L("Original ratio")
        case .free: return L("Freeform")
        case .square: return L("Square", as: "a ratio")
        default:
            // The numbers as the screen has them, "4:5" upright and "5:4" lying
            // down, for the way round the crop is now.
            let shown = oriented(a, portrait: portraitOutput)
            let r = shown.fixedRatio ?? 1
            let upright = (r < 1) != quarterTurned
            return upright ? CropPage.orientedLabel(shown.isPortrait ? shown : shown.transposed) : shown.canonical.label
        }
    }

    private func pickRatio(_ chip: CropAspect) {
        withAnimation(glide) {
            var g = geometry
            g.aspect = oriented(chip, portrait: portraitOutput)
            geometry = g.constrained(in: imageSize)
        }
    }

    /// Photos' two shapes: the crop stood up or laid down. A free crop and a
    /// square have no way round.
    private func orientationButton(portrait: Bool, small: Bool = false) -> some View {
        let enabled = geometry.aspect.hasOrientation
        let on = enabled && portraitOutput == portrait
        return Button {
            guard enabled, portraitOutput != portrait else { return }
            withAnimation(glide) {
                var g = geometry
                g.aspect = oriented(g.aspect, portrait: portrait)
                geometry = g.constrained(in: imageSize)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(on ? Theme.selection : Theme.card)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(on ? Theme.selection : Theme.secondaryText, lineWidth: 1.5)
                if on {
                    Image(systemName: "checkmark").font(.system(size: small ? 9 : 12, weight: .bold)).foregroundStyle(Theme.onSelection)
                }
            }
            .frame(width: portrait ? (small ? 16 : 26) : (small ? 24 : 40), height: portrait ? (small ? 24 : 40) : (small ? 16 : 26))
            .frame(width: small ? 32 : 50, height: small ? 30 : 50).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .rowEnabled(enabled)
        .accessibilityLabel(portrait ? L("Portrait") : L("Landscape"))
        .accessibilityIdentifier(portrait ? "crop.portrait" : "crop.landscape")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The ratio as the crop has it: the portrait member of a pair reads
    /// "4:5", not its landscape twin's "5:4".
    static func orientedLabel(_ a: CropAspect) -> String {
        switch a {
        case .r2x3: "2:3"
        case .r3x4: "3:4"
        case .r9x16: "9:16"
        case .r4x5: "4:5"
        case .r5x7: "5:7"
        default: a.label
        }
    }

    // The guides (参考线, Capture One's)

    private var visibleLines: [StageLine] {
        guard let guideMode else { return [] }
        return CropGuides.lines(guideMode).map { StageLine(a: $0.a, b: $0.b, kind: $0.level ? .level : .upright) }
    }

    private var visiblePointIndices: [Int] {
        Array(Set(visibleLines.flatMap { [$0.a, $0.b] })).sorted()
    }

    private var guideHint: String {
        switch guideMode {
        case nil: L("Find lines in the picture that should be parallel, or a shape that should be a rectangle, then Apply to correct the perspective.")
        case .horizontals: L("Lay the two lines on two lines in the picture that should lie level and parallel, then Apply.")
        case .verticals: L("Lay the two lines on two lines in the picture that should stand upright and parallel, then Apply.")
        case .rectangle: L("Set the four corners on a shape in the picture that should be a rectangle, then Apply.")
        }
    }

    private func guideTitle(_ mode: CropGuides.Mode) -> String {
        switch mode {
        case .horizontals: L("Horizontals", as: "guides")
        case .verticals: L("Verticals", as: "guides")
        case .rectangle: L("Rectangle", as: "guides")
        }
    }

    /// The crop's own 0…1 frame on the source: where a line is pulled out to.
    private func onCrop(_ p: CGPoint) -> CGPoint {
        let c = geometry.crop
        let corrected = geometry.rotated(CGPoint(x: c.x + p.x * c.width, y: c.y + p.y * c.height), in: imageSize)
        let s = geometry.sourcePoint(forCorrected: corrected, in: imageSize)
        return CGPoint(x: s.x.clamped(to: 0...1), y: s.y.clamped(to: 0...1))
    }

    /// A mode's lines are drawn out of the crop — the horizontals from its
    /// top and bottom, the verticals from its sides, the rectangle's corners
    /// from its middle — their points opening as they come. Tapped again they
    /// go back the way they came; another mode's go back before its own come.
    private func pull(_ mode: CropGuides.Mode) {
        pulls += 1
        let pull = pulls
        let out = guideMode
        if let out {
            withAnimation(glide) { points = CropGuides.edge(out, in: onCrop) }
        }
        let bring = {
            guard pull == pulls else { return }
            guidesMoved = false
            guard out != mode else { withAnimation(.easeOut(duration: 0.2)) { guideMode = nil }; return }
            points = CropGuides.edge(mode, in: onCrop)
            withAnimation(.easeOut(duration: 0.2)) { guideMode = mode }
            DispatchQueue.main.async {
                guard pull == pulls else { return }
                withAnimation(glide) { points = CropGuides.pulled(mode, in: onCrop) }
            }
        }
        if out == nil { bring() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: bring) }
    }

    /// Apply: the perspective and straighten the lines ask, solved and glided
    /// to. The lines stay where they are on the picture, and are drawn as the
    /// result has them — level and upright.
    private func apply() {
        guard allowsPerspective, let guideMode,
              let solved = CropGuides.solve(guideMode, points: points, geometry: geometry, imageSize: imageSize) else { return }
        var g = geometry.perspective(vertical: (solved.vertical * 10).rounded() / 10,
                                     horizontal: (solved.horizontal * 10).rounded() / 10)
        g = g.straightened(to: (solved.angle * 10).rounded() / 10, in: imageSize)
        withAnimation(glide) { geometry = g; guidesMoved = false }
    }

    // MARK: the Mac's inspector

    // The owner, 2026-10-25: "In crop we don't need to treat it like the reference version. All features
    // could be expanded with no second layer. Also align the design here with the rest of the desktop
    // vibe more." No pill switching the panel under it between the ratios and the dials and the guides:
    // the column holds every part at once, in sections as the develop column has them (Decode, Effects:
    // a 13 pt semibold name, a round Reset at its right, the column's chips and rulers). Flip and Rotate
    // are buttons in a section of their own. The bar over it is the Mac's (`MacFlowBar`), unchanged.

    /// A page of its own on the Mac (a cover, not the develop page's crop): the inspector at the left as the
    /// develop column is, the crop beside it; in a window too narrow for that, the inspector under the crop.
    private var macCoverPage: some View {
        GeometryReader { geo in
            let column = WindowLayout.columnWidth
            if geo.size.width >= column + 360 {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).clearsWindowControls()
                        macInspector
                    }
                    .frame(width: column)
                    Theme.rule.frame(width: 1)
                    GeometryReader { s in stage(s.size) }
                }
            } else {
                VStack(spacing: 0) {
                    topBar.clearsWindowControls().frame(height: Self.barHeight)
                    GeometryReader { s in stage(s.size) }
                    macSections.frame(maxWidth: Self.narrowSectionsWidth).frame(height: min(360, geo.size.height * 0.45))
                }
            }
        }
    }

    /// In a window too narrow for the inspector beside the crop, the sections under it are no wider than this.
    private static let narrowSectionsWidth: CGFloat = 744

    /// The bar, then the sections, scrolling where the column is too short for them all.
    private var macInspector: some View {
        VStack(spacing: 0) {
            topBar.frame(height: Self.barHeight)
            macSections
        }
    }

    private var macSections: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                macSummary
                // Under a film edge the film frames the picture: the crop box, and so its ratio, is held;
                // straighten, the keystone, the turns and the flips still apply (2026-10-25).
                macAspect.rowEnabled(!heldByFilm)
                macStraighten
                if allowsPerspective { macPerspective }
                macTurns
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.automatic)
    }

    /// What is cut and how large it comes out — or, under a film edge, that the film frames it.
    private var macSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                cropTargetSwitch
                Spacer(minLength: 8)
                if !heldByFilm {
                    Text(sizeText).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.dim).monospacedDigit()
                } else if let film {
                    // The cut the gate makes of the original, as it will develop.
                    Text(film.cut.text + Fmt.dot + Fmt.megapixels(film.cut.megapixels))
                        .font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.dim).monospacedDigit()
                }
            }
            .lineLimit(1)
            if heldByFilm {
                Note(L("Film edge on: place the picture under the film's gate. Straighten and perspective still apply."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// A section's name, as the develop column's (Decode, Effects), with its Reset at the right.
    private func macHeader(_ title: String, reset: (() -> Void)? = nil, resettable: Bool = false, id: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let reset {
                RoundButton(diameter: 28, label: L("Reset") + " " + title, action: reset) { Icon(.reset, size: 16) }
                    .rowEnabled(resettable)
                    .accessibilityIdentifier("crop.reset." + id)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .padding(.top, 18)
    }

    /// Aspect: the two shapes beside the name, every ratio under it as the column's chips.
    private var macAspect: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("Aspect ratio")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                orientationButton(portrait: true, small: true)
                orientationButton(portrait: false, small: true)
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .padding(.top, 18)
            ChipFlow(spacing: 8, lineSpacing: 8) {
                ForEach(Self.ratios, id: \.self) { chip in
                    Chip(title: ratioName(chip), on: chip.canonical == geometry.aspect.canonical,
                         height: 28, size: 12.5, padding: 12) { pickRatio(chip) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Straighten: the angle's ruler, and the ⌘-drag said in a line under it.
    private var macStraighten: some View {
        VStack(alignment: .leading, spacing: 0) {
            macHeader(L("Straighten"), reset: { withAnimation(glide) { set(.straighten, 0) } },
                      resettable: geometry.angle != 0, id: "straighten")
            macRuler(.straighten, L("Angle", as: "straighten"))
            Note(L("Hold ⌘ and drag along the picture where it should be level, or upright, to straighten it."))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
    }

    /// Perspective (a RAW, in Develop's crop): Vertical and Horizontal, then Capture One's guides.
    private var macPerspective: some View {
        VStack(alignment: .leading, spacing: 0) {
            macHeader(L("Perspective"), reset: {
                withAnimation(glide) { geometry = geometry.perspective(vertical: 0, horizontal: 0) }
            }, resettable: geometry.vertical != 0 || geometry.horizontal != 0, id: "perspective")
            macRuler(.vertical, L("Vertical", as: "perspective"))
            macRuler(.horizontal, L("Horizontal", as: "perspective"))
            HStack(spacing: 8) {
                Text(L("Guides")).font(Theme.Font.ui(DevelopType.label, .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            ChipFlow(spacing: 8, lineSpacing: 8) {
                ForEach(CropGuides.Mode.allCases) { mode in
                    Chip(title: guideTitle(mode), on: guideMode == mode, height: 28, size: 12.5, padding: 12) { pull(mode) }
                        .accessibilityIdentifier("crop.guide." + mode.rawValue)
                }
            }
            // Under the gate the lines have no crop to be laid out of: the dials still turn.
            .rowEnabled(!heldByFilm)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Note(guideHint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .id(guideMode)
        }
    }

    /// Rotate and Flip, as plain buttons: a word beside its symbol.
    private var macTurns: some View {
        VStack(alignment: .leading, spacing: 8) {
            macHeader(L("Rotate & Flip"), id: "turns")
            HStack(spacing: 8) {
                macButton("rotate.left", L("Rotate Left"), id: "crop.rotate") {
                    withAnimation(glide) { geometry = geometry.turned(by: -1); turns -= 1 }
                }
                macButton("arrow.left.and.right.righttriangle.left.righttriangle.right", L("Flip"), id: "crop.flip",
                          on: geometry.flipH) {
                    withAnimation(glide) { geometry.flipH.toggle() }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
    }

    private func macButton(_ symbol: String, _ title: String, id: String, on: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(Theme.Font.ui(12.5, on ? .semibold : .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Theme.onSelection : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(on ? Theme.selection : Theme.card))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// One of the page's three dials as the develop column's ruler row; turning it is what `dialing` was.
    private func macRuler(_ d: Dial, _ label: String) -> some View {
        let limit = d == .straighten ? Geometry.maxAngle : Geometry.maxPerspective
        return rulerRow(label, Fmt.signed(value(d)) + "°",
                        value: Binding(get: { value(d) }, set: { set(d, $0) }),
                        range: -limit...limit, step: 1, majorEvery: 5, spacing: 9, snap: 0.1, home: 0,
                        onEditingChanged: { on in
                            dial = d
                            withAnimation(.easeOut(duration: 0.15)) { dialing = on }
                        })
    }

    // MARK: under a film edge: the gate in the crop box's place

    /// The frame's edit as this page has it: its own geometry, and the picture's place under the gate.
    /// The develop page's session where it is open, which is ahead of the library's.
    private var draftEdit: FrameEdit {
        var e = model.openSession(frame.id)?.edit ?? frame.edit
        var g = geometry
        g.quarterTurns = ((g.quarterTurns % 4) + 4) % 4
        e.geometry = g
        e.filmEdge.framing = framing
        return e
    }

    /// The film laid out for the page: the selected format's gate, holes and edge print, round the
    /// framing in force (`FilmFraming.resolved`: the kept one under the photo's corrections, else the
    /// largest cut).
    private var film: ResolvedFilmEdge? {
        guard heldByFilm else { return nil }
        return model.filmEdge(for: frame, edit: draftEdit, forcing: true)
    }

    /// Where the film sits on the stage: the whole canvas in the room, centred.
    private func filmPlacement(_ film: ResolvedFilmEdge, size: CGSize) -> FilmCanvasView.Placement {
        let mm = film.geometry.canvasMM
        let room = room(size)
        let k = min(room.height / max(mm.height, 0.001), room.width / max(mm.width, 0.001))
        return .init(k: k, origin: CGPoint(x: (size.width - mm.width * k) / 2, y: (size.height - mm.height * k) / 2))
    }

    /// The gate's picture box on the stage, in points.
    private func gateBox(_ film: ResolvedFilmEdge, place: FilmCanvasView.Placement) -> CGRect {
        let (box, _, _) = film.geometry.pictureBox
        return CGRect(x: place.origin.x + box.minX * place.k, y: place.origin.y + box.minY * place.k,
                      width: max(box.width * place.k, 1), height: max(box.height * place.k, 1))
    }

    /// The Frame step's guide on the crop's stage: the film's own layout over the undeveloped picture,
    /// the picture beyond the gate dimmed. A drag moves the picture under the fixed gate (and at the end of
    /// its travel still follows a little and settles back), a pinch or a scroll enlarges it about the
    /// fingers or the pointer, ⌘-drag levels it as on the plain crop.
    private func filmStage(_ film: ResolvedFilmEdge, size: CGSize) -> some View {
        let place = filmPlacement(film, size: size)
        let shown = gateBox(film, place: place)
        return ZStack(alignment: .topLeading) {
            FilmCanvasView(geometry: film.geometry, style: .guide, picture: frame.originalPicture ?? frame.picture,
                           sourceSize: imageSize, framing: film.framing, pointSize: max(size.width, size.height),
                           placement: place, nudge: nudge)
                .frame(width: size.width, height: size.height)
            if let refLine { RefLineView(line: refLine).allowsHitTesting(false) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .macScrollZoom { phase, dy, at in
            switch phase {
            case .began, .changed:
                if enlargeBase == nil {
                    guard placeBase == nil, drag == nil else { return }
                    enlargeBase = film.framing
                    nudge = .zero
                }
                guard let base = enlargeBase else { return }
                framing = enlarged(base, by: exp(dy * 0.006), at: at, shown: shown)
            case .ended:
                enlargeBase = nil
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if MacKeys.command { MacCursor.crosshair(); crossCursor = true }
                else if crossCursor { MacCursor.arrow(); crossCursor = false }
            case .ended:
                if crossCursor, drag == nil { MacCursor.arrow(); crossCursor = false }
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.cropLine)) { n in
            guard let deg = n.object as? Double else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) * 0.35, t = deg * .pi / 180
            let line = RefLine(a: CGPoint(x: c.x - r * cos(t), y: c.y - r * sin(t)), b: CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t)))
            refLine = line
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { refLine = nil; level(line, size: size) }
        }
        // MacDriver's `crop.place.*`: the picture enlarged about the gate's middle, then moved by a part of
        // the gate's width and height, through the same two functions the scroll and the drag call.
        .onReceive(NotificationCenter.default.publisher(for: MacDriver.cropPlace)) { n in
            guard let p = n.object as? [Double], p.count == 3 else { return }
            if p[2] <= 0 { withAnimation(glide) { framing = nil }; return }
            let big = enlarged(film.framing, by: p[2], at: CGPoint(x: shown.midX, y: shown.midY), shown: shown)
            let moved = FilmFraming.dragged(big, by: CGSize(width: p[0] * shown.width, height: p[1] * shown.height),
                                            shown: shown, source: imageSize)
            withAnimation(glide) { framing = moved.framing }
            NSLog("cropplace framing width %.4f centre %.4f,%.4f", moved.framing.crop.width, moved.framing.centre.x, moved.framing.centre.y)
        }
        #endif
        .gesture(placeDrag(film, shown: shown, size: size).simultaneously(with: placePinch(film, shown: shown)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("The film's guide over the undeveloped picture"))
    }

    private func enlarged(_ base: Geometry, by m: CGFloat, at: CGPoint, shown: CGRect) -> Geometry {
        let e = draftEdit
        return FilmFraming.enlarged(base, by: m, at: at, shown: shown, edge: e.filmEdge, source: imageSize, photo: e.geometry)
    }

    /// A drag under the gate: the picture follows it; ⌘ at the press draws the levelling line instead.
    private func placeDrag(_ film: ResolvedFilmEdge, shown: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard enlargeBase == nil else { return }
                if drag == nil, placeBase == nil, MacKeys.command {
                    drag = .line(from: v.startLocation)
                    MacCursor.crosshair(); crossCursor = true
                }
                if case .line(let from) = drag {
                    refLine = RefLine(a: from, b: v.location)
                    MacCursor.crosshair()
                    return
                }
                if placeBase == nil {
                    placeBase = (film.framing, v.translation)
                    withAnimation(.easeOut(duration: 0.15)) { touching = true }
                }
                guard let base = placeBase else { return }
                let t = CGSize(width: v.translation.width - base.travelled.width,
                               height: v.translation.height - base.travelled.height)
                let moved = FilmFraming.dragged(base.framing, by: t, shown: shown, source: imageSize)
                framing = moved.framing
                nudge = moved.nudge
            }
            .onEnded { _ in
                if drag != nil { finishDrag(size); return }
                placeBase = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { nudge = .zero; touching = false }
            }
    }

    /// Two fingers enlarge the picture under the gate about where they came down.
    private func placePinch(_ film: ResolvedFilmEdge, shown: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if enlargeBase == nil {
                    enlargeBase = film.framing
                    placeBase = nil
                    nudge = .zero
                    withAnimation(.easeOut(duration: 0.15)) { touching = true }
                }
                guard let base = enlargeBase else { return }
                framing = enlarged(base, by: v.magnification, at: v.startLocation, shown: shown)
            }
            .onEnded { _ in
                enlargeBase = nil
                withAnimation(.easeOut(duration: 0.2)) { touching = false }
            }
    }

    // MARK: the ⌘-drag line

    /// The line, levelled: the straighten that lays it level on the screen, or upright where it is
    /// nearer upright — through `straightened`, as the dial is, so it is one step of Undo.
    private func level(_ line: RefLine, size: CGSize) {
        guard let angle = Self.levelled(geometry, from: line.a, to: line.b) else { return }
        #if DEBUG
        let before = rest(size), ca = before.corrected(line.a), cb = before.corrected(line.b)
        #endif
        withAnimation(glide) { geometry = geometry.straightened(to: angle, in: imageSize) }
        #if DEBUG
        // The check: the same two points of the picture, through the map the page now rests at.
        let after = rest(size), sa = after.screen(ca), sb = after.screen(cb)
        NSLog("cropline drawn %.2f° → angle %.2f° (flip %d, turns %d): the line now at %.4f° on the screen",
              atan2(line.b.y - line.a.y, line.b.x - line.a.x) * 180 / .pi, geometry.angle, geometry.flipH ? 1 : 0, turns,
              atan2(sb.y - sa.y, sb.x - sa.x) * 180 / .pi)
        #endif
    }

    /// The straighten that turns a line drawn on the screen level (or upright, past 45°), from the crop
    /// as it is. The stage shows the corrected frame turned by `90·turns − angle` and then mirrored
    /// (`StageMapping.affine`): a line's angle on the screen moves by −Δangle, or by +Δangle when the
    /// picture is mirrored once (a flip; both flips are a half turn). Nil for a click, not a line.
    static func levelled(_ g: Geometry, from a: CGPoint, to b: CGPoint) -> Double? {
        let dx = b.x - a.x, dy = b.y - a.y
        guard hypot(dx, dy) > 8 else { return nil }
        var off = atan2(dy, dx) * 180 / .pi                          // −180…180, y down
        if off > 90 { off -= 180 } else if off <= -90 { off += 180 }  // the line has no direction
        if off > 45 { off -= 90 } else if off < -45 { off += 90 }     // off upright, past 45°
        let mirrored = g.flipH != g.flipV
        return (g.angle + (mirrored ? -off : off)).clamped(to: -Geometry.maxAngle...Geometry.maxAngle)
    }

    // MARK: Done

    /// Writes this page's record, and only it, where it changed. Cancel
    /// writes nothing.
    private func done() {
        var cut = geometry
        cut.quarterTurns = ((cut.quarterTurns % 4) + 4) % 4
        if target == .finished { cut.vertical = 0; cut.horizontal = 0 }
        else if !allowsPerspective { cut.vertical = opened.vertical; cut.horizontal = opened.horizontal }
        // A crop back at nothing is stored as nothing, so the frame reads unchanged.
        if cut.isIdentity && cut.aspect == .free { cut = .default }
        switch target {
        case .source:
            // Under the gate the placement is the film's framing (`FilmFraming.resolved` develops it).
            let placed = framing
            let moves = heldByFilm && placed != frame.edit.filmEdge.framing
            if cut != frame.edit.geometry || moves {
                model.change(frame.id) {
                    $0.geometry = cut
                    if moves { $0.filmEdge.framing = placed }
                }
            }
        case .finished:
            if cut != frame.edit.printCrop { model.change(frame.id) { $0.printCrop = cut } }
        }
        close()
    }
}

// MARK: - the stage: the picture, the crop over it, the guides

/// Everything on the stage that glides, as one vector (`CropStageView`).
struct StageState: Equatable {
    var mapping = StageMapping()
    var crop = CropRect.full
    var angle = 0.0
    var vertical = 0.0
    var horizontal = 0.0
    /// The guides' four points, on the source, normalised.
    var points: [CGPoint] = Array(repeating: .zero, count: 4)
    /// The points' circles, 0…1: they open as the drawer does.
    var pointScale = 0.0
    /// The held point's loupe, 0…1.
    var loupe = 0.0

    struct Vector: VectorArithmetic, Equatable {
        var v = SIMD32<Double>(repeating: 0)
        static var zero: Vector { Vector() }
        static func + (a: Vector, b: Vector) -> Vector { Vector(v: a.v + b.v) }
        static func - (a: Vector, b: Vector) -> Vector { Vector(v: a.v - b.v) }
        mutating func scale(by rhs: Double) { v *= rhs }
        var magnitudeSquared: Double { (v * v).sum() }
    }

    var vector: Vector {
        get {
            var v = SIMD32<Double>(repeating: 0)
            let m = mapping.vector.v
            for i in 0..<8 { v[i] = m[i] }
            v[8] = crop.x; v[9] = crop.y; v[10] = crop.width; v[11] = crop.height
            v[12] = angle; v[13] = vertical; v[14] = horizontal
            for (i, p) in points.prefix(4).enumerated() { v[15 + 2 * i] = p.x; v[16 + 2 * i] = p.y }
            v[23] = pointScale; v[24] = loupe
            return Vector(v: v)
        }
        set {
            let v = newValue.v
            var m = SIMD8<Double>(repeating: 0)
            for i in 0..<8 { m[i] = v[i] }
            mapping.vector = StageVector(v: m)
            crop = CropRect(x: v[8], y: v[9], width: v[10], height: v[11])
            angle = v[12]; vertical = v[13]; horizontal = v[14]
            points = (0..<4).map { CGPoint(x: v[15 + 2 * $0], y: v[16 + 2 * $0]) }
            pointScale = v[23]; loupe = v[24]
        }
    }
}

/// A guide line between two of the four points.
struct StageLine: Equatable {
    enum Kind { case level, upright }
    var a: Int
    var b: Int
    var kind: Kind
}

/// The stage, drawn from one interpolated state: the picture through the map
/// and its perspective, the dim outside the crop, the crop's frame, its grid
/// while something moves, and the guides with their points and the loupe.
private struct CropStageView<Picture: View>: View, Animatable {
    var state: StageState
    /// The crop's other fields (aspect, turns, flips), as they are.
    let base: Geometry
    let imageSize: CGSize
    let area: CGSize
    let dim: Double
    /// 0 none, 1 thirds, 2 thirds and ninths (straightening).
    let grid: Int
    let lines: [StageLine]
    let held: Int?
    @ViewBuilder let picture: (CGFloat) -> Picture

    var animatableData: StageState.Vector {
        get { state.vector }
        set { state.vector = newValue }
    }

    private var geometry: Geometry {
        var g = base
        g.crop = state.crop; g.angle = state.angle
        g.vertical = state.vertical; g.horizontal = state.horizontal
        return g
    }

    /// The picture is laid out once at a size that keeps a zoom sharp; the
    /// map does the rest.
    private var viewSize: CGSize {
        let long = max(area.width, area.height) * 1.6
        let k = long / max(imageSize.width, imageSize.height, 1)
        return CGSize(width: imageSize.width * k, height: imageSize.height * k)
    }

    var body: some View {
        let g = geometry
        let keystone = g.keystone(in: imageSize)
        let m = state.mapping
        let corners = m.corners(g, imageSize: imageSize)
        let view = viewSize
        ZStack(alignment: .topLeading) {
            // Mac: the corrected picture is drawn only as far as it develops. A keystone re-projects
            // the source into a trapezoid, and the frame that develops — the host's re-projection
            // (`HostCut.corrected`), the engine's crop, every bound a crop is held to — is the
            // corrected frame inscribed in it (`Keystone.fill`): the source's own size, with the
            // trapezoid cut off at it. Drawn whole, the trapezoid's slack (up to 630 px of a 12 MP
            // frame at the dials' angles) showed beside the crop as picture it could never reach.
            ZStack(alignment: .topLeading) {
                picture(max(view.width, view.height))
                    .frame(width: view.width, height: view.height)
                    .projectionEffect(m.projection(viewSize: view, imageSize: imageSize, keystone: keystone))
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            .mask(alignment: .topLeading) { correctedFrame(m) }
            .allowsHitTesting(false)
            Canvas { ctx, size in
                drawCrop(&ctx, size: size, corners: corners)
                drawGuides(&ctx, keystone: keystone)
            }
            .allowsHitTesting(false)
            if let held, state.loupe > 0.01, held < state.points.count {
                loupe(at: point(held, keystone), keystone: keystone, view: view)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    /// The corrected frame — the picture as it develops — on the screen, as a shape to cut by.
    private func correctedFrame(_ m: StageMapping) -> Path {
        let w = max(imageSize.width, 1), h = max(imageSize.height, 1)
        var p = Path()
        p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].map(m.screen))
        p.closeSubpath()
        return p
    }

    private func point(_ i: Int, _ keystone: Keystone) -> CGPoint {
        let p = state.points[i]
        return state.mapping.screen(keystone.corrected(CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)))
    }

    private func drawCrop(_ ctx: inout GraphicsContext, size: CGSize, corners: [CGPoint]) {
        guard corners.count == 4 else { return }
        var outline = Path()
        outline.addLines(corners)
        outline.closeSubpath()
        var shade = Path(CGRect(origin: .zero, size: size))
        shade.addPath(outline)
        ctx.fill(shade, with: .color(.black.opacity(dim)), style: FillStyle(eoFill: true))
        ctx.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 1)

        let (tl, tr, br, bl) = (corners[0], corners[1], corners[2], corners[3])
        func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        if grid > 0 {
            var thirds = Path()
            for t in [1.0 / 3, 2.0 / 3] {
                thirds.move(to: lerp(tl, tr, t)); thirds.addLine(to: lerp(bl, br, t))
                thirds.move(to: lerp(tl, bl, t)); thirds.addLine(to: lerp(tr, br, t))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.5)), lineWidth: 0.6)
        }
        if grid > 1 {
            // Straightening: a finer grid to hold a horizon against.
            var fine = Path()
            for k in 1..<9 where k % 3 != 0 {
                let t = CGFloat(k) / 9
                fine.move(to: lerp(tl, tr, t)); fine.addLine(to: lerp(bl, br, t))
                fine.move(to: lerp(tl, bl, t)); fine.addLine(to: lerp(tr, br, t))
            }
            ctx.stroke(fine, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
        }
        // Photos' grips: a bracket at each corner, a short bar at each edge's middle.
        var grips = Path()
        for (i, c) in corners.enumerated() {
            let next = corners[(i + 1) % 4], previous = corners[(i + 3) % 4]
            grips.move(to: along(c, previous, 18))
            grips.addLine(to: c)
            grips.addLine(to: along(c, next, 18))
            let mid = lerp(c, next, 0.5)
            grips.move(to: along(mid, c, 10))
            grips.addLine(to: along(mid, next, 10))
        }
        ctx.stroke(grips, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
    }

    private func along(_ from: CGPoint, _ to: CGPoint, _ length: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let d = max(hypot(dx, dy), 0.0001)
        let l = min(length, d / 2)
        return CGPoint(x: from.x + dx / d * l, y: from.y + dy / d * l)
    }

    /// Capture One's guides: each line drawn right across the picture, each
    /// point a circle with the point at its centre.
    private func drawGuides(_ ctx: inout GraphicsContext, keystone: Keystone) {
        guard !lines.isEmpty, state.pointScale > 0.01 else { return }
        let reach = hypot(area.width, area.height) * 2
        var path = Path()
        for line in lines {
            let a = point(line.a, keystone), b = point(line.b, keystone)
            let d = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
            let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
            path.move(to: CGPoint(x: a.x - ux * reach, y: a.y - uy * reach))
            path.addLine(to: CGPoint(x: b.x + ux * reach, y: b.y + uy * reach))
        }
        let alpha = min(state.pointScale, 1)
        ctx.stroke(path, with: .color(.black.opacity(0.35 * alpha)), lineWidth: 2.2)
        ctx.stroke(path, with: .color(.white.opacity(0.9 * alpha)), lineWidth: 1)
        let indices = Array(Set(lines.flatMap { [$0.a, $0.b] }))
        for i in indices where i != held || state.loupe < 0.5 {
            let p = point(i, keystone)
            let r = 15 * CGFloat(state.pointScale)
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            ctx.stroke(ring, with: .color(.black.opacity(0.35 * alpha)), lineWidth: 2.6)
            ctx.stroke(ring, with: .color(.white.opacity(alpha)), lineWidth: 1.3)
            let dot = Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
            ctx.fill(dot, with: .color(.white.opacity(alpha)))
        }
    }

    /// The held point's circle grown into a loupe: the picture under it, three
    /// times closer, a fine cross at the point itself.
    private func loupe(at p: CGPoint, keystone: Keystone, view: CGSize) -> some View {
        let k = 3.0
        var close = state.mapping
        close.scale *= k
        close.centre = CGPoint(x: p.x + (close.centre.x - p.x) * k, y: p.y + (close.centre.y - p.y) * k)
        let r = 15 + 37 * CGFloat(state.loupe)
        return ZStack(alignment: .topLeading) {
            Theme.background
            picture(max(view.width, view.height))
                .frame(width: view.width, height: view.height)
                .projectionEffect(close.projection(viewSize: view, imageSize: imageSize, keystone: keystone))
            Canvas { ctx, _ in
                // The lines through the loupe, as close as the picture.
                var path = Path()
                for line in lines {
                    let a = close.screen(keystone.corrected(CGPoint(x: state.points[line.a].x * imageSize.width,
                                                                    y: state.points[line.a].y * imageSize.height)))
                    let b = close.screen(keystone.corrected(CGPoint(x: state.points[line.b].x * imageSize.width,
                                                                    y: state.points[line.b].y * imageSize.height)))
                    let d = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
                    let ux = (b.x - a.x) / d * 4000, uy = (b.y - a.y) / d * 4000
                    path.move(to: CGPoint(x: a.x - ux, y: a.y - uy)); path.addLine(to: CGPoint(x: b.x + ux, y: b.y + uy))
                }
                ctx.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 7, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 7)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                ctx.stroke(cross, with: .color(Theme.accent), lineWidth: 1.2)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .mask { Circle().frame(width: 2 * r, height: 2 * r).position(p) }
        .overlay {
            Circle().stroke(Color.white, lineWidth: 2)
                .frame(width: 2 * r, height: 2 * r).position(p)
                .shadow(color: .black.opacity(0.5), radius: 6)
        }
        .allowsHitTesting(false)
    }
}

/// The Mac's ⌘-drag reference line, in the stage's points (the owner, 2026-10-25).
struct RefLine: Equatable {
    var a: CGPoint
    var b: CGPoint
}

/// The line as it is drawn, and faintly through its middle what it will be laid to: level, or upright
/// where it is nearer upright.
private struct RefLineView: View {
    let line: RefLine

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: line.a); path.addLine(to: line.b)
            ctx.stroke(path, with: .color(.black.opacity(0.45)), lineWidth: 3)
            ctx.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
            for p in [line.a, line.b] {
                let dot = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                ctx.fill(dot, with: .color(Theme.accent))
                ctx.stroke(dot, with: .color(.black.opacity(0.45)), lineWidth: 1)
            }
            let dx = line.b.x - line.a.x, dy = line.b.y - line.a.y
            guard hypot(dx, dy) > 8 else { return }
            let mid = CGPoint(x: (line.a.x + line.b.x) / 2, y: (line.a.y + line.b.y) / 2)
            let half = hypot(dx, dy) / 2
            var target = Path()
            if abs(dx) >= abs(dy) {
                target.move(to: CGPoint(x: mid.x - half, y: mid.y)); target.addLine(to: CGPoint(x: mid.x + half, y: mid.y))
            } else {
                target.move(to: CGPoint(x: mid.x, y: mid.y - half)); target.addLine(to: CGPoint(x: mid.x, y: mid.y + half))
            }
            ctx.stroke(target, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}
