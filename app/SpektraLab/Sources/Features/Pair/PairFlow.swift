//  PairFlow.swift — how a half-frame pair is made, and the page a frame's picture is placed on.
//
//  design/pair v2 (`design/src/gen_pair_v2.py`). Until 2026-10-10 this was the
//  pair's own page — the piece, three layers, a frame's exposure, the camera,
//  the spacing — reached from the develop page's Frame tab. The owner, that
//  day: the pair is "a really important worth being taken out standalone
//  feature, instead of like current way stuffed all the way inside". So the
//  layers and everything they hold are the pair's darkroom now (the develop
//  page on a pair, `Features/Develop`), and what is left here is two things:
//
//  - **`PairStart.make`**: what a pair starts as, from the frames it is made
//    of (the desktop's `Session.makePair`, `newPair`, `enterPair`,
//    `adoptPair`). `AppServices.makePair` keeps what this makes, and the pair's
//    darkroom opens on it: no page stands between.
//  - **`PairPlaceFlow`** (H8): a frame's picture placed under its hole, where
//    Crop is for a photograph — a page of its own, with Cancel and Done.
//
//  **Placing a picture.** The hole never moves; the picture does: a drag
//  moves it, a pinch enlarges it about the fingers, *Turn* turns it a quarter.
//  The desktop has a mode for this on its canvas (*Crop on the Canvas*, then
//  *Done*); the host's develop page already gives a drag and a pinch on its
//  picture to looking closer, so placing has its own page, as Crop has. The
//  frame that is touched is the frame that moves, so both can be placed in one
//  visit. The arithmetic is the desktop's
//  (`HalfFramePair.placement(_:draggedBy:…)`, `…zoomedBy:about:…`).
//
//  **What the piece is drawn from.** The frames' own previews, decoded at the
//  size shown (`PairPieceView`): a guide, tagged as one. Nothing is developed
//  on this page — RFC-036 §4, there is no live render; *Done* writes the
//  placements to the pair (`AppServices.changePair`) and the darkroom under this
//  page develops the piece once.

import SwiftUI

/// How the pair's page is entered.
enum PairEntry: Equatable, Hashable, Sendable {
    /// From the library's Select: the picked frames fill the holes in the
    /// library's own order — two fill both, one fills the first, none leaves
    /// both empty (the desktop's New Half-Frame Pair).
    case new(first: LibraryFrame.ID?, second: LibraryFrame.ID?)
    /// From a half frame's Film Edge: the frame becomes the first hole, cut as
    /// its film edge framed it, and its film edge carries over (the desktop's
    /// *Enter Half-Frame Pair*, under Format while it reads Half).
    case halfFrame(LibraryFrame.ID)
    /// A pair made before: its item in the library (`LibraryFrame.pair`).
    case kept(LibraryFrame.ID)
}

/// What a page starts from: the piece, its look, the layer picked first.
struct PairStart: Equatable {
    var pair: HalfFramePair
    var look: FrameEdit
    var layer: HalfFramePair.Layer
    /// The pair's item in the library when it is one made before.
    var keptID: LibraryFrame.ID? = nil
    /// The frame the page is entered with, when it is entered with one: it
    /// keeps a hole on this page (`HalfFramePair.mayChange`). Nil when the
    /// page opens on two frames or on none.
    var origin: LibraryFrame.ID? = nil

    /// A frame as a hole takes it: the library's own id, its file's name, and
    /// mirrors of its decode and of the cut it is shown with — the photo's
    /// crop, or Film Edge's own framing while it wears one. The shot stays
    /// the frame's.
    static func hole(for frame: LibraryFrame) -> HalfFramePair.Hole {
        HalfFramePair.Hole(path: frame.fileName, frame: frame.id, sourceEdit: frame.edit,
                           sourceGeometry: frame.pictureGeometry)
    }

    /// The desktop's `Session.makePair`, `newPair`, `enterPair` and `adoptPair`.
    @MainActor
    static func make(_ entry: PairEntry, library: FrameCatalog) -> PairStart {
        switch entry {
        case .kept(let id):
            guard let item = library.frame(id), var pair = item.pair else { return make(.new(first: nil, second: nil), library: library) }
            // The shot stays the frame's: read again every time the pair is opened.
            for side in HalfFramePair.Side.allCases {
                if let frame = library.frame(pair[side]?.frame) {
                    pair.mirror(side, decode: frame.edit.decode, geometry: frame.pictureGeometry)
                }
            }
            // `onStrip` as it was kept: a pair's film edge is the pair's own switch, and its
            // look wears none (`FrameEdit.asPairLook`).
            return PairStart(pair: pair, look: item.edit, layer: .film, keptID: id, origin: pair.soleFrame)

        case .new(let first, let second):
            // The library's order, not the order they were picked in.
            let order = library.grid().flatMap(\.frames).map(\.id)
            // A pair is a piece of film, not a photograph: it fills no hole.
            let picks = [first, second].compactMap { $0 }
                .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
                .compactMap { library.frame($0) }.filter { !$0.isPair }
            return start(frames: picks, keepFilmEdge: false)

        case .halfFrame(let id):
            return start(frames: [library.frame(id)].compactMap { $0 }.filter { !$0.isPair }, keepFilmEdge: true)
        }
    }

    private static func start(frames: [LibraryFrame], keepFilmEdge: Bool) -> PairStart {
        var pair = HalfFramePair()
        pair.left = frames.first.map(hole(for:))
        pair.right = frames.count > 1 ? hole(for: frames[1]) : nil
        // A landscape first frame is the camera turned: the holes are stacked.
        if let first = frames.first { pair.turned = first.displaySize.width > first.displaySize.height }
        let look = HalfFramePair.look(from: frames.first?.edit ?? .default, keepFilmEdge: keepFilmEdge)
        pair.onStrip = look.filmEdge.active
        // One frame in: the empty hole is the one to fill.
        let layer: HalfFramePair.Layer = pair.left != nil && pair.right == nil ? .right : .film
        // And that frame is what the pair is of: it stays in it (the owner, 2026-10-09).
        return PairStart(pair: pair, look: look, layer: layer, origin: pair.soleFrame)
    }
}

// MARK: - placing a frame's picture (H8)

struct PairPlaceFlow: View {
    let pairID: LibraryFrame.ID
    let side: HalfFramePair.Side
    /// Snapshot harness only: the piece a drawing shows.
    var snapshot: HalfFramePair? = nil

    @Environment(FrameCatalog.self) private var library

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let pair = snapshot ?? library.frame(pairID)?.pair {
                PairPlacePage(pairID: pairID, pair: pair, side: side, isSnapshot: snapshot != nil)
            }
        }
    }
}

private struct PairPlacePage: View {
    let pairID: LibraryFrame.ID
    let isSnapshot: Bool
    /// The piece as it was when the page opened: what Cancel leaves.
    private let opened: HalfFramePair

    @State private var pair: HalfFramePair
    @State private var side: HalfFramePair.Side
    /// The placement when a drag began, the hole it is in, and how far the
    /// finger had already travelled (one left down after a pinch has).
    @State private var dragBase: (side: HalfFramePair.Side, placement: HalfFramePair.Placement, travelled: CGSize)?
    @State private var pinchBase: (side: HalfFramePair.Side, placement: HalfFramePair.Placement)?

    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library

    init(pairID: LibraryFrame.ID, pair: HalfFramePair, side: HalfFramePair.Side, isSnapshot: Bool) {
        self.pairID = pairID
        self.isSnapshot = isSnapshot
        opened = pair
        _pair = State(initialValue: pair)
        // A hole with a frame in it: the one asked for, or the other.
        _side = State(initialValue: pair[side] != nil || pair[side.other] == nil ? side : side.other)
    }

    private func frame(_ hole: HalfFramePair.Hole) -> LibraryFrame? { library.frame(hole.frame) }

    var body: some View {
        padPage
            .macPageActions(confirm: { done() }, cancel: { router.dismissCover() })
    }

    private var doneRow: some View {
        HStack {
            Spacer(minLength: 0)
            CapsuleButton(title: L("Done"), width: 112) { done() }
        }
        .padding(.trailing, Theme.Metric.margin)
        .frame(height: PairLayout.actions)
        .padding(.bottom, PairLayout.actionsBottom)
    }

    /// The window (`FlowDialogLayout.swift`): the piece on the picture side as tall as the window, and the bar,
    /// the controls and Done in the 393 pt column.
    private var padPage: some View {
        FlowDialogShape { size in
            FlowDialogColumns(size: size) { width in
                preview(width: width, height: size.height)
            } column: { _ in
                VStack(spacing: 0) {
                    topBar
                    // The rule is on the controls' top edge and takes no room of its own (`q0`).
                    controls.overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule) }
                    Spacer(minLength: 0)
                    doneRow
                }
            }
        }
    }

    private var topBar: some View {
        DrawnBand(height: PairLayout.bar) {
            TextButton(title: L("Cancel"), color: Theme.secondaryText) { router.dismissCover() }
                .clearsWindowControls()
                .leading(16).baseline(24)
            DrawnText(pair.title(.init(side)), 16, .semibold).frame(maxWidth: .infinity).baseline(24)
        }
    }

    // MARK: the piece

    private func preview(width: CGFloat, height: CGFloat) -> some View {
        let r = PairLayout.piece(mm: pair.pieceSizeMM, room: CGSize(width: width, height: height))
        return ZStack(alignment: .topLeading) {
            Theme.background
            PairPieceView(pair: pair, size: r.size, picked: .init(side), asksForFrames: false, frame: frame)
                .offset(x: r.minX, y: r.minY)
            GuideTag().offset(x: max(PairLayout.pieceMargin, r.minX), y: PairLayout.tagTop)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(isSnapshot ? nil : placeGesture(piece: r))
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in touched(tap.location, piece: r) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("The piece of film: a guide over the frames' own pictures"))
    }

    /// The hole under a point of the preview; nil on the film between and around them.
    private func hole(at p: CGPoint, piece r: CGRect) -> HalfFramePair.Side? {
        guard r.width > 0, r.height > 0 else { return nil }
        let n = CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
        return pair.holeRects.first { $0.value.contains(n) }?.key
    }

    /// A touch on a frame makes it the one being placed.
    private func touched(_ p: CGPoint, piece r: CGRect) {
        guard let hit = hole(at: p, piece: r), pair[hit] != nil, hit != side else { return }
        withAnimation(.easeOut(duration: 0.15)) { side = hit }
    }

    /// A hole on the page, and its picture as framed (what a placement moves).
    private func placing(_ side: HalfFramePair.Side, piece r: CGRect) -> (hole: CGRect, source: CGSize)? {
        guard let held = pair[side], let frame = frame(held), let n = pair.holeRects[side] else { return nil }
        let hole = CGRect(x: r.minX + n.minX * r.width, y: r.minY + n.minY * r.height,
                          width: max(n.width * r.width, 1), height: max(n.height * r.height, 1))
        let source = held.geometry.outputSize(for: CGSize(width: frame.originalSize.width, height: frame.originalSize.height))
        return (hole, source)
    }

    private func placeGesture(piece r: CGRect) -> some Gesture {
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { v in
                guard pinchBase == nil else { return }
                if dragBase == nil {
                    // The frame that is touched is the frame that moves.
                    guard let hit = hole(at: v.startLocation, piece: r), let held = pair[hit] else { return }
                    side = hit
                    dragBase = (hit, held.placement, v.translation)
                }
                guard let base = dragBase, let at = placing(base.side, piece: r) else { return }
                let d = CGSize(width: (v.translation.width - base.travelled.width) / at.hole.width,
                               height: (v.translation.height - base.travelled.height) / at.hole.height)
                pair[base.side]?.placement = HalfFramePair.placement(base.placement, draggedBy: d, source: at.source,
                                                                     aspect: pair.holeAspect)
            }
            .onEnded { _ in dragBase = nil }
        let pinch = MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil {
                    let hit = hole(at: v.startLocation, piece: r) ?? side
                    guard let held = pair[hit] else { return }
                    side = hit
                    pinchBase = (hit, held.placement)
                    dragBase = nil
                }
                guard let base = pinchBase, let at = placing(base.side, piece: r) else { return }
                // About the fingers where they are on the hole; about its middle otherwise.
                var anchor = CGPoint(x: 0.5, y: 0.5)
                if at.hole.contains(v.startLocation) {
                    anchor = CGPoint(x: (v.startLocation.x - at.hole.minX) / at.hole.width,
                                     y: (v.startLocation.y - at.hole.minY) / at.hole.height)
                }
                pair[base.side]?.placement = HalfFramePair.placement(base.placement, zoomedBy: max(v.magnification, 0.05),
                                                                     about: anchor, source: at.source, aspect: pair.holeAspect)
            }
            .onEnded { _ in pinchBase = nil }
        return drag.simultaneously(with: pinch)
    }

    // MARK: the controls

    private var controls: some View {
        typealias Y = PairLayout.Place
        let placement = pair[side]?.placement ?? HalfFramePair.Placement()
        return DrawnBand(height: PairLayout.placeControls) {
            DrawnText(L("Picture"), PairLayout.label, .semibold).leading(16).baseline(Y.picture)
            DrawnText(Fmt.times(placement.scale), PairLayout.label, .semibold).monospacedDigit()
                .trailingInset(16).baseline(Y.picture)
            HStack(spacing: 8) {
                Chip(title: L("Turn")) { pair[side]?.placement.quarterTurns = (placement.quarterTurns + 1) % 4 }
                Chip(title: L("Reset"), dim: placement == HalfFramePair.Placement()) {
                    withAnimation(.easeOut(duration: 0.18)) { pair[side]?.placement = HalfFramePair.Placement() }
                }
            }
            .leading(16).top(Y.chips)
            note(L("Drag and pinch the picture under its hole. The hole never moves.")).baseline(Y.note)
            if pair.isFilled { note(L("Click the other frame to place that one.")).baseline(Y.note + Y.noteLead) }
        }
    }

    /// A line of the page's own words: one line, set smaller before it leaves its frame.
    private func note(_ text: String) -> some View {
        DrawnText(text, 11.5, .medium, Theme.dim, fit: true).spanning(leading: 16, trailing: 16)
    }

    /// Each frame's placement, written to the pair: the darkroom under this
    /// page composes the piece again, once.
    private func done() {
        guard !isSnapshot else { return }
        let placed = pair
        if HalfFramePair.Side.allCases.contains(where: { placed[$0]?.placement.held != opened[$0]?.placement.held }) {
            model.changePair(pairID) { kept, _ in
                for side in HalfFramePair.Side.allCases where kept[side]?.frame == placed[side]?.frame {
                    if let p = placed[side]?.placement.held { kept[side]?.placement = p }
                }
            }
        }
        router.dismissCover()
    }
}
