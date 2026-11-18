// spk_mask_reduce and spk_mask_epilogue on Vulkan against contrast_mask.metal in double.
//
// A synthetic negative (densities 0..3) through an 81-wavelength enlarger; the reduce over a grid
// that does not divide the frame evenly; the epilogue with both branches on, a band (row0 > 0), and
// an (a, b) coefficient grid that varies across the frame. Bounds: the cell means 1e-4 absolute
// (a float sum over each cell's pixels), the epilogue's log10 exposures 2e-5 of max(1, |ref|).
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::Gpu;
constexpr uint32_t L = 81;

struct Setup {
    std::vector<float> chd, base, ixs, p;
};

double mmax0(double x) { return (std::isnan(x) || x < 0) ? 0.0 : x; }

std::array<double, 3> exposure(const Setup& s, const float* c) {
    double a[3] = {0, 0, 0};
    for (uint32_t l = 0; l < L; ++l) {
        const double d = c[0] * double(s.chd[3 * l]) + c[1] * double(s.chd[3 * l + 1]) + c[2] * double(s.chd[3 * l + 2]) + s.base[l];
        const double t = std::pow(10.0, -d);
        for (int k = 0; k < 3; ++k) a[k] += t * s.ixs[3 * l + k];
    }
    return {a[0] * s.p[0], a[1] * s.p[1], a[2] * s.p[2]};
}
double mask_x(const Setup& s, const std::array<double, 3>& a) {
    double sum = 0;
    for (int c = 0; c < 3; ++c) {
        const double r = mmax0(a[c] * s.p[3 + c]);
        sum += std::max(r > 0 ? std::log2(r) : -INFINITY, -20.0);
    }
    return sum / 3;
}
double mask_g(double d, double h) { return d * h / std::sqrt(h * h + d * d); }
double mask_delta(const Setup& s, double b) {
    const auto& p = s.p;
    double delta = 0;
    if (p[11] != 0 && b < p[9]) { const double d = p[9] - b; delta = d - mask_g(d, p[10]); }
    else if (p[14] != 0 && b > p[12]) { const double d = b - p[12]; delta = mask_g(d, p[13]) - d; }
    const double lim = p[15];
    return delta * lim / std::sqrt(lim * lim + delta * delta);
}

Setup make_setup() {
    Setup s;
    s.chd.resize(L * 3); s.base.resize(L); s.ixs.resize(L * 3);
    for (uint32_t l = 0; l < L; ++l) {
        const double w = double(l) / (L - 1);
        for (int c = 0; c < 3; ++c) {
            s.chd[3 * l + c] = float(std::exp(-std::pow((w - (0.25 + 0.25 * c)) / 0.11, 2)));
            s.ixs[3 * l + c] = float(0.03 * std::exp(-std::pow((w - (0.75 - 0.25 * c)) / 0.09, 2)));
        }
        s.base[l] = float(0.4 + 0.1 * w);
    }
    s.p = {1.2f, 1.1f, 0.95f,        // setup gain
           25.0f, 22.0f, 30.0f,      // 1 / A_ref
           0.0004f, 0.0003f, 0.0002f,  // pre-flash
           -0.8f, 1.2f, 1.0f,        // k_lo h_lo lo_on
           0.9f, 1.0f, 1.0f,         // k_hi h_hi hi_on
           1.5f};                    // gain limit
    return s;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_mask <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    const Setup s = make_setup();
    const uint32_t W = 211, H = 157, N = W * H, gw = 23, gh = 17;
    std::mt19937 rng(41);
    std::uniform_real_distribution<float> den(0.0f, 3.0f);
    std::vector<float> cmy(size_t(N) * 3);
    for (auto& v : cmy) v = den(rng);
    auto up = [&](const std::vector<float>& v) { return gpu->upload(v.data(), v.size() * sizeof(float), error); };
    auto b_cmy = up(cmy), b_chd = up(s.chd), b_base = up(s.base), b_ixs = up(s.ixs), b_p = up(s.p);
    if (!b_cmy || !b_chd || !b_base || !b_ixs || !b_p) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }

    // --- reduce
    auto b_grid = gpu->alloc(size_t(gw) * gh * sizeof(float), error);
    const uint32_t meta_r[5] = {W, H, gw, gh, L};
    if (!b_grid || !gpu->dispatch("spk_mask_reduce", {Arg::buf(b_cmy), Arg::buf(b_chd), Arg::buf(b_base), Arg::buf(b_ixs), Arg::buf(b_p),
                                                       Arg::inline_bytes(meta_r, 5), Arg::buf(b_grid)}, size_t(gw) * gh, error) ||
        !gpu->flush(error)) { std::fprintf(stderr, "mask_reduce: %s\n", error.c_str()); return 1; }
    std::vector<float> grid;
    if (!read_test_buffer(gpu.get(), b_grid, grid, error)) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }
    double worst_r = 0;
    for (uint32_t cy = 0; cy < gh; ++cy)
        for (uint32_t cx = 0; cx < gw; ++cx) {
            uint32_t x0 = (cx * W) / gw, x1 = std::max(((cx + 1) * W) / gw, x0 + 1);
            uint32_t y0 = (cy * H) / gh, y1 = std::max(((cy + 1) * H) / gh, y0 + 1);
            x1 = std::min(x1, W); y1 = std::min(y1, H);
            double acc = 0;
            for (uint32_t y = y0; y < y1; ++y)
                for (uint32_t x = x0; x < x1; ++x) acc += mask_x(s, exposure(s, &cmy[3 * (y * W + x)]));
            const double ref = acc / double((x1 - x0) * (y1 - y0));
            const double d = std::fabs(grid[cy * gw + cx] - ref);
            worst_r = std::max(worst_r, d);
            if (!(d <= 1e-4)) { std::fprintf(stderr, "mask_reduce: cell %u,%u got %.9g reference %.9g\n", cx, cy, double(grid[cy * gw + cx]), ref); return 1; }
        }

    // --- epilogue on a band of the frame
    const uint32_t row0 = 40, rows = 90, n = W * rows;
    std::vector<float> coef(size_t(gw) * gh * 2);
    for (uint32_t c = 0; c < gw * gh; ++c) {
        coef[2 * c] = float(0.3 + 0.4 * ((c * 7) % 11) / 10.0);          // a: edge-aware weight
        coef[2 * c + 1] = float(-1.5 + 3.0 * ((c * 13) % 17) / 16.0);   // b: the base
    }
    std::vector<float> band(cmy.begin() + size_t(row0) * W * 3, cmy.begin() + size_t(row0 + rows) * W * 3);
    auto b_band = up(band), b_coef = up(coef);
    auto b_out = gpu->alloc(size_t(n) * 3 * sizeof(float), error);
    const uint32_t meta_e[7] = {n, L, W, H, row0, gw, gh};
    if (!b_band || !b_coef || !b_out ||
        !gpu->dispatch("spk_mask_epilogue", {Arg::buf(b_band), Arg::buf(b_chd), Arg::buf(b_base), Arg::buf(b_ixs), Arg::buf(b_p),
                                              Arg::buf(b_coef), Arg::inline_bytes(meta_e, 7), Arg::buf(b_out)}, n, error) ||
        !gpu->flush(error)) { std::fprintf(stderr, "mask_epilogue: %s\n", error.c_str()); return 1; }
    std::vector<float> out;
    if (!read_test_buffer(gpu.get(), b_out, out, error)) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }
    double worst_e = 0;
    size_t moved = 0;
    for (uint32_t i = 0; i < n; ++i) {
        const auto a = exposure(s, &band[3 * i]);
        const uint32_t px = i % W, py = row0 + i / W;
        const double u = std::clamp((px + 0.5) * gw / W - 0.5, 0.0, double(gw - 1));
        const double v = std::clamp((py + 0.5) * gh / H - 0.5, 0.0, double(gh - 1));
        const uint32_t u0 = uint32_t(std::floor(u)), v0 = uint32_t(std::floor(v));
        const uint32_t u1 = std::min(u0 + 1, gw - 1), v1 = std::min(v0 + 1, gh - 1);
        const double tu = u - u0, tv = v - v0;
        double ab[2];
        for (int k = 0; k < 2; ++k) {
            const double c00 = coef[2 * (v0 * gw + u0) + k], c01 = coef[2 * (v0 * gw + u1) + k];
            const double c10 = coef[2 * (v1 * gw + u0) + k], c11 = coef[2 * (v1 * gw + u1) + k];
            ab[k] = (c00 + (c01 - c00) * tu) + ((c10 + (c11 - c10) * tu) - (c00 + (c01 - c00) * tu)) * tv;
        }
        const double b = ab[0] * mask_x(s, a) + ab[1];
        const double dl = mask_delta(s, b);
        if (dl != 0) ++moved;
        const double k = std::exp2(dl);
        for (int c = 0; c < 3; ++c) {
            const double ref = std::log10(mmax0(k * a[c] + s.p[6 + c]) + 1e-10);
            const double d = std::fabs(out[3 * i + c] - ref) / std::max(1.0, std::fabs(ref));
            worst_e = std::max(worst_e, d);
            if (!(d <= 2e-5)) { std::fprintf(stderr, "mask_epilogue: pixel %u c%d got %.9g reference %.9g\n", i, c, double(out[3 * i + c]), ref); return 1; }
        }
    }
    if (moved < n / 10) { std::fprintf(stderr, "mask_epilogue: the mask moved only %zu of %u pixels\n", moved, n); return 1; }
    std::printf("mask: reduce %ux%u cells over %ux%u (max |error| %.3g); epilogue %u pixels of a band, %zu with a gain (max error %.3g)\n",
                gw, gh, W, H, worst_r, n, moved, worst_e);
    return 0;
}
