// lens.metal -- the lens (API-SPEC §21.5-§21.6), a pass on the source before the film:
// the diffusion filter's pyramid and core (and the exact path's coarse grid and
// mix, the tests' reference), the glow, and the lens aberrations' kernels. The
// host half is `pipeline/lens.cpp`, which says what each pass is for.
//
// **Positions are the frame's, never the chunk's.** Every aberration kernel
// takes `row0`, the frame row of the image's row 0 (a chunk's first row, or
// 0), and does all of its position arithmetic in frame coordinates: only
// integer indices have `row0` subtracted. So a pixel's taps, weights and grid
// phases are the same float operations on the same values whether it is
// rendered whole or in a chunk, and a chunk's interior is the whole frame's.
//
// **Grids are anchored on the plane.** A coarse grid of factor f has its row I
// centred on plane row f I + (f - 1) / 2 whatever band it is built for; a band
// stores rows [I0, I0 + LH) of it and clamps there (in the band's halo, which
// is what the halo is for). Indices past the plane are clamped -- sample
// replication, the edge rule of the IIR the grids' blurs run through.
#include <metal_stdlib>
using namespace metal;

// --- shared helpers ----------------------------------------------------------

inline float3 ld3(device const float* img, uint s) {
    return float3(img[3u * s], img[3u * s + 1u], img[3u * s + 2u]);
}

// Bilinear on a plane-anchored grid of factor f (f = 1: the image itself, its
// samples on the pixel centres). (x, Y): the plane position in full-resolution
// pixel units, pixel centres on the integers. Rows stored: [I0, I0 + LH).
inline float3 grid_up(device const float* low, int LH, int LW, int I0, uint f, float x, float Y) {
    float ff = float(f), c = 0.5f * float(f - 1u);
    float u = (x - c) / ff, v = (Y - c) / ff;
    float uf = floor(u), vf = floor(v);
    float fx = u - uf, fy = v - vf;
    int j0 = clamp(int(uf), 0, LW - 1), j1 = clamp(int(uf) + 1, 0, LW - 1);
    int i0 = clamp(int(vf) - I0, 0, LH - 1), i1 = clamp(int(vf) + 1 - I0, 0, LH - 1);
    float3 v00 = ld3(low, uint(i0) * uint(LW) + uint(j0)), v01 = ld3(low, uint(i0) * uint(LW) + uint(j1));
    float3 v10 = ld3(low, uint(i1) * uint(LW) + uint(j0)), v11 = ld3(low, uint(i1) * uint(LW) + uint(j1));
    return (1.0f - fy) * ((1.0f - fx) * v00 + fx * v01) + fy * ((1.0f - fx) * v10 + fx * v11);
}

// --- the diffusion filter (and the spherical glow) ---------------------------

// Down: a tent splat, with the grid anchored on the plane. Writes coarse
// rows [I0, I0 + nI) to out rows [I0 - outI0, ...). Plane rows are clamped
// to the plane [0, PH), then to the image's own rows: a band's image ends
// inside the plane, and a row past it is one only the band's halo reads.
// meta: {H, W, row0, PH, LW, I0, nI, f, outI0}
kernel void spk_lens_splat(device const float* img [[buffer(0)]],
                           device const uint* meta [[buffer(1)]],
                           device float* out [[buffer(2)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1], row0 = meta[2], PH = meta[3], LW = meta[4];
    uint I0 = meta[5], nI = meta[6], f = meta[7], outI0 = meta[8];
    if (i >= nI * LW) return;
    uint I = I0 + i / LW, J = i % LW;
    float ff = float(f), c = 0.5f * float(f - 1u);
    float cy = float(f * I) + c, cx = float(f * J) + c;
    int y0 = int(floor(cy - ff)) + 1, y1 = int(ceil(cy + ff)) - 1;
    int x0 = int(floor(cx - ff)) + 1, x1 = int(ceil(cx + ff)) - 1;
    float3 acc = float3(0.0f);
    for (int y = y0; y <= y1; ++y) {
        float wy = max(0.0f, 1.0f - fabs(float(y) - cy) / ff);
        int yp = clamp(y, 0, int(PH) - 1);
        uint yy = uint(clamp(yp - int(row0), 0, int(H) - 1));
        float3 row = float3(0.0f);
        for (int x = x0; x <= x1; ++x) {
            float wx = max(0.0f, 1.0f - fabs(float(x) - cx) / ff);
            uint xx = uint(clamp(x, 0, int(W) - 1));
            row += wx * ld3(img, yy * W + xx);
        }
        acc += wy * row;
    }
    acc /= ff * ff;
    uint o = (I - outI0) * LW + J;
    out[3u * o] = acc.x; out[3u * o + 1u] = acc.y; out[3u * o + 2u] = acc.z;
}

// out = a * raw + b * (fine + up(grid A) + up(grid B)), per channel. Grid A is
// the band's own coarse grid, grid B the frame's (the diffusion filter's broad
// components, one field for every band). A factor of 0 leaves a grid out.
// meta: {H, W, row0, has_fine, fa, I0a, LHa, LWa, fb, I0b, LHb, LWb}; ab: a[3], b[3].
kernel void spk_lens_mix(device const float* raw [[buffer(0)]],
                         device const float* fine [[buffer(1)]],
                         device const float* ga [[buffer(2)]],
                         device const float* gb [[buffer(3)]],
                         device const float* ab [[buffer(4)]],
                         device const uint* meta [[buffer(5)]],
                         device float* out [[buffer(6)]],
                         uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1], row0 = meta[2], has_fine = meta[3];
    if (i >= H * W) return;
    uint y = i / W, x = i % W;
    float X = float(x), Y = float(y + row0);
    float3 m = float3(0.0f);
    if (has_fine != 0u) m += ld3(fine, i);
    if (meta[4] != 0u) m += grid_up(ga, int(meta[6]), int(meta[7]), int(meta[5]), meta[4], X, Y);
    if (meta[8] != 0u) m += grid_up(gb, int(meta[10]), int(meta[11]), int(meta[9]), meta[8], X, Y);
    float3 r = ld3(raw, i);
    float3 o = float3(ab[0], ab[1], ab[2]) * r + float3(ab[3], ab[4], ab[5]) * m;
    out[3u * i] = o.x; out[3u * i + 1u] = o.y; out[3u * i + 2u] = o.z;
}

// --- lateral chromatic aberration ---------------------------------------------

// One channel at plane position (qx, qY), bilinear. Not bicubic, measured: a
// Catmull-Rom's negative lobes undershoot a highlight's edge below zero (the
// film's log then reads black), and clamping them to the neighbours' range
// gave a point 13 % more energy. Bilinear is positive and a partition of
// unity; what it costs is up to a quarter px^2 of blur on R and B.
inline float bl_sample(device const float* img, uint H, uint W, uint row0, uint c, float qx, float qY) {
    float xf = floor(qx), yf = floor(qY);
    float fx = qx - xf, fy = qY - yf;
    int x0 = clamp(int(xf), 0, int(W) - 1), x1 = clamp(int(xf) + 1, 0, int(W) - 1);
    int y0 = clamp(int(yf) - int(row0), 0, int(H) - 1), y1 = clamp(int(yf) + 1 - int(row0), 0, int(H) - 1);
    float v00 = img[3u * (uint(y0) * W + uint(x0)) + c], v01 = img[3u * (uint(y0) * W + uint(x1)) + c];
    float v10 = img[3u * (uint(y1) * W + uint(x0)) + c], v11 = img[3u * (uint(y1) * W + uint(x1)) + c];
    return (1.0f - fy) * ((1.0f - fx) * v00 + fx * v01) + fy * ((1.0f - fx) * v10 + fx * v11);
}

// The R and B images magnified against G by k(h) = 1 + a h (lensfun's poly3
// with only its linear term, run in reverse to add the aberration): the output
// at radius r_d reads the input at r_u, r_d = r_u (1 + a r_u / hd), and is
// scaled by the map's Jacobian so a point keeps its energy.
// p: {pcx, pcy, inv_hd, a_r, a_b}; meta: {H, W, row0}
kernel void spk_lens_tca(device const float* img [[buffer(0)]],
                         device const float* p [[buffer(1)]],
                         device const uint* meta [[buffer(2)]],
                         device float* out [[buffer(3)]],
                         uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1], row0 = meta[2];
    if (i >= H * W) return;
    uint y = i / W, x = i % W;
    float X = float(x), Y = float(y + row0);
    float dx = X - p[0], dy = Y - p[1];
    float rd = sqrt(dx * dx + dy * dy);
    float hd = rd * p[2];
    out[3u * i + 1u] = img[3u * i + 1u];
    for (uint k = 0u; k < 2u; ++k) {
        uint c = k == 0u ? 0u : 2u;
        float a = p[3u + k];
        if (a == 0.0f || rd <= 0.0f) { out[3u * i + c] = img[3u * i + c]; continue; }
        float ru = 2.0f * rd / (1.0f + sqrt(max(1.0f + 4.0f * a * hd, 1e-6f)));
        float s = ru / rd, hu = ru * p[2];
        float jac = 1.0f / ((1.0f + 2.0f * a * hu) * (1.0f + a * hu));
        out[3u * i + c] = jac * bl_sample(img, H, W, row0, c, p[0] + dx * s, p[1] + dy * s);
    }
}

// --- longitudinal CA, the depth-free stand-in -----------------------------------

// The share of a pixel's light the soft channels scatter: m = (1 - gate) +
// gate * highlight(Y), on the sharp luminance. The scattered light M = m A is
// taken out where it is and put back blurred, out = A - M + G * M, so the soft
// channels keep their energy exactly and go soft only where the light is
// bright -- which shows only at its edges (a flat field blurred is itself).
// Measured before this (the blurred image mixed in by a gate): a point light's
// R and B left its core and were not put down around it -- green points.
inline float loca_share(float3 v, device const float* p) {
    float y = 0.25f * v.x + 0.5f * v.y + 0.25f * v.z;
    return (1.0f - p[3]) + p[3] * smoothstep(p[4], 4.0f * p[4], y);
}

// M = soft * m * A. p: {soft_r, soft_g, soft_b, gate, mid}; meta: {n}
kernel void spk_lens_loca_share(device const float* a [[buffer(0)]],
                                device const float* p [[buffer(1)]],
                                device const uint* meta [[buffer(2)]],
                                device float* out [[buffer(3)]],
                                uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    float3 va = ld3(a, i);
    float3 o = float3(p[0], p[1], p[2]) * loca_share(va, p) * va;
    out[3u * i] = o.x; out[3u * i + 1u] = o.y; out[3u * i + 2u] = o.z;
}

// out = A - M + B, B = G * M, M recomputed from A. Same p and meta.
kernel void spk_lens_loca_mix(device const float* a [[buffer(0)]],
                              device const float* b [[buffer(1)]],
                              device const float* p [[buffer(2)]],
                              device const uint* meta [[buffer(3)]],
                              device float* out [[buffer(4)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    float3 va = ld3(a, i), vb = ld3(b, i);
    float3 m = float3(p[0], p[1], p[2]) * loca_share(va, p) * va;
    float3 o = va - m + vb;
    out[3u * i] = o.x; out[3u * i + 1u] = o.y; out[3u * i + 2u] = o.z;
}

// --- the field gather: curvature, astigmatism, coma ------------------------------

// One mip level from the one below, plane-anchored: texel i of level l is
// centred on plane pixel (i + 0.5) 2^l - 0.5, and made from level l - 1's
// texels 2i - 1 .. 2i + 2 with the tent [1 3 3 1] / 8 per axis.
//
// **A tent, not a 2 x 2 box, and measured.** A box puts a point's whole weight
// in the texel it falls in, so read back bilinearly it sits on that texel's
// centre -- up to (2^l - 1) / 2 px from where it was. Where a pass blends two
// levels with a fraction that varies across the field, the two copies' means
// differ and the point's energy moved with them: +-1.0e-3 by the column's
// parity at 12 um/px (`lens_checks.py`). The tent keeps every point's mean
// exactly (pixel 2k: 3/8 to texel k, 1/8 to k - 1; 2k + 1: 3/8 to k, 1/8 to
// k + 1), and bilinear interpolation keeps it on the way back.
// meta: {Hin, Win, I0in, Hout, Wout, I0out}
kernel void spk_lens_down2(device const float* img [[buffer(0)]],
                           device const uint* meta [[buffer(1)]],
                           device float* out [[buffer(2)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint Hin = meta[0], Win = meta[1], I0in = meta[2], Hout = meta[3], Wout = meta[4], I0out = meta[5];
    if (i >= Hout * Wout) return;
    uint r = i / Wout, j = i % Wout;
    const float c[4] = {0.125f, 0.375f, 0.375f, 0.125f};
    int fy = 2 * int(I0out + r) - 1 - int(I0in), fx = 2 * int(j) - 1;
    float3 s = float3(0.0f);
    for (int a = 0; a < 4; ++a) {
        uint yy = uint(clamp(fy + a, 0, int(Hin) - 1));
        float3 row = float3(0.0f);
        for (int b = 0; b < 4; ++b) {
            uint xx = uint(clamp(fx + b, 0, int(Win) - 1));
            row += c[b] * ld3(img, yy * Win + xx);
        }
        s += c[a] * row;
    }
    out[3u * i] = s.x; out[3u * i + 1u] = s.y; out[3u * i + 2u] = s.z;
}

struct Level { int I0, LH, LW; };

inline float3 level_sample(device const float* L, Level lv, float T, float X, float Y) {
    // texel centres of level l on plane pixel (i + 0.5) T - 0.5
    float u = (X + 0.5f) / T - 0.5f, v = (Y + 0.5f) / T - 0.5f;
    float uf = floor(u), vf = floor(v);
    float fx = u - uf, fy = v - vf;
    int j0 = clamp(int(uf), 0, lv.LW - 1), j1 = clamp(int(uf) + 1, 0, lv.LW - 1);
    int i0 = clamp(int(vf) - lv.I0, 0, lv.LH - 1), i1 = clamp(int(vf) + 1 - lv.I0, 0, lv.LH - 1);
    float3 v00 = ld3(L, uint(i0) * uint(lv.LW) + uint(j0)), v01 = ld3(L, uint(i0) * uint(lv.LW) + uint(j1));
    float3 v10 = ld3(L, uint(i1) * uint(lv.LW) + uint(j0)), v11 = ld3(L, uint(i1) * uint(lv.LW) + uint(j1));
    return (1.0f - fy) * ((1.0f - fx) * v00 + fx * v01) + fy * ((1.0f - fx) * v10 + fx * v11);
}

// The standard normal CDF (Abramowitz & Stegun 7.1.26 for erf, |error| < 1.5e-7).
inline float norm_cdf(float z) {
    float x = fabs(z) * 0.70710678118654752f;
    float t = 1.0f / (1.0f + 0.3275911f * x);
    float y = 1.0f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t +
                      0.254829592f) * t * exp(-x * x);
    return z >= 0.0f ? 0.5f * (1.0f + y) : 0.5f * (1.0f - y);
}
inline float norm_pdf(float z) { return exp(-0.5f * z * z); }   // unnormalised: a common factor

// The lens's field functions at height h, shared by both passes so each knows
// what the other does. lp: {pcx, pcy, inv_hd, h0, p, sfc, sast, coma}.
struct Field { float var_t, var_r, L; };
inline float knee(float h, float h0) {
    return h0 > 0.0f ? smoothstep(h0, min(h0 + 0.1f, 1.0f), h) : 1.0f;
}
inline float g_field(float h, float h0, float p) {
    float u = h0 > 0.0f ? max(h - h0, 0.0f) / (1.0f - h0) : h;
    return knee(h, h0) * pow(max(u, 0.0f), p);
}
inline float g_coma(float h, float h0) {
    float u = h0 > 0.0f ? max(h - h0, 0.0f) / (1.0f - h0) : h;
    return knee(h, h0) * u;
}
inline Field field_at(device const float* lp, float h) {
    float g = g_field(h, lp[3], lp[4]);
    float sfc = lp[5] * g, sa = fabs(lp[6]) * g;
    Field F;
    F.L = lp[7] * g_coma(h, lp[3]);
    // the comet's tangential spread: a 60-degree wedge, s | t uniform on
    // +-t tan 30 deg, so E[s^2] = E[t^2] / 9 = L^2 / 54 for the triangle below
    F.var_t = sfc * sfc + (lp[6] > 0.0f ? sa * sa : 0.0f) + F.L * F.L / 54.0f;
    F.var_r = sfc * sfc + (lp[6] < 0.0f ? sa * sa : 0.0f);
    return F;
}

constexpr constant float kMinSigma = 0.4f;   // kMinEffectiveBlurSigma
constexpr constant int kMaxTaps = 160;
constexpr constant float kMinComet = 0.05f;   // px: a comet shorter moves nothing a code sees
constexpr constant float kTruncate = 3.5f;   // the Gaussian's support, sigmas (lens.cpp kLineTruncate)

// The level a pass reads, as a continuous log2: spacing T = 2^l <= sigma / 4.
// What a level adds, per axis: along the pass, the tent pyramid and the
// bilinear tent; across it, those and the tap pair at +-T/2 (below).
struct Lod { int l0; float frac; float va, vp, q, rho; bool active; };
inline float level_variance(int l) {
    float T = float(1 << l);
    return (T * T - 1.0f) / 4.0f + T * T / 6.0f;   // the tents down (sum of 0.75 (2^m)^2), the bilinear back
}
// `force`: a comet too short to reach kMinSigma still moves its light (its
// centroid's L / 3), so the radial pass runs wherever there is one. `q` scales
// the tap pair's offset: a pass this narrow needs no pair, and a pair would
// add its T^2 / 4 to a pixel that is barely blurred.
inline Lod lod_for(float sigma, int lmax, bool force) {
    Lod d;
    d.active = sigma >= kMinSigma || force;
    d.q = clamp((sigma - kMinSigma) / (2.0f - kMinSigma), 0.0f, 1.0f);
    // How much of the pass's kernel is used: it is mixed with the identity by
    // rho, 0 where the pass starts and 1 from four times that sigma, so the field
    // has no step where it starts -- a step there is a gather whose kernel
    // jumps, and a point at the boundary lost or gained 1-4 % of its light.
    d.rho = force ? 1.0f : smoothstep(kMinSigma, 4.0f * kMinSigma, sigma);
    if (!d.active) { d.l0 = 0; d.frac = 0.0f; d.va = 0.0f; d.vp = 0.0f; d.rho = 0.0f; return d; }
    float lam = log2(sigma / 4.0f);
    if (lam <= 0.0f) { d.l0 = 0; d.frac = 0.0f; }
    else if (lam >= float(lmax)) { d.l0 = lmax; d.frac = 0.0f; }
    else { d.l0 = int(floor(lam)); d.frac = lam - float(d.l0); }
    float T0 = float(1 << d.l0), T1 = 2.0f * T0;
    d.va = (1.0f - d.frac) * level_variance(d.l0) +
           (d.frac > 0.0f ? d.frac * level_variance(d.l0 + 1) : 0.0f);
    d.vp = d.va + 0.25f * d.q * d.q * ((1.0f - d.frac) * T0 * T0 + d.frac * T1 * T1);
    return d;
}

// The radial pass's 1-D kernel at offset s: a Gaussian sigma convolved with the
// comet's triangle rho(t) ~ (1 - t / L) on [0, L] (L > 0 here; the caller
// mirrors s for an inward comet). Unnormalised: the caller divides by the sum.
inline float comet_weight(float s, float sigma, float L) {
    if (L < 1e-3f) return sigma > 1e-3f ? norm_pdf(s / sigma) : (fabs(s) < 0.5f ? 1.0f : 0.0f);
    if (sigma < 1e-3f) return (s >= 0.0f && s <= L) ? (1.0f - s / L) : 0.0f;
    float b = s / sigma, a = (s - L) / sigma;
    float dP = norm_cdf(b) - norm_cdf(a);
    float dp = (norm_pdf(b) - norm_pdf(a)) * 0.39894228040143268f;
    return max(dP - (s * dP + sigma * dp) / L, 0.0f);
}

// The comet's mass up to s: F(s) = integral of rho(t) Phi((s - t) / sigma) dt,
// rho(t) = 1 - t / L on [0, L]. With z = (s - t) / sigma on [a, b] = [(s - L) /
// sigma, s / sigma]: F = sigma ((1 - s / L) I0 + (sigma / L) I1), I0 the
// integral of Phi (z Phi + phi), I1 of z Phi (((z^2 - 1) Phi + z phi) / 2).
inline float comet_cdf(float s, float sigma, float L) {
    float a = (s - L) / sigma, b = s / sigma;
    float Pa = norm_cdf(a), Pb = norm_cdf(b);
    float pa = norm_pdf(a) * 0.39894228040143268f, pb = norm_pdf(b) * 0.39894228040143268f;
    float I0 = (b * Pb + pb) - (a * Pa + pa);
    float I1 = 0.5f * (((b * b - 1.0f) * Pb + b * pb) - ((a * a - 1.0f) * Pa + a * pa));
    return sigma * ((1.0f - s / L) * I0 + (sigma / L) * I1);
}
// A tap's share of the comet: its mass over the tap's own cell [s - T/2,
// s + T/2], not its density at s. Sampled at its density, a short comet's
// head (the triangle's top) counts whole and its mean comes out ~T/3 short --
// measured, a constant 0.4 px inward shift at 12 um/px.
inline float comet_cell(float s, float sigma, float L, float T) {
    sigma = max(sigma, 0.02f * T);
    return max(comet_cdf(s + 0.5f * T, sigma, L) - comet_cdf(s - 0.5f * T, sigma, L), 0.0f);
}

// One directional pass: along e_t (mode 0: curvature + tangential astigmatism
// + the comet's spread) or along e_r (mode 1: curvature + radial astigmatism +
// the comet). out(p) = sum_s w(s) in(p - s e) / sum_s w(s), on the mip level
// whose texel is <= sigma / 4, blended with the next coarser one by the
// fraction (trilinear), each level's own variance taken out of the Gaussian so
// the second moments are the formula's. Mode 1 also scales by the comet's
// Jacobian, so a point keeps its energy where the shift varies over the field.
// levels 0..4 at buffers 0..4; lv: {I0, LH, LW} x 5; lp as `field_at`;
// meta: {H, W, row0, mode, lmax}
kernel void spk_lens_line(device const float* L0 [[buffer(0)]],
                          device const float* L1 [[buffer(1)]],
                          device const float* L2 [[buffer(2)]],
                          device const float* L3 [[buffer(3)]],
                          device const float* L4 [[buffer(4)]],
                          device const int* lv [[buffer(5)]],
                          device const float* lp [[buffer(6)]],
                          device const uint* meta [[buffer(7)]],
                          device float* out [[buffer(8)]],
                          uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1], row0 = meta[2], mode = meta[3];
    int lmax = int(meta[4]);
    if (i >= H * W) return;
    uint y = i / W, x = i % W;
    float X = float(x), Y = float(y + row0);
    float dx = X - lp[0], dy = Y - lp[1];
    float r = sqrt(dx * dx + dy * dy);
    float h = r * lp[2];
    Field F = field_at(lp, h);
    float La = fabs(F.L);
    Lod lt = lod_for(sqrt(F.var_t), lmax, false);
    Lod lr = lod_for(sqrt(F.var_r + La * La / 18.0f), lmax, La >= kMinComet);
    Lod me = mode == 0u ? lt : lr;
    float3 here = ld3(L0, i);
    // The comet's Jacobian: m(p) = p - D(r) e_r with D the kernel's mean,
    // L / 3, so |det Dm| = (1 - D'(r)) (1 - D(r) / r). Applied wherever there
    // is a comet at all, also where it is too short to gather, so the field
    // has no step where the gather starts.
    float jac = 1.0f;
    if (mode == 1u && lp[7] != 0.0f && r > 1.0f) {
        float Dm = field_at(lp, (r - 0.5f) * lp[2]).L / 3.0f;
        float Dp = field_at(lp, (r + 0.5f) * lp[2]).L / 3.0f;
        jac = (1.0f - (Dp - Dm)) * (1.0f - (F.L / 3.0f) / r);
    }
    if (!me.active || me.rho <= 0.0f) {
        here *= jac; out[3u * i] = here.x; out[3u * i + 1u] = here.y; out[3u * i + 2u] = here.z; return;
    }
    // Each pass's level blurs both axes, so the other pass's is taken out here
    // too (by the share of it that is used); and this pass's kernel is used at
    // rho, so it carries the variance over rho.
    float var = mode == 0u ? F.var_t - lr.rho * lr.vp : F.var_r - lt.rho * lt.vp;
    float sigma = sqrt(max(var / me.rho - me.va, 0.0f));
    float2 er = r > 1e-6f ? float2(dx, dy) / r : float2(1.0f, 0.0f);
    float2 e = mode == 0u ? float2(-er.y, er.x) : er;
    float2 n = float2(-e.y, e.x);
    float Ls = mode == 1u ? F.L : 0.0f;          // signed: > 0 the comet points outward
    float Lp = fabs(Ls), sgn = Ls < 0.0f ? -1.0f : 1.0f;
    float3 acc2 = float3(0.0f);
    for (int k = 0; k < 2; ++k) {
        int l = me.l0 + k;
        float wl = k == 0 ? 1.0f - me.frac : me.frac;
        if (wl <= 0.0f) continue;
        float T = float(1 << l);
        Level L = {lv[3 * l], lv[3 * l + 1], lv[3 * l + 2]};
        device const float* img = l == 0 ? L0 : l == 1 ? L1 : l == 2 ? L2 : l == 3 ? L3 : L4;
        // taps on multiples of the spacing, so a symmetric kernel has one at 0
        float smin = -kTruncate * sigma - (sgn < 0.0f ? Lp : 0.0f);
        float smax = kTruncate * sigma + (sgn > 0.0f ? Lp : 0.0f);
        // a comet's taps no coarser than a sixth of it (bilinear between
        // pixels at level 0), so a short one's mean is not the grid's
        float step = Lp > 0.0f ? min(T, max(Lp / 6.0f, 0.125f)) : T;
        int k0 = int(floor(smin / step)), k1 = int(ceil(smax / step));
        if (k1 - k0 + 1 > kMaxTaps) {
            step = (smax - smin) / float(kMaxTaps - 1);
            k0 = int(floor(smin / step)); k1 = int(ceil(smax / step));
        }
        float3 acc = float3(0.0f);
        float wsum = 0.0f;
        float sigc = sqrt(max(sigma * sigma - step * step / 12.0f, 0.0f));
        for (int t = k0; t <= k1; ++t) {
            float s = float(t) * step;
            // a comet's taps carry their cells' mass; their spread over the
            // cell (T^2 / 12, Sheppard) is taken out of the Gaussian below
            float w = Lp > 0.0f ? comet_cell(sgn * s, sigc, Lp, step) : comet_weight(s, sigma, 0.0f);
            if (w <= 0.0f) continue;
            // Each tap is a pair across the line, +-T/2: a single bilinear tap
            // on the line blurs across it by 0 to T^2/4 with the pixel's
            // phase, which left a one-pixel spike on a point light wherever
            // the line ran through a pixel centre (a diagonal at level 0).
            float qx = X - s * e.x, qy = Y - s * e.y, o = 0.5f * T * me.q;
            acc += (0.5f * w) * (level_sample(img, L, T, qx + o * n.x, qy + o * n.y) +
                                 level_sample(img, L, T, qx - o * n.x, qy - o * n.y));
            wsum += w;
        }
        acc2 += wl * (wsum > 0.0f ? acc / wsum : here);
    }
    acc2 = mix(here, acc2, me.rho) * jac;
    out[3u * i] = acc2.x; out[3u * i + 1u] = acc2.y; out[3u * i + 2u] = acc2.z;
}

// --- the diffusion filter, fast: a Gaussian-pyramid basis -------------------------
//
// out = c_id E + c_0 S + up(A_1), A_k = a_k L_k + up(A_{k+1}), L_k = down^k(S),
// S the scatter source (E, or E with the film's highlight boost). The weights
// are fitted on the host to the PSF (core/diffusion_psf `fit_pyramid`); the two
// filters are the ones its basis was measured through. The levels are fp16
// (half a plane's third): they hold scattered light, a low-pass of the frame
// at weights of a few per cent, where half's 11 bits are far below a code.

// node_boost's lift (`spk_boost`), in the source's units. bp: {on, x0, 1/max, a, scale}
inline float3 scatter_source(float3 v, device const float* bp) {
    if (bp[0] == 0.0f) return v;
    float3 o;
    for (uint c = 0u; c < 3u; ++c) {
        float x = v[c];
        if (x <= bp[1]) { o[c] = x; continue; }
        float dx = (x - bp[1]) * bp[2];
        o[c] = x + bp[4] * (exp(bp[3] * dx) - bp[3] * dx - 1.0f);
    }
    return o;
}

inline float3 ld3h(device const half* img, uint s) {
    return float3(float(img[3u * s]), float(img[3u * s + 1u]), float(img[3u * s + 2u]));
}
inline void st3h(device half* img, uint s, float3 v) {
    img[3u * s] = half(v.x); img[3u * s + 1u] = half(v.y); img[3u * s + 2u] = half(v.z);
}

// One level down, the binomial [1 5 10 10 5 1] / 32 per axis on samples
// 2i - 2 .. 2i + 3 (core/diffusion_psf `down1`, which the fit's basis was
// measured through). From the image itself (fp32, the scatter source applied)
// or from the level above (fp16). meta: {Hin, Win, Hout, Wout}
constant float kB6[6] = {1.0f / 32.0f, 5.0f / 32.0f, 10.0f / 32.0f, 10.0f / 32.0f, 5.0f / 32.0f, 1.0f / 32.0f};
kernel void spk_lens_pyr_down0(device const float* img [[buffer(0)]],
                               device const float* bp [[buffer(1)]],
                               device const uint* meta [[buffer(2)]],
                               device half* out [[buffer(3)]],
                               uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint Hin = meta[0], Win = meta[1], Hout = meta[2], Wout = meta[3];
    if (i >= Hout * Wout) return;
    uint r = i / Wout, j = i % Wout;
    int fy = 2 * int(r) - 2, fx = 2 * int(j) - 2;
    uint xs[6];
    for (int b = 0; b < 6; ++b) xs[b] = uint(clamp(fx + b, 0, int(Win) - 1));
    float3 s = float3(0.0f);
    for (int a = 0; a < 6; ++a) {
        uint row = uint(clamp(fy + a, 0, int(Hin) - 1)) * Win;
        float3 acc = float3(0.0f);
        for (int b = 0; b < 6; ++b) acc += kB6[b] * scatter_source(ld3(img, row + xs[b]), bp);
        s += kB6[a] * acc;
    }
    st3h(out, i, s);
}
kernel void spk_lens_pyr_down(device const half* img [[buffer(0)]],
                              device const uint* meta [[buffer(1)]],
                              device half* out [[buffer(2)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint Hin = meta[0], Win = meta[1], Hout = meta[2], Wout = meta[3];
    if (i >= Hout * Wout) return;
    uint r = i / Wout, j = i % Wout;
    int fy = 2 * int(r) - 2, fx = 2 * int(j) - 2;
    uint xs[6];
    for (int b = 0; b < 6; ++b) xs[b] = uint(clamp(fx + b, 0, int(Win) - 1));
    float3 s = float3(0.0f);
    for (int a = 0; a < 6; ++a) {
        uint row = uint(clamp(fy + a, 0, int(Hin) - 1)) * Win;
        float3 acc = float3(0.0f);
        for (int b = 0; b < 6; ++b) acc += kB6[b] * ld3h(img, row + xs[b]);
        s += kB6[a] * acc;
    }
    st3h(out, i, s);
}

// Up one level at fine pixel (x, y): the down filter's transpose x 2 per axis,
// an even fine sample 2b taking (5, 10, 1) / 16 of coarse b - 1, b, b + 1 and
// an odd one (1, 10, 5) / 16 (core/diffusion_psf `up1`).
inline float3 pyr_up(device const half* C, uint Hc, uint Wc, uint x, uint y) {
    const float ev[3] = {5.0f / 16.0f, 10.0f / 16.0f, 1.0f / 16.0f};
    const float od[3] = {1.0f / 16.0f, 10.0f / 16.0f, 5.0f / 16.0f};
    int bx = int(x / 2u), by = int(y / 2u);
    uint cs[3];
    float wx[3], wy[3];
    for (int t = 0; t < 3; ++t) {
        cs[t] = uint(clamp(bx - 1 + t, 0, int(Wc) - 1));
        wx[t] = (x & 1u) ? od[t] : ev[t];
        wy[t] = (y & 1u) ? od[t] : ev[t];
    }
    float3 s = float3(0.0f);
    for (int a = 0; a < 3; ++a) {
        uint row = uint(clamp(by - 1 + a, 0, int(Hc) - 1)) * Wc;
        float3 acc = wx[0] * ld3h(C, row + cs[0]) + wx[1] * ld3h(C, row + cs[1]) + wx[2] * ld3h(C, row + cs[2]);
        s += wy[a] * acc;
    }
    return s;
}

// A_k = a_k L_k + up(A_{k+1}), in place over L_k. meta: {Hf, Wf, Hc, Wc, has_coarse}; a: a_k[3]
kernel void spk_lens_pyr_up(device half* fine [[buffer(0)]],
                            device const half* coarse [[buffer(1)]],
                            device const float* a [[buffer(2)]],
                            device const uint* meta [[buffer(3)]],
                            uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint Hf = meta[0], Wf = meta[1];
    if (i >= Hf * Wf) return;
    float3 v = float3(a[0], a[1], a[2]) * ld3h(fine, i);
    if (meta[4] != 0u) v += pyr_up(coarse, meta[2], meta[3], i % Wf, i / Wf);
    st3h(fine, i, v);
}

// out = c_id E + sum_t f_t S(p + t) + up(A_1): the identity on E (fp32), the
// core FIR on the scatter source (a (2 R + 1)^2 window, R <= 5, edges
// replicated) and the pyramid. Rows [row0, row0 + n) of the frame into `out`'s
// rows 0 .. n - 1 (not in place: the core reads its neighbours). 32 x 8 tiles:
// the tile's scatter source with its border, fp16 (scattered light: half's 11
// bits are far below a code at the core's off-centre weights; the centre tap
// reads E in fp32), and the coarse level's
// samples it needs, in threadgroup memory. The core is symmetric in x, y and
// their swap, so one weight serves up to eight samples.
// c: {c_id[3], f[(R+1)^2][3]} (the quadrant dx, dy >= 0, f[dy][dx] = f[dx][dy]);
// meta: {H, W, H1, W1, R, row0, n}. Correct for any threadgroup size (the
// grain FIR's pattern: tiles walked by threadgroup with a grid stride,
// cooperative loops by the group's size). The tile origin is even (row0 is a
// chunk's, a multiple of 8), so the coarse rows are (ty0 / 2 - 1) + 0 .. 5.
constant constexpr uint kCoreTW = 32u, kCoreTH = 8u, kCoreRMax = 5u;
constant constexpr uint kCoarseW = kCoreTW / 2u + 2u, kCoarseH = kCoreTH / 2u + 2u;
kernel void spk_lens_pyr_out(device const float* E [[buffer(0)]],
                             device const half* A1 [[buffer(1)]],
                             device const float* c [[buffer(2)]],
                             device const float* bp [[buffer(3)]],
                             device const uint* meta [[buffer(4)]],
                             device float* out [[buffer(5)]],
                             uint3 lid3 [[thread_position_in_threadgroup]],
                             uint3 group_size3 [[threads_per_threadgroup]],
                             uint3 group3 [[threadgroup_position_in_grid]],
                             uint3 groups3 [[threadgroups_per_grid]]) {
    constexpr uint SWM = kCoreTW + 2u * kCoreRMax, SHM = kCoreTH + 2u * kCoreRMax;
    threadgroup half4 ts[SWM * SHM];
    threadgroup float4 tc[kCoarseW * kCoarseH];
    const uint lid = lid3.x, group_size = group_size3.x;
    const uint H = meta[0], W = meta[1], Hc = meta[2], Wc = meta[3], R = meta[4], row0 = meta[5], n = meta[6];
    const uint SW = kCoreTW + 2u * R, SH = kCoreTH + 2u * R, Q = R + 1u;
    const uint tiles_x = (W + kCoreTW - 1u) / kCoreTW;
    const uint n_tiles = tiles_x * ((n + kCoreTH - 1u) / kCoreTH);
    const float3 cid = float3(c[0], c[1], c[2]);
    const float ev[3] = {5.0f / 16.0f, 10.0f / 16.0f, 1.0f / 16.0f};
    const float od[3] = {1.0f / 16.0f, 10.0f / 16.0f, 5.0f / 16.0f};
    for (uint tile = group3.x; tile < n_tiles; tile += groups3.x) {
        const int tx0 = int((tile % tiles_x) * kCoreTW), ty0 = int(row0 + (tile / tiles_x) * kCoreTH);
        for (uint e = lid; e < SW * SH; e += group_size) {
            uint r = e / SW, q = e % SW;
            uint gy = uint(clamp(ty0 + int(r) - int(R), 0, int(H) - 1));
            uint gx = uint(clamp(tx0 + int(q) - int(R), 0, int(W) - 1));
            ts[e] = half4(half3(scatter_source(ld3(E, gy * W + gx), bp)), 0.0h);
        }
        const int cy0 = ty0 / 2 - 1, cx0 = tx0 / 2 - 1;
        for (uint e = lid; e < kCoarseW * kCoarseH; e += group_size) {
            uint r = e / kCoarseW, q = e % kCoarseW;
            uint gy = uint(clamp(cy0 + int(r), 0, int(Hc) - 1)), gx = uint(clamp(cx0 + int(q), 0, int(Wc) - 1));
            tc[e] = float4(ld3h(A1, gy * Wc + gx), 0.0f);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint e = lid; e < kCoreTW * kCoreTH; e += group_size) {
            uint r = e / kCoreTW, q = e % kCoreTW;
            uint gy = uint(ty0) + r, gx = uint(tx0) + q;
            if (gy >= row0 + n || gx >= W) continue;
            // the pyramid: `pyr_up` from the tile's coarse samples
            const uint br = r / 2u, bq = q / 2u;   // coarse b - 1 is tile index b - cy0 - 1 = br
            float3 up = float3(0.0f);
            for (uint a = 0u; a < 3u; ++a) {
                float wy = (gy & 1u) ? od[a] : ev[a];
                uint row = (br + a) * kCoarseW + bq;
                float3 acc = ((gx & 1u) ? od[0] : ev[0]) * tc[row].xyz + ((gx & 1u) ? od[1] : ev[1]) * tc[row + 1u].xyz +
                             ((gx & 1u) ? od[2] : ev[2]) * tc[row + 2u].xyz;
                up += wy * acc;
            }
            // the core: f[dy][dx] over the eight samples (+-dx, +-dy), (+-dy, +-dx)
            // The centre tap -- the core's largest, up to a third of the light
            // -- from E itself in fp32, the others from the fp16 tile.
            const int ci = int((r + R) * SW + (q + R)), sw = int(SW);
            const float3 e0 = ld3(E, gy * W + gx);
            float3 core = float3(c[3], c[4], c[5]) * scatter_source(e0, bp);
            for (uint dy = 0u; dy <= R; ++dy) {
                for (uint dx = max(dy, 1u); dx <= R; ++dx) {
                    const int x = int(dx), y = int(dy);
                    float3 s = float3(ts[ci + y * sw + x].xyz);
                    if (x != 0) s += float3(ts[ci + y * sw - x].xyz);
                    if (y != 0) {
                        s += float3(ts[ci - y * sw + x].xyz);
                        if (x != 0) s += float3(ts[ci - y * sw - x].xyz);
                    }
                    if (x != y) {   // the swap
                        s += float3(ts[ci + x * sw + y].xyz) + float3(ts[ci - x * sw + y].xyz);
                        if (y != 0) s += float3(ts[ci + x * sw - y].xyz) + float3(ts[ci - x * sw - y].xyz);
                    }
                    const uint w = 3u + 3u * (dy * Q + dx);
                    core += float3(c[w], c[w + 1u], c[w + 2u]) * s;
                }
            }
            const uint oi = (gy - row0) * W + gx;
            float3 o = cid * e0 + core + up;
            out[3u * oi] = o.x; out[3u * oi + 1u] = o.y; out[3u * oi + 2u] = o.z;
        }
        // Before the next tile overwrites what this one's threads may still read.
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// A symmetric FIR along one axis of an fp16 level (the glow's Gaussian on its
// level, `lens_glow_fast`), edges replicated. w: taps 0 .. r; meta: {H, W, r, axis}
kernel void spk_lens_gauss_1d(device const half* img [[buffer(0)]],
                              device const float* w [[buffer(1)]],
                              device const uint* meta [[buffer(2)]],
                              device half* out [[buffer(3)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1], axis = meta[3];
    int r = int(meta[2]);
    if (i >= H * W) return;
    int y = int(i / W), x = int(i % W);
    float3 s = w[0] * ld3h(img, i);
    for (int t = 1; t <= r; ++t) {
        uint a, b;
        if (axis == 0u) {
            a = uint(y) * W + uint(clamp(x - t, 0, int(W) - 1));
            b = uint(y) * W + uint(clamp(x + t, 0, int(W) - 1));
        } else {
            a = uint(clamp(y - t, 0, int(H) - 1)) * W + uint(x);
            b = uint(clamp(y + t, 0, int(H) - 1)) * W + uint(x);
        }
        s += w[t] * (ld3h(img, a) + ld3h(img, b));
    }
    st3h(out, i, s);
}

// Rows of one image into another: dst row (dst_row + r) = src row (src_row + r).
// meta: {W, src_row, dst_row, n_floats}
kernel void spk_lens_rows_put(device const float* src [[buffer(0)]],
                              device const uint* meta [[buffer(1)]],
                              device float* dst [[buffer(2)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[3]) return;
    dst[size_t(meta[2]) * meta[0] * 3u + i] = src[size_t(meta[1]) * meta[0] * 3u + i];
}

// The input's transfer function, put back after the lens (`spk_cctf_decode`'s
// inverse, `cctf_encode_mode` in nodes.metal): the lens runs in linear light.
// In place. meta: {n, mode}
inline float lens_cctf_encode(float v, uint mode) {
    switch (mode) {
        case 0u: return (v <= 0.0031308f) ? 12.92f * v : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
        case 1u: return (v < 1.0f / 512.0f) ? v * 16.0f : pow(v, 1.0f / 1.8f);
        case 2u: return pow(v, 256.0f / 563.0f);
        case 3u: return (0.018f > v) ? v * 4.5f : 1.099f * pow(v, 0.45f) - 0.099f;
        default: return v;
    }
}
kernel void spk_lens_cctf_encode(device float* x [[buffer(0)]],
                                 device const uint* meta [[buffer(1)]],
                                 uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    x[i] = lens_cctf_encode(x[i], meta[1]);
}
