// spk_scene_latitude and spk_scene_curve on Vulkan against scene_latitude.metal in double.
//
// Scene latitude: the three norms (power, Y, max), the m = 1, m = 2 and general roll-offs, a highlight
// and a shadow branch, the bounded lift, a half-frame split on either long edge, and pathological
// pixels (zero, negative, NaN, infinite: k = 1, passed through). Decode curve: a five-row table
// with Film Exposure, values past both ends, and the same pathological pixels.
// Bound: 2e-5 of max(1, |reference|) (float log2/exp2/pow against double).
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

double mmax0(double x) { return (std::isnan(x) || x < 0) ? 0.0 : x; }

double departure(double D, double H, double m) {
    if (!(D > 0)) return 0;
    if (m == 2) { const double r = std::sqrt(H * H + D * D); return -(D * D * D) / (r * (H + r)); }
    if (m == 1) return -(D * D) / (H + D);
    return D * (H / std::pow(std::pow(H, m) + std::pow(D, m), 1 / m) - 1);
}

void latitude_ref(const std::vector<float>& p, uint32_t i, const float in[3], double out[3]) {
    const double cr = mmax0(in[0]), cg = mmax0(in[1]), cb = mmax0(in[2]);
    double v;
    const uint32_t norm = uint32_t(p[6]);
    if (norm == 1) v = p[7] * cr + p[8] * cg + p[9] * cb;
    else if (norm == 2) v = std::max(cr, std::max(cg, cb));
    else { const double s2 = cr * cr + cg * cg + cb * cb; v = s2 > 0 ? (cr * cr * cr + cg * cg * cg + cb * cb * cb) / s2 : 0; }
    double k = 1;
    if (v > 0 && std::isfinite(v)) {
        const double nref = p[10];
        const double E = std::clamp(std::log2(std::max(v, nref * std::exp2(-24.0)) / nref), -24.0, 24.0);
        double d = 0, Kh = p[0], Hh = p[1], Ks = p[2], Hs = p[3];
        if (p[13] > 0) {
            const uint32_t w = uint32_t(p[11]), h = uint32_t(p[12]);
            const double along = w >= h ? (double(i % w) + 0.5) / w : (double(i / w) + p[18] + 0.5) / h;
            if (along >= p[13]) { Kh = p[14]; Hh = p[15]; Ks = p[16]; Hs = p[17]; }
        }
        if (Hh > 0 && E > Kh) d = departure(E - Kh, Hh, p[4]);
        else if (Hs > 0 && E < Ks) d = -departure(Ks - E, Hs, p[4]);
        if (d > 0) { const double L = p[5]; d = d * L / std::sqrt(L * L + d * d); }
        k = std::clamp(std::exp2(d), std::exp2(-30.0), std::exp2(30.0));
    }
    for (int c = 0; c < 3; ++c) out[c] = in[c] * k;
}

double curve_gain(double v, const std::vector<float>& t, uint32_t row, uint32_t n, double S, double nref, double c) {
    if (!(v > 0) || !std::isfinite(v)) return 1;
    const double E = std::log2(v / nref) + c;
    const double u = std::clamp((E + S) / (2 * S), 0.0, 1.0);
    const double x = u * (n - 1);
    const uint32_t i = std::min(uint32_t(x), n - 2);
    const double f = x - i;
    const double y = t[row * n + i] + (t[row * n + i + 1] - t[row * n + i]) * f;
    return std::clamp(std::exp2(2 * S * (y - u)), std::exp2(-30.0), std::exp2(30.0));
}

void curve_ref(const std::vector<float>& p, const std::vector<float>& t, const float in[3], double out[3]) {
    const uint32_t n = uint32_t(p[0]);
    const double S = p[1], nref = p[2], ec = p[6];
    double c[3] = {in[0], in[1], in[2]};
    const double y = p[3] * mmax0(c[0]) + p[4] * mmax0(c[1]) + p[5] * mmax0(c[2]);
    const double gy = curve_gain(y, t, 1, n, S, nref, ec);
    for (double& v : c) v *= gy;
    for (double& v : c) v *= curve_gain(v, t, 0, n, S, nref, ec);
    for (int k = 0; k < 3; ++k) c[k] *= curve_gain(c[k], t, 2 + k, n, S, nref, ec);
    for (int k = 0; k < 3; ++k) out[k] = c[k];
}

bool compare(Gpu* gpu, const spk::gpu::BufferRef& b, const std::vector<std::vector<double>>& ref, const char* name,
             double& worst, std::string& error) {
    std::vector<float> out;
    if (!gpu->flush(error) || !read_test_buffer(gpu, b, out, error)) return false;
    for (size_t i = 0; i < ref.size(); ++i)
        for (int c = 0; c < 3; ++c) {
            const double r = ref[i][c], g = out[3 * i + c];
            const bool both_nan = std::isnan(r) && std::isnan(g);
            const double delta = std::fabs(g - r) / std::max(1.0, std::fabs(r));
            if (!both_nan && !(std::isinf(r) && g == r)) {
                worst = std::max(worst, delta);
                if (!(delta <= 2e-5)) {
                    char m[200];
                    std::snprintf(m, sizeof m, "%s: pixel %zu c%d got %.9g reference %.9g", name, i, c, g, r);
                    error = m;
                    return false;
                }
            }
        }
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_scene <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    std::mt19937 rng(31);
    std::lognormal_distribution<float> lum(-1.7f, 2.2f);
    std::uniform_real_distribution<float> tint(0.6f, 1.4f);
    const uint32_t W = 301, H = 233, N = W * H;
    std::vector<float> rgb(size_t(N) * 3);
    for (uint32_t i = 0; i < N; ++i) {
        const float l = lum(rng);
        for (int c = 0; c < 3; ++c) rgb[3 * i + c] = l * tint(rng);
    }
    const float inf = std::numeric_limits<float>::infinity(), nan = std::numeric_limits<float>::quiet_NaN();
    const float odd[][3] = {{0, 0, 0}, {-0.2f, -0.1f, -0.3f}, {nan, 0.2f, 0.3f}, {inf, 1, 1}, {-0.5f, 0.8f, 0.1f}, {1e-12f, 1e-12f, 1e-12f}};
    for (size_t k = 0; k < 6; ++k) for (int c = 0; c < 3; ++c) rgb[3 * k + c] = odd[k][c];
    auto in = gpu->upload(rgb.data(), rgb.size() * sizeof(float), error);
    if (!in) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }
    const uint32_t count[1] = {N};
    double worst = 0;
    size_t cases = 0;
    // Scene latitude: norm x roll-off, with and without a split.
    for (int norm = 0; norm < 3; ++norm)
        for (float m : {1.0f, 2.0f, 3.5f})
            for (int split = 0; split < 2; ++split) {
                std::vector<float> p(19, 0.0f);
                p[0] = 1.5f; p[1] = 2.0f; p[2] = -2.5f; p[3] = 1.5f; p[4] = m; p[5] = 3.0f; p[6] = float(norm);
                p[7] = 0.2126f; p[8] = 0.7152f; p[9] = 0.0722f; p[10] = 0.184f;
                p[11] = float(W); p[12] = float(H);
                if (split) { p[13] = 0.45f; p[14] = 0.5f; p[15] = 3.0f; p[16] = -1.0f; p[17] = 2.5f; p[18] = 0; }
                auto pb = gpu->upload(p.data(), p.size() * sizeof(float), error);
                auto out = gpu->alloc(rgb.size() * sizeof(float), error);
                if (!pb || !out || !gpu->dispatch("spk_scene_latitude", {Arg::buf(in), Arg::buf(pb), Arg::inline_bytes(count, 1), Arg::buf(out)}, N, error)) {
                    std::fprintf(stderr, "scene_latitude: %s\n", error.c_str()); return 1;
                }
                std::vector<std::vector<double>> ref(N, std::vector<double>(3));
                for (uint32_t i = 0; i < N; ++i) latitude_ref(p, i, &rgb[3 * i], ref[i].data());
                if (!compare(gpu.get(), out, ref, "scene_latitude", worst, error)) { std::fprintf(stderr, "%s (norm %d m %.1f split %d)\n", error.c_str(), norm, m, split); return 1; }
                ++cases;
            }
    // Decode curve: an S-curve per row, with Film Exposure.
    {
        const uint32_t n = 33;
        std::vector<float> p = {float(n), 6.0f, 0.184f, 0.2126f, 0.7152f, 0.0722f, 0.7f};
        std::vector<float> t(5 * n);
        for (uint32_t r = 0; r < 5; ++r)
            for (uint32_t k = 0; k < n; ++k) {
                const double u = double(k) / (n - 1);
                t[r * n + k] = float(u + (0.05 + 0.01 * r) * std::sin(6.2831853 * u));
            }
        auto pb = gpu->upload(p.data(), p.size() * sizeof(float), error);
        auto tb = gpu->upload(t.data(), t.size() * sizeof(float), error);
        auto out = gpu->alloc(rgb.size() * sizeof(float), error);
        if (!pb || !tb || !out || !gpu->dispatch("spk_scene_curve", {Arg::buf(in), Arg::buf(pb), Arg::buf(tb), Arg::inline_bytes(count, 1), Arg::buf(out)}, N, error)) {
            std::fprintf(stderr, "scene_curve: %s\n", error.c_str()); return 1;
        }
        std::vector<std::vector<double>> ref(N, std::vector<double>(3));
        for (uint32_t i = 0; i < N; ++i) curve_ref(p, t, &rgb[3 * i], ref[i].data());
        if (!compare(gpu.get(), out, ref, "scene_curve", worst, error)) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }
        ++cases;
    }
    std::printf("scene: %zu configurations x %u pixels vs double (latitude: 3 norms x 3 roll-offs x split; decode curve), max error/max(1,|ref|) %.3g\n",
                cases, N, worst);
    return 0;
}
