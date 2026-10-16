// Contrast-mask gates (RFC-024). The two kernels against a C++ double
// transcription of contrast_mask.metal -- partial and clamped cells at the
// frame's edges, bands that start mid-frame, one-cell grids, the log2 floor,
// NaN and the pre-flash clamp, and one count per kernel past 65535 x 256
// threads -- then the feature end to end through the C API: the field, a
// reprint that keeps the negative, striped against whole-frame, the worker
// partition, and mask-off returning to the unmasked bytes.
//
// Local kernel validation and behavioural checks, not whole-frame Metal
// parity: no Mac dump of a masked render exists to compare against yet.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"
#include "spektrafilm/spk_engine.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;

constexpr float kGuard = -24680.5f;
constexpr size_t kGuards = 13;
constexpr uint32_t kLambdas = 81;
constexpr double kLog2Floor = -20.0;   // contrast_mask.metal's kMaskLog2Floor
constexpr double kGainLimit = 6.0, kReach = 4.0;   // contrast_mask.cpp's constants
// 65535 groups of 256: the most a device at the spec minimum dispatches in
// one row (lavapipe, Intel). One past it folds into a second row there; on a
// device with a larger limit (the RTX 3070 reports 2^31 - 1) the same case is
// one long row, so there it checks the count and not the fold.
constexpr uint64_t kFoldThreads = 65535ull * 256ull;

size_t cases = 0;
double reduce_error = 0, epilogue_error = 0;
// Reference pixels on each path of the epilogue -- lowered, raised, the core,
// and an exposure clamped at 0 -- so a gate that never reached one says so.
size_t engaged[4] = {0, 0, 0, 0};

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

uint32_t hash(uint32_t i, uint32_t salt) {
    uint32_t h = i * 2654435761u ^ (salt + 1u) * 0x9E3779B9u;
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
    return h;
}
float unit(uint32_t i, uint32_t salt) { return float(hash(i, salt) >> 8) / 16777216.0f; }

// A stand-in for the enlarger's constants with the shapes that matter: three
// overlapping dye bands, three paper sensitivities, and zeroed sensitivity
// rows at both ends (the rows prepare_spectral_constants neutralises).
struct Spectral { std::vector<float> chd, base, ixs; };

Spectral make_spectral() {
    Spectral s;
    s.chd.resize(3 * kLambdas); s.base.resize(kLambdas); s.ixs.resize(3 * kLambdas);
    const double dye[3] = {62, 36, 14}, sens[3] = {64, 34, 12};
    for (uint32_t l = 0; l < kLambdas; ++l) {
        for (int c = 0; c < 3; ++c) {
            const double dd = (l - dye[c]) / 9.0, ds = (l - sens[c]) / 5.0;
            s.chd[3 * l + c] = float(0.08 + 0.95 * std::exp(-dd * dd));
            s.ixs[3 * l + c] = (l < 2 || l > 78) ? 0.0f : float(0.02 * std::exp(-ds * ds));
        }
        const double db = (l - 6.0) / 10.0;
        s.base[l] = float(0.04 + 0.12 * std::exp(-db * db));
    }
    return s;
}

// --- the double transcription of contrast_mask.metal ---------------------

std::array<double, 3> exposure(const float* rgb, const Spectral& s, const float* p) {
    double a[3] = {0, 0, 0};
    for (uint32_t l = 0; l < kLambdas; ++l) {
        const double d = double(rgb[0]) * s.chd[3 * l] + double(rgb[1]) * s.chd[3 * l + 1] +
                         double(rgb[2]) * s.chd[3 * l + 2] + s.base[l];
        const double t = std::exp2(-d * 3.321928094887362);
        for (int c = 0; c < 3; ++c) a[c] += t * s.ixs[3 * l + c];
    }
    return {a[0] * p[0], a[1] * p[1], a[2] * p[2]};
}

// Metal's max is NaN-tolerant and log2(0) is -inf; std::fmax and std::log2
// behave the same, so the floor catches zero, negative and NaN alike.
double mask_x(const std::array<double, 3>& a, const float* p) {
    double s = 0;
    for (int c = 0; c < 3; ++c) s += std::fmax(std::log2(std::fmax(a[c] * p[3 + c], 0.0)), kLog2Floor);
    return s / 3.0;
}

double mask_g(double d, double h) { return d * h / std::sqrt(h * h + d * d); }

double mask_delta(double b, const float* p) {
    double delta = 0;
    if (p[11] != 0.0f && b < p[9]) { const double d = double(p[9]) - b; delta = d - mask_g(d, p[10]); }
    else if (p[14] != 0.0f && b > p[12]) { const double d = b - double(p[12]); delta = mask_g(d, p[13]) - d; }
    const double lim = p[15];
    return delta * lim / std::sqrt(lim * lim + delta * delta);
}

// contrast_mask.cpp's `room_for`, so the parameter blocks are the product's.
double room_for(double amount) {
    const double L = kGainLimit, R = kReach;
    const double delta = amount * L / std::sqrt(L * L - amount * amount);
    const double t = std::max(R - delta, 1e-3);
    return R * t / std::sqrt(R * R - t * t);
}

// --- inputs ----------------------------------------------------------------

// A frame of negative densities: a diagonal ramp wide enough to reach past
// both knees, per-pixel texture, and three planted pixels -- a density that
// underflows the integral to 0 (the floor), a NaN (the floor through Metal's
// NaN-tolerant max), and a thin negative that lands far above mid-grey.
std::vector<float> make_frame(uint32_t W, uint32_t H) {
    std::vector<float> cmy(size_t(W) * H * 3);
    for (uint32_t y = 0; y < H; ++y)
        for (uint32_t x = 0; x < W; ++x) {
            const uint32_t i = y * W + x;
            const float ramp = 0.6f * (float(x) + 0.5f) / float(W) + 0.4f * (float(y) + 0.5f) / float(H);
            for (uint32_t c = 0; c < 3; ++c)
                cmy[3 * size_t(i) + c] = -0.3f + 2.4f * ramp + 0.25f * (unit(i, c) - 0.5f) + 0.05f * float(c);
        }
    const size_t n = size_t(W) * H;
    if (n > 3) for (int c = 0; c < 3; ++c) cmy[3 * 3 + c] = 40.0f;
    if (n > 5) cmy[3 * 5 + 1] = std::numeric_limits<float>::quiet_NaN();
    if (n > 7) for (int c = 0; c < 3; ++c) cmy[3 * 7 + c] = -3.0f;
    return cmy;
}

// A parameter block as prepare_contrast_mask writes it, with 1 / A_ref taken
// from a mid density so that x = 0 falls inside the frame's range.
struct Block { std::array<float, 16> p; const char* name; };

std::vector<Block> make_blocks(const Spectral& s) {
    const float gain[3] = {1.3f, 0.9f, 1.1f};
    const float mid[3] = {0.8f, 0.8f, 0.8f};
    float unit_gain[16] = {gain[0], gain[1], gain[2], 1, 1, 1};
    const auto a_ref = exposure(mid, s, unit_gain);
    auto block = [&](double core, double hi, double sh, float f0, float f1, float f2, const char* name) {
        Block b{{gain[0], gain[1], gain[2], float(1 / a_ref[0]), float(1 / a_ref[1]), float(1 / a_ref[2]),
                 f0, f1, f2,
                 float(-core), float(hi > 0 ? room_for(hi) : 1.0), hi > 0 ? 1.0f : 0.0f,
                 float(core), float(sh > 0 ? room_for(sh) : 1.0), sh > 0 ? 1.0f : 0.0f,
                 float(kGainLimit)}, name};
        return b;
    };
    return {block(1.0, 1.5, 1.0, 0.002f, 0.004f, 0.0f, "both branches, pre-flash"),
            block(0.5, 2.5, 0.0, 0.0f, 0.0f, 0.0f, "highlights only"),
            // A negative offset is not a real pre-flash; it drives the
            // exposure below zero so the max(..., 0) branch is exercised.
            block(2.0, 0.0, 3.0, -0.5f, -0.5f, -0.5f, "shadows only, clamped exposure")};
}

BufferRef guarded(Gpu* gpu, size_t count, std::string& error) {
    const std::vector<float> values(count + kGuards, kGuard);
    return gpu->upload(values.data(), values.size() * sizeof(float), error);
}

// Every index for a small case; for a fold case the first and last 300 and a
// stride through the middle -- the reference costs 81 exp2 per pixel.
std::vector<size_t> sample(size_t count) {
    std::vector<size_t> out;
    if (count <= 70000) { for (size_t i = 0; i < count; ++i) out.push_back(i); return out; }
    for (size_t i = 0; i < 300; ++i) out.push_back(i);
    for (size_t i = 300; i + 300 < count; i += 4099) out.push_back(i);
    for (size_t i = count - 300; i < count; ++i) out.push_back(i);
    return out;
}

// The readback is the whole allocation, which the pool may round up; the
// guards are the values just past the logical output.
void check_guards(const std::vector<float>& actual, size_t count, const std::string& label) {
    require(actual.size() >= count + kGuards, label + ": readback size");
    for (size_t i = count; i < count + kGuards; ++i)
        require(actual[i] == kGuard, label + ": wrote past its logical output");
}

void compare(double got, double want, double abs_tol, double rel_tol, double& largest,
             const std::string& label, size_t index) {
    const double delta = std::fabs(got - want);
    if (!std::isfinite(got) || !(delta <= abs_tol + rel_tol * std::fabs(want))) {
        char detail[256];
        std::snprintf(detail, sizeof detail, " index=%zu got=%.9g expected=%.17g error=%.3g", index, got, want, delta);
        throw std::runtime_error(label + detail);
    }
    largest = std::max(largest, delta);
}

// --- spk_mask_reduce ---------------------------------------------------------

// x is in stops; relative 1e-6 in an 81-term float sum of exp2 is 1.4e-6
// stops after log2. Measured 9.0e-7 on an RTX 3070; the bar leaves room for
// drivers whose exp2/log2 use the spec's wider ulp allowance.
constexpr double kReduceAbs = 2e-5;

// The reduce reads only p[0..5], which every block shares, so it runs once.
void check_reduce(Gpu* gpu, const Spectral& s, const BufferRef& chd, const BufferRef& base,
                  const BufferRef& ixs, const Block& block) {
    struct Case { uint32_t W, H, gw, gh; };
    const Case reduce_cases[] = {
        {1, 1, 1, 1},          // one pixel, one cell
        {7, 5, 3, 2},          // partial cells: widths 2, 2, 3 and heights 2, 3
        {5, 3, 8, 4},          // more cells than pixels: max(x1, x0 + 1) and min(x1, W)
        {37, 23, 5, 7},        // uneven partition on both axes
        {64, 48, 64, 48},      // one pixel per cell
        {300, 200, 128, 85},   // the production shape: a few pixels per cell
        {4100, 4093, 4100, 4093},   // 16.78 M cells, past the 65535-group fold
    };
    std::string error;
    BufferRef p = gpu->upload(block.p.data(), sizeof block.p, error);
    require(bool(p), "params upload: " + error);
    for (const Case& k : reduce_cases) {
        const std::string label = "reduce " + std::to_string(k.W) + "x" + std::to_string(k.H) + " grid " +
                                  std::to_string(k.gw) + "x" + std::to_string(k.gh) + " [" + block.name + "]";
        const size_t cells = size_t(k.gw) * k.gh;
        const std::vector<float> cmy = make_frame(k.W, k.H);
        BufferRef input = gpu->upload(cmy.data(), cmy.size() * sizeof(float), error);
        BufferRef output = guarded(gpu, cells, error);
        require(input && output, label + ": upload: " + error);
        const uint32_t meta[5] = {k.W, k.H, k.gw, k.gh, kLambdas};
        // Dispatch first, then build the message: as one call's arguments the
        // message could be evaluated before `error` is written.
        const bool dispatched = gpu->dispatch("spk_mask_reduce",
                                              {Arg::buf(input), Arg::buf(chd), Arg::buf(base), Arg::buf(ixs),
                                               Arg::buf(p), Arg::inline_bytes(meta, 5), Arg::buf(output)},
                                              cells, error);
        require(dispatched, label + ": dispatch: " + error);
        std::vector<float> actual;
        const bool read = read_test_buffer(gpu, output, actual, error);
        require(read, label + ": readback: " + error);
        check_guards(actual, cells, label);
        for (size_t cell : sample(cells)) {
            // The cell bounds in the kernel's own uint32 arithmetic; the mean
            // in double.
            const uint32_t cy = uint32_t(cell / k.gw), cx = uint32_t(cell % k.gw);
            const uint32_t x0 = (cx * k.W) / k.gw, y0 = (cy * k.H) / k.gh;
            const uint32_t x1 = std::min(std::max(((cx + 1) * k.W) / k.gw, x0 + 1), k.W);
            const uint32_t y1 = std::min(std::max(((cy + 1) * k.H) / k.gh, y0 + 1), k.H);
            double acc = 0;
            for (uint32_t y = y0; y < y1; ++y)
                for (uint32_t x = x0; x < x1; ++x)
                    acc += mask_x(exposure(&cmy[3 * (size_t(y) * k.W + x)], s, block.p.data()), block.p.data());
            compare(actual[cell], acc / double((x1 - x0) * (y1 - y0)), kReduceAbs, 0, reduce_error, label, cell);
        }
        // The planted pixels' own cells in the one-pixel-per-cell cases: the
        // floor is exact, not approximately -20.
        if (k.gw == k.W && k.gh == k.H && cells > 5) {
            require(actual[3] == float(kLog2Floor), label + ": an underflowed exposure missed the floor");
            require(actual[5] == float(kLog2Floor), label + ": a NaN density missed the floor");
        }
        ++cases;
    }
}

// --- spk_mask_epilogue -------------------------------------------------------

// log10 of exposure: ~1e-6 relative error in the exposure is 4e-7, and the
// base's error reaches the gain through a slope below 1. Measured 9.5e-7 on
// an RTX 3070.
constexpr double kEpilogueAbs = 1e-5, kEpilogueRel = 1e-6;

// The coefficients are smooth over the grid (the Gaussian base is): a sample
// position differing by a rounding then moves the base by little, so the bar
// is about the integral and the curve rather than about cell contrast.
std::vector<float> make_coef(uint32_t gw, uint32_t gh, int mode) {
    std::vector<float> coef(2 * size_t(gw) * gh);
    for (uint32_t cy = 0; cy < gh; ++cy)
        for (uint32_t cx = 0; cx < gw; ++cx) {
            const size_t i = size_t(cy) * gw + cx;
            const double fx = (cx + 0.5) / gw, fy = (cy + 0.5) / gh;
            double a = 0, b = -3.0 + 6.0 * (0.6 * fx + 0.4 * fy) + 0.3 * std::cos(0.41 * cx - 0.29 * cy);
            if (mode == 1) a = 0.5 + 0.25 * std::sin(0.37 * cx + 0.23 * cy);   // the guided filter's shape
            if (mode == 2) { a = 1; b = 0; }                                    // RFC-024 §9.1's pointwise arm
            coef[2 * i] = float(a);
            coef[2 * i + 1] = float(b);
        }
    return coef;
}

// `fold` adds the 16.78 M-pixel case; one block and one coefficient mode of
// it is enough to show the folded index, and each costs ~600 MB of host copies.
void check_epilogue(Gpu* gpu, const Spectral& s, const BufferRef& chd, const BufferRef& base,
                    const BufferRef& ixs, const Block& block, bool fold) {
    struct Case { uint32_t W, H, row0, h, gw, gh; };
    const Case epilogue_cases[] = {
        {1, 1, 0, 1, 1, 1},
        {37, 23, 0, 23, 5, 7},       // whole frame, uneven cells
        {37, 23, 5, 11, 5, 7},       // a band starting mid-frame: the field at frame rows
        {37, 23, 22, 1, 5, 7},       // the frame's last row alone
        {64, 48, 0, 48, 64, 48},     // one cell per pixel
        {19, 300, 100, 150, 1, 9},   // one column of cells: u clamps both ways to 0
        {257, 3, 0, 3, 128, 1},      // one row of cells
        {4100, 4093, 0, 4093, 512, 511},   // 16.78 M pixels, past the fold
    };
    std::string error;
    BufferRef p = gpu->upload(block.p.data(), sizeof block.p, error);
    require(bool(p), "params upload: " + error);
    for (const Case& k : epilogue_cases) {
        const size_t n = size_t(k.W) * k.h;
        if (n > kFoldThreads && !fold) continue;
        // The band's rows only, as the striped executor hands them over.
        std::vector<float> cmy = make_frame(k.W, k.H);
        cmy.erase(cmy.begin() + 3 * (size_t(k.row0) + k.h) * k.W, cmy.end());
        cmy.erase(cmy.begin(), cmy.begin() + 3 * size_t(k.row0) * k.W);
        BufferRef input = gpu->upload(cmy.data(), cmy.size() * sizeof(float), error);
        require(bool(input), "epilogue upload: " + error);
        for (int mode = 0; mode < 3; ++mode) {
            if (n > kFoldThreads && mode != 0) continue;
            const std::string label = "epilogue " + std::to_string(k.W) + "x" + std::to_string(k.H) + " rows " +
                                      std::to_string(k.row0) + "+" + std::to_string(k.h) + " grid " +
                                      std::to_string(k.gw) + "x" + std::to_string(k.gh) + " coef " +
                                      std::to_string(mode) + " [" + block.name + "]";
            const std::vector<float> coef = make_coef(k.gw, k.gh, mode);
            BufferRef coef_buf = gpu->upload(coef.data(), coef.size() * sizeof(float), error);
            BufferRef output = guarded(gpu, 3 * n, error);
            require(coef_buf && output, label + ": upload: " + error);
            const uint32_t meta[7] = {uint32_t(n), kLambdas, k.W, k.H, k.row0, k.gw, k.gh};
            const bool dispatched = gpu->dispatch("spk_mask_epilogue",
                                                  {Arg::buf(input), Arg::buf(chd), Arg::buf(base), Arg::buf(ixs),
                                                   Arg::buf(p), Arg::buf(coef_buf), Arg::inline_bytes(meta, 7),
                                                   Arg::buf(output)},
                                                  n, error);
            require(dispatched, label + ": dispatch: " + error);
            std::vector<float> actual;
            const bool read = read_test_buffer(gpu, output, actual, error);
            require(read, label + ": readback: " + error);
            check_guards(actual, 3 * n, label);
            const float* q = block.p.data();
            for (size_t i : sample(n)) {
                const auto a = exposure(&cmy[3 * i], s, q);
                const uint32_t px = uint32_t(i % k.W), py = k.row0 + uint32_t(i / k.W);
                // The sample position in float, as Metal computes it -- the
                // bilinear weights are the kernel's own up to the GPU's
                // division rounding -- and everything after it in double.
                auto position = [](uint32_t pixel, uint32_t cells, uint32_t extent) {
                    const float t = (float(pixel) + 0.5f) * float(cells) / float(extent) - 0.5f;
                    return std::fmin(std::fmax(t, 0.0f), float(cells - 1));
                };
                const float u = position(px, k.gw, k.W), v = position(py, k.gh, k.H);
                const uint32_t u0 = uint32_t(std::floor(u)), v0 = uint32_t(std::floor(v));
                const uint32_t u1 = std::min(u0 + 1, k.gw - 1), v1 = std::min(v0 + 1, k.gh - 1);
                const double tu = double(u) - u0, tv = double(v) - v0;
                double ab[2];
                for (int j = 0; j < 2; ++j) {
                    auto c = [&](uint32_t cu, uint32_t cv) { return double(coef[2 * (size_t(cv) * k.gw + cu) + j]); };
                    const double top = c(u0, v0) + (c(u1, v0) - c(u0, v0)) * tu;
                    const double bottom = c(u0, v1) + (c(u1, v1) - c(u0, v1)) * tu;
                    ab[j] = top + (bottom - top) * tv;
                }
                const double base_x = ab[0] * mask_x(a, q) + ab[1];
                const double delta = mask_delta(base_x, q);
                const double gain = std::exp2(delta);
                ++engaged[delta < 0 ? 0 : delta > 0 ? 1 : 2];
                for (int c = 0; c < 3; ++c) {
                    if (!(gain * a[c] + q[6 + c] > 0.0)) ++engaged[3];
                    const double e = std::fmax(gain * a[c] + q[6 + c], 0.0) + double(1e-10f);
                    compare(actual[3 * i + c], std::log10(e), kEpilogueAbs, kEpilogueRel, epilogue_error,
                            label, 3 * i + c);
                }
            }
            ++cases;
        }
    }
}

// --- end to end --------------------------------------------------------------

void set_mask_threads(const char* value) {
#ifdef _WIN32
    _putenv_s("SPEKTRAFILM_MASK_THREADS", value ? value : "");
#else
    if (value) setenv("SPEKTRAFILM_MASK_THREADS", value, 1); else unsetenv("SPEKTRAFILM_MASK_THREADS");
#endif
}

struct Frame { std::vector<uint16_t> rgba; uint32_t w = 0, h = 0; int reprint = 0, cached = 0; };

Frame print(spk_engine* engine, spk_session* session, bool reprint, const char* what) {
    spk_result result{};
    const spk_status status = reprint ? spk_reprint(session, "full", &result) : spk_render(session, "full", &result);
    const std::string error = spk_last_error(engine);
    Frame f;
    const bool valid = status == SPK_OK && result.rgba16 && result.width && result.height;
    if (valid) {
        f.w = result.width; f.h = result.height; f.reprint = result.reprint; f.cached = result.negative_was_cached;
        f.rgba.resize(size_t(f.w) * f.h * 4);
        for (uint32_t y = 0; y < f.h; ++y)
            std::memcpy(&f.rgba[size_t(y) * f.w * 4], result.rgba16 + size_t(y) * result.row_stride_px * 4,
                        size_t(f.w) * 4 * sizeof(uint16_t));
    }
    spk_result_free(&result);
    require(valid, std::string(what) + " failed: " + error);
    return f;
}

void apply_delta(spk_engine* engine, spk_session* session, const char* delta) {
    const bool ok = spk_set_params(session, delta, nullptr) == SPK_OK;
    require(ok, std::string("set_params ") + delta + ": " + spk_last_error(engine));
}

struct Field { std::vector<float> delta; uint32_t gw = 0, gh = 0; double ms = 0; };

Field field(spk_engine* engine, spk_session* session) {
    const float* values = nullptr;
    Field f;
    const auto start = std::chrono::steady_clock::now();
    const bool ok = spk_contrast_mask_field(session, "full", &values, &f.gw, &f.gh) == SPK_OK;
    require(ok, std::string("spk_contrast_mask_field: ") + spk_last_error(engine));
    f.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    if (values) f.delta.assign(values, values + size_t(f.gw) * f.gh);
    return f;
}

size_t differing(const Frame& a, const Frame& b) {
    size_t n = 0;
    for (size_t i = 0; i < a.rgba.size(); ++i) n += a.rgba[i] != b.rgba[i];
    return n;
}

void check_end_to_end(const char* resources) {
    std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)> engine(spk_engine_create(resources, nullptr),
                                                                      spk_engine_destroy);
    require(bool(engine), std::string("engine creation failed: ") + spk_last_error(nullptr));
    spk_engine* e = engine.get();

    // Long edge 640 > the grid's 512-cell minimum, so the field is on the
    // canonical grid rather than capped at the frame. A horizontal ramp of
    // ten stops around mid-grey reaches past both knees; a bright block in
    // the dark half and a dark one in the bright half give the base local
    // structure.
    const uint32_t W = 640, H = 400;
    std::vector<float> pixels(size_t(W) * H * 3);
    for (uint32_t y = 0; y < H; ++y)
        for (uint32_t x = 0; x < W; ++x) {
            double stops = -6.0 + 10.0 * (x + 0.5) / W;
            if (x > 80 && x < 160 && y > 120 && y < 280) stops = 2.5;
            if (x > 480 && x < 560 && y > 120 && y < 280) stops = -4.5;
            const double v = 0.184 * std::exp2(stops);
            const double tint[3] = {1.0, 0.92 + 0.1 * y / H, 0.8};
            for (int c = 0; c < 3; ++c) pixels[3 * (size_t(y) * W + x) + c] = float(v * tint[c]);
        }
    const spk_image input{pixels.data(), W, H, 3};
    // Grain, glare and auto exposure off: every comparison below is exact.
    const char* fixed = "{\"film_stock\":\"kodak_portra_400\",\"print_stock\":\"kodak_portra_endura\","
                        "\"input_color_space\":\"ProPhoto RGB\",\"input_cctf_decoding\":false,"
                        "\"grain_active\":false,\"glare_active\":false,\"auto_exposure\":false}";
    std::unique_ptr<spk_session, decltype(&spk_session_release)> owned(spk_open(e, &input, fixed, nullptr),
                                                                       spk_session_release);
    require(bool(owned), std::string("open failed: ") + spk_last_error(e));
    spk_session* session = owned.get();

    const Frame plain = print(e, session, false, "unmasked render");
    require(plain.w == W && plain.h == H, "the full tier is not the frame's own size");
    require(field(e, session).delta.empty(), "a disabled mask must have an empty field");

    apply_delta(e, session, "{\"contrast_mask_active\":true,\"contrast_mask_highlights\":1.5,"
                    "\"contrast_mask_shadows\":1.0}");
    const Frame masked = print(e, session, true, "masked reprint");
    // API-SPEC §11 / RFC-024 §8: a mask edit reprints; it never re-develops.
    require(masked.reprint == 1 && masked.cached == 1, "a mask edit re-developed the negative");
    const size_t changed = differing(plain, masked);
    require(changed > masked.rgba.size() / 10, "the mask moved too few values: " + std::to_string(changed));

    // The field on the canonical grid: 512 cells on the long edge at the
    // default scale (4 cells per sigma asks for 134, the floor is 512).
    set_mask_threads(nullptr);
    const Field f = field(e, session);
    const uint32_t want_gh = uint32_t(std::lround(double(H) * 512 / W));
    require(f.gw == 512 && f.gh == want_gh && f.delta.size() == size_t(f.gw) * f.gh,
            "field grid " + std::to_string(f.gw) + "x" + std::to_string(f.gh));
    double lo = 0, hi = 0;
    for (float d : f.delta) {
        require(std::isfinite(d) && std::fabs(d) < kGainLimit, "field value not finite or past the gain limit");
        lo = std::min(lo, double(d)); hi = std::max(hi, double(d));
    }
    require(lo < -0.05 && hi > 0.05, "the field does not move both ends: min " + std::to_string(lo) +
                                         " max " + std::to_string(hi));

    // The worker partition of the host blur cannot change a bit: one worker
    // is the serial loop, three split 320 rows and 512 columns unevenly.
    // Interleaved five times, so the printed medians are not one noisy call.
    std::vector<double> all_ms, one_ms;
    for (int round = 0; round < 5; ++round) {
        const Field every = field(e, session);
        set_mask_threads("1");
        const Field serial = field(e, session);
        set_mask_threads("3");
        const Field three = field(e, session);
        set_mask_threads(nullptr);
        require(every.delta == f.delta && serial.delta == f.delta && three.delta == f.delta,
                "the field depends on the worker count");
        all_ms.push_back(every.ms);
        one_ms.push_back(serial.ms);
    }
    std::sort(all_ms.begin(), all_ms.end());
    std::sort(one_ms.begin(), one_ms.end());

    // Asking for the field does not disturb the next print, and a striped
    // print samples the field at frame rows exactly as the whole frame does.
    const Frame again = print(e, session, true, "masked reprint after the field");
    require(again.cached == 1 && again.rgba == masked.rgba, "the field call changed the next print");
    apply_delta(e, session, "{\"striped\":true,\"strip_rows\":37}");
    const Frame striped = print(e, session, true, "striped masked reprint");
    apply_delta(e, session, "{\"striped\":false,\"strip_rows\":0}");
    require(striped.cached == 1, "the striped reprint re-developed the negative");
    require(striped.rgba == masked.rgba, "striped and whole-frame masked prints differ in " +
                                             std::to_string(differing(striped, masked)) + " values");

    apply_delta(e, session, "{\"contrast_mask_active\":false}");
    const Frame off = print(e, session, true, "reprint with the mask off");
    require(off.cached == 1 && off.rgba == plain.rgba, "mask off did not return to the unmasked print");
    require(field(e, session).delta.empty(), "the field is not empty after the mask was turned off");

    std::printf("end to end: %ux%u, %zu of %zu values moved by the mask, field %ux%u in [%.4f, %.4f] stops; "
                "field median %.1f ms with every core, %.1f ms with one, bit-identical; striped == whole "
                "frame; mask off == unmasked\n",
                W, H, changed, masked.rgba.size(), f.gw, f.gh, lo, hi, all_ms[2], one_ms[2]);
}

// Its own scope: every BufferRef must drop before the device that made it.
void check_kernels(const char* resources) {
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(resources) + "/vulkan", error));
    require(bool(gpu), "Vulkan device: " + error);
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    const Spectral s = make_spectral();
    BufferRef chd = gpu->upload(s.chd.data(), s.chd.size() * sizeof(float), error);
    BufferRef base = gpu->upload(s.base.data(), s.base.size() * sizeof(float), error);
    BufferRef ixs = gpu->upload(s.ixs.data(), s.ixs.size() * sizeof(float), error);
    require(chd && base && ixs, "constants upload: " + error);
    const std::vector<Block> blocks = make_blocks(s);
    check_reduce(gpu.get(), s, chd, base, ixs, blocks.front());
    for (const Block& block : blocks)
        check_epilogue(gpu.get(), s, chd, base, ixs, block, &block == &blocks.front());
    require(engaged[0] && engaged[1] && engaged[2] && engaged[3],
            "the epilogue cases did not reach every path (lowered, raised, core, clamped)");
    std::printf("kernels: %zu cases against the double transcription; max abs error reduce %.3g stops "
                "(bar %.0e), epilogue %.3g log10 (bar %.0e + %.0e rel); paths lowered/raised/core/clamped "
                "%zu/%zu/%zu/%zu; guards intact\n",
                cases, reduce_error, kReduceAbs, epilogue_error, kEpilogueAbs, kEpilogueRel,
                engaged[0], engaged[1], engaged[2], engaged[3]);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_contrast_mask <resources>\n"); return 2; }
    try {
        check_kernels(argv[1]);
        check_end_to_end(argv[1]);
        return 0;
    } catch (const std::exception& failure) {
        std::fprintf(stderr, "contrast mask: %s\n", failure.what());
        return 1;
    }
}
