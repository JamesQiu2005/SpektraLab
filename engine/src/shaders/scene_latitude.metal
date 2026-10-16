// scene_latitude.metal -- RFC-023's Scene Latitude Mapping.
//
// One pointwise kernel, before `filming.expose.upsample`: a positive scalar
// gain per pixel, computed on the stop axis and applied to the linear triple.
// The signal never becomes log (§5.6): `log2` and `exp2` only compute `k`.
//
//     n  = norm(max(RGB, 0))               power | Y | max  (§5.2, §15.5)
//     E  = clamp(log2(max(n, floor) / n_ref), -24, 24)
//     d  = f(E) - E                        0.0 exactly in the core
//     d  = d > 0 ? d L / sqrt(L^2 + d^2)   the bounded lift (§15.5)
//     RGB' = 2^d * RGB
//
// `core/latitude_fit.cpp::delta` is the double-precision reference of the
// same arithmetic, in the same order. The node is not dispatched at all when
// the feature is off (the bypass is structural); inside it, a pixel in the core
// takes `exp2(0.0f) = 1.0f` and is written back unchanged.
//
// §11's rule: this node never changes what the pipeline does with a
// pathological pixel -- a norm that is zero, negative, NaN or infinite takes
// k = 1 and passes through as it came. Negative components are not clamped in
// the signal; only the scalar sees `max(RGB, 0)` (§11.2).
//
// `p`:
//   0 K_h   1 H_h (0 = off)   2 K_s   3 H_s (0 = off)
//   4 m     5 L_max           6 norm (0 power, 1 Y, 2 max)
//   7..9 the Y row of the working space's RGB -> XYZ   10 n_ref
//   11 width  12 height  13 split (0 = none)  14..17 the second frame's K_h H_h K_s H_s
//   18 the image's first row in the frame (RFC-035 §9: a band; RFC-020: a strip; 0 for a whole render)
#include "spk_common.h"

// g_m(D) - D, the branch's departure, in the forms that do not cancel near the
// knee: exactly 0 at D = 0 through the multiply, negative beyond it.
inline float slm_departure(float D, float H, float m) {
    if (!(D > 0.0f)) return 0.0f;
    if (m == 2.0f) {
        float r = sqrt(H * H + D * D);
        return -(D * D * D) / (r * (H + r));
    }
    if (m == 1.0f) return -(D * D) / (H + D);
    return D * (H / pow(pow(H, m) + pow(D, m), 1.0f / m) - 1.0f);
}

kernel void spk_scene_latitude(device const float* rgb [[buffer(0)]],
                               device const float* p [[buffer(1)]],
                               device const uint* n [[buffer(2)]],
                               device float* out [[buffer(3)]],
                               uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float r = rgb[3u * i], g = rgb[3u * i + 1u], b = rgb[3u * i + 2u];
    float cr = max(r, 0.0f), cg = max(g, 0.0f), cb = max(b, 0.0f);

    float v;
    uint norm = uint(p[6]);
    if (norm == 1u) {
        v = p[7] * cr + p[8] * cg + p[9] * cb;
    } else if (norm == 2u) {
        v = max(cr, max(cg, cb));
    } else {
        float s2 = cr * cr + cg * cg + cb * cb;
        v = s2 > 0.0f ? (cr * cr * cr + cg * cg * cg + cb * cb * cb) / s2 : 0.0f;
    }

    float k = 1.0f;
    if (v > 0.0f && isfinite(v)) {
        float n_ref = p[10];
        float E = clamp(log2(max(v, n_ref * exp2(-24.0f)) / n_ref), -24.0f, 24.0f);
        float d = 0.0f;
        // A half-frame pair: from `split` along the long edge, the second
        // frame's own knees and rooms (p[14..17]).
        float Kh = p[0], Hh = p[1], Ks = p[2], Hs = p[3];
        if (p[13] > 0.0f) {
            uint w = uint(p[11]), h = uint(p[12]);
            float along = w >= h ? (float(i % w) + 0.5f) / float(w) : (float(i / w) + p[18] + 0.5f) / float(h);
            if (along >= p[13]) { Kh = p[14]; Hh = p[15]; Ks = p[16]; Hs = p[17]; }
        }
        if (Hh > 0.0f && E > Kh) d = slm_departure(E - Kh, Hh, p[4]);
        else if (Hs > 0.0f && E < Ks) d = -slm_departure(Ks - E, Hs, p[4]);
        if (d > 0.0f) { float L = p[5]; d = d * L / sqrt(L * L + d * d); }
        k = clamp(exp2(d), exp2(-30.0f), exp2(30.0f));
    }
    out[3u * i] = r * k;
    out[3u * i + 1u] = g * k;
    out[3u * i + 2u] = b * k;
}

// --- the scene tone: Highlights and Shadows before Scene Latitude ----------
//
// SceneToneParams. Two kernels and a host step between them
// (`scene_latitude.cpp::node_scene_tone`): the frame's mean stop-axis
// brightness per grid cell, a self-guided filter of that grid on the host, and
// the move per pixel against the base `a * x + b`:
//
//     x    = clamp(log2(Y / mid-grey), floor, -floor)    Y of max(RGB, 0)
//     base = a * x + b                                   (a, b) bilinear on the grid
//     d    = H * smoothstep(0, R, base) + S * smoothstep(0, R, -base)
//     RGB' = 2^d * RGB
//
// `p` (8 floats): 0..2 the working space's Y row  3 mid-grey  4 H, stops
//   5 S, stops  6 R, stops  7 the floor, stops (negative)
// The Vulkan transcription is spk_scene_tone{,_reduce}.comp; its explicit
// branches are where GLSL leaves NaN handling undefined and Metal does not.
inline float scene_tone_x(device const float* rgb, uint i, device const float* p) {
    float y = 0.0f;
    for (uint c = 0u; c < 3u; ++c) {
        float v = rgb[3u * i + c];
        if (v > 0.0f) y += p[c] * v;
    }
    float floor_stops = p[7];
    float x = floor_stops;
    if (y > 0.0f) {
        x = log2(y / p[3]);
        if (!(x > floor_stops)) x = floor_stops;
        if (x > -floor_stops) x = -floor_stops;
    }
    return x;
}

inline float scene_tone_ramp(float v, float width) {
    float t = clamp(v / width, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// One thread per grid cell: the mean of `x` over the cell's pixels. The cells
// partition the frame, as spk_mask_reduce's do.
kernel void spk_scene_tone_reduce(device const float* rgb [[buffer(0)]],
                                  device const float* p [[buffer(1)]],
                                  device const uint* meta [[buffer(2)]],
                                  device float* out [[buffer(3)]],
                                  uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint W = meta[0], H = meta[1], gw = meta[2], gh = meta[3];
    uint cell = thread_position_in_grid.x;
    if (cell >= gw * gh) return;
    uint cy = cell / gw, cx = cell % gw;
    uint x0 = (cx * W) / gw, x1 = max(((cx + 1u) * W) / gw, x0 + 1u);
    uint y0 = (cy * H) / gh, y1 = max(((cy + 1u) * H) / gh, y0 + 1u);
    x1 = min(x1, W); y1 = min(y1, H);
    float acc = 0.0f;
    for (uint y = y0; y < y1; ++y)
        for (uint x = x0; x < x1; ++x)
            acc += scene_tone_x(rgb, y * W + x, p);
    out[cell] = acc / float((x1 - x0) * (y1 - y0));
}

// Per pixel: the base from the grid's coefficients, then the gain. `meta`:
// 0 pixels  1 width  2 height  3 the image's first row in the frame  4 gw  5 gh
kernel void spk_scene_tone(device const float* rgb [[buffer(0)]],
                           device const float* p [[buffer(1)]],
                           device const float* coef [[buffer(2)]],
                           device const uint* meta [[buffer(3)]],
                           device float* out [[buffer(4)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint n = meta[0], W = meta[1], H = meta[2], row0 = meta[3], gw = meta[4], gh = meta[5];
    uint i = thread_position_in_grid.x;
    if (i >= n) return;
    uint px = i % W, py = row0 + i / W;
    float u = clamp((float(px) + 0.5f) * float(gw) / float(W) - 0.5f, 0.0f, float(gw - 1u));
    float v = clamp((float(py) + 0.5f) * float(gh) / float(H) - 0.5f, 0.0f, float(gh - 1u));
    uint u0 = uint(floor(u)), v0 = uint(floor(v));
    uint u1 = min(u0 + 1u, gw - 1u), v1 = min(v0 + 1u, gh - 1u);
    float tu = u - float(u0), tv = v - float(v0);
    float2 c00 = float2(coef[2u * (v0 * gw + u0)], coef[2u * (v0 * gw + u0) + 1u]);
    float2 c01 = float2(coef[2u * (v0 * gw + u1)], coef[2u * (v0 * gw + u1) + 1u]);
    float2 c10 = float2(coef[2u * (v1 * gw + u0)], coef[2u * (v1 * gw + u0) + 1u]);
    float2 c11 = float2(coef[2u * (v1 * gw + u1)], coef[2u * (v1 * gw + u1) + 1u]);
    float2 ab = mix(mix(c00, c01, tu), mix(c10, c11, tu), tv);
    float base = ab.x * scene_tone_x(rgb, i, p) + ab.y;
    float d = p[4] * scene_tone_ramp(base, p[6]) + p[5] * scene_tone_ramp(-base, p[6]);
    float k = exp2(d);
    for (uint c = 0u; c < 3u; ++c) out[3u * i + c] = rgb[3u * i + c] * k;
}
