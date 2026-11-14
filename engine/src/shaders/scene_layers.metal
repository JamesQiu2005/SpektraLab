// scene_layers.metal -- RFC-052 §6, the 场景 stage: a local amount of Film
// Exposure (and of a filter on the light) before the film.
//
// One pointwise kernel, after Scene Latitude and before the Decode curve. Each
// layer is a mask in source space S (a 16-bit plane the host baked, §4.4), a
// coverage (on · opacity) and a gain g at full coverage, the natural log of a
// gain on the three cone responses (§6.1):
//
//     k_i(x) = coverage_i · m_i(x)
//     G(x)   = Σ k_i(x) · g_i
//     RGB'   = C⁻¹ · diag(exp G) · C · RGB          C = M_CAT16 · M_(working RGB → XYZ)
//
// and, with no colour delta in any layer (`meta[10]` = 0), the scalar form
// `RGB' = 2^(Σ k_i e_i) · RGB`, e_i = g_i / ln 2: the same operation as Film
// Exposure, so a full-mask layer of e stops is Film Exposure + e (§10.1)
// between two scalar gains and not across a matrix round trip.
//
// **Where a pixel is in S.** The image here is the frame after the engine's cut
// (`preprocess.geometry`), a band of it under RFC-020's strips. A pixel is
// mapped back through the cut by `spk_geometry_source_px` -- the function that
// cut the picture, not a copy of it -- into the handed frame, normalised with
// pixel centres at (i + 0.5) / N, and then into S by the host's
// `frame_to_source` (identity unless the host cut the frame itself, `HostCut`).
//
// **Sampling is manual bilinear from the buffer** (§4.4): texel centres at
// (i + 0.5) / N, clamped at the plane's edge, in float, written as
// `a + (b − a)·t` so a constant plane samples to itself exactly (an all-65535
// plane is 1.0 everywhere, and the full-mask identity is exact in its k).
// Outside S the mask is 0.
//
// A pixel no layer reaches (every k 0) is written back unchanged on both paths:
// `exp2(0) = 1` on the scalar one, and on the colour one the matrices are not
// run at all for it, so outside every mask the frame is the frame (§2.1).
//
// `meta`: 0 pixels in `in`, 1 its width, 2 its first row in the frame (a band),
//         3 SH, 4 SW (the frame the cut was made of), 5 OH, 6 OW (the cut
//         frame, whose band `in` is), 7 turns, 8 flips, 9 layer count (1…8),
//         10 colour (0 scalar, 1 the cone matrices).
// `p`:    0..8 frame_to_source (row-major, column vectors (x, y, 1)),
//         9..17 C, 18..26 C⁻¹ (both row-major: out[i] = Σ_j m[3i + j] x[j]),
//         27 + 8i: layer i's coverage, e_i (log2 gain, the scalar path),
//                  g_i (three, the colour path), plane width, plane height, 0.
#include "spk_common.h"

// The plane's value at S = (s, t), bilinear on texel centres, 0 outside S.
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

kernel void spk_scene_layers(device const float* img [[buffer(0)]],
                             device const float* g [[buffer(1)]],
                             device const uint* meta [[buffer(2)]],
                             device const float* p [[buffer(3)]],
                             device const ushort* m0 [[buffer(4)]],
                             device const ushort* m1 [[buffer(5)]],
                             device const ushort* m2 [[buffer(6)]],
                             device const ushort* m3 [[buffer(7)]],
                             device const ushort* m4 [[buffer(8)]],
                             device const ushort* m5 [[buffer(9)]],
                             device const ushort* m6 [[buffer(10)]],
                             device const ushort* m7 [[buffer(11)]],
                             device float* out [[buffer(12)]],
                             uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    const uint W = meta[1];
    const uint ox = i % W, oy = meta[2] + i / W;
    const float SH = (float)meta[3], SW = (float)meta[4];
    df fx, fy;
    spk_geometry_source_px(ox, oy, g, meta[5], meta[6], meta[7], meta[8], fx, fy);
    // The handed frame's normalised coordinates: pixel centre j at (j + 0.5) / N.
    const float u = ((fx.hi + 0.5f) + fx.lo) / SW;
    const float v = ((fy.hi + 0.5f) + fy.lo) / SH;
    float s = p[0] * u + p[1] * v + p[2];
    float t = p[3] * u + p[4] * v + p[5];
    const float w = p[6] * u + p[7] * v + p[8];
    if (w != 1.0f) { s /= w; t /= w; }

    const uint count = meta[9];
    const bool colour = meta[10] != 0u;
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
    const float r = img[3u * i], gg = img[3u * i + 1u], b = img[3u * i + 2u];
    if (!colour) {
        const float gain = exp2(E);
        out[3u * i] = r * gain;
        out[3u * i + 1u] = gg * gain;
        out[3u * i + 2u] = b * gain;
        return;
    }
    if (G.x == 0.0f && G.y == 0.0f && G.z == 0.0f) {
        out[3u * i] = r; out[3u * i + 1u] = gg; out[3u * i + 2u] = b;
        return;
    }
    const float3 e = exp(G);
    const float l0 = (p[9] * r + p[10] * gg + p[11] * b) * e.x;
    const float l1 = (p[12] * r + p[13] * gg + p[14] * b) * e.y;
    const float l2 = (p[15] * r + p[16] * gg + p[17] * b) * e.z;
    out[3u * i] = p[18] * l0 + p[19] * l1 + p[20] * l2;
    out[3u * i + 1u] = p[21] * l0 + p[22] * l1 + p[23] * l2;
    out[3u * i + 2u] = p[24] * l0 + p[25] * l1 + p[26] * l2;
}
