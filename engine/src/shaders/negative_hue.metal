// negative_hue.metal -- the print's hue, taken from the negative (core/negative_hue.hpp).
//
// One pass over the scanned optical print. Lightness and chroma stay the print's
// own; the hue turns toward the negative's reading by a weight that is zero for a
// near-neutral and falls where a layer has left the straight part of its curve;
// chroma is then held inside the paper's own gamut. A pixel whose weight is zero
// is copied, so greys and everything the reading cannot vouch for are the optical
// print to the bit.
//
// The tables are `core/negative_hue.cpp`'s; the arithmetic is here and only here.
// `engine/tests/negative_hue_checks.py` holds it to its bars end to end, through the dylib.
#include "spk_common.h"

// One layer: density -> (log10 exposure, unreliability), by index into the even table
// (samples, 3, 2). `read_layer` in core/negative_hue.cpp.
inline float2 spk_read_layer(const device float* layers, uint N, uint c, float lo, float scale, float v) {
    float f = clamp((v - lo) * scale, 0.0f, float(N - 1u));
    uint j = min(uint(f), N - 2u);
    float t = f - float(j);
    uint a = (j * 3u + c) * 2u, b = a + 6u;
    return float2(layers[a] + t * (layers[b] - layers[a]), layers[a + 1u] + t * (layers[b + 1u] - layers[a + 1u]));
}

// MSL has no cbrt.
inline float spk_cbrt(float v) { return pow(max(v, 0.0f), 1.0f / 3.0f); }

inline float3 spk_oklab_from_xyz(float3 xyz) {
    float l = 0.8189330101f * xyz.x + 0.3618667424f * xyz.y - 0.1288597137f * xyz.z;
    float m = 0.0329845436f * xyz.x + 0.9293118715f * xyz.y + 0.0361456387f * xyz.z;
    float s = 0.0482003018f * xyz.x + 0.2643662691f * xyz.y + 0.6338517070f * xyz.z;
    l = spk_cbrt(l); m = spk_cbrt(m); s = spk_cbrt(s);
    return float3(0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
                  1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
                  0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s);
}

inline float3 spk_xyz_from_oklab(float3 lab) {
    float l = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3(1.2270138511f * l - 0.5577999807f * m + 0.2812561490f * s,
                  -0.0405801784f * l + 1.1122568696f * m - 0.0716766787f * s,
                  -0.0763812845f * l - 0.4214819784f * m + 1.5861632204f * s);
}

inline float3 spk_mul3(const device float* m, float3 v) {
    return float3(m[0] * v.x + m[1] * v.y + m[2] * v.z,
                  m[3] * v.x + m[4] * v.y + m[5] * v.z,
                  m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

// p: [0..2] 1 / a grey's layer exposures; [3] 1 / the map's lightness; [4..6] each layer's least
//    density; [7] the weight's floor; [9..17] scan XYZ -> D65; [18..26] D65 -> scan XYZ; [27..29] log10 exposure offsets
//    (the enlarger's filters, as the negative sees them); [30] chroma lo; [31] 1 / (chroma hi -
//    lo); [32] unreliability k; [33] gamut knee; [34] gamut L lo; [35] (levels - 1) / (L hi -
//    L lo); [36..38] each layer's index scale; [40] a film-edge canvas: [41] its width, [42] this
//    band's first row, [43] mm per pixel, [44..47] canvas mm -> film mm, [48..49] its offset in
//    film mm, [50..51] the canvas centre, [52..55] the gate (s0, t0, along, across), [56] a pair's advance
//
// One pixel: the negative's three layer densities and the optical print's scanned XYZ in, the
// print's XYZ out. Shared by the node and by the fused print below, so there is one arithmetic.
inline float3 spk_negative_hue_pixel(uint i, float3 negative, float3 optical,
                                     const device float* layers,
                                     const device float* p, const device float* gamut,
                                     const device float* map, uint N, uint nh, uint nl, uint S) {
    if (p[40] != 0.0f) {
        // A film-edge canvas: outside the picture's gate the print is the optical one.
        // `canvas_to_film` (overscan.metal), on the gate's rectangle.
        uint cw = uint(p[41]);
        float u = (float(i % cw) + 0.5f) * p[43] - p[50];
        float v = (float(i / cw) + p[42] + 0.5f) * p[43] - p[51];
        float s = p[44] * u + p[45] * v + p[48], t = p[46] * u + p[47] * v + p[49];
        bool inside = t >= p[53] && t <= p[53] + p[55] &&
                      ((s >= p[52] && s <= p[52] + p[54]) ||
                       (p[56] > 0.0f && s >= p[52] + p[56] && s <= p[52] + p[56] + p[54]));
        if (!inside) return optical;
    }
    float2 r0 = spk_read_layer(layers, N, 0u, p[4], p[36], negative.x);
    float2 r1 = spk_read_layer(layers, N, 1u, p[5], p[37], negative.y);
    float2 r2 = spk_read_layer(layers, N, 2u, p[6], p[38], negative.z);
    float3 e = float3(exp10(r0.x + p[27]) * p[0], exp10(r1.x + p[28]) * p[1], exp10(r2.x + p[29]) * p[2]);
    float esum = e.x + e.y + e.z;
    float3 x65 = spk_mul3(p + 9, optical);
    float3 lab_o = spk_oklab_from_xyz(x65);
    if (!(esum > 0.0f)) return optical;

    // The film's exposure map, inverted: (red share, green share) -> the colour's Oklab (a, b).
    float fx = clamp(e.x / esum, 0.0f, 1.0f) * float(S - 1u), fy = clamp(e.y / esum, 0.0f, 1.0f) * float(S - 1u);
    uint mx = min(uint(fx), S - 2u), my = min(uint(fy), S - 2u);
    float tx = fx - float(mx), ty = fy - float(my);
    uint m00 = (mx * S + my) * 2u, m10 = ((mx + 1u) * S + my) * 2u;
    float2 q00 = float2(map[m00], map[m00 + 1u]), q01 = float2(map[m00 + 2u], map[m00 + 3u]);
    float2 q10 = float2(map[m10], map[m10 + 1u]), q11 = float2(map[m10 + 2u], map[m10 + 3u]);
    float2 qa = q00 + (q01 - q00) * ty, qb = q10 + (q11 - q10) * ty;
    float2 lab_r = qa + (qb - qa) * tx;
    float c_o = length(lab_o.yz), c_r = length(lab_r);
    if (!(c_o > 1e-7f) || !(c_r > 1e-9f)) return optical;

    float c_at_print = c_r * lab_o.x * p[3];
    float t = clamp((c_at_print - p[30]) * p[31], 0.0f, 1.0f);
    float ubar = (e.x * r0.y + e.y * r1.y + e.z * r2.y) / esum;
    float ku = p[32] * ubar;
    float w = (t * t * (3.0f - 2.0f * t) / (1.0f + ku * ku) - p[7]) / (1.0f - p[7]);
    if (!(w > 0.0f)) return optical;

    // The turn toward the reading: a blend of the two directions, renormalised.
    float2 od = lab_o.yz / c_o;
    float2 vd = od + w * (lab_r / c_r - od);
    float vlen = length(vd);
    if (!(vlen > 1e-6f)) return optical;
    float a = c_o * vd.x / vlen, b = c_o * vd.y / vlen;

    // The paper's gamut at this lightness and hue, bilinear, hue wrapping.
    float fl = clamp((lab_o.x - p[34]) * p[35], 0.0f, float(nl - 1u));
    uint l0 = min(uint(fl), nl - 2u);
    float tl = fl - float(l0);
    float fh = atan2(b, a) * (float(nh) / 6.283185307179586f);
    fh -= floor(fh / float(nh)) * float(nh);
    uint h0 = uint(fh) % nh, h1 = (h0 + 1u) % nh;
    float th = fh - floor(fh);
    float g00 = gamut[l0 * nh + h0], g01 = gamut[l0 * nh + h1];
    float g10 = gamut[(l0 + 1u) * nh + h0], g11 = gamut[(l0 + 1u) * nh + h1];
    float ga = g00 + (g01 - g00) * th, gb = g10 + (g11 - g10) * th;
    float cmax = max(ga + (gb - ga) * tl, 1e-4f);
    float un = c_o / cmax, knee = p[33];
    if (un > knee) {
        float x = (un - knee) / (1.0f - knee);
        float kn = knee + (1.0f - knee) * x / sqrt(1.0f + x * x);
        float scale = 1.0f - w * (1.0f - kn / un);
        a *= scale; b *= scale;
    }
    return max(spk_mul3(p + 18, spk_xyz_from_oklab(float3(lab_o.x, a, b))), float3(1e-10f));
}

// meta: pixels, layer samples, hues, levels, map side
kernel void spk_negative_hue(device const float* cmy [[buffer(0)]],
                             device const float* xyz [[buffer(1)]],
                             device const float* layers [[buffer(2)]],
                             device const float* p [[buffer(3)]],
                             device const float* gamut [[buffer(4)]],
                             device const float* map [[buffer(5)]],
                             device const uint* meta [[buffer(6)]],
                             device float* out [[buffer(7)]],
                             uint3 pos [[thread_position_in_grid]]) {
    uint i = pos.x, n = meta[0];
    if (i >= n) return;
    float3 o = spk_negative_hue_pixel(i, float3(cmy[3u * i], cmy[3u * i + 1u], cmy[3u * i + 2u]),
                                      float3(xyz[3u * i], xyz[3u * i + 1u], xyz[3u * i + 2u]),
                                      layers, p, gamut, map, meta[1], meta[2], meta[3], meta[4]);
    out[3u * i] = o.x; out[3u * i + 1u] = o.y; out[3u * i + 2u] = o.z;
}

// The optical print in one pass: the enlarger's integral, the print exposure, the paper's curves
// and the scan -- `spk_spectral_epilogue` (log), `spk_print_exposure`, `spk_curves`,
// `spk_spectral_epilogue` (linear) with every expression as those kernels have it, so the four
// planes between them stay in registers and the result is theirs to the bit -- then the hue, when
// `meta[5]` says so. Measured at 45 MP: 68 ms as five passes, 2026-11-11.
//
// e: [0..2] enlarger gain, [3..5] its offset, [6..8] the print exposure's gain
// meta: pixels, the enlarger's wavelengths, paper curve K, layer samples, hue on, hues, levels,
//       map side, the scan's wavelengths (each integral's own live rows: `Pipeline::spectral_rows`)
kernel void spk_print_fused(device const float* cmy [[buffer(0)]],
                            device const float* pchd [[buffer(1)]],
                            device const float* pbase [[buffer(2)]],
                            device const float* pixs [[buffer(3)]],
                            device const float* e [[buffer(4)]],
                            device const float* cxa [[buffer(5)]],
                            device const float* cinv [[buffer(6)]],
                            device const float* cy [[buffer(7)]],
                            device const float* schd [[buffer(8)]],
                            device const float* sbase [[buffer(9)]],
                            device const float* sixs [[buffer(10)]],
                            device const float* layers [[buffer(11)]],
                            device const float* p [[buffer(12)]],
                            device const float* gamut [[buffer(13)]],
                            device const float* map [[buffer(14)]],
                            device const uint* meta [[buffer(15)]],
                            device float* out [[buffer(16)]],
                            uint3 pos [[thread_position_in_grid]]) {
    uint i = pos.x, n = meta[0], nl = meta[1], CK = meta[2], sl = meta[8];
    if (i >= n) return;
    float c0 = cmy[3u * i], c1 = cmy[3u * i + 1u], c2 = cmy[3u * i + 2u];
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * pchd[3u * l] + c1 * pchd[3u * l + 1u] + c2 * pchd[3u * l + 2u] + pbase[l];
        float t = exp2(-d * 3.321928094887362f);
        a0 += t * pixs[3u * l]; a1 += t * pixs[3u * l + 1u]; a2 += t * pixs[3u * l + 2u];
    }
    float v0 = log10(max(a0 * e[0] + e[3], 0.0f) + 1e-10f);
    float v1 = log10(max(a1 * e[1] + e[4], 0.0f) + 1e-10f);
    float v2 = log10(max(a2 * e[2] + e[5], 0.0f) + 1e-10f);
    // print exposure
    v0 = log10(max(exp2(v0 * 3.321928094887362f) * e[6], 0.0f) + 1e-10f);
    v1 = log10(max(exp2(v1 * 3.321928094887362f) * e[7], 0.0f) + 1e-10f);
    v2 = log10(max(exp2(v2 * 3.321928094887362f) * e[8], 0.0f) + 1e-10f);
    // the paper's curves
    float q0 = interp_channel(cxa, cinv, cy, CK, 0u, v0);
    float q1 = interp_channel(cxa, cinv, cy, CK, 1u, v1);
    float q2 = interp_channel(cxa, cinv, cy, CK, 2u, v2);
    // the scan
    float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f;
    for (uint l = 0u; l < sl; ++l) {
        float d = q0 * schd[3u * l] + q1 * schd[3u * l + 1u] + q2 * schd[3u * l + 2u] + sbase[l];
        float t = exp2(-d * 3.321928094887362f);
        s0 += t * sixs[3u * l]; s1 += t * sixs[3u * l + 1u]; s2 += t * sixs[3u * l + 2u];
    }
    float3 o = float3(max(s0 * 1.0f + 0.0f, 0.0f) + 1e-10f, max(s1 * 1.0f + 0.0f, 0.0f) + 1e-10f,
                      max(s2 * 1.0f + 0.0f, 0.0f) + 1e-10f);
    if (meta[4] != 0u)
        o = spk_negative_hue_pixel(i, float3(c0, c1, c2), o, layers, p, gamut, map,
                                   meta[3], meta[5], meta[6], meta[7]);
    out[3u * i] = o.x; out[3u * i + 1u] = o.y; out[3u * i + 2u] = o.z;
}
