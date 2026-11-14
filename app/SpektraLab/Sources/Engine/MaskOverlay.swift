//  MaskOverlay.swift — the mask on the picture: the red overlay and the mask alone (design/masks/MASKS-SPEC.md §6.1;
//  RFC-052 §3, §4.4; trap 27).
//
//  **Made from the plane every surface samples.** The picked layer's canonical plane (`MaskBaker.bake`, the same key
//  and the same buffer the engine's node and Edit's pass are handed) is laid on the view through the view's one
//  matrix (`MaskFrame.view`, inverted): its four corners in S go where the view shows them, and Core Image's
//  perspective transform — a homography, exact for the affine maps of a crop, a turn, a flip, a straighten and a film
//  edge's gate, and for Develop's perspective too — lays every texel between them. Only the part of the picture in
//  view is made, at the screen's pixels. Nothing is rasterised from the parts again for the view, so the overlay's
//  edge is the developed picture's edge.
//
//  **The red is converted, not written** (trap 27): sRGB (255, 59, 48) is handed to Core Image as an sRGB colour and
//  the picture is made in Display P3, the space the page's picture is made in (`CanvasGamut`, `EngineHost`'s canvas),
//  so the same red lands on the drawable whichever space the canvas holds. Alpha is 0.5 · m: 50 % where the mask is 1
//  and in proportion below. The mask alone is the plane white on black, opaque, outside S black.
//
//  **Off the main actor, and never queued behind itself.** A bake and a render run in a task of their own; while one
//  runs, a newer ask waits as the one pending (the latest wins), so a stroke's overlay follows the pointer at the rate
//  the GPU makes it and the main actor never waits on a bake (M0: 7 ms a stroke at 4096).
//
//  **Never stored.** It is a picture of the page's alone, drawn over the canvas (`MaskStage`): the kept develop, a
//  tile, the Light Table, the histogram and an export are made from the edit and never see it.

import CoreGraphics
import CoreImage
import Foundation
import Metal
import UIKit

@MainActor @Observable
final class MaskOverlay {
    static let shared = MaskOverlay()

    /// sRGB (255, 59, 48) at 50 % (MASKS-SPEC §6.1).
    nonisolated static let red = (r: 255.0 / 255, g: 59.0 / 255, b: 48.0 / 255)
    nonisolated static let alpha = 0.5

    enum Mode: String, Sendable { case overlay, alone }

    /// What is asked: the layer's mask, the view's matrix and the part of it in view.
    struct Ask: Equatable, Sendable {
        var layer: LocalLayer
        var source: PixelSize
        /// The picture's rect in view points (`shown`): its normalised coordinates are what `toS` reads.
        var shown: CGRect
        /// The view's normalised coordinates → S (`MaskFrame.view`).
        var toS: MaskMatrix
        /// The part of the view to make, in view points (the picture's rect within the area).
        var visible: CGRect
        /// Pixels a point.
        var scale: CGFloat
        var mode: Mode
        /// Output pixels the overlay is moved down by: 0, but for `--masks-check-break geometry-halftexel` (½).
        var nudge: CGFloat = 0

        var planeKey: String { MaskBaker.planeKey(layer, source: source) }
        /// The picture's own key: what it is of, and where.
        var key: String {
            "\(planeKey)|\(toS.key)|\(shown.debugDescription)|\(visible.debugDescription)|\(scale)|\(mode.rawValue)|\(nudge)"
        }
        static func == (a: Ask, b: Ask) -> Bool { a.key == b.key }
    }

    /// The picture made last, and where it is drawn (view points).
    struct Made { var image: UIImage; var rect: CGRect; var key: String; var mode: Mode; var planeKey: String; var layer: UUID }
    private(set) var made: Made?
    /// The plane `made` was made from: what a live stroke folds onto (`MaskLive`), so it needs no bake at the press.
    @ObservationIgnored private(set) var plane: MaskPlane?
    /// The time the last one took, from the ask to the picture (a stroke's turnaround, `--masks-check`'s cost).
    private(set) var lastMilliseconds: Double?
    /// Where the last picture's time went (`--masks-check`'s cost, M1c step 0c), in ms from the ask: the hop to the
    /// task, the bake, the picture's render, the hop back and the picture handed to the view.
    struct Timing: Sendable { var start = 0.0, baked = 0.0, rendered = 0.0, landed = 0.0 }
    private(set) var lastTiming: Timing?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending: Ask?
    @ObservationIgnored private var wanted: String?

    /// The last ask the view made: where a drag's next picture is laid (`follow`).
    @ObservationIgnored private var lastAsk: Ask?

    /// The picture for `ask`, made off the main actor; nil puts it away.
    func want(_ ask: Ask?) {
        guard let ask else { wanted = nil; pending = nil; made = nil; plane = nil; lastAsk = nil; MaskLive.shared.uncover(); return }
        lastAsk = ask
        MaskLive.shared.asked(ask.planeKey)
        wanted = ask.key
        if made?.key == ask.key { return }
        pending = ask
        guard !running else { return }
        runNext()
    }

    /// **A tool's move, asked at once** (M1c step 0c): the layer as the drag left it, laid where the view's last ask
    /// was, without waiting for the view to be drawn again and its `.task` to ask (measured: that wait was most of a
    /// stroke's turnaround, see `--masks-check`'s cost). The view's own ask follows with the same key and finds it made
    /// or under way. Nothing where the view asked for nothing, or for another layer.
    func follow(_ layer: LocalLayer) {
        guard var ask = lastAsk, wanted != nil, ask.layer.id == layer.id, ask.layer != layer else { return }
        ask.layer = layer
        want(ask)
    }

    /// A bake and a render under way: a stroke's next move waits for it (`MaskTools`' owed move).
    var busy: Bool { running }

    private func runNext() {
        guard let ask = pending else { running = false; return }
        pending = nil
        running = true
        let start = Date()
        Task.detached(priority: .userInitiated) {
            var timing = Timing()
            timing.start = Date().timeIntervalSince(start) * 1000
            let made = await Self.made(ask, timing: &timing, from: start)
            await MainActor.run {
                if let (image, plane) = made, self.wanted != nil {
                    self.made = Made(image: UIImage(cgImage: image), rect: Self.drawnRect(ask, image), key: ask.key, mode: ask.mode,
                                     planeKey: ask.planeKey, layer: ask.layer.id)
                    self.plane = plane
                    self.lastMilliseconds = Date().timeIntervalSince(start) * 1000
                    timing.landed = self.lastMilliseconds ?? 0
                    self.lastTiming = timing
                    // The live stroke goes in the transaction the picture comes back in.
                    MaskLive.shared.landed(ask.planeKey)
                }
                // A stroke's move that waited for this one is the next ask (`MaskTools.payOwed`).
                MaskTools.shared.payOwed()
                self.runNext()
            }
        }
    }

    // MARK: making it

    nonisolated static let context: CIContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }()
    /// The page's picture's space: the overlay is made in it (trap 27).
    nonisolated static let space = CGColorSpace(name: CGColorSpace.displayP3)!

    nonisolated static func make(_ ask: Ask) async -> CGImage? {
        var t = Timing()
        return await make(ask, timing: &t, from: Date())
    }

    nonisolated static func make(_ ask: Ask, timing: inout Timing, from start: Date) async -> CGImage? {
        await made(ask, timing: &timing, from: start)?.image
    }

    nonisolated static func made(_ ask: Ask, timing: inout Timing, from start: Date) async -> (image: CGImage, plane: MaskPlane)? {
        guard let device = MTLCreateSystemDefaultDevice(), let baker = try? SceneLayerWire.baker(for: device),
              let plane = try? await baker.bake(ask.layer, source: ask.source) else { return nil }
        timing.baked = Date().timeIntervalSince(start) * 1000
        let image = render(plane, ask)
        timing.rendered = Date().timeIntervalSince(start) * 1000
        return image.map { ($0, plane) }
    }

    /// Where the picture is drawn, in view points: its whole pixels at `ask.scale` from the visible part's corner. The
    /// picture is laid at exactly `ask.scale` pixels a point (`render`), but is a whole number of pixels; drawn into
    /// `ask.visible` itself it was stretched by the rounding, up to half a pixel at the far edge (the M1c review's
    /// item 3: −0.20 px across S's x-stroke on the flat frame in every framing).
    nonisolated static func drawnRect(_ ask: Ask, _ image: CGImage) -> CGRect {
        CGRect(x: ask.visible.minX, y: ask.visible.minY, width: CGFloat(image.width) / ask.scale, height: CGFloat(image.height) / ask.scale)
    }

    /// The plane laid on the view (`ask.visible` at `ask.scale`), as an overlay or alone.
    nonisolated static func render(_ plane: MaskPlane, _ ask: Ask) -> CGImage? {
        guard let context else { return nil }
        let W = max(1, Int((ask.visible.width * ask.scale).rounded())), H = max(1, Int((ask.visible.height * ask.scale).rounded()))
        guard W * H <= 40_000_000, ask.shown.width > 0, ask.shown.height > 0 else { return nil }
        let w = plane.width, h = plane.height
        // A copy Core Image owns, not the buffer's own memory (`bytesNoCopy`, as M1b had it): the mask alone re-made at
        // every step of a 羽化 drag (a new 22 MB plane each, the store letting the oldest go) ended three `--masks-check`
        // runs in 4 in "memory corruption of free block" (2026-11-13; with the copy, 0 in 3). A copy costs ~2 ms at 4096.
        let data = Data(bytes: plane.buffer.contents(), count: w * h * 2)
        // The plane's values as they are: no colour space, so no conversion touches the mask.
        let mask = CIImage(bitmapData: data, bytesPerRow: w * 2, size: CGSize(width: w, height: h), format: .L16, colorSpace: nil)
        // S → the output's pixels (Core Image's: origin bottom left).
        let fromS = ask.toS.inverted
        func out(_ s: CGPoint) -> CIVector {
            let n = fromS.apply(s)
            let x = (ask.shown.minX + n.x * ask.shown.width - ask.visible.minX) * ask.scale
            let y = (ask.shown.minY + n.y * ask.shown.height - ask.visible.minY) * ask.scale + ask.nudge
            return CIVector(x: x, y: CGFloat(H) - y)
        }
        let placed = mask.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": out(CGPoint(x: 0, y: 0)), "inputTopRight": out(CGPoint(x: 1, y: 0)),
            "inputBottomLeft": out(CGPoint(x: 0, y: 1)), "inputBottomRight": out(CGPoint(x: 1, y: 1)),
        ])
        let frame = CGRect(x: 0, y: 0, width: W, height: H)
        let result: CIImage
        switch ask.mode {
        case .overlay:
            let colour = CIColor(red: red.r, green: red.g, blue: red.b, alpha: alpha, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            result = CIImage(color: colour).cropped(to: frame)
                .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: placed])
        case .alone:
            result = placed.composited(over: CIImage(color: .black).cropped(to: frame))
        }
        return context.createCGImage(result.cropped(to: frame), from: frame, format: .RGBA8, colorSpace: space)
    }

    /// The overlay's red at full mask as it lands in the page's space (trap 27's number): Display P3 components and
    /// alpha, premultiplied as the picture holds them. For `--masks-check`.
    nonisolated static func redInPageSpace() -> [CGFloat]? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGColor(colorSpace: srgb, components: [red.r, red.g, red.b, alpha]),
              let p3 = c.converted(to: space, intent: .defaultIntent, options: nil) else { return nil }
        return p3.components
    }
}
