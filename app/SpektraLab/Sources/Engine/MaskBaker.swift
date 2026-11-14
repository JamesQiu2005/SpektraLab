//  MaskBaker.swift — a layer's mask → the canonical 16-bit plane in S (RFC-052 §4), on the GPU, off the main actor.
//
//  **One plane a layer, one size for every tier** (§4.4): long edge `L_c = min(4096, the source's long edge)`, the
//  source's shape, 16-bit unorm, rows tight, top row first, texel (i, j) centred at S = ((i + 0.5)/W, (j + 0.5)/H) —
//  what `spk_set_scene_layers` takes and what part B's local kernels will sample. Every surface at every size samples
//  this one plane; nothing is rasterised again for a tier, so a mask cannot differ by tier at its edges.
//
//  The bake, in order (§4.1, §4.2):
//
//  1. each part that is on, evaluated into a float plane of the plane's size, at the texel's centre in metric
//     coordinates (units of the source's long edge, so a circle is a circle on any aspect):
//     - **linear**: t = (p − a)·(b − a)/‖b − a‖², c = 1 − s(clamp(t, 0, 1)), s(t) = t²(3 − 2t); a = b writes 0;
//     - **radial**: d = ‖R(−θ)(p − centre)/(rx, ry)‖, c = 1 − smoothstep(1 − f, 1, d), and f = 0 a step at d = 1;
//     - **brush**: its strokes drawn in order into a float target, one instanced draw a stroke, a dab every 0.1 r of
//       the stroke's length, α(ρ) = α₀ (1 − smoothstep(h, 1, ρ)), α₀ = 1 − (1 − F)^(1/20), painted
//       v ← v + α(1 − v) (blend: source × (1 − destination) + destination) or erased v ← v(1 − α) (blend:
//       destination × (1 − source)) — fixed-function blends, which a GPU applies in the order the dabs were
//       submitted. A checkpoint plane is kept every 32 strokes (`MaskStore`), so a new stroke is drawn onto the
//       plane already made and Undo redraws from the last checkpoint, never the whole list;
//     - **found**: its immutable 8-bit picture, sampled bilinear at the texel's centre, inverted for 背景;
//  2. folded in list order from m = 0 by the **product forms** (add m + c − mc, subtract m(1 − c), intersect mc), or
//     — for RFC-052 gate 10 only, behind `JoinFamily.maxMin` — by max(m, c), max(m − c, 0), min(m, c);
//  3. feathered: a separable Gaussian, σ metric (σ·L_c texels), edges clamped, three σ each side;
//  4. inverted where 反相 is set; quantised to 16 bits, round to nearest. Outside S is the sampler's 0 (the plane
//     covers exactly S).
//
//  Smoothsteps whose two edges are equal (a radial feather of 0, a brush hardness of 1) are steps, taken by a branch
//  and not by dividing by zero (§4.1).
//
//  **Math flags.** The app compiles its own kernels at run time from strings (no `.metal` file may be in the app's
//  target, which compiles with `MTL_FAST_MATH = YES`; AGENTS.md): `Layer2Kernel`, `OutputTransformer`, `HDRRendition`
//  and this one all with `MTLCompileOptions.mathMode = .safe` and `mathFloatingPointFunctions = .precise` (macOS 15 /
//  Catalyst 18, the app's floor), `fastMathEnabled = false` before it — the engine's kernels' `-fmetal-math-mode=safe
//  -fmetal-math-fp32-functions=precise` (engine/build.sh). Chosen the same: a mask's smoothstep and its Gaussian then
//  give the same numbers whichever build or machine bakes them, and a stamp names a plane that is one picture.
//
//  Cost (RFC-052 §10.6): `tools/mask_bake_drive.swift`, written down in the commit that records it.

import CoreGraphics
import Foundation
import Metal

/// RFC-052 §4.2's two joining families: the products are the product's; max/min is gate 10's to look at.
enum JoinFamily: String, Sendable, CaseIterable {
    case products
    case maxMin
}

/// A found mask's picture as the baker is handed it: 8 bits, `width × height`, rows tight, top row first, in S.
struct FoundPicture: Sendable {
    var width: Int
    var height: Int
    var bytes: [UInt8]
}

/// A baked plane: immutable once made. The buffer is shared storage on the device it was baked on; nothing writes
/// into it after `bake` returns (the engine retains it; RFC-052 §6.4).
struct MaskPlane: @unchecked Sendable {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    /// The hash of what it was made from (`MaskBaker.planeKey`): its cache key and its part of the stamp.
    let key: String
    var bytes: Int { width * height * 2 }

    /// The plane's values, read back (shared storage). For checks and pictures; never written.
    var values: [UInt16] {
        let p = buffer.contents().bindMemory(to: UInt16.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: p, count: width * height))
    }
}

actor MaskBaker {
    enum Failure: Error, CustomStringConvertible {
        /// `missingFound`: a found part whose picture is neither handed nor in the files (`FoundMaskFiles`) — never
        /// baked as empty or as full; the layer it is in is named, so a page can mark that row (M1c).
        case compile(String), noRoom(String), missingFound(asset: String, layer: UUID, name: String), gpu(String)
        var description: String {
            switch self {
            case .compile(let s): "the mask kernels did not compile: \(s)"
            case .noRoom(let s): "no room for the mask: \(s)"
            case .missingFound(let asset, let layer, let name): "no picture for the found mask \(asset) of the layer \"\(name)\" (\(layer))"
            case .gpu(let s): "the mask bake failed: \(s)"
            }
        }
    }

    /// RFC-052 §4.4: the canonical plane's long edge, at most. Raised only if M0's look at a hard edge at 45 and
    /// 100 MP says so (gate "the hard brush edge").
    static let maxLongEdge = 4096
    /// A checkpoint of a brush's drawn plane every this many strokes (RFC-052 §4.1).
    static let checkpointEvery = 32

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    private let paint: MTLRenderPipelineState
    private let erase: MTLRenderPipelineState
    /// The brush's drawn planes: checkpoints and the last one made (`MaskStore`).
    let store: MaskStore

    init(device: MTLDevice, store: MaskStore = MaskStore()) throws {
        self.device = device
        self.store = store
        guard let q = device.makeCommandQueue() else { throw Failure.gpu("no command queue") }
        queue = q
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.source, options: Self.options()) } catch { throw Failure.compile("\(error)") }
        var p: [String: MTLComputePipelineState] = [:]
        for name in ["mask_linear", "mask_radial", "mask_found", "mask_fold", "mask_blur", "mask_quantise", "mask_copy_texture"] {
            guard let f = library.makeFunction(name: name) else { throw Failure.compile("no \(name)") }
            p[name] = try device.makeComputePipelineState(function: f)
        }
        pipelines = p
        func brush(_ erasing: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "dab_vertex")
            d.fragmentFunction = library.makeFunction(name: "dab_fragment")
            let a = d.colorAttachments[0]!
            a.pixelFormat = .r32Float
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            if erasing {
                // v ← v (1 − α): source × 0 + destination × (1 − source).
                a.sourceRGBBlendFactor = .zero; a.destinationRGBBlendFactor = .oneMinusSourceColor
                a.sourceAlphaBlendFactor = .zero; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else {
                // v ← v + α (1 − v): source × (1 − destination) + destination × 1.
                a.sourceRGBBlendFactor = .oneMinusDestinationColor; a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .oneMinusDestinationAlpha; a.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        paint = try brush(false)
        erase = try brush(true)
    }

    /// Safe math, as the engine's kernels and Layer 2's are compiled (`Layer2Kernel.options`).
    nonisolated static func options() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        if #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else {
            options.fastMathEnabled = false
        }
        return options
    }

    // MARK: size and key

    /// The canonical plane's size for a source of this size: long edge `min(4096, source's)`, the source's shape.
    nonisolated static func planeSize(source: PixelSize, maxLongEdge: Int = MaskBaker.maxLongEdge) -> PixelSize {
        let long = max(source.longEdge, 1)
        let lc = min(maxLongEdge, long)
        let s = Double(lc) / Double(long)
        return PixelSize(width: max(1, Int((Double(source.width) * s).rounded())), height: max(1, Int((Double(source.height) * s).rounded())))
    }

    /// What a plane is made of, as a word: the plane's size and the source's shape, the parts that are on with their
    /// joins and their own fields (a found part by its asset's hash), the feather, the invert, the family. The plane's
    /// cache key, and its part of the `scene_layers` stamp. Not the layer's deltas, opacity or name: those do not
    /// change the plane.
    nonisolated static func planeKey(_ layer: LocalLayer, source: PixelSize, family: JoinFamily = .products,
                                     maxLongEdge: Int = MaskBaker.maxLongEdge) -> String {
        let size = planeSize(source: source, maxLongEdge: maxLongEdge)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var parts = layer.foldOrder
        for i in parts.indices { parts[i].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }
        let body = (try? e.encode(parts)) ?? Data()
        let words = "v1|\(size.width)x\(size.height)|\(source.width)x\(source.height)|\(family.rawValue)|f=\(layer.feather)|i=\(layer.invert)|"
        return StampHash.hex(Data(words.utf8) + body)
    }

    // MARK: the bake

    /// The layer's plane for a source of `source`'s size. A found part's picture is `found`'s by its asset
    /// (`MaskPart.asset`) where it is handed, else the store's, read from its file (`MaskStore.foundPicture`); a part
    /// with neither fails the bake (`missingFound`). Cached under `planeKey`.
    func bake(_ layer: LocalLayer, source: PixelSize, found: [String: FoundPicture] = [:], family: JoinFamily = .products,
              maxLongEdge: Int = MaskBaker.maxLongEdge) async throws -> MaskPlane {
        let key = Self.planeKey(layer, source: source, family: family, maxLongEdge: maxLongEdge)
        if let kept = await store.plane(key) { return kept }
        let size = Self.planeSize(source: source, maxLongEdge: maxLongEdge)
        let w = size.width, h = size.height, n = w * h
        let long = Double(max(source.longEdge, 1))
        var info = BakeInfo(w: UInt32(w), h: UInt32(h), ax: Float(Double(source.width) / long), ay: Float(Double(source.height) / long))
        guard let m = device.makeBuffer(length: n * 4, options: .storageModePrivate),
              let c = device.makeBuffer(length: n * 4, options: .storageModePrivate),
              let out = device.makeBuffer(length: n * 2, options: .storageModeShared) else {
            throw Failure.noRoom("\(w) x \(h)")
        }
        guard let cb = queue.makeCommandBuffer() else { throw Failure.gpu("no command buffer") }
        if let b = cb.makeBlitCommandEncoder() { b.fill(buffer: m, range: 0..<n * 4, value: 0); b.endEncoding() }
        for part in layer.foldOrder {
            switch part.kind {
            case .linear:
                guard let g = part.linear else { continue }
                var ab = SIMD4<Float>(Float(g.a.x) * info.ax, Float(g.a.y) * info.ay, Float(g.b.x) * info.ax, Float(g.b.y) * info.ay)
                dispatch(cb, "mask_linear", w, h) { e in
                    e.setBuffer(c, offset: 0, index: 0); e.setBytes(&info, length: MemoryLayout<BakeInfo>.stride, index: 1)
                    e.setBytes(&ab, length: 16, index: 2)
                }
            case .radial:
                guard let g = part.radial else { continue }
                let a = g.angle * .pi / 180
                var r = RadialInfo(cx: Float(g.centre.x) * info.ax, cy: Float(g.centre.y) * info.ay, rx: Float(max(g.rx, 1e-9)),
                                   ry: Float(max(g.ry, 1e-9)), cosA: Float(cos(a)), sinA: Float(sin(a)),
                                   feather: Float(min(max(g.feather, 0), 1)), pad: 0)
                dispatch(cb, "mask_radial", w, h) { e in
                    e.setBuffer(c, offset: 0, index: 0); e.setBytes(&info, length: MemoryLayout<BakeInfo>.stride, index: 1)
                    e.setBytes(&r, length: MemoryLayout<RadialInfo>.stride, index: 2)
                }
            case .brush:
                guard let b = part.brush else { continue }
                let texture = try await drawn(b, size: size, source: source, cb: cb)
                dispatch(cb, "mask_copy_texture", w, h) { e in
                    e.setTexture(texture, index: 0); e.setBuffer(c, offset: 0, index: 0)
                    e.setBytes(&info, length: MemoryLayout<BakeInfo>.stride, index: 1)
                }
            case .found:
                // A found part with no asset or no provenance is a record that lost its picture: it fails as a
                // missing one does, never baked as nothing.
                guard let f = part.found, let hash = part.asset else {
                    throw Failure.missingFound(asset: part.asset ?? "", layer: layer.id, name: layer.name)
                }
                var handed = found[hash]
                if handed == nil { handed = await store.foundPicture(hash) }
                guard let pic = handed, pic.width > 0, pic.height > 0, pic.bytes.count >= pic.width * pic.height else {
                    throw Failure.missingFound(asset: hash, layer: layer.id, name: layer.name)
                }
                guard let src = device.makeBuffer(bytes: pic.bytes, length: pic.width * pic.height, options: .storageModeShared) else {
                    throw Failure.noRoom("found \(pic.width) x \(pic.height)")
                }
                var fi = SIMD4<UInt32>(UInt32(pic.width), UInt32(pic.height), f.invert ? 1 : 0, 0)
                dispatch(cb, "mask_found", w, h) { e in
                    e.setBuffer(c, offset: 0, index: 0); e.setBytes(&info, length: MemoryLayout<BakeInfo>.stride, index: 1)
                    e.setBuffer(src, offset: 0, index: 2); e.setBytes(&fi, length: 16, index: 3)
                }
            }
            var fold = SIMD4<UInt32>(UInt32(n), Self.joinCode(part.join), family == .maxMin ? 1 : 0, 0)
            dispatch1(cb, "mask_fold", n) { e in
                e.setBuffer(m, offset: 0, index: 0); e.setBuffer(c, offset: 0, index: 1); e.setBytes(&fold, length: 16, index: 2)
            }
        }
        // The feather: horizontally into `c`, vertically back into `m`.
        let sigma = Float(layer.feather * Double(max(w, h)))
        if sigma > 0 {
            for (from, to, vertical) in [(m, c, UInt32(0)), (c, m, UInt32(1))] {
                var blur = BlurInfo(w: UInt32(w), h: UInt32(h), vertical: vertical, radius: UInt32(min(Float(max(w, h)), (3 * sigma).rounded(.up))), sigma: sigma)
                dispatch(cb, "mask_blur", w, h) { e in
                    e.setBuffer(from, offset: 0, index: 0); e.setBuffer(to, offset: 0, index: 1)
                    e.setBytes(&blur, length: MemoryLayout<BlurInfo>.stride, index: 2)
                }
            }
        }
        var q = SIMD4<UInt32>(UInt32(n), layer.invert ? 1 : 0, 0, 0)
        dispatch1(cb, "mask_quantise", n) { e in
            e.setBuffer(m, offset: 0, index: 0); e.setBuffer(out, offset: 0, index: 1); e.setBytes(&q, length: 16, index: 2)
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            cb.addCompletedHandler { _ in done.resume() }
            cb.commit()
        }
        if let error = cb.error { throw Failure.gpu("\(error)") }
        let plane = MaskPlane(buffer: out, width: w, height: h, key: key)
        await store.keep(plane)
        return plane
    }

    nonisolated static func joinCode(_ j: MaskPart.Join) -> UInt32 {
        switch j { case .add: 0; case .subtract: 1; case .intersect: 2 }
    }

    // MARK: the brush

    /// A brush's strokes drawn into a float target of the plane's size, from the longest drawn prefix the store
    /// holds (a checkpoint every 32 strokes, and the last plane made), the rest drawn onto it in order.
    private func drawn(_ brush: BrushStrokes, size: PixelSize, source: PixelSize, cb: MTLCommandBuffer) async throws -> MTLTexture {
        let strokes = brush.strokes
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: size.width, height: size.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d) else { throw Failure.noRoom("brush \(size.width) x \(size.height)") }
        var from = 0
        if let (count, kept) = await store.longestDrawn(strokes, size: size, source: source), count > 0 {
            if let b = cb.makeBlitCommandEncoder() { b.copy(from: kept, to: target); b.endEncoding() }
            from = count
        }
        let long = Double(max(source.longEdge, 1))
        // Metric → the plane's texels, per axis (the plane's shape is the source's to a rounding).
        let kx = Double(size.width) / (Double(source.width) / long), ky = Double(size.height) / (Double(source.height) / long)
        let rScale = Double(max(size.width, size.height))
        var first = from == 0
        for i in from..<strokes.count {
            let s = strokes[i]
            let dabs = Self.dabs(s, ax: Double(source.width) / long, ay: Double(source.height) / long)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = first ? .clear : .load
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            first = false
            guard !dabs.isEmpty, let e = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
            e.setRenderPipelineState(s.erase ? erase : paint)
            var dabInfo = DabInfo(w: Float(size.width), h: Float(size.height), radius: Float(max(s.radius, 1e-6) * rScale),
                                  hardness: Float(min(max(s.hardness, 0), 1)),
                                  alpha0: Float(1 - pow(1 - min(max(s.flow, 0), 1), 1.0 / 20)), pad: 0, kx: Float(kx), ky: Float(ky))
            let centres = dabs.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            guard let vb = device.makeBuffer(bytes: centres, length: centres.count * 8, options: .storageModeShared) else { e.endEncoding(); continue }
            e.setVertexBuffer(vb, offset: 0, index: 0)
            e.setVertexBytes(&dabInfo, length: MemoryLayout<DabInfo>.stride, index: 1)
            e.setFragmentBytes(&dabInfo, length: MemoryLayout<DabInfo>.stride, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: centres.count)
            e.endEncoding()
            let done = i + 1
            // Kept: the last two checkpoints and the plane made. An earlier checkpoint is not copied when a list is
            // drawn from nothing — the copies live until the command buffer ends, so all of them would be the bake's
            // peak (measured: +674 MB for 200 strokes at 4096 with every one kept, RFC-052 §10.6).
            let lastCheckpoint = (strokes.count / Self.checkpointEvery) * Self.checkpointEvery
            let keeps = done == strokes.count || (done % Self.checkpointEvery == 0 && done >= lastCheckpoint - Self.checkpointEvery)
            if keeps {
                // Kept for the next stroke and for Undo: a copy, so the target can go on being drawn into.
                guard let copy = device.makeTexture(descriptor: d) else { continue }
                if let b = cb.makeBlitCommandEncoder() { b.copy(from: target, to: copy); b.endEncoding() }
                await store.keepDrawn(Array(strokes[0..<done]), size: size, source: source, texture: copy, checkpoint: done % Self.checkpointEvery == 0)
            }
        }
        if from == 0, strokes.isEmpty {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        return target
    }

    /// A stroke's dabs in metric coordinates: one at its first point and one every 0.1 r of its length after it
    /// (RFC-052 §4.1). Metric so the same stroke lays the same coverage at any plane size.
    nonisolated static func dabs(_ s: BrushStroke, ax: Double, ay: Double) -> [SIMD2<Double>] {
        let pts = s.unpacked.map { SIMD2(Double($0.x) * ax, Double($0.y) * ay) }
        guard let first = pts.first else { return [] }
        let step = max(0.1 * s.radius, 1e-6)
        var out = [first]
        var carried = 0.0          // length since the last dab
        for (a, b) in zip(pts, pts.dropFirst()) {
            let seg = b - a
            let len = (seg * seg).sum().squareRoot()
            guard len > 0 else { continue }
            var t = step - carried
            while t <= len {
                out.append(a + seg * (t / len))
                t += step
            }
            carried = len - (t - step)
        }
        return out
    }

    // MARK: dispatch

    private func dispatch(_ cb: MTLCommandBuffer, _ name: String, _ w: Int, _ h: Int, _ set: (MTLComputeCommandEncoder) -> Void) {
        guard let e = cb.makeComputeCommandEncoder(), let p = pipelines[name] else { return }
        e.setComputePipelineState(p)
        set(e)
        let tw = 16, th = 16
        e.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        e.endEncoding()
    }

    private func dispatch1(_ cb: MTLCommandBuffer, _ name: String, _ n: Int, _ set: (MTLComputeCommandEncoder) -> Void) {
        guard let e = cb.makeComputeCommandEncoder(), let p = pipelines[name] else { return }
        e.setComputePipelineState(p)
        set(e)
        e.dispatchThreadgroups(MTLSize(width: (n + 255) / 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding()
    }

    struct BakeInfo { var w: UInt32; var h: UInt32; var ax: Float; var ay: Float }
    struct RadialInfo { var cx, cy, rx, ry, cosA, sinA, feather, pad: Float }
    struct BlurInfo { var w: UInt32; var h: UInt32; var vertical: UInt32; var radius: UInt32; var sigma: Float }
    struct DabInfo { var w, h, radius, hardness, alpha0, pad, kx, ky: Float }

    // MARK: the kernels

    nonisolated static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct BakeInfo { uint w; uint h; float ax; float ay; };
    struct RadialInfo { float cx, cy, rx, ry, cosA, sinA, feather, pad; };
    struct BlurInfo { uint w; uint h; uint vertical; uint radius; float sigma; };
    struct DabInfo { float w, h, radius, hardness, alpha0, pad, kx, ky; };

    // The texel's centre in metric coordinates: S = ((i + 0.5)/W, (j + 0.5)/H), times (W_s/L, H_s/L).
    inline float2 metric_at(uint2 g, constant BakeInfo& b) {
        return float2((float(g.x) + 0.5f) / float(b.w) * b.ax, (float(g.y) + 0.5f) / float(b.h) * b.ay);
    }
    inline float s01(float t) { return t * t * (3.0f - 2.0f * t); }
    // smoothstep(e0, e1, x); equal edges are a step at the edge, by a branch (RFC-052 §4.1).
    inline float smooth_edges(float e0, float e1, float x) {
        if (e0 == e1) return x < e0 ? 0.0f : 1.0f;
        return s01(clamp((x - e0) / (e1 - e0), 0.0f, 1.0f));
    }

    kernel void mask_linear(device float* c [[buffer(0)]], constant BakeInfo& b [[buffer(1)]],
                            constant float4& ab [[buffer(2)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= b.w || g.y >= b.h) return;
        const float2 p = metric_at(g, b), a = ab.xy, d = ab.zw - ab.xy;
        const float l2 = dot(d, d);
        float v = 0.0f;
        if (l2 > 0.0f) v = 1.0f - s01(clamp(dot(p - a, d) / l2, 0.0f, 1.0f));
        c[g.y * b.w + g.x] = v;
    }

    kernel void mask_radial(device float* c [[buffer(0)]], constant BakeInfo& b [[buffer(1)]],
                            constant RadialInfo& r [[buffer(2)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= b.w || g.y >= b.h) return;
        const float2 q = metric_at(g, b) - float2(r.cx, r.cy);
        // R(−θ) q, θ clockwise with y down.
        const float u = q.x * r.cosA + q.y * r.sinA, v = -q.x * r.sinA + q.y * r.cosA;
        const float d = length(float2(u / r.rx, v / r.ry));
        c[g.y * b.w + g.x] = 1.0f - smooth_edges(1.0f - r.feather, 1.0f, d);
    }

    // A found mask's 8-bit picture, bilinear between its texel centres, clamped at its edge.
    kernel void mask_found(device float* c [[buffer(0)]], constant BakeInfo& b [[buffer(1)]],
                           device const uchar* pic [[buffer(2)]], constant uint4& fi [[buffer(3)]],
                           uint2 g [[thread_position_in_grid]]) {
        if (g.x >= b.w || g.y >= b.h) return;
        const float pw = float(fi.x), ph = float(fi.y);
        const float s = (float(g.x) + 0.5f) / float(b.w), t = (float(g.y) + 0.5f) / float(b.h);
        const float x = clamp(s * pw - 0.5f, 0.0f, pw - 1.0f), y = clamp(t * ph - 0.5f, 0.0f, ph - 1.0f);
        const float x0f = floor(x), y0f = floor(y), tx = x - x0f, ty = y - y0f;
        const uint x0 = uint(x0f), y0 = uint(y0f), x1 = min(x0 + 1u, fi.x - 1u), y1 = min(y0 + 1u, fi.y - 1u);
        const float a = float(pic[y0 * fi.x + x0]), bb = float(pic[y0 * fi.x + x1]);
        const float cc = float(pic[y1 * fi.x + x0]), d = float(pic[y1 * fi.x + x1]);
        const float top = a + (bb - a) * tx, bot = cc + (d - cc) * tx;
        float v = (top + (bot - top) * ty) * (1.0f / 255.0f);
        if (fi.z != 0u) v = 1.0f - v;
        c[g.y * b.w + g.x] = v;
    }

    // The brush's drawn plane, into the part's coverage.
    kernel void mask_copy_texture(texture2d<float, access::read> t [[texture(0)]], device float* c [[buffer(0)]],
                                  constant BakeInfo& b [[buffer(1)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= b.w || g.y >= b.h) return;
        c[g.y * b.w + g.x] = clamp(t.read(g).r, 0.0f, 1.0f);
    }

    // One part folded into m (RFC-052 §4.2). family 0: the products; 1: max / max(m − c, 0) / min (gate 10).
    kernel void mask_fold(device float* m [[buffer(0)]], device const float* c [[buffer(1)]],
                          constant uint4& f [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        if (i >= f.x) return;
        const float a = m[i], k = c[i];
        float v;
        if (f.z == 0u) v = f.y == 0u ? a + k - a * k : f.y == 1u ? a * (1.0f - k) : a * k;
        else v = f.y == 0u ? max(a, k) : f.y == 1u ? max(a - k, 0.0f) : min(a, k);
        m[i] = v;
    }

    // One direction of the feather's Gaussian, σ in texels, edges clamped, weights normalised over the window.
    kernel void mask_blur(device const float* from [[buffer(0)]], device float* to [[buffer(1)]],
                          constant BlurInfo& b [[buffer(2)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= b.w || g.y >= b.h) return;
        const int R = int(b.radius);
        const float k = -0.5f / (b.sigma * b.sigma);
        float sum = 0.0f, wsum = 0.0f;
        for (int o = -R; o <= R; ++o) {
            const float w = exp(k * float(o * o));
            int x = int(g.x), y = int(g.y);
            if (b.vertical == 0u) x = clamp(x + o, 0, int(b.w) - 1); else y = clamp(y + o, 0, int(b.h) - 1);
            sum += w * from[uint(y) * b.w + uint(x)];
            wsum += w;
        }
        to[g.y * b.w + g.x] = sum / wsum;
    }

    // 反相, then 16 bits, round to nearest.
    kernel void mask_quantise(device const float* m [[buffer(0)]], device ushort* out [[buffer(1)]],
                              constant uint4& q [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        if (i >= q.x) return;
        float v = clamp(m[i], 0.0f, 1.0f);
        if (q.y != 0u) v = 1.0f - v;
        out[i] = ushort(rint(v * 65535.0f));
    }

    struct DabOut { float4 position [[position]]; float2 centre; };

    // One dab: a quad round its centre, in the plane's texels (top-left origin), to clip space.
    vertex DabOut dab_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             device const float2* centres [[buffer(0)]], constant DabInfo& d [[buffer(1)]]) {
        const float2 corner = float2(float(vid & 1u), float(vid >> 1u)) * 2.0f - 1.0f;
        const float2 c = centres[iid] * float2(d.kx, d.ky);
        const float2 p = c + corner * (d.radius + 1.0f);
        DabOut o;
        o.position = float4(p.x / d.w * 2.0f - 1.0f, 1.0f - p.y / d.h * 2.0f, 0.0f, 1.0f);
        o.centre = c;
        return o;
    }

    fragment float4 dab_fragment(DabOut in [[stage_in]], constant DabInfo& d [[buffer(0)]]) {
        // The fragment's position is its pixel's centre (i + 0.5, j + 0.5), the texel centre of the plane.
        const float rho = distance(in.position.xy, in.centre) / d.radius;
        const float a = d.alpha0 * (1.0f - smooth_edges(d.hardness, 1.0f, rho));
        return float4(a, a, a, a);
    }
    """
}

/// A stable hash of bytes, as hex: what a plane's key and the `scene_layers` stamp are named by. FNV-1a 64 over the
/// bytes, twice with two offsets (128 bits): no CryptoKit in the Foundation-only checks, and no collision a person's
/// edits can make by chance.
enum StampHash {
    static func hex(_ data: Data) -> String {
        var a: UInt64 = 0xcbf29ce484222325, b: UInt64 = 0x84222325cbf29ce4
        for byte in data {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte)) &* 0x100000001b3
            b = b &+ (a >> 29)
        }
        return String(format: "%016llx%016llx", a, b)
    }
    static func hex(_ s: String) -> String { hex(Data(s.utf8)) }
}
