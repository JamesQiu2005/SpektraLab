//  HDRZoneView.swift — the histogram of the HDR rendition on screen (the arithmetic is HDRHistogram.swift).
//
//  The counts are made off the main thread from the histogram's own picture, and kept up with the edit, the
//  frame's Enable HDR and the screen's headroom. With no look they are nil and the plot is exactly as before.
//  `HistogramPlot` draws either: the SDR histogram alone, or Lightroom's one plot that goes on past SDR white.
//
//  HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D7. On the Mac:
//  - **The look is the page's** (`HDRLook.of(edit, session.hdr)`): the curve the engine gave this frame's session
//    with its develop, never a file's; nil wherever the canvas draws SDR (the switch off, the film off, no curve,
//    no screen of this Mac that shows HDR) — then the panel is the SDR histogram, as before.
//  - **One set of counts a page** (`OpenFrameSession.hdrZone`), which the histogram panel and Edit's curve both
//    read: on the Mac they are on screen together, and the same ask from both is made once (`Ask`).
//  - **The picture is always the 640 px copy.** Taking the develop as it is held whenever Layer 2 is
//    neutral would put the whole 1,920 px preview (2.5 MP) through the kernels, where the SDR histogram beside
//    it counts the 640 px copy; here a neutral layer's copy is drawn at 640 px as the adjusted one is.

import CoreGraphics
import SwiftUI

/// The counts as the last pass made them. One a page (`OpenFrameSession.hdrZone`).
@MainActor @Observable
final class HDRZoneModel {
    private(set) var zone: HDRZone?
    @ObservationIgnored private var generation = 0
    /// The ask the shown counts answer, and the look now asked for: an answer is shown when it is newer than
    /// the shown one and of the look still asked for — never dropped only because a newer ask is under way
    /// (2026-11-03: two asks a toggle, the first's answer dropped, the second's slow: the histogram stood still).
    @ObservationIgnored private var shownGeneration = 0
    @ObservationIgnored private var askedLook: HDRLook?

    /// What a pass is of: the same ask twice (the panel's feed and the curve's, on one change) is made once.
    private struct Ask: Equatable {
        var look: HDRLook?
        var weight: Double
        var picture: PictureRef?
        var adjustments: Adjustments
        var histogram: Layer2Histogram?
    }
    @ObservationIgnored private var lastAsk: Ask?
    /// One pass at a time; while one is out, only the newest ask waits (2026-11-10: a peak drag or a curve drag
    /// started a detached pass a step, ~20 at once, each waiting on `HDRRendition.gate` — 233 ms became 1,000 ms,
    /// and the canvas's own rendition queued behind them for 1.4 s: the "unresponsive" canvas and Decode curve).
    @ObservationIgnored private var running = false
    @ObservationIgnored private var waiting: (look: HDRLook, weight: Double, picture: PictureRef, adjustments: Adjustments, mine: Int)?

    /// Makes the counts of the picture the histogram reads, off the main thread; the latest ask wins. No `look`,
    /// or no histogram (not asked for, or folded), takes them away at once.
    func refresh(layer2: Layer2Live, look: HDRLook?, weight: Double) {
        let ask = Ask(look: look, weight: weight, picture: layer2.picture, adjustments: layer2.adjustments, histogram: layer2.histogram)
        guard ask != lastAsk else { return }
        lastAsk = ask
        generation += 1
        askedLook = look
        guard let look, layer2.histogram != nil, let picture = layer2.picture else {
            shownGeneration = generation
            waiting = nil
            #if DEBUG
            Log.note(.develop, "hdr histogram cleared", ["look": look != nil, "histogram": layer2.histogram != nil, "picture": layer2.picture != nil])
            #endif
            if zone != nil { zone = nil }
            return
        }
        let mine = generation, adjustments = layer2.adjustments
        waiting = (look, weight, picture, adjustments, mine)
        startNext()
    }

    /// The newest waiting ask, when no pass is out.
    private func startNext() {
        guard !running, let next = waiting else { return }
        waiting = nil
        running = true
        let (look, weight, picture, adjustments, mine) = next
        Task.detached(priority: .userInitiated) { [weak self] in
            var made: HDRZone?
            let started = Date()
            autoreleasepool {
                // The histogram's copy (`Layer2Work.histogramPixel`), with the edit when there is one: what the SDR
                // histogram beside it counts.
                guard let renderer = Layer2Renderer.shared,
                      let full = Layer2Work.image(of: picture, maxPixel: Layer2Work.histogramPixel),
                      let source = try? renderer.source(full, maxPixel: Layer2Work.histogramPixel) else { return }
                let image: CGImage?
                if adjustments.isActive { image = (try? renderer.image(source, adjustments))?.0 }
                else { image = try? Layer2Renderer.image(over: source.buffer, width: source.width, height: source.height, pool: nil) }
                // The page's own HDR picture of it (the canvas's kernels, on the GPU), binned as it is.
                if let image, let edr = try? HDRRendition.make(image, look: look, weight: weight) {
                    made = HDRHistogram.zone(edr: edr, headroom: look.curve.headroom, weight: weight)
                }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await MainActor.run {
                guard let self else { return }
                self.running = false
                defer { self.startNext() }
                #if DEBUG
                Log.note(.develop, "hdr histogram", ["latest": self.generation == mine, "shown": mine > self.shownGeneration && self.askedLook == look && made != nil,
                                                     "in_zone": made?.inZone ?? -1, "samples": made?.samples ?? 0,
                                                     "weight": (weight * 1000).rounded() / 1000, "ms": ms])
                #endif
                guard mine > self.shownGeneration, self.askedLook == look, let made else { return }
                self.shownGeneration = mine
                self.zone = made
            }
        }
    }
}

/// Keeps a page's counts up with the edit (a new SDR histogram landing), Enable HDR and the headroom.
struct HDRZoneFeed: ViewModifier {
    let session: OpenFrameSession

    private var look: HDRLook? { HDRLook.of(session.edit, session.hdr) }
    private var weight: Double { look.map(Self.weight) ?? 0 }

    /// The canvas's weight; on an SDR screen, which shows none, the file's full one. The curve's HDR line
    /// takes the same, so its line and its share agree with the histogram's. (On the Mac an SDR screen here is
    /// the window's own: another of the Mac's shows HDR, or there would be no look.)
    static func weight(_ look: HDRLook) -> Double {
        let headroom = HDRScreen.shared.headroom
        return headroom > 1.01 ? look.weight(headroom: headroom) : 1
    }

    private struct Key: Hashable { var look: HDRLook?; var weight: Double }

    func body(content: Content) -> some View {
        let key = Key(look: look, weight: (weight * 100).rounded() / 100)
        let present = session.layer2.histogram != nil
        return content
            .onChange(of: key, initial: true) { _, _ in refresh() }
            .onChange(of: session.layer2.histogram) { _, _ in refresh() }
            .onChange(of: present) { _, _ in refresh() }
    }

    private func refresh() { session.hdrZone.refresh(layer2: session.layer2, look: look, weight: weight) }
}
