//  HistogramPanel.swift — the picture's histogram at the top of a wide window's develop panel.
//
//  "a real histogram", in the
//  same place on Develop and on Edit — directly under the Develop | Edit row — folding on its head as
//  Capture One's does (a chevron and 直方图), drawn as Capture One draws it: red, green and blue as
//  lines over the luminance as a grey fill, on the dark plot with faint quarter lines, and under it the
//  frame's ISO · shutter · aperture, each only where the file says it (`LibraryFrame.exposure`, read
//  from its EXIF at import).
//
//  One style only (the owner, 2026-11-09: "the capture one style / SpektraLab style histogram difference
//  can be dropped completely … no need to have the ... menu"). Until then a ⋯ menu offered a second,
//  the Latitude card's filled grey shape; its defaults key, `develop.wide.histogram.style`, is retired
//  and no longer read. The fold is kept across launches (`DevelopPanelPrefs`). The numbers are the picture
//  as the canvas shows it, after Layer 2 (`Layer2Live.histogram`, 256 bins a channel from a 640 px
//  copy): asked for only while this panel is open on the page, and let go when it folds or the page
//  goes (`Layer2Live.holdHistogram`). Theme tokens only: the theme is the colour scheme's.
//
//  **Enable HDR** (HDR port, 2026-11-06, D7): where the frame's HDR is on and
//  the canvas draws it (`HDRLook.of`), the plot is Lightroom Classic's HDR histogram — one plot that goes on past
//  SDR white, from the page's own HDR picture (`HDRZoneView.swift`, `HistogramPlot`); otherwise it is the SDR
//  histogram, as it was. The plot is drawn by `HistogramPlot.swift`, where `HistogramStyle` and
//  `HistogramDisplay` now live; the panel's heights are the same either way (the HDR bar takes its room inside
//  the plot), so the column does not move when the switch is turned.

import SwiftUI

struct HistogramPanel: View {
    let session: OpenFrameSession
    /// "1/250 s · f/5.6 · ISO 100", as the import wrote it; nil where the file said nothing.
    let exposure: String?
    var prefs = DevelopPanelPrefs.shared

    /// The head (the chevron and the title), the plot under it, and Capture One's line of the frame.
    static let head: CGFloat = 32
    static let plot: CGFloat = 84
    static let footer: CGFloat = 22
    /// The card's margin in the column, above and below.
    static let margin: CGFloat = 6

    /// The panel's height as the column lays it: what the panel under it does not have.
    @MainActor static func height(_ prefs: DevelopPanelPrefs = .shared) -> CGFloat {
        guard !prefs.histogramCollapsed else { return head + 2 * margin }
        return head + plot + footer + 2 * margin
    }

    /// One holder per panel: the curve tool holds the same histogram for its own plot.
    @State private var holder = "histogram.\(UUID().uuidString)"
    /// Whether the panel is still on the page when its first hold comes due (`onAppear`).
    private final class Shown { var on = true }
    @State private var shown = Shown()

    private var collapsed: Bool { prefs.histogramCollapsed }

    var body: some View {
        VStack(spacing: 0) {
            head
            if !collapsed {
                plot.frame(height: Self.plot)
                footer.frame(height: Self.footer)
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.plot))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12).padding(.vertical, Self.margin)
        .onChange(of: collapsed) { _, folded in
            if folded { session.layer2.releaseHistogram(holder) } else { session.layer2.holdHistogram(holder) }
        }
        // Asked once the page's first frame is on the screen (made for each frame, 2.4.0 A2b): its pass and its plot
        // landing in the turn after a change of photograph held that frame back ~30–50 ms in a Debug build.
        .onAppear {
            let session = session, holder = holder, shown = shown
            shown.on = true
            AfterFrame.run(after: 2) {
                if shown.on, !DevelopPanelPrefs.shared.histogramCollapsed, session.isHeld { session.layer2.holdHistogram(holder) }
            }
        }
        .onDisappear { shown.on = false; session.layer2.releaseHistogram(holder) }
        .modifier(HDRZoneFeed(session: session))
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
        }
        .frame(height: Self.head)
    }

    /// The plot, Capture One style only (RFC-051); with the page's HDR counts it goes on past SDR white (`HistogramPlot`).
    private var plot: some View {
        HistogramPlot(h: session.layer2.histogram, zone: session.hdrZone.zone, style: .captureOne, labelSize: Self.hdrLabel)
    }

    /// The SDR and HDR words under an HDR plot: the size of the curve's HDR words (`CurveTool`), a step under the
    /// footer's 11. 9 would be about 7 Mac points at the Mac's 0.77 drawing scale.
    static let hdrLabel: CGFloat = 10

    /// The bins, 0…1, across the plot: the shape closed onto the base, or the line alone (`HistogramPlot.shape`;
    /// Edit's curve draws its ground with it).
    static func shape(_ bins: [Float], _ size: CGSize, closed: Bool) -> Path {
        HistogramPlot.shape(bins, size, closed: closed)
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
