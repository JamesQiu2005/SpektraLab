//  LatitudeSection.swift — how much of the frame this film and paper hold.
//
//  The Pre-Dev tab's first section (v4), and `design/prototypes/latitude-
//  graph-prototype.svg` made live. Read it like Lightroom's depth-of-field
//  bar, except that it cannot be dragged and it measures the medium:
//
//  - the **histogram** is the frame on the stop axis, relative to the metered
//    mid-grey, *after* Scene Placement (the engine's placed histogram), with
//    a square-root height so one bright area cannot flatten the rest;
//  - the **band** under it is the chain's lightness change per stop, over its
//    peak — the model's own toe and shoulder;
//  - the **dashed lines** are the ISO 6846 boundaries the Fit targets;
//  - beyond them the fill dims and its edge turns accent: those pixels print,
//    but flattened.
//
//  Every number is `spk_scene_latitude`'s (`Model/Latitude.swift`). Colour
//  latitude is narrower than tonal and is deliberately not drawn: the probe is
//  neutral, and a boundary it did not measure would mislead.

import SwiftUI

struct LatitudeSection: View {
    @Bindable var session: Session

    /// A fixed axis, so two frames or two papers compare at a glance.
    static let axis: ClosedRange<Double> = -8...8

    private var readout: LatitudeReadout? {
        guard let r = session.latitude.reply, session.latitude.frame == session.selection else { return nil }
        return LatitudeReadout(r)
    }

    /// What the measurement was taken on, as v4 writes it: "Portra 400 ·
    /// Supra Endura". The maker is dropped for the header only — there is one
    /// row to hold both names, and the lists above already carry them whole.
    private var pairNote: String {
        func short(_ id: String) -> String {
            var name = session.catalog.stock(id)?.name ?? id
            for maker in ["Kodak Professional ", "Kodak ", "Fujifilm ", "Fuji "] where name.hasPrefix(maker) {
                name = String(name.dropFirst(maker.count)); break
            }
            return name
        }
        let film = short(session.params.filmStock)
        guard !session.params.scanFilm, !session.filmIsPositive else { return film }
        return "\(film) · \(short(session.params.printStock))"
    }

    var body: some View {
        PanelSection(L(.sectionLatitude), key: "latitude", note: pairNote) {
            VStack(alignment: .leading, spacing: 0) {
                if let readout {
                    LatitudePlot(readout: readout)
                        .frame(height: Theme.Metric.latitudePlotHeight + Theme.Metric.latitudeBandGap
                               + Theme.Metric.latitudeBandHeight + Theme.Metric.latitudeAxisHeight)
                    readouts(readout).padding(.top, Theme.Metric.rowSpacing)
                } else {
                    Text(session.latitude.frame == session.selection
                         ? session.latitude.failure ?? L(.latitudeEmpty) : L(.latitudeEmpty))
                        .font(Theme.Font.caption).foregroundStyle(Theme.Ink.tertiary)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metric.latitudePlotHeight, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.Metric.rowInset)
        }
    }

    private func readouts(_ r: LatitudeReadout) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                share(L(.latitudeBelow), r.below, warn: true)
                Spacer(minLength: 4)
                share(L(.latitudeWithin), r.within, warn: false)
                Spacer(minLength: 4)
                share(L(.latitudeAbove), r.above, warn: true)
            }
            Text(summary(r))
                .font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private func share(_ label: String, _ v: Double, warn: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label).font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary)
            Text(String(format: "%.1f %%", v * 100))
                .font(Theme.Font.value)
                .foregroundStyle(warn && v >= 0.005 ? Theme.accent : Theme.text)
        }
        .lineLimit(1)
    }

    private func summary(_ r: LatitudeReadout) -> String {
        var s = String(format: "%.2f %@ · %@ – %@", r.highlightEV - r.shadowEV, L(.latitudeHeld),
                       Self.stops(r.shadowEV), Self.stops(r.highlightEV))
        if let c = r.core {
            s += " · \(L(.latitudeFullSeparation)) \(Self.stops(c.lowerBound)) – \(Self.stops(c.upperBound))"
        }
        return s
    }

    static func stops(_ v: Double) -> String {
        (v > 0 ? "+" : v < 0 ? "\u{2212}" : "") + String(format: "%.2f", abs(v))
    }
}

/// The plot, the band and the axis, drawn as one `Canvas` so the boundaries
/// can run through all three on the same x.
struct LatitudePlot: View {
    let readout: LatitudeReadout

    var body: some View {
        Canvas { ctx, size in
            let axis = LatitudeSection.axis
            let plotH = Theme.Metric.latitudePlotHeight
            let bandY = plotH + Theme.Metric.latitudeBandGap
            let bandH = Theme.Metric.latitudeBandHeight
            func x(_ ev: Double) -> CGFloat {
                CGFloat((ev - axis.lowerBound) / (axis.upperBound - axis.lowerBound)) * size.width
            }
            let plot = CGRect(x: 0, y: 0, width: size.width, height: plotH)
            ctx.fill(Path(roundedRect: plot, cornerRadius: 2), with: .color(Theme.plot))
            for e in stride(from: axis.lowerBound + 2, to: axis.upperBound, by: 2) {
                var p = Path(); p.move(to: CGPoint(x: x(e), y: 0)); p.addLine(to: CGPoint(x: x(e), y: plotH))
                ctx.stroke(p, with: .color(e == 0 ? Theme.plotMidGrey : Theme.plotGrid), lineWidth: 0.5)
            }

            // The histogram: step outline over the bins on the axis.
            let shown = zip(readout.centres, readout.fractions).filter { axis.contains($0.0) }
            let top = shown.map { $0.1.squareRoot() }.max() ?? 0
            let half = readout.binWidth / 2
            var fill = Path(), edge = Path()
            fill.move(to: CGPoint(x: x(axis.lowerBound), y: plotH))
            var open = false
            for (c, f) in shown {
                let h = top > 0 ? (plotH - 4) * CGFloat(f.squareRoot() / top) : 0
                fill.addLine(to: CGPoint(x: x(c - half), y: plotH - h))
                fill.addLine(to: CGPoint(x: x(c + half), y: plotH - h))
                // The edge only where there are pixels, so an empty floor
                // carries no line — and no accent.
                if f > 1e-5 {
                    if !open { edge.move(to: CGPoint(x: x(c - half), y: plotH)); open = true }
                    edge.addLine(to: CGPoint(x: x(c - half), y: plotH - h))
                    edge.addLine(to: CGPoint(x: x(c + half), y: plotH - h))
                } else if open {
                    edge.addLine(to: CGPoint(x: x(c - half), y: plotH)); open = false
                }
            }
            fill.addLine(to: CGPoint(x: x(axis.upperBound), y: plotH))
            fill.closeSubpath()
            let lo = x(readout.shadowEV), hi = x(readout.highlightEV)
            let regions: [(CGRect, Bool)] = [
                (CGRect(x: 0, y: 0, width: max(lo, 0), height: plotH), false),
                (CGRect(x: lo, y: 0, width: max(hi - lo, 0), height: plotH), true),
                (CGRect(x: hi, y: 0, width: max(size.width - hi, 0), height: plotH), false),
            ]
            for (rect, inside) in regions {
                ctx.drawLayer { l in
                    l.clip(to: Path(rect))
                    l.fill(fill, with: .color(inside ? Theme.latitudeInside.opacity(0.8) : Theme.latitudeBeyond))
                    l.stroke(edge, with: .color(inside ? Theme.latitudeInsideEdge : Theme.accent),
                             style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                }
            }
            // Pixels past the axis's ends: a small triangle at that end.
            let under = zip(readout.centres, readout.fractions).filter { $0.0 < axis.lowerBound }.map(\.1).reduce(0, +)
            let over = zip(readout.centres, readout.fractions).filter { $0.0 > axis.upperBound }.map(\.1).reduce(0, +)
            if under > 0.0005 {
                var t = Path(); t.move(to: CGPoint(x: 2, y: 3)); t.addLine(to: CGPoint(x: 7, y: 3)); t.addLine(to: CGPoint(x: 2, y: 8))
                ctx.fill(t, with: .color(Theme.accent))
            }
            if over > 0.0005 {
                var t = Path(); t.move(to: CGPoint(x: size.width - 2, y: 3)); t.addLine(to: CGPoint(x: size.width - 7, y: 3))
                t.addLine(to: CGPoint(x: size.width - 2, y: 8))
                ctx.fill(t, with: .color(Theme.accent))
            }

            // The separation band: its opacity at each stop is the measured
            // lightness change there, over its peak.
            let band = Path(roundedRect: CGRect(x: 0, y: bandY, width: size.width, height: bandH),
                            cornerRadius: bandH / 2)
            ctx.fill(band, with: .color(Theme.plot))
            let stops = stride(from: axis.lowerBound, through: axis.upperBound, by: 0.25).map { ev -> Gradient.Stop in
                let s = Self.strength(at: ev, readout.separation)
                return Gradient.Stop(color: Theme.text.opacity(0.9 * s),
                                     location: CGFloat((ev - axis.lowerBound) / (axis.upperBound - axis.lowerBound)))
            }
            ctx.fill(band, with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: 0, y: bandY),
                                                 endPoint: CGPoint(x: size.width, y: bandY)))

            // The ISO 6846 boundaries, through plot and band, labelled at the top.
            for (ev, leading) in [(readout.shadowEV, true), (readout.highlightEV, false)] {
                var p = Path(); p.move(to: CGPoint(x: x(ev), y: 1)); p.addLine(to: CGPoint(x: x(ev), y: bandY + bandH))
                ctx.stroke(p, with: .color(Theme.secondaryText.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 0.75, dash: [2, 1.5]))
                let label = ctx.resolve(Text(LatitudeSection.stops(ev)).font(Theme.Font.meta)
                    .foregroundStyle(Theme.secondaryText))
                ctx.draw(label, at: CGPoint(x: x(ev) + (leading ? -3 : 3), y: 2),
                         anchor: leading ? .topTrailing : .topLeading)
            }

            // The axis: stops from the metered mid-grey.
            for e in stride(from: axis.lowerBound, through: axis.upperBound, by: 2) {
                let t = e == 0 ? "0" : (e > 0 ? "+" : "\u{2212}") + String(Int(abs(e)))
                let label = ctx.resolve(Text(t).font(Theme.Font.meta).foregroundStyle(Theme.Ink.tertiary))
                let anchor: UnitPoint = e == axis.lowerBound ? .topLeading : e == axis.upperBound ? .topTrailing : .top
                ctx.draw(label, at: CGPoint(x: x(e), y: bandY + bandH + 3), anchor: anchor)
            }
        }
    }

    static func strength(at ev: Double, _ s: [(ev: Double, strength: Double)]) -> Double {
        guard let first = s.first, let last = s.last else { return 0 }
        if ev <= first.ev { return first.strength }
        if ev >= last.ev { return last.strength }
        for i in 0..<(s.count - 1) where s[i].ev <= ev && ev <= s[i + 1].ev {
            let t = (ev - s[i].ev) / max(s[i + 1].ev - s[i].ev, 1e-9)
            return s[i].strength + t * (s[i + 1].strength - s[i].strength)
        }
        return 0
    }
}
