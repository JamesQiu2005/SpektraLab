// spk_negative_hue on Vulkan against negative_hue.metal transcribed into double.
//
// The tables are synthetic but at the engine's own sizes (kNegativeHue*: 1024 layer samples, a
// 120 x 48 gamut, a 160 x 160 map), so every index the kernel forms is the one a real render forms.
// The pixels cover each branch: greys and anything whose weight falls to zero must come back as the
// optical print to the bit; no exposure; a pixel outside a film-edge gate; the gamut knee; hues
// round the wrap; random colours. Bound: 2e-5 of max(1, |reference|) per channel (float pow, cbrt,
// atan and exp10 against double), and exact equality where the kernel copies its input.
#include "core/negative_hue.hpp"
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
using V3 = std::array<double, 3>;

constexpr uint32_t N = spk::kNegativeHueLayerSamples, NH = spk::kNegativeHueGamutHues,
                   NL = spk::kNegativeHueGamutLevels, S = spk::kNegativeHueMapSide;

struct Tables {
    std::vector<float> layers, gamut, map;
    std::array<float, 60> p{};
};

double cbrt0(double v) { return std::cbrt(std::max(v, 0.0)); }
V3 oklab_from_xyz(V3 x) {
    double l = 0.8189330101 * x[0] + 0.3618667424 * x[1] - 0.1288597137 * x[2];
    double m = 0.0329845436 * x[0] + 0.9293118715 * x[1] + 0.0361456387 * x[2];
    double s = 0.0482003018 * x[0] + 0.2643662691 * x[1] + 0.6338517070 * x[2];
    l = cbrt0(l); m = cbrt0(m); s = cbrt0(s);
    return {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s};
}
V3 xyz_from_oklab(V3 lab) {
    double l = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2];
    double m = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2];
    double s = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2];
    l = l * l * l; m = m * m * m; s = s * s * s;
    return {1.2270138511 * l - 0.5577999807 * m + 0.2812561490 * s,
            -0.0405801784 * l + 1.1122568696 * m - 0.0716766787 * s,
            -0.0763812845 * l - 0.4214819784 * m + 1.5861632204 * s};
}
V3 mul3(const float* m, V3 v) {
    return {m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
            m[6] * v[0] + m[7] * v[1] + m[8] * v[2]};
}
std::array<double, 2> read_layer(const Tables& T, uint32_t c, double lo, double scale, double v) {
    double f = std::clamp((v - lo) * scale, 0.0, double(N - 1));
    uint32_t j = std::min(uint32_t(f), N - 2);
    double t = f - j;
    uint32_t a = (j * 3 + c) * 2, b = a + 6;
    return {T.layers[a] + t * (T.layers[b] - T.layers[a]), T.layers[a + 1] + t * (T.layers[b + 1] - T.layers[a + 1])};
}

// negative_hue.metal `spk_negative_hue_pixel`, in double. `copied` says the kernel returns its input.
V3 reference(const Tables& T, uint32_t i, V3 neg, V3 opt, bool& copied) {
    const float* p = T.p.data();
    copied = true;
    if (p[40] != 0.0f) {
        uint32_t cw = uint32_t(p[41]);
        double u = (double(i % cw) + 0.5) * p[43] - p[50];
        double v = (double(i / cw) + p[42] + 0.5) * p[43] - p[51];
        double s = p[44] * u + p[45] * v + p[48], t = p[46] * u + p[47] * v + p[49];
        bool inside = t >= p[53] && t <= p[53] + p[55] &&
                      ((s >= p[52] && s <= p[52] + p[54]) ||
                       (p[56] > 0 && s >= p[52] + p[56] && s <= p[52] + p[56] + p[54]));
        if (!inside) return opt;
    }
    auto r0 = read_layer(T, 0, p[4], p[36], neg[0]), r1 = read_layer(T, 1, p[5], p[37], neg[1]),
         r2 = read_layer(T, 2, p[6], p[38], neg[2]);
    V3 e{std::pow(10.0, r0[0] + p[27]) * p[0], std::pow(10.0, r1[0] + p[28]) * p[1], std::pow(10.0, r2[0] + p[29]) * p[2]};
    double esum = e[0] + e[1] + e[2];
    V3 lab_o = oklab_from_xyz(mul3(p + 9, opt));
    if (!(esum > 0)) return opt;
    double fx = std::clamp(e[0] / esum, 0.0, 1.0) * (S - 1), fy = std::clamp(e[1] / esum, 0.0, 1.0) * (S - 1);
    uint32_t mx = std::min(uint32_t(fx), S - 2), my = std::min(uint32_t(fy), S - 2);
    double tx = fx - mx, ty = fy - my;
    uint32_t m00 = (mx * S + my) * 2, m10 = ((mx + 1) * S + my) * 2;
    double qa[2], qb[2], lab_r[2];
    for (int k = 0; k < 2; ++k) {
        qa[k] = T.map[m00 + k] + (T.map[m00 + 2 + k] - T.map[m00 + k]) * ty;
        qb[k] = T.map[m10 + k] + (T.map[m10 + 2 + k] - T.map[m10 + k]) * ty;
        lab_r[k] = qa[k] + (qb[k] - qa[k]) * tx;
    }
    double c_o = std::hypot(lab_o[1], lab_o[2]), c_r = std::hypot(lab_r[0], lab_r[1]);
    if (!(c_o > 1e-7) || !(c_r > 1e-9)) return opt;
    double c_at = c_r * lab_o[0] * p[3];
    double t = std::clamp((c_at - p[30]) * p[31], 0.0, 1.0);
    double ubar = (e[0] * r0[1] + e[1] * r1[1] + e[2] * r2[1]) / esum;
    double ku = p[32] * ubar;
    double w = (t * t * (3 - 2 * t) / (1 + ku * ku) - p[7]) / (1 - p[7]);
    if (!(w > 0)) return opt;
    double od[2] = {lab_o[1] / c_o, lab_o[2] / c_o};
    double vd[2] = {od[0] + w * (lab_r[0] / c_r - od[0]), od[1] + w * (lab_r[1] / c_r - od[1])};
    double vlen = std::hypot(vd[0], vd[1]);
    if (!(vlen > 1e-6)) return opt;
    copied = false;
    double a = c_o * vd[0] / vlen, b = c_o * vd[1] / vlen;
    double fl = std::clamp((lab_o[0] - p[34]) * p[35], 0.0, double(NL - 1));
    uint32_t l0 = std::min(uint32_t(fl), NL - 2);
    double tl = fl - l0;
    double fh = std::atan2(b, a) * (double(NH) / 6.283185307179586);
    fh -= std::floor(fh / NH) * NH;
    uint32_t h0 = uint32_t(fh) % NH, h1 = (h0 + 1) % NH;
    double th = fh - std::floor(fh);
    double ga = T.gamut[l0 * NH + h0] + (T.gamut[l0 * NH + h1] - T.gamut[l0 * NH + h0]) * th;
    double gb = T.gamut[(l0 + 1) * NH + h0] + (T.gamut[(l0 + 1) * NH + h1] - T.gamut[(l0 + 1) * NH + h0]) * th;
    double cmax = std::max(ga + (gb - ga) * tl, 1e-4);
    double un = c_o / cmax, knee = p[33];
    if (un > knee) {
        double x = (un - knee) / (1 - knee);
        double kn = knee + (1 - knee) * x / std::sqrt(1 + x * x);
        double scale = 1 - w * (1 - kn / un);
        a *= scale; b *= scale;
    }
    V3 o = mul3(p + 18, xyz_from_oklab({lab_o[0], a, b}));
    for (double& c : o) c = std::max(c, 1e-10);
    return o;
}

Tables make_tables(bool film_edge) {
    Tables T;
    // layers: density -> (log10 exposure, unreliability), monotonic exposure, unreliability rising at the ends
    T.layers.resize(size_t(N) * 3 * 2);
    for (uint32_t j = 0; j < N; ++j)
        for (uint32_t c = 0; c < 3; ++c) {
            double f = double(j) / (N - 1);
            T.layers[(j * 3 + c) * 2] = float(-3.0 + 4.0 * f + 0.1 * c + 0.05 * std::sin(9 * f));
            T.layers[(j * 3 + c) * 2 + 1] = float(std::pow(std::abs(2 * f - 1), 4.0) * (1.5 + 0.2 * c));
        }
    // gamut: chroma limit by (lightness, hue), smooth with hue wrapping
    T.gamut.resize(size_t(NL) * NH);
    for (uint32_t l = 0; l < NL; ++l)
        for (uint32_t h = 0; h < NH; ++h)
            T.gamut[l * NH + h] = float(0.06 + 0.12 * std::sin(3.14159 * (l + 0.5) / NL) *
                                        (0.75 + 0.25 * std::cos(6.2832 * h / NH)));
    // map: (red share, green share) -> Oklab (a, b), a smooth colour wheel with a neutral at 1/3, 1/3
    T.map.resize(size_t(S) * S * 2);
    for (uint32_t x = 0; x < S; ++x)
        for (uint32_t y = 0; y < S; ++y) {
            double rx = double(x) / (S - 1) - 1.0 / 3, gy = double(y) / (S - 1) - 1.0 / 3;
            T.map[(x * S + y) * 2] = float(0.45 * rx - 0.2 * gy);
            T.map[(x * S + y) * 2 + 1] = float(0.25 * rx + 0.5 * gy);
        }
    float* p = T.p.data();
    for (int c = 0; c < 3; ++c) {
        p[c] = float(1.0 / (0.18 + 0.01 * c));     // 1 / a grey's layer exposures
        p[4 + c] = float(0.1 + 0.02 * c);           // least density
        p[36 + c] = float((N - 1) / 3.0);           // index scale: density 0.1..3.1 over the table
        p[27 + c] = float(-0.05 + 0.04 * c);        // the enlarger's filters
    }
    p[3] = float(1.0 / spk::kNegativeHueLightness);
    p[7] = float(spk::kNegativeHueWeightFloor);
    const float scan_to_d65[9] = {0.98f, 0.02f, 0.0f, 0.01f, 0.99f, 0.0f, 0.0f, 0.01f, 1.08f};
    for (int k = 0; k < 9; ++k) { p[9 + k] = scan_to_d65[k]; p[18 + k] = (k % 4 == 0) ? 1.0f / scan_to_d65[k] : -scan_to_d65[k]; }
    p[30] = float(spk::kNegativeHueChromaLo);
    p[31] = float(1.0 / (spk::kNegativeHueChromaHi - spk::kNegativeHueChromaLo));
    p[32] = float(spk::kNegativeHueUnreliability);
    p[33] = float(spk::kNegativeHueGamutKnee);
    p[34] = 0.05f;
    p[35] = float((NL - 1) / 0.95);
    if (film_edge) {
        // a 64-wide canvas, 0.1 mm a pixel, identity mapping, a 4 x 2.4 mm gate at (1, 0.8), no pair
        p[40] = 1; p[41] = 64; p[42] = 0; p[43] = 0.1f;
        p[44] = 1; p[45] = 0; p[46] = 0; p[47] = 1; p[48] = 0; p[49] = 0; p[50] = 0; p[51] = 0;
        p[52] = 1.0f; p[53] = 0.8f; p[54] = 4.0f; p[55] = 2.4f; p[56] = 0;
    }
    return T;
}

bool run(Gpu* gpu, bool film_edge, size_t& cases, size_t& copies, size_t& turned, double& worst, std::string& error) {
    const Tables T = make_tables(film_edge);
    std::mt19937 rng(film_edge ? 17u : 5u);
    std::uniform_real_distribution<double> d(0.0, 3.2), x(0.0, 0.95);
    const uint32_t n = film_edge ? 64 * 48 : 70001;   // > 65535 / 256 groups: crosses the dispatch fold path
    std::vector<float> neg(size_t(n) * 3), opt(size_t(n) * 3);
    for (uint32_t i = 0; i < n; ++i) {
        const uint32_t kind = i % 7;
        double base = x(rng);
        for (int c = 0; c < 3; ++c) {
            neg[3 * i + c] = float(kind == 0 ? 1.2 : d(rng));                         // 0: a neutral negative
            opt[3 * i + c] = float(kind == 1 ? base : kind == 2 ? 1e-12 : x(rng));     // 1: a grey print, 2: black
        }
        if (kind == 3) { opt[3 * i] = 0.9f; opt[3 * i + 1] = 0.05f; opt[3 * i + 2] = 0.05f; }  // saturated: the knee
        if (kind == 4) for (int c = 0; c < 3; ++c) neg[3 * i + c] = -5.0f;               // below every layer
    }
    auto up = [&](const std::vector<float>& v) { return gpu->upload(v.data(), v.size() * sizeof(float), error); };
    auto b_neg = up(neg), b_opt = up(opt), b_layers = up(T.layers), b_gamut = up(T.gamut), b_map = up(T.map);
    auto b_p = gpu->upload(T.p.data(), sizeof(float) * 60, error);
    auto b_out = gpu->alloc(size_t(n) * 3 * sizeof(float), error);
    if (!b_neg || !b_opt || !b_layers || !b_gamut || !b_map || !b_p || !b_out) return false;
    const uint32_t meta[5] = {n, N, NH, NL, S};
    if (!gpu->dispatch("spk_negative_hue",
                       {Arg::buf(b_neg), Arg::buf(b_opt), Arg::buf(b_layers), Arg::buf(b_p), Arg::buf(b_gamut),
                        Arg::buf(b_map), Arg::inline_bytes(meta, 5), Arg::buf(b_out)},
                       n, error) || !gpu->flush(error)) return false;
    std::vector<float> out;
    if (!read_test_buffer(gpu, b_out, out, error)) return false;
    for (uint32_t i = 0; i < n; ++i) {
        bool copied = false;
        const V3 ref = reference(T, i, {neg[3 * i], neg[3 * i + 1], neg[3 * i + 2]},
                                 {opt[3 * i], opt[3 * i + 1], opt[3 * i + 2]}, copied);
        for (int c = 0; c < 3; ++c) {
            const float got = out[3 * i + c];
            if (copied) {
                if (got != opt[3 * i + c]) {
                    char m[256];
                    std::snprintf(m, sizeof m, "pixel %u c%d: the reference copies the optical print (%.9g), got %.9g",
                                  i, c, double(opt[3 * i + c]), double(got));
                    error = m;
                    return false;
                }
                continue;
            }
            const double delta = std::fabs(double(got) - ref[c]);
            const double bound = 2e-5 * std::max(1.0, std::fabs(ref[c]));
            worst = std::max(worst, delta / std::max(1.0, std::fabs(ref[c])));
            if (!std::isfinite(got) || delta > bound) {
                char m[256];
                std::snprintf(m, sizeof m, "pixel %u c%d: got %.9g, reference %.9g (delta %.3g, bound %.3g)%s",
                              i, c, double(got), ref[c], delta, bound, film_edge ? " [film edge]" : "");
                error = m;
                return false;
            }
        }
        ++cases;
        (copied ? copies : turned) += 1;
    }
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_negative_hue <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    size_t cases = 0, copies = 0, turned = 0;
    double worst = 0;
    if (!run(gpu.get(), false, cases, copies, turned, worst, error) || !run(gpu.get(), true, cases, copies, turned, worst, error)) {
        std::fprintf(stderr, "negative_hue: %s\n", error.c_str());
        return 1;
    }
    if (turned < 1000 || copies < 1000) {
        std::fprintf(stderr, "negative_hue: the cases did not reach both branches (turned %zu, copied %zu)\n", turned, copies);
        return 1;
    }
    std::printf("negative_hue: %zu pixels vs double (%zu turned, %zu copied to the bit), max error/max(1,|ref|) %.3g\n",
                cases, turned, copies, worst);
    return 0;
}
