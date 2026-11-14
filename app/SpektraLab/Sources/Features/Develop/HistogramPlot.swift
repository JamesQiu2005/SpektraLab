//  HistogramPlot.swift — the histogram as it is drawn, in either style, with or without the HDR span.
//
//  Kept apart from the panel (sessions, folding, menus) so a check can render it from synthetic counts
//  (tools/hdr_histogram_preview.sh). The counts of the HDR span are HDRHistogram.swift's.
//
//  HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D7: split out of HistogramPanel.swift, with one
//  plot past SDR white. `HistogramStyle` and
//  `HistogramDisplay` moved here from the panel with it, unchanged but for `init(counts:clipsWhite:)` and
//  `binCount`, which the HDR span needs. What differs on the Mac: the SDR and HDR words under the plot are in
//  the theme's type (`Theme.Font.ui`), as every other word in the column is, not a bare system size.

import Accelerate
import SwiftUI

/// How the histogram is drawn. RFC-051: the panel is Capture One style only and the ⋯ menu is gone; the other style
/// stays drawable (the HDR port's plot draws both), with no title to show.
enum HistogramStyle: String, CaseIterable, Identifiable, Sendable {
    case captureOne = "captureOne", spektraLab = "spektraLab"
    var id: String { rawValue }
}

/// The histogram plot, in either style. With `zone` (Enable HDR on, with a curve) it is Lightroom Classic's HDR
/// histogram: one plot, the same curves and fill going on across SDR white into the HDR range, a thin line at
/// white, the HDR side shaded darker with a faint line at each stop, and a bar under it, SDR then HDR. Without
/// one it is the SDR histogram alone, as before.
struct HistogramPlot: View {
    let h: Layer2Histogram?
    let zone: HDRZone?
    let style: HistogramStyle
    let labelSize: CGFloat

    /// The HDR span's room under the plot, where the bar and its words are.
    private var strip: CGFloat { labelSize * 1.3 + 4 }

    var body: some View {
        #if DEBUG && SPK_ENGINE
        let _ = TransitionMarks.mark(h == nil ? "histogram.empty" : "histogram")
        #endif
        let hdr = (zone?.stops ?? 0) > 0.05 ? zone : nil
        let shown: HistogramDisplay? = hdr.map { HistogramDisplay(counts: $0.combined(), clipsWhite: false) } ?? h.map { HistogramDisplay($0) }
        return Canvas { ctx, size in draw(ctx, size, shown: shown, stops: hdr?.stops) }
            .accessibilityLabel(L("Histogram"))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, shown: HistogramDisplay?, stops: Double?) {
        let plot = CGSize(width: size.width, height: size.height - (stops == nil ? 0 : strip))
        // Where SDR white falls: the end of the 256 SDR bins among all of them.
        let bins = shown?.binCount ?? 256
        let whiteX = stops == nil ? plot.width : plot.width * 255.5 / CGFloat(max(bins - 1, 1))
        let lines = style == .captureOne

        if let stops {
            ctx.fill(Path(CGRect(x: whiteX, y: 0, width: plot.width - whiteX, height: plot.height)), with: .color(.black.opacity(0.16)))
            // A faint line at each stop past white.
            var marks = Path()
            let perStop = (plot.width - whiteX) / CGFloat(stops)
            var stop = 1
            while Double(stop) < stops - 0.01 {
                let x = whiteX + perStop * CGFloat(stop)
                marks.move(to: CGPoint(x: x, y: 0)); marks.addLine(to: CGPoint(x: x, y: plot.height))
                stop += 1
            }
            ctx.stroke(marks, with: .color(Theme.rule.opacity(0.8)), lineWidth: 0.5)
        }
        if lines {
            var grid = Path()
            for k in 1..<4 {
                let x = whiteX * CGFloat(k) / 4
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: plot.height))
            }
            for k in 1..<3 {
                let y = plot.height * CGFloat(k) / 3
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: plot.width, y: y))
            }
            ctx.stroke(grid, with: .color(Theme.rule), lineWidth: 0.5)
        }
        if let shown {
            if lines {
                ctx.fill(Self.shape(shown[.luma], plot, closed: true), with: .color(Theme.dim.opacity(0.55)))
                let channels: [(Layer2Histogram.Channel, CurveChannel)] = [(.red, .red), (.green, .green), (.blue, .blue)]
                for (channel, swatch) in channels {
                    ctx.stroke(Self.shape(shown[channel], plot, closed: false), with: .color(swatch.swatch.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
                }
            } else {
                ctx.fill(Self.shape(shown[.luma], plot, closed: true), with: .color(Theme.latitudeInside))
            }
        }
        ctx.fill(Path(CGRect(x: 0, y: plot.height - (lines ? 0.5 : 1), width: plot.width, height: lines ? 0.5 : 1)), with: .color(Theme.rule))

        guard stops != nil else { return }
        // SDR white, and under the plot the bar: light under SDR, grey under HDR.
        var white = Path()
        white.move(to: CGPoint(x: whiteX, y: 0)); white.addLine(to: CGPoint(x: whiteX, y: plot.height))
        ctx.stroke(white, with: .color(Theme.text.opacity(0.55)), lineWidth: 0.75)
        let barY = plot.height + 2
        ctx.fill(Path(CGRect(x: 0, y: barY, width: max(0, whiteX - 0.5), height: 1.5)), with: .color(Theme.text.opacity(0.85)))
        ctx.fill(Path(CGRect(x: whiteX + 0.5, y: barY, width: max(0, plot.width - whiteX - 0.5), height: 1.5)), with: .color(Theme.dim))
        let labelY = barY + 1.5 + labelSize * 0.7
        ctx.draw(Text(L("SDR")).font(Theme.Font.ui(labelSize, .medium)).foregroundStyle(Theme.secondaryText),
                 at: CGPoint(x: whiteX / 2, y: labelY), anchor: .center)
        ctx.draw(Text(L("HDR")).font(Theme.Font.ui(labelSize, .medium)).foregroundStyle(Theme.dim),
                 at: CGPoint(x: (whiteX + plot.width) / 2, y: labelY), anchor: .center)
    }

    /// The bins, 0…1, across the plot: the shape closed onto the base, or the line alone. The plot's
    /// top 2 pt are left clear, as the Latitude card leaves them.
    static func shape(_ bins: [Float], _ size: CGSize, closed: Bool) -> Path {
        var p = Path()
        guard bins.count > 1 else { return p }
        let top: CGFloat = 2, base = size.height
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: size.width * CGFloat(i) / CGFloat(bins.count - 1), y: base - CGFloat(bins[i]) * (base - top))
        }
        if closed { p.move(to: CGPoint(x: 0, y: base)); p.addLine(to: point(0)) } else { p.move(to: point(0)) }
        for i in 1..<bins.count { p.addLine(to: point(i)) }
        if closed { p.addLine(to: CGPoint(x: size.width, y: base)); p.closeSubpath() }
        return p
    }
}

/// The histogram as it is drawn: Capture One's way of showing it, not the counts over the tallest bin.
///
/// The owner, 2026-10-24, holding the same frame (`_DSC4680.NEF`) in both: the bins sat where Capture
/// One's do, peak for peak, and were flat. Two things flattened them, both in the drawing and neither
/// in the counts (`Layer2Histogram`, which the curve's own readings keep as they are):
///
/// - **One spike set the scale.** The counts were over the tallest bin of all four channels, and on
///   that frame the tallest was a narrow red spike near black, three times the luminance's body: every
///   other line lay in the plot's lowest third. The scale is now the tallest of each channel smoothed
///   wide (σ 6 bins), which a spike a few bins wide is diluted by and a body is not, with a tenth of
///   headroom; a spike runs off the top, as Capture One lets it.
/// - **Linear heights hide the tones that matter.** Capture One's secondary humps stand about a
///   quarter as tall as its peak where the counts are 1/25 of it: its heights are compressed. A square
///   root gives the same reading (measured on a capture of the develop page, 2026-10-24: the peak at the
///   top with two to seven bins clipped, the mid-tones at 0.15–0.35 of the plot where they were 0.02).
///
/// The lines are smoothed a little (σ 1.2 bins), as Capture One's are; the two bins at each end, the
/// clipped black and white, are left out as they were.
struct HistogramDisplay {
    private let rows: [[Float]]
    /// The count a full-height line stands for (squared).
    let top: Float

    init(_ h: Layer2Histogram) {
        let channels = Layer2Histogram.Channel.allCases
        self.init(counts: channels.map { c in
            Array(h.counts[(c.rawValue * 256)..<(c.rawValue * 256 + 256)]).map { Float($0) }   // not `Float.init`: on a UInt32 that is `init(bitPattern:)`
        }, clipsWhite: true)
    }

    /// Counts a channel, in `Layer2Histogram.Channel` order. The clipped black is left out; so is the clipped
    /// white, unless the plot goes on past it (the HDR histogram, where white is no end and no clip).
    init(counts: [[Float]], clipsWhite: Bool) {
        let counts: [[Float]] = counts.map { row in
            var row = row
            row[0] = 0; row[1] = 0
            if clipsWhite { row[254] = 0; row[255] = 0 }
            return row
        }
        let lines = counts.map { Self.smoothed($0, sigma: 1.2) }
        let top = max(1, counts.map { Self.smoothed($0, sigma: 6).max() ?? 0 }.max() ?? 0) * 1.1
        self.top = top
        // min(1, √(line / top)), a row at a time (the lines and the top are never negative).
        rows = lines.map { row in vDSP.clip(vForce.sqrt(vDSP.divide(row, top)), to: 0...1) }
    }

    /// Bins across the plot.
    var binCount: Int { rows.first?.count ?? 0 }

    subscript(channel: Layer2Histogram.Channel) -> [Float] { rows[channel.rawValue] }

    /// A Gaussian of `sigma` bins across the row, the ends held at the row's own ends.
    ///
    /// The row held at its ends `r` bins either side, then Accelerate's correlation with the kernel (made once for
    /// each of the two sigmas): the same weights as the loop it replaces, summed in another order (a few parts in 10⁷).
    /// As `map`s over arrays the plot cost ~6 ms of the main thread at every histogram in a Debug build — each develop,
    /// and each change of picture (2.4.0 A2b, by `sample`).
    private static func smoothed(_ row: [Float], sigma: Float) -> [Float] {
        let (kernel, sum) = sigma == 1.2 ? fine : sigma == 6 ? broad : Self.kernel(sigma)
        let r = kernel.count / 2, n = row.count
        guard let first = row.first, let last = row.last else { return [] }
        let held = [Float](repeating: first, count: r) + row + [Float](repeating: last, count: r)
        var out = [Float](repeating: 0, count: n)
        vDSP_conv(held, 1, kernel, 1, &out, 1, vDSP_Length(n), vDSP_Length(kernel.count))
        return vDSP.divide(out, sum)
    }

    private static let fine = kernel(1.2), broad = kernel(6)

    private static func kernel(_ sigma: Float) -> ([Float], Float) {
        let r = Int(3 * sigma) + 1
        let kernel = (-r...r).map { exp(-0.5 * pow(Float($0) / sigma, 2)) }
        return (kernel, kernel.reduce(0, +))
    }
}
