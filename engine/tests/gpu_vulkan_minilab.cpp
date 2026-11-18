// spk_minilab on Vulkan against minilab.metal transcribed into double.
//
// Synthetic inputs at the shapes a render uses: 81 wavelengths, a 256-knot curve, a 65^3 table (the
// size the catalog pins). The densities cover the clamps on both sides of the table's domain, NaN,
// and a large plane past the dispatch fold. Bound: 2e-5 of max(1, |reference|) (float exp2, log
// and a 81-term sum against double).
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
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
constexpr uint32_t L = 81, K = 256, S = 65;

struct In {
    std::vector<float> chd, base, ixs, xa, inv, y, lut;
    float ep[6], lo[3], inv_span[3];
};

double interp(const In& in, uint32_t c, double v) {
    const double x0 = in.xa[c], xn = in.xa[(K - 1) * 3 + c];
    if (v <= x0) return in.y[c];
    if (v >= xn) return in.y[(K - 1) * 3 + c];
    uint32_t lo = 0, hi = K;
    while (lo < hi) {
        const uint32_t mid = lo + ((hi - lo) >> 1);
        if (in.xa[mid * 3 + c] <= v) lo = mid + 1; else hi = mid;
    }
    const uint32_t low = lo - 1;
    const double t = (v - in.xa[low * 3 + c]) * in.inv[low * 3 + c];
    return in.y[low * 3 + c] + t * (in.y[(low + 1) * 3 + c] - in.y[low * 3 + c]);
}

double clamp01_metal(double x) { return (std::isnan(x) || x < 0) ? 0.0 : (x > 1 ? 1.0 : x); }

void reference(const In& in, const float d[3], double out[3]) {
    double a[3] = {0, 0, 0};
    for (uint32_t l = 0; l < L; ++l) {
        const double den = d[0] * double(in.chd[3 * l]) + d[1] * double(in.chd[3 * l + 1]) + d[2] * double(in.chd[3 * l + 2]) + in.base[l];
        const double t = std::pow(10.0, -den);
        for (int c = 0; c < 3; ++c) a[c] += t * in.ixs[3 * l + c];
    }
    double pos[3];
    for (int c = 0; c < 3; ++c) {
        // Metal's max is fmax: NaN gives 0 (std::max would keep the NaN).
        const double v = a[c] * in.ep[c] + in.ep[3 + c];
        pos[c] = interp(in, c, std::log10((std::isnan(v) || v < 0 ? 0.0 : v) + 1e-10));
    }
    double f[3];
    uint32_t i0[3], i1[3];
    for (int c = 0; c < 3; ++c) {
        const double u = clamp01_metal((pos[c] - in.lo[c]) * in.inv_span[c]) * (S - 1);
        i0[c] = uint32_t(std::floor(u));
        i1[c] = std::min(i0[c] + 1, S - 1);
        f[c] = u - i0[c];
    }
    auto at = [&](uint32_t i, uint32_t j, uint32_t k, int ch) { return double(in.lut[((i * S + j) * S + k) * 3 + ch]); };
    for (int ch = 0; ch < 3; ++ch) {
        const double c00 = at(i0[0], i0[1], i0[2], ch) * (1 - f[2]) + at(i0[0], i0[1], i1[2], ch) * f[2];
        const double c01 = at(i0[0], i1[1], i0[2], ch) * (1 - f[2]) + at(i0[0], i1[1], i1[2], ch) * f[2];
        const double c10 = at(i1[0], i0[1], i0[2], ch) * (1 - f[2]) + at(i1[0], i0[1], i1[2], ch) * f[2];
        const double c11 = at(i1[0], i1[1], i0[2], ch) * (1 - f[2]) + at(i1[0], i1[1], i1[2], ch) * f[2];
        out[ch] = (c00 * (1 - f[1]) + c01 * f[1]) * (1 - f[0]) + (c10 * (1 - f[1]) + c11 * f[1]) * f[0];
    }
}

In make_inputs() {
    In in;
    in.chd.resize(L * 3); in.base.resize(L); in.ixs.resize(L * 3);
    for (uint32_t l = 0; l < L; ++l) {
        const double w = double(l) / (L - 1);
        for (int c = 0; c < 3; ++c) {
            const double centre = 0.2 + 0.3 * c;
            in.chd[3 * l + c] = float(std::exp(-std::pow((w - centre) / 0.12, 2)));
            in.ixs[3 * l + c] = float(0.02 * std::exp(-std::pow((w - (0.75 - 0.3 * c)) / 0.1, 2)));
        }
        in.base[l] = float(0.05 + 0.02 * w);
    }
    in.xa.resize(K * 3); in.inv.resize(K * 3); in.y.resize(K * 3);
    for (uint32_t k = 0; k < K; ++k)
        for (int c = 0; c < 3; ++c) {
            in.xa[k * 3 + c] = float(-4.0 + 4.5 * k / (K - 1) + 0.01 * c);
            in.y[k * 3 + c] = float(std::tanh(1.2 * (in.xa[k * 3 + c] + 1.5)) + 0.05 * c);
        }
    for (uint32_t k = 0; k + 1 < K; ++k)
        for (int c = 0; c < 3; ++c) in.inv[k * 3 + c] = float(1.0 / (double(in.xa[(k + 1) * 3 + c]) - in.xa[k * 3 + c]));
    in.lut.resize(size_t(S) * S * S * 3);
    for (uint32_t i = 0; i < S; ++i)
        for (uint32_t j = 0; j < S; ++j)
            for (uint32_t k = 0; k < S; ++k) {
                const double r = double(i) / (S - 1), g = double(j) / (S - 1), b = double(k) / (S - 1);
                const size_t o = ((size_t(i) * S + j) * S + k) * 3;
                in.lut[o] = float(2.2 * r + 0.1 * g * b);
                in.lut[o + 1] = float(2.0 * g + 0.15 * std::sin(3 * r));
                in.lut[o + 2] = float(1.8 * b * b + 0.05 * r);
            }
    const float ep[6] = {1.3f, 1.1f, 0.9f, 0.0f, 0.001f, -0.0005f};
    std::copy(ep, ep + 6, in.ep);
    for (int c = 0; c < 3; ++c) { in.lo[c] = -0.9f + 0.05f * c; in.inv_span[c] = 1.0f / 1.9f; }
    return in;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_minilab <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    const In in = make_inputs();
    std::mt19937 rng(11);
    std::uniform_real_distribution<float> d(-0.5f, 3.5f);
    const uint32_t n = 70003;
    std::vector<float> cmy(size_t(n) * 3);
    for (auto& v : cmy) v = d(rng);
    cmy[0] = cmy[1] = cmy[2] = std::numeric_limits<float>::quiet_NaN();
    cmy[3] = cmy[4] = cmy[5] = 40.0f;      // no light: the table's low corner
    cmy[6] = cmy[7] = cmy[8] = -3.0f;      // more than the base: its high corner
    auto up = [&](const std::vector<float>& v) { return gpu->upload(v.data(), v.size() * sizeof(float), error); };
    auto b_cmy = up(cmy), b_chd = up(in.chd), b_base = up(in.base), b_ixs = up(in.ixs), b_xa = up(in.xa),
         b_inv = up(in.inv), b_y = up(in.y), b_lut = up(in.lut);
    auto b_ep = gpu->upload(in.ep, sizeof in.ep, error), b_lo = gpu->upload(in.lo, sizeof in.lo, error),
         b_is = gpu->upload(in.inv_span, sizeof in.inv_span, error);
    auto b_out = gpu->alloc(size_t(n) * 3 * sizeof(float), error);
    if (!b_cmy || !b_chd || !b_base || !b_ixs || !b_xa || !b_inv || !b_y || !b_lut || !b_ep || !b_lo || !b_is || !b_out) {
        std::fprintf(stderr, "minilab: %s\n", error.c_str());
        return 1;
    }
    const uint32_t meta[4] = {n, L, K, S};
    if (!gpu->dispatch("spk_minilab",
                       {Arg::buf(b_cmy), Arg::buf(b_chd), Arg::buf(b_base), Arg::buf(b_ixs), Arg::buf(b_ep),
                        Arg::inline_bytes(meta, 4), Arg::buf(b_xa), Arg::buf(b_inv), Arg::buf(b_y), Arg::buf(b_lut),
                        Arg::buf(b_lo), Arg::buf(b_is), Arg::buf(b_out)},
                       n, error) || !gpu->flush(error)) {
        std::fprintf(stderr, "minilab: %s\n", error.c_str());
        return 1;
    }
    std::vector<float> out;
    if (!read_test_buffer(gpu.get(), b_out, out, error)) { std::fprintf(stderr, "minilab: %s\n", error.c_str()); return 1; }
    double worst = 0;
    for (uint32_t i = 0; i < n; ++i) {
        double ref[3];
        reference(in, &cmy[3 * i], ref);
        for (int c = 0; c < 3; ++c) {
            const double delta = std::fabs(double(out[3 * i + c]) - ref[c]);
            const double scaled = delta / std::max(1.0, std::fabs(ref[c]));
            worst = std::max(worst, scaled);
            if (!std::isfinite(out[3 * i + c]) || scaled > 2e-5) {
                std::fprintf(stderr, "minilab: pixel %u c%d got %.9g reference %.9g\n", i, c, double(out[3 * i + c]), ref[c]);
                return 1;
            }
        }
    }
    std::printf("minilab: %u pixels vs double (NaN, both table corners, 81 wavelengths, 65^3), max error/max(1,|ref|) %.3g\n", n, worst);
    return 0;
}
