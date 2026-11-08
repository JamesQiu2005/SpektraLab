// Independent float64/64-bit-integer reference for the mirror bilinear
// resample, including collapsed axes and coordinates beyond 32-bit products.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

namespace {
struct Axis { uint32_t lo, hi; double fraction; };
Axis reference_axis(uint32_t out, uint32_t input_length, uint32_t output_length) {
    const int64_t denominator = int64_t(output_length) * 2;
    int64_t numerator = (int64_t(out) * 2 + 1) * input_length - output_length;
    const int64_t end = denominator * (input_length - 1);
    if (numerator > end) numerator = end * 2 - numerator;
    numerator = std::abs(numerator);
    const uint32_t lo = uint32_t(numerator / denominator);
    return {lo, std::min(lo + 1, input_length - 1), double(numerator % denominator) / denominator};
}

bool run_case(spk::gpu::Gpu* gpu, const std::array<uint32_t, 4>& shape, uint32_t pattern,
              double& max_error, std::string& error) {
    const uint32_t sh = shape[0], sw = shape[1], oh = shape[2], ow = shape[3];
    std::vector<float> input(size_t(sh) * sw * 3);
    for (uint32_t y = 0; y < sh; ++y) for (uint32_t x = 0; x < sw; ++x)
        for (uint32_t c = 0; c < 3; ++c) {
            const size_t i = (size_t(y) * sw + x) * 3 + c;
            if (pattern == 0) input[i] = float(-0.5 + c * 0.75);
            else if (pattern == 1) input[i] = float(-0.4 + 0.3 * c +
                0.7 * double(x) / sw - 0.2 * double(y) / sh);
            else if (pattern == 2) {
                const uint32_t ix = c == 0 ? 0 : c == 1 ? sw / 2 : sw - 1;
                const uint32_t iy = c == 0 ? 0 : c == 1 ? sh / 2 : sh - 1;
                input[i] = x == ix && y == iy ? 1.0f : 0.0f;
            } else input[i] = float(((x + y + c) & 1) ? -0.75 : 1.25);
        }
    const size_t output_count = size_t(oh) * ow * 3;
    constexpr size_t guard = 32;
    constexpr float sentinel = -123456.0f;
    std::vector<float> initial(output_count + guard, sentinel);
    auto src = gpu->upload(input.data(), input.size() * sizeof(float), error);
    auto dst = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
    if (!src || !dst || !gpu->dispatch("spk_zoom_bilinear_mirror",
        {spk::gpu::Arg::buf(src), spk::gpu::Arg::inline_bytes(shape.data(), 4), spk::gpu::Arg::buf(dst)},
        size_t(oh) * ow, error) || !gpu->flush(error)) return false;
    std::vector<float> actual_readback;
    if (!read_test_buffer(gpu, dst, actual_readback, error)) return false;
    const float* actual = actual_readback.data();
    for (uint32_t y = 0; y < oh; ++y) {
        const Axis ay = reference_axis(y, sh, oh);
        for (uint32_t x = 0; x < ow; ++x) {
            const Axis ax = reference_axis(x, sw, ow);
            for (uint32_t c = 0; c < 3; ++c) {
                const size_t i = (size_t(y) * ow + x) * 3 + c;
                auto at = [&](uint32_t sy, uint32_t sx) { return double(input[(size_t(sy) * sw + sx) * 3 + c]); };
                // Weights and accumulators are float64 here; the shader
                // independently computes exact integer coordinates, then
                // rounds the weights and interpolation arithmetic to float32.
                const double top = at(ay.lo, ax.lo) * (1 - ax.fraction) + at(ay.lo, ax.hi) * ax.fraction;
                const double bot = at(ay.hi, ax.lo) * (1 - ax.fraction) + at(ay.hi, ax.hi) * ax.fraction;
                const double expected = top * (1 - ay.fraction) + bot * ay.fraction;
                const double delta = std::abs(actual[i] - expected);
                const double tolerance = 4e-7 * std::max(1.0, std::abs(expected));
                max_error = std::max(max_error, delta);
                if (!std::isfinite(actual[i]) || delta > tolerance ||
                    (pattern == 0 && actual[i] != input[c])) {
                    char detail[512];
                    std::snprintf(detail, sizeof detail,
                        "resample %ux%u -> %ux%u pattern=%u y=%u x=%u c=%u got=%.9g expected=%.12g delta=%.9g",
                        sh, sw, oh, ow, pattern, y, x, c, double(actual[i]), expected, delta);
                    error = detail; return false;
                }
            }
        }
    }
    for (size_t i = output_count; i < initial.size(); ++i) if (actual[i] != sentinel) {
        error = "resample wrote beyond the output count"; return false;
    }
    return true;
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_resample <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<spk::gpu::Gpu> gpu(spk::gpu::Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan resample device: %s\n", gpu->device_name().c_str());
    const std::array<uint32_t, 4> shapes[] = {
        {1,1,1,1}, {1,1,3,5}, {1,7,1,13}, {7,1,13,1},
        {2,2,3,3}, {2,3,7,11}, {3,7,2,5}, {11,13,17,19},
        {11,13,1,1}, {257,263,180,192}, {1172,1757,800,1200},
        {8193,3,4123,7}, {3,16385,7,8193},
        // 64-bit products are necessary on this long, narrow image. A
        // float32 coordinate loses fractions here and causes visible error
        // on the checkerboard; the two-word divide must keep them exactly.
        {1,131071,1,196613}, {131071,1,196613,1}
    };
    double max_error = 0;
    size_t cases = 0;
    for (const auto& shape : shapes) for (uint32_t pattern = 0; pattern < 4; ++pattern) {
        if (!run_case(gpu.get(), shape, pattern, max_error, error)) {
            std::fprintf(stderr, "resample gate: %s\n", error.c_str()); return 1;
        }
        ++cases;
    }
    std::printf("mirror bilinear: %zu GPU cases, singleton/mirror edges/noninteger scales/RAW-tier dimensions/large axes, max abs error %.9g\n",
                cases, max_error);
    return 0;
}
