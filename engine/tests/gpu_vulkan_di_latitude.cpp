// DI encode and scene-latitude gates. Each Metal kernel (nodes.metal's
// spk_di_encode, scene_latitude.metal's spk_scene_latitude) is transcribed to
// double here as the reference, around the float decisions the kernel makes
// (an overflowing 10^x, the norm's finiteness, the split). Exceptional inputs,
// every branch and the edges between them, partial workgroups, and one pixel
// past the dispatch fold of a 65535-group device. This is local kernel
// validation, not a claim of whole-frame Metal parity.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"
#include "digital_intermediate.hpp"
#include "latitude_fit.hpp"

#include <algorithm>
#include <array>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;
constexpr float kGuard = -654321.0f;
constexpr size_t kGuards = 19;
// vulkan_gpu.cpp folds past maxComputeWorkGroupCount[0]; at the spec minimum
// (lavapipe, Intel) that is 65535 groups of 256, and this is one pixel more.
// A device with a larger limit runs it as one row: the same 1D index, unfolded.
constexpr uint32_t kPastFold = 65535u * 256u + 1u;
const float kNan = std::numeric_limits<float>::quiet_NaN();
const float kInf = std::numeric_limits<float>::infinity();

struct Expect { double a, b, bar; };   // b == a unless either side of a branch is right

struct Stats {
    size_t cases = 0, ambiguous = 0;
    double largest_error = 0, largest_relative = 0;
    double worst_ratio = 0;   // worst |error| / bar, and where
    std::string worst_where;
};

// A float literal of a kernel, widened: the kernel rounds every constant to float.
constexpr double F(double x) { return double(float(x)); }

// Reads the whole allocation back; every element must meet its expectation
// and every guard past the logical output must be untouched.
template <class Want>
bool check_output(Gpu* gpu, const BufferRef& output, size_t elements, Want want, Stats& stats,
                  const std::string& label, std::string& error) {
    std::vector<float> actual;
    if (!read_test_buffer(gpu, output, actual, error)) return false;
    // The pool may hand back a larger buffer; only the guarded window is ours.
    if (actual.size() < elements + kGuards) { error = label + ": output smaller than requested"; return false; }
    for (size_t e = 0; e < elements; ++e) {
        const Expect x = want(e);
        const double got = actual[e];
        bool ok;
        double err = 0;
        if (std::isnan(x.a)) ok = std::isnan(got);
        else if (std::isinf(x.a)) ok = got == x.a;
        else {
            err = std::min(std::abs(got - x.a), std::abs(got - x.b));
            ok = std::isfinite(got) && err <= x.bar;
        }
        if (!ok) {
            char detail[320];
            std::snprintf(detail, sizeof detail,
                          " element=%zu (pixel %zu channel %zu) got=%.9g expected=%.17g or %.17g bar=%.3g",
                          e, e / 3, e % 3, got, x.a, x.b, x.bar);
            error = label + detail;
            return false;
        }
        stats.largest_error = std::max(stats.largest_error, err);
        if (x.a != 0) stats.largest_relative = std::max(stats.largest_relative, err / std::abs(x.a));
        if (x.bar > 0 && err / x.bar > stats.worst_ratio) {
            stats.worst_ratio = err / x.bar;
            char where[160];
            std::snprintf(where, sizeof where, " pixel %zu channel %zu (expected %.9g, bar %.3g)",
                          e / 3, e % 3, x.a, x.bar);
            stats.worst_where = label + where;
        }
    }
    for (size_t e = elements; e < elements + kGuards; ++e)
        if (actual[e] != kGuard) { error = label + " wrote outside the logical output"; return false; }
    ++stats.cases;
    return true;
}

// Uploads `pixels` RGB triples (pixel i is `pattern[i % pattern.size()]`) and
// a guarded output, then dispatches one thread per pixel.
bool run_kernel(Gpu* gpu, const char* kernel, const std::vector<std::array<float, 3>>& pattern,
                uint32_t pixels, const float* params, size_t n_params, BufferRef& output, std::string& error) {
    BufferRef input;
    {
        std::vector<float> host(size_t(std::max(pixels, 1u)) * 3);
        for (size_t i = 0; i < host.size() / 3; ++i)
            for (size_t c = 0; c < 3; ++c) host[3 * i + c] = pattern[i % pattern.size()][c];
        input = gpu->upload(host.data(), host.size() * sizeof(float), error);
    }
    {
        std::vector<float> initial(size_t(pixels) * 3 + kGuards, kGuard);
        output = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
    }
    const uint32_t n[1] = {pixels};
    return input && output &&
           gpu->dispatch(kernel, {Arg::buf(input), Arg::inline_bytes(params, n_params), Arg::inline_bytes(n, 1),
                                  Arg::buf(output)}, pixels, error);
}

// ---------------------------------------------------------------------------
// spk_di_encode
// ---------------------------------------------------------------------------

// The decision quantities, and per channel the sum of |terms| of the matrix
// product that last formed `lin` (its float rounding scales with that sum,
// not with the result, when the terms cancel).
struct DiTrace { double w = 0, d = 0, C = 0; double terms[3] = {0, 0, 0}; };

// nodes.metal::spk_di_encode in double. `window` forces the blue-window branch
// (0 skip, 1 take) or lets it decide (-1), so both sides of a decision that
// sits within rounding of its edge can be evaluated.
void di_reference(const float y[3], const float* p, int window, double code[3], DiTrace* trace) {
    double pos[3];
    for (int c = 0; c < 3; ++c) {
        // y + offset is a float sum in the kernel and 10^that a float, so one
        // past FLT_MAX is +inf there (and inf - inf a NaN downstream).
        const float t = y[c] + p[9 + c];
        double v = std::pow(10.0, double(t));
        if (v > double(FLT_MAX)) v = INFINITY;
        pos[c] = v - double(p[40]) * std::pow(10.0, double(p[9 + c]));
    }
    double lin[3];
    DiTrace t;
    for (int j = 0; j < 3; ++j) {
        lin[j] = pos[0] * p[j] + pos[1] * p[3 + j] + pos[2] * p[6 + j];
        t.terms[j] = std::abs(pos[0] * p[j]) + std::abs(pos[1] * p[3 + j]) + std::abs(pos[2] * p[6 + j]);
    }
    if (p[30] != 0.0f) {
        double lms[3];
        for (int r = 0; r < 3; ++r)
            lms[r] = p[12 + 3 * r] * lin[0] + p[13 + 3 * r] * lin[1] + p[14 + 3 * r] * lin[2];
        for (double& v : lms) v = std::pow(std::fmax(v, 0.0), double(1.0f / 3.0f));   // fmax: NaN -> 0
        const double L = F(0.2104542553) * lms[0] + F(0.7936177850) * lms[1] - F(0.0040720468) * lms[2];
        double a = F(1.9779984951) * lms[0] - F(2.4285922050) * lms[1] + F(0.4505937099) * lms[2];
        double b = F(0.0259040371) * lms[0] + F(0.7827717662) * lms[1] - F(0.8086757660) * lms[2];
        t.C = std::sqrt(a * a + b * b);
        const double h = std::atan2(b, a) * F(57.29577951308232);
        t.d = std::fmod(h - p[33] + 540.0, 360.0) - 180.0;
        t.w = std::abs(t.d) < p[34] ? 0.5 * (1.0 + std::cos(F(3.14159265358979) * t.d / p[34])) : 0.0;
        const double g = std::fmin(std::fmax((t.C - p[35]) / (p[36] - p[35]), 0.0), 1.0);
        t.w *= g * g * (3.0 - 2.0 * g);
        if (window == 1 || (window < 0 && t.w > 0.0)) {
            const double h2 = (h + t.w * p[31]) * F(0.017453292519943295);
            const double C2 = t.C * (1.0 + t.w * (p[32] - 1.0));
            a = C2 * std::cos(h2);
            b = C2 * std::sin(h2);
            const double l_[3] = {L + F(0.3963377774) * a + F(0.2158037573) * b,
                                  L - F(0.1055613458) * a - F(0.0638541728) * b,
                                  L - F(0.0894841775) * a - F(1.2914855480) * b};
            for (int r = 0; r < 3; ++r) lms[r] = l_[r] * l_[r] * l_[r];
            for (int r = 0; r < 3; ++r) {
                lin[r] = p[21 + 3 * r] * lms[0] + p[22 + 3 * r] * lms[1] + p[23 + 3 * r] * lms[2];
                t.terms[r] = std::max(t.terms[r], std::abs(p[21 + 3 * r] * lms[0]) +
                                      std::abs(p[22 + 3 * r] * lms[1]) + std::abs(p[23 + 3 * r] * lms[2]));
            }
        }
    }
    for (int c = 0; c < 3; ++c) {
        const double arg = std::fmax(lin[c], 0.0) * (1.0 - p[41]) + p[41];
        code[c] = std::fmin(std::fmax((p[37] + p[38] * std::log10(arg)) / p[39], 0.0), 1.0);
    }
    if (trace) *trace = t;
}

// The expectation of one pixel. The bar is 4e-6 of a code plus the pixel's own
// conditioning, in two parts: an input error of 2e-6 in log10 (the float sum,
// exp2's argument rounding and its approximation; ~6e-7 at |y| <= 4) carried
// through the reference's measured slope, so a positive just above its floor
// earns its own room; and a 1e-6 relative error in the terms of the matrix
// product that formed `lin` (float rounding, the GPU's sin/cos/pow), carried
// through the log encode, so a channel the inverse Oklab matrix cancels to near
// zero does too. Measured on an RTX 3070 before this second part existed, such
// a channel reached 0.73 of the first part alone.
std::array<Expect, 3> di_expect(const std::array<float, 3>& y, const float* p, Stats& stats) {
    double natural[3], alt[3];
    DiTrace t;
    di_reference(y.data(), p, -1, natural, &t);
    const int taken = p[30] != 0.0f && t.w > 0.0 ? 1 : 0;
    std::copy(natural, natural + 3, alt);
    // The window fades to w = 0 at its edges, but taking the branch at all
    // passes LMS through max(., 0): out of gamut, w = 0+ and w = 0 differ. A
    // weight within rounding of its edge may land on either side.
    if (p[30] != 0.0f && t.w < 1e-5 && std::abs(t.d) < p[34] + 1e-3 && t.C > p[35] - 1e-6) {
        di_reference(y.data(), p, 1 - taken, alt, nullptr);
    }
    double slope[3] = {0, 0, 0};
    for (int j = 0; j < 3; ++j) {
        if (!std::isfinite(y[j])) continue;
        std::array<float, 3> lo = y, hi = y;
        lo[j] = y[j] - 1e-4f;
        hi[j] = y[j] + 1e-4f;
        double clo[3], chi[3];
        di_reference(lo.data(), p, taken, clo, nullptr);
        di_reference(hi.data(), p, taken, chi, nullptr);
        for (int c = 0; c < 3; ++c) slope[c] += std::abs(chi[c] - clo[c]) / (double(hi[j]) - double(lo[j]));
    }
    std::array<Expect, 3> out;
    bool two_valued = false;
    for (int c = 0; c < 3; ++c) {
        double rounding = 0;
        if (natural[c] > 0 && natural[c] < 1) {
            // d code / d lin at the reference's own argument of the log.
            const double arg = std::pow(10.0, (natural[c] * p[39] - p[37]) / p[38]);
            rounding = p[38] * (1.0 - p[41]) / (p[39] * std::log(10.0) * arg) * t.terms[c] * 1e-6;
            if (!std::isfinite(rounding)) rounding = 0;
        }
        out[c] = {natural[c], alt[c], 4e-6 + 2e-6 * slope[c] + rounding};
        two_valued = two_valued || std::abs(alt[c] - natural[c]) > out[c].bar;
    }
    stats.ambiguous += two_valued ? 1 : 0;
    return out;
}

struct DiParams {
    const char* name;
    float p[42];
};

DiParams di_params(const char* name, const double m[9], const double live[3], bool comp, double rot,
                   double kappa, double floor, double black) {
    // Ottosson's linear sRGB -> LMS and back: a working space's to_lms/from_lms.
    static const double to_lms[9] = {0.4122214708, 0.5363325363, 0.0514459929,
                                     0.2119034982, 0.6806995451, 0.1073969566,
                                     0.0883024619, 0.2817188376, 0.6299787005};
    static const double from_lms[9] = {4.0767416621, -3.3077115913, 0.2309699292,
                                       -1.2684380046, 2.6097574011, -0.3413193965,
                                       -0.0041960863, -0.7034186147, 1.7076147010};
    DiParams d{name, {}};
    for (int i = 0; i < 9; ++i) d.p[i] = float(m[i]);
    for (int i = 0; i < 3; ++i) d.p[9 + i] = float(live[i]);
    for (int i = 0; i < 9; ++i) d.p[12 + i] = float(to_lms[i]);
    for (int i = 0; i < 9; ++i) d.p[21 + i] = float(from_lms[i]);
    d.p[30] = comp ? 1.0f : 0.0f;
    d.p[31] = float(rot);
    d.p[32] = float(kappa);
    d.p[33] = float(spk::kDiBlueHueCentre);
    d.p[34] = float(spk::kDiBlueHueHalfWidth);
    d.p[35] = float(spk::kDiBlueChromaLo);
    d.p[36] = float(spk::kDiBlueChromaHi);
    d.p[37] = float(spk::kDiCineonWhite);
    d.p[38] = float(spk::kDiCineonPerDecade);
    d.p[39] = float(spk::kDiCineonMax);
    d.p[40] = float(floor);
    d.p[41] = float(black);
    return d;
}

bool invert3(const double m[9], double out[9]) {
    const double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
                       m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (det == 0) return false;
    out[0] = (m[4] * m[8] - m[5] * m[7]) / det; out[1] = (m[2] * m[7] - m[1] * m[8]) / det;
    out[2] = (m[1] * m[5] - m[2] * m[4]) / det; out[3] = (m[5] * m[6] - m[3] * m[8]) / det;
    out[4] = (m[0] * m[8] - m[2] * m[6]) / det; out[5] = (m[2] * m[3] - m[0] * m[5]) / det;
    out[6] = (m[3] * m[7] - m[4] * m[6]) / det; out[7] = (m[1] * m[6] - m[0] * m[7]) / det;
    out[8] = (m[0] * m[4] - m[1] * m[3]) / det;
    return true;
}

// The positives a parameter set is tested on: a log grid (every hue and
// chroma the matrix reaches), every exceptional value in every channel, the
// floor and the white clamp, and pixels placed by their Oklab output hue and
// chroma on the window's centre, both hue edges and both chroma edges.
std::vector<std::array<float, 3>> di_pixels(const float* p) {
    std::vector<std::array<float, 3>> px;
    const float grid[] = {-3.5f, -2.2f, -1.3f, -0.7f, -0.25f, 0.0f, 0.35f, 0.9f};
    for (float r : grid) for (float g : grid) for (float b : grid) px.push_back({r, g, b});
    const float specials[] = {kNan, kInf, -kInf, -0.0f, 40.0f, 37.5f, -60.0f, 1e-30f};
    for (float s : specials) {
        for (int c = 0; c < 3; ++c) { std::array<float, 3> y{-0.5f, -0.5f, -0.5f}; y[c] = s; px.push_back(y); }
        px.push_back({s, s, s});
    }
    // Exactly at, and around, the clear-base floor (lin = 0, code 95), and at
    // the white end (code 1023 near lin = 13.4).
    if (p[40] > 0) {
        const float at = float(std::log10(double(p[40])));
        for (float y : {at, std::nextafter(at, -kInf), std::nextafter(at, kInf), at - 1e-3f, at + 1e-3f})
            px.push_back({y, y, y});
    }
    for (float y : {1.1f, 1.2f, 1.25f, 1.3f, 2.0f}) px.push_back({y, y, y});

    double m[9], inverse[9], from_lms[9], gain[3];
    for (int i = 0; i < 9; ++i) { m[i] = p[i]; from_lms[i] = p[21 + i]; }
    for (int c = 0; c < 3; ++c) gain[c] = std::pow(10.0, double(p[9 + c]));
    if (!invert3(m, inverse)) return px;
    const double centre = p[33] - 360.0, half = p[34];   // the window in atan2's (-180, 180]
    const double hues[] = {centre, centre - half - 0.05, centre - half + 0.001, centre - half + 0.05,
                           centre - half + 0.5, centre + half - 0.5, centre + half - 0.001,
                           centre + half + 0.05, centre + 10.0, -179.99, 179.99, 30.0, 140.0};
    const double chromas[] = {0.0199, 0.0201, 0.05, 0.0799, 0.0801, 0.12, 0.3};
    for (double L : {0.35, 0.6, 0.85})
        for (double h : hues)
            for (double C : chromas) {
                const double a = C * std::cos(h * 0.017453292519943295), b = C * std::sin(h * 0.017453292519943295);
                const double l_[3] = {L + 0.3963377774 * a + 0.2158037573 * b,
                                      L - 0.1055613458 * a - 0.0638541728 * b,
                                      L - 0.0894841775 * a - 1.2914855480 * b};
                double lms[3], lin[3];
                for (int r = 0; r < 3; ++r) lms[r] = l_[r] * l_[r] * l_[r];
                for (int r = 0; r < 3; ++r)
                    lin[r] = from_lms[3 * r] * lms[0] + from_lms[3 * r + 1] * lms[1] + from_lms[3 * r + 2] * lms[2];
                std::array<float, 3> y;
                bool ok = true;
                for (int c = 0; c < 3; ++c) {
                    // lin = pos @ M, so pos = lin @ M^-1; then undo the floor and the live gain.
                    const double pos = lin[0] * inverse[c] + lin[1] * inverse[3 + c] + lin[2] * inverse[6 + c];
                    const double q = pos + double(p[40]) * gain[c];
                    ok = ok && q > 0;
                    y[c] = ok ? float(std::log10(q) - double(p[9 + c])) : 0.0f;
                }
                if (ok) px.push_back(y);
            }
    return px;
}

bool check_di(Gpu* gpu, Stats& stats, std::string& error) {
    const double film[9] = {1.18, -0.12, -0.04, -0.15, 1.22, -0.10, -0.03, -0.10, 1.14};
    const double identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    const double live[3] = {0.03, -0.02, 0.05}, none[3] = {0, 0, 0};
    const double black = spk::di_cineon_black_offset();
    const DiParams sets[] = {
        di_params("film+window", film, live, true, -9.0, 0.88, 0.0123, black),
        di_params("film", film, live, false, -9.0, 0.88, 0.0123, black),
        // No black offset and no floor: log10(0) = -inf, code 0.
        di_params("identity+window, no offset", identity, none, true, 25.0, 1.3, 0.0, 0.0),
    };
    for (const DiParams& set : sets) {
        const auto pattern = di_pixels(set.p);
        std::vector<Expect> want;
        want.reserve(pattern.size() * 3);
        for (const auto& y : pattern) for (const Expect& e : di_expect(y, set.p, stats)) want.push_back(e);
        const uint32_t counts[] = {0, 1, 255, 256, 257, uint32_t(pattern.size())};
        for (uint32_t count : counts) {
            BufferRef output;
            if (!run_kernel(gpu, "spk_di_encode", pattern, count, set.p, 42, output, error) ||
                !check_output(gpu, output, size_t(count) * 3, [&](size_t e) { return want[e % want.size()]; },
                              stats, std::string("DI ") + set.name + " pixels=" + std::to_string(count), error))
                return false;
        }
        if (&set == &sets[0]) {
            BufferRef output;
            if (!run_kernel(gpu, "spk_di_encode", pattern, kPastFold, set.p, 42, output, error) ||
                !check_output(gpu, output, size_t(kPastFold) * 3, [&](size_t e) { return want[e % want.size()]; },
                              stats, std::string("DI ") + set.name + " pixels=" + std::to_string(kPastFold), error))
                return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// spk_scene_latitude
// ---------------------------------------------------------------------------

constexpr double kTwoM30 = 9.313225746154785e-10, kTwoP30 = 1073741824.0;

// Metal's frame choice for pixel i: `along` is a correctly rounded float
// quotient there (and in this C++), compared with the split as a float.
// Negative control, RTX 3070: the kernel with a plain GLSL `n / d >= split`
// fails here at the centre column of 33 (pixel 16, split 0.5).
bool second_frame(const float* p, uint32_t i) {
    if (!(p[13] > 0.0f)) return false;
    const uint32_t w = uint32_t(p[11]), h = uint32_t(p[12]);
    const float along = w >= h ? (float(i % w) + 0.5f) / float(w) : (float(i / w) + p[18] + 0.5f) / float(h);
    return along >= p[13];
}

// scene_latitude.metal::spk_scene_latitude in double for one frame's knees.
// The norm's finiteness is decided in float, in the kernel's order: a cube
// that overflows, or a square sum that underflows, is the kernel's decision.
void latitude_reference(const std::array<float, 3>& rgb, const float* p, bool second, double out[3]) {
    const float cr = rgb[0] > 0 ? rgb[0] : 0.0f, cg = rgb[1] > 0 ? rgb[1] : 0.0f, cb = rgb[2] > 0 ? rgb[2] : 0.0f;
    const uint32_t norm = uint32_t(p[6]);
    float vf;
    double vd;
    if (norm == 1u) {
        vf = p[7] * cr + p[8] * cg + p[9] * cb;
        vd = double(p[7]) * cr + double(p[8]) * cg + double(p[9]) * cb;
    } else if (norm == 2u) {
        vf = std::max(cr, std::max(cg, cb));
        vd = vf;
    } else {
        const float s2 = cr * cr + cg * cg + cb * cb;
        vf = s2 > 0 ? (cr * cr * cr + cg * cg * cg + cb * cb * cb) / s2 : 0.0f;
        const double r = cr, g = cg, b = cb, d2 = r * r + g * g + b * b;
        vd = d2 > 0 ? (r * r * r + g * g * g + b * b * b) / d2 : 0.0;
    }
    double k = 1.0;
    if (vf > 0 && std::isfinite(vf)) {
        const double n_ref = p[10];
        const double E = std::clamp(std::log2(std::max(vd, n_ref * std::exp2(-24.0)) / n_ref), -24.0, 24.0);
        // core/latitude_fit.cpp's delta is the double reference of the curve
        // the kernel evaluates, in the same order (scene_latitude.metal says so).
        spk::SceneLatitudeParams s;
        const int base = second ? 14 : 0;
        s.highlight_knee = p[base]; s.highlight_room = p[base + 1];
        s.shadow_knee = p[base + 2]; s.shadow_room = p[base + 3];
        s.rolloff = p[4];
        s.max_lift = p[5];
        k = std::clamp(std::exp2(spk::slm::delta(E, s)), kTwoM30, kTwoP30);
    }
    for (int c = 0; c < 3; ++c) out[c] = double(rgb[c]) * k;
}

// 1e-6 of the output plus 2e-7 per stop of |E| and of the gain: float log2,
// the stop arithmetic and exp2 all lose in proportion to the stops involved.
// Measured on an RTX 3070: 2.9e-6 relative at most, ~7e-8 per stop.
std::array<Expect, 3> latitude_expect(const std::array<float, 3>& rgb, const float* p, bool second) {
    double out[3];
    latitude_reference(rgb, p, second, out);
    double stops = 0;
    for (int c = 0; c < 3; ++c)
        if (std::isfinite(out[c]) && rgb[c] != 0.0f && std::isfinite(rgb[c]))
            stops = std::max(stops, std::abs(std::log2(std::abs(out[c] / double(rgb[c])))));
    double mx = 0;   // the largest finite component stands in for the norm
    for (float v : rgb) if (std::isfinite(v)) mx = std::max(mx, double(std::abs(v)));
    const double E = mx > 0 ? std::min(24.0, std::abs(std::log2(mx / p[10]))) : 0.0;
    std::array<Expect, 3> e;
    for (int c = 0; c < 3; ++c) e[c] = {out[c], out[c], std::abs(out[c]) * (1e-6 + 2e-7 * (E + stops))};
    return e;
}

struct LatParams {
    std::string name;
    float p[19];
};

LatParams lat_params(std::string name, int norm, double m, double lift, std::array<double, 4> a,
                     double split = 0, uint32_t w = 37, uint32_t h = 11, double row0 = 0,
                     std::array<double, 4> b = {2, 0, -2, 0}) {
    LatParams s{std::move(name), {}};
    for (int i = 0; i < 4; ++i) s.p[i] = float(a[size_t(i)]);
    s.p[4] = float(m);
    s.p[5] = float(lift);
    s.p[6] = float(norm);
    // The Y row of linear sRGB's RGB -> XYZ (D65), as rgb_to_xyz_ae_ gives it.
    s.p[7] = 0.2126729f; s.p[8] = 0.7151522f; s.p[9] = 0.0721750f;
    s.p[10] = float(spk::slm::kMidgray);
    s.p[11] = float(w); s.p[12] = float(h); s.p[13] = float(split);
    for (int i = 0; i < 4; ++i) s.p[14 + i] = float(b[size_t(i)]);
    s.p[18] = float(row0);
    return s;
}

// A stop ladder past the clamp at both ends in several chromaticities (one
// with a negative component), mid-grey placed exactly on every knee and one
// ulp either side, and every exceptional value in every channel.
std::vector<std::array<float, 3>> latitude_pixels(const float* p) {
    std::vector<std::array<float, 3>> px;
    const double tints[][3] = {{1, 1, 1}, {1.6, 1, 0.5}, {0.4, 0.8, 1.7}, {2.5, 0.05, 0.02}, {1.2, -0.3, 0.6}};
    const double n_ref = p[10];
    for (int e = -30; e <= 30; ++e)
        for (const auto& t : tints) {
            const double v = n_ref * std::exp2(e + 0.37 * (e % 3));
            px.push_back({float(t[0] * v), float(t[1] * v), float(t[2] * v)});
        }
    for (int i : {0, 2, 14, 16}) {
        const float x = float(double(p[10]) * std::exp2(double(p[i])));
        for (float y : {x, std::nextafter(x, 0.0f), std::nextafter(x, kInf)}) px.push_back({y, y, y});
    }
    const float specials[] = {kNan, kInf, -kInf, -1.0f, 0.0f, -0.0f, 1e-25f, 1e12f, 1e13f, 3e38f};
    for (float s : specials) {
        for (int c = 0; c < 3; ++c) { std::array<float, 3> y{0.2f, 0.3f, 0.1f}; y[c] = s; px.push_back(y); }
        px.push_back({s, s, s});
    }
    return px;
}

bool check_latitude(Gpu* gpu, Stats& stats, std::string& error) {
    const float half = 0.5f;
    const float sixth = 5.5f / 33.0f;                    // pixel 5 of 33: an inexact quotient
    const float strip = (12.0f + 7.0f + 0.5f) / 40.0f;   // row 12 of a strip starting at row 7
    std::vector<LatParams> sets = {
        lat_params("power m=2", 0, 2.0, 4.0, {2.0, 1.5, -2.5, 2.0}),
        lat_params("Y m=1 highlight only", 1, 1.0, 12.0, {0.5, 3.0, -6.0, 0.0}),
        lat_params("max m=3 shadow only", 2, 3.0, 0.25, {4.0, 0.0, -1.0, 6.0}),
        // A knee far down: past 30 stops of compression the gain clamps at 2^-30.
        lat_params("power m=2.5 gain clamp", 0, 2.5, 0.25, {-20.0, 0.5, -22.0, 1.0}),
    };
    // Half-frame pairs. An odd width puts a column's centre exactly on 0.5;
    // the split one float either side of it moves only that column.
    const std::array<double, 4> a = {1.0, 2.0, -1.0, 2.0}, b = {-1.0, 4.0, -4.0, 1.0};
    const auto named = [](const char* what, float s) {
        char text[64];
        std::snprintf(text, sizeof text, "%s, split=%.9g", what, double(s));
        return std::string(text);
    };
    for (float s : {half, std::nextafter(half, 0.0f), std::nextafter(half, 1.0f),
                    sixth, std::nextafter(sixth, 0.0f), std::nextafter(sixth, 1.0f)})
        sets.push_back(lat_params(named("pair across", s), 0, 1.5, 4.0, a, s, 33, 7, 0, b));
    // Portrait: the split runs along rows, counted from the strip's first row.
    for (float s : {strip, std::nextafter(strip, 0.0f), std::nextafter(strip, 1.0f)})
        sets.push_back(lat_params(named("pair down a strip", s), 1, 2.0, 4.0, a, s, 9, 40, 7.0, b));
    // The second pair alone (the first frame's rooms 0), as scene_latitude_wanted allows.
    sets.push_back(lat_params("second pair only", 2, 2.0, 4.0, {2.0, 0.0, -2.0, 0.0}, 0.25, 16, 9, 0, b));

    for (const LatParams& set : sets) {
        const auto pattern = latitude_pixels(set.p);
        std::vector<Expect> first, second;   // per pattern pixel, under each frame's knees
        for (const auto& rgb : pattern) {
            for (const Expect& e : latitude_expect(rgb, set.p, false)) first.push_back(e);
            for (const Expect& e : latitude_expect(rgb, set.p, true)) second.push_back(e);
        }
        const size_t period = pattern.size();
        auto want = [&](size_t e) {
            const size_t i = e / 3, k = (i % period) * 3 + e % 3;
            return second_frame(set.p, uint32_t(i)) ? second[k] : first[k];
        };
        const uint32_t frame = uint32_t(set.p[11]) * 30u;   // 30 rows of the frame's width
        const uint32_t counts[] = {0, 1, 255, 256, 257, uint32_t(period), frame};
        for (uint32_t count : counts) {
            BufferRef output;
            if (!run_kernel(gpu, "spk_scene_latitude", pattern, count, set.p, 19, output, error) ||
                !check_output(gpu, output, size_t(count) * 3, want, stats,
                              "latitude " + set.name + " pixels=" + std::to_string(count), error))
                return false;
        }
        if (&set == &sets[4]) {   // the split exactly at a column centre, past the fold
            BufferRef output;
            if (!run_kernel(gpu, "spk_scene_latitude", pattern, kPastFold, set.p, 19, output, error) ||
                !check_output(gpu, output, size_t(kPastFold) * 3, want, stats,
                              "latitude " + set.name + " pixels=" + std::to_string(kPastFold), error))
                return false;
        }
    }
    // The tie must have been a tie: the centre column of 33 sits on 0.5 exactly
    // and takes the second frame, the column before it does not.
    const LatParams& tie = sets[4];
    if (!second_frame(tie.p, 16) || second_frame(tie.p, 15) || second_frame(sets[5].p, 16) == false ||
        second_frame(sets[6].p, 16))
        { error = "latitude: the split cases do not straddle a column centre"; return false; }
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_di_latitude <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    Stats di, latitude;
    if (!check_di(gpu.get(), di, error)) { std::fprintf(stderr, "DI encode: %s\n", error.c_str()); return 1; }
    std::printf("DI encode: %zu cases, max abs error %.3g codes, worst %.2f of its bar at %s; "
                "%zu window-edge pixels allowed either side; NaN/Inf and guards passed\n",
                di.cases, di.largest_error, di.worst_ratio, di.worst_where.c_str(), di.ambiguous);
    if (!check_latitude(gpu.get(), latitude, error)) {
        std::fprintf(stderr, "scene latitude: %s\n", error.c_str()); return 1;
    }
    std::printf("scene latitude: %zu cases, max relative error %.3g, worst %.2f of its bar at %s; "
                "norms, branches, gain clamp, split ties, NaN/Inf and guards passed\n",
                latitude.cases, latitude.largest_relative, latitude.worst_ratio, latitude.worst_where.c_str());
    return 0;
}
