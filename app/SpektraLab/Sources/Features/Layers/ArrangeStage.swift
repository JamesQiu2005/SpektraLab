//  ArrangeStage.swift — 摆放 (Arrange): where a picture lies in its frame, in the page, as 裁剪 is
//  (design/layers/LAYERS-SPEC.md §6.4, PRD-D §3.6; the UX review's R5).
//
//  A pair's frame lies under its hole, a double's exposure over the whole frame; either is dragged, zoomed
//  (1–4×, never smaller than what it covers), turned a quarter and — a double's — flipped. **The stage is the
//  page's own canvas**: every move is written to the piece as it comes (`changePair`, `changeDouble`), so what
//  is shown is the develop itself — the film, the paper, and a double's Balance — at the live tier the moment
//  the pointer rests, and never a second picture of how it might look (R5: a cover would show the two
//  photographs added, without Balance). The canvas is put back to its fit while 摆放 is open, so a fraction
//  of the picture on screen is a fraction of the frame.
//
//  **One step of Undo for the whole visit** (gap G7): the page's history is held from the moment 摆放 opens
//  until Done (`OpenFrameSession.holdHistory`), every gesture inside it. Cancel writes the placements back as
//  they were, and so records nothing.

import SwiftUI

/// The picture being arranged, read and written the same way whichever piece it is of.
@MainActor struct ArrangeSubject {
    let session: OpenFrameSession
    let model: AppServices
    let frameID: LibraryFrame.ID
    let pick: LayerPick

    var placement: HalfFramePair.Placement? {
        switch pick {
        case .film, .mask: nil
        case .frame(let side): session.pair?[side]?.placement
        case .exposure(let position): session.double?[position]?.placement.base
        }
    }

    var flipped: Bool? {
        guard case .exposure(let position) = pick else { return nil }
        return session.double?[position]?.placement.flipped
    }

    /// The picture as its own cut frames it, unturned, and the shape of what it lies under.
    private var ground: (source: CGSize, aspect: Double)? {
        switch pick {
        case .film, .mask: return nil
        case .frame(let side):
            guard let pair = session.pair, let hole = pair[side], let id = hole.frame, let photo = model.library.frame(id) else { return nil }
            let source = hole.geometry.outputSize(for: CGSize(width: photo.originalSize.width, height: photo.originalSize.height))
            return (source, pair.holeAspect)
        case .exposure(let position):
            guard let double = session.double else { return nil }
            let framed = model.framed(double)
            guard let source = framed[position], let aspect = double.frameAspect(framed) else { return nil }
            return (source, aspect)
        }
    }

    func write(_ p: HalfFramePair.Placement) {
        switch pick {
        case .film, .mask: break
        case .frame(let side): model.changePair(frameID) { piece, _ in piece[side]?.placement = p.held }
        case .exposure(let position): model.changeDouble(frameID) { double, _ in double[position]?.placement.base = p.held }
        }
    }

    func dragged(_ origin: HalfFramePair.Placement, by d: CGSize) -> HalfFramePair.Placement {
        guard let ground else { return origin }
        return HalfFramePair.placement(origin, draggedBy: d, source: ground.source, aspect: ground.aspect)
    }

    func zoomed(_ origin: HalfFramePair.Placement, by factor: Double, about anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> HalfFramePair.Placement {
        guard let ground else { return origin }
        return HalfFramePair.placement(origin, zoomedBy: factor, about: anchor, source: ground.source, aspect: ground.aspect)
    }

    /// A gesture begins and ends as any film-side control's: the live tier while it moves, the guide once on lift.
    func began() { session.began(.shoot) }
    func ended() {
        session.ended()
        if session.double != nil { model.drawOwedDoubleGuide(frameID) }
    }
}

/// Over the canvas while 摆放 is open: the pointer moves the picture, not the page.
struct ArrangeOverlay: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pick: LayerPick
    /// The picture's shape as the canvas shows it.
    let aspect: CGFloat
    @Environment(AppServices.self) private var model
    @State private var dragBase: HalfFramePair.Placement?
    @State private var pinchBase: HalfFramePair.Placement?

    private var subject: ArrangeSubject { ArrangeSubject(session: session, model: model, frameID: frame.id, pick: pick) }

    var body: some View {
        GeometryReader { geo in
            let picture = Self.fit(aspect: aspect, in: geo.size)
            let region = region(in: picture)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                // What is being arranged: the hole, or the whole frame.
                Rectangle().strokeBorder(Theme.selectionFrame.opacity(0.9), lineWidth: 1)
                    .frame(width: region.width, height: region.height)
                    .offset(x: region.minX, y: region.minY)
                    .allowsHitTesting(false)
            }
            .gesture(drag(region: region))
            .simultaneousGesture(pinch(region: region))
        }
        .accessibilityElement()
        .accessibilityLabel(L("Arrange"))
        .accessibilityIdentifier("layers.arrange.stage")
    }

    /// The canvas's fit (`DevelopCanvas.fitSize`), centred.
    static func fit(aspect: CGFloat, in whole: CGSize) -> CGRect {
        let inset = (12 * 10 / 9 / InterfaceScale.padTarget).rounded()
        let area = CGSize(width: max(whole.width - inset * 2, 1), height: max(whole.height - inset * 2, 1))
        let a = max(aspect, 0.0001)
        let size = area.width / max(area.height, 1) > a
            ? CGSize(width: (area.height * a).rounded(), height: area.height)
            : CGSize(width: area.width, height: (area.width / a).rounded())
        return CGRect(x: (whole.width - size.width) / 2, y: (whole.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The part of the picture on screen the arranged picture lies under.
    private func region(in picture: CGRect) -> CGRect {
        guard case .frame(let side) = pick, let n = session.frameRects?[side] else { return picture }
        return CGRect(x: picture.minX + n.minX * picture.width, y: picture.minY + n.minY * picture.height,
                      width: max(n.width * picture.width, 1), height: max(n.height * picture.height, 1))
    }

    private func drag(region: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard pinchBase == nil else { return }
                if dragBase == nil { dragBase = subject.placement; subject.began() }
                guard let base = dragBase else { return }
                let d = CGSize(width: v.translation.width / region.width, height: v.translation.height / region.height)
                subject.write(subject.dragged(base, by: d))
            }
            .onEnded { _ in
                guard dragBase != nil else { return }
                dragBase = nil
                subject.ended()
            }
    }

    private func pinch(region: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil {
                    if dragBase != nil { dragBase = nil } else { subject.began() }
                    pinchBase = subject.placement
                }
                guard let base = pinchBase else { return }
                let anchor = CGPoint(x: ((v.startLocation.x - region.minX) / region.width).clamped(to: 0...1),
                                     y: ((v.startLocation.y - region.minY) / region.height).clamped(to: 0...1))
                subject.write(subject.zoomed(base, by: max(Double(v.magnification), 0.05), about: anchor))
            }
            .onEnded { _ in
                guard pinchBase != nil else { return }
                pinchBase = nil
                subject.ended()
            }
    }
}

/// The column while 摆放 is open: which picture, its zoom, turn and flip, and Cancel · Done.
struct ArrangeColumn: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let pick: LayerPick
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    private var stage: LayersStage { .shared }
    /// The piece as 摆放 found it: what Cancel puts back.
    @State private var openedPair: HalfFramePair?
    @State private var openedDouble: DoubleExposure?

    private var subject: ArrangeSubject { ArrangeSubject(session: session, model: model, frameID: frame.id, pick: pick) }
    private var rows: [LayerRow] {
        LayerRules.rows(session.layerPiece, has: { library.frame($0) != nil }).filter(LayerRules.arrangeable)
    }

    var body: some View {
        let placement = subject.placement ?? HalfFramePair.Placement()
        VStack(spacing: 0) {
            // Which picture: its name here, and another picture's row in the panel above moves 摆放 to it.
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Text(L("Arrange") + Fmt.dot + (rows.first { $0.pick == pick }?.name ?? ""))
                    .font(Theme.Font.ui(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(placedText(placement)).font(Theme.Font.ui(12, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .padding(.horizontal, 16).frame(height: FoldHeader<EmptyView, EmptyView>.height)
            ValueSlider(title: L("Zoom"),
                        value: Binding(get: { placement.scale },
                                       set: { z in subject.write(subject.zoomed(subject.placement ?? placement, by: z / max(subject.placement?.scale ?? 1, 0.0001))) }),
                        range: HalfFramePair.Placement.scaleRange, rest: 1, step: 0.01, text: { Fmt.times($0) },
                        onEditingChanged: { down in if down { subject.began() } else { subject.ended() } })
                .padding(.horizontal, 16).frame(height: 44)
                .accessibilityIdentifier("layers.arrange.zoom")
            HStack(spacing: 8) {
                Chip(title: L("Turn 90°"), height: 26, size: 12.5, padding: 12) {
                    var p = subject.placement ?? placement
                    p.quarterTurns = (p.quarterTurns + 1) % 4
                    subject.write(p)
                }
                .accessibilityIdentifier("layers.arrange.turn")
                if let flipped = subject.flipped, case .exposure(let position) = pick {
                    Chip(title: L("Flip Horizontally"), on: flipped, height: 26, size: 12.5, padding: 12) {
                        model.flipDouble(frame.id, position)
                    }
                    .accessibilityIdentifier("layers.arrange.flip")
                }
                Chip(title: L("Reset"), height: 26, size: 12.5, padding: 12, dim: placement.held == HalfFramePair.Placement()) {
                    subject.write(HalfFramePair.Placement())
                }
                .accessibilityIdentifier("layers.arrange.reset")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 40)
            Note(session.double != nil
                 ? L("Drag the picture to move it. It develops on film, at Balance, when you stop.")
                 : L("Drag the picture to move it. It develops on film when you stop."))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
            FoldRule()
            HStack(spacing: 10) {
                CapsuleButton(title: L("Cancel"), primary: false, height: 32) { cancel() }
                    .accessibilityIdentifier("layers.arrange.cancel")
                CapsuleButton(title: L("Done"), height: 32) { stage.arranging = nil }
                    .accessibilityIdentifier("layers.arrange.done")
            }
            .padding(.horizontal, 16).frame(height: 56)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.arrange.column")
        .onAppear {
            openedPair = session.pair
            openedDouble = session.double
            session.holdHistory()
        }
        .onDisappear { session.releaseHistory() }
    }

    private func placedText(_ placement: HalfFramePair.Placement) -> String {
        if case .exposure = pick { return DoubleExposure.placedText(DoubleExposure.Placement(base: placement)) }
        return PairWords.placed(placement)
    }

    /// The placements as they were: nothing has changed, so Undo gets no step.
    private func cancel() {
        if let opened = openedPair {
            model.changePair(frame.id) { piece, _ in
                for side in HalfFramePair.Side.allCases where piece[side]?.frame == opened[side]?.frame {
                    if let p = opened[side]?.placement { piece[side]?.placement = p }
                }
            }
        }
        if let opened = openedDouble {
            model.changeDouble(frame.id) { double, _ in
                for position in DoubleExposure.Position.allCases where double[position]?.frame == opened[position]?.frame {
                    if let p = opened[position]?.placement { double[position]?.placement = p }
                }
            }
        }
        stage.arranging = nil
    }
}
