//  LibraryParts.swift — the pieces the Library and Select share: a tile, a day's
//  header, the grid's grouping, the heart chip, and the frame shown large on top.
//
//  `library_v2()` and `select_mode()` in gen_flow.py draw these with the same
//  numbers: three columns, 2 pt gaps, square tiles; a day's name in 15 pt bold
//  with its date beside it in 13 pt dim, its baseline 10 pt above the tiles;
//  28 pt from a day's last row to the next day's baseline. A part used by the
//  library side alone lives here, beside its pages, not in the design system.

import SwiftUI

// MARK: the grid's grouping

/// A day's header: "Today 30 Sep", the name bold and the date quiet, on one
/// baseline. A band with that baseline at a fixed place in it, so the day's
/// tiles begin 10 pt under the baseline whatever height the system gives a
/// line of this type (a stack of paddings left them 1 to 1.5 pt high on the operating system).
struct DayHeader: View {
    let day: Date
    let now: Date

    /// The baseline from the band's top, and the band: the baseline and the
    /// drawings' 10 pt to the tiles, which follow the band with nothing between.
    static let baseline: CGFloat = 14.5
    static let height: CGFloat = baseline + 10
    /// From a day's last row to the next day's band: that day's baseline is
    /// 30 pt under the tiles (the grid's 2 pt gap and the drawings' 28).
    static let gap: CGFloat = 30 - baseline

    var body: some View {
        DrawnBand(height: Self.height) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.dayName(day, now: now)).font(Theme.Font.ui(15, .bold)).foregroundStyle(Theme.text)
                Text(Fmt.dayMonth(day)).font(Theme.Font.ui(13)).foregroundStyle(Theme.dim)
            }
            .lineLimit(1)
            .fixedSize()
            .leading(Theme.Metric.margin)
            .baseline(Self.baseline)
        }
    }
}

// MARK: a tile

/// One frame in the grid: its picture through its crop, filling a square; the
/// stock's dot; and whatever state it is in. The develop ring is the frame's
/// own develop (a shot or an import); the badge says where its original is.
struct LibraryTile: View {
    enum Mark: Equatable {
        case none
        /// The frame shown large on top: the white selection frame.
        case selected
        /// In Select: the pick circle, ticked or not.
        case pick(Bool)
    }

    let frame: LibraryFrame
    var mark: Mark = .none
    /// The original's badge opens Original missing (F3); nil leaves it a mark.
    var onBadge: (() -> Void)? = nil

    var body: some View {
        // The square's side; the picture behind it is decoded at the long edge
        // it is drawn at, which for a 3:2 frame filling a square is 1.5 × the side.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let side = geo.size.width
                    if frame.isPair {
                        // A half-frame pair: the piece whole on the tile's ground (design/pair).
                        PairTile(item: frame, side: side)
                    } else {
                        let a = max(frame.displayAspect, 1 / max(frame.displayAspect, 0.01))
                        FrameView(frame: frame, pointSize: side * CGFloat(a))
                            .frame(width: side, height: side)
                    }
                }
            }
            .clipped()
            .overlay { developState }
            .overlay(alignment: .bottomLeading) {
                // A pair's tile is drawn without the dot: its two pictures are small on it.
                if !frame.isPair { StockDot(color: stockColor, diameter: 8, onPicture: true).padding(6) }
            }
            .overlay(alignment: .topTrailing) { originalBadge }
            .overlay { selectionMark }
            .contentShape(Rectangle())
    }

    private var stockColor: Color {
        StockCatalog.shared.stock(frame.edit.params.filmStock)?.color ?? Theme.card
    }

    /// Developing: dimmed, with the accent ring. Queued or waiting: dimmer, the
    /// ring's track alone (gen_flow: 0.45 and 0.6 black).
    @ViewBuilder private var developState: some View {
        switch frame.develop {
        case .developing(let p):
            ZStack {
                Color.black.opacity(0.45)
                ProgressRing(progress: p, diameter: 26, lineWidth: 2.5)
            }
            .allowsHitTesting(false)
        case .queued, .waiting:
            ZStack {
                Color.black.opacity(0.6)
                ProgressRing(progress: nil, diameter: 26, lineWidth: 2.5)
            }
            .allowsHitTesting(false)
        case .developed, .failed:
            EmptyView()
        }
    }

    /// The preview is still the picture; a badge says where the original is.
    @ViewBuilder private var originalBadge: some View {
        switch frame.original {
        case .offline:
            Circle().fill(Color.black.opacity(0.7)).frame(width: 22, height: 22)
                .overlay { Icon(.diskOff, size: 22 * 0.62, color: Theme.text) }
                .padding(4)
                .accessibilityLabel(L("Its disk is not connected"))
        case .missing:
            Button { onBadge?() } label: {
                Circle().fill(Color.black.opacity(0.7)).frame(width: 22, height: 22)
                    .overlay { Icon(.alertSmall, color: Theme.danger) }
                    .padding(4)
                    // The badge is 22; a finger needs more.
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            // In Select the whole tile picks; the badge is only a mark there.
            .allowsHitTesting(onBadge != nil)
            .accessibilityLabel(L("Original missing"))
        case .available, .inCloud:
            EmptyView()
        }
    }

    @ViewBuilder private var selectionMark: some View {
        switch mark {
        case .none:
            EmptyView()
        case .selected:
            Rectangle().strokeBorder(Theme.selectionFrame, lineWidth: 3).allowsHitTesting(false)
        case .pick(let on):
            ZStack(alignment: .bottomTrailing) {
                if on {
                    Color.white.opacity(0.12)
                    Rectangle().strokeBorder(Theme.selectionFrame, lineWidth: 3)
                }
                PickCircle(on: on).padding(5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
        }
    }
}

// MARK: the heart chip

/// Favourites as a chip with a heart (B2): the white capsule when on, like
/// every chip. `Chip` holds a word; this one holds a glyph, at the drawing's
/// 36 × 26.
struct IconChip: View {
    let icon: SpkIcon
    var on = false
    var width: CGFloat = 36
    var height: CGFloat = 26
    var glyph: CGFloat = 13.6
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: glyph, color: on ? Theme.onSelection : Theme.secondaryText, weight: .medium)
                .frame(width: width, height: height)
                .background(Capsule().fill(on ? Theme.selection : Theme.card))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: the frame on top

/// The selected frame, shown large, as it will export: its picture through
/// its crop — or, when it wears a film edge, its film (`DevelopedFrameView`) —
/// fitted and centred on black.
///
/// The library drawing puts the frame in a 135 strip between its neighbours.
/// That strip was a drawing of a film, not the engine's: a frame is now shown
/// in the film it will actually export in, alone on its own canvas, so the
/// library, the develop page and the export agree.
struct TopFrame: View {
    let frame: LibraryFrame
    var previous: LibraryFrame? = nil
    var next: LibraryFrame? = nil

    @Environment(AppServices.self) private var model

    var body: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            DevelopedFrameView(frame: frame, pointSize: max(size.width, size.height))
                .frame(width: size.width, height: size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Theme.background)
        .clipped()
    }

    /// The frame's own shape — its film's when it has one — as large as the area holds.
    private func fitted(in area: CGSize) -> CGSize {
        let a = CGFloat(max(DevelopedFrameView.shownAspect(frame: frame, edit: frame.edit, model: model), 0.01))
        guard area.width > 0, area.height > 0 else { return .zero }
        return area.width / area.height > a
            ? CGSize(width: area.height * a, height: area.height)
            : CGSize(width: area.width, height: area.width / a)
    }
}

/// Direction of a page transition.
enum FramePager {
    /// Which way a swipe that lifted turns: +1 the next frame, −1 the
    /// previous, 0 none. It goes the way the finger went — far enough, or
    /// still moving that way as it lifted — and stays when the finger
    /// flicked back at the end. Never the other way: a lift's last sample
    /// can point backwards, and a page must not turn against the finger.
    static func turn(translation t: CGFloat, predicted p: CGFloat, width w: CGFloat) -> Int {
        let fling = p - t
        let way: CGFloat
        if abs(t) >= 4 { way = t < 0 ? -1 : 1 }
        else if abs(fling) >= w * 0.12 { way = fling < 0 ? -1 : 1 }
        else { return 0 }
        if fling * way < -w * 0.15 { return 0 }
        let goes = abs(t) > w * 0.4 || fling * way > w * 0.12 || p * way > w * 0.3
        return goes ? (way < 0 ? 1 : -1) : 0
    }
}

// MARK: rows in a box

extension View {
    /// The hairline under a row, drawn on the row's last point rather than
    /// stacked below it: a box of n rows is then n × the row height, as the
    /// drawings draw it (`sep` sits on the boundary between two rows).
    func hairlineBelow(leading: CGFloat = 14) -> some View {
        overlay(alignment: .bottom) { RowSeparator(leading: leading) }
    }
}
