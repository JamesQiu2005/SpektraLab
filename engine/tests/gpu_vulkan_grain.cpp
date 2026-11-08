// GPU gates for the Windows grain port: integer RNG vectors, analytic
// distribution moments, interpolation branches, and lognormal correlation.
// This is local kernel validation, not Python/Metal whole-frame parity.
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

namespace {
using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;
constexpr uint32_t kSamples = 524288;
constexpr size_t kGuard = 16;
constexpr float kSentinel = -12345.0f;

std::array<uint32_t, 4> cpu_philox(std::array<uint32_t, 4> c, uint32_t k0, uint32_t k1) {
    // Independent 64-bit multiplication extracts each product's two words;
    // the GPU uses GLSL umulExtended instead.
    for (unsigned r = 0; r < 10; ++r) {
        const uint64_t p0 = uint64_t(0xD2511F53u) * c[0];
        const uint64_t p1 = uint64_t(0xCD9E8D57u) * c[2];
        c = {uint32_t(p1 >> 32) ^ c[1] ^ k0, uint32_t(p1),
             uint32_t(p0 >> 32) ^ c[3] ^ k1, uint32_t(p0)};
        k0 += 0x9E3779B9u; k1 += 0xBB67AE85u;
    }
    return c;
}

struct Moments { double mean, variance, skew; };
Moments moments(const std::vector<float>& values, size_t offset = 0, size_t stride = 1,
                size_t n = 0) {
    if (!n) n = (values.size() - offset) / stride;
    double mean = 0, m2 = 0, m3 = 0;
    for (size_t i = 0; i < n; ++i) mean += values[offset + i * stride];
    mean /= double(n);
    for (size_t i = 0; i < n; ++i) {
        const double d = double(values[offset + i * stride]) - mean;
        m2 += d * d; m3 += d * d * d;
    }
    m2 /= double(n); m3 /= double(n);
    return {mean, m2, m2 > 0 ? m3 / std::pow(m2, 1.5) : 0};
}

bool assert_moments(const char* label, const Moments& got, double mean, double variance,
                    double skew, size_t n, double skew_bar, std::string& error) {
    // Mean bar is six standard errors. The variance bar uses the Poisson
    // fourth moment (scaled Poisson has the same excess kurtosis).
    const double mean_bar = 6 * std::sqrt(variance / double(n)) + 2e-6 * std::abs(mean);
    const double var_bar = 7 * variance * std::sqrt((2 + skew * skew) / double(n)) +
                           2e-6 * variance;
    if (std::abs(got.mean - mean) > mean_bar || std::abs(got.variance - variance) > var_bar ||
        std::abs(got.skew - skew) > skew_bar) {
        char detail[512];
        std::snprintf(detail, sizeof detail,
            "%s mean %.9g/%.9g (bar %.3g), variance %.9g/%.9g (bar %.3g), skew %.9g/%.9g (bar %.3g)",
            label, got.mean, mean, mean_bar, got.variance, variance, var_bar, got.skew, skew, skew_bar);
        error = detail; return false;
    }
    return true;
}

bool dispatch_f32(Gpu* gpu, const char* kernel, std::vector<Arg> args, size_t threads,
                  size_t count, std::vector<float>& values, std::string& error) {
    std::vector<float> initial(count + kGuard, kSentinel);
    auto out = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
    if (!out) return false;
    args.push_back(Arg::buf(out));
    if (!gpu->dispatch(kernel, args, threads, error) || !gpu->flush(error)) return false;
    std::vector<float> p_readback;
    if (!read_test_buffer(gpu, out, p_readback, error)) return false;
    const float* p = p_readback.data();
    values.assign(p, p + count);
    for (size_t i = 0; i < count; ++i) if (!std::isfinite(p[i]) || p[i] == kSentinel) {
        error = std::string(kernel) + " produced a nonfinite or untouched value at " + std::to_string(i);
        return false;
    }
    for (size_t i = count; i < initial.size(); ++i) if (p[i] != kSentinel) {
        error = std::string(kernel) + " wrote beyond the requested count"; return false;
    }
    return true;
}

bool probe(Gpu* gpu, uint32_t mode, const float* p, size_t np, uint32_t seed, uint32_t stream,
           uint32_t count, std::vector<float>& values, std::string& error) {
    const uint32_t dummy = 0, meta[4] = {count, seed, stream, mode};
    auto ctr = gpu->upload_u32(&dummy, 1, error);
    auto params = gpu->upload(p, np * sizeof(float), error);
    if (!ctr || !params) return false;
    return dispatch_f32(gpu, "spk_rng_probe", {Arg::buf(ctr), Arg::buf(params), Arg::inline_bytes(meta, 4)},
                        count, count, values, error);
}

bool check_rng(Gpu* gpu, std::string& error) {
    constexpr uint32_t count = 259; // partial workgroup and arbitrary counters
    std::vector<uint32_t> input(count * 6), initial(count * 4 + kGuard, 0xdeadbeefu);
    for (uint32_t i = 0; i < count; ++i)
        for (uint32_t j = 0; j < 6; ++j)
            input[i * 6 + j] = i == 0 ? 0 : i == 1 ? 0xffffffffu :
                              (0x9e3779b9u * i) ^ (0x85ebca6bu * (j + 1u));
    const uint32_t meta[4] = {count, 0, 0, 0};
    const float dummy = 0;
    auto ctr = gpu->upload_u32(input.data(), input.size(), error);
    auto params = gpu->upload(&dummy, sizeof dummy, error);
    auto out = gpu->upload_u32(initial.data(), initial.size(), error);
    if (!ctr || !params || !out ||
        !gpu->dispatch("spk_rng_probe", {Arg::buf(ctr), Arg::buf(params), Arg::inline_bytes(meta, 4),
                                        Arg::buf(out)}, count, error) || !gpu->flush(error)) return false;
    std::vector<uint32_t> got_readback;
    if (!read_test_buffer(gpu, out, got_readback, error)) return false;
    const uint32_t* got = got_readback.data();
    constexpr uint32_t zero_vector[4] = {0x6627e8d5u, 0xe169c58du, 0xbc57ac4cu, 0x9b00dbd8u};
    for (uint32_t i = 0; i < count; ++i) {
        const auto expected = cpu_philox({input[i * 6], input[i * 6 + 1], input[i * 6 + 2],
                                         input[i * 6 + 3]}, input[i * 6 + 4], input[i * 6 + 5]);
        for (unsigned j = 0; j < 4; ++j) if (got[i * 4 + j] != expected[j] ||
                                               (i == 0 && got[j] != zero_vector[j])) {
            error = "Philox integer vector mismatch at " + std::to_string(i * 4 + j); return false;
        }
    }
    for (size_t i = count * 4; i < initial.size(); ++i) if (got[i] != 0xdeadbeefu) {
        error = "Philox probe overrun"; return false;
    }
    std::vector<float> u, repeated, changed;
    if (!probe(gpu, 1, &dummy, 1, 1234, 7, kSamples, u, error) ||
        !probe(gpu, 1, &dummy, 1, 1234, 7, kSamples, repeated, error) ||
        !probe(gpu, 1, &dummy, 1, 1235, 7, kSamples, changed, error)) return false;
    if (u != repeated || u == changed) { error = "RNG seed repeat/change contract failed"; return false; }
    std::array<size_t, 32> bins{};
    size_t equal_seed_pixels = 0;
    for (size_t i = 0; i < u.size(); ++i) {
        // The highest 24-bit midpoint rounds to 1.0 in float32, exactly as
        // in Metal's u01. Preserve that mapping instead of changing its RNG.
        if (!(u[i] > 0 && u[i] <= 1)) { error = "uniform draw outside (0,1]"; return false; }
        ++bins[std::min(bins.size() - 1, size_t(u[i] * bins.size()))];
        equal_seed_pixels += u[i] == changed[i];
        const auto words = cpu_philox({uint32_t(i), 7, 0, 0}, 1234, 0);
        const float expected = (float(words[0] >> 8) + 0.5f) / 16777216.0f;
        if (u[i] != expected) { error = "RNG first-draw mapping mismatch"; return false; }
    }
    double chi2 = 0;
    const double expected_bin = double(kSamples) / bins.size();
    for (auto b : bins) chi2 += (double(b) - expected_bin) * (double(b) - expected_bin) / expected_bin;
    const auto m = moments(u);
    if (chi2 > 75 || equal_seed_pixels > 32 || std::abs(m.mean - 0.5) > 0.002 ||
        std::abs(m.variance - 1.0 / 12) > 0.0008) {
        error = "uniform distribution or seed independence failed"; return false;
    }
    std::printf("Philox: %u exact integer vectors; uniform N=%u mean=%.6f variance=%.6f chi2=%.3f\n",
                count, kSamples, m.mean, m.variance, chi2);
    const float rates[] = {0, 0.1f, 1, 9.9f, 10, 36, 1000};
    for (float rate : rates) {
        std::vector<float> draws;
        if (!probe(gpu, 2, &rate, 1, 0x12345678u, 19, kSamples, draws, error)) return false;
        for (float x : draws) if (x < 0 || x != std::floor(x)) {
            error = "Poisson draw is negative or nonintegral"; return false;
        }
        const auto p = moments(draws);
        if (!rate) {
            if (p.mean != 0 || p.variance != 0) { error = "Poisson zero-rate draw changed"; return false; }
        } else {
            // Sampling error of skew grows at the sparse-rate end.
            const double skew_bar = rate < 1 ? 0.065 : rate < 2 ? 0.025 : 0.016;
            if (!assert_moments("Poisson", p, rate, rate, 1 / std::sqrt(rate), kSamples, skew_bar, error)) return false;
        }
        std::printf("Poisson mu=%.4g N=%u: mean=%.6f variance=%.6f skew=%.6f\n", rate, kSamples,
                    p.mean, p.variance, p.skew);
    }
    return true;
}

bool check_layer_moments(Gpu* gpu, std::string& error) {
    // Uniformity changes variance and skew, while expected density stays d.
    for (float d : {0.01f, 0.3f, 0.8f}) for (float uniformity : {0.0f, 0.7f, 1.0f}) {
        const float p[4] = {d, 1, 36, uniformity};
        std::vector<float> draws;
        if (!probe(gpu, 3, p, 4, 2468, 27, kSamples, draws, error)) return false;
        // Compute the contract in float64; float32 parameter differences are
        // below the sampling uncertainty and accounted for by the bars.
        const double sat = 1 - double(d) * uniformity * (1 - 1e-6);
        const double rate = 36 * double(d) / sat;
        const auto m = moments(draws);
        if (!assert_moments("layer_draw", m, d, d * sat / 36, 1 / std::sqrt(rate),
                            kSamples, d < 0.02 ? 0.035 : 0.016, error)) return false;
        std::printf("layer_draw d=%.2g u=%.2g: mean=%.6f variance=%.8f skew=%.6f\n",
                    d, uniformity, m.mean, m.variance, m.skew);
    }
    return true;
}

float interpolate(const std::vector<float>& xa, const std::vector<float>& y, uint32_t ch,
                  uint32_t sl, float query) {
    constexpr uint32_t K = 4;
    const uint32_t col = ch * 3 + sl;
    if (query <= xa[ch]) return y[col];
    if (query >= xa[(K - 1) * 3 + ch]) return y[(K - 1) * 9 + col];
    // Independent upper-bound selection, with an explicit linear scan.
    uint32_t upper = 1;
    while (upper < K && xa[upper * 3 + ch] <= query) ++upper;
    const uint32_t low = upper - 1;
    const float t = (query - xa[low * 3 + ch]) *
                    (1.0f / (xa[upper * 3 + ch] - xa[low * 3 + ch]));
    const float y0 = y[low * 9 + col], y1 = y[upper * 9 + col];
    return y0 + t * (y1 - y0);
}

bool check_grain(Gpu* gpu, std::string& error) {
    constexpr uint32_t K = 4, count = 1031;
    const float axis[4] = {0, 0.4f, 1, 2};
    std::vector<float> xa(K * 3), inv((K - 1) * 3), y(K * 9), lp(36), cmy(count * 3);
    uint32_t streams[9];
    for (uint32_t ch = 0; ch < 3; ++ch) {
        for (uint32_t k = 0; k < K; ++k) xa[k * 3 + ch] = axis[k] + 0.125f * ch;
        for (uint32_t k = 0; k + 1 < K; ++k) inv[k * 3 + ch] = 1 / (xa[(k+1) * 3 + ch] - xa[k * 3 + ch]);
        for (uint32_t sl = 0; sl < 3; ++sl) {
            const uint32_t col = ch * 3 + sl;
            streams[col] = 17 + col * 13;
            lp[col * 4] = 0.015f * (sl + 1);
            lp[col * 4 + 1] = 1 + 0.25f * ch;
            lp[col * 4 + 2] = 12 + 24 * sl;
            lp[col * 4 + 3] = sl == 0 ? 0 : sl == 1 ? 0.7f : 1;
            for (uint32_t k = 0; k < K; ++k) y[k * 9 + col] = 0.02f + 0.07f * col + 0.08f * k;
        }
    }
    const float queries[] = {-2, 0, 0.2f, 0.4f, 0.6f, 1, 1.5f, 2, 5};
    for (uint32_t i = 0; i < count; ++i) for (uint32_t ch = 0; ch < 3; ++ch)
        cmy[i * 3 + ch] = queries[i % 9] + 0.125f * ch;
    auto input = gpu->upload(cmy.data(), cmy.size() * sizeof(float), error);
    auto axis_buffer = gpu->upload(xa.data(), xa.size() * sizeof(float), error);
    auto inv_buffer = gpu->upload(inv.data(), inv.size() * sizeof(float), error);
    auto layers = gpu->upload(y.data(), y.size() * sizeof(float), error);
    auto layer_params = gpu->upload(lp.data(), lp.size() * sizeof(float), error);
    auto stream_buffer = gpu->upload_u32(streams, 9, error);
    if (!input || !axis_buffer || !inv_buffer || !layers || !layer_params || !stream_buffer) return false;
    uint32_t meta[5] = {K, count, 0, 13579, 0};
    auto args = [&](BufferRef& source) { return std::vector<Arg>{Arg::buf(source), Arg::buf(axis_buffer),
        Arg::buf(inv_buffer), Arg::buf(layers), Arg::buf(layer_params), Arg::buf(stream_buffer),
        Arg::inline_bytes(meta, 5)}; };
    std::vector<float> fused, repeat, accumulated(cmy.size(), 0);
    if (!dispatch_f32(gpu, "spk_grain_layers", args(input), count, cmy.size(), fused, error) ||
        !dispatch_f32(gpu, "spk_grain_layers", args(input), count, cmy.size(), repeat, error)) return false;
    if (fused != repeat) { error = "fused grain is not reproducible"; return false; }
    for (uint32_t sl = 0; sl < 3; ++sl) {
        meta[4] = sl;
        std::vector<float> one, simple_input(cmy.size()), slp(12);
        uint32_t sstreams[3];
        for (uint32_t ch = 0; ch < 3; ++ch) {
            std::copy_n(lp.data() + (ch * 3 + sl) * 4, 4, slp.data() + ch * 4);
            sstreams[ch] = streams[ch * 3 + sl];
            for (uint32_t i = 0; i < count; ++i)
                simple_input[i * 3 + ch] = interpolate(xa, y, ch, sl, cmy[i * 3 + ch]);
        }
        if (!dispatch_f32(gpu, "spk_grain_layer_one", args(input), count, cmy.size(), one, error)) return false;
        auto si = gpu->upload(simple_input.data(), simple_input.size() * sizeof(float), error);
        auto sp = gpu->upload(slp.data(), slp.size() * sizeof(float), error);
        auto ss = gpu->upload_u32(sstreams, 3, error);
        const uint32_t smeta[3] = {count, 1, meta[3]};
        std::vector<float> simple;
        if (!si || !sp || !ss || !dispatch_f32(gpu, "spk_grain_simple",
                {Arg::buf(si), Arg::buf(sp), Arg::buf(ss), Arg::inline_bytes(smeta, 3)},
                count, cmy.size(), simple, error)) return false;
        if (one != simple) { error = "layer-one interpolation differs from independently interpolated simple grain"; return false; }
        for (size_t i = 0; i < one.size(); ++i) accumulated[i] += one[i];
    }
    if (fused != accumulated) { error = "fused grain differs from the sum of three single layers"; return false; }
    for (float& v : cmy) v = -v;
    auto negative_input = gpu->upload(cmy.data(), cmy.size() * sizeof(float), error);
    meta[2] = 1;
    std::vector<float> positive;
    if (!negative_input || !dispatch_f32(gpu, "spk_grain_layers", args(negative_input), count, cmy.size(), positive, error)) return false;
    if (positive != fused) { error = "positive-film axis/query sign convention differs"; return false; }
    ++meta[3];
    if (!dispatch_f32(gpu, "spk_grain_layers", args(negative_input), count, cmy.size(), positive, error)) return false;
    if (positive == fused) { error = "fused grain ignored a changed seed"; return false; }
    // Multiple simple sublayers must use streams[ch]+sl*10. Pin this by
    // summing independent nsub=1 dispatches rather than a duplicate sampler.
    const uint32_t nsub = 4;
    std::vector<float> slp(lp.begin(), lp.begin() + 12);
    auto sp = gpu->upload(slp.data(), slp.size() * sizeof(float), error);
    uint32_t base_streams[3] = {7, 31, 89};
    auto ss = gpu->upload_u32(base_streams, 3, error);
    uint32_t smeta[3] = {count, nsub, 98765};
    std::vector<float> multi, sum(cmy.size(), 0);
    if (!sp || !ss || !dispatch_f32(gpu, "spk_grain_simple", {Arg::buf(input), Arg::buf(sp),
        Arg::buf(ss), Arg::inline_bytes(smeta, 3)}, count, cmy.size(), multi, error)) return false;
    smeta[1] = 1;
    for (uint32_t sl = 0; sl < nsub; ++sl) {
        uint32_t substreams[3] = {base_streams[0] + sl * 10, base_streams[1] + sl * 10, base_streams[2] + sl * 10};
        auto stream = gpu->upload_u32(substreams, 3, error);
        std::vector<float> one;
        if (!stream || !dispatch_f32(gpu, "spk_grain_simple", {Arg::buf(input), Arg::buf(sp),
            Arg::buf(stream), Arg::inline_bytes(smeta, 3)}, count, cmy.size(), one, error)) return false;
        for (size_t i = 0; i < one.size(); ++i) sum[i] += one[i];
    }
    if (multi != sum) { error = "simple sublayer stream ordering differs"; return false; }
    std::printf("grain: %u pixels, 9 endpoint/exact-knot/interior queries, positive sign, fused/layer/simple branches passed\n", count);
    return true;
}

bool check_lognormal(Gpu* gpu, std::string& error) {
    for (const auto& pair : {std::array<float, 2>{1, 0.2f}, std::array<float, 2>{0.04f, 0.06f},
                             std::array<float, 2>{1.5f, 0}}) {
        auto params = gpu->upload(pair.data(), sizeof pair, error);
        if (!params) return false;
        uint32_t meta[4] = {kSamples + 3, 7654321, 100, 1}; // partial final workgroup
        std::vector<float> field, repeat, changed;
        auto run = [&](std::vector<float>& result) { return dispatch_f32(gpu, "spk_lognormal_field",
            {Arg::buf(params), Arg::inline_bytes(meta, 4)}, meta[0], size_t(meta[0]) * 3, result, error); };
        if (!run(field) || !run(repeat)) return false;
        if (field != repeat) { error = "lognormal field fixed seed is not reproducible"; return false; }
        const size_t count = meta[0];
        for (uint32_t ch = 0; ch < 3; ++ch) {
            const auto m = moments(field, ch, 3, count);
            const double mean = pair[0], variance = double(pair[1]) * pair[1];
            const double r = variance / (mean * mean);
            const double excess = std::pow(1 + r, 4) + 2 * std::pow(1 + r, 3) + 3 * (1 + r) * (1 + r) - 6;
            const double mean_bar = 7 * std::sqrt(variance / count) + 1e-5;
            const double var_bar = 8 * variance * std::sqrt((excess + 2) / count) + 1e-8;
            if (std::abs(m.mean - mean) > mean_bar || std::abs(m.variance - variance) > var_bar) {
                error = "lognormal analytic mean/std failed"; return false;
            }
            for (uint32_t other = 0; other < ch && variance > 0; ++other) {
                const auto mo = moments(field, other, 3, count);
                double covariance = 0;
                for (size_t i = 0; i < count; ++i) covariance +=
                    (field[i * 3 + ch] - m.mean) * (field[i * 3 + other] - mo.mean);
                const double correlation = covariance / count / std::sqrt(m.variance * mo.variance);
                if (std::abs(correlation) > 0.012) { error = "per-channel lognormal streams are correlated"; return false; }
            }
        }
        ++meta[1];
        if (!run(changed)) return false;
        if (pair[1] > 0 && field == changed) { error = "lognormal ignored changed seed"; return false; }
        --meta[1]; meta[3] = 0;
        if (!run(changed)) return false;
        for (size_t i = 0; i < count; ++i)
            if (changed[i * 3] != changed[i * 3 + 1] || changed[i * 3] != changed[i * 3 + 2] ||
                changed[i * 3] != field[i * 3]) {
                error = "shared-channel lognormal does not repeat the first stream"; return false;
            }
        const auto m = moments(field, 0, 3, count);
        std::printf("lognormal m=%.4g s=%.4g N=%zu: mean=%.6f std=%.6f, seed/channel contracts passed\n",
                    pair[0], pair[1], count, m.mean, std::sqrt(m.variance));
    }
    return true;
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_grain <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan grain device: %s\n", gpu->device_name().c_str());
    if (!check_rng(gpu.get(), error) || !check_layer_moments(gpu.get(), error) ||
        !check_grain(gpu.get(), error) || !check_lognormal(gpu.get(), error)) {
        std::fprintf(stderr, "grain gate: %s\n", error.c_str()); return 1;
    }
    std::printf("Windows Vulkan grain local gates passed; whole-frame Python/Metal parity remains unverified.\n");
    return 0;
}
