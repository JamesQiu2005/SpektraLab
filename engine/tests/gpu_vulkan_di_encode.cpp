// spk_di_encode on Vulkan against nodes.metal transcribed into double: the Digital Intermediate's
// last pass (log10 positive -> working RGB -> optional Oklab hue window -> Cineon code values).
// Two parameter sets: compensation off, and on with a hue window wide enough that pixels fall
// inside, on its taper and outside. Inputs include NaN, very dark and very bright positives.
// Bound: 3e-5 absolute on code values in 0..1 (about 0.03 of a 10-bit Cineon code).
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <limits>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::Gpu;

template <typename T> T mmax0(T x) { return (std::isnan(x) || x < 0) ? T(0) : x; }
template <typename T> T mclamp01(T x) { return (std::isnan(x) || x < 0) ? T(0) : (x > 1 ? T(1) : x); }

template <typename T>
void reference_t(const std::array<float, 42>& pf, const float in[3], T out[3]) {
    std::array<T, 42> p;
    for (int k = 0; k < 42; ++k) p[k] = pf[k];
    T pos[3];
    for (int c = 0; c < 3; ++c) pos[c] = std::pow(T(10), T(in[c]) + p[9 + c]) - p[40] * std::pow(T(10), p[9 + c]);
    T lin[3] = {pos[0] * p[0] + pos[1] * p[3] + pos[2] * p[6], pos[0] * p[1] + pos[1] * p[4] + pos[2] * p[7],
                     pos[0] * p[2] + pos[1] * p[5] + pos[2] * p[8]};
    if (p[30] != 0) {
        T lms[3];
        for (int r = 0; r < 3; ++r)
            lms[r] = std::cbrt(mmax0(p[12 + 3 * r] * lin[0] + p[13 + 3 * r] * lin[1] + p[14 + 3 * r] * lin[2]));
        const T L = 0.2104542553 * lms[0] + 0.7936177850 * lms[1] - 0.0040720468 * lms[2];
        T a = 1.9779984951 * lms[0] - 2.4285922050 * lms[1] + 0.4505937099 * lms[2];
        T b = 0.0259040371 * lms[0] + 0.7827717662 * lms[1] - 0.8086757660 * lms[2];
        const T C = std::sqrt(a * a + b * b);
        const T h = std::atan2(b, a) * 57.29577951308232;
        const T d = std::fmod(h - p[33] + 540.0, 360.0) - 180.0;
        T w = std::fabs(d) < p[34] ? 0.5 * (1 + std::cos(3.14159265358979 * d / p[34])) : 0.0;
        const T g = mclamp01((C - p[35]) / (p[36] - p[35]));
        w *= g * g * (3 - 2 * g);
        if (w > 0) {
            const T h2 = (h + w * p[31]) * 0.017453292519943295;
            const T C2 = C * (1 + w * (p[32] - 1));
            a = C2 * std::cos(h2);
            b = C2 * std::sin(h2);
            const T l_[3] = {L + 0.3963377774 * a + 0.2158037573 * b, L - 0.1055613458 * a - 0.0638541728 * b,
                                  L - 0.0894841775 * a - 1.2914855480 * b};
            const T cube[3] = {l_[0] * l_[0] * l_[0], l_[1] * l_[1] * l_[1], l_[2] * l_[2] * l_[2]};
            for (int r = 0; r < 3; ++r)
                lin[r] = p[21 + 3 * r] * cube[0] + p[22 + 3 * r] * cube[1] + p[23 + 3 * r] * cube[2];
        }
    }
    for (int c = 0; c < 3; ++c)
        out[c] = mclamp01((p[37] + p[38] * std::log10(mmax0(lin[c]) * (1 - p[41]) + p[41])) / p[39]);
}

void reference(const std::array<float, 42>& pf, const float in[3], double out[3]) { reference_t<double>(pf, in, out); }

std::array<float, 42> params(bool compensation) {
    std::array<float, 42> p{};
    const float m[9] = {0.92f, 0.05f, 0.03f, 0.04f, 0.91f, 0.05f, 0.02f, 0.06f, 0.92f};
    for (int k = 0; k < 9; ++k) p[k] = m[k];
    p[9] = 0.02f; p[10] = -0.01f; p[11] = 0.03f;
    const float to_lms[9] = {0.4122214708f, 0.5363325363f, 0.0514459929f, 0.2119034982f, 0.6806995451f,
                             0.1073969566f, 0.0883024619f, 0.2817188376f, 0.6299787005f};
    const float from_lms[9] = {4.0767416621f, -3.3077115913f, 0.2309699292f, -1.2684380046f, 2.6097574011f,
                               -0.3413193965f, -0.0041960863f, -0.7034186147f, 1.7076147010f};
    for (int k = 0; k < 9; ++k) { p[12 + k] = to_lms[k]; p[21 + k] = from_lms[k]; }
    p[30] = compensation ? 1.0f : 0.0f;
    p[31] = -9.0f;          // hue rotation, degrees
    p[32] = 1.12f;          // chroma scale
    p[33] = 250.0f;         // window centre (blue)
    p[34] = 70.0f;          // half width
    p[35] = 0.01f; p[36] = 0.05f;
    p[37] = 685.0f; p[38] = 300.0f; p[39] = 1023.0f;
    p[40] = 0.04f;
    p[41] = float(std::pow(10.0, (95.0 - 685.0) * 0.002 / 0.6));
    return p;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_di_encode <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    std::mt19937 rng(23);
    std::uniform_real_distribution<float> lg(-2.6f, 0.4f);
    const uint32_t n = 70001;
    std::vector<float> in(size_t(n) * 3);
    for (auto& v : in) v = lg(rng);
    in[0] = in[1] = in[2] = std::numeric_limits<float>::quiet_NaN();
    in[3] = in[4] = in[5] = -12.0f;   // far below the base: code 0
    in[6] = in[7] = in[8] = 3.0f;     // far above white: code 1
    double worst = 0;
    size_t windowed = 0;
    for (bool comp : {false, true}) {
        const auto p = params(comp);
        auto b_in = gpu->upload(in.data(), in.size() * sizeof(float), error);
        auto b_p = gpu->upload(p.data(), sizeof(float) * 42, error);
        auto b_out = gpu->alloc(in.size() * sizeof(float), error);
        const uint32_t count[1] = {n};
        if (!b_in || !b_p || !b_out ||
            !gpu->dispatch("spk_di_encode", {Arg::buf(b_in), Arg::buf(b_p), Arg::inline_bytes(count, 1), Arg::buf(b_out)}, n, error) ||
            !gpu->flush(error)) { std::fprintf(stderr, "di_encode: %s\n", error.c_str()); return 1; }
        std::vector<float> out;
        if (!read_test_buffer(gpu.get(), b_out, out, error)) { std::fprintf(stderr, "di_encode: %s\n", error.c_str()); return 1; }
        const auto p_off = params(false);
        for (uint32_t i = 0; i < n; ++i) {
            double ref[3], plain[3];
            reference(p, &in[3 * i], ref);
            if (comp) { reference(p_off, &in[3 * i], plain); if (std::fabs(plain[0] - ref[0]) + std::fabs(plain[2] - ref[2]) > 1e-4) ++windowed; }
            for (int c = 0; c < 3; ++c) {
                const double delta = std::fabs(double(out[3 * i + c]) - ref[c]);
                worst = std::max(worst, delta);
                if (!std::isfinite(out[3 * i + c]) || delta > 3e-5) {
                    float f32[3];
                    reference_t<float>(p, &in[3 * i], f32);
                    std::fprintf(stderr, "di_encode%s: pixel %u c%d got %.9g reference %.9g (the same maths in float32: %.9g)\n",
                                 comp ? " (compensated)" : "", i, c, double(out[3 * i + c]), ref[c], double(f32[c]));
                    return 1;
                }
            }
        }
    }
    if (windowed < 1000) { std::fprintf(stderr, "di_encode: the hue window moved only %zu pixels\n", windowed); return 1; }
    std::printf("di_encode: %u pixels x 2 (compensation off/on, %zu inside the hue window) vs double, max |error| %.3g of full code\n",
                n, windowed, worst);
    return 0;
}
