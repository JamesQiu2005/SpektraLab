//  PairPieceView.swift — a half-frame pair as a page draws it before it is developed.
//
//  design/pair (`gen_pair.piece`). The piece of film, its two 18 × 24 holes
//  and what is under each: a frame's picture, cut by the model's own
//  arithmetic (`HalfFramePair.sourceRect`), or unexposed film with the way a
//  frame gets in. **This is a guide, not a develop**: the pictures are the
//  frames' own previews, decoded at the size shown, and the film between them
//  is a flat dark ground where the engine develops the stock's own base. A
//  developed pair is the engine's one picture of the piece, shown as any
//  frame's develop is.
//
//  Nothing here decides where a hole is: `HalfFramePair.holeRects` does, the
//  same rectangles the engine is handed the pictures in.

import SwiftUI

/// The colours of a guide's unexposed film (`gen_pair.BASE`, `gen_overscan.WELL`).
enum PairInk {
    /// The piece's ground: the desktop's own for a pair's thumbnail, grey 0.06.
    static let base = Color(hex: 0x0F0F0F)
    /// An empty hole, a little lighter, so the two holes read on the film.
    static let well = Color(hex: 0x1A1A19)
}

struct PairPieceView: View {
    let pair: HalfFramePair
    /// The piece's size on the page, in points.
    let size: CGSize
    /// The layer that wears the white frame: a hole's own, or the whole piece for the film.
    var picked: HalfFramePair.Layer? = nil
    /// An empty hole's **+** and its words. A tile is too small for the words.
    var asksForFrames = true
    /// The frame a hole holds, from the library; nil when it is not there.
    let frame: (HalfFramePair.Hole) -> LibraryFrame?
    /// A tap on an empty hole's **+**.
    var onAdd: (HalfFramePair.Side) -> Void = { _ in }

    /// A hole's rectangle on the piece, in points.
    func rect(_ side: HalfFramePair.Side) -> CGRect {
        let n = pair.holeRects[side] ?? .zero
        return CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PairInk.base
            ForEach(HalfFramePair.Side.allCases, id: \.self) { side in
                let r = rect(side)
                hole(side, size: r.size)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            if let picked {
                // Selection is the white frame, never the accent. On the hole's own edge, as
                // the drawing strokes it; round the whole piece, a point outside it.
                let r = picked.side.map(rect) ?? CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                Rectangle().stroke(Theme.selectionFrame, lineWidth: 2)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder private func hole(_ side: HalfFramePair.Side, size: CGSize) -> some View {
        if let held = pair[side], let frame = frame(held) {
            PairHolePicture(frame: frame, hole: held, aspect: pair.holeAspect, size: size)
        } else if pair[side] != nil {
            // A frame that is no longer in the library: its hole says so.
            ZStack {
                PairInk.well
                if asksForFrames { DrawnText(L("Missing"), 13, .medium, Theme.dim) }
            }
        } else {
            ZStack {
                PairInk.well
                if asksForFrames {
                    Button { onAdd(side) } label: {
                        // `add_frame`: the disc's centre 10 pt above the hole's, its words 42 under it.
                        VStack(spacing: 0) {
                            PlusGlyph().frame(width: 44, height: 44)
                                .background(Circle().fill(Theme.text.opacity(0.14)))
                            DrawnText(L("Add Frame"), 13, .medium, Theme.secondaryText).padding(.top, 7.5)
                        }
                        .offset(y: 1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(L("Add a frame to this hole"))
                } else {
                    PlusGlyph(arm: 5, width: 1.4)
                }
            }
        }
    }
}

/// A frame's picture under its hole: the frame as its owner left it (its own
/// crop, turn and flips: `Hole.geometry`), turned by the placement, and the
/// model's cut of that scaled to fill the hole. The hole never moves.
struct PairHolePicture: View {
    let frame: LibraryFrame
    let hole: HalfFramePair.Hole
    /// The hole's shape, width over height.
    let aspect: Double
    /// The hole on the page, in points.
    let size: CGSize

    var body: some View {
        let source = CGSize(width: frame.originalSize.width, height: frame.originalSize.height)
        let framed = hole.geometry.outputSize(for: source)
        let turned = HalfFramePair.turned(framed, by: hole.placement)
        let cut = HalfFramePair.sourceRect(for: hole.placement, source: turned, aspect: aspect)
        // Points a pixel of the framed picture.
        let k = size.width / max(cut.width, 1)
        let turns = ((hole.placement.quarterTurns % 4) + 4) % 4
        picture(longEdge: max(framed.width, framed.height) * k, source: source)
            .frame(width: framed.width * k, height: framed.height * k)
            // Clockwise as seen; about its middle, which the frame below keeps where it was.
            .rotationEffect(.degrees(Double(turns) * 90))
            .frame(width: turned.width * k, height: turned.height * k)
            .offset(x: -cut.minX * k, y: -cut.minY * k)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .accessibilityLabel(frame.fileName)
    }

    /// The frame's own picture, decoded at the size it is shown and never
    /// larger (RAM first), through the frame's own geometry.
    @ViewBuilder private func picture(longEdge: CGFloat, source: CGSize) -> some View {
        if hole.geometry.isIdentity {
            FramePicture(picture: frame.picture, pointSize: longEdge, contentMode: .fill)
        } else {
            CroppedPicture(picture: frame.picture, pointSize: longEdge, contentMode: .fill, geometry: hole.geometry,
                           sourceSize: source)
        }
    }
}

/// `add_frame`'s **+**: two strokes, 16 pt across, as the drawing draws them.
struct PlusGlyph: View {
    var arm: CGFloat = 8
    var width: CGFloat = 1.8
    var color: Color = Theme.text
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var p = Path()
            p.move(to: CGPoint(x: c.x - arm, y: c.y)); p.addLine(to: CGPoint(x: c.x + arm, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - arm)); p.addLine(to: CGPoint(x: c.x, y: c.y + arm))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        .frame(minWidth: arm * 2 + 2, minHeight: arm * 2 + 2)
        .accessibilityHidden(true)
    }
}

/// A kept pair's own tile in the grid (`gen_pair.pair_tile`, design/pair/
/// the page layout): the piece whole on the tile's ground, never cut to
/// the square — its develop once the engine has made one, in its film when it
/// is on a strip, and its guide until then (`PairGuide`).
struct PairTile: View {
    let item: LibraryFrame
    /// The tile's side, in points.
    let side: CGFloat

    var body: some View {
        // The shape of what is shown: the develop's own, or the piece's.
        let aspect = CGFloat((item.developed?.size ?? item.displaySize).aspect)
        let room = max(side - 12, 1)
        let width = min(room, room * aspect)
        ZStack {
            Theme.panel
            FrameView(frame: item, pointSize: room, contentMode: .fit)
                .frame(width: width, height: width / max(aspect, 0.01))
        }
        .frame(width: side, height: side)
        .accessibilityLabel(L("A half-frame pair"))
    }
}

/// A pair as a tile shows it before it is kept: the piece in miniature on the
/// tile's ground, both frames whole, drawn from the frames' own previews.
struct PairTilePicture: View {
    let pair: HalfFramePair
    /// The tile's side, in points.
    let side: CGFloat
    let frame: (HalfFramePair.Hole) -> LibraryFrame?

    var body: some View {
        let mm = pair.pieceSizeMM
        let k = min((side - 12) / mm.width, (side - 12) / mm.height)
        ZStack {
            Theme.panel
            PairPieceView(pair: pair, size: CGSize(width: mm.width * k, height: mm.height * k), asksForFrames: false, frame: frame)
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityLabel(L("A half-frame pair"))
    }
}
