//  PairOverlay.swift — the half-frame pair's marks on the canvas.
//
//  The canvas draws the piece; this draws what is said about it: a + on an
//  empty hole (the way a frame gets in), the picked hole's frame, the frame
//  picker where it was asked for, and — while a picture is being cropped
//  under its hole — the hole's outline and how to finish.
//
//  It takes the mouse only on its buttons. Everything else on the canvas is
//  the canvas view's: a click picks the hole under it, a right click opens
//  that hole's menu, and in the crop mode a drag moves the picture.

import SwiftUI

struct PairOverlay: View {
    @Bindable var session: Session

    var body: some View {
        GeometryReader { geo in
            let v = session.viewportSnapshot
            let rects = session.pairHoleRects
            if let pair = session.pair, v.image.width > 1 {
                ZStack(alignment: .topLeading) {
                    ForEach(HalfFramePair.Side.allCases, id: \.self) { side in
                        if let n = rects[side] {
                            let r = viewRect(n, v)
                            hole(side, pair: pair, rect: r)
                        }
                    }
                    if session.pairPlacing {
                        cropBar.position(x: geo.size.width / 2, y: geo.size.height - 30)
                    }
                }
            }
        }
    }

    private func viewRect(_ n: CGRect, _ v: ViewportState) -> CGRect {
        let w = v.image.width * v.scale, h = v.image.height * v.scale
        return CGRect(x: v.offset.x + n.minX * w, y: v.offset.y + n.minY * h, width: n.width * w, height: n.height * h)
    }

    @ViewBuilder
    private func hole(_ side: HalfFramePair.Side, pair: HalfFramePair, rect r: CGRect) -> some View {
        let picked = session.pairLayer.side == side
        let empty = pair[side] == nil
        // While its picture is moved or scaled: the frame's own preview where
        // the gesture has it, so the change is seen before it is developed.
        // Under the hole's frame, which is drawn next.
        if let drag = session.pairDrag, drag.side == side, let held = pair[side] {
            PairDragPreview(hole: held, placement: drag.live, aspect: pair.holeAspect)
                .frame(width: r.width, height: r.height)
                .clipped()
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
        // The picked hole's frame: the selection frame's own ink.
        if picked {
            Rectangle()
                .strokeBorder(Theme.selectionFrame,
                              style: StrokeStyle(lineWidth: session.pairPlacing ? 1.5 : 1,
                                                 dash: session.pairPlacing ? [6, 4] : []))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
        if empty {
            Button { session.pairLayer = side == .left ? .left : .right; session.pairPicker = side } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.text.opacity(0.14)).frame(width: 44, height: 44)
                        Image(systemName: "plus").font(.system(size: 20, weight: .regular)).foregroundStyle(Theme.text)
                    }
                    Text(L("Add Frame", zh: "添加照片"))
                        .font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
                }
                .frame(width: max(min(r.width, 160), 60), height: max(min(r.height, 120), 60))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Put a frame in this hole", zh: "在这一格放入照片"))
            .position(x: r.midX, y: r.midY)
        }
        // The picker's anchor: the middle of the hole it fills.
        Color.clear.frame(width: 1, height: 1)
            .position(x: r.midX, y: r.midY)
            .popover(isPresented: Binding(get: { session.pairPicker == side },
                                          set: { if !$0, session.pairPicker == side { session.pairPicker = nil } }),
                     arrowEdge: .bottom) {
                PairFramePicker(frames: session.pairCandidates,
                                used: Set([pair.left?.path, pair.right?.path].compactMap { $0 })) { url in
                    session.pairPicker = nil
                    session.setHole(side, to: url)
                }
            }
            .allowsHitTesting(false)
    }

    /// While a picture is cropped under its hole: what the gestures are, and
    /// the way out.
    private var cropBar: some View {
        HStack(spacing: 10) {
            Text(L("Drag to move the picture · scroll or pinch to scale", zh: "拖动移动画面 · 滚动或捏合缩放"))
                .font(Theme.Font.label).foregroundStyle(Theme.text)
            Button { _ = session.endPlacement() } label: {
                Text(L("Done", zh: "完成"))
                    .font(Theme.Font.value).foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).frame(height: Theme.Metric.controlHeight)
                    .background(Theme.text.opacity(0.16), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).frame(height: 34)
        .background(Theme.card.opacity(0.94), in: Capsule())
        .fixedSize()
    }
}

/// A filmstrip thumbnail dropped on the canvas goes into the hole under it
/// (or the first empty one). Only a pair takes the drop; for a frame the
/// window's own handler opens whatever was dropped, as before.
struct PairDrop: ViewModifier {
    @Bindable var session: Session

    func body(content: Content) -> some View {
        if session.pair != nil {
            content.onDrop(of: [.fileURL], delegate: Target(session: session))
        } else {
            content
        }
    }

    private struct Target: DropDelegate {
        let session: Session

        func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            let n = session.viewportSnapshot.normalised(atView: info.location)
            session.clicked(normalised: n)
            return DropProposal(operation: .copy)
        }

        func performDrop(info: DropInfo) -> Bool {
            guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
            let n = session.viewportSnapshot.normalised(atView: info.location)
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    session.draggedFrame = nil
                    _ = session.dropFrame(url, atNormalised: n)
                }
            }
            return true
        }
    }
}

/// The frame under a hole at a placement: what a crop gesture shows while it
/// is in flight and until its develop lands. Not the developed picture, but
/// the same rectangle of the same frame, framed and turned the same way.
struct PairDragPreview: View {
    let hole: HalfFramePair.Hole
    let placement: HalfFramePair.Placement
    let aspect: Double
    @State private var image: CGImage?

    private struct Key: Equatable { let path: String; let geometry: Geometry; let turns: Int }

    var body: some View {
        GeometryReader { geo in
            if let image {
                // Already turned (`framedPreview`), so the cut is taken as is.
                let source = CGSize(width: image.width, height: image.height)
                let cut = HalfFramePair.sourceRect(for: placement, source: source, aspect: aspect)
                // Cut first, then scaled: only the hole's worth of pixels is
                // resampled on a move. Scaled whole and offset, the picture was
                // drawn at up to four times the hole's size on every mouse
                // move, on the main thread, and the drag came in bursts.
                if let piece = image.cropping(to: cut.integral) {
                    Image(decorative: piece, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task(id: Key(path: hole.path, geometry: hole.geometry, turns: placement.quarterTurns)) {
            var framed = hole
            framed.placement.quarterTurns = placement.quarterTurns
            image = await Task.detached(priority: .userInitiated) { PairComposer.framedPreview(framed) }.value
        }
    }
}
