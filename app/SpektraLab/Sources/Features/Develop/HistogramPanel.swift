//  HistogramPanel.swift — the picture's histogram at the top of a wide window's develop panel.
//
//  "a real histogram", in the
//  same place on Develop and on Edit — directly under the Develop | Edit row — folding on its head as
//  Capture One's does (a chevron and 直方图), with a ⋯ menu at its right that chooses how it is drawn:
//
//  - **Capture One style**: red, green and blue as lines over the luminance as a grey fill, on the
//    dark plot with faint quarter lines, and under it the frame's ISO · shutter · aperture, each only
//    where the file says it (`LibraryFrame.exposure`, read from its EXIF at import).
//  - **SpektraLab style**: the Latitude card's filled grey shape (`LatitudePlot`), of the picture's
//    luminance rather than the scene's stops.
//
//  The style and the fold are kept across launches (`DevelopPanelPrefs`). The numbers are the picture
//  as the canvas shows it, after Layer 2 (`Layer2Live.histogram`, 256 bins a channel from a 640 px
//  copy): asked for only while this panel is open on the page, and let go when it folds or the page
//  goes (`Layer2Live.holdHistogram`). Theme tokens only: the theme is the colour scheme's.

import SwiftUI

/// How the histogram is drawn: the ⋯ menu's two choices.
enum HistogramStyle: String, CaseIterable, Identifiable, Sendable {
    case captureOne = "captureOne", spektraLab = "spektraLab"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captureOne: L("Capture One Style")
        case .spektraLab: L("SpektraLab Style")
        }
    }
}

struct HistogramPanel: View {
    let session: OpenFrameSession
    /// "1/250 s · f/5.6 · ISO 100", as the import wrote it; nil where the file said nothing.
    let exposure: String?
    var prefs = DevelopPanelPrefs.shared

    /// The head (the chevron, the title, ⋯), the plot under it, and Capture One's line of the frame.
    static let head: CGFloat = 32
    static let plot: CGFloat = 84
    static let footer: CGFloat = 22
    /// The card's margin in the column, above and below.
    static let margin: CGFloat = 6

    /// The panel's height as the column lays it: what the panel under it does not have.
    @MainActor static func height(_ prefs: DevelopPanelPrefs = .shared) -> CGFloat {
        guard !prefs.histogramCollapsed else { return head + 2 * margin }
        return head + plot + (prefs.histogramStyle == .captureOne ? footer : 8) + 2 * margin
    }

    /// One holder per panel: the curve tool holds the same histogram for its own plot.
    @State private var holder = "histogram.\(UUID().uuidString)"

    private var collapsed: Bool { prefs.histogramCollapsed }

    var body: some View {
        VStack(spacing: 0) {
            head
            if !collapsed {
                plot.frame(height: Self.plot)
                if prefs.histogramStyle == .captureOne {
                    footer.frame(height: Self.footer)
                } else {
                    Spacer(minLength: 0).frame(height: 8)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.plot))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12).padding(.vertical, Self.margin)
        .onChange(of: collapsed, initial: true) { _, folded in
            if folded { session.layer2.releaseHistogram(holder) } else { session.layer2.holdHistogram(holder) }
        }
        .onDisappear { session.layer2.releaseHistogram(holder) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v5.histogram")
    }

    private var head: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { prefs.histogramCollapsed.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Icon(.chevronDown, size: 13, color: Theme.secondaryText)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(L("Histogram")).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: Self.head, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Histogram"))
            .accessibilityHint(collapsed ? L("Shows the plot") : L("Folds the plot away"))
            Menu {
                ForEach(HistogramStyle.allCases) { style in
                    Button { prefs.histogramStyle = style } label: {
                        if style == prefs.histogramStyle { Label(style.title, systemImage: "checkmark") } else { Text(style.title) }
                    }
                }
            } label: {
                Icon(.more, size: 18, color: Theme.secondaryText)
                    .frame(width: 32, height: Self.head).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Histogram style"))
            .accessibilityIdentifier("v5.histogram.style")
        }
        .frame(height: Self.head)
    }

    @ViewBuilder private var plot: some View {
        let h = session.layer2.histogram
        switch prefs.histogramStyle {
        case .captureOne: Self.lines(h)
        case .spektraLab: Self.filled(h)
        }
    }

    /// Capture One's: the luminance filled grey, the three channels as lines, quarter lines behind.
    private static func lines(_ h: Layer2Histogram?) -> some View {
        Canvas { ctx, size in
            var grid = Path()
            for k in 1..<4 {
                let x = size.width * CGFloat(k) / 4
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for k in 1..<3 {
                let y = size.height * CGFloat(k) / 3
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(Theme.rule), lineWidth: 0.5)
            guard let h else { return }
            let shown = HistogramDisplay(h)
            ctx.fill(shape(shown[.luma], size, closed: true), with: .color(Theme.dim.opacity(0.55)))
            let channels: [(Layer2Histogram.Channel, CurveChannel)] = [(.red, .red), (.green, .green), (.blue, .blue)]
            for (channel, swatch) in channels {
                ctx.stroke(shape(shown[channel], size, closed: false), with: .color(swatch.swatch.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 0.5) }
        .accessibilityLabel(L("Histogram"))
    }

    /// The Latitude card's: the luminance as one filled grey shape over its base line.
    private static func filled(_ h: Layer2Histogram?) -> some View {
        Canvas { ctx, size in
            guard let h else { return }
            ctx.fill(shape(HistogramDisplay(h)[.luma], size, closed: true), with: .color(Theme.latitudeInside))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
        .accessibilityLabel(L("Histogram"))
    }

    /// 256 bins, 0…1, across the plot: the shape closed onto the base, or the line alone. The plot's
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

    /// ISO · shutter · aperture, spread across the plot as Capture One sets them; what the file does
    /// not say is left out, and a file that says none of it leaves the line empty.
    private var footer: some View {
        let parts = Self.shootingParts(exposure)
        return HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Spacer(minLength: 8) }
                Text(part).font(Theme.Font.ui(11, .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: parts.count == 1 ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    /// "1/250 s · f/5.6 · ISO 100" → ["ISO 100", "1/250 s", "f/5.6"]: Capture One's order.
    static func shootingParts(_ exposure: String?) -> [String] {
        let parts = (exposure ?? "").components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        let iso = parts.first { $0.hasPrefix("ISO") }
        let shutter = parts.first { $0.hasSuffix(" s") }
        let aperture = parts.first { $0.lowercased().hasPrefix("f/") }
        return [iso, shutter, aperture].compactMap { $0 }
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

    init(_ h: Layer2Histogram) {
        let channels = Layer2Histogram.Channel.allCases
        let counts: [[Float]] = channels.map { c in
            var row = h.counts[(c.rawValue * 256)..<(c.rawValue * 256 + 256)].map { Float($0) }   // not `Float.init`: on a UInt32 that is `init(bitPattern:)`
            row[0] = 0; row[1] = 0; row[254] = 0; row[255] = 0
            return row
        }
        let lines = counts.map { Self.smoothed($0, sigma: 1.2) }
        let top = max(1, counts.map { Self.smoothed($0, sigma: 6).max() ?? 0 }.max() ?? 0) * 1.1
        rows = lines.map { row in row.map { min(1, ($0 / top).squareRoot()) } }
    }

    subscript(channel: Layer2Histogram.Channel) -> [Float] { rows[channel.rawValue] }

    /// A Gaussian of `sigma` bins across the row, the ends held at the row's own ends.
    private static func smoothed(_ row: [Float], sigma: Float) -> [Float] {
        let r = Int(3 * sigma) + 1
        let kernel = (-r...r).map { exp(-0.5 * pow(Float($0) / sigma, 2)) }
        let sum = kernel.reduce(0, +)
        return row.indices.map { i in
            var v: Float = 0
            for (j, k) in kernel.enumerated() { v += k * row[min(max(i + j - r, 0), row.count - 1)] }
            return v / sum
        }
    }
}
