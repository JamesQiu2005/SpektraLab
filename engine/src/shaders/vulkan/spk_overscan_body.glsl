// Ported from the pinned upstream overscan.metal; parameter indices and
// physical exposure/film/scan stages are shared with overscan.cpp.
layout(local_size_x = 256) in;
layout(set=0,binding=0,std430) readonly buffer Source { float v[]; } src;
layout(set=0,binding=1,std430) readonly buffer Parameters { float v[]; } params;
layout(set=0,binding=2,std430) readonly buffer Count { uint v[]; } count;
layout(set=0,binding=3,std430) buffer Destination { float v[]; } dst;
// overscan.metal -- RFC-032 §26-§27: the film outside the frame, as exposure.
//
// All three kernels read one parameter block `P` (floats; layout in
// `overscan.cpp`, `enum OsP`, which is the single source of the indices).
// Geometry is in film millimetres: `s` along the film, `t` across it, `t = 0`
// at the film's first long edge. A canvas pixel maps to film coordinates
// through the scan registration (a rotation and an offset), so the film --
// gate, perforations, edge print -- can sit a hair off square in the output,
// as it does in a real scan.


const uint P_CW = 0u;
const uint P_CH = 1u;
const uint P_PX = 2u;
const uint P_FW = 3u;
const uint P_FH = 4u;
const uint P_A00 = 5u;
const uint P_A01 = 6u;
const uint P_A10 = 7u;
const uint P_A11 = 8u;
const uint P_CS = 9u;
const uint P_CT = 10u;
const uint P_CU = 11u;
const uint P_CV = 12u;
const uint P_VERTICAL = 13u;
const uint P_GS0 = 14u;
const uint P_GT0 = 15u;
const uint P_GW = 16u;
const uint P_GH = 17u;
const uint P_CORNER = 18u;
const uint P_PENUMBRA = 19u;
const uint P_WOB_A = 20u;
const uint P_WOB_PH = 32u;
const uint P_FILM_W = 44u;
const uint P_FOG_AMP = 45u;
const uint P_FOG_WIDTH = 46u;
const uint P_FOG_SEED = 47u;
const uint P_FOG_PERIOD = 48u;
const uint P_FOG_R = 49u;
const uint P_FOG_G = 50u;
const uint P_FOG_B = 51u;
const uint P_N_LEAKS = 52u;
const uint P_PERFORATED = 83u;
const uint P_PERF_PITCH = 84u;
const uint P_PERF_W = 85u;
const uint P_PERF_H = 86u;
const uint P_PERF_EDGE = 87u;
const uint P_PERF_R = 88u;
const uint P_PERF_PHASE = 89u;
const uint P_HOLE_C = 90u;
const uint P_HOLE_M = 91u;
const uint P_HOLE_Y = 92u;
const uint P_FLARE_AMP = 93u;
const uint P_FLARE_WIDTH = 94u;
const uint P_GATE_R = 95u;
const uint P_N_Q = 99u;
const uint P_Q = 100u;
const uint P_ROUGH_AMP = 180u;
const uint P_ROUGH_PERIOD = 181u;
const uint P_ROUGH_SEED = 182u;
const uint P_HOLES_LIGHT = 183u;
const uint P_LIGHT_R = 184u;
const uint P_LIGHT_G = 185u;
const uint P_LIGHT_B = 186u;
const uint P_PERF_SEED = 187u;
const uint P_LIGHT_FALL = 188u;
const uint P_LIGHT_DIR = 189u;
const uint P_WALL_T = 190u;
const uint P_WALL_VS = 191u;
const uint P_WALL_VT = 192u;
const uint P_WALL_PAR = 193u;
const uint P_BASE_R = 194u;
const uint P_BASE_G = 195u;
const uint P_BASE_B = 196u;
const uint P_WALL_GLOW = 197u;
const uint P_WALL_SCATTER = 198u;
const uint P_CARRIER = 199u;
const uint P_LEAKS = 200u;
const uint P_PAIR_ADV = 260u;
const uint P_COUNT = 261u;
const uint kQStride = 10u;

vec2 canvas_to_film(float x, float y) {
    const float u = (x + 0.5f) * params.v[P_PX] - params.v[P_CU];
    const float v = (y + 0.5f) * params.v[P_PX] - params.v[P_CV];
    return vec2(params.v[P_A00] * u + params.v[P_A01] * v + params.v[P_CS], params.v[P_A10] * u + params.v[P_A11] * v + params.v[P_CT]);
}

uint hash_u(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
float hash_f(int i, uint seed) { return float(hash_u(uint(i) * 0x9E3779B9u ^ seed)) * (1.0f / 4294967295.0f); }
float value_noise(float x, uint seed) {
    const float i0 = floor(x), f = x - i0;
    const float w = f * f * (3.0f - 2.0f * f);
    return mix(hash_f(int(i0), seed), hash_f(int(i0) + 1, seed), w);
}

// Signed distance to a convex quad (either winding; a repeated vertex makes a
// triangle), negative inside.
float sd_quad(vec2 p, uint qbase) {
    vec2 v[4] = vec2[4](vec2(params.v[qbase + 0u], params.v[qbase + 1u]), vec2(params.v[qbase + 2u], params.v[qbase + 3u]), vec2(params.v[qbase + 4u], params.v[qbase + 5u]), vec2(params.v[qbase + 6u], params.v[qbase + 7u]));
    float d = dot(p - v[0], p - v[0]);
    float sgn = 1.0f;
    for (uint i = 0u, j = 3u; i < 4u; j = i, ++i) {
        const vec2 e = v[j] - v[i], w = p - v[i];
        const float ee = dot(e, e);
        if (ee < 1e-12f) continue;
        const vec2 b = w - e * clamp(dot(w, e) / ee, 0.0f, 1.0f);
        d = min(d, dot(b, b));
        const bool c0 = p.y >= v[i].y, c1 = p.y < v[j].y, c2 = e.x * w.y > e.y * w.x;
        if ((c0 && c1 && c2) || (!c0 && !c1 && !c2)) sgn = -sgn;
    }
    return sgn * sqrt(d);
}

// The gate (RFC-032 §29). Real gates are not symmetric rounded rectangles:
// each corner has its own radius, and a camera's gate carries its own
// features -- the eared sides of a 645 whose film rails stand proud, the
// shoulders of a 6x8 mask, the kicked-out corners of a 6x6 insert, a burr.
// Those come in as convex quads that add to or cut from the opening, and a
// fine roughness models the machined edge. On top, each side keeps the
// camera's low-frequency wobble (three harmonics, vanishing at the corners).
// Signed distance, negative inside, in mm.
float gate_sdf(vec2 st) {
    const float hw = 0.5f * params.v[P_GW], hh = 0.5f * params.v[P_GH];
    const float ds = st.x - (params.v[P_GS0] + hw), dt = st.y - (params.v[P_GT0] + hh);
    const float r = ds > 0.0f ? (dt > 0.0f ? params.v[P_GATE_R + 2u] : params.v[P_GATE_R + 1u])
                              : (dt > 0.0f ? params.v[P_GATE_R + 3u] : params.v[P_GATE_R + 0u]);
    const float qs = abs(ds) - (hw - r), qt = abs(dt) - (hh - r);
    float d = length(max(vec2(qs, qt), 0.0f)) + min(max(qs, qt), 0.0f) - r;
    uint side; float along, len;
    if (qs > qt) { side = ds > 0.0f ? 1u : 3u; along = dt + hh; len = 2.0f * hh; }
    else         { side = dt > 0.0f ? 2u : 0u; along = ds + hw; len = 2.0f * hw; }
    const float u = clamp(along / len, 0.0f, 1.0f);
    float w = 0.0f;
    for (uint k = 0; k < 3u; ++k)
        w += params.v[P_WOB_A + side * 3u + k] * sin(float(k + 1u) * 3.14159265358979323846 * u + params.v[P_WOB_PH + side * 3u + k]);
    d -= w * sin(3.14159265358979323846 * u);
    const uint nq = uint(params.v[P_N_Q]);
    for (uint k = 0; k < nq; ++k) {
        uint qbase = P_Q + kQStride * k;
        float dq;
        if (abs(params.v[qbase + 9u]) > 1.5f) {
            // an ellipse: centre q[0..1], radii q[2..3]; distance scaled by the
            // smaller radius, exact on the boundary, which is all a penumbra reads
            const vec2 r = max(vec2(params.v[qbase + 2u], params.v[qbase + 3u]), vec2(1e-4f));
            dq = (length((st - vec2(params.v[qbase + 0u], params.v[qbase + 1u])) / r) - 1.0f) * min(r.x, r.y);
        } else {
            dq = sd_quad(st, qbase) - params.v[qbase + 8u];
        }
        d = params.v[qbase + 9u] > 0.0f ? min(d, dq) : max(d, -dq);
    }
    if (params.v[P_ROUGH_AMP] > 0.0f) {
        const uint seed = uint(params.v[P_ROUGH_SEED]);
        const float per = max(params.v[P_ROUGH_PERIOD], 1e-3f);
        d += params.v[P_ROUGH_AMP] * (value_noise(st.x / per, seed) + value_noise(st.y / per, seed ^ 0x5bd1e995u) - 1.0f);
    }
    return d;
}

// The gate's shadow on the emulsion from a circular aperture: the lit fraction
// of a disc of radius r cut by a straight edge at signed distance d. Not a
// Gaussian -- a Gaussian has tails a real penumbra does not have.
float penumbra(float d, float r) {
    if (r <= 1e-6f) return d < 0.0f ? 1.0f : 0.0f;
    const float u = clamp(-d / r, -1.0f, 1.0f);
    return 0.5f + (u * sqrt(max(1.0f - u * u, 0.0f)) + asin(u)) * (1.0f / 3.14159265358979323846);
}

vec3 sample_frame(float fx, float fy, uint fw, uint fh) {
    fx = clamp(fx, 0.0f, float(fw) - 1.0f);
    fy = clamp(fy, 0.0f, float(fh) - 1.0f);
    const uint x0 = uint(floor(fx)), y0 = uint(floor(fy));
    const uint x1 = min(x0 + 1u, fw - 1u), y1 = min(y0 + 1u, fh - 1u);
    const float ax = fx - float(x0), ay = fy - float(y0);
    const uint i00 = 3u * (y0 * fw + x0), i01 = 3u * (y0 * fw + x1);
    const uint i10 = 3u * (y1 * fw + x0), i11 = 3u * (y1 * fw + x1);
    const vec3 a = vec3(src.v[i00], src.v[i00 + 1u], src.v[i00 + 2u]);
    const vec3 b = vec3(src.v[i01], src.v[i01 + 1u], src.v[i01 + 2u]);
    const vec3 c = vec3(src.v[i10], src.v[i10 + 1u], src.v[i10 + 2u]);
    const vec3 d = vec3(src.v[i11], src.v[i11 + 1u], src.v[i11 + 2u]);
    return mix(mix(a, b, ax), mix(c, d, ax), ay);
}

// ① + ② + the fog of ③: raw exposure on the film canvas.
#if defined(SPK_OVERSCAN_CANVAS)
void main() {
    const uint i = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
    if (i >= count.v[0]) return;
    const uint cw = uint(params.v[P_CW]);
    const vec2 st = canvas_to_film(float(i % cw), float(i / cw));
    const float W = params.v[P_FILM_W];
    vec3 e = vec3(0.0f);
    if (params.v[P_CARRIER] > 1.5f || (st.y >= 0.0f && st.y <= W)) {
        // A pair: past the middle of the gap, the second exposure of the same gate.
        vec2 sg = st;
        float shift = 0.0f;
        if (params.v[P_PAIR_ADV] > 0.0f && st.x > params.v[P_GS0] + 0.5f * (params.v[P_GW] + params.v[P_PAIR_ADV])) { shift = params.v[P_PAIR_ADV]; sg.x -= shift; }
        const float cov = penumbra(gate_sdf(sg), params.v[P_PENUMBRA]);
        if (cov > 0.0f) {
            const float px = params.v[P_PX];
            float fx, fy;
            if (params.v[P_VERTICAL] < 0.5f) { fx = (st.x - params.v[P_GS0]) / px - 0.5f; fy = (st.y - params.v[P_GT0]) / px - 0.5f; }
            else                      { fx = (params.v[P_GT0] + params.v[P_GH] - st.y) / px - 0.5f; fy = (st.x - params.v[P_GS0]) / px - 0.5f; }
            e += cov * sample_frame(fx, fy, uint(params.v[P_FW]), uint(params.v[P_FH]));
        }
        // Gate flare: the gate's bevelled edge reflects scene light onto the
        // film just outside the frame -- a thin line that follows the scene's
        // brightness along the edge (bright sky, bright line).
        const float d_gate = gate_sdf(sg);
        if (params.v[P_FLARE_AMP] > 0.0f && d_gate > -0.02f && d_gate < 6.0f * params.v[P_FLARE_WIDTH]) {
            const float px = params.v[P_PX];
            const float in_s = clamp(sg.x, params.v[P_GS0] + 0.12f, params.v[P_GS0] + params.v[P_GW] - 0.12f) + shift;
            const float in_t = clamp(st.y, params.v[P_GT0] + 0.12f, params.v[P_GT0] + params.v[P_GH] - 0.12f);
            float fx, fy;
            if (params.v[P_VERTICAL] < 0.5f) { fx = (in_s - params.v[P_GS0]) / px - 0.5f; fy = (in_t - params.v[P_GT0]) / px - 0.5f; }
            else                      { fx = (params.v[P_GT0] + params.v[P_GH] - in_t) / px - 0.5f; fy = (in_s - params.v[P_GS0]) / px - 0.5f; }
            const vec3 edge_light = sample_frame(fx, fy, uint(params.v[P_FW]), uint(params.v[P_FH]));
            const float prof = exp(-max(d_gate, 0.0f) / params.v[P_FLARE_WIDTH]);
            e += params.v[P_FLARE_AMP] * prof * edge_light;
        }
        // Edge fog: warm exposure decaying inward from each long edge, slowly
        // varying along the length; and the spool leaks, seeded blobs on an edge.
        // (clamped: the canvas reaches past the film, where there is none to fog)
        const float d_top = max(st.y, 0.0f), d_bot = max(W - st.y, 0.0f);
        const uint seed = uint(params.v[P_FOG_SEED]);
        const float period = max(params.v[P_FOG_PERIOD], 0.1f);
        const float nz = 0.6f * value_noise(st.x / period, seed) +
                         0.4f * value_noise(st.x / (0.37f * period), seed ^ 0xA5A5A5A5u);
        float fog = params.v[P_FOG_AMP] * exp(-min(d_top, d_bot) / max(params.v[P_FOG_WIDTH], 1e-3f)) * (0.3f + 0.7f * nz);
        const uint nl = uint(params.v[P_N_LEAKS]);
        for (uint k = 0; k < nl; ++k) {
            const uint b = P_LEAKS + 5u * k;
            const float dd = params.v[b + 1u] < 0.5f ? d_top : d_bot;
            const float ds = st.x - params.v[b];
            fog += params.v[b + 2u] * exp(-ds * ds / (2.0f * params.v[b + 3u] * params.v[b + 3u])) * exp(-dd / params.v[b + 4u]);
        }
        e += fog * vec3(params.v[P_FOG_R], params.v[P_FOG_G], params.v[P_FOG_B]);
    }
    dst.v[3u * i] = e.x;
    dst.v[3u * i + 1u] = e.y;
    dst.v[3u * i + 2u] = e.z;
}
#endif

// ③: a rasterised imprint (coverage, canvas-aligned) added as exposure.
// M = {x0, y0, mw, mh, cw, ch, e_r, e_g, e_b}.
#if defined(SPK_OVERSCAN_ADD_MASK)
void main() {
    const uint i = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
    if (i >= count.v[0]) return;
    const uint mw = uint(params.v[2]);
    const int x = int(params.v[0]) + int(i % mw), y = int(params.v[1]) + int(i / mw);
    if (x < 0 || y < 0 || x >= int(params.v[4]) || y >= int(params.v[5])) return;
    const float c = src.v[i];
    if (c <= 0.0f) return;
    const uint o = 3u * (uint(y) * uint(params.v[4]) + uint(x));
    dst.v[o] += c * params.v[6];
    dst.v[o + 1u] += c * params.v[7];
    dst.v[o + 2u] += c * params.v[8];
}
#endif

// The nearest perforation's signed distance (mm, negative inside). KS holes
// are punched to tight tolerances, not drawn: each hole sits a few microns
// off the ideal pitch and row, is a few microns off size, its corners are not
// all the same, and the punched edge is not a perfect line. `hole` returns the
// hole's own hash (row and index) for the scan's dust.
float perf_sdf(vec2 st, out uint hole) {
    const float W = params.v[P_FILM_W];
    const float pitch = params.v[P_PERF_PITCH], ph = params.v[P_PERF_PHASE];
    // The nearest hole: the cell is centred on it. (It began at the hole's
    // leading edge, so just outside that edge the distance was the previous
    // hole's -- 2.8 mm -- and that side had no shoulder, no flare, and a hard
    // cut where the other three sides were soft.)
    const float k = floor((st.x - ph - 0.5f * params.v[P_PERF_W]) / pitch + 0.5f);
    const bool top = st.y < 0.5f * W;
    const uint seed = uint(params.v[P_PERF_SEED]);
    hole = hash_u(uint(int(k) * 2 + (top ? 0 : 1)) * 0x9E3779B9u ^ seed);
    const float j0 = hash_f(int(hole & 0xFFFFu), seed ^ 0x1u) - 0.5f, j1 = hash_f(int(hole & 0xFFFFu), seed ^ 0x2u) - 0.5f;
    const float j2 = hash_f(int(hole & 0xFFFFu), seed ^ 0x3u) - 0.5f, j3 = hash_f(int(hole & 0xFFFFu), seed ^ 0x4u) - 0.5f;
    const float j4 = hash_f(int(hole & 0xFFFFu), seed ^ 0x5u) - 0.5f;
    const float wa = params.v[P_PERF_W] + 0.016f * j2, hc = params.v[P_PERF_H] + 0.016f * j3;
    const float r = clamp(params.v[P_PERF_R] + 0.08f * j4, 0.3f, 0.6f);
    const float sc = ph + k * pitch + 0.5f * params.v[P_PERF_W] + 0.020f * j0;
    const float tc = (top ? params.v[P_PERF_EDGE] + 0.5f * params.v[P_PERF_H] : W - params.v[P_PERF_EDGE] - 0.5f * params.v[P_PERF_H]) + 0.024f * j1;
    const vec2 q = abs(vec2(st.x - sc, st.y - tc)) - vec2(0.5f * wa - r, 0.5f * hc - r);
    float d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
    // the punched edge: each hole's own roughness, 1-4 microns
    const float rough = 0.001f + 0.003f * hash_f(int(hole & 0xFFFFu), seed ^ 0x6u);
    d += rough * (value_noise(st.x / 0.05f, seed ^ 0x77u) + value_noise(st.y / 0.05f, seed ^ 0x99u) - 1.0f) * 2.0f;
    // a burr or a chip on about one hole in four: a 20-50 micron bump on the
    // edge, into the hole or out of it, somewhere around its outline
    if (hash_f(int(hole & 0xFFFFu), seed ^ 0x7u) < 0.25f) {
        const float ang = 6.2831853f * hash_f(int(hole & 0xFFFFu), seed ^ 0x8u);
        const vec2 pb = vec2(sc, tc) + vec2(cos(ang) * 0.5f * wa, sin(ang) * 0.5f * hc);
        const float sig = 0.020f + 0.030f * hash_f(int(hole & 0xFFFFu), seed ^ 0x9u);
        const float amp = (hash_f(int(hole & 0xFFFFu), seed ^ 0xAu) < 0.5f ? -1.0f : 1.0f) *
                          (0.006f + 0.010f * hash_f(int(hole & 0xFFFFu), seed ^ 0xBu));
        d += amp * exp(-dot(st - pb, st - pb) / (sig * sig));
    }
    return d;
}

// How soft a perforation's edge is in a scan, as the sigma of a Gaussian edge
// in film millimetres. Measured on the owner's strips in reference_film/135
// (2026-10-04): across 61-80 hole edges on each of eight scans the edge takes
// 44-71 microns to go from 10 % to 90 % of the hole's light (median 59), at
// 21-32 px/mm -- where this engine's one-pixel edge took 34, and at the full
// tier of a 45 MP frame 5: a knife. Less the scans' own pixels that is a
// sigma of 17 microns: the scanner's lens, and a cut wall 0.13 mm deep that
// is not all in focus at once.
const float kHoleEdgeSigma = 0.017f;

// erf, Abramowitz and Stegun 7.1.26 (|error| < 1.5e-7).
float erf_as(float x) {
    const float t = 1.0f / (1.0f + 0.3275911f * abs(x));
    const float y = 1.0f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t + 0.254829592f) * t * exp(-x * x);
    return x < 0.0f ? -y : y;
}

// Where there is film: 1 on the strip, 0 in the perforations and past its edges.
float film_alpha(vec2 st) {
    const float W = params.v[P_FILM_W], px = params.v[P_PX];
    // (with no carrier the canvas is the film's width, and the film runs on
    // under the corners a tilted scan carries past its edge)
    float a = params.v[P_CARRIER] > 1.5f ? 1.0f : clamp(min(st.y, W - st.y) / px + 0.5f, 0.0f, 1.0f);
    if (params.v[P_PERFORATED] > 0.5f) {
        uint hole;
        // The hole's edge as the scan resolves it: the measured softness, and
        // the pixel's own width (a one-pixel ramp is a sigma of 0.31 px), so a
        // small render is no softer than it was and a large one no harder
        // than film.
        const float sigma = sqrt(kHoleEdgeSigma * kHoleEdgeSigma + 0.0961f * px * px);
        a *= 0.5f + 0.5f * erf_as(perf_sdf(st, hole) / (1.41421356f * sigma));
    }
    return a;
}

// ④: where there is no film -- the perforations, and outside the strip --
// the negative's density goes to the cmy that cancels this film's base, so
// the enlarger or the scanner sees clear light.
#if defined(SPK_OVERSCAN_FILM_PRESENT)
void main() {
    const uint i = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
    if (i >= count.v[0]) return;
    const uint cw = uint(params.v[P_CW]);
    const float a = film_alpha(canvas_to_film(float(i % cw), float(i / cw)));
    const vec3 c = vec3(src.v[3u * i], src.v[3u * i + 1u], src.v[3u * i + 2u]);
    const vec3 hole = vec3(params.v[P_HOLE_C], params.v[P_HOLE_M], params.v[P_HOLE_Y]);
    const vec3 r3 = a * c + (1.0f - a) * hole;
    dst.v[3u * i] = r3.x;
    dst.v[3u * i + 1u] = r3.y;
    dst.v[3u * i + 2u] = r3.z;
}
#endif

// ⑤ (RFC-032 §30.5, §31): the scan's view of the holes. Inside a hole: the
// picture's own white (holes = white) or a black backing (holes = black).
// Around it, the cut wall: the punch shears the top of the base clean and
// fractures the rest at a slant, and a scan seen a little off-axis sees the
// wall on the side away from its axis. Seen from above, that is a band where
// the base thins from full to nothing -- brown through the orange mask on a
// white hole, a dim warm rim around a black one. Each hole's slant is its
// own; the viewing tilt and parallax are the scan's. Linear output RGB,
// after the scanner's blur and sharpening (the edge's softness is `film_alpha`'s).
#if defined(SPK_OVERSCAN_LIGHT)
void main() {
    const uint i = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * gl_WorkGroupSize.x) + gl_GlobalInvocationID.x;
    if (i >= count.v[0]) return;
    const uint cw = uint(params.v[P_CW]);
    const vec2 st = canvas_to_film(float(i % cw), float(i / cw));
    const float a = film_alpha(st);
    const bool white = params.v[P_HOLES_LIGHT] > 0.5f;
    vec3 light = vec3(params.v[P_LIGHT_R], params.v[P_LIGHT_G], params.v[P_LIGHT_B]);
    vec3 c = vec3(src.v[3u * i], src.v[3u * i + 1u], src.v[3u * i + 2u]);
    if (params.v[P_PERFORATED] > 0.5f) {
        uint hole;
        const float d = perf_sdf(st, hole);
        // The cut is not a perfectly vertical knife: the base is a little rounded
        // where the punch went through, and a scan sees that as a soft shoulder
        // just outside the hole -- measured on the owner's reference at 1-2 px
        // of 0.03 mm, lifting the black by ~1-5 % (linear), a faint olive-warm,
        // and not the same on every side or every hole. Inside, a few edges
        // carry a faint cream line. Subtle on purpose (RFC-032 §31.5).
        const uint seed = uint(params.v[P_PERF_SEED]);
        const int h = int(hole & 0xFFFFu);
        if (d > -0.03f && d < 0.15f) {
            const float e = 0.003f;
            uint hh;
            const vec2 g = vec2(perf_sdf(st + vec2(e, 0), hh) - perf_sdf(st - vec2(e, 0), hh),
                                    perf_sdf(st + vec2(0, e), hh) - perf_sdf(st - vec2(0, e), hh));
            const vec2 nrm = g / max(length(g), 1e-6f);
            const vec2 vdir = vec2(params.v[P_WALL_VS], params.v[P_WALL_VT]);
            // how much this stretch of this hole's outline shows: per hole, patchy
            // along the outline, a little more on the side the scan leans to
            const float per_hole = 0.4f + 0.6f * hash_f(h, seed ^ 0xE1u);
            const float patch_factor = smoothstep(0.25f, 0.75f, 0.5f * (value_noise(st.x / 0.35f, seed ^ uint(h)) +
                                                                 value_noise(st.y / 0.35f, seed ^ uint(h) ^ 0x3Cu)));
            const float side = 0.6f + 0.8f * max(0.0f, dot(nrm, vdir));
            const float k = per_hole * patch_factor * side;
            // the base's tint, mostly washed out
            const vec3 tint = mix(vec3(1.0f), vec3(params.v[P_BASE_R], params.v[P_BASE_G], params.v[P_BASE_B]), 0.3f);
            const float lam = params.v[P_WALL_SCATTER];
            if (d >= 0.0f) {
                const float lift = params.v[P_WALL_GLOW] * k * exp(-d / lam);
                c += lift * tint * (white ? light : vec3(1.0f));
            } else if (white && hash_f(h, seed ^ 0xE4u) < 0.5f) {
                light *= 1.0f - 0.12f * k * (1.0f - tint) * exp(d / 0.012f);
            }
        }
        if (white && d >= 0.0f) {
            // a faint flare from the hole's light into the film, on some holes
            const float fl = 0.012f * hash_f(h, seed ^ 0xC4u) * step(0.5f, hash_f(h, seed ^ 0xC5u));
            c += fl * exp(-d / 0.025f) * light;
        }
    }
    // Past the film's long edges is the scan's carrier, not a hole: black, or
    // the scan's open light.
    const float W = params.v[P_FILM_W], px = params.v[P_PX];
    const float on_strip = params.v[P_CARRIER] > 1.5f ? 1.0f : clamp(min(st.y, W - st.y) / px + 0.5f, 0.0f, 1.0f);
    const float in_film = on_strip > 0.0f ? a / on_strip : 0.0f;
    // Metal mix preserves these physical endpoints. Explicit precise terms
    // prevent GLSL mix lowering to x + (y-x)*a, which rounded intact film
    // differently when switching only the carrier outside it.
    precise vec3 film_view = light * (1.0f - in_film) + c * in_film;
    precise vec3 r3 = vec3(params.v[P_CARRIER]) * (1.0f - on_strip) + film_view * on_strip;
    dst.v[3u * i] = r3.x;
    dst.v[3u * i + 1u] = r3.y;
    dst.v[3u * i + 2u] = r3.z;
}
#endif
