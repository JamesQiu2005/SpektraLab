//  Layer2Local.swift — Edit's pass with a local amount of each scalar control: the 成片 stage of PRD-E (RFC-052 §7).
//
//  **A layer is a field of offsets to a control** (RFC-052 §2.1). For each of Edit's eleven scalar controls — exposure,
//  contrast, brightness, highlights, shadows, black point, white point, saturation, vibrance, temperature, tint — the
//  pass reads, per pixel, `c(x) = c₀ + Σ kᵢ(x)·Δcᵢ` **in the sliders' own units** (`Adjustments`' numbers), and only
//  then makes the kernel's number from it the way `Layer2Uniforms.tone` makes it from the slider (`exposureGain =
//  2^exposure`, `wbGain` from temperature and tint, `contrast / 100`, …), and runs `l2Tone` and the rest of `l2Apply` as
//  they are. Interpolating the kernel's numbers instead would make a half-covered pixel something other than the control
//  at half its amount (2^(e/2) is not (1 + 2^e)/2; `tools/layer2_local_selftest.swift` shows that red). The curve, the
//  colour balance, HSL, the channel mixer and the vignette are tables and matrices: the whole picture's, once, in their
//  places (RFC-052 §2.2).
//
//  - **New entry points, not changed ones.** `spkLayer2` and its siblings are compiled from `Layer2Kernel.source` as
//    they were, untouched; a surface with no acting 成片 layer dispatches them, so a picture without layers is today's
//    picture to the bit. The local variants live in a library of their own (`source`) and are dispatched only with
//    layers. `kᵢ = 0` at a pixel adds `+ 0` to nothing: a control with no offset there **keeps the whole picture's own
//    kernel number** (`u`'s, made in Swift), so its step takes today's branch — not run where its control is zero —
//    and the pixel is today's to the bit (held by the self-test). A control whose whole is zero and whose layer is not
//    runs its step where the layer reaches and is the exact identity where it does not.
//  - **The tone is today's text.** `l2ToneLocal`, `l2HslLocal` and `l2ApplyLocal` are not a copy kept beside
//    `Layer2Kernel.functions`: they are made from it at run time (`derived`), the same statements with the block taken
//    from thread memory instead of `constant` (the per-pixel block is the pixel's own), so a change to the tone reaches
//    both. A source that no longer has the lines they are made from compiles to an `#error` naming them.
//  - **The mapping is twice now** — `Layer2Uniforms.tone` in Swift and `l2LocalBlock` below (trap 28). The full-mask
//    identity test (`layer2_local_selftest`: each control, at a few deltas including the ends of its range, with the
//    whole's own value non-zero) is what holds them together.
//  - **Masks are sampled by hand**, bilinear between texel centres at (i + 0.5)/N, clamped at the plane's edge, 0
//    outside S, `a + (b − a)·t` — `scene_layer_sample` of the engine's node (`engine/src/shaders/scene_layers.metal`),
//    statement for statement, so a full plane (65,535) is k = 1 exactly and a full mask is the whole picture's control.
//    Every surface reads the same canonical plane (`MaskBaker`, cached by `planeKey`), never a rasterisation of its own.
//  - **One matrix a surface**: its pixels' normalised coordinates → S (`MaskFrame`). The page's picture, the histogram's
//    copy and a tile's copy are the finished canvas (`FinishedLayers.toSource`); the export's kernel and the zoom work on
//    the engine's result before the host's quarter turns (`MaskFrame.hostTurns`). Edit's crop (`printCrop`) is made
//    after the pass on every surface (a view's crop, `FinishedCut` for a file), so it never enters the matrix.
//  - `Adjustments.enabled` off is the whole pass off, the layers with it (`acts`).
//
//  Compiled at run time with safe math (`Layer2Kernel.options`), as every kernel of the app's is: no `.metal` file in
//  the target.

import CoreGraphics
import Foundation
import Metal

/// An edit's acting 成片 layers, as Edit's pass takes them: everything but the planes, which are baked from `layers` off
/// the main actor (`planes`). Nil where none acts (`of`): the pass is then today's.
struct FinishedLayers: Equatable, Sendable {
    struct Layer: Equatable, Sendable {
        var layer: LocalLayer
        /// The plane's key (`MaskBaker.planeKey`): the same plane the 场景 stage and every surface reads.
        var planeKey: String
        /// The deltas, `FinishedDeltas.values`' order, narrowed to the floats the kernel is handed.
        var deltas: [Float]
        /// on · opacity.
        var coverage: Float
    }

    var layers: [Layer]
    /// The photograph's size: the planes' shape and L_c.
    var source: PixelSize
    /// The finished canvas (after the engine and the host's quarter turns, before Edit's crop), normalised → S.
    var toSource: MaskMatrix
    var family: JoinFamily = .products
    /// Found parts' pictures handed by asset (a driver's, a check's). Empty in the app: the baker reads them from
    /// their files (`MaskStore.foundPicture`, `FoundMaskFiles`), for the page, the zoom, a tile, the histogram and the
    /// export alike; a part with no file fails the bake naming its layer (`MaskBaker.Failure.missingFound`).
    var found: [String: FoundPicture] = [:]

    /// What the pass draws, as a word: each plane's key, each delta and coverage as the kernel's floats, the matrix.
    /// For a cache and a file's name (`Layer2Copies`), beside `Adjustments.key`.
    var key: String {
        var words = "finished_layers v1|"
        for l in layers {
            words += l.planeKey + ":" + (l.deltas + [l.coverage]).map { String($0.bitPattern, radix: 16) }.joined(separator: ",") + "|"
        }
        words += toSource.floats.map { String($0.bitPattern, radix: 16) }.joined(separator: ",")
        return "fl1." + StampHash.hex(words)
    }

    static func == (a: FinishedLayers, b: FinishedLayers) -> Bool { a.key == b.key && a.source == b.source && a.family == b.family }

    /// An edit's 成片 layers that can move a pixel (`LocalLayers.active(.finished)`, at most 8), or nil: none, or Edit's
    /// pass switched off (`Adjustments.enabled`, which takes the layers with it). `toSource` is the finished canvas → S
    /// (`MaskFrame.finished`).
    static func of(_ layers: LocalLayers?, adjustments: Adjustments, source: PixelSize, toSource: MaskMatrix,
                   family: JoinFamily = .products, found: [String: FoundPicture] = [:]) -> FinishedLayers? {
        guard adjustments.enabled else { return nil }
        let acting = Array((layers?.active(.finished) ?? []).prefix(Layer2Local.maxLayers))
        guard !acting.isEmpty else { return nil }
        let made = acting.map { l in
            Layer(layer: l, planeKey: MaskBaker.planeKey(l, source: source, family: family),
                  deltas: (l.finished ?? FinishedDeltas()).values.map { Float($0) }, coverage: Float(l.coverage))
        }
        return FinishedLayers(layers: made, source: source, toSource: toSource, family: family, found: found)
    }

    /// The matrix of a surface that is the engine's result before the host's `turns` clockwise quarter turns (the
    /// export's kernel, the zoom): its normalised coordinates → the finished canvas → S.
    func matrix(turnsAfter turns: Int) -> MaskMatrix { toSource.after(MaskFrame.hostTurns(turns)) }

    // MARK: the planes, off the main actor

    /// The planes, in the layers' order, from the baker of `device` (its store keeps them by key, so a plane the
    /// 场景 stage or another surface baked is the same buffer). Async: for a task.
    func planes(device: MTLDevice) async throws -> [MaskPlane] {
        let baker = try SceneLayerWire.baker(for: device)
        var out: [MaskPlane] = []
        for l in layers { out.append(try await baker.bake(l.layer, source: source, found: found, family: family)) }
        return out
    }

    /// The same, blocking the calling thread until they are made: for a queue of the pass's own or the engine's,
    /// never the main actor nor a task's thread.
    func planesBlocking(device: MTLDevice) throws -> [MaskPlane] {
        let box = PlanesBox()
        let done = DispatchSemaphore(value: 0)
        let me = self
        Task.detached(priority: .userInitiated) {
            do { box.set(.success(try await me.planes(device: device))) } catch { box.set(.failure(error)) }
            done.signal()
        }
        done.wait()
        return try box.get()
    }

    private final class PlanesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[MaskPlane], Error> = .success([])
        func set(_ r: Result<[MaskPlane], Error>) { lock.lock(); result = r; lock.unlock() }
        func get() throws -> [MaskPlane] { lock.lock(); defer { lock.unlock() }; return try result.get() }
    }
}

/// One surface's layers, ready to dispatch: the planes and the block of `Layer2LocalBlock` (below) for its matrix.
struct Layer2LocalPass: @unchecked Sendable {
    let planes: [MaskPlane]
    let block: [UInt8]

    /// `matrix` is the surface's normalised coordinates → S (`FinishedLayers.toSource`, or `matrix(turnsAfter:)`).
    init(_ layers: FinishedLayers, planes: [MaskPlane], adjustments a: Adjustments, matrix: MaskMatrix) {
        self.planes = planes
        block = Layer2Local.block(base: Layer2Local.base(a), layers: Array(zip(layers.layers, planes)), matrix: matrix)
    }

    /// The block at `index` and the eight planes after it (a slot with no layer reads the first plane; the kernel
    /// never samples past `count`).
    func bind(_ e: MTLComputeCommandEncoder, at index: Int) {
        block.withUnsafeBytes { e.setBytes($0.baseAddress!, length: $0.count, index: index) }
        guard let first = planes.first else { return }          // count 0 in the block: nothing is sampled
        for i in 0..<Layer2Local.maxLayers { e.setBuffer(i < planes.count ? planes[i].buffer : first.buffer, offset: 0, index: index + 1 + i) }
    }
}

enum Layer2Local {
    /// PRD-E §9 decision 8: 8 a stage on a photograph.
    static let maxLayers = 8

    /// Whether Edit's pass runs: switched on, and either the whole picture's controls or a 成片 layer move something.
    static func acts(_ a: Adjustments, _ layers: FinishedLayers?) -> Bool { a.isActive || (a.enabled && layers != nil) }

    /// The whole picture's controls in the sliders' units, `FinishedDeltas.values`' order: the block's `base`.
    static func base(_ a: Adjustments) -> [Double] {
        [a.exposure, a.contrast, a.brightness, a.highlights, a.shadows, a.blackPoint, a.whitePoint, a.saturation, a.vibrance,
         a.temperature, a.tint]
    }

    /// `Layer2LocalBlock` as the kernels lay it out: `m` (9 floats, 3 spare), `base` (11, 1 spare), `count` and three
    /// spare words, then eight layers of `delta` (11, 1 spare), `width`, `height`, `coverage`, a spare: 624 bytes.
    static func block(base: [Double], layers: [(FinishedLayers.Layer, MaskPlane)], matrix: MaskMatrix) -> [UInt8] {
        var w = [UInt32](repeating: 0, count: 156)
        for (i, v) in matrix.floats.enumerated() { w[i] = v.bitPattern }
        for (i, v) in base.prefix(11).enumerated() { w[12 + i] = Float(v).bitPattern }
        let n = min(layers.count, maxLayers)
        w[24] = UInt32(n)
        for (i, (l, p)) in layers.prefix(n).enumerated() {
            let o = 28 + 16 * i
            for (j, d) in l.deltas.prefix(11).enumerated() { w[o + j] = d.bitPattern }
            w[o + 12] = UInt32(p.width); w[o + 13] = UInt32(p.height)
            w[o + 14] = l.coverage.bitPattern
        }
        return w.withUnsafeBytes { Array($0) }
    }

    // MARK: the kernels

    /// The local functions: today's HSL, tone and pass made from `Layer2Kernel.functions` for a block in thread memory,
    /// the mask's sampling, and the per-pixel block.
    static let functions = derived(Layer2Kernel.functions) + "\n" + blockFunctions

    /// Everything the host's local kernels need, after `Layer2Kernel.functions` (whose names they read).
    static let source = Layer2Kernel.functions + "\n" + functions + "\n" + kernels

    /// `l2HslLocal`, `l2ToneLocal` and `l2ApplyLocal`, made from `text` (the shared functions) by changing the block's
    /// address space and nothing else. Each change must find exactly what it changes, or the result is an `#error`.
    static func derived(_ text: String) -> String {
        func between(_ a: String, _ b: String) -> String? {
            guard let s = text.range(of: a), let e = text.range(of: b, range: s.upperBound..<text.endIndex) else { return nil }
            return String(text[s.lowerBound..<e.lowerBound])
        }
        /// `from` → `to` in `t`, where `from` is there exactly `count` times.
        func change(_ t: inout String, _ from: String, _ to: String, _ count: Int) -> Bool {
            guard t.components(separatedBy: from).count - 1 == count else { return false }
            t = t.replacingOccurrences(of: from, with: to)
            return true
        }
        guard var tone = between("static inline float3 l2Hsl(", "// A row of the five-row table"),
              var apply = between("static inline float3 l2Apply(", "static inline ushort l2To16(") else {
            return "#error \"the local pass: Layer2Kernel.functions has no l2Hsl ... l2Curve or l2Apply ... l2To16\"\n"
        }
        guard change(&tone, "constant Layer2Uniforms &u", "thread const Layer2Uniforms &u", 2),
              change(&tone, "l2Hsl(", "l2HslLocal(", 2),
              change(&tone, "l2Tone(", "l2ToneLocal(", 1),
              change(&apply, "static inline float3 l2Apply(float3 c, float2 uv, constant Layer2Uniforms &u, device const float *curves) {",
                     "static inline float3 l2ApplyLocal(float3 c, float2 uv, constant Layer2Uniforms &u, device const float *curves, thread const Layer2Uniforms &v) {", 1),
              change(&apply, "c = l2Tone(c, u);", "c = l2ToneLocal(c, v);", 1) else {
            return "#error \"the local pass: Layer2Kernel.functions no longer has the lines l2ToneLocal is made from\"\n"
        }
        return "// Made from Layer2Kernel.functions at run time (Layer2Local.derived): the block in thread memory.\n" + tone + apply
    }

    static let blockFunctions = #"""
    struct L2LocalLayer { float delta[12]; uint width; uint height; float coverage; uint pad; };
    struct Layer2LocalBlock {          // must match Layer2Local.block
        float m[12];                   // the surface's normalised coordinates -> S, row-major 3 x 3 (3 spare)
        float base[12];                // the whole picture's controls in the sliders' units (FinishedDeltas.values' order)
        uint count; uint pad0; uint pad1; uint pad2;
        L2LocalLayer layers[8];
    };

    // The plane's value at S = (s, t): the engine's scene_layer_sample (scene_layers.metal), statement for statement --
    // bilinear on texel centres, clamped at the plane's edge, 0 outside S, a + (b - a) t so a full plane is 1 exactly.
    static inline float l2MaskSample(device const ushort* plane, float pw, float ph, float s, float t) {
        if (!(s >= 0.0f && s <= 1.0f && t >= 0.0f && t <= 1.0f)) return 0.0f;
        const uint W = (uint)pw, H = (uint)ph;
        float x = clamp(s * pw - 0.5f, 0.0f, pw - 1.0f);
        float y = clamp(t * ph - 0.5f, 0.0f, ph - 1.0f);
        float x0f = floor(x), y0f = floor(y);
        float tx = x - x0f, ty = y - y0f;
        uint x0 = (uint)x0f, y0 = (uint)y0f;
        uint x1 = min(x0 + 1u, W - 1u), y1 = min(y0 + 1u, H - 1u);
        float a = (float)plane[y0 * W + x0], b = (float)plane[y0 * W + x1];
        float c = (float)plane[y1 * W + x0], d = (float)plane[y1 * W + x1];
        float top = a + (b - a) * tx;
        float bot = c + (d - c) * tx;
        return (top + (bot - top) * ty) * (1.0f / 65535.0f);
    }

    #define L2_PLANE_PARAMS(i0, i1, i2, i3, i4, i5, i6, i7) \
        device const ushort *l2m0 [[buffer(i0)]], device const ushort *l2m1 [[buffer(i1)]], \
        device const ushort *l2m2 [[buffer(i2)]], device const ushort *l2m3 [[buffer(i3)]], \
        device const ushort *l2m4 [[buffer(i4)]], device const ushort *l2m5 [[buffer(i5)]], \
        device const ushort *l2m6 [[buffer(i6)]], device const ushort *l2m7 [[buffer(i7)]]
    #define L2_PLANES l2m0, l2m1, l2m2, l2m3, l2m4, l2m5, l2m6, l2m7

    // The pixel's own block: the whole picture's (`u`), and for each control a layer moves here, c0 + sum k d in the
    // slider's units through the slider's mapping (Layer2Uniforms.tone). A control no layer moves here keeps u's number
    // exactly, so its step runs, or does not, as today's does.
    static inline Layer2Uniforms l2LocalBlock(constant Layer2Uniforms &u, constant Layer2LocalBlock &L, float2 f,
                                             device const ushort *m0, device const ushort *m1, device const ushort *m2,
                                             device const ushort *m3, device const ushort *m4, device const ushort *m5,
                                             device const ushort *m6, device const ushort *m7) {
        Layer2Uniforms v = u;
        float s = L.m[0] * f.x + L.m[1] * f.y + L.m[2];
        float t = L.m[3] * f.x + L.m[4] * f.y + L.m[5];
        const float w = L.m[6] * f.x + L.m[7] * f.y + L.m[8];
        if (w != 1.0f) { s /= w; t /= w; }
        float d[11] = { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
        for (uint l = 0u; l < L.count && l < 8u; ++l) {
            device const ushort* plane = l == 0u ? m0 : l == 1u ? m1 : l == 2u ? m2 : l == 3u ? m3
                                       : l == 4u ? m4 : l == 5u ? m5 : l == 6u ? m6 : m7;
            const float k = L.layers[l].coverage * l2MaskSample(plane, float(L.layers[l].width), float(L.layers[l].height), s, t);
            if (k == 0.0f) continue;
            for (uint j = 0u; j < 11u; ++j) d[j] += k * L.layers[l].delta[j];
        }
        // Layer2Uniforms.tone, control by control: exposure, contrast, brightness, highlights, shadows, black point,
        // white point, saturation, vibrance (Adjustments.uniforms), temperature and tint together.
        if (d[0] != 0.0f) v.exposureGain = exp2(L.base[0] + d[0]);
        if (d[1] != 0.0f) v.contrast = (L.base[1] + d[1]) / 100.0f;
        if (d[2] != 0.0f) v.brightness = (L.base[2] + d[2]) / 100.0f;
        if (d[3] != 0.0f) v.highlights = (L.base[3] + d[3]) / 100.0f;
        if (d[4] != 0.0f) v.shadows = (L.base[4] + d[4]) / 100.0f;
        if (d[5] != 0.0f) v.blackPoint = (L.base[5] + d[5]) / 100.0f;
        if (d[6] != 0.0f) v.whitePoint = (L.base[6] + d[6]) / 100.0f;
        if (d[7] != 0.0f) v.saturation = 1.0f + (L.base[7] + d[7]) / 100.0f;
        if (d[8] != 0.0f) v.vibrance = (L.base[8] + d[8]) / 100.0f;
        if (d[9] != 0.0f || d[10] != 0.0f) {
            const float tt = (L.base[9] + d[9]) / 100.0f, g = (L.base[10] + d[10]) / 100.0f;
            v.wbGain = float3(1.0f + 0.18f * tt, 1.0f - 0.12f * g, 1.0f - 0.18f * tt);
        }
        return v;
    }

    // The whole pass on one pixel with its layers: `uv` is its place in the whole picture (the vignette's), `f` its
    // place on the surface the matrix is of (the same point on every surface but the export's and the zoom's, where
    // both are the engine's result before the host's turns).
    static inline float3 l2LocalApply(float3 c, float2 uv, float2 f, constant Layer2Uniforms &u, device const float *curves,
                                      constant Layer2LocalBlock &L,
                                      device const ushort *m0, device const ushort *m1, device const ushort *m2,
                                      device const ushort *m3, device const ushort *m4, device const ushort *m5,
                                      device const ushort *m6, device const ushort *m7) {
        if (u.enabled == 0u) return c;
        const Layer2Uniforms v = l2LocalBlock(u, L, f, m0, m1, m2, m3, m4, m5, m6, m7);
        return l2ApplyLocal(c, uv, u, curves, v);
    }
    """#

    /// The host's local kernels: `spkLayer2`, `spkLayer2Float` and `spkLayer2Histogram` with the block at 5 and the
    /// planes at 6–13; everything else is theirs.
    static let kernels = #"""
    struct Layer2LocalSize { uint width; uint height; uint stride; uint applies; };   // Layer2Size's

    kernel void spkLayer2Local(device const ushort *src [[buffer(0)]],
                               device ushort *dst [[buffer(1)]],
                               constant Layer2Uniforms &u [[buffer(2)]],
                               device const float *curves [[buffer(3)]],
                               constant Layer2LocalSize &size [[buffer(4)]],
                               constant Layer2LocalBlock &L [[buffer(5)]],
                               L2_PLANE_PARAMS(6, 7, 8, 9, 10, 11, 12, 13),
                               uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.width || gid.y >= size.height) return;
        uint i = (gid.y * size.width + gid.x) * 4u;
        float3 c = float3(src[i], src[i + 1u], src[i + 2u]) / 65535.0f;
        float2 uv = (float2(gid) + 0.5f) / float2(size.width, size.height);
        c = l2LocalApply(c, uv, uv, u, curves, L, L2_PLANES);
        dst[i]      = l2To16(c.x);
        dst[i + 1u] = l2To16(c.y);
        dst[i + 2u] = l2To16(c.z);
        dst[i + 3u] = (ushort)65535;
    }

    kernel void spkLayer2LocalFloat(device const ushort *src [[buffer(0)]],
                                    device float4 *dst [[buffer(1)]],
                                    constant Layer2Uniforms &u [[buffer(2)]],
                                    device const float *curves [[buffer(3)]],
                                    constant Layer2LocalSize &size [[buffer(4)]],
                                    constant Layer2LocalBlock &L [[buffer(5)]],
                                    L2_PLANE_PARAMS(6, 7, 8, 9, 10, 11, 12, 13),
                                    uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= size.width || gid.y >= size.height) return;
        uint p = gid.y * size.width + gid.x;
        float3 c = float3(src[p * 4u], src[p * 4u + 1u], src[p * 4u + 2u]) / 65535.0f;
        float2 uv = (float2(gid) + 0.5f) / float2(size.width, size.height);
        dst[p] = float4(l2LocalApply(c, uv, uv, u, curves, L, L2_PLANES), 1.0f);
    }

    kernel void spkLayer2LocalHistogram(device const ushort *src [[buffer(0)]],
                                        device atomic_uint *bins [[buffer(1)]],
                                        constant Layer2Uniforms &u [[buffer(2)]],
                                        device const float *curves [[buffer(3)]],
                                        constant Layer2LocalSize &size [[buffer(4)]],
                                        constant Layer2LocalBlock &L [[buffer(5)]],
                                        L2_PLANE_PARAMS(6, 7, 8, 9, 10, 11, 12, 13),
                                        uint2 gid [[thread_position_in_grid]])
    {
        uint2 p = gid * size.stride;
        if (p.x >= size.width || p.y >= size.height) return;
        uint i = (p.y * size.width + p.x) * 4u;
        float3 c = float3(src[i], src[i + 1u], src[i + 2u]) / 65535.0f;
        if (size.applies != 0u) {
            float2 uv = (float2(p) + 0.5f) / float2(size.width, size.height);
            c = l2LocalApply(c, uv, uv, u, curves, L, L2_PLANES);
        }
        c = saturate(c);
        uint r = uint(c.r * 255.0f + 0.5f), g = uint(c.g * 255.0f + 0.5f), b = uint(c.b * 255.0f + 0.5f);
        uint y = uint(saturate(l2Luma(c)) * 255.0f + 0.5f);
        atomic_fetch_add_explicit(&bins[r], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[256u + g], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[512u + b], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bins[768u + y], 1u, memory_order_relaxed);
    }
    """#

    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries: [ObjectIdentifier: MTLLibrary] = [:]

    /// The local kernels on `device`, compiled once and kept (safe math). `source` is for a check that compiles a
    /// broken copy.
    static func library(_ device: MTLDevice, source: String = Layer2Local.source) throws -> MTLLibrary {
        let shared = source == Layer2Local.source
        let key = ObjectIdentifier(device)
        if shared {
            lock.lock()
            if let made = libraries[key] { lock.unlock(); return made }
            lock.unlock()
        }
        let made: MTLLibrary
        do { made = try device.makeLibrary(source: source, options: Layer2Kernel.options()) } catch {
            throw Layer2Kernel.Failure.compile("the local pass: \(error)")
        }
        if shared { lock.lock(); libraries[key] = made; lock.unlock() }
        return made
    }
}
