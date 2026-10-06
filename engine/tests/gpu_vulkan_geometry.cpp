// GPU geometry against an independent double-precision spatial mapping.
// This is a Metal contract port, not a recorded Metal image parity result.
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
struct Case {
    const char* name;
    uint32_t height, width;
    double x = 0, y = 0, width_fraction = 1, height_fraction = 1;
    double angle = 0;
    uint32_t turns = 0, flips = 0;
};

struct Axis { uint32_t first, second; double fraction; };
Axis reference_axis(double coordinate, uint32_t length) {
    // The contract explicitly branches on the float-pair HIGH word, not its
    // real-number sum. Preserve that boundary convention in the oracle while
    // computing the spatial transform independently in float64 below.
    const float high = float(coordinate);
    if (high <= 0) return {0, std::min(1u, length - 1), 0};
    if (high >= float(length) - 1) return {length - 1, length - 1, 0};
    const uint32_t first = uint32_t(std::floor(high));
    return {first, std::min(first + 1, length - 1),
            std::clamp(coordinate - double(first), 0.0, 1.0)};
}

std::array<double, 2> source_coordinate(const Case& test, uint32_t y, uint32_t x,
                                         uint32_t oh, uint32_t ow) {
    // Normalize to the output rectangle first. This avoids reproducing the
    // shader's float-pair constants and sequence of arithmetic operations.
    double u = (double(x) + 0.5) / ow, v = (double(y) + 0.5) / oh;
    if (test.flips & 1u) u = 1 - u;
    if (test.flips & 2u) v = 1 - v;
    const std::array<double, 2> unturned = test.turns == 1 ? std::array<double, 2>{v, 1 - u}
        : test.turns == 2 ? std::array<double, 2>{1 - u, 1 - v}
        : test.turns == 3 ? std::array<double, 2>{1 - v, u}
                          : std::array<double, 2>{u, v};
    const double px = (unturned[0] - 0.5) * test.width_fraction * test.width;
    const double py = (unturned[1] - 0.5) * test.height_fraction * test.height;
    const double angle = test.angle * 3.14159265358979323846 / 180;
    const double ca = std::cos(angle), sa = std::sin(angle);
    return {(test.x + test.width_fraction / 2) * test.width - 0.5 + ca * px - sa * py,
            (test.y + test.height_fraction / 2) * test.height - 0.5 + sa * px + ca * py};
}

bool run_case(spk::gpu::Gpu* gpu, const Case& test, uint32_t pattern,
              double& max_error, std::string& error) {
    const uint32_t sh = test.height, sw = test.width;
    uint32_t oh = uint32_t(std::lround(test.height_fraction * sh));
    uint32_t ow = uint32_t(std::lround(test.width_fraction * sw));
    if (test.turns & 1u) std::swap(oh, ow);
    oh = std::max(oh, 1u); ow = std::max(ow, 1u);
    const uint32_t cw = test.turns & 1u ? oh : ow, ch = test.turns & 1u ? ow : oh;
    const double angle = test.angle * 3.14159265358979323846 / 180;
    const double constants[8] = {
        test.width_fraction * sw / cw, test.height_fraction * sh / ch,
        test.width_fraction * sw / 2, test.height_fraction * sh / 2,
        (test.x + test.width_fraction / 2) * sw - 0.5,
        (test.y + test.height_fraction / 2) * sh - 0.5, std::cos(angle), std::sin(angle)
    };
    float pairs[16];
    for (size_t j = 0; j < 8; ++j) {
        pairs[j * 2] = float(constants[j]);
        pairs[j * 2 + 1] = float(constants[j] - double(pairs[j * 2]));
    }
    std::vector<float> input(size_t(sh) * sw * 3);
    for (uint32_t y = 0; y < sh; ++y) for (uint32_t x = 0; x < sw; ++x)
        for (uint32_t c = 0; c < 3; ++c) {
            const size_t i = (size_t(y) * sw + x) * 3 + c;
            if (pattern == 0) input[i] = float(-0.75 + 1.25 * c);
            else if (pattern == 1) input[i] = float(-0.5 + 0.6 * c +
                0.75 * double(x) / sw - 0.3 * double(y) / sh);
            else if (pattern == 2) {
                const uint32_t ix = c == 0 ? 0 : c == 1 ? sw / 2 : sw - 1;
                const uint32_t iy = c == 0 ? 0 : c == 1 ? sh / 2 : sh - 1;
                input[i] = x == ix && y == iy ? 2.5f : -0.125f;
            } else {
                // A deterministic high-frequency pattern makes coordinate
                // precision failures visible even along very long axes.
                uint32_t hash = x * 1664525u + y * 1013904223u + c * 747796405u;
                hash ^= hash >> 13;
                input[i] = float(int(hash & 1023u) - 256) / 256;
            }
        }
    const size_t pixels = size_t(oh) * ow, output_count = pixels * 3;
    constexpr size_t guard = 64;
    constexpr float sentinel = -123456.0f;
    std::vector<float> initial(output_count + guard, sentinel);
    const uint32_t meta[6] = {sh, sw, oh, ow, test.turns, test.flips};
    auto src = gpu->upload(input.data(), input.size() * sizeof(float), error);
    auto dst = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
    if (!src || !dst || !gpu->dispatch("spk_geometry_resample_df",
        {spk::gpu::Arg::buf(src), spk::gpu::Arg::inline_bytes(pairs, 16),
         spk::gpu::Arg::inline_bytes(meta, 6), spk::gpu::Arg::buf(dst)},
        pixels + 17, error) || !gpu->flush(error)) return false;
    std::vector<float> actual;
    if (!read_test_buffer(gpu, dst, actual, error)) return false;
    const bool permutation = test.x == 0 && test.y == 0 && test.width_fraction == 1 &&
                             test.height_fraction == 1 && test.angle == 0;
    for (uint32_t y = 0; y < oh; ++y) for (uint32_t x = 0; x < ow; ++x) {
        const auto coordinate = source_coordinate(test, y, x, oh, ow);
        const Axis ax = reference_axis(coordinate[0], sw), ay = reference_axis(coordinate[1], sh);
        for (uint32_t c = 0; c < 3; ++c) {
            auto at = [&](uint32_t sy, uint32_t sx) { return double(input[(size_t(sy) * sw + sx) * 3 + c]); };
            const double top = at(ay.first, ax.first) * (1 - ax.fraction) + at(ay.first, ax.second) * ax.fraction;
            const double bot = at(ay.second, ax.first) * (1 - ax.fraction) + at(ay.second, ax.second) * ax.fraction;
            const double expected = top * (1 - ay.fraction) + bot * ay.fraction;
            const size_t i = (size_t(y) * ow + x) * 3 + c;
            const double delta = std::abs(actual[i] - expected);
            const double tolerance = 3e-6 * std::max(1.0, std::abs(expected));
            max_error = std::max(max_error, delta);
            if (!std::isfinite(actual[i]) || delta > tolerance) {
                char detail[512];
                std::snprintf(detail, sizeof detail,
                    "%s %ux%u -> %ux%u pattern=%u y=%u x=%u c=%u got=%.9g expected=%.12g delta=%.9g",
                    test.name, sh, sw, oh, ow, pattern, y, x, c, double(actual[i]), expected, delta);
                error = detail; return false;
            }
            if (permutation) {
                const uint32_t fx = test.flips & 1u ? ow - 1 - x : x;
                const uint32_t fy = test.flips & 2u ? oh - 1 - y : y;
                const uint32_t sx = test.turns == 1 ? fy : test.turns == 2 ? sw - 1 - fx
                                    : test.turns == 3 ? sw - 1 - fy : fx;
                const uint32_t sy = test.turns == 1 ? sh - 1 - fx : test.turns == 2 ? sh - 1 - fy
                                    : test.turns == 3 ? fx : fy;
                if (actual[i] != input[(size_t(sy) * sw + sx) * 3 + c]) {
                    error = std::string(test.name) + ": integer rotation/flip changed a pixel value";
                    return false;
                }
            }
        }
    }
    for (size_t i = output_count; i < initial.size(); ++i) if (actual[i] != sentinel) {
        error = std::string(test.name) + ": geometry wrote beyond output count"; return false;
    }
    return true;
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_geometry <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<spk::gpu::Gpu> gpu(spk::gpu::Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan geometry device: %s\n", gpu->device_name().c_str());
    std::vector<Case> cases = {
        {"singleton", 1, 1}, {"single-row", 1, 19}, {"single-column", 23, 1},
        {"integer-crop", 20, 32, 0.25, 0.2, 0.5, 0.6},
        {"fractional-crop", 19, 37, 0.071, 0.133, 0.673, 0.711},
        {"one-pixel-crop", 19, 37, 0.41, 0.37, 0.001, 0.002},
        {"positive-angle", 29, 47, 0.07, 0.11, 0.83, 0.79, 17.3},
        {"negative-angle", 29, 47, 0.07, 0.11, 0.83, 0.79, -32.125},
        {"right-angle", 17, 31, 0, 0, 1, 1, 90},
        {"all-corners-clamp", 17, 31, 0, 0, 1, 1, 43.25},
        {"crop-outside-source", 9, 13, -0.25, 0.8, 1.5, 0.75, 12.5},
        {"singleton-rotated", 1, 1, 0, 0, 1, 1, -71.3},
        {"long-horizontal", 3, 32771, 0.02173, 0.07, 0.91231, 0.83, 0.017},
        {"long-vertical", 32771, 3, 0.13, 0.03719, 0.73, 0.90013, -0.013},
        {"eight-k-crop-rotated", 17, 8193, 0.08371, 0.091, 0.81319, 0.793, 0.037, 3, 1},
        {"eight-k-portrait", 8193, 17, 0.091, 0.08371, 0.793, 0.81319, -0.037, 1, 2},
    };
    for (uint32_t turns = 0; turns < 4; ++turns) for (uint32_t flips = 0; flips < 4; ++flips) {
        cases.push_back({"exact-quarter-turn-flip", 17, 31, 0, 0, 1, 1, 0, turns, flips});
        cases.push_back({"crop-angle-turn-flip", 23, 43, 0.071, 0.139, 0.763, 0.691, 11.125, turns, flips});
    }
    double max_error = 0;
    size_t passed = 0;
    for (const auto& test : cases) for (uint32_t pattern = 0; pattern < 4; ++pattern) {
        if (!run_case(gpu.get(), test, pattern, max_error, error)) {
            std::fprintf(stderr, "geometry gate: %s\n", error.c_str()); return 1;
        }
        ++passed;
    }
    std::printf("geometry: %zu GPU cases; float64 mapping, exact rotations/flips, fractional crops, "
                "arbitrary angles, edge clamp, long axes, guards; max abs error %.9g\n", passed, max_error);
    return 0;
}
