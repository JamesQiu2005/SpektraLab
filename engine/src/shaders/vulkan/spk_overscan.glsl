// spk_overscan.glsl -- overscan.metal's helpers on Vulkan: the film canvas's geometry (the gate, the
// perforations, the film's presence), the leak's field, the hashes and noise. Expression for expression
// from the Metal file; sin, cos, atan2 and asin through spk_trig.glsl (Vulkan's built-ins are far looser
// than Metal's). The including kernel declares the parameter block as `P` (overscan.cpp `enum OsP`).
#include "spk_trig.glsl"

const uint P_CW = 0u, P_CH = 1u, P_PX = 2u, P_FW = 3u, P_FH = 4u;
const uint P_A00 = 5u, P_A01 = 6u, P_A10 = 7u, P_A11 = 8u, P_CS = 9u, P_CT = 10u, P_CU = 11u, P_CV = 12u;
const uint P_VERTICAL = 13u;
const uint P_GS0 = 14u, P_GT0 = 15u, P_GW = 16u, P_GH = 17u, P_CORNER = 18u, P_PENUMBRA = 19u;
const uint P_WOB_A = 20u, P_WOB_PH = 32u;
const uint P_FILM_W = 44u, P_FOG_AMP = 45u, P_FOG_WIDTH = 46u, P_FOG_SEED = 47u, P_FOG_PERIOD = 48u;
const uint P_FOG_R = 49u, P_FOG_G = 50u, P_FOG_B = 51u;
const uint P_N_LEAKS = 52u;
const uint P_PERFORATED = 83u, P_PERF_PITCH = 84u, P_PERF_W = 85u, P_PERF_H = 86u, P_PERF_EDGE = 87u, P_PERF_R = 88u,
           P_PERF_PHASE = 89u;
const uint P_HOLE_C = 90u, P_HOLE_M = 91u, P_HOLE_Y = 92u;
const uint P_FLARE_AMP = 93u, P_FLARE_WIDTH = 94u;
const uint P_GATE_R = 95u;
const uint P_N_Q = 99u, P_Q = 100u;
const uint P_ROUGH_AMP = 180u, P_ROUGH_PERIOD = 181u, P_ROUGH_SEED = 182u;
const uint P_HOLES_LIGHT = 183u, P_LIGHT_R = 184u, P_LIGHT_G = 185u, P_LIGHT_B = 186u;
const uint P_PERF_SEED = 187u, P_LIGHT_FALL = 188u, P_LIGHT_DIR = 189u;
const uint P_WALL_T = 190u, P_WALL_VS = 191u, P_WALL_VT = 192u, P_WALL_PAR = 193u, P_BASE_R = 194u, P_BASE_G = 195u,
           P_BASE_B = 196u, P_WALL_GLOW = 197u, P_WALL_SCATTER = 198u;
const uint P_CARRIER = 199u;
const uint P_LEAKS = 200u;
const uint P_PAIR_ADV = 260u;
const uint P_LEAK_KIND = 261u, P_LEAK_AMP = 262u, P_LEAK_SC = 263u, P_LEAK_ST = 264u, P_LEAK_EDGE = 265u,
           P_LEAK_SIG_A = 266u, P_LEAK_SIG_B = 267u, P_LEAK_DIR = 268u, P_LEAK_TILT = 269u,
           P_LEAK_FRONT = 270u, P_LEAK_LAMBDA = 271u, P_LEAK_LEN = 272u, P_LEAK_CORE = 273u;
const uint P_LEAK_REAR_R = 274u, P_LEAK_FRONT_R = 277u;
const uint P_FALLOFF = 280u, P_FALLOFF_F = 281u, P_FALLOFF_N = 282u;
const uint P_PERF_DT = 283u;
const uint P_EDGE_S = 284u, P_EDGE_L = 286u, P_EDGE_U = 288u, P_EDGE_K = 290u, P_EDGE_PH = 292u;
const uint P_EDGE_JIT = 296u, P_EDGE_CORE = 297u, P_EDGE_P0 = 298u, P_EDGE_P1 = 299u, P_EDGE_PA = 300u,
           P_EDGE_SHIFT = 301u, P_EDGE_TAIL = 302u, P_EDGE_TLEN = 303u;
const uint P_PERF_SHAPE = 304u, P_PERF_ROWS = 305u, P_PERF_RMIN = 306u, P_PERF_RMAX = 307u, P_PERF_JIT = 308u,
           P_NB_PREV = 309u, P_NB_NEXT = 310u;
const uint P_EDGE_AMP = 311u, P_EDGE_FRONT = 312u;
const uint kQStride = 10u;
const float SPK_PI = 3.14159265358979323846;

uint spk_global_index() {
    return gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
}

vec2 canvas_to_film(float x, float y) {
    const float u = (x + 0.5) * P[P_PX] - P[P_CU];
    const float v = (y + 0.5) * P[P_PX] - P[P_CV];
    return vec2(P[P_A00] * u + P[P_A01] * v + P[P_CS], P[P_A10] * u + P[P_A11] * v + P[P_CT]);
}

uint hash_u(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
float hash_f(int i, uint seed) { return float(hash_u(uint(i) * 0x9E3779B9u ^ seed)) * (1.0 / 4294967295.0); }
float value_noise(float x, uint seed) {
    const float i0 = floor(x), f = x - i0;
    const float w = f * f * (3.0 - 2.0 * f);
    return mix(hash_f(int(i0), seed), hash_f(int(i0) + 1, seed), w);
}

// asin to float accuracy (spk_trig's atan2), for the penumbra.
float spk_asin(float u) { return spk_atan2(u, sqrt(max(1.0 - u * u, 0.0))); }

// Signed distance to a convex quad at P[q0 .. q0 + 7] (either winding), negative inside.
float sd_quad(vec2 p, uint q0) {
    vec2 v[4] = vec2[4](vec2(P[q0], P[q0 + 1u]), vec2(P[q0 + 2u], P[q0 + 3u]), vec2(P[q0 + 4u], P[q0 + 5u]),
                        vec2(P[q0 + 6u], P[q0 + 7u]));
    float d = dot(p - v[0], p - v[0]);
    float sgn = 1.0;
    for (uint i = 0u, j = 3u; i < 4u; j = i, ++i) {
        const vec2 e = v[j] - v[i], w = p - v[i];
        const float ee = dot(e, e);
        if (ee < 1e-12) continue;
        const vec2 b = w - e * clamp(dot(w, e) / ee, 0.0, 1.0);
        d = min(d, dot(b, b));
        const bool c0 = p.y >= v[i].y, c1 = p.y < v[j].y, c2 = e.x * w.y > e.y * w.x;
        if ((c0 && c1 && c2) || (!c0 && !c1 && !c2)) sgn = -sgn;
    }
    return sgn * sqrt(d);
}

// The gate: signed distance, negative inside, in mm (overscan.metal `gate_sdf`).
float gate_sdf(vec2 st) {
    const float hw = 0.5 * P[P_GW], hh = 0.5 * P[P_GH];
    const float ds = st.x - (P[P_GS0] + hw), dt = st.y - (P[P_GT0] + hh);
    const float r = ds > 0.0 ? (dt > 0.0 ? P[P_GATE_R + 2u] : P[P_GATE_R + 1u])
                             : (dt > 0.0 ? P[P_GATE_R + 3u] : P[P_GATE_R + 0u]);
    const float qs = abs(ds) - (hw - r), qt = abs(dt) - (hh - r);
    float d = length(max(vec2(qs, qt), 0.0)) + min(max(qs, qt), 0.0) - r;
    uint side; float along, len;
    if (qs > qt) { side = ds > 0.0 ? 1u : 3u; along = dt + hh; len = 2.0 * hh; }
    else         { side = dt > 0.0 ? 2u : 0u; along = ds + hw; len = 2.0 * hw; }
    const float u = clamp(along / len, 0.0, 1.0);
    float w = 0.0;
    for (uint k = 0u; k < 3u; ++k)
        w += P[P_WOB_A + side * 3u + k] * spk_sin(float(k + 1u) * SPK_PI * u + P[P_WOB_PH + side * 3u + k]);
    d -= w * spk_sin(SPK_PI * u);
    const uint nq = uint(P[P_N_Q]);
    for (uint k = 0u; k < nq; ++k) {
        const uint q = P_Q + kQStride * k;
        float dq;
        if (abs(P[q + 9u]) > 1.5) {
            const vec2 rr = max(vec2(P[q + 2u], P[q + 3u]), vec2(1e-4));
            dq = (length((st - vec2(P[q], P[q + 1u])) / rr) - 1.0) * min(rr.x, rr.y);
        } else {
            dq = sd_quad(st, q) - P[q + 8u];
        }
        d = P[q + 9u] > 0.0 ? min(d, dq) : max(d, -dq);
    }
    if (P[P_ROUGH_AMP] > 0.0) {
        const uint seed = uint(P[P_ROUGH_SEED]);
        const float per = max(P[P_ROUGH_PERIOD], 1e-3);
        d += P[P_ROUGH_AMP] * (value_noise(st.x / per, seed) + value_noise(st.y / per, seed ^ 0x5bd1e995u) - 1.0);
    }
    return d;
}

// The lit fraction of a disc of radius r cut by an edge at signed distance d.
float penumbra(float d, float r) {
    if (r <= 1e-6) return d < 0.0 ? 1.0 : 0.0;
    const float u = clamp(-d / r, -1.0, 1.0);
    return 0.5 + (u * sqrt(max(1.0 - u * u, 0.0)) + spk_asin(u)) * (1.0 / SPK_PI);
}

// API-SPEC §21.4: the lens's falloff at gate position `sg`.
float lens_falloff(vec2 sg) {
    const vec2 c = vec2(P[P_GS0] + 0.5 * P[P_GW], P[P_GT0] + 0.5 * P[P_GH]);
    const float fl = max(P[P_FALLOFF_F], 1.0);
    const float r2 = dot(sg - c, sg - c);
    const float cos_t = fl * inversesqrt(fl * fl + r2);
    return pow(cos_t, P[P_FALLOFF_N] * P[P_FALLOFF]);
}

// The nearest perforation's signed distance (mm, negative inside); `hole` its hash.
float perf_sdf(vec2 st, out uint hole) {
    const float W = P[P_FILM_W];
    const float pitch = P[P_PERF_PITCH], ph = P[P_PERF_PHASE];
    const float k = floor((st.x - ph - 0.5 * P[P_PERF_W]) / pitch + 0.5);
    const bool top = st.y < 0.5 * W;
    if ((P[P_PERF_ROWS] > 0.5 && P[P_PERF_ROWS] < 1.5 && !top) || (P[P_PERF_ROWS] > 1.5 && top)) {
        hole = 0u;
        return 1.0e3;
    }
    const uint seed = uint(P[P_PERF_SEED]);
    const float jit = P[P_PERF_JIT] > 0.0 ? P[P_PERF_JIT] : 1.0;
    const float rmin = P[P_PERF_RMIN] > 0.0 ? P[P_PERF_RMIN] : 0.3, rmax = P[P_PERF_RMAX] > 0.0 ? P[P_PERF_RMAX] : 0.6;
    hole = hash_u(uint(int(k) * 2 + (top ? 0 : 1)) * 0x9E3779B9u ^ seed);
    const int hh = int(hole & 0xFFFFu);
    const float j0 = hash_f(hh, seed ^ 0x1u) - 0.5, j1 = hash_f(hh, seed ^ 0x2u) - 0.5;
    const float j2 = hash_f(hh, seed ^ 0x3u) - 0.5, j3 = hash_f(hh, seed ^ 0x4u) - 0.5;
    const float j4 = hash_f(hh, seed ^ 0x5u) - 0.5;
    const float wa = P[P_PERF_W] + 0.016 * jit * j2, hc = P[P_PERF_H] + 0.016 * jit * j3;
    const float r = clamp(P[P_PERF_R] + 0.08 * jit * j4, rmin, rmax);
    const float sc = ph + k * pitch + 0.5 * P[P_PERF_W] + 0.020 * jit * j0;
    const float tc = (top ? P[P_PERF_EDGE] + 0.5 * P[P_PERF_H] : W - P[P_PERF_EDGE] - 0.5 * P[P_PERF_H]) + 0.024 * jit * j1 +
                     P[P_PERF_DT];
    float d;
    if (P[P_PERF_SHAPE] > 0.5) {
        const vec2 pd = vec2(st.x - sc, st.y - tc);
        d = max(length(pd) - (0.5 * hc - r), abs(pd.x) - (0.5 * wa - r)) - r;
    } else {
        const vec2 q = abs(vec2(st.x - sc, st.y - tc)) - vec2(0.5 * wa - r, 0.5 * hc - r);
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }
    const float rough = 0.001 + 0.003 * hash_f(hh, seed ^ 0x6u);
    d += rough * (value_noise(st.x / 0.05, seed ^ 0x77u) + value_noise(st.y / 0.05, seed ^ 0x99u) - 1.0) * 2.0;
    if (hash_f(hh, seed ^ 0x7u) < 0.25) {
        const float ang = 6.2831853 * hash_f(hh, seed ^ 0x8u);
        const vec2 pb = vec2(sc, tc) + vec2(spk_cos(ang) * 0.5 * wa, spk_sin(ang) * 0.5 * hc);
        const float sig = 0.020 + 0.030 * hash_f(hh, seed ^ 0x9u);
        const float amp = (hash_f(hh, seed ^ 0xAu) < 0.5 ? -1.0 : 1.0) * (0.006 + 0.010 * hash_f(hh, seed ^ 0xBu));
        d += amp * exp(-dot(st - pb, st - pb) / (sig * sig));
    }
    return d;
}

const float kHoleEdgeSigma = 0.017;

// erf, Abramowitz and Stegun 7.1.26 (|error| < 1.5e-7).
float erf_as(float x) {
    const float t = 1.0 / (1.0 + 0.3275911 * abs(x));
    const float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
    return x < 0.0 ? -y : y;
}

// Where there is film: 1 on the strip, 0 in the perforations and past its edges.
float film_alpha(vec2 st) {
    const float W = P[P_FILM_W], px = P[P_PX];
    float a = P[P_CARRIER] > 1.5 ? 1.0 : clamp(min(st.y, W - st.y) / px + 0.5, 0.0, 1.0);
    if (P[P_PERFORATED] > 0.5) {
        uint hole;
        const float sigma = sqrt(kHoleEdgeSigma * kHoleEdgeSigma + 0.0961 * px * px);
        a *= 0.5 + 0.5 * erf_as(perf_sdf(st, hole) / (1.41421356 * sigma));
    }
    return a;
}

// --- the light leak (API-SPEC §21.1, §21.9) ---------------------------------------
vec3 leak_edge(vec2 st, vec3 rear, vec3 front, float amp, float f) {
    const float W = P[P_FILM_W];
    if (st.y < 0.0 || st.y > W) return vec3(0.0);
    const float s = st.x + P[P_EDGE_SHIFT];
    vec3 e = vec3(0.0);
    for (uint k = 0u; k < 2u; ++k) {
        const float d = max(k == 0u ? st.y : W - st.y, 0.0);
        const float p1 = P[P_EDGE_PH + 2u * k], p2 = P[P_EDGE_PH + 2u * k + 1u];
        const float k1 = P[P_EDGE_K], k2 = P[P_EDGE_K + 1u];
        const float w = 0.55 * spk_sin(k1 * s + p1) + 0.33 * spk_sin(k2 * s + p2) + 0.12 * spk_sin(2.9 * k2 * s + p1 + p2);
        const float w2 = 0.6 * spk_sin(k1 * s + p2 + 2.1) + 0.4 * spk_sin(k2 * s + p1 + 0.7);
        const float len = max(P[P_EDGE_L + k] * exp(P[P_EDGE_U + k] * w), 1e-3);
        const float str = P[P_EDGE_S + k] * exp2(P[P_EDGE_JIT] * (0.6 * w + 0.4 * w2));
        const float tlen = len * max(P[P_EDGE_TLEN], 1.0);
        float p = exp(-d / len) + P[P_EDGE_TAIL] * exp(-d / tlen);
        const float rows = P[P_PERF_ROWS];
        const bool row_here = rows < 0.5 || (rows < 1.5 ? k == 0u : k == 1u);
        if (P[P_EDGE_PA] > 0.0 && row_here) {
            const float dh = max(max(P[P_EDGE_P0] - d, d - P[P_EDGE_P1]), 0.0);
            p += P[P_EDGE_PA] * exp(-dh / tlen);
        }
        const float core = exp(-d / (len * max(P[P_EDGE_CORE], 1e-3)));
        e += str * ((1.0 - f) * p * rear + f * core * front);
    }
    return amp * e;
}

vec3 leak_kind_field(vec2 st, float kind, vec3 rear, vec3 front) {
    const float W = P[P_FILM_W], amp = P[P_LEAK_AMP], f = P[P_LEAK_FRONT];
    const float d_edge = max(P[P_LEAK_EDGE] < 0.5 ? st.y : W - st.y, 0.0);
    const float across = exp(-d_edge / max(P[P_LEAK_LAMBDA], 1e-3));
    float p, core;
    if (kind < 1.5) {
        // band: tilted a few degrees off square; soft on one flank, sharp on the other
        const float d = st.x - P[P_LEAK_SC] + P[P_LEAK_TILT] * (st.y - 0.5 * W);
        const float sig = d * P[P_LEAK_DIR] > 0.0 ? P[P_LEAK_SIG_A] : P[P_LEAK_SIG_B];
        p = exp(-0.5 * d * d / max(sig * sig, 1e-6));
        const float c = P[P_LEAK_CORE];
        core = exp(-0.5 * d * d / max(c * c, 1e-6));
    } else if (kind < 2.5) {
        // wash: from the leaking end into the frame, rising a little past the end
        const float x = (st.x - P[P_LEAK_SC]) * P[P_LEAK_DIR] + P[P_LEAK_TILT] * (st.y - 0.5 * W);
        const float len = max(P[P_LEAK_LEN], 1e-3);
        p = exp(-max(x, -0.5 * len) / len);
        core = p;
    } else {
        // spot: the 120 window, or off 120 a pinhole
        const vec2 dd = st - vec2(P[P_LEAK_SC], P[P_LEAK_ST]);
        const float ca = spk_cos(P[P_LEAK_TILT]), sa = spk_sin(P[P_LEAK_TILT]);
        const vec2 q = vec2(ca * dd.x + sa * dd.y, (ca * dd.y - sa * dd.x) / max(P[P_LEAK_SIG_B], 0.1));
        const float rho = length(q), th = rho > 0.0 ? spk_atan2(q.y, q.x) : 0.0, ph = 6.2831853 * P[P_LEAK_DIR];
        const float edge = 0.55 * spk_cos(2.0 * th + ph) + 0.30 * spk_cos(3.0 * th + 2.7 * ph + 1.3)
                         + 0.15 * spk_cos(5.0 * th + 4.1 * ph + 2.1);
        const float r = max(P[P_LEAK_LEN], 1e-3) * (1.0 + P[P_LEAK_CORE] * edge);
        const float u = rho / r;
        const float window = exp(-u * u * u * u);
        const float scatter = exp(-max(rho - r, 0.0) / max(P[P_LEAK_SIG_A], 1e-3));
        p = 8.0 * window + 0.125 * scatter;
        return amp * ((1.0 - f) * p * rear + f * p * front);
    }
    return amp * across * ((1.0 - f) * p * rear + f * core * front);
}

vec3 leak_field(vec2 st) {
    const float kind = P[P_LEAK_KIND];
    const vec3 rear = vec3(P[P_LEAK_REAR_R], P[P_LEAK_REAR_R + 1u], P[P_LEAK_REAR_R + 2u]);
    const vec3 front = vec3(P[P_LEAK_FRONT_R], P[P_LEAK_FRONT_R + 1u], P[P_LEAK_FRONT_R + 2u]);
    vec3 e = vec3(0.0);
    if (kind > 0.5) e = leak_kind_field(st, kind, rear, front);
    if (P[P_EDGE_AMP] > 0.0) e += leak_edge(st, rear, front, P[P_EDGE_AMP], P[P_EDGE_FRONT]);
    return e;
}

