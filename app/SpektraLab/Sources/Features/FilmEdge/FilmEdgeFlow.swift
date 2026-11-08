//  FilmEdgeFlow.swift — D2 Film · D3 Frame · D4 Edge · D5 Date.
//
//  the page layout
//  (`gen_overscan.reference`), and the page layout
//  (`gen_flow.film_edge_plus`). One full-screen
//  flow over the develop page, entered from the Frame tab's two rows:
//  *Cancel · Film Edge · n of 4*, the preview, the steps in the develop tabs'
//  capsule, the step's controls, and Back / Next / Develop where Reset and
//  Export sit on the develop page.
//
//  The order is the order the decisions depend on (design/overscan §1): the
//  format decides the gate, the gate decides the cut, the turn decides where
//  the film runs, and the edge and the date are what that camera and that
//  scan did.
//
//  **What the preview is.** Steps 1-2 show the GUIDE: the film's own layout
//  laid over the undeveloped picture, drawn from one `FilmGeometry`
//  (`FilmEdge/FilmGeometry.swift`), which is the engine's layout — so the
//  holes, the gate, the name, the numbers and the DX bars the guide ghosts are
//  where the develop puts them. Steps 3-4 show the developed film, which is
//  the engine's own picture of it: the session's develop, as on the develop
//  page under this flow (they are one session, `AppServices.session(for:)`).
//
//  **Placing the picture.** Under the guide the picture is a thing to push
//  about: a drag moves it under the fixed gate, a pinch enlarges it about the
//  fingers, and where the cut has no further to go the picture still follows
//  the finger a little and settles back, so the end of its travel is felt
//  rather than met as a control that does nothing (the owner, from the host,
//  2026-10-07: "we cannot really decide how to hover it over the canvas, as
//  it should be scrollable"). Both guide steps take it: the picture is as
//  much there under the format cards as under the straighten ruler.
//
//  **When it develops.** Never while a format or the picture's place is being
//  chosen: nothing is written until the flow leaves the guide for Edge or Date,
//  by *Next* from Frame or by a tap on either in the steps — every step is
//  open from the start, and what one cannot use yet is greyed in its panel
//  (`FilmEdgeJourney.swift`, the owner's direction of 2026-10-19). From there
//  every control is a film-side edit through the frame's `OpenFrameSession`, as
//  on the develop page — when the finger rests or lifts. *Cancel* puts the
//  frame's film edge and date back as they were when the flow opened.
//
//  Not drawn by the design and built here by interpretation: the Edge step's
//  Holes, Light and Body panels, the Date step's Size ruler, what a format or
//  a face that cannot be chosen says, and the Date step alone (entered from
//  *Date Back* with no film edge: the date goes in the bare frame).

import SwiftUI

/// The Edge step's tools: one at a time, as the Pro controls do.
enum EdgeTool: String, CaseIterable, Identifiable, Sendable {
    /// *Edge Print* (2026-10-20): the brightness of the film's own name,
    /// numbers and barcode (`FilmEdgeSettings.edgeBrightness`), shown greyed.
    case gate = "Gate", holes = "Holes", light = "Light", print = "Edge Print", body = "Body"
    var id: String { rawValue }
}

struct FilmEdgeFlow: View {
    let frameID: LibraryFrame.ID
    var entry: FilmEdgeStep = .film
    /// Snapshot harness only: the state a drawing shows.
    var snapshot: Snapshot? = nil

    struct Snapshot {
        var draft: FrameEdit
        var status: DevelopStatus? = nil
        var tool: EdgeTool = .gate
        var sizing = false
        /// The Date step's control under its rule, where `sizing` does not say it (Brightness).
        var dateControl: DateControl? = nil
    }

    @Environment(AppServices.self) private var model
    @State private var session: OpenFrameSession?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let session, let frame = session.frame {
                FilmEdgeFlowPage(session: session, frame: frame, entry: entry, snapshot: snapshot)
            }
        }
        // Over the develop page this is that page's own session, so what the
        // flow changes is developed onto the page it returns to.
        .onAppear {
            if session == nil {
                session = model.session(for: frameID)
                session?.enter()
            }
            if snapshot == nil { PairWay.filmEdgeEntered() }
        }
        .onDisappear {
            session?.leave()
            session = nil
            // Left by the Format line on Half: now that this cover has gone, the page
            // under it is asked for the pair's second frame (design/pair v2, H2).
            if snapshot == nil { PairWay.filmEdgeLeft(of: frameID, on: model.router) }
        }
    }
}

// MARK: - the page

private struct FilmEdgeFlowPage: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let snapshot: FilmEdgeFlow.Snapshot?
    /// The frame's film edge and date when the flow opened: what Cancel restores.
    let opened: FrameEdit
    /// Entered from *Date Back* with no film edge: the flow is that one step.
    let dateAlone: Bool

    /// The step shown, and where a tap or Next may go from it: every step,
    /// from the first moment (`FilmEdgeJourney`).
    @State private var journey: FilmEdgeJourney
    private var step: FilmEdgeStep { journey.step }
    /// The film edge and the date under edit. Written to the frame when the
    /// flow leaves the guide, and by every control after it.
    @State private var draft: FrameEdit
    @State private var tool: EdgeTool
    @State private var dateControl: DateControl
    /// The framing when a drag began, and how far the finger had already
    /// travelled then (one left down after a pinch has).
    @State private var dragBase: (framing: Geometry, travelled: CGSize)?
    /// The framing when a pinch began.
    @State private var pinchBase: Geometry?
    /// Mac: the framing when a scroll zoom began.
    @State private var scrollBase: Geometry?
    /// The scroll's travel already applied: each step enlarges the framing as it is now (`scrollPlace`).
    @State private var scrollApplied: CGFloat = 0
    /// The picture carried past the end of its cut's travel, in points.
    @State private var nudge = CGSize.zero
    @State private var asksReset = false
    /// Mac: the flow's own Undo and Redo (`MacFlowHistory`).
    @State private var macHistory: MacFlowHistory<Step>

    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    init(session: OpenFrameSession, frame: LibraryFrame, entry: FilmEdgeStep, snapshot: FilmEdgeFlow.Snapshot?) {
        self.session = session
        self.frame = frame
        self.snapshot = snapshot
        let opened = session.edit
        self.opened = opened
        let alone = entry == .date && !(snapshot?.draft ?? opened).filmEdge.active
        dateAlone = alone
        var draft = snapshot?.draft ?? opened
        if snapshot == nil, !draft.filmEdge.active, draft.filmEdge.cameraSeed == 0, !alone {
            // A film edge that was never on: the turn follows the picture.
            draft.filmEdge.turn = draft.filmEdge.format.defaultTurn(pictureAspect: Self.pictureAspect(frame, draft))
        }
        _draft = State(initialValue: draft)
        _journey = State(initialValue: FilmEdgeJourney(entry: entry, dateAlone: alone))
        _tool = State(initialValue: snapshot?.tool ?? .gate)
        _dateControl = State(initialValue: snapshot?.dateControl ?? (snapshot?.sizing == true ? .size : .corner))
        _macHistory = State(initialValue: MacFlowHistory(Step(draft)))
    }

    /// The picture's shape as the user has it: turned, not cropped.
    static func pictureAspect(_ frame: LibraryFrame, _ edit: FrameEdit) -> Double {
        let a = frame.originalSize.aspect
        return edit.geometry.quarterTurns % 2 == 0 ? a : 1 / max(a, 0.0001)
    }

    private var source: CGSize { CGSize(width: frame.originalSize.width, height: frame.originalSize.height) }

    // The drawing's vertical rhythm, from the top of the safe area (y = 59).
    enum Y {
        static let preview: CGFloat = 372           // 100 → 472
        static let steps: CGFloat = 50              // 472 → 522, the rule on its bottom edge
    }

    var body: some View {
        padPage
        .resetAlert(step == .date ? L("Date Back") : step.title, isPresented: $asksReset) {
            switch step {
            case .date: draft.dateBack = DateBackSettings()
            case .film:
                let neutral = FilmEdgeSettings().format
                if StockCatalog.shared.stock(draft.params.filmStock)?.isMade(in: neutral) == true { draft.filmEdge.format = neutral }
                draft.filmEdge.mode = FilmEdgeSettings().mode
            case .frame:
                draft.filmEdge.framing = nil
                draft.filmEdge.turn = draft.filmEdge.format.defaultTurn(pictureAspect: Self.pictureAspect(frame, draft))
            case .edge:
                let d = FilmEdgeSettings()
                draft.filmEdge.gate = d.gate; draft.filmEdge.holes = d.holes
                draft.filmEdge.fog = d.fog; draft.filmEdge.leaks = d.leaks
                draft.filmEdge.frameNumber = d.frameNumber
            }
            commit()
        }
        .onChange(of: Step(draft)) { _, now in macHistory.observe(now) }
        .onChange(of: dragBase != nil || pinchBase != nil || scrollBase != nil) { _, now in macHistory.busy = now }
        // ⌘Z and ⇧⌘Z in the menu bar's Edit menu are this flow's while it is in front.
        .macFlowUndo(undo: { macUndo() }, redo: { macRedo() })
    }

    /// The window (`FlowDialogLayout.swift`, PAGES.md W-F1): the film on the picture side as tall as the
    /// window, and the bar, the steps, the step's controls and ‹ · ↺ · Next in the 393 pt column.
    private var padPage: some View {
        FlowDialogShape { size in
            FlowDialogColumns(size: size) { width in
                preview(width: width, height: size.height)
            } column: { column in
                VStack(spacing: 0) {
                    topBar
                    stepsBar(width: column)
                    controls(width: column)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    // MARK: top bar

    @ViewBuilder private var topBar: some View {
        // Mac (the owner, 2026-10-23): Cancel · the name · ↺ ↶ ↷ · Next (Develop on Date) at the top,
        // no row at the bottom, and no "n of 4": the steps say it. Back is the steps too.
        GeometryReader { geo in
            MacFlowBar(width: geo.size.width, title: dateAlone ? nil : L("Film Edge"), cancel: { cancel() },
                       canReset: true, reset: { asksReset = true },
                       canUndo: macHistory.canUndo, undo: { macUndo() },
                       canRedo: macHistory.canRedo, redo: { macRedo() },
                       action: step == .date ? L("Develop") : L("Next"), actionID: "film-edge.next") { next() }
        }
        .frame(height: MacFlowBar.height)
    }

    /// What the flow's Undo and Redo walk: the film edge and the date as the user set them. Whether
    /// the film edge is on is the flow's own doing (it goes on when the guide is left), not a step.
    struct Step: Equatable {
        var filmEdge: FilmEdgeSettings
        var dateBack: DateBackSettings
        var frameSeed: Int
        init(_ edit: FrameEdit) {
            filmEdge = edit.filmEdge
            filmEdge.active = false
            dateBack = edit.dateBack
            frameSeed = edit.frameSeed
        }
    }

    private func macApply(_ s: Step) {
        withAnimation(.easeOut(duration: 0.18)) {
            let on = draft.filmEdge.active
            draft.filmEdge = s.filmEdge
            draft.filmEdge.active = on
            draft.dateBack = s.dateBack
            draft.frameSeed = s.frameSeed
        }
        // Past the guide every edit reaches the frame; on the guide nothing is written yet.
        if !step.showsGuide { commit() }
        #if DEBUG
        if MacScrollZoom.logs {
            let c = draft.filmEdge.framing?.centre ?? CGPoint(x: 0.5, y: 0.5)
            NSLog("macflow film edge now %@ framing centre %.4f,%.4f width %.4f", draft.filmEdge.format.rawValue, c.x, c.y,
                  draft.filmEdge.framing?.crop.width ?? 1)
        }
        #endif
    }

    private func macUndo() { if let s = macHistory.undo() { macApply(s) } }
    private func macRedo() { if let s = macHistory.redo() { macApply(s) } }

    // MARK: the preview

    /// The draft with the film edge laid out whether or not it is on yet.
    private var film: ResolvedFilmEdge? { model.filmEdge(for: frame, edit: draft, forcing: true) }

    /// The stage, `height` tall: the host's 372 pt, or a window's picture side (`padPage`).
    private func preview(width: CGFloat, height: CGFloat = Y.preview) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.background
            if step.showsGuide {
                if let film { guide(film, width: width, height: height) }
            } else {
                developed(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// Where the guide's film sits: room above it for the GUIDE tag, as drawn
    /// (`m_guide_preview`), and inside the page's margins when the film is long.
    private func guidePlacement(_ film: ResolvedFilmEdge, width: CGFloat, height: CGFloat = Y.preview) -> FilmCanvasView.Placement {
        let mm = film.geometry.canvasMM
        let room = CGSize(width: width - 24, height: height - 46)
        let k = min(room.height / max(mm.height, 0.001), room.width / max(mm.width, 0.001))
        return .init(k: k, origin: CGPoint(x: (width - mm.width * k) / 2, y: 34 + (room.height - mm.height * k) / 2))
    }

    private func guide(_ film: ResolvedFilmEdge, width: CGFloat, height: CGFloat = Y.preview) -> some View {
        let place = guidePlacement(film, width: width, height: height)
        return ZStack(alignment: .topLeading) {
            FilmCanvasView(geometry: film.geometry, style: .guide, picture: frame.originalPicture ?? frame.picture,
                           sourceSize: source, framing: film.framing, pointSize: height, placement: place,
                           nudge: nudge)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                // Mac: a wheel or a two-finger scroll enlarges the picture in the gate about the
                // pointer, as a pinch does about the fingers (Sources/Mac/MacScrollZoom.swift).
                .macScrollZoom { phase, dy, at in scrollPlace(phase, travel: dy, at: at, film: film, place: place) }
                .gesture(snapshot == nil ? placeGesture(film, place: place) : nil)
            GuideTag().offset(x: max(12, place.origin.x), y: 6)
            if step == .frame {
                // the turn: the one button that decides the film's direction
                Text(draft.filmEdge.turnText(stockID: draft.params.filmStock))
                    .font(Theme.Font.ui(11)).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 11)
                    .frame(minWidth: 168, minHeight: 22)
                    .background(Capsule().fill(Theme.panel.opacity(0.85)))
                    .offset(x: 12, y: height - 34)
                Button { turnFilm() } label: {
                    TurnGlyph().frame(width: 42, height: 42)
                        .background(Circle().fill(Theme.panel.opacity(0.9)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L("Turn the film a quarter"))
                .offset(x: width - 34 - 21, y: height - 34 - 21)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("The film's guide over the undeveloped picture"))
    }

    /// The developed film (or, with no film edge, the bare frame and its date),
    /// with the develop bar on its bottom edge.
    private func developed(width: CGFloat, height: CGFloat = Y.preview) -> some View {
        let edit = snapshot?.draft ?? session.edit
        // The session's own develop, as the develop page shows it: the film is in it.
        let made = snapshot == nil ? session.developed : nil
        // The whole film, never Edit's crop of the finished picture: the film edge is being made here.
        let aspect = CGFloat(DevelopedFrameView.shownAspect(frame: frame, edit: edit, model: model, developed: made, cropsPrint: false))
        let area = CGSize(width: width, height: height)
        let fit = area.width / area.height > aspect ? CGSize(width: area.height * aspect, height: area.height)
                                                    : CGSize(width: area.width, height: area.width / aspect)
        return DevelopedFrameView(frame: frame, edit: edit, pointSize: max(fit.width, fit.height), developed: made, cropsPrint: false)
            .frame(width: fit.width, height: fit.height)
            .overlay(alignment: .bottom) { DevelopProgressBar(progress: status.progress) }
            .frame(width: area.width, height: area.height)
            .accessibilityLabel(L("The developed film"))
    }

    private var status: DevelopStatus { snapshot?.status ?? session.status }

    // MARK: placing the picture in the gate

    /// The picture's box in the preview, in points.
    private func shownBox(_ film: ResolvedFilmEdge, place: FilmCanvasView.Placement) -> CGRect {
        let (box, _, _) = film.geometry.pictureBox
        return CGRect(x: place.origin.x + box.minX * place.k, y: place.origin.y + box.minY * place.k,
                      width: max(box.width * place.k, 1), height: max(box.height * place.k, 1))
    }

    /// The framing `m` times enlarged about `at` (preview points): the point of the picture under
    /// it stays under it. No smaller than the handles allow, no larger than the gate's largest cut;
    /// back inside the picture by sliding first, smaller only where a straighten leaves no room.
    private func enlarged(_ base: Geometry, by m: CGFloat, at: CGPoint, shown: CGRect) -> Geometry {
        let m = max(m, 0.05)
        let full = FilmFraming.largest(format: draft.filmEdge.format, turn: draft.filmEdge.turn, source: source,
                                       photo: draft.geometry)
        let minW = Geometry.minSide / max(source.width, 1)
        let w = min(max(base.crop.width / m, minW), max(full.crop.width, minW))
        let ratio = w / max(base.crop.width, 1e-9)
        let h = base.crop.height * ratio
        let u = CGPoint(x: (at.x - shown.minX) / shown.width, y: (at.y - shown.minY) / shown.height)
        let under = base.sourcePoint(forOutput: u, imageSize: source)
        let c = base.centre
        let centre = CGPoint(x: under.x - (under.x - c.x) * ratio, y: under.y - (under.y - c.y) * ratio)
        var g = base
        g.crop = CropRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
        g = g.moved(by: .zero, in: source).fitted(in: source)
        g.intendedSize = CGSize(width: g.crop.width, height: g.crop.height)
        return g
    }

    /// Mac: a scroll enlarges the picture as the pinch does, about the pointer; 100 pt is ×1.8.
    private func scrollPlace(_ phase: MacScrollZoom.Phase, travel: CGFloat, at: CGPoint,
                             film: ResolvedFilmEdge, place: FilmCanvasView.Placement) {
        guard snapshot == nil else { return }
        switch phase {
        case .began, .changed:
            if scrollBase == nil {
                guard dragBase == nil, pinchBase == nil else { return }
                scrollBase = film.framing
                scrollApplied = 0
                nudge = .zero
            }
            guard scrollBase != nil else { return }
            // Step by step from the framing as it is (2026-11-05): travel spun past the largest or the
            // smallest had to be paid back before a turn the other way did anything.
            let step = travel - scrollApplied
            scrollApplied = travel
            guard step != 0 else { return }
            // The draft's own framing, which the last step set; the resolved one before the first.
            draft.filmEdge.framing = enlarged(draft.filmEdge.framing ?? film.framing, by: exp(step * 0.006), at: at, shown: shownBox(film, place: place))
            #if DEBUG
            if MacScrollZoom.logs, let f = draft.filmEdge.framing {
                NSLog("macscroll framing width %.4f centre %.4f,%.4f", f.crop.width, f.centre.x, f.centre.y)
            }
            #endif
        case .ended:
            scrollBase = nil
        }
    }

    private func placeGesture(_ film: ResolvedFilmEdge, place: FilmCanvasView.Placement) -> some Gesture {
        let shown = shownBox(film, place: place)
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard pinchBase == nil else { return }
                if dragBase == nil { dragBase = (film.framing, v.translation) }
                guard let base = dragBase else { return }
                let t = CGSize(width: v.translation.width - base.travelled.width,
                               height: v.translation.height - base.travelled.height)
                // The picture follows the finger, so the cut moves the other way.
                let n = CGPoint(x: 0.5 - t.width / shown.width, y: 0.5 - t.height / shown.height)
                let a = base.framing.sourcePoint(forOutput: CGPoint(x: 0.5, y: 0.5), imageSize: source)
                let b = base.framing.sourcePoint(forOutput: n, imageSize: source)
                let moved = base.framing.moved(by: CGSize(width: b.x - a.x, height: b.y - a.y), in: source)
                draft.filmEdge.framing = moved
                // What the picture's edge held back, the picture still gives at a third.
                let reached = base.framing.outputPoint(forSource: moved.centre, imageSize: source)
                let got = CGSize(width: (0.5 - reached.x) * shown.width, height: (0.5 - reached.y) * shown.height)
                nudge = CGSize(width: (t.width - got.width) * 0.3, height: (t.height - got.height) * 0.3)
            }
            .onEnded { _ in
                dragBase = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { nudge = .zero }
            }
        let pinch = MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil {
                    pinchBase = film.framing
                    dragBase = nil
                    nudge = .zero
                }
                guard let base = pinchBase else { return }
                // About the fingers: the point of the picture under them stays under them.
                draft.filmEdge.framing = enlarged(base, by: v.magnification, at: v.startLocation, shown: shown)
            }
            .onEnded { _ in pinchBase = nil }
        return drag.simultaneously(with: pinch)
    }

    /// ↻: the film a quarter turn round the picture. An odd turn swaps the
    /// gate between upright and across, so the cut starts again.
    private func turnFilm() {
        withAnimation(.easeOut(duration: 0.2)) {
            draft.filmEdge.turn = (draft.filmEdge.turn + 1) % 4
            let kept = draft.filmEdge.framing
            if let kept, !FilmFraming.fits(kept, format: draft.filmEdge.format, turn: draft.filmEdge.turn, source: source) {
                draft.filmEdge.framing = nil
            }
        }
    }

    // MARK: the steps

    private func stepsBar(width: CGFloat) -> some View {
        let steps = FilmEdgeStep.allCases
        let gap = (width - 32 - steps.map(\.width).reduce(0, +)) / 3
        return DrawnBand(height: Y.steps) {
            if !dateAlone {
                ForEach(steps) { s in
                    let x = 16 + steps.prefix(s.rawValue).map(\.width).reduce(0, +) + CGFloat(s.rawValue) * gap
                    let on = s == step
                    // Every step is open: what a step cannot use yet is greyed in its panel.
                    Button { go(to: s) } label: {
                        Text(s.title)
                            .font(Theme.Font.ui(13.5, on ? .semibold : .medium))
                            .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                            .frame(width: s.width, height: 27)
                            .background { if on { Capsule().fill(Theme.selection) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 1))
                    .allowsHitTesting(!on)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityHint(journey.writes(to: s) && !draft.filmEdge.active ? L("Puts the film edge on this frame.") : "")
                    .leading(x).top(11)
                    if s != .date {
                        StepChevron().leading(x + s.width + gap / 2 - 2).top(21)
                    }
                }
            }
            if dateAlone {
                // Mac: the bar has no room to promise the name in every language; the empty band has.
                DrawnText(L("Date Back"), 16, .semibold).frame(maxWidth: .infinity).baseline(31)
            }
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).top(Y.steps - 0.5)
        }
    }

    /// A step in the bar: any of them, at any time. Leaving the guide for the
    /// developed film puts the film edge on the frame, as Next from Frame does.
    private func go(to s: FilmEdgeStep) { make(journey.go(to: s)) }

    /// A move of the journey's, made: the film edge written first where the
    /// move asks, then the step shown, or the flow ended.
    private func make(_ move: FilmEdgeJourney.Move) {
        switch move {
        case .stay: return
        case .to(_, let writes):
            if writes { writeFilmEdge() }
            withAnimation(.easeOut(duration: 0.18)) { journey.arrive(move) }
        case .develop(let writes):
            // Develop ends the flow: whatever is outstanding is asked for now.
            if writes { writeFilmEdge() } else { commit() }
            router.dismissCover()
        }
    }

    // MARK: controls

    @ViewBuilder private func controls(width: CGFloat) -> some View {
        switch step {
        case .film:
            FilmStepPanel(frame: frame, draft: $draft, width: width, pick: { format in pick(format) },
                          // The flow's film edge goes on the frame first, as Next would write it;
                          // this flow goes, and when it has gone the sheet that asks for the pair's
                          // second frame comes over the page under it (design/pair v2, H2).
                          enterPair: frame.isPair ? nil : {
                              guard snapshot == nil else { return }
                              writeFilmEdge()
                              PairWay.leaveFilmEdge(of: frame.id, on: router)
                          })
        case .frame:
            FrameStepPanel(film: film, draft: $draft, source: source, photo: draft.geometry)
        case .edge:
            EdgeStepPanel(film: film, draft: $draft, tool: $tool, width: width,
                          editing: { down in if down { session.began(.shoot) } else { session.ended() } },
                          changed: { commit() })
        case .date:
            DateStepPanel(frame: frame, draft: $draft, control: $dateControl, width: width,
                          editing: { down in if down { session.began(.shoot) } else { session.ended() } },
                          changed: { commit() },
                          pick: { face in pick(face) })
        }
    }

    /// A format card was tapped.
    private func pick(_ format: FilmEdgeFormat) {
        guard format != draft.filmEdge.format else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            let wasHalfTurned = draft.filmEdge.turn >= 2
            draft.filmEdge.format = format
            // The gate lies the way the picture does; a half turn already chosen is kept.
            draft.filmEdge.turn = format.defaultTurn(pictureAspect: Self.pictureAspect(frame, draft)) + (wasHalfTurned ? 2 : 0)
            draft.filmEdge.framing = nil
            if !format.draws(draft.dateBack.style), let face = DateBackFace.allCases.first(where: format.draws) {
                draft.dateBack.style = face
            }
        }
    }

    /// A date face was tapped. LCD and Dots are the date, one at a time; Data is its own switch beside
    /// them (`DateBackSettings.tap`: date only, data only, or both).
    private func pick(_ face: DateBackFace) {
        var back = draft.dateBack
        back.tap(face)
        guard back != draft.dateBack else { return }
        draft.dateBack = back
        commit()
    }

    // MARK: writing the frame

    /// Leaving the guide (Next from Frame, or a tap on Edge or Date): the film
    /// edge goes on the frame, with the body it was shot through and the cut
    /// the guide showed — the largest one when Frame was passed by — and develops.
    private func writeFilmEdge() {
        guard !dateAlone else { return }
        draft = FilmEdgeJourney.written(draft, bodySeed: settings.bodySeed, framing: film?.framing)
        commit()
    }

    /// The draft's film edge and date, onto the frame: one film-side edit.
    private func commit() {
        guard snapshot == nil else { return }
        let (edge, date, seed) = (draft.filmEdge, draft.dateBack, draft.frameSeed)
        // The Frame step's straighten is the photo's own (2026-10-25: the framing takes the photo's
        // corrections, `FilmFraming`), so it goes on the frame's geometry, as the crop page's does.
        let (angle, src) = (draft.geometry.angle, source)
        session.change {
            $0.filmEdge = edge; $0.dateBack = date; $0.frameSeed = seed
            if $0.geometry.angle != angle { $0.geometry = $0.geometry.straightened(to: angle, in: src) }
        }
    }

    // MARK: actions

    private func next() { make(journey.next(filmEdgeOn: draft.filmEdge.active)) }

    /// The frame's film edge and date, as they were when the flow opened.
    private func cancel() {
        if snapshot == nil, session.edit.filmEdge != opened.filmEdge || session.edit.dateBack != opened.dateBack
            || session.edit.frameSeed != opened.frameSeed || session.edit.geometry.angle != opened.geometry.angle {
            let (edge, date, seed, geometry) = (opened.filmEdge, opened.dateBack, opened.frameSeed, opened.geometry)
            session.change { $0.filmEdge = edge; $0.dateBack = date; $0.frameSeed = seed; $0.geometry = geometry }
        }
        router.dismissCover()
    }
}

// MARK: - small drawn parts

/// `guide_tag`: what the preview is, said on it.
struct GuideTag: View {
    var text = L("GUIDE")
    var body: some View {
        Text(text)
            .font(Theme.Font.ui(10.5, .bold)).tracking(1.2)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize()
            .frame(width: 9 + CGFloat(text.count) * 7.2, height: 22)
            .background(Capsule().fill(Theme.panel.opacity(0.85)))
            .accessibilityHidden(true)
    }
}

/// The little chevron between two steps (`m_steps`): 4 across, 8 tall, in the rule colour.
private struct StepChevron: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 4, y: 4)); p.addLine(to: CGPoint(x: 0, y: 8))
        }
        .stroke(Theme.rule, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        .frame(width: 4, height: 8)
        .accessibilityHidden(true)
    }
}

/// `ic_turn`: a frame and a quarter-turn arrow, about (21, 21).
struct TurnGlyph: View {
    var color: Color = Theme.text
    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2 + 1
            var p = Path(roundedRect: CGRect(x: cx - 8, y: cy - 3, width: 11, height: 13), cornerRadius: 1.8)
            // M(cx−2, cy−9) a9 9 0 0 1 10 8: a quarter of a circle about (cx−2, cy)
            p.move(to: CGPoint(x: cx - 2, y: cy - 9))
            p.addArc(center: CGPoint(x: cx - 1.06, y: cy + 0.06), radius: 9.1,
                     startAngle: .degrees(-96), endAngle: .degrees(-7), clockwise: false)
            p.move(to: CGPoint(x: cx + 5, y: cy - 2))
            p.addLine(to: CGPoint(x: cx + 8, y: cy - 1))
            p.addLine(to: CGPoint(x: cx + 9.5, y: cy - 4.2))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
