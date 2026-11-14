//  MaskLive.swift — a brush stroke on the picture while it is being painted: drawn on the main actor at the pointer's
//  own event, into a Metal layer over the overlay, while the exact bake catches up behind it (2.4.0 A1; MASKS-SPEC §6.1,
//  §6.2; `MaskOverlay`).
//
//  **Why.** The overlay is the canonical plane laid on the view (`MaskOverlay`): every pointer move re-baked the layer
//  (6.4 ms at 4096), re-made the overlay through Core Image (7.4 ms) and waited two actor hops; measured by
//  `--masks-check`'s cost, a move reached the overlay in a median 43 ms, worst 100 ms (56 / 315 ms under load 18), on
//  24 and 45 MP alike — 7 to 16 display frames at 160 Hz. The owner: "the brush still feels draggy".
//
//  **What is drawn.** At the press the stroke's own coverage starts at 0 in a float target of the overlay's pixels
//  (the ask's `visible` at its `scale`: the same grid `MaskOverlay.render` makes). Each move draws only the dabs the
//  move added (`MaskBaker.dabs`: the baker's own dabs, every 0.1 r from the first point), each evaluated at the four
//  canonical-plane texel centres round the pixel's place in S and taken bilinearly — what the overlay's bilinear
//  sample of the baked plane sees of one dab — and painted v ← v + α(1 − v), the baker's blend. Then the layer as it
//  will be is composed per pixel from the plane as it was at the press (the pre-stroke plane, sampled as Core Image
//  samples it) and the stroke: the stroke is always the fold's last term (`MaskTools.beginStroke`: it joins the last
//  part, or starts one), so m' = m + c − mc for 加 and m(1 − c) for 减去 — exact for the products, since a stroke
//  joining its part's paint v composes as (m ⊕ v) ⊕ c — swapped by 反相 (1 − m' in the stored plane's terms), and mc for a
//  new 交集 part. A 交集 stroke joining an existing 交集 part cannot be written from m alone: it is not drawn live (the
//  bake shows it, as before). A layer's 羽化 is the plane's Gaussian after the fold; live, the stroke's coverage alone is
//  blurred by the same σ in view pixels, so a feathered layer's live edge is soft as the baked one is (not exact where
//  the stroke overlaps the old mask's soft edge; the bake lands within ~50 ms of the lift).
//
//  **Colour** as `MaskOverlay.render` writes it (trap 27): the red's Display P3 components (`redInPageSpace`) at
//  α = 0.5 m', premultiplied, on a Display P3 layer; the mask alone is m' white on black, sRGB-encoded (Core Image's
//  linear working space to the P3 picture: the plane's values pass as linear), black outside S.
//
//  **When it is shown.** From the press (`covering`: the stage leaves the made picture off for this layer, and the
//  first composite is presented with the Core Animation transaction that does so) until the overlay of the layer as the
//  stroke left it lands (`landed`, from `MaskOverlay`): the made picture comes back and this layer is hidden in that one
//  transaction. Each move presents in its own event (`presentsWithTransaction` off), before the session hears of it
//  (`MaskTools.continueStroke`), so nothing the main actor does after the move stands between it and the screen. At
//  most three composites are on the GPU (the layer's drawables); a move past that is drawn when one is done.
//
//  **Never stored, never the picture.** It is the page's alone, as the overlay is: the edit, the bake and every surface
//  are made from the stroke's points as before (`MaskTools`), byte for byte.

import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore

@MainActor @Observable
final class MaskLive {
    static let shared = MaskLive()

    /// The layer whose overlay the live stroke stands in for, while it does: the stage leaves its made picture off.
    private(set) var covering: UUID?

    /// Where the stage lays the overlay: pushed by the stage (`MaskPointerView`) whenever it is placed. The ask's
    /// fields (`MaskOverlay.Ask`), so the live pixels are the overlay's pixels.
    struct Place: Equatable {
        var source: PixelSize
        var shown: CGRect
        var toS: MaskMatrix
        var visible: CGRect
        var scale: CGFloat
        var size: (w: Int, h: Int) {
            (max(1, Int((visible.width * scale).rounded())), max(1, Int((visible.height * scale).rounded())))
        }
        /// Where the overlay's picture is drawn, in view points (`MaskOverlay.drawnRect`).
        var drawn: CGRect { CGRect(x: visible.minX, y: visible.minY, width: CGFloat(size.w) / scale, height: CGFloat(size.h) / scale) }
        static func == (a: Place, b: Place) -> Bool {
            a.source == b.source && a.shown == b.shown && a.toS == b.toS && a.visible == b.visible && a.scale == b.scale
        }
    }
    @ObservationIgnored var place: Place?
    /// The pointer view's Metal layer, where the live stroke is presented.
    @ObservationIgnored weak var layer: CAMetalLayer?

    /// Off: the path before A1 (every move to the bake), for `--masks-check`'s red against the old path
    /// (`MASKS_LIVE_OFF=1`).
    nonisolated static let enabled: Bool = ProcessInfo.processInfo.environment["MASKS_LIVE_OFF"] == nil

    /// One move's time, from the move's event (`MaskTools.continueStroke`) in ms: the composite committed with its
    /// drawable ("handed to the screen"), the GPU done with it, and the drawable on the screen (0 until it is: a
    /// layer not in a window is never presented).
    struct Timing: Sendable { var handed = 0.0, gpu = 0.0, presented = 0.0, drawable = 0.0, first = false }
    /// Drawables the window server said were never shown (`presentedTime` 0).
    @ObservationIgnored private(set) var unshown = 0
    @ObservationIgnored private(set) var timings: [Int: Timing] = [:]
    @ObservationIgnored private(set) var presents = 0

    private struct Stroke {
        var layerID: UUID
        var alone: Bool
        /// The fold of the stroke's coverage c onto the plane m as it was: 0 m ⊕ c, 1 m(1 − c), 2 mc, 3 1 − (1 − m)c.
        var op: UInt32
        var plane: MaskPlane?
        var place: Place
        var coverage: MTLTexture
        var blurred: MTLTexture?
        var blur: MPSImageGaussianBlur?
        /// The brush's settings for this stroke.
        var brush: BrushSettings?
        /// The stroke's points taken so far, the last of them (metric, as stored: 16 bits), the length since the last
        /// dab, and the dabs not yet drawn: `MaskBaker.dabs` run one point at a time, so a move costs its own points
        /// and not the whole stroke's (measured: packing and re-dabbing a 1,200-point stroke at every move was most of
        /// a move's main-actor time).
        var taken = 0
        var last: SIMD2<Double>?
        var carried = 0.0
        var dabs: [SIMD2<Double>] = []
        /// The plane key of the layer as the stroke left it: the overlay that ends the live drawing.
        var awaiting: String?
        var first = true
    }
    @ObservationIgnored private var live: Stroke?
    @ObservationIgnored private var inFlight = 0
    /// The display's frame (`MaskPointerView` sets it from its screen): what `--masks-check` paces a pointer by.
    @ObservationIgnored var frameSeconds: CFTimeInterval = 1.0 / 120
    @ObservationIgnored private var owed: CFTimeInterval?
    @ObservationIgnored private var giveUp: Task<Void, Never>?

    @ObservationIgnored private let device: MTLDevice?
    @ObservationIgnored private let queue: MTLCommandQueue?
    @ObservationIgnored private var dab: MTLRenderPipelineState?
    @ObservationIgnored private var compose: MTLRenderPipelineState?
    @ObservationIgnored private var composeOffscreen: MTLRenderPipelineState?
    @ObservationIgnored private let red: SIMD3<Float>

    init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        // A CGColor's components are not premultiplied: the red's own, the alpha beside them.
        if let c = MaskOverlay.redInPageSpace(), c.count == 4 {
            red = SIMD3(Float(c[0]), Float(c[1]), Float(c[2]))
        } else {
            red = SIMD3(1, 0.23, 0.19)
        }
        guard let device, let library = try? device.makeLibrary(source: Self.source, options: MaskBaker.options()) else { return }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "live_dab_vertex")
        d.fragmentFunction = library.makeFunction(name: "live_dab_fragment")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .r32Float
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
        // v ← v + α (1 − v), the baker's paint.
        a.sourceRGBBlendFactor = .oneMinusDestinationColor; a.destinationRGBBlendFactor = .one
        a.sourceAlphaBlendFactor = .oneMinusDestinationAlpha; a.destinationAlphaBlendFactor = .one
        dab = try? device.makeRenderPipelineState(descriptor: d)
        let c = MTLRenderPipelineDescriptor()
        c.vertexFunction = library.makeFunction(name: "live_full_vertex")
        c.fragmentFunction = library.makeFunction(name: "live_compose")
        c.colorAttachments[0].pixelFormat = .bgra8Unorm
        compose = try? device.makeRenderPipelineState(descriptor: c)
        c.colorAttachments[0].pixelFormat = .rgba8Unorm
        composeOffscreen = try? device.makeRenderPipelineState(descriptor: c)
    }

    // MARK: the stroke

    /// A stroke begins on `layerID`. `before`: the layer as it was before the stroke (nil: the stroke makes it);
    /// `join`, and whether the stroke joins its last part (`joins`). False where the stroke is not drawn live.
    @discardableResult
    func begin(layerID: UUID, before: LocalLayer?, join: MaskPart.Join, joins: Bool, alone: Bool) -> Bool {
        reset()
        guard Self.enabled, let device, let place, layer != nil, dab != nil, compose != nil else { return false }
        let inverted = before?.invert ?? false
        let op: UInt32
        switch join {
        case .add: op = inverted ? 1 : 0
        case .subtract: op = inverted ? 0 : 1
        case .intersect:
            // m · (v ⊕ c) is not a function of m: left to the bake.
            if joins { return false }
            op = inverted ? 3 : 2
        }
        let (w, h) = place.size
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead, .shaderWrite]
        td.storageMode = .private
        guard let coverage = device.makeTexture(descriptor: td) else { return false }
        var s = Stroke(layerID: layerID, alone: alone, op: op, plane: nil, place: place, coverage: coverage)
        // 羽化: the plane's σ (a share of its long edge) in view pixels about the view's centre.
        if let feather = before?.feather, feather > 0 {
            let plane = MaskBaker.planeSize(source: place.source)
            let sigma = feather * Double(max(plane.width, plane.height)) * pixelsPerTexel(place)
            if sigma > 0.3, let b = device.makeTexture(descriptor: td) {
                s.blurred = b
                let k = MPSImageGaussianBlur(device: device, sigma: Float(sigma))
                k.edgeMode = .clamp
                s.blur = k
            }
        }
        // The plane as it was: the overlay's, when it is of this layer as it stands; else baked (cached under its key).
        if let before {
            let key = MaskBaker.planeKey(before, source: place.source)
            if let p = MaskOverlay.shared.plane, p.key == key {
                s.plane = p
            } else {
                let source = place.source
                Task { [weak self] in
                    guard let baker = try? SceneLayerWire.baker(for: device), let p = try? await baker.bake(before, source: source) else { return }
                    guard let self, self.live?.layerID == layerID, self.live?.plane == nil else { return }
                    self.live?.plane = p
                    self.present(nil)
                }
            }
        }
        live = s
        covering = layerID
        if let layer {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.frame = place.drawn
            layer.contentsScale = place.scale
            layer.drawableSize = CGSize(width: w, height: h)
            CATransaction.commit()
        }
        return true
    }

    /// The stroke as it stands (its points so far, S, with `brush`), drawn: only its new dabs, then the composite
    /// presented. `at`: the move's event, for the timing.
    func draw(_ points: [MaskPoint], brush: BrushSettings, at t0: CFTimeInterval) {
        guard var l = live else { return }
        l.brush = brush
        let long = Double(max(l.place.source.longEdge, 1))
        let ax = Double(l.place.source.width) / long, ay = Double(l.place.source.height) / long
        let step = max(0.1 * brush.radius, 1e-6)
        func q(_ v: Double) -> Double { Double(UInt16((min(max(v, 0), 1) * 65535).rounded())) / 65535 }
        // `MaskBaker.dabs`, a point at a time, on the points as the stroke stores them (`BrushStroke.pack`).
        for p in points.dropFirst(l.taken) {
            let b = SIMD2(q(p.x) * ax, q(p.y) * ay)
            guard let a = l.last else { l.dabs.append(b); l.last = b; continue }
            l.last = b
            let seg = b - a
            let len = (seg * seg).sum().squareRoot()
            guard len > 0 else { continue }
            var t = step - l.carried
            while t <= len {
                l.dabs.append(a + seg * (t / len))
                t += step
            }
            l.carried = len - (t - step)
        }
        l.taken = max(l.taken, points.count)
        live = l
        present(t0)
    }

    /// The pointer lifted: the live drawing stays until the overlay of `key` (the layer as the stroke left it) lands.
    func end(awaiting key: String?) {
        guard live != nil else { return }
        if owed != nil { owed = nil; present(nil) }
        live?.awaiting = key
        if let key, MaskOverlay.shared.made?.planeKey == key, MaskOverlay.shared.plane?.key == key { uncover(); return }
        // Never left over the picture: an overlay that does not come (a refusal, the page left) lets it go.
        giveUp?.cancel()
        giveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.uncover()
        }
    }

    /// The overlay made of `planeKey` was handed to the stage (`MaskOverlay`).
    func landed(_ planeKey: String) {
        guard let l = live, l.awaiting == planeKey else { return }
        uncover()
    }

    /// The overlay is asked for another mask while nothing is drawn (an Undo, another pick): the live drawing goes.
    func asked(_ planeKey: String) {
        guard let l = live, let awaiting = l.awaiting, awaiting != planeKey else { return }
        uncover()
    }

    /// The live drawing put away: the made picture back, in the same transaction.
    func uncover() {
        giveUp?.cancel(); giveUp = nil
        live = nil
        owed = nil
        if covering != nil { covering = nil }
        if let layer, !layer.isHidden {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.isHidden = true
            CATransaction.commit()
        }
    }

    /// The display's frame began: a move held for it is presented now.
    /// From a present to its drawable's presented handler (ms), and the moves a busy GPU held (`--masks-check`).
    @ObservationIgnored var handedBack: [Double] = []
    @ObservationIgnored private(set) var heldByGPU = 0

    private func reset() { if live != nil || covering != nil { uncover() } }

    // MARK: drawing

    /// View pixels a plane texel, about the visible part's centre (the local scale of S → the view's pixels).
    private func pixelsPerTexel(_ place: Place) -> Double {
        let plane = MaskBaker.planeSize(source: place.source)
        let ps = Self.pixelToS(place), sp = ps.inverted
        let c = ps.apply(CGPoint(x: Double(place.size.w) / 2, y: Double(place.size.h) / 2))
        let o = sp.apply(c), ex = sp.apply(CGPoint(x: c.x + 1 / Double(plane.width), y: c.y)), ey = sp.apply(CGPoint(x: c.x, y: c.y + 1 / Double(plane.height)))
        return (hypot(ex.x - o.x, ex.y - o.y) + hypot(ey.x - o.x, ey.y - o.y)) / 2
    }

    /// The overlay's pixels (top-left origin, pixel centres at i + ½) → S: the ask's `visible` at its `scale`, then
    /// `shown`'s normalised coordinates, then the view's matrix — `MaskOverlay.render`'s `out` inverted.
    nonisolated static func pixelToS(_ p: Place) -> MaskMatrix {
        let sw = Double(max(p.shown.width, 1e-9)), sh = Double(max(p.shown.height, 1e-9)), k = Double(p.scale)
        let toN = MaskMatrix([1 / (k * sw), 0, Double(p.visible.minX - p.shown.minX) / sw,
                              0, 1 / (k * sh), Double(p.visible.minY - p.shown.minY) / sh, 0, 0, 1])
        return p.toS.after(toN)
    }

    /// The kernels' numbers: px → S and S → px (row-major), the target's and the plane's sizes, metric → texels, the
    /// stroke's dab, the fold, the mode, the red.
    private func info(_ l: Stroke) -> [Float] {
        let ps = Self.pixelToS(l.place), sp = ps.inverted
        let plane = MaskBaker.planeSize(source: l.place.source)
        let long = Double(max(l.place.source.longEdge, 1))
        let ax = Double(l.place.source.width) / long, ay = Double(l.place.source.height) / long
        let s = l.brush
        let (w, h) = l.place.size
        var f = ps.floats + sp.floats
        f += [Float(w), Float(h), Float(plane.width), Float(plane.height),
              Float(Double(plane.width) / ax), Float(Double(plane.height) / ay),
              Float(max(s?.radius ?? 0, 1e-6) * Double(max(plane.width, plane.height))),
              Float(min(max(s?.hardness ?? 1, 0), 1)),
              Float(1 - pow(1 - min(max(s?.flow ?? 1, 0), 1), 1.0 / 20)),
              Float(l.op), l.alone ? 1 : 0, red.x, red.y, red.z, l.plane == nil ? 0 : 1, 0]
        return f
    }

    private func present(_ t0: CFTimeInterval?) {
        guard let l = live, let layer, let queue, let compose else { return }
        // A present per move, as the move comes: a pointer's events come once a display frame (UIKit coalesces the
        // rest: `MaskPress`). Only a GPU still on the last three (the layer's drawables) holds a move, to be drawn when one is done. Measured
        // (2026-11-13, `--masks-check`'s cost): holding moves for the display's next frame (a display link) or for the
        // drawable's presented handler held them 40–140 ms whenever the main actor was busy; a present per move
        // waits in `nextDrawable` at most about a frame, and only when moves come faster than the display.
        guard inFlight < 3 else {
            heldByGPU += 1
            owed = owed ?? t0 ?? CACurrentMediaTime()
            return
        }
        let first = l.first
        // The first composite with the transaction that leaves the made picture off (the stage's, this turn's).
        layer.presentsWithTransaction = first
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        let gotDrawable = CACurrentMediaTime()
        encode(cb, l)
        live?.first = false
        composite(cb, l, into: drawable.texture, pipeline: compose)
        inFlight += 1
        presents += 1
        let n = presents
        let start = t0
        let committed = CACurrentMediaTime()
        drawable.addPresentedHandler { d in
            let at = d.presentedTime, back = CACurrentMediaTime()
            Task { @MainActor in
                MaskLive.shared.handedBack.append((back - committed) * 1000)
                guard let start else { return }
                if at > 0 { MaskLive.shared.timings[n]?.presented = (at - start) * 1000 } else { MaskLive.shared.unshown += 1 }
            }
        }
        cb.addCompletedHandler { _ in
            let done = CACurrentMediaTime()
            Task { @MainActor in
                let me = MaskLive.shared
                me.inFlight -= 1
                if let start { me.timings[n]?.gpu = (done - start) * 1000 }
                if let o = me.owed { me.owed = nil; me.present(o) }
            }
        }
        if first {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.isHidden = false
            CATransaction.commit()
        } else {
            cb.present(drawable)
            cb.commit()
        }
        if let start {
            timings[n] = Timing(handed: (CACurrentMediaTime() - start) * 1000, drawable: (gotDrawable - start) * 1000, first: first)
            if timings.count > 512 { timings = timings.filter { $0.key > n - 256 } }
        }
    }

    /// The new dabs into the coverage, and the feather's blur of it.
    private func encode(_ cb: MTLCommandBuffer, _ l: Stroke) {
        guard let dab, let device else { return }
        let new = l.dabs
        live?.dabs = []
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = l.coverage
        pass.colorAttachments[0].loadAction = l.first ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !new.isEmpty {
            var f = info(l)
            let centres = new.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            e.setRenderPipelineState(dab)
            if let vb = device.makeBuffer(bytes: centres, length: centres.count * 8, options: .storageModeShared) {
                e.setVertexBuffer(vb, offset: 0, index: 0)
                e.setVertexBytes(&f, length: f.count * 4, index: 1)
                e.setFragmentBytes(&f, length: f.count * 4, index: 0)
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: centres.count)
            }
        }
        e.endEncoding()
        if let blur = l.blur, let to = l.blurred { blur.encode(commandBuffer: cb, sourceTexture: l.coverage, destinationTexture: to) }
    }

    private func composite(_ cb: MTLCommandBuffer, _ l: Stroke, into target: MTLTexture, pipeline: MTLRenderPipelineState) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = info(l)
        e.setRenderPipelineState(pipeline)
        e.setFragmentBytes(&f, length: f.count * 4, index: 0)
        e.setFragmentTexture(l.blurred ?? l.coverage, index: 0)
        if let p = l.plane { e.setFragmentBuffer(p.buffer, offset: 0, index: 1) } else {
            var zero: UInt16 = 0
            e.setFragmentBytes(&zero, length: 2, index: 1)
        }
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }

    // MARK: for the check

    /// A stroke is being drawn live.
    var isLive: Bool { live != nil }

    #if DEBUG
    /// The live composite as it stands, read back: RGBA8, premultiplied, the overlay's pixels (`--masks-check`
    /// holds it against the overlay that replaces it). Nil where nothing is drawn live.
    func snapshot() async -> (w: Int, h: Int, bytes: [UInt8])? {
        guard let l = live, let device, let queue, let composeOffscreen else { return nil }
        let (w, h) = l.place.size
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let t = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        if let blur = l.blur, let to = l.blurred { blur.encode(commandBuffer: cb, sourceTexture: l.coverage, destinationTexture: to) }
        composite(cb, l, into: t, pipeline: composeOffscreen)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            cb.addCompletedHandler { _ in done.resume() }
            cb.commit()
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        t.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return (w, h, bytes)
    }
    var hasPlane: Bool { live?.plane != nil }
    #endif

    // MARK: the kernels

    nonisolated static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // f: [0..8] px → S, [9..17] S → px (row-major), 18 W, 19 H, 20 plane w, 21 plane h, 22 kx, 23 ky (metric → texels),
    // 24 the dab's radius (texels), 25 hardness, 26 α₀, 27 the fold, 28 alone, 29..31 the red (P3), 32 a plane.
    inline float2 proj(constant float* f, int o, float2 p) {
        const float x = f[o] * p.x + f[o + 1] * p.y + f[o + 2];
        const float y = f[o + 3] * p.x + f[o + 4] * p.y + f[o + 5];
        const float w = f[o + 6] * p.x + f[o + 7] * p.y + f[o + 8];
        return float2(x, y) / w;
    }
    inline float s01(float t) { return t * t * (3.0f - 2.0f * t); }
    inline float smooth_edges(float e0, float e1, float x) {
        if (e0 == e1) return x < e0 ? 0.0f : 1.0f;
        return s01(clamp((x - e0) / (e1 - e0), 0.0f, 1.0f));
    }

    struct DabOut { float4 position [[position]]; float2 centre; };

    // One dab: the square round its centre in the plane's texels (radius + the bilinear's texel), through S to the
    // overlay's pixels — a quadrilateral that holds the dab under any of the view's maps.
    vertex DabOut live_dab_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  device const float2* centres [[buffer(0)]], constant float* f [[buffer(1)]]) {
        const float2 corner = float2(float(vid & 1u), float(vid >> 1u)) * 2.0f - 1.0f;
        const float2 c = centres[iid] * float2(f[22], f[23]);
        const float2 t = c + corner * (f[24] + 2.0f);
        const float2 px = proj(f, 9, t / float2(f[20], f[21]));
        DabOut o;
        o.position = float4(px.x / f[18] * 2.0f - 1.0f, 1.0f - px.y / f[19] * 2.0f, 0.0f, 1.0f);
        o.centre = c;
        return o;
    }

    // The dab at the four plane texel centres round the pixel's place, bilinear: as the overlay samples a baked dab.
    fragment float4 live_dab_fragment(DabOut in [[stage_in]], constant float* f [[buffer(0)]]) {
        const float2 s = proj(f, 0, in.position.xy);
        const float2 u = s * float2(f[20], f[21]) - 0.5f;
        const float2 i0 = floor(u), fr = u - i0;
        float a[4];
        for (int k = 0; k < 4; ++k) {
            const float2 i = i0 + float2(float(k & 1), float(k >> 1));
            if (i.x < 0.0f || i.y < 0.0f || i.x >= f[20] || i.y >= f[21]) { a[k] = 0.0f; continue; }
            const float rho = distance(i + 0.5f, in.centre) / f[24];
            a[k] = f[26] * (1.0f - smooth_edges(f[25], 1.0f, rho));
        }
        const float v = mix(mix(a[0], a[1], fr.x), mix(a[2], a[3], fr.x), fr.y);
        return float4(v, v, v, v);
    }

    struct FullOut { float4 position [[position]]; };
    vertex FullOut live_full_vertex(uint vid [[vertex_id]]) {
        const float2 p = float2(float((vid << 1u) & 2u), float(vid & 2u)) * 2.0f - 1.0f;
        FullOut o; o.position = float4(p, 0.0f, 1.0f); return o;
    }

    inline float plane_at(device const ushort* m, constant float* f, float2 s) {
        const float2 u = s * float2(f[20], f[21]) - 0.5f;
        const float2 i0 = floor(u), fr = u - i0;
        const uint w = uint(f[20]);
        float a[4];
        for (int k = 0; k < 4; ++k) {
            const float2 i = i0 + float2(float(k & 1), float(k >> 1));
            if (i.x < 0.0f || i.y < 0.0f || i.x >= f[20] || i.y >= f[21]) { a[k] = 0.0f; continue; }
            a[k] = float(m[uint(i.y) * w + uint(i.x)]) * (1.0f / 65535.0f);
        }
        return mix(mix(a[0], a[1], fr.x), mix(a[2], a[3], fr.x), fr.y);
    }
    inline float srgb_encode(float v) { return v <= 0.0031308f ? 12.92f * v : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f; }

    // The layer as it will be: the plane as it was folded with the stroke, as the overlay or the mask alone.
    fragment float4 live_compose(FullOut in [[stage_in]], constant float* f [[buffer(0)]],
                                 texture2d<float, access::read> cover [[texture(0)]], device const ushort* plane [[buffer(1)]]) {
        const float2 s = proj(f, 0, in.position.xy);
        const float m = f[32] > 0.5f ? plane_at(plane, f, s) : 0.0f;
        const float c = clamp(cover.read(uint2(in.position.xy)).r, 0.0f, 1.0f);
        const uint op = uint(f[27]);
        float v = op == 0u ? m + c - m * c : op == 1u ? m * (1.0f - c) : op == 2u ? m * c : 1.0f - (1.0f - m) * c;
        // Outside S the plane's texels are nothing (the taps' 0): the overlay clear, the mask alone black.
        v = clamp(v, 0.0f, 1.0f);
        if (f[28] > 0.5f) { const float g = srgb_encode(v); return float4(g, g, g, 1.0f); }
        const float a = 0.5f * v;
        return float4(f[29] * a, f[30] * a, f[31] * a, a);
    }
    """
}
