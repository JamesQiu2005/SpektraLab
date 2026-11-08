//  LatitudeMeter.swift — the scene against the film's held window.
//
//  The desktop's Latitude graph (v4), on the card above the develop tabs.
//  Inside the window the histogram is a light
//  fill; beyond it the fill drops to near the plot — those stops print,
//  flattened.
//
//  It is a measurement, never a setting. On the develop page the numbers are
//  the engine's `spk_scene_latitude` (RFC-023), asked of the page's own
//  session after each develop: the frame's histogram on a stop axis and the
//  two boundaries the film and paper hold between (`LatitudeReadout`,
//  `SceneLatitude.swift`). Nothing there is drawn by eye. The drawings' own
//  library carries the drawing's reading (`LatitudeReadout.developDemo`).

import SwiftUI

/// The plot alone: histogram, window, and the window's two edges.
struct LatitudePlot: View {
    let readout: LatitudeReadout
    /// Scene Placement's marks, on each side that is on: a dashed line where
    /// that end of the scene was, and the stops it was moved, shaded
    /// (`PlacementSpan`).
    var showsPlacement = false

    var body: some View {
        Canvas { ctx, size in
            let span = readout.hiEV - readout.loEV
            // A window with no scene in it (the viewfinder's meter before its first reading): the two edges.
            guard span > 0 else { return }
            func x(_ ev: Double) -> CGFloat { size.width * CGFloat((ev - readout.loEV) / span) }
            let top: CGFloat = 2, base = size.height
            // A reading's first and last samples may sit a little past the axis.
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            var hist = Path()
            if readout.bins.count > 1 {
                hist.move(to: CGPoint(x: x(readout.binsFromEV), y: base))
                for (i, v) in readout.bins.enumerated() {
                    hist.addLine(to: CGPoint(x: x(readout.binEV(i)), y: base - CGFloat(v) * (base - top)))
                }
                hist.addLine(to: CGPoint(x: x(readout.binsToEV), y: base))
                hist.closeSubpath()
            }
            ctx.fill(hist, with: .color(Theme.latitudeBeyond))
            let w0 = x(readout.shadowEV), w1 = x(readout.highlightEV)
            var inside = ctx
            inside.clip(to: Path(CGRect(x: w0, y: 0, width: max(w1 - w0, 0), height: size.height)))
            inside.fill(hist, with: .color(Theme.latitudeInside))
            if showsPlacement {
                let spans: [(from: CGFloat, to: CGFloat)] = [readout.highlightPlaced, readout.shadowPlaced].compactMap { span in
                    span.map { (x($0.line), x($0.reach)) }
                }
                for s in spans {
                    ctx.fill(Path(CGRect(x: min(s.from, s.to), y: 0, width: abs(s.to - s.from), height: size.height)),
                             with: .color(Theme.text.opacity(0.07)))
                    var knee = Path()
                    knee.move(to: CGPoint(x: s.from, y: 0)); knee.addLine(to: CGPoint(x: s.from, y: base))
                    ctx.stroke(knee, with: .color(Theme.latitudeInsideEdge),
                               style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                }
            }
            for wx in [w0, w1] {
                var edge = Path()
                edge.move(to: CGPoint(x: wx, y: 0)); edge.addLine(to: CGPoint(x: wx, y: base))
                ctx.stroke(edge, with: .color(Theme.latitudeInsideEdge), lineWidth: 0.8)
            }
        }
        .accessibilityLabel(L("Latitude: \(readout.heldText)"))
    }
}

/// `latitude_card`: the card above the develop tabs. A tap on its head folds
/// the plot away and leaves the line (the owner, 2026-10-04: "latitude should
/// be collapsible on its own"); the page gives the picture the room.
///
/// With no reading — the page's develop has not landed, or the frame could
/// not be measured — the card keeps its place and its axis, and its line says
/// which (`note`). It never draws a reading that is not this frame's.
struct LatitudeCard: View {
    let readout: LatitudeReadout?
    /// What the head says where there is no reading: "Measuring", or why not.
    var note: String? = nil
    var showsPlacement = false
    /// Whose scene it is, on a half-frame pair: "Right frame" (design/pair v2).
    /// One frame of the piece is read at a time, and the card says which.
    var name: String? = nil
    /// Folded to its head alone; nil is a card that does not fold.
    var collapsed: Binding<Bool>? = nil

    /// Where the card's parts sit, from its top (`gen_edit_v2.latitude_card`:
    /// 76 pt whole, which the page's layout gives it — `DevelopLayout`).
    private enum Y {
        /// The card folded to its head.
        static let folded: CGFloat = 30
        /// The title's and the reading's baseline.
        static let title: CGFloat = 19
        /// Where the plot's box starts, and how tall it is: 26…57, the
        /// histogram's own top 2 pt inside it, its base the box's bottom.
        static let plotTop: CGFloat = 26
        static let plot: CGFloat = 31
        /// The axis's numbers, under the base: their baseline at 69.
        static let axis: CGFloat = 19
    }

    private var isCollapsed: Bool { collapsed?.wrappedValue ?? false }
    /// The axis, which is the reading's, and the drawing's without one.
    private var loEV: Double { readout?.loEV ?? -8 }
    private var hiEV: Double { readout?.hiEV ?? 8 }

    var body: some View {
        VStack(spacing: 0) {
            // The head is as tall as the folded card while it is folded, and
            // ends where the plot begins while it is not: the title's baseline
            // is the same in both, so a fold moves nothing but the plot.
            DrawnBand(height: isCollapsed ? Y.folded : Y.plotTop) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(L("Latitude")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                    if collapsed != nil {
                        // `chevron_down`: 7 wide, 1.4 pt, its middle 10 pt past
                        // the title and 4.5 above its baseline.
                        Icon(.chevronDown, size: 19.25, color: Theme.dim)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                            .frame(width: 7, height: 7)
                            .offset(y: -1)
                            .padding(.leading, 6.5)
                    }
                    if let name {
                        // `gen_pair.latitude_card(name:)`: 11 pt, 8 pt past the title's own end.
                        Text(name).font(Theme.Font.ui(11, .medium)).foregroundStyle(Theme.secondaryText)
                            .lineLimit(1).fixedSize()
                            .padding(.leading, 8)
                    }
                    Spacer(minLength: 8)
                    Text(readout?.heldText ?? note ?? "").font(Theme.Font.ui(11)).foregroundStyle(Theme.dim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .baseline(Y.title)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let collapsed else { return }
                withAnimation(.easeOut(duration: 0.2)) { collapsed.wrappedValue.toggle() }
            }
            .accessibilityAddTraits(collapsed != nil ? .isButton : [])
            .accessibilityHint(collapsed != nil ? (isCollapsed ? L("Shows the plot") : L("Folds the plot away")) : "")
            if !isCollapsed { plot }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.plot))
        .clipped()
    }

    private var plot: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let readout {
                        LatitudePlot(readout: readout, showsPlacement: showsPlacement)
                    }
                    Rectangle().fill(Theme.rule).frame(height: 1).offset(y: geo.size.height - 0.5)
                    if let readout {
                        // The window's two boundaries, named outside it — or
                        // inside, where the card has no room outside: a wide
                        // film's boundary can sit at the axis's end, or past it.
                        let span = readout.hiEV - readout.loEV
                        let w0 = geo.size.width * CGFloat((readout.shadowEV - readout.loEV) / span)
                        let w1 = geo.size.width * CGFloat((readout.highlightEV - readout.loEV) / span)
                        Text(LatitudeReadout.stopText(readout.shadowEV))
                            .font(Theme.Font.ui(9, .semibold)).foregroundStyle(Theme.secondaryText)
                            .fixedSize().position(x: LatitudeReadout.labelX(shadowEdge: w0), y: 3)
                        Text(LatitudeReadout.stopText(readout.highlightEV))
                            .font(Theme.Font.ui(9, .semibold)).foregroundStyle(Theme.secondaryText)
                            .fixedSize().position(x: LatitudeReadout.labelX(highlightEdge: w1, width: geo.size.width), y: 3)
                    }
                }
            }
            .frame(height: Y.plot)
            // −8 … +8, every four stops.
            GeometryReader { geo in
                ForEach(0..<5, id: \.self) { k in
                    let ev = loEV + Double(k) * (hiEV - loEV) / 4
                    Text(ev == 0 ? "0" : (ev < 0 ? "−" : "+") + String(format: "%.0f", abs(ev)))
                        .font(Theme.Font.ui(9)).foregroundStyle(Theme.dim)
                        .fixedSize().position(x: geo.size.width * CGFloat(k) / 4, y: 8)
                }
            }
            .frame(height: Y.axis)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
