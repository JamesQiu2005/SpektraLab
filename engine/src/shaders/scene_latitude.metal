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
        if (p[1] > 0.0f && E > p[0]) d = slm_departure(E - p[0], p[1], p[4]);
        else if (p[3] > 0.0f && E < p[2]) d = -slm_departure(p[2] - E, p[3], p[4]);
        if (d > 0.0f) { float L = p[5]; d = d * L / sqrt(L * L + d * d); }
        k = clamp(exp2(d), exp2(-30.0f), exp2(30.0f));
    }
    out[3u * i] = r * k;
    out[3u * i + 1u] = g * k;
    out[3u * i + 2u] = b * k;
}
