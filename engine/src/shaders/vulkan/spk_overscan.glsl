// GLSL translation of the helpers overscan.metal's canvas, film-presence and
// light kernels share (RFC-032 §26-§31): the parameter block, the scan
// registration, the hash and value noise, the gate's and the perforations'
// signed distances, the penumbra and erf. spk_overscan_add_mask needs none of
// it -- it is integer indexing and a multiply-add -- and does not include it.
//
// P is binding 1 in every kernel that includes this, as [[buffer(1)]] is in
// Metal, and keeps Metal's name so the indices read as they do there; its
// layout is overscan.cpp's `enum OsP`. Every literal is Metal's.
//
// No operand of a min, max or clamp below can be NaN for a finite P, and pixel
// values reach the output only through mix and multiply-add, so GLSL leaving
// those functions' NaN choice undefined never matters here, and a NaN pixel
// stays NaN on both backends.
#ifndef SPK_OVERSCAN_GLSL
#define SPK_OVERSCAN_GLSL

layout(set = 0, binding = 1, std430) readonly buffer OverscanParams { float P[]; };

const uint P_CW = 0u, P_CH = 1u, P_PX = 2u, P_FW = 3u, P_FH = 4u,
    P_A00 = 5u, P_A01 = 6u, P_A10 = 7u, P_A11 = 8u, P_CS = 9u, P_CT = 10u, P_CU = 11u, P_CV = 12u,
    P_VERTICAL = 13u,
    P_GS0 = 14u, P_GT0 = 15u, P_GW = 16u, P_GH = 17u, P_CORNER = 18u, P_PENUMBRA = 19u,
    P_WOB_A = 20u,                // 4 sides x 3 harmonics
    P_WOB_PH = 32u,               // 4 sides x 3 harmonics
    P_FILM_W = 44u, P_FOG_AMP = 45u, P_FOG_WIDTH = 46u, P_FOG_SEED = 47u, P_FOG_PERIOD = 48u,
    P_FOG_R = 49u, P_FOG_G = 50u, P_FOG_B = 51u,
    P_N_LEAKS = 52u,
    P_PERFORATED = 83u, P_PERF_PITCH = 84u, P_PERF_W = 85u, P_PERF_H = 86u, P_PERF_EDGE = 87u,
    P_PERF_R = 88u, P_PERF_PHASE = 89u,
    P_HOLE_C = 90u, P_HOLE_M = 91u, P_HOLE_Y = 92u,
    P_FLARE_AMP = 93u, P_FLARE_WIDTH = 94u,
    P_GATE_R = 95u,               // 4 corner radii: (s-,t-), (s+,t-), (s+,t+), (s-,t+)
    P_N_Q = 99u, P_Q = 100u,      // up to 8 x (4 vertices s,t; round; sign: +1/-1 quad adds/cuts, +2/-2 ellipse (cs, ct, rs, rt))
    P_ROUGH_AMP = 180u, P_ROUGH_PERIOD = 181u, P_ROUGH_SEED = 182u,
    P_HOLES_LIGHT = 183u, P_LIGHT_R = 184u, P_LIGHT_G = 185u, P_LIGHT_B = 186u,
    P_PERF_SEED = 187u, P_LIGHT_FALL = 188u, P_LIGHT_DIR = 189u,
    P_WALL_T = 190u, P_WALL_VS = 191u, P_WALL_VT = 192u, P_WALL_PAR = 193u,
    P_BASE_R = 194u, P_BASE_G = 195u, P_BASE_B = 196u, P_WALL_GLOW = 197u, P_WALL_SCATTER = 198u,
    P_CARRIER = 199u,
    P_LEAKS = 200u,               // up to 12 x (s, side, amp, sigma_s, sigma_t)
    P_PAIR_ADV = 260u,            // > 0: the same gate exposed again this far along (a half-frame pair)
    P_COUNT = 261u;
const uint kQStride = 10u;
const float M_PI_F = 3.14159265358979323846;

// The scan registration. `precise` keeps every product and sum rounded on its
// own, in the order overscan.metal writes them (Vulkan rounds each correctly;
// precise forbids fusing them), so spk_vulkan_overscan's float32 mirror is
// this coordinate -- the one every discontinuity below is decided on: the
// film's edge, the nearest hole, the flare's band. Without it the canvas's
// frame samples differed from that reference by up to 2.0e-4 rather than
// 4.6e-5, and 40,684 values rather than 15,969 needed its edge envelope.
vec2 canvas_to_film(float x, float y) {
    precise float u = (x + 0.5) * P[P_PX] - P[P_CU];
    precise float v = (y + 0.5) * P[P_PX] - P[P_CV];
    precise float s = P[P_A00] * u + P[P_A01] * v + P[P_CS];
    precise float t = P[P_A10] * u + P[P_A11] * v + P[P_CT];
    return vec2(s, t);
}

// uint arithmetic wraps modulo 2^32 in GLSL as it does in Metal, so the hash
// is the same bits. 1/4294967295 is 2^-32 in float either way (Metal's
// 4294967295.0f is itself 2^32).
uint hash_u(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
float hash_f(int i, uint seed) { return float(hash_u(uint(i) * 0x9E3779B9u ^ seed)) * (1.0 / 4294967295.0); }
float value_noise(float x, uint seed) {
    float i0 = floor(x), f = x - i0;
    float w = f * f * (3.0 - 2.0 * f);
    return mix(hash_f(int(i0), seed), hash_f(int(i0) + 1, seed), w);
}

// Signed distance to a convex quad (either winding; a repeated vertex makes a
// triangle), negative inside. `qb` is the quad's first index in P.
float sd_quad(vec2 p, uint qb) {
    vec2 v[4] = vec2[4](vec2(P[qb], P[qb + 1u]), vec2(P[qb + 2u], P[qb + 3u]),
                        vec2(P[qb + 4u], P[qb + 5u]), vec2(P[qb + 6u], P[qb + 7u]));
    float d = dot(p - v[0], p - v[0]);
    float sgn = 1.0;
    for (uint i = 0u, j = 3u; i < 4u; j = i, ++i) {
        vec2 e = v[j] - v[i], w = p - v[i];
        float ee = dot(e, e);
        if (ee < 1e-12) continue;
        vec2 b = w - e * clamp(dot(w, e) / ee, 0.0, 1.0);
        d = min(d, dot(b, b));
        bool c0 = p.y >= v[i].y, c1 = p.y < v[j].y, c2 = e.x * w.y > e.y * w.x;
        if ((c0 && c1 && c2) || (!c0 && !c1 && !c2)) sgn = -sgn;
    }
    return sgn * sqrt(d);
}

// The gate (RFC-032 §29): a rounded rectangle with a radius per corner, each
// side's three-harmonic wobble, the camera's quads and ellipses that add to or
// cut from the opening, and the machined edge's roughness. Signed distance,
// negative inside, in mm.
float gate_sdf(vec2 st) {
    float hw = 0.5 * P[P_GW], hh = 0.5 * P[P_GH];
    float ds = st.x - (P[P_GS0] + hw), dt = st.y - (P[P_GT0] + hh);
    float r = ds > 0.0 ? (dt > 0.0 ? P[P_GATE_R + 2u] : P[P_GATE_R + 1u])
                       : (dt > 0.0 ? P[P_GATE_R + 3u] : P[P_GATE_R + 0u]);
    float qs = abs(ds) - (hw - r), qt = abs(dt) - (hh - r);
    float d = length(max(vec2(qs, qt), 0.0)) + min(max(qs, qt), 0.0) - r;
    uint side; float along, len;
    if (qs > qt) { side = ds > 0.0 ? 1u : 3u; along = dt + hh; len = 2.0 * hh; }
    else         { side = dt > 0.0 ? 2u : 0u; along = ds + hw; len = 2.0 * hw; }
    float u = clamp(along / len, 0.0, 1.0);
    float w = 0.0;
    for (uint k = 0u; k < 3u; ++k)
        w += P[P_WOB_A + side * 3u + k] * sin(float(k + 1u) * M_PI_F * u + P[P_WOB_PH + side * 3u + k]);
    d -= w * sin(M_PI_F * u);
    uint nq = uint(P[P_N_Q]);
    for (uint k = 0u; k < nq; ++k) {
        uint qb = P_Q + kQStride * k;
        float dq;
        if (abs(P[qb + 9u]) > 1.5) {
            // an ellipse: centre q[0..1], radii q[2..3]; distance scaled by the
            // smaller radius, exact on the boundary, which is all a penumbra reads
            vec2 radii = max(vec2(P[qb + 2u], P[qb + 3u]), vec2(1e-4));
            dq = (length((st - vec2(P[qb], P[qb + 1u])) / radii) - 1.0) * min(radii.x, radii.y);
        } else {
            dq = sd_quad(st, qb) - P[qb + 8u];
        }
        d = P[qb + 9u] > 0.0 ? min(d, dq) : max(d, -dq);
    }
    if (P[P_ROUGH_AMP] > 0.0) {
        uint seed = uint(P[P_ROUGH_SEED]);
        float per = max(P[P_ROUGH_PERIOD], 1e-3);
        d += P[P_ROUGH_AMP] * (value_noise(st.x / per, seed) + value_noise(st.y / per, seed ^ 0x5bd1e995u) - 1.0);
    }
    return d;
}

// The gate's shadow from a circular aperture: the lit fraction of a disc of
// radius r cut by a straight edge at signed distance d.
float penumbra(float d, float r) {
    if (r <= 1e-6) return d < 0.0 ? 1.0 : 0.0;
    float u = clamp(-d / r, -1.0, 1.0);
    return 0.5 + (u * sqrt(max(1.0 - u * u, 0.0)) + asin(u)) * (1.0 / M_PI_F);
}

// The nearest perforation's signed distance (mm, negative inside), each hole
// with its own jitter, corners, punched-edge roughness and, on about one in
// four, a burr. `hole` returns the hole's own hash (row and index).
float perf_sdf(vec2 st, out uint hole) {
    float W = P[P_FILM_W];
    float pitch = P[P_PERF_PITCH], ph = P[P_PERF_PHASE];
    float k = floor((st.x - ph - 0.5 * P[P_PERF_W]) / pitch + 0.5);
    bool top = st.y < 0.5 * W;
    uint seed = uint(P[P_PERF_SEED]);
    hole = hash_u(uint(int(k) * 2 + (top ? 0 : 1)) * 0x9E3779B9u ^ seed);
    int h = int(hole & 0xFFFFu);
    float j0 = hash_f(h, seed ^ 0x1u) - 0.5, j1 = hash_f(h, seed ^ 0x2u) - 0.5;
    float j2 = hash_f(h, seed ^ 0x3u) - 0.5, j3 = hash_f(h, seed ^ 0x4u) - 0.5;
    float j4 = hash_f(h, seed ^ 0x5u) - 0.5;
    float wa = P[P_PERF_W] + 0.016 * j2, hc = P[P_PERF_H] + 0.016 * j3;
    float r = clamp(P[P_PERF_R] + 0.08 * j4, 0.3, 0.6);
    float sc = ph + k * pitch + 0.5 * P[P_PERF_W] + 0.020 * j0;
    float tc = (top ? P[P_PERF_EDGE] + 0.5 * P[P_PERF_H] : W - P[P_PERF_EDGE] - 0.5 * P[P_PERF_H]) + 0.024 * j1;
    vec2 q = abs(vec2(st.x - sc, st.y - tc)) - vec2(0.5 * wa - r, 0.5 * hc - r);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    // the punched edge: each hole's own roughness, 1-4 microns
    float rough = 0.001 + 0.003 * hash_f(h, seed ^ 0x6u);
    d += rough * (value_noise(st.x / 0.05, seed ^ 0x77u) + value_noise(st.y / 0.05, seed ^ 0x99u) - 1.0) * 2.0;
    // a burr or a chip on about one hole in four
    if (hash_f(h, seed ^ 0x7u) < 0.25) {
        float ang = 6.2831853 * hash_f(h, seed ^ 0x8u);
        vec2 pb = vec2(sc, tc) + vec2(cos(ang) * 0.5 * wa, sin(ang) * 0.5 * hc);
        float sig = 0.020 + 0.030 * hash_f(h, seed ^ 0x9u);
        float amp = (hash_f(h, seed ^ 0xAu) < 0.5 ? -1.0 : 1.0) * (0.006 + 0.010 * hash_f(h, seed ^ 0xBu));
        d += amp * exp(-dot(st - pb, st - pb) / (sig * sig));
    }
    return d;
}

// How soft a perforation's edge is in a scan, as a Gaussian sigma in mm
// (measured on the owner's strips; overscan.metal says how).
const float kHoleEdgeSigma = 0.017;

// erf, Abramowitz and Stegun 7.1.26 (|error| < 1.5e-7).
float erf_as(float x) {
    float t = 1.0 / (1.0 + 0.3275911 * abs(x));
    float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
    return x < 0.0 ? -y : y;
}

// Where there is film: 1 on the strip, 0 in the perforations and past its edges.
float film_alpha(vec2 st) {
    float W = P[P_FILM_W], px = P[P_PX];
    float a = P[P_CARRIER] > 1.5 ? 1.0 : clamp(min(st.y, W - st.y) / px + 0.5, 0.0, 1.0);
    if (P[P_PERFORATED] > 0.5) {
        uint hole;
        // the measured softness, and the pixel's own width (a one-pixel ramp
        // is a sigma of 0.31 px)
        float sigma = sqrt(kHoleEdgeSigma * kHoleEdgeSigma + 0.0961 * px * px);
        a *= 0.5 + 0.5 * erf_as(perf_sdf(st, hole) / (1.41421356 * sigma));
    }
    return a;
}
#endif
