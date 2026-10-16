// Film Edge (overscan) gates: spk_overscan_canvas, spk_overscan_film_present
// and spk_overscan_light against a float64 transcription of overscan.metal,
// over parameter blocks laid out the way overscan.cpp lays them out -- 135 and
// 120, perforated and not, white and black holes, every carrier, a half-frame
// pair, fine windows on a gate corner, a hole and the film's edge, a canvas
// copied without resampling, and a canvas one past the dispatch fold.
// This is local kernel validation, not a claim of whole-frame Metal parity.
//
// How the comparison is made. The reference is float64 except where float32's
// bits decide something: the scan registration (the kernels compute it
// `precise` and the reference mirrors it -- it puts each pixel on one side or
// the other of the film's edge, a hole's cell, the flare's band), the hashes
// (a hole's burr and flare are a float32 hash compared against 0.25 and 0.5),
// and erf beside -1 (film_alpha). Away from edges the GPU must agree to kRel;
// a frame sample also gets the bilinear's slope across float32's rounding of
// the sample position (Out::slack). What is left is the kernel's float32
// arithmetic inside a coordinate -- a hole's centre, the gate's half-width, a
// noise argument -- which moves an edge by a few ulps of the coordinate, and
// at a steep edge that is far more than kRel. So a value that misses the bar
// must lie within the reference's range over the box +-eps around the pixel's
// film coordinate, eps = kEnvelopeUlps float32 ulps at the canvas's largest
// coordinate (3.1e-5 mm on 135, 6.1e-5 on 120). A wrong hole, a misplaced
// edge or a sample off by a pixel moves values by microns to millimetres of
// film; an edge that rounded differently moves them by hundredths of a micron.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <initializer_list>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::Gpu;

// overscan.metal's `enum OsP`, the single layout overscan.cpp fills.
enum : unsigned {
    P_CW = 0, P_CH, P_PX, P_FW, P_FH,
    P_A00, P_A01, P_A10, P_A11, P_CS, P_CT, P_CU, P_CV,
    P_VERTICAL,
    P_GS0, P_GT0, P_GW, P_GH, P_CORNER, P_PENUMBRA,
    P_WOB_A = 20, P_WOB_PH = 32,
    P_FILM_W = 44, P_FOG_AMP, P_FOG_WIDTH, P_FOG_SEED, P_FOG_PERIOD,
    P_FOG_R, P_FOG_G, P_FOG_B,
    P_N_LEAKS = 52,
    P_PERFORATED = 83, P_PERF_PITCH, P_PERF_W, P_PERF_H, P_PERF_EDGE, P_PERF_R, P_PERF_PHASE,
    P_HOLE_C = 90, P_HOLE_M, P_HOLE_Y,
    P_FLARE_AMP = 93, P_FLARE_WIDTH,
    P_GATE_R = 95,
    P_N_Q = 99, P_Q = 100,
    P_ROUGH_AMP = 180, P_ROUGH_PERIOD, P_ROUGH_SEED,
    P_HOLES_LIGHT = 183, P_LIGHT_R, P_LIGHT_G, P_LIGHT_B,
    P_PERF_SEED = 187, P_LIGHT_FALL, P_LIGHT_DIR,
    P_WALL_T = 190, P_WALL_VS, P_WALL_VT, P_WALL_PAR, P_BASE_R, P_BASE_G, P_BASE_B, P_WALL_GLOW, P_WALL_SCATTER,
    P_CARRIER = 199,
    P_LEAKS = 200,
    P_PAIR_ADV = 260,
    P_COUNT = 261
};
constexpr unsigned kQStride = 10;
using Block = std::array<float, P_COUNT>;

// The bars, measured on an RTX 3070 (2026-10-16); the run prints its own.
// kRel: float32 arithmetic, 8 ulps at 1.0. The canvas away from samples and
//   edges measured 9e-8; the film presence and light reach 2.9e-6 and 1.1e-6
//   only beside hole edges, where whatever misses goes to the envelope.
// kSampleUlps: how far float32 carries fx = (s - s0) / px - 0.5 from its value
//   -- a subtraction, GLSL's division (2.5 ulps allowed), the half pixel. At 1
//   76,695 canvas values fell to the envelope, at 4 15,969: the slack is what
//   keeps the envelope for edges, not grain.
// kEnvelopeUlps: every value passes at 2; at 1 the light kernel's first miss
//   is beside a hole on the half-frame pair. 8 is the margin.
constexpr double kRel = 1e-6;
constexpr double kSampleUlps = 4;
constexpr double kEnvelopeUlps = 8;
constexpr float kGuard = -654321.0f;
constexpr size_t kGuards = 19;
constexpr double kPi = 3.14159265358979323846;

uint32_t hash_u(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}

// float32's spacing at |v|.
double ulpf(double v) {
    const double a = std::abs(v);
    if (!(a >= 0x1p-126)) return 0x1p-149;
    int e;
    std::frexp(a, &e);                   // a = m 2^e, m in [0.5, 1)
    return std::ldexp(1.0, e - 24);
}

double clampd(double x, double lo, double hi) { return std::min(std::max(x, lo), hi); }
// Metal's mix, x + (y - x) a.
double mixd(double x, double y, double a) { return x + (y - x) * a; }
double smoothstepd(double e0, double e1, double x) {
    const double t = clampd((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

struct V2 { double x, y; };
V2 operator+(V2 a, V2 b) { return {a.x + b.x, a.y + b.y}; }
V2 operator-(V2 a, V2 b) { return {a.x - b.x, a.y - b.y}; }
V2 operator*(V2 a, double s) { return {a.x * s, a.y * s}; }
double dot(V2 a, V2 b) { return a.x * b.x + a.y * b.y; }
double length(V2 a) { return std::sqrt(dot(a, a)); }

// P read as float64: the kernels' float32 parameters, exactly. Metal's float
// literals are kept below with their `f`, so each is the same float32 value
// while the arithmetic around it is float64.
struct PD {
    const float* f;
    double operator[](unsigned k) const { return f[k]; }
};

// ---------------------------------------------------------------------------
// The reference: overscan.metal, line for line.
// ---------------------------------------------------------------------------

struct V2f { float x, y; };
// The kernels compute this `precise`: every product and sum rounded on its
// own, in this order, each correctly as Vulkan requires. x64 MSVC (SSE2, no
// contraction) and GCC/Clang without -mfma do the same with float32
// operands, so this is the kernel's coordinate.
V2f canvas_to_film_f(float x, float y, const float* P) {
    const float u = (x + 0.5f) * P[P_PX] - P[P_CU];
    const float v = (y + 0.5f) * P[P_PX] - P[P_CV];
    const float s = P[P_A00] * u + P[P_A01] * v + P[P_CS];
    const float t = P[P_A10] * u + P[P_A11] * v + P[P_CT];
    return {s, t};
}

// float32, as the kernels compute it: a hole's burr and flare are this
// compared against 0.25 and 0.5.
double hash_f(int i, uint32_t seed) {
    return double(float(hash_u(uint32_t(i) * 0x9E3779B9u ^ seed)) * (1.0f / 4294967295.0f));
}
double value_noise(double x, uint32_t seed) {
    const double i0 = std::floor(x), f = x - i0;
    const double w = f * f * (3.0f - 2.0f * f);
    return mixd(hash_f(int(i0), seed), hash_f(int(i0) + 1, seed), w);
}

// What a case's pixels exercised, so a green run cannot be one that never
// reached a branch (AGENTS.md trap 16).
struct Coverage {
    size_t partial_gate = 0, frame_interior = 0, flare = 0, off_film = 0, pair_second = 0, leaks = 0;
    size_t hole_edge = 0, strip_edge = 0, burr = 0, wall_lift = 0, wall_shade = 0, hole_flare = 0, carrier = 0;
};
Coverage coverage;

double sd_quad(V2 p, const PD& P, unsigned qb) {
    const V2 v[4] = {{P[qb], P[qb + 1]}, {P[qb + 2], P[qb + 3]}, {P[qb + 4], P[qb + 5]}, {P[qb + 6], P[qb + 7]}};
    double d = dot(p - v[0], p - v[0]);
    double sgn = 1.0;
    for (unsigned i = 0, j = 3; i < 4; j = i, ++i) {
        const V2 e = v[j] - v[i], w = p - v[i];
        const double ee = dot(e, e);
        if (ee < 1e-12f) continue;
        const V2 b = w - e * clampd(dot(w, e) / ee, 0.0, 1.0);
        d = std::min(d, dot(b, b));
        const bool c0 = p.y >= v[i].y, c1 = p.y < v[j].y, c2 = e.x * w.y > e.y * w.x;
        if ((c0 && c1 && c2) || (!c0 && !c1 && !c2)) sgn = -sgn;
    }
    return sgn * std::sqrt(d);
}

double gate_sdf(V2 st, const PD& P) {
    constexpr double kPiF = 3.14159265358979323846f;     // Metal's M_PI_F
    const double hw = 0.5f * P[P_GW], hh = 0.5f * P[P_GH];
    const double ds = st.x - (P[P_GS0] + hw), dt = st.y - (P[P_GT0] + hh);
    const double r = ds > 0.0 ? (dt > 0.0 ? P[P_GATE_R + 2] : P[P_GATE_R + 1])
                              : (dt > 0.0 ? P[P_GATE_R + 3] : P[P_GATE_R + 0]);
    const double qs = std::abs(ds) - (hw - r), qt = std::abs(dt) - (hh - r);
    const double ms = std::max(qs, 0.0), mt = std::max(qt, 0.0);
    double d = std::sqrt(ms * ms + mt * mt) + std::min(std::max(qs, qt), 0.0) - r;
    unsigned side;
    double along, len;
    if (qs > qt) { side = ds > 0.0 ? 1 : 3; along = dt + hh; len = 2.0f * hh; }
    else         { side = dt > 0.0 ? 2 : 0; along = ds + hw; len = 2.0f * hw; }
    const double u = clampd(along / len, 0.0, 1.0);
    double w = 0.0;
    for (unsigned k = 0; k < 3; ++k)
        w += P[P_WOB_A + side * 3 + k] * std::sin(double(k + 1) * kPiF * u + P[P_WOB_PH + side * 3 + k]);
    d -= w * std::sin(kPiF * u);
    const unsigned nq = unsigned(P[P_N_Q]);
    for (unsigned k = 0; k < nq; ++k) {
        const unsigned qb = P_Q + kQStride * k;
        double dq;
        if (std::abs(P[qb + 9]) > 1.5f) {
            const double rs = std::max(P[qb + 2], double(1e-4f)), rt = std::max(P[qb + 3], double(1e-4f));
            dq = (length({(st.x - P[qb]) / rs, (st.y - P[qb + 1]) / rt}) - 1.0f) * std::min(rs, rt);
        } else {
            dq = sd_quad(st, P, qb) - P[qb + 8];
        }
        d = P[qb + 9] > 0.0f ? std::min(d, dq) : std::max(d, -dq);
    }
    if (P[P_ROUGH_AMP] > 0.0f) {
        const uint32_t seed = uint32_t(P[P_ROUGH_SEED]);
        const double per = std::max(P[P_ROUGH_PERIOD], double(1e-3f));
        d += P[P_ROUGH_AMP] * (value_noise(st.x / per, seed) + value_noise(st.y / per, seed ^ 0x5bd1e995u) - 1.0f);
    }
    return d;
}

double penumbra(double d, double r) {
    constexpr double kInvPiF = 1.0f / 3.14159265358979323846f;   // Metal's (1.0f / M_PI_F)
    if (r <= 1e-6f) return d < 0.0 ? 1.0 : 0.0;
    const double u = clampd(-d / r, -1.0, 1.0);
    return 0.5f + (u * std::sqrt(std::max(1.0 - u * u, 0.0)) + std::asin(u)) * kInvPiF;
}

double perf_sdf(V2 st, const PD& P, uint32_t& hole, Coverage* cv) {
    const double W = P[P_FILM_W];
    const double pitch = P[P_PERF_PITCH], ph = P[P_PERF_PHASE];
    const double k = std::floor((st.x - ph - 0.5f * P[P_PERF_W]) / pitch + 0.5f);
    const bool top = st.y < 0.5f * W;
    const uint32_t seed = uint32_t(P[P_PERF_SEED]);
    hole = hash_u(uint32_t(int(k) * 2 + (top ? 0 : 1)) * 0x9E3779B9u ^ seed);
    const int h = int(hole & 0xFFFFu);
    const double j0 = hash_f(h, seed ^ 0x1u) - 0.5f, j1 = hash_f(h, seed ^ 0x2u) - 0.5f;
    const double j2 = hash_f(h, seed ^ 0x3u) - 0.5f, j3 = hash_f(h, seed ^ 0x4u) - 0.5f;
    const double j4 = hash_f(h, seed ^ 0x5u) - 0.5f;
    const double wa = P[P_PERF_W] + 0.016f * j2, hc = P[P_PERF_H] + 0.016f * j3;
    const double r = clampd(P[P_PERF_R] + 0.08f * j4, 0.3f, 0.6f);
    const double sc = ph + k * pitch + 0.5f * P[P_PERF_W] + 0.020f * j0;
    const double tc = (top ? P[P_PERF_EDGE] + 0.5f * P[P_PERF_H] : W - P[P_PERF_EDGE] - 0.5f * P[P_PERF_H]) + 0.024f * j1;
    const double qx = std::abs(st.x - sc) - (0.5f * wa - r), qy = std::abs(st.y - tc) - (0.5f * hc - r);
    const double mx = std::max(qx, 0.0), my = std::max(qy, 0.0);
    double d = std::sqrt(mx * mx + my * my) + std::min(std::max(qx, qy), 0.0) - r;
    const double rough = 0.001f + 0.003f * hash_f(h, seed ^ 0x6u);
    d += rough * (value_noise(st.x / 0.05f, seed ^ 0x77u) + value_noise(st.y / 0.05f, seed ^ 0x99u) - 1.0f) * 2.0f;
    if (hash_f(h, seed ^ 0x7u) < 0.25f) {
        if (cv) ++cv->burr;
        const double ang = 6.2831853f * hash_f(h, seed ^ 0x8u);
        const V2 pb = {sc + std::cos(ang) * 0.5f * wa, tc + std::sin(ang) * 0.5f * hc};
        const double sig = 0.020f + 0.030f * hash_f(h, seed ^ 0x9u);
        const double amp = (hash_f(h, seed ^ 0xAu) < 0.5f ? -1.0 : 1.0) * (0.006f + 0.010f * hash_f(h, seed ^ 0xBu));
        d += amp * std::exp(-dot(st - pb, st - pb) / (sig * sig));
    }
    return d;
}

double erf_as(double x) {
    const double t = 1.0f / (1.0f + 0.3275911f * std::abs(x));
    const double y = 1.0f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t +
                             0.254829592f) * t * std::exp(-x * x);
    return x < 0.0 ? -y : y;
}

double film_alpha(V2 st, const PD& P, Coverage* cv) {
    constexpr double kHoleEdgeSigma = 0.017f;
    const double W = P[P_FILM_W], px = P[P_PX];
    const double strip = P[P_CARRIER] > 1.5f ? 1.0 : clampd(std::min(st.y, W - st.y) / px + 0.5f, 0.0, 1.0);
    if (cv && strip > 0.0 && strip < 1.0) ++cv->strip_edge;
    double a = strip;
    if (P[P_PERFORATED] > 0.5f) {
        uint32_t hole;
        const double sigma = std::sqrt(kHoleEdgeSigma * kHoleEdgeSigma + 0.0961f * px * px);
        // float32 holds erf to 2^-24 beside -1, so deep in a hole the kernel's
        // alpha is exactly 0 where float64's is 1e-13 -- and 0 x inf is NaN,
        // not inf. The rounding decides that and nothing else measurable.
        const double y = float(erf_as(perf_sdf(st, P, hole, cv) / (1.41421356f * sigma)));
        const double hf = 0.5f + 0.5f * y;
        if (cv && hf > 0.02 && hf < 0.98) ++cv->hole_edge;
        a *= hf;
    }
    return a;
}

// ---------------------------------------------------------------------------
// Cases.
// ---------------------------------------------------------------------------

enum Which { kCanvas, kPresent, kLight };
const char* const kKernel[3] = {"spk_overscan_canvas", "spk_overscan_film_present", "spk_overscan_light"};

struct Case {
    std::string name;
    Block P{};
    uint32_t cw = 0, ch = 0;
    std::vector<float> frame;            // packed RGB, P_FW x P_FH
    uint32_t seed = 1;                   // the cmy / rgb inputs
    bool exact = false;                  // the canvas and the film presence must be bit-exact
    bool sampled = false;                // check a subset (the fold case)
};

// The film-presence and light inputs, from (case, pixel, channel) alone so
// the reference never needs the 200 MB arrays of the fold case. Every 7919th
// pixel is NaN, +inf, -inf: the kernels pass pixel values only through mix and
// multiply-add, so those must come out where the reference puts them.
float pixel_input(const Case& c, Which which, size_t i, unsigned ch) {
    if (i % 7919 == 13) {
        const float inf = std::numeric_limits<float>::infinity();
        return ch == 0 ? std::numeric_limits<float>::quiet_NaN() : ch == 1 ? inf : -inf;
    }
    const uint32_t h = hash_u(uint32_t(3 * i + ch) * 0x9E3779B9u ^ (c.seed * 0x85ebca6bu + unsigned(which)));
    const float lo = which == kPresent ? -0.1f : 0.0f, hi = which == kPresent ? 3.0f : 1.2f;
    return lo + (hi - lo) * float(h >> 8) * (1.0f / 16777216.0f);
}

// A reference value, and what the bar adds to kRel for it (a frame sample's).
struct Out { std::array<double, 3> v{}, slack{}; };

struct Sample { std::array<double, 3> v{}, slack{}; };
// The bilinear, Metal's mix order. Its slack: float32 carries fx and fy to
// about kSampleUlps ulps of themselves, so the result may differ by the
// bilinear's slope across that much.
Sample sample_frame(const std::vector<float>& f, double fx, double fy, uint32_t fw, uint32_t fh) {
    const double ex = kSampleUlps * ulpf(fx), ey = kSampleUlps * ulpf(fy);
    fx = clampd(fx, 0.0, double(fw) - 1.0);
    fy = clampd(fy, 0.0, double(fh) - 1.0);
    const uint32_t x0 = uint32_t(std::floor(fx)), y0 = uint32_t(std::floor(fy));
    const uint32_t x1 = std::min(x0 + 1u, fw - 1u), y1 = std::min(y0 + 1u, fh - 1u);
    const double ax = fx - x0, ay = fy - y0;
    const size_t i00 = 3 * (size_t(y0) * fw + x0), i01 = 3 * (size_t(y0) * fw + x1);
    const size_t i10 = 3 * (size_t(y1) * fw + x0), i11 = 3 * (size_t(y1) * fw + x1);
    Sample s;
    for (unsigned c = 0; c < 3; ++c) {
        const double a = f[i00 + c], b = f[i01 + c], cc = f[i10 + c], d = f[i11 + c];
        const double top = mixd(a, b, ax), bot = mixd(cc, d, ax);
        s.v[c] = mixd(top, bot, ay);
        s.slack[c] = std::abs((b - a) * (1.0 - ay) + (d - cc) * ay) * ex + std::abs(bot - top) * ey;
    }
    return s;
}

Out canvas_ref(const Case& c, V2 st, size_t, Coverage* cv) {
    const PD P{c.P.data()};
    const double W = P[P_FILM_W];
    Out o;
    if (!(P[P_CARRIER] > 1.5f || (st.y >= 0.0 && st.y <= W))) {
        if (cv) ++cv->off_film;
        return o;
    }
    V2 sg = st;
    double shift = 0.0;
    if (P[P_PAIR_ADV] > 0.0f && st.x > P[P_GS0] + 0.5f * (P[P_GW] + P[P_PAIR_ADV])) {
        shift = P[P_PAIR_ADV];
        sg.x -= shift;
        if (cv) ++cv->pair_second;
    }
    const uint32_t fw = uint32_t(P[P_FW]), fh = uint32_t(P[P_FH]);
    const double px = P[P_PX];
    const double cov = penumbra(gate_sdf(sg, P), P[P_PENUMBRA]);
    if (cov > 0.0) {
        double fx, fy;
        if (P[P_VERTICAL] < 0.5f) { fx = (st.x - P[P_GS0]) / px - 0.5f; fy = (st.y - P[P_GT0]) / px - 0.5f; }
        else                      { fx = (P[P_GT0] + P[P_GH] - st.y) / px - 0.5f; fy = (st.x - P[P_GS0]) / px - 0.5f; }
        if (cv && cov < 1.0) ++cv->partial_gate;
        if (cv && fx > 0.0 && fx < fw - 1.0 && fy > 0.0 && fy < fh - 1.0) ++cv->frame_interior;
        const Sample s = sample_frame(c.frame, fx, fy, fw, fh);
        for (unsigned k = 0; k < 3; ++k) { o.v[k] += cov * s.v[k]; o.slack[k] += cov * s.slack[k]; }
    }
    const double d_gate = gate_sdf(sg, P);
    if (P[P_FLARE_AMP] > 0.0f && d_gate > -0.02f && d_gate < 6.0f * P[P_FLARE_WIDTH]) {
        if (cv) ++cv->flare;
        const double in_s = clampd(sg.x, P[P_GS0] + 0.12f, P[P_GS0] + P[P_GW] - 0.12f) + shift;
        const double in_t = clampd(st.y, P[P_GT0] + 0.12f, P[P_GT0] + P[P_GH] - 0.12f);
        double fx, fy;
        if (P[P_VERTICAL] < 0.5f) { fx = (in_s - P[P_GS0]) / px - 0.5f; fy = (in_t - P[P_GT0]) / px - 0.5f; }
        else                      { fx = (P[P_GT0] + P[P_GH] - in_t) / px - 0.5f; fy = (in_s - P[P_GS0]) / px - 0.5f; }
        const Sample s = sample_frame(c.frame, fx, fy, fw, fh);
        const double prof = std::exp(-std::max(d_gate, 0.0) / P[P_FLARE_WIDTH]);
        for (unsigned k = 0; k < 3; ++k) {
            o.v[k] += P[P_FLARE_AMP] * prof * s.v[k];
            o.slack[k] += P[P_FLARE_AMP] * prof * s.slack[k];
        }
    }
    const double d_top = std::max(st.y, 0.0), d_bot = std::max(W - st.y, 0.0);
    const uint32_t seed = uint32_t(P[P_FOG_SEED]);
    const double period = std::max(P[P_FOG_PERIOD], double(0.1f));
    const double nz = 0.6f * value_noise(st.x / period, seed) +
                      0.4f * value_noise(st.x / (0.37f * period), seed ^ 0xA5A5A5A5u);
    double fog = P[P_FOG_AMP] * std::exp(-std::min(d_top, d_bot) / std::max(P[P_FOG_WIDTH], double(1e-3f))) *
                 (0.3f + 0.7f * nz);
    const unsigned nl = unsigned(P[P_N_LEAKS]);
    if (cv && nl) ++cv->leaks;
    for (unsigned k = 0; k < nl; ++k) {
        const unsigned b = P_LEAKS + 5 * k;
        const double dd = P[b + 1] < 0.5f ? d_top : d_bot;
        const double ds = st.x - P[b];
        fog += P[b + 2] * std::exp(-ds * ds / (2.0f * P[b + 3] * P[b + 3])) * std::exp(-dd / P[b + 4]);
    }
    for (unsigned k = 0; k < 3; ++k) o.v[k] += fog * P[P_FOG_R + k];
    return o;
}

Out present_ref(const Case& c, V2 st, size_t i, Coverage* cv) {
    const PD P{c.P.data()};
    const double a = film_alpha(st, P, cv);
    Out o;
    for (unsigned k = 0; k < 3; ++k)
        o.v[k] = a * double(pixel_input(c, kPresent, i, k)) + (1.0f - a) * P[P_HOLE_C + k];
    return o;
}

Out light_ref(const Case& c, V2 st, size_t i, Coverage* cv) {
    const PD P{c.P.data()};
    const double a = film_alpha(st, P, cv);
    const bool white = P[P_HOLES_LIGHT] > 0.5f;
    std::array<double, 3> light = {P[P_LIGHT_R], P[P_LIGHT_G], P[P_LIGHT_B]}, col;
    for (unsigned k = 0; k < 3; ++k) col[k] = pixel_input(c, kLight, i, k);
    if (P[P_PERFORATED] > 0.5f) {
        uint32_t hole;
        const double d = perf_sdf(st, P, hole, cv);
        const uint32_t seed = uint32_t(P[P_PERF_SEED]);
        const int h = int(hole & 0xFFFFu);
        if (d > -0.03f && d < 0.15f) {
            // The wall's normal from four distances 6 um apart. Taking the
            // probes as float32 rounds them, as the kernel's st + vec2(e, 0)
            // does, moved 27,042 edge values to 27,016: not worth mirroring.
            const double e = 0.003f;
            uint32_t hh;
            const V2 g = {perf_sdf({st.x + e, st.y}, P, hh, nullptr) - perf_sdf({st.x - e, st.y}, P, hh, nullptr),
                          perf_sdf({st.x, st.y + e}, P, hh, nullptr) - perf_sdf({st.x, st.y - e}, P, hh, nullptr)};
            const double gl = std::max(length(g), double(1e-6f));
            const V2 nrm = {g.x / gl, g.y / gl}, vdir = {P[P_WALL_VS], P[P_WALL_VT]};
            const double per_hole = 0.4f + 0.6f * hash_f(h, seed ^ 0xE1u);
            const double patchy = smoothstepd(0.25f, 0.75f, 0.5f * (value_noise(st.x / 0.35f, seed ^ uint32_t(h)) +
                                                                    value_noise(st.y / 0.35f, seed ^ uint32_t(h) ^ 0x3Cu)));
            const double side = 0.6f + 0.8f * std::max(0.0, dot(nrm, vdir));
            const double k = per_hole * patchy * side;
            std::array<double, 3> tint;
            for (unsigned j = 0; j < 3; ++j) tint[j] = mixd(1.0, P[P_BASE_R + j], 0.3f);
            const double lam = P[P_WALL_SCATTER];
            if (d >= 0.0) {
                const double lift = P[P_WALL_GLOW] * k * std::exp(-d / lam);
                if (cv && lift > 0.0) ++cv->wall_lift;
                for (unsigned j = 0; j < 3; ++j) col[j] += lift * tint[j] * (white ? light[j] : 1.0);
            } else if (white && hash_f(h, seed ^ 0xE4u) < 0.5f) {
                if (cv && k > 0.0) ++cv->wall_shade;
                for (unsigned j = 0; j < 3; ++j) light[j] *= 1.0 - 0.12f * k * (1.0 - tint[j]) * std::exp(d / 0.012f);
            }
        }
        if (white && d >= 0.0) {
            const double fl = 0.012f * hash_f(h, seed ^ 0xC4u) * (hash_f(h, seed ^ 0xC5u) < 0.5f ? 0.0 : 1.0);
            if (cv && fl > 0.0) ++cv->hole_flare;
            for (unsigned j = 0; j < 3; ++j) col[j] += fl * std::exp(-d / 0.025f) * light[j];
        }
    }
    const double W = P[P_FILM_W], px = P[P_PX];
    const double on_strip = P[P_CARRIER] > 1.5f ? 1.0 : clampd(std::min(st.y, W - st.y) / px + 0.5f, 0.0, 1.0);
    const double in_film = on_strip > 0.0 ? a / on_strip : 0.0;
    if (cv && on_strip < 1.0) ++cv->carrier;
    Out o;
    for (unsigned j = 0; j < 3; ++j) o.v[j] = mixd(P[P_CARRIER], mixd(light[j], col[j], in_film), on_strip);
    return o;
}

using Ref = Out (*)(const Case&, V2, size_t, Coverage*);
const Ref kRef[3] = {canvas_ref, present_ref, light_ref};

// --- parameter blocks, as overscan_layout fills them --------------------------

void holes(Block& P, bool white) {
    P[P_HOLES_LIGHT] = white ? 1.0f : 0.0f;
    for (unsigned k = 0; k < 3; ++k) P[P_LIGHT_R + k] = white ? 1.0f : 0.0f;
    P[P_WALL_GLOW] = white ? 0.045f : 0.02f;
}

void leaks(Block& P, std::initializer_list<std::array<float, 5>> list) {
    unsigned k = 0;
    for (const auto& l : list) {
        for (unsigned j = 0; j < 5; ++j) P[P_LEAKS + 5 * k + j] = l[j];
        ++k;
    }
    P[P_N_LEAKS] = float(k);
}

// gate_shape's quad: 6 numbers make a triangle, 4 an ellipse (cs, ct, rs, rt).
void add_quad(Block& P, std::initializer_list<double> pts, double round, double sign) {
    const unsigned k = unsigned(P[P_N_Q]);
    float* q = P.data() + P_Q + kQStride * k;
    unsigned j = 0;
    for (double v : pts) q[j++] = float(v);
    if (j == 6) { q[6] = q[4]; q[7] = q[5]; }
    q[8] = float(round);
    q[9] = float(sign);
    P[P_N_Q] = float(k + 1);
}

// gate_shape's burrs and nicks: a triangle on a side, out of the opening
// (sign +1) or into it (-1).
void nick(Block& P, int side, double pos, double sz, double sign, double skew) {
    const double s0 = P[P_GS0], t0 = P[P_GT0], gw = P[P_GW], gh = P[P_GH];
    if (side == 0 || side == 2) {
        const double te = side == 0 ? t0 : t0 + gh, out = (side == 0 ? -1.0 : 1.0) * sign, sc = s0 + pos * gw;
        add_quad(P, {sc - sz, te, sc + sz, te, sc + skew * sz, te + out * sz}, 0.005, sign);
    } else {
        const double se = side == 3 ? s0 : s0 + gw, out = (side == 3 ? -1.0 : 1.0) * sign, tc = t0 + pos * gh;
        add_quad(P, {se, tc - sz, se, tc + sz, se + out * sz, tc + skew * sz}, 0.005, sign);
    }
}

// The 645N's eared sides: each film-edge side stands `depth` into the opening
// between ears, swept out to them by circular arcs (two ellipse cuts).
void eared(Block& P, double depth, double la, double lb) {
    const double s0 = P[P_GS0], t0 = P[P_GT0], gw = P[P_GW], gh = P[P_GH];
    for (bool top : {true, false}) {
        const double te = top ? t0 : t0 + gh, out = top ? -1.0 : 1.0, ea = 0.02, eb = 0.03;
        add_quad(P, {s0 + ea + la, te + out * 1.0, s0 + gw - eb - lb, te + out * 1.0,
                     s0 + gw - eb - lb, te - out * depth, s0 + ea + la, te - out * depth}, 0.0, -1.0);
        const double ra = (la * la + depth * depth) / (2.0 * depth), rb = (lb * lb + depth * depth) / (2.0 * depth);
        add_quad(P, {s0 + ea + la, te + out * (ra - depth), ra, ra}, 0.0, -2.0);
        add_quad(P, {s0 + gw - eb - lb, te + out * (rb - depth), rb, rb}, 0.0, -2.0);
    }
}

// The gate and the frame behind it, as overscan_layout sizes them: the
// frame's pixels are the canvas's, so the gate is the frame in mm (less the
// advance, for a pair, whose input carries both pictures).
void gate(Block& P, double px, bool vertical, uint32_t along_px, uint32_t across_px,
          double s0, double t0, double pair_adv = 0.0) {
    P[P_PX] = float(px);
    P[P_VERTICAL] = vertical ? 1.0f : 0.0f;
    P[P_FW] = float(vertical ? across_px : along_px);
    P[P_FH] = float(vertical ? along_px : across_px);
    P[P_GS0] = float(s0);
    P[P_GT0] = float(t0);
    P[P_GW] = float(along_px * px - pair_adv);
    P[P_GH] = float(across_px * px);
    P[P_PAIR_ADV] = float(pair_adv);
}

// The canvas and the scan registration: canvas (u, v) -> film (s, t) is the
// scan's rotation, a quarter turn more for a vertical film, with the canvas's
// centre on (s_mid, t_mid).
void scan(Case& c, uint32_t cw, uint32_t ch, double degrees, double s_mid, double t_mid) {
    Block& P = c.P;
    const double px = P[P_PX], r = degrees * kPi / 180.0, co = std::cos(r), sn = std::sin(r);
    const bool vertical = P[P_VERTICAL] > 0.5f;
    const double A[4] = {vertical ? sn : co, vertical ? co : -sn, vertical ? -co : sn, vertical ? sn : co};
    for (unsigned k = 0; k < 4; ++k) P[P_A00 + k] = float(A[k]);
    P[P_CW] = float(cw);
    P[P_CH] = float(ch);
    P[P_CU] = float(0.5 * cw * px);
    P[P_CV] = float(0.5 * ch * px);
    P[P_CS] = float(s_mid);
    P[P_CT] = float(t_mid);
    c.cw = cw;
    c.ch = ch;
}

// A picture with a smooth gradient and `grain` of per-pixel noise, so a
// sample from the wrong pixel or along the wrong axis is a large error.
std::vector<float> make_frame(const Block& P, uint32_t seed, double smooth, double grain) {
    const uint32_t fw = uint32_t(P[P_FW]), fh = uint32_t(P[P_FH]);
    std::vector<double> sx(size_t(fw) * 3), cy(size_t(fh) * 3);
    for (uint32_t x = 0; x < fw; ++x)
        for (unsigned c = 0; c < 3; ++c) sx[3 * x + c] = std::sin(6.0 * x / fw + 2.0 * c + seed);
    for (uint32_t y = 0; y < fh; ++y)
        for (unsigned c = 0; c < 3; ++c) cy[3 * y + c] = std::cos(4.0 * y / fh - 1.3 * c);
    std::vector<float> f(size_t(fw) * fh * 3);
    for (uint32_t y = 0; y < fh; ++y)
        for (uint32_t x = 0; x < fw; ++x)
            for (unsigned c = 0; c < 3; ++c) {
                const size_t i = (size_t(y) * fw + x) * 3 + c;
                const double u = double(hash_u(uint32_t(i) ^ (seed * 0x27d4eb2du)) >> 8) / 16777216.0;
                f[i] = float(smooth * (0.6 + 0.4 * sx[3 * x + c] * cy[3 * y + c]) + grain * u);
            }
    return f;
}

// A 135 camera: overscan_layout's ranges, one draw of each.
Block camera_135() {
    Block P{};
    P[P_FILM_W] = 35.0f;
    P[P_PENUMBRA] = 0.022f;
    const float wob[12] = {0.009f, -0.004f, 0.002f, -0.011f, 0.005f, -0.003f,
                           0.007f, 0.006f, -0.001f, -0.013f, -0.002f, 0.004f};
    const float phase[12] = {0.4f, 2.1f, 5.5f, 1.3f, 3.9f, 0.2f, 4.4f, 2.8f, 6.0f, 0.9f, 3.3f, 5.1f};
    for (unsigned k = 0; k < 12; ++k) { P[P_WOB_A + k] = wob[k]; P[P_WOB_PH + k] = phase[k]; }
    const float radii[4] = {0.21f, 0.27f, 0.33f, 0.14f};
    for (unsigned k = 0; k < 4; ++k) P[P_GATE_R + k] = radii[k];
    P[P_ROUGH_AMP] = 0.006f; P[P_ROUGH_PERIOD] = 0.13f; P[P_ROUGH_SEED] = float(0x3a5f1c);
    P[P_FOG_AMP] = 0.33f; P[P_FOG_WIDTH] = 1.3f; P[P_FOG_SEED] = float(0x51e7a3); P[P_FOG_PERIOD] = 7.3f;
    P[P_FOG_R] = 0.92f; P[P_FOG_G] = 0.57f; P[P_FOG_B] = 0.24f;
    P[P_PERFORATED] = 1.0f;
    P[P_PERF_PITCH] = 4.75f; P[P_PERF_W] = 1.98f; P[P_PERF_H] = 2.80f; P[P_PERF_EDGE] = 2.00f;
    P[P_PERF_R] = 0.50f; P[P_PERF_PHASE] = -3.3f;
    P[P_HOLE_C] = -0.12f; P[P_HOLE_M] = -0.48f; P[P_HOLE_Y] = -0.81f;
    P[P_FLARE_AMP] = 0.24f; P[P_FLARE_WIDTH] = 0.05f;
    holes(P, true);
    P[P_PERF_SEED] = float(0x2b7e15);
    P[P_WALL_T] = 0.125f; P[P_WALL_VS] = float(std::cos(0.7)); P[P_WALL_VT] = float(std::sin(0.7));
    P[P_BASE_R] = 0.86f; P[P_BASE_G] = 0.55f; P[P_BASE_B] = 0.33f;
    P[P_WALL_SCATTER] = 0.028f;
    P[P_CARRIER] = 2.0f;                 // none: the film runs on under a tilted scan's corners
    return P;
}

// A 120 back: unperforated, a wider and less centred film, black holes (none).
Block camera_120() {
    Block P = camera_135();
    P[P_FILM_W] = 61.1f;
    P[P_PENUMBRA] = 0.031f;
    for (unsigned k = 0; k < 12; ++k) P[P_WOB_A + k] = -0.7f * P[P_WOB_A + k];
    const float radii[4] = {0.05f, 0.04f, 0.07f, 0.03f};
    for (unsigned k = 0; k < 4; ++k) P[P_GATE_R + k] = radii[k];
    P[P_ROUGH_AMP] = 0.004f; P[P_ROUGH_PERIOD] = 0.17f; P[P_ROUGH_SEED] = float(0x9e1d07);
    P[P_FOG_AMP] = 0.5f; P[P_FOG_WIDTH] = 2.1f; P[P_FOG_SEED] = float(0x0c4f22); P[P_FOG_PERIOD] = 9.1f;
    P[P_PERFORATED] = 0.0f;
    P[P_FLARE_AMP] = 0.18f; P[P_FLARE_WIDTH] = 0.06f;
    holes(P, false);
    P[P_CARRIER] = 1.0f;
    return P;
}

std::vector<Case> make_cases() {
    std::vector<Case> cases;
    {
        Case c{"135 strip, 60 um, no carrier, white holes"};
        c.P = camera_135();
        gate(c.P, 0.06, false, 604, 405, 0.0, 5.38);
        nick(c.P, 0, 0.3, 0.09, 1.0, 0.2);
        nick(c.P, 1, 0.6, 0.07, -1.0, -0.3);
        leaks(c.P, {{5.0f, 0, 0.8f, 2.5f, 0.9f}, {24.0f, 1, 0.45f, 1.6f, 0.6f}, {-0.3f, 0, 1.2f, 3.1f, 1.1f}});
        scan(c, 632, 583, 0.21, 18.17, 17.44);
        c.frame = make_frame(c.P, 11, 1.0, 0.25);
        c.seed = 1;
        cases.push_back(std::move(c));
    }
    {
        // A gate corner beside a hole's corner, at a 45 MP frame's pixel: the
        // penumbra, the flare band, a nick, an ellipse cut, the hole's edge.
        Case c{"135 gate corner and hole, 4 um, black carrier, black holes"};
        c.P = camera_135();
        holes(c.P, false);
        c.P[P_CARRIER] = 0.0f;
        c.P[P_PERF_PHASE] = -1.5f;
        gate(c.P, 0.004, false, 250, 200, 0.0, 5.0);
        nick(c.P, 0, 0.3, 0.05, -1.0, 0.1);
        add_quad(c.P, {0.25, 4.6, 0.3, 0.45}, 0.0, -2.0);
        leaks(c.P, {{0.2f, 0, 0.9f, 1.4f, 0.7f}});
        scan(c, 401, 277, 0.33, 0.1, 4.95);
        c.frame = make_frame(c.P, 12, 1.0, 0.25);
        c.seed = 2;
        cases.push_back(c);
        // the same block, one pixel at the gate's corner
        c.name = "one pixel at the gate corner";
        scan(c, 1, 1, 0.33, 0.0, 5.0);
        c.seed = 3;
        cases.push_back(std::move(c));
    }
    {
        Case c{"135 film edge and a hole, 4 um, open carrier"};
        c.P = camera_135();
        c.P[P_CARRIER] = 1.0f;
        c.P[P_PERF_PHASE] = -1.5f;
        gate(c.P, 0.004, false, 250, 200, 0.0, 5.0);
        leaks(c.P, {{3.6f, 0, 1.1f, 1.2f, 0.5f}});
        scan(c, 401, 701, -0.29, 3.6, 1.1);
        c.frame = make_frame(c.P, 13, 1.0, 0.25);
        c.seed = 4;
        cases.push_back(std::move(c));
    }
    {
        Case c{"120 6x7 vertical, eared gate, 80 um, open carrier"};
        c.P = camera_120();
        gate(c.P, 0.08, true, 869, 700, 0.0, 2.75);
        eared(c.P, 0.55, 1.8, 1.6);
        nick(c.P, 1, 0.4, 0.1, 1.0, 0.0);
        leaks(c.P, {{12.0f, 1, 0.7f, 3.0f, 1.2f}, {50.0f, 0, 0.5f, 2.0f, 0.8f}});
        scan(c, 774, 911, -0.27, 34.8, 30.57);
        c.frame = make_frame(c.P, 14, 1.0, 0.25);
        c.seed = 5;
        cases.push_back(std::move(c));
    }
    {
        Case c{"135 half-frame pair, vertical, 50 um, open carrier"};
        c.P = camera_135();
        c.P[P_CARRIER] = 1.0f;
        c.P[P_PERF_PHASE] = -3.0f;
        gate(c.P, 0.05, true, 740, 480, 0.0, 5.46, 19.0);
        nick(c.P, 3, 0.5, 0.08, 1.0, 0.25);
        leaks(c.P, {{9.0f, 1, 0.6f, 2.2f, 0.7f}});
        scan(c, 716, 758, 0.12, 18.53, 17.53);
        c.frame = make_frame(c.P, 15, 1.0, 0.25);
        c.seed = 6;
        cases.push_back(std::move(c));
    }
    {
        // overscan_layout snaps the gate onto pixel boundaries so that "with no
        // scan rotation the frame is copied, not resampled". With a dyadic
        // pixel and a sharp, plain gate every coordinate is exact, so the
        // canvas must be the frame bit for bit inside the gate and 0 outside,
        // and the film presence the input itself.
        Case c{"sharp gate, no rotation: the frame copied"};
        c.P[P_FILM_W] = 7.3125f;
        gate(c.P, 0.0625, false, 77, 53, 0.0, 2.0);
        c.P[P_HOLE_C] = 0.25f; c.P[P_HOLE_M] = -0.5f; c.P[P_HOLE_Y] = 0.75f;
        holes(c.P, true);
        c.P[P_CARRIER] = 2.0f;
        scan(c, 93, 117, 0.0, 2.40625, 3.65625);
        c.frame = make_frame(c.P, 16, 0.0, 4.0);
        c.seed = 7;
        c.exact = true;
        cases.push_back(std::move(c));
    }
    {
        // 4099 x 4093 = 16,777,207 pixels: 65,536 workgroups, one past the
        // 65,535 a row holds where maxComputeWorkGroupCount[0] is the spec
        // minimum (lavapipe, Intel), so there the dispatch folds into two rows.
        // An RTX 3070 allows 2^31 - 1 and runs it as one: there this checks the
        // index arithmetic and bounds at that size, not the fold itself.
        Case c{"135 strip, 8.75 um, open carrier, one past the dispatch fold"};
        c.P = camera_135();
        c.P[P_CARRIER] = 1.0f;
        gate(c.P, 0.00875, false, 3886, 2743, 0.0, 5.5);
        leaks(c.P, {{4.0f, 1, 0.7f, 2.0f, 0.8f}, {30.0f, 0, 0.9f, 3.0f, 1.0f}});
        scan(c, 4099, 4093, -0.18, 17.03, 17.51);
        c.frame = make_frame(c.P, 17, 1.0, 0.25);
        c.seed = 8;
        c.sampled = true;
        cases.push_back(std::move(c));
    }
    return cases;
}

// eps: kEnvelopeUlps float32 ulps at the largest coordinate the kernel forms.
double coordinate_eps(const Case& c) {
    const PD P{c.P.data()};
    double m = std::max({2.0 * std::abs(P[P_CU]), 2.0 * std::abs(P[P_CV]), P[P_FILM_W],
                         std::abs(P[P_GS0]) + P[P_GW] + P[P_PAIR_ADV], std::abs(P[P_GT0]) + P[P_GH]});
    for (uint32_t y : {0u, c.ch - 1}) for (uint32_t x : {0u, c.cw - 1}) {
        const V2f st = canvas_to_film_f(float(x), float(y), c.P.data());
        m = std::max({m, double(std::abs(st.x)), double(std::abs(st.y))});
    }
    return kEnvelopeUlps * ulpf(m);
}

// max_plain: values with no sample slack, i.e. what kRel alone holds;
// max_error: every value that met its bar; max_edge: those that needed the
// envelope.
struct Stats {
    size_t cases = 0, values = 0, enveloped = 0, exact = 0;
    double max_plain = 0, max_error = 0, max_edge = 0;
};

bool run(Gpu* gpu, const Case& c, Which which, Stats& stats, std::string& error) {
    const size_t pixels = size_t(c.cw) * c.ch;
    const std::string label = std::string(kKernel[which]) + " [" + c.name + "]";
    spk::gpu::BufferRef input, output, params;
    {
        std::vector<float> data;
        if (which != kCanvas) {
            data.resize(pixels * 3);
            for (size_t i = 0; i < pixels; ++i)
                for (unsigned k = 0; k < 3; ++k) data[3 * i + k] = pixel_input(c, which, i, k);
        }
        const std::vector<float>& in = which == kCanvas ? c.frame : data;
        input = gpu->upload(in.data(), in.size() * sizeof(float), error);
        if (!input) return false;
    }
    {
        const std::vector<float> initial(pixels * 3 + kGuards, kGuard);
        output = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
    }
    params = gpu->upload(c.P.data(), c.P.size() * sizeof(float), error);
    const uint32_t n[1] = {uint32_t(pixels)};
    // 17 threads past the last pixel: the kernel's own bounds check must stop them.
    if (!output || !params ||
        !gpu->dispatch(kKernel[which], {Arg::buf(input), Arg::buf(params), Arg::inline_bytes(n, 1),
                       Arg::buf(output)}, pixels + 17, error)) return false;
    std::vector<float> actual;
    if (!read_test_buffer(gpu, output, actual, error)) return false;
    for (size_t k = pixels * 3; k < pixels * 3 + kGuards; ++k)
        if (actual[k] != kGuard) { error = label + ": wrote past the canvas"; return false; }
    for (size_t k = 0; k < pixels * 3; ++k)
        if (actual[k] == kGuard) { error = label + ": left a pixel unwritten at " + std::to_string(k / 3); return false; }

    std::vector<size_t> check;
    if (c.sampled) {
        for (size_t i = 0; i < pixels; i += 997) check.push_back(i);
        const size_t fold = size_t(65535) * 256;
        for (size_t i = fold - 2 * size_t(c.cw); i < std::min(pixels, fold + 2 * size_t(c.cw)); ++i) check.push_back(i);
        for (size_t i = pixels - 600; i < pixels; ++i) check.push_back(i);
    } else {
        check.resize(pixels);
        for (size_t i = 0; i < pixels; ++i) check[i] = i;
    }
    const double eps = coordinate_eps(c);
    const Ref ref = kRef[which];
    for (size_t i : check) {
        const uint32_t x = uint32_t(i % c.cw), y = uint32_t(i / c.cw);
        const V2f stf = canvas_to_film_f(float(x), float(y), c.P.data());
        const V2 st{stf.x, stf.y};
        const Out r0 = ref(c, st, i, &coverage);
        bool have_env = false;
        std::array<Out, 8> env;
        for (unsigned k = 0; k < 3; ++k) {
            const double g = actual[3 * i + k], want = r0.v[k];
            ++stats.values;
            if (c.exact && which != kLight) {
                if (g != want && !(std::isnan(g) && std::isnan(want))) {
                    char detail[256];
                    std::snprintf(detail, sizeof detail, ": x=%u y=%u c=%u got %.9g, the frame copy is %.9g",
                                  x, y, k, g, want);
                    error = label + detail;
                    return false;
                }
                ++stats.exact;
                continue;
            }
            if (std::isfinite(g) && std::isfinite(want)) {
                const double delta = std::abs(g - want);
                if (delta <= kRel * std::max(1.0, std::abs(want)) + r0.slack[k]) {
                    stats.max_error = std::max(stats.max_error, delta);
                    if (r0.slack[k] == 0.0) stats.max_plain = std::max(stats.max_plain, delta);
                    continue;
                }
            } else if ((std::isnan(g) && std::isnan(want)) || g == want) {
                continue;
            }
            // Missed the bar: the reference's range around the pixel's coordinate.
            if (!have_env) {
                unsigned e = 0;
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx)
                    if (dx || dy) env[e++] = ref(c, {st.x + dx * eps, st.y + dy * eps}, i, nullptr);
                have_env = true;
            }
            double lo = std::numeric_limits<double>::infinity(), hi = -lo, mag = 0.0, slack = 0.0;
            bool same_class = false;
            auto take = [&](const Out& o) {
                const double v = o.v[k];
                if (std::isfinite(v)) {
                    lo = std::min(lo, v); hi = std::max(hi, v);
                    mag = std::max(mag, std::abs(v)); slack = std::max(slack, o.slack[k]);
                } else if ((std::isnan(g) && std::isnan(v)) || g == v) {
                    same_class = true;
                }
            };
            take(r0);
            for (const Out& o : env) take(o);
            auto within = [&] {
                const double bar = kRel * std::max(1.0, mag) + slack;
                return std::isfinite(g) ? lo <= hi && g >= lo - bar && g <= hi + bar : same_class;
            };
            bool ok = within();
            if (!ok) {
                // A piecewise-smooth value's extremes over the box are at its
                // corners or at a one-sided limit of a jump inside it -- the
                // light's d = 0, the flare's band, the film's edge, a hole's
                // cell. Bisect each segment from the centre toward the larger
                // change, which closes on the jump when there is one, and take
                // both ends: every point is still inside the box.
                unsigned e = 0;
                for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                    if (!dx && !dy) continue;
                    double ta = 0.0, tb = 1.0, fa = r0.v[k], fb = env[e++].v[k];
                    for (int it = 0; it < 48; ++it) {
                        const double tm = 0.5 * (ta + tb);
                        const Out om = ref(c, {st.x + dx * eps * tm, st.y + dy * eps * tm}, i, nullptr);
                        take(om);
                        const double fm = om.v[k];
                        if (std::abs(fm - fa) > std::abs(fb - fm)) { tb = tm; fb = fm; } else { ta = tm; fa = fm; }
                    }
                }
                ok = within();
            }
            if (!ok) {
                char detail[384];
                std::snprintf(detail, sizeof detail,
                              ": x=%u y=%u c=%u st=(%.9g, %.9g) got %.9g, float64 %.12g, range within %.3g mm "
                              "[%.12g, %.12g], bar %.3g", x, y, k, st.x, st.y, g, want, eps, lo, hi,
                              kRel * std::max(1.0, mag) + slack);
                error = label + detail;
                return false;
            }
            ++stats.enveloped;
            if (std::isfinite(g) && std::isfinite(want)) stats.max_edge = std::max(stats.max_edge, std::abs(g - want));
        }
    }
    ++stats.cases;
    return true;
}

// n[0] == 0: every thread returns before writing.
bool run_empty(Gpu* gpu, const Case& c, Which which, std::string& error) {
    const std::vector<float> data(300 * 3, 0.5f), initial(300 * 3 + kGuards, kGuard);
    auto input = gpu->upload(which == kCanvas ? c.frame.data() : data.data(),
                             (which == kCanvas ? c.frame.size() : data.size()) * sizeof(float), error);
    auto output = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
    auto params = gpu->upload(c.P.data(), c.P.size() * sizeof(float), error);
    const uint32_t n[1] = {0};
    if (!input || !output || !params ||
        !gpu->dispatch(kKernel[which], {Arg::buf(input), Arg::buf(params), Arg::inline_bytes(n, 1),
                       Arg::buf(output)}, 300, error)) return false;
    std::vector<float> actual;
    if (!read_test_buffer(gpu, output, actual, error)) return false;
    for (size_t k = 0; k < initial.size(); ++k)
        if (actual[k] != kGuard) { error = std::string(kKernel[which]) + ": wrote with n = 0"; return false; }
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_overscan <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    std::vector<Case> cases = make_cases();
    Stats stats[3];
    for (Case& c : cases) {
        for (Which which : {kCanvas, kPresent, kLight}) {
            if (!run(gpu.get(), c, which, stats[which], error)) {
                std::fprintf(stderr, "overscan gate: %s\n", error.c_str());
                return 1;
            }
        }
        if (c.sampled) c.frame = {};
    }
    for (Which which : {kCanvas, kPresent, kLight})
        if (!run_empty(gpu.get(), cases.front(), which, error)) {
            std::fprintf(stderr, "overscan gate: %s\n", error.c_str());
            return 1;
        }
    const Coverage& v = coverage;
    const std::pair<const char*, size_t> reached[] = {
        {"partial gate shadow", v.partial_gate}, {"frame interior sample", v.frame_interior},
        {"gate flare", v.flare}, {"off the film, black/open carrier", v.off_film},
        {"pair's second exposure", v.pair_second}, {"spool leaks", v.leaks},
        {"perforation edge", v.hole_edge}, {"film's long edge", v.strip_edge}, {"burr", v.burr},
        {"wall shoulder", v.wall_lift}, {"wall shade in a white hole", v.wall_shade},
        {"hole flare", v.hole_flare}, {"carrier mix", v.carrier}};
    for (const auto& r : reached)
        if (r.second == 0) { std::fprintf(stderr, "overscan gate: no pixel reached the %s\n", r.first); return 1; }
    for (Which which : {kCanvas, kPresent, kLight}) {
        const Stats& s = stats[which];
        std::printf("%s: %zu cases, %zu values; max |GPU - float64| %.3g (%.3g with no frame sample); "
                    "%zu at an edge, within the coordinate envelope (max %.3g); %zu bit-exact\n",
                    kKernel[which], s.cases, s.values, s.max_error, s.max_plain, s.enveloped, s.max_edge, s.exact);
    }
    std::printf("coverage:");
    for (const auto& r : reached) std::printf(" %s %zu;", r.first, r.second);
    std::printf(" NaN/Inf, n = 0 and guards passed\n");
    return 0;
}
