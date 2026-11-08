// contrast_mask.metal -- RFC-024's virtual contrast mask.
//
// Two kernels, and neither replaces an existing one. The unmasked print path
// still runs `spk_spectral_epilogue` unchanged; `spk_mask_epilogue` below is
// what `print_spectral` dispatches *instead* when the mask is on, and it is
// that kernel's integral with one change in the epilogue: the image exposure
// is multiplied by the mask's gain **before** the pre-flash offset is added.
//
//     today:   E = max(a * gain + flash, 0) + 1e-10
//     masked:  E = max(2^delta * (a * gain) + flash, 0) + 1e-10
//
// which is RFC-024 §4's `P * [2^delta * A + F]` with `P` left to the existing
// `spk_print_exposure` node. Deriving `A` here, rather than subtracting the
// flash back out of a logged total, is §7.2's contract.
//
// The mask's coordinate is RFC-024 §5's `x`: the equal-weight mean over the
// three paper channels of `log2(A_c / A_ref_c)`, where `A_ref` is the
// negative's own mid-grey through the same enlarger. `x = 0` is mid-grey.
//
// `p` is the one parameter block both kernels read:
//   0..2  the enlarger's setup gain (image exposure only)
//   3..5  1 / A_ref
//   6..8  the pre-flash offset (epilogue only)
//   9 k_lo  10 h_lo  11 lo_on    -- the print-highlight branch
//   12 k_hi 13 h_hi  14 hi_on    -- the print-shadow branch
//   15 the gain limit, stops
#include "spk_common.h"

// The floor under `log2`, relative to mid-grey: 2^-20 is ~6 densities below
// it, far under any paper's toe. It is a numerical guard, not a signal -- a
// pixel that lands on it gets a bounded gain from the curve like any other.
constant float kMaskLog2Floor = -20.0f;

inline float3 mask_image_exposure(device const float* cmy, uint i, device const float* chd,
                                  device const float* base, device const float* ixs, uint nl,
                                  device const float* p) {
    float c0 = cmy[3u * i], c1 = cmy[3u * i + 1u], c2 = cmy[3u * i + 2u];
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * chd[3u * l] + c1 * chd[3u * l + 1u] + c2 * chd[3u * l + 2u] + base[l];
        float t = exp2(-d * 3.321928094887362f);
        a0 += t * ixs[3u * l]; a1 += t * ixs[3u * l + 1u]; a2 += t * ixs[3u * l + 2u];
    }
    return float3(a0 * p[0], a1 * p[1], a2 * p[2]);
}

inline float mask_x(float3 a, device const float* p) {
    float s = 0.0f;
    for (uint c = 0u; c < 3u; ++c) {
        float r = max(a[c] * p[3u + c], 0.0f);
        s += max(log2(r), kMaskLog2Floor);   // log2(0) = -inf, then the floor
    }
    return s * (1.0f / 3.0f);
}

// RFC-023's m = 2 branch, `D * H / sqrt(H^2 + D^2)`: slope 1 at the knee,
// asymptote H.
inline float mask_g(float d, float h) { return d * h * rsqrt(h * h + d * d); }

// delta = f(b) - b, bounded. Exactly 0.0 inside the core and on a disabled
// branch, so the gain there is exp2(0) = 1.
inline float mask_delta(float b, device const float* p) {
    float delta = 0.0f;
    if (p[11] != 0.0f && b < p[9]) {
        float d = p[9] - b;
        delta = d - mask_g(d, p[10]);
    } else if (p[14] != 0.0f && b > p[12]) {
        float d = b - p[12];
        delta = mask_g(d, p[13]) - d;
    }
    // The same smooth-min bounds the gain itself (RFC-023 §15's fix for an
    // unbounded shadow gain): |delta| < limit for any base.
    float lim = p[15];
    return delta * lim * rsqrt(lim * lim + delta * delta);
}

// The analysis: one thread per grid cell, the mean of `x` over the cell's
// pixels. The cells partition the frame (`[cx*W/gw, (cx+1)*W/gw)`), so every
// pixel is counted exactly once whatever the tier's size.
kernel void spk_mask_reduce(device const float* cmy [[buffer(0)]],
                            device const float* chd [[buffer(1)]],
                            device const float* base [[buffer(2)]],
                            device const float* ixs [[buffer(3)]],
                            device const float* p [[buffer(4)]],
                            device const uint* meta [[buffer(5)]],
                            device float* out [[buffer(6)]],
                            uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint W = meta[0], H = meta[1], gw = meta[2], gh = meta[3], nl = meta[4];
    uint cell = thread_position_in_grid.x;
    if (cell >= gw * gh) return;
    uint cy = cell / gw, cx = cell % gw;
    uint x0 = (cx * W) / gw, x1 = max(((cx + 1u) * W) / gw, x0 + 1u);
    uint y0 = (cy * H) / gh, y1 = max(((cy + 1u) * H) / gh, y0 + 1u);
    x1 = min(x1, W); y1 = min(y1, H);
    float acc = 0.0f;
    for (uint y = y0; y < y1; ++y)
        for (uint x = x0; x < x1; ++x)
            acc += mask_x(mask_image_exposure(cmy, y * W + x, chd, base, ixs, nl, p), p);
    out[cell] = acc / float((x1 - x0) * (y1 - y0));
}

// The application, per pixel of a band. `row0` is the band's first row in
// the frame, so a strip reads the field at the frame's coordinates and a
// striped render samples exactly what the whole-frame one does.
//
// The base is `a * x + b` with `(a, b)` sampled bilinearly from the grid: the
// guided filter's coefficients when edge-aware (so the base follows this
// pixel's own `x` across an edge), `a = 0` and the Gaussian base otherwise.
kernel void spk_mask_epilogue(device const float* cmy [[buffer(0)]],
                              device const float* chd [[buffer(1)]],
                              device const float* base [[buffer(2)]],
                              device const float* ixs [[buffer(3)]],
                              device const float* p [[buffer(4)]],
                              device const float* coef [[buffer(5)]],
                              device const uint* meta [[buffer(6)]],
                              device float* out [[buffer(7)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint n = meta[0], nl = meta[1], W = meta[2], H = meta[3], row0 = meta[4];
    uint gw = meta[5], gh = meta[6];
    uint i = thread_position_in_grid.x;
    if (i >= n) return;
    float3 a = mask_image_exposure(cmy, i, chd, base, ixs, nl, p);

    uint px = i % W, py = row0 + i / W;
    float u = clamp(((float)px + 0.5f) * (float)gw / (float)W - 0.5f, 0.0f, (float)(gw - 1u));
    float v = clamp(((float)py + 0.5f) * (float)gh / (float)H - 0.5f, 0.0f, (float)(gh - 1u));
    uint u0 = (uint)floor(u), v0 = (uint)floor(v);
    uint u1 = min(u0 + 1u, gw - 1u), v1 = min(v0 + 1u, gh - 1u);
    float tu = u - (float)u0, tv = v - (float)v0;
    float2 c00 = float2(coef[2u * (v0 * gw + u0)], coef[2u * (v0 * gw + u0) + 1u]);
    float2 c01 = float2(coef[2u * (v0 * gw + u1)], coef[2u * (v0 * gw + u1) + 1u]);
    float2 c10 = float2(coef[2u * (v1 * gw + u0)], coef[2u * (v1 * gw + u0) + 1u]);
    float2 c11 = float2(coef[2u * (v1 * gw + u1)], coef[2u * (v1 * gw + u1) + 1u]);
    float2 ab = mix(mix(c00, c01, tu), mix(c10, c11, tu), tv);

    float b = ab.x * mask_x(a, p) + ab.y;
    float k = exp2(mask_delta(b, p));
    float v0e = max(k * a.x + p[6], 0.0f) + 1e-10f;
    float v1e = max(k * a.y + p[7], 0.0f) + 1e-10f;
    float v2e = max(k * a.z + p[8], 0.0f) + 1e-10f;
    out[3u * i] = log10(v0e); out[3u * i + 1u] = log10(v1e); out[3u * i + 2u] = log10(v2e);
}
