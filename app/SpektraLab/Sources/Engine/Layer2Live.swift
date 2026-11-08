//  Layer2Live.swift — the develop page's Layer 2: its picture with the edit, as a finger moves.
//
//  design/v5 §3.1: Light, Curve and Colour move live on the last render, at the
//  display's rate, with no job. One of these per page (`OpenFrameSession.layer2`):
//  the session hands it the page's picture and the edit as each lands, the
//  canvas says how large it draws (`display(maxPixel:)`) and draws `shown`.
//
//  - **One pass at a time, the latest wins.** A change while a pass is out
//    marks it again; when the pass lands the newest edit is run. Nothing
//    queues behind a finger, and nothing is asked of the scheduler: this is
//    not the engine.
//  - **The pass runs at the size the canvas draws**, the size `FramePicture`
//    decodes for the same place (the screen's pixels, in steps of 64, never
//    past the picture's own): about 1.1 MP at fit on a 6.1" host, and the
//    preview's own pixels zoomed in. The picture is drawn into the pass's
//    buffer once per picture and size (`Layer2Renderer.source`).
//  - **The histogram is of the picture as shown**, after the pass, taken from
//    a small copy of the picture (640 px) whenever the Curve tool asks
//    (`wantsHistogram`): about 0.3 MP, a few hundred samples a bin.
//  - **A neutral layer runs nothing**: the canvas shows the develop as before,
//    and `shown` is let go.
//
//  The snapshot harness draws a page still: `renderedNow` makes the picture on
//  the spot, on the calling thread, for a page that must be complete when it
//  is captured.

import CoreGraphics
import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class Layer2Live {
    /// The page's picture with the edit, at the size the canvas asked for. Nil
    /// until the first pass lands, and while the layer is neutral.
    private(set) var shown: CGImage?
    /// The histogram of the picture as shown (`wantsHistogram`).
    private(set) var histogram: Layer2Histogram?
    /// The last pass, measured (the GPU's time, and from the ask to the picture).
    private(set) var lastPass: Layer2Timing?
    /// The last histogram's GPU time, in milliseconds.
    private(set) var lastHistogramMilliseconds: Double?
    /// Set by the Curve tool while it is shown: the histogram is kept up with the edit.
    var wantsHistogram = false {
        didSet { if wantsHistogram != oldValue { if wantsHistogram { schedule() } else { histogram = nil } } }
    }
    /// Who asks for the histogram : the Curve tool,
    /// and a wide window's histogram panel (`HistogramPanel`), which can both be on the page at once —
    /// a tool closing must not take the histogram from the panel. `wantsHistogram` is their union.
    @ObservationIgnored private var histogramHolders: Set<String> = []
    func holdHistogram(_ holder: String) {
        histogramHolders.insert(holder)
        wantsHistogram = true
    }
    func releaseHistogram(_ holder: String) {
        histogramHolders.remove(holder)
        wantsHistogram = !histogramHolders.isEmpty
    }

    /// The picture the pass reads: the page's develop. Nil where there is none
    /// it can adjust as the page shows it (`picture(for:)`).
    private(set) var picture: PictureRef?
    @ObservationIgnored private(set) var adjustments = Adjustments()
    @ObservationIgnored private var displayPixel: Int?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private let work = Layer2Work()
    @ObservationIgnored private var still: (key: String, image: CGImage)?
    @ObservationIgnored nonisolated(unsafe) private var warning: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var reclaiming: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "layer2")

    init() {
        // A memory warning: the pass's copies of the picture go, and are drawn again at the next pass.
        warning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                         object: nil, queue: .main) { [weak work] _ in work?.drop() }
        // And when a job someone waits on cannot fit (`RenderQueue.reclaim`).
        reclaiming = NotificationCenter.default.addObserver(forName: .spkReclaim, object: nil, queue: .main) { [weak work] _ in work?.drop() }
    }

    deinit {
        if let warning { NotificationCenter.default.removeObserver(warning) }
        if let reclaiming { NotificationCenter.default.removeObserver(reclaiming) }
    }

    /// The picture Layer 2 adjusts on the page: the page's own develop, or the
    /// frame's kept one; a frame with none — its camera's preview, a drawing —
    /// only where the page shows that picture as it is (no crop, no film, no
    /// date drawn over it). Nil where the page draws something else.
    static func picture(for frame: LibraryFrame?, developed: DevelopedPicture?, edit: FrameEdit) -> PictureRef? {
        guard let frame else { return nil }
        if let made = developed ?? frame.shownDevelop { return made.picture }   // never a develop whose file is gone
        guard !frame.isPair, edit.geometry.isIdentity, !edit.filmEdge.effective, !edit.dateBack.active else { return nil }
        return frame.picture
    }

    // MARK: what the page tells it

    func show(picture next: PictureRef?) {
        guard next != picture else { return }
        picture = next
        schedule()
    }

    func show(adjustments next: Adjustments) {
        guard next != adjustments else { return }
        let was = adjustments.isActive
        adjustments = next
        if !next.isActive {
            // Nothing to draw: the picture and the pass's copy of the page's picture go.
            shown = nil
            if was { work.dropDisplay() }
        }
        schedule()
    }

    /// The canvas draws at this long edge (nil: it does not draw the live picture).
    func display(maxPixel: Int?) {
        guard maxPixel != displayPixel else { return }
        displayPixel = maxPixel
        schedule()
    }

    /// The page has closed: everything the pass held goes.
    func close() {
        shown = nil
        histogram = nil
        picture = nil
        displayPixel = nil
        histogramHolders = []
        wantsHistogram = false
        still = nil
        work.drop()
    }

    // MARK: the pass

    private func schedule() {
        guard picture != nil else { return }
        let wantsImage = adjustments.isActive && displayPixel != nil
        guard wantsImage || wantsHistogram else { return }
        if inFlight { again = true; return }
        inFlight = true
        let ask = Layer2Work.Ask(picture: picture!, displayPixel: displayPixel, adjustments: adjustments,
                                 wantsImage: wantsImage, wantsHistogram: wantsHistogram)
        work.run(ask) { [weak self] answer in
            Task { @MainActor in self?.landed(ask, answer) }
        }
    }

    private func landed(_ ask: Layer2Work.Ask, _ answer: Layer2Work.Answer) {
        inFlight = false
        // Only what is still of the page's picture and its layer: a pass for an
        // edit since put back to zero is not drawn.
        if ask.picture == picture {
            if let image = answer.image, adjustments.isActive { shown = image }
            if let h = answer.histogram, wantsHistogram { histogram = h }
        }
        if let t = answer.timing {
            lastPass = t
            log.debug("layer 2: a pass at \(t.width) x \(t.height), \(t.gpuMilliseconds, format: .fixed(precision: 2)) ms on the GPU, \(t.wallMilliseconds, format: .fixed(precision: 2)) ms in all")
        }
        if let ms = answer.histogramMilliseconds { lastHistogramMilliseconds = ms }
        if let failure = answer.failure { log.error("layer 2: \(failure, privacy: .public)") }
        if again { again = false; schedule() }
    }

    /// The picture as the canvas would show it, made now on this thread: for a
    /// page drawn still (the snapshot harness). Kept for the same picture, size
    /// and layer, so a page drawn twice is not made twice.
    func renderedNow(maxPixel: Int) -> CGImage? {
        guard let picture, adjustments.isActive, let renderer = Layer2Renderer.shared else { return nil }
        let key = "\(picture)|\(maxPixel)|\(adjustments.key)"
        if let still, still.key == key { return still.image }
        guard let image = Layer2Work.image(of: picture, maxPixel: maxPixel),
              let source = try? renderer.source(image, maxPixel: maxPixel),
              let (made, _) = try? renderer.image(source, adjustments) else { return nil }
        still = (key, made)
        return made
    }
}

/// The pass's side: its copies of the picture, on a queue of its own. Only
/// ever touched there.
final class Layer2Work: @unchecked Sendable {
    struct Ask: Sendable {
        var picture: PictureRef
        var displayPixel: Int?
        var adjustments: Adjustments
        var wantsImage: Bool
        var wantsHistogram: Bool
    }
    struct Answer: @unchecked Sendable {
        var image: CGImage?
        var timing: Layer2Timing?
        var histogram: Layer2Histogram?
        var histogramMilliseconds: Double?
        var failure: String?
    }

    /// The histogram's copy of the picture: small, so a histogram costs nothing.
    static let histogramPixel = 640

    private let queue = DispatchQueue(label: "com.spektralab.layer2", qos: .userInteractive)
    private let pool = Layer2Pool()
    private var display: (key: String, source: Layer2Source)?
    private var small: (key: String, source: Layer2Source)?

    func run(_ ask: Ask, done: @escaping @Sendable (Answer) -> Void) {
        queue.async { [self] in
            var answer = Answer()
            autoreleasepool {
                guard let renderer = Layer2Renderer.shared else { answer.failure = "no Metal device"; return }
                do {
                    if ask.wantsImage, let px = ask.displayPixel {
                        let source = try self.source(ask.picture, px, &display, renderer)
                        let (image, timing) = try renderer.image(source, ask.adjustments, pool: pool)
                        answer.image = image
                        answer.timing = timing
                    }
                    if ask.wantsHistogram {
                        let source = try self.source(ask.picture, Self.histogramPixel, &small, renderer)
                        let (h, ms) = try renderer.histogram(source, ask.adjustments)
                        answer.histogram = h
                        answer.histogramMilliseconds = ms
                    }
                } catch {
                    answer.failure = "\(error)"
                }
            }
            done(answer)
        }
    }

    /// The display's copy of the picture and its buffers go; the histogram's small copy stays.
    func dropDisplay() {
        queue.async { [self] in
            display = nil
            pool.drain()
        }
    }

    /// Everything held goes (on the pass's queue, after any pass under way).
    func drop() {
        queue.async { [self] in
            display = nil
            small = nil
            pool.drain()
        }
    }

    private func source(_ picture: PictureRef, _ maxPixel: Int, _ slot: inout (key: String, source: Layer2Source)?,
                        _ renderer: Layer2Renderer) throws -> Layer2Source {
        let key = "\(picture)@\(maxPixel)"
        if let slot, slot.key == key { return slot.source }
        slot = nil
        guard let image = Self.image(of: picture, maxPixel: maxPixel) else {
            throw Layer2Renderer.Failure.picture("the page's picture could not be read for Layer 2")
        }
        let made = try renderer.source(image, maxPixel: maxPixel)
        slot = (key, made)
        return made
    }

    /// A picture as an upright `CGImage`: a develop held in memory as it is,
    /// a file decoded at the size asked (`ThumbnailStore`, whose decode the
    /// page's own picture shares). Any thread.
    static func image(of picture: PictureRef, maxPixel: Int) -> CGImage? {
        switch picture {
        case .rendered(let id): RenderedPictures.shared.image(id)?.cgImage
        case .file, .sample: ThumbnailStore.shared.load(picture, maxPixel: maxPixel)?.cgImage
        }
    }
}
