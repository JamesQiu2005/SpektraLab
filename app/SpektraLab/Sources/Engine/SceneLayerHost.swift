//  SceneLayerHost.swift — the 场景 layers where no engine runs: 应用胶片模拟 off (RFC-052 §6.5).
//
//  With the film off there is no session and no film; the frame is Apple's decode with Edit on top
//  (`DigitalDecode`). A 场景 layer still applies, on the linear decode, by **the same expression as the engine's node**
//  (`engine/src/shaders/scene_layers.metal`), transliterated here and held to it:
//
//      k_i(x) = coverage_i · m_i(x)           m sampled by hand, bilinear between texel centres, clamped, 0 outside S
//      scalar (no colour delta in any layer): RGB' = 2^(Σ k_i e_i) · RGB,  e_i = g_i / ln 2 narrowed to float
//      colour: G = Σ k_i g_i; G = 0 → RGB unchanged; else RGB' = C⁻¹ · diag(exp G) · C · RGB
//
//  The pixel's place in S is one matrix (`MaskFrame.finished`: the decode is cut by the frame's whole geometry, so
//  the frame is the finished picture). C is the host's copy of the engine's reply (`SceneLayerWire.rgbToCone`),
//  held to the recorded reply by `tools/scene_layer_selftest.swift`, which also holds this kernel to the expression
//  in double: the bar of RFC-052 §10.1 (the engine's own: ≤ 1 count of 16 bits).
//
//  Two copies of §6.1, which is the cost RFC-052 §6.5 names; the self-test is what holds them together (trap 28).
//  Compiled at run time with safe math, as the engine's kernels and every other kernel of the app's are.

import Foundation
import Metal

final class SceneLayerHost: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case compile(String), gpu(String)
        var description: String {
            switch self { case .compile(let s): "the scene layers' host kernel did not compile: \(s)"; case .gpu(let s): "scene layers (host): \(s)" }
        }
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw Failure.gpu("no queue") }
        queue = q
        do {
            let library = try device.makeLibrary(source: Self.source, options: MaskBaker.options())
            pipeline = try device.makePipelineState(library.makeFunction(name: "spk_scene_layers_host")!)
        } catch { throw Failure.compile("\(error)") }
    }

    /// The layers applied in place to `pixels`: `width × height` RGBA float, linear in C's space (ProPhoto), rows tight.
    /// `frameToSource` is the frame's normalised coordinates → S. A frame no layer reaches is left to the bit.
    func apply(_ ask: SceneLayerWire.Ask, planes: [MaskPlane], frameToSource: MaskMatrix, to pixels: MTLBuffer,
               width: Int, height: Int) throws {
        let count = min(ask.layers.count, planes.count, 8)
        guard count > 0 else { return }
        let colour = ask.layers.prefix(count).contains { !($0.logGain.x == $0.logGain.y && $0.logGain.y == $0.logGain.z) }
        var p = [Float](repeating: 0, count: 27 + 8 * 8)
        for i in 0..<9 { p[i] = frameToSource.floats[i] }
        let c = SceneLayerWire.rgbToCone.map { Float($0) }, ci = SceneLayerWire.coneToRGB.map { Float($0) }
        for i in 0..<9 { p[9 + i] = c[i]; p[18 + i] = ci[i] }
        for (i, l) in ask.layers.prefix(count).enumerated() {
            let b = 27 + 8 * i
            p[b] = l.coverage
            // The scalar path's exponent as the engine makes it: g / ln 2, narrowed.
            p[b + 1] = Float(Double(l.logGain.x) / M_LN2)
            p[b + 2] = l.logGain.x; p[b + 3] = l.logGain.y; p[b + 4] = l.logGain.z
            p[b + 5] = Float(planes[i].width); p[b + 6] = Float(planes[i].height)
        }
        var meta: [UInt32] = [UInt32(width * height), UInt32(width), UInt32(height), UInt32(count), colour ? 1 : 0]
        guard let cb = queue.makeCommandBuffer(), let e = cb.makeComputeCommandEncoder() else { throw Failure.gpu("no encoder") }
        e.setComputePipelineState(pipeline)
        e.setBuffer(pixels, offset: 0, index: 0)
        e.setBytes(&meta, length: meta.count * 4, index: 1)
        e.setBytes(&p, length: p.count * 4, index: 2)
        for i in 0..<8 { e.setBuffer(planes[min(i, count - 1)].buffer, offset: 0, index: 3 + i) }
        let n = width * height
        e.dispatchThreadgroups(MTLSize(width: (n + 255) / 256, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw Failure.gpu("\(error)") }
    }

    /// The engine's kernel's arithmetic, for a frame that is already the picture (no engine cut): RGBA float in place.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    inline float scene_layer_sample(device const ushort* plane, float pw, float ph, float s, float t) {
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

    kernel void spk_scene_layers_host(device float* img [[buffer(0)]], device const uint* meta [[buffer(1)]],
                                      device const float* p [[buffer(2)]],
                                      device const ushort* m0 [[buffer(3)]], device const ushort* m1 [[buffer(4)]],
                                      device const ushort* m2 [[buffer(5)]], device const ushort* m3 [[buffer(6)]],
                                      device const ushort* m4 [[buffer(7)]], device const ushort* m5 [[buffer(8)]],
                                      device const ushort* m6 [[buffer(9)]], device const ushort* m7 [[buffer(10)]],
                                      uint i [[thread_position_in_grid]]) {
        if (i >= meta[0]) return;
        const uint W = meta[1], H = meta[2];
        const float u = ((float)(i % W) + 0.5f) / (float)W;
        const float v = ((float)(i / W) + 0.5f) / (float)H;
        float s = p[0] * u + p[1] * v + p[2];
        float t = p[3] * u + p[4] * v + p[5];
        const float w = p[6] * u + p[7] * v + p[8];
        if (w != 1.0f) { s /= w; t /= w; }
        const uint count = meta[3];
        const bool colour = meta[4] != 0u;
        float E = 0.0f;
        float3 G = float3(0.0f);
        for (uint l = 0u; l < count; ++l) {
            device const float* L = p + 27u + 8u * l;
            device const ushort* plane = l == 0u ? m0 : l == 1u ? m1 : l == 2u ? m2 : l == 3u ? m3
                                       : l == 4u ? m4 : l == 5u ? m5 : l == 6u ? m6 : m7;
            const float k = L[0] * scene_layer_sample(plane, L[5], L[6], s, t);
            if (k == 0.0f) continue;
            E += k * L[1];
            G += k * float3(L[2], L[3], L[4]);
        }
        device float* px = img + 4u * i;
        const float r = px[0], gg = px[1], b = px[2];
        if (!colour) {
            const float gain = exp2(E);
            px[0] = r * gain; px[1] = gg * gain; px[2] = b * gain;
            return;
        }
        if (G.x == 0.0f && G.y == 0.0f && G.z == 0.0f) return;
        const float3 e = exp(G);
        const float l0 = (p[9] * r + p[10] * gg + p[11] * b) * e.x;
        const float l1 = (p[12] * r + p[13] * gg + p[14] * b) * e.y;
        const float l2 = (p[15] * r + p[16] * gg + p[17] * b) * e.z;
        px[0] = p[18] * l0 + p[19] * l1 + p[20] * l2;
        px[1] = p[21] * l0 + p[22] * l1 + p[23] * l2;
        px[2] = p[24] * l0 + p[25] * l1 + p[26] * l2;
    }
    """
}

private extension MTLDevice {
    func makePipelineState(_ f: MTLFunction) throws -> MTLComputePipelineState { try makeComputePipelineState(function: f) }
}
