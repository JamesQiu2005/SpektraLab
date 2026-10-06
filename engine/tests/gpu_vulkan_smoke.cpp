// Headless Windows gate: exercise the ported Vulkan input and Hanatos LUT
// kernels, then create an engine and open a C-ABI session.
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "cam16.hpp"
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"
#include "numeric.hpp"
#include "spektrafilm/spk_engine.h"

namespace {
// Set from math_mode: an accepted unfused-fma device (lavapipe).
bool g_unfused_fma = false;

bool check_fma_vectors(spk::gpu::Gpu* gpu, bool unfused, std::string& error) {
    // Exact binary32 bit patterns derived with integer/rational arithmetic,
    // independent of the host C runtime's fmaf. Cover small residuals, both
    // round-to-even ties, an exact product and legacy MinGW failure cases.
    constexpr uint32_t cases[][3] = {
        {0x3f800001, 0x3f800001, 0x28800000},
        {0x3f800800, 0x3f800800, 0x33800000},
        {0x3f800800, 0x3f801800, 0xb3800000},
        {0x3fc00000, 0x40000000, 0x00000000},
        {0x40a8f5c3, 0x4068f5c3, 0xb5425aee},
        {0x40cc7ae1, 0x40863d70, 0x3357dc00},
    };
    constexpr size_t count = std::size(cases);
    std::array<float, count * 2> input;
    for (size_t i = 0; i < count; ++i) {
        input[2 * i] = std::bit_cast<float>(cases[i][0]);
        input[2 * i + 1] = std::bit_cast<float>(cases[i][1]);
    }
    auto src = gpu->upload(input.data(), sizeof input, error);
    auto dst = gpu->alloc(count * sizeof(float), error);
    if (!src || !dst || !gpu->dispatch("spk_math_probe",
        {spk::gpu::Arg::buf(src), spk::gpu::Arg::buf(dst)}, count, error)) return false;
    std::vector<float> actual;
    if (!read_test_buffer(gpu, dst, actual, error)) return false;
    for (size_t i = 0; i < count; ++i) {
        // An accepted unfused device (a CPU implementation, reported in
        // math_mode) returns exactly 0 for every residual; nothing else.
        const uint32_t want = unfused ? 0u : cases[i][2];
        if (std::bit_cast<uint32_t>(actual[i]) != want) {
            error = "FMA known-bit vector mismatch at " + std::to_string(i);
            return false;
        }
    }
    std::printf("FMA residual: %zu %s known-bit vectors\n", count, unfused ? "unfused (zero)" : "exact");
    return true;
}

// Independent integer oracle: repeatedly reflect at the two walls rather
// than reproducing the shader's period/modulus implementation.
uint32_t fir_reference_index(int64_t index, uint32_t length, bool mirror) {
    if (length <= 1) return 0;
    while (index < 0 || index >= int64_t(length)) {
        if (index < 0) index = mirror ? -index : -index - 1;
        else index = mirror ? 2 * int64_t(length) - 2 - index
                            : 2 * int64_t(length) - 1 - index;
    }
    return uint32_t(index);
}

bool check_fir_boundaries(spk::gpu::Gpu* gpu, std::string& error) {
    // The original smoke had period 4 for both reflect and mirror. A negative
    // value accidentally treated as unsigned has the same remainder for that
    // power of two, hiding the defect. Odd lengths and bands do not hide it.
    const uint32_t shapes[][2] = {{1, 1}, {1, 7}, {7, 1}, {7, 11}, {19, 13}, {129, 193}};
    const uint32_t radii[] = {1, 2, 9};
    const float mix[3] = {0.5f, 1.0f, 2.0f};
    constexpr float sentinel = -12345.0f;
    constexpr size_t guard = 16;
    size_t cases = 0;
    for (const auto& shape : shapes) {
        const uint32_t height = shape[0], width = shape[1];
        const size_t count = size_t(height) * width * 3;
        std::vector<float> input(count), accumulated(count), initial(count + guard, sentinel);
        for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x)
            for (uint32_t c = 0; c < 3; ++c) {
                const size_t at = (size_t(y) * width + x) * 3 + c;
                input[at] = float(17 * y + 11 * x + 31 * c + (x * y) % 7) / 1024.0f;
                accumulated[at] = float(c + 1) / 16.0f;
            }
        auto src = gpu->upload(input.data(), count * sizeof(float), error);
        auto acc = gpu->upload(accumulated.data(), count * sizeof(float), error);
        auto mix_buffer = gpu->upload(mix, sizeof mix, error);
        if (!src || !acc || !mix_buffer) return false;
        for (uint32_t radius : radii) {
            const uint32_t taps = 2 * radius + 1;
            // One-hot weights select -R, 0 and +R in the three channels.
            // Inputs, gains and offsets are exact binary fractions, making
            // this an exact indexing gate without a numerical tolerance.
            std::vector<float> weights(size_t(taps) * 3, 0.0f);
            weights[0] = weights[taps + radius] = weights[2 * taps + 2 * radius] = 1.0f;
            auto w = gpu->upload(weights.data(), weights.size() * sizeof(float), error);
            if (!w) return false;
            for (uint32_t axis = 0; axis < 2; ++axis)
                for (uint32_t mirror = 0; mirror < 2; ++mirror)
                    for (uint32_t accumulate = 0; accumulate < 2; ++accumulate) {
                        auto dst = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
                        const uint32_t meta[6] = {height, width, radius, axis, accumulate, mirror};
                        if (!dst || !gpu->dispatch("spk_sep_fir_acc",
                            {spk::gpu::Arg::buf(src), spk::gpu::Arg::buf(w), spk::gpu::Arg::buf(acc),
                             spk::gpu::Arg::buf(mix_buffer), spk::gpu::Arg::inline_bytes(meta, 6),
                             spk::gpu::Arg::buf(dst)}, size_t(height) * width, error)) return false;
                        std::vector<float> actual;
                        if (!read_test_buffer(gpu, dst, actual, error)) return false;
                        for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x)
                            for (uint32_t c = 0; c < 3; ++c) {
                                const int64_t tap = (int64_t(c) - 1) * radius;
                                const uint32_t coordinate = fir_reference_index(
                                    int64_t(axis ? x : y) + tap, axis ? width : height, mirror != 0);
                                const size_t from = axis ? (size_t(y) * width + coordinate) * 3 + c
                                                         : (size_t(coordinate) * width + x) * 3 + c;
                                const size_t at = (size_t(y) * width + x) * 3 + c;
                                const float expected = accumulate ? accumulated[at] + mix[c] * input[from]
                                                                  : input[from];
                                if (actual[at] != expected) {
                                    char detail[384];
                                    std::snprintf(detail, sizeof detail,
                                        "FIR boundary H=%u W=%u R=%u axis=%u mirror=%u acc=%u y=%u x=%u c=%u got=%.9g expected=%.9g source_axis=%u",
                                        height, width, radius, axis, mirror, accumulate, y, x, c,
                                        double(actual[at]), double(expected), coordinate);
                                    error = detail; return false;
                                }
                            }
                        for (size_t at = count; at < initial.size(); ++at) if (actual[at] != sentinel) {
                            error = "FIR boundary dispatch overwrote its output guard"; return false;
                        }
                        ++cases;
                    }
        }
    }
    std::printf("FIR boundary oracle: %zu exact cases, odd/singleton dimensions, both axes and edge modes, long radii and accumulation\n", cases);
    return true;
}

// Independent float64 state recurrence, without copying the shader's
// double-float arithmetic. The forward plane is rounded to float32, as the
// public image contract and Metal kernel require, while state stays float64.
std::vector<float> reference_iir(const std::vector<float>& input,
                                uint32_t height, uint32_t width, uint32_t axis,
                                const double coefficients[3][4], uint32_t active_mask,
                                const std::vector<float>& accumulator,
                                const float weights[3], bool accumulate) {
    std::vector<float> out(input.size());
    const uint32_t length = axis == 0 ? height : width;
    const uint32_t lines = axis == 0 ? width : height;
    const size_t stride = axis == 0 ? size_t(width) * 3 : 3;
    std::vector<float> forward(length);
    for (uint32_t line = 0; line < lines; ++line)
        for (uint32_t channel = 0; channel < 3; ++channel) {
            const size_t base = axis == 0 ? size_t(line) * 3 + channel
                                         : size_t(line) * width * 3 + channel;
            if ((active_mask & (1u << channel)) == 0) {
                for (uint32_t i = 0; i < length; ++i) {
                    const size_t index = base + i * stride;
                    const float weighted = weights[channel] * input[index];
                    out[index] = accumulate ? accumulator[index] + weighted : input[index];
                }
                continue;
            }
            const double* b = coefficients[channel];
            std::array<double, 3> state{input[base], input[base], input[base]};
            for (uint32_t i = 0; i < length; ++i) {
                const double value = b[0] * double(input[base + i * stride]) +
                                     b[1] * state[0] + b[2] * state[1] + b[3] * state[2];
                forward[i] = float(value);
                state = {value, state[0], state[1]};
            }
            state.fill(forward.back());
            for (uint32_t i = length; i-- > 0;) {
                const double value = b[0] * double(forward[i]) +
                                     b[1] * state[0] + b[2] * state[1] + b[3] * state[2];
                const float weighted = weights[channel] * float(value);
                const size_t index = base + i * stride;
                out[index] = accumulate ? accumulator[index] + weighted : float(value);
                state = {value, state[0], state[1]};
            }
        }
    return out;
}

bool check_iir(spk::gpu::Gpu* gpu, std::string& error) {
    // The large-sigma tail (130) is precisely where a plain float32 IIR
    // drifts; 3 is the actual FIR/IIR crossover and 12 covers a middle case.
    const double sigmas[3] = {3.0, 12.0, 130.0};
    double coefficients[3][4];
    float pairs[24];
    for (size_t channel = 0; channel < 3; ++channel) {
        spk::yvv_coeffs(sigmas[channel], coefficients[channel]);
        for (size_t j = 0; j < 4; ++j) {
            const float hi = float(coefficients[channel][j]);
            pairs[channel * 8 + j * 2] = hi;
            pairs[channel * 8 + j * 2 + 1] = float(coefficients[channel][j] - double(hi));
        }
    }
    const float weights[3] = {-0.5f, 0.25f, 1.75f};
    const float constants[3] = {-0.25f, 0.5f, 1.5f};
    auto coefficient_buffer = gpu->upload(pairs, sizeof pairs, error);
    auto weight_buffer = gpu->upload(weights, sizeof weights, error);
    if (!coefficient_buffer || !weight_buffer) return false;
    // Dimension 1 pins sample-replication boundaries; lengths 2 and 3 expose
    // recurrence initialization, while 257 crosses a workgroup boundary and
    // gives the nearly-unit poles enough distance to reveal precision loss.
    const uint32_t shapes[][2] = {
        {1, 1}, {1, 2}, {2, 1}, {2, 3}, {3, 2}, {5, 7}, {3, 257}, {257, 3}
    };
    const uint32_t masks[] = {0u, 2u, 7u};  // zero, one, and three active channels
    size_t cases = 0;
    double max_error = 0;
    for (const auto& shape : shapes) {
        const uint32_t height = shape[0], width = shape[1];
        const size_t count = size_t(height) * width * 3;
        for (uint32_t pattern = 0; pattern < 3; ++pattern) {
            std::vector<float> input(count), accumulator(count);
            for (uint32_t y = 0; y < height; ++y)
                for (uint32_t x = 0; x < width; ++x)
                    for (uint32_t channel = 0; channel < 3; ++channel) {
                        const size_t index = (size_t(y) * width + x) * 3 + channel;
                        accumulator[index] = float(0.2 + 0.03 * channel + 0.001 * (int(x) - int(y)));
                        if (pattern == 0) input[index] = constants[channel];
                        else if (pattern == 1)
                            input[index] = float(-0.4 + 0.2 * channel + 0.003 * x - 0.002 * y +
                                                 0.1 * std::sin(0.07 * x + 0.11 * y));
                        else {
                            const uint32_t impulse_x = channel == 0 ? 0 : channel == 1 ? width / 2 : width - 1;
                            const uint32_t impulse_y = channel == 0 ? 0 : channel == 1 ? height / 2 : height - 1;
                            input[index] = x == impulse_x && y == impulse_y ? 1.0f : 0.0f;
                        }
                    }
            for (uint32_t axis = 0; axis < 2; ++axis)
                for (uint32_t mask : masks)
                    for (uint32_t accumulate = 0; accumulate < 2; ++accumulate)
                        for (uint32_t in_place = 0; in_place < 2; ++in_place) {
                            const uint32_t active[3] = {mask & 1u, (mask >> 1) & 1u, (mask >> 2) & 1u};
                            const uint32_t meta[4] = {height, width, accumulate, axis};
                            auto input_buffer = gpu->upload(input.data(), count * sizeof(float), error);
                            auto active_buffer = gpu->upload_u32(active, 3, error);
                            auto accumulator_buffer = gpu->upload(accumulator.data(), count * sizeof(float), error);
                            auto output_buffer = in_place ? input_buffer : gpu->alloc(count * sizeof(float), error);
                            if (!input_buffer || !active_buffer || !accumulator_buffer || !output_buffer ||
                                !gpu->dispatch("spk_iir_df_acc",
                                    {spk::gpu::Arg::buf(input_buffer), spk::gpu::Arg::buf(coefficient_buffer),
                                     spk::gpu::Arg::buf(active_buffer), spk::gpu::Arg::buf(accumulator_buffer),
                                     spk::gpu::Arg::buf(weight_buffer), spk::gpu::Arg::inline_bytes(meta, 4),
                                     spk::gpu::Arg::buf(output_buffer)},
                                    size_t(axis == 0 ? width : height) * 3, error) ||
                                !gpu->flush(error)) return false;
                            const auto expected = reference_iir(input, height, width, axis, coefficients,
                                                                mask, accumulator, weights, accumulate != 0);
                            std::vector<float> actual_readback;
                            if (!read_test_buffer(gpu, output_buffer, actual_readback, error)) return false;
                            const float* actual = actual_readback.data();
                            for (size_t i = 0; i < count; ++i) {
                                const double delta = std::fabs(double(actual[i]) - expected[i]);
                                const double tolerance = 4 * double(std::numeric_limits<float>::epsilon()) *
                                                         std::max(1.0, std::fabs(double(expected[i])));
                                max_error = std::max(max_error, delta);
                                // Constants have an analytic solution under replicated
                                // boundaries, independent of the reference recurrence.
                                const uint32_t channel = uint32_t(i % 3);
                                const float weighted_constant = weights[channel] * constants[channel];
                                const float analytic = accumulate ? accumulator[i] + weighted_constant
                                                                  : constants[channel];
                                const bool constant_wrong = pattern == 0 &&
                                    std::fabs(double(actual[i]) - analytic) > tolerance;
                                if (!std::isfinite(actual[i]) || delta > tolerance || constant_wrong) {
                                    char detail[320];
                                    std::snprintf(detail, sizeof detail,
                                        "IIR %ux%u axis=%u mask=%u pattern=%u acc=%u alias=%u index=%zu "
                                        "got=%.9g expected=%.9g delta=%.9g tolerance=%.9g",
                                        height, width, axis, mask, pattern, accumulate, in_place, i,
                                        double(actual[i]), double(expected[i]), delta, tolerance);
                                    error = detail;
                                    return false;
                                }
                                if ((mask & (1u << channel)) == 0 && actual[i] != expected[i]) {
                                    error = "IIR inactive channel changed its copy/accumulate result";
                                    return false;
                                }
                            }
                            ++cases;
                        }
        }
    }
    std::printf("iir_df_acc: %zu float64/analytic cases, max abs error %.9g\n", cases, max_error);
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_smoke <resources>\n"); return 2; }
    const std::string resources = argv[1];
    std::string error;
    spk::gpu::Gpu* gpu = spk::gpu::Gpu::create_vulkan(resources + "/vulkan", error);
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    std::string math;
    if (!gpu->check_math_mode(math)) {
        std::fprintf(stderr, "math mode: %s\n", math.c_str());
        delete gpu;
        return 1;
    }
    std::printf("math mode: %s\n", math.c_str());

    g_unfused_fma = math.find("unfused") != std::string::npos;
    if (!check_fma_vectors(gpu, g_unfused_fma, error)) {
        std::fprintf(stderr, "FMA residual: %s\n", error.c_str());
        delete gpu;
        return 1;
    }

    if (!check_fir_boundaries(gpu, error)) {
        std::fprintf(stderr, "FIR boundary oracle: %s\n", error.c_str());
        delete gpu;
        return 1;
    }

    if (!check_iir(gpu, error)) {
        std::fprintf(stderr, "iir_df_acc: %s\n", error.c_str());
        delete gpu;
        return 1;
    }

    const float rgba[] = {1, 2, 3, 0.5f, 4, 5, 6, 0.25f};
    const uint32_t meta[] = {2, 4};
    auto input = gpu->upload(rgba, sizeof rgba, error);
    auto rgb = gpu->alloc(6 * sizeof(float), error);
    if (!input || !rgb ||
        !gpu->dispatch("spk_take_rgb",
                       {spk::gpu::Arg::buf(input), spk::gpu::Arg::inline_bytes(meta, 2),
                        spk::gpu::Arg::buf(rgb)}, 2, error)) {
        std::fprintf(stderr, "take_rgb: %s\n", error.c_str());
        return 1;
    }
    const float expected_rgb[] = {1, 2, 3, 4, 5, 6};
    std::vector<float> rgb_readback;
    if (!read_test_buffer(gpu, rgb, rgb_readback, error)) return 1;
    if (std::memcmp(rgb_readback.data(), expected_rgb, sizeof expected_rgb) != 0) {
        std::fprintf(stderr, "take_rgb: wrong pixels\n");
        return 1;
    }

    const float matrix[] = {1, 0, 0, 0, 2, 0, 0, 0, 3};
    const uint32_t n[] = {2};
    auto m = gpu->upload(matrix, sizeof matrix, error);
    auto transformed = gpu->alloc(6 * sizeof(float), error);
    if (!m || !transformed ||
        !gpu->dispatch("spk_matmul3",
                       {spk::gpu::Arg::buf(rgb), spk::gpu::Arg::buf(m),
                        spk::gpu::Arg::inline_bytes(n, 1), spk::gpu::Arg::buf(transformed)},
                       2, error)) {
        std::fprintf(stderr, "matmul3: %s\n", error.c_str());
        return 1;
    }
    const float expected_transformed[] = {1, 4, 9, 4, 10, 18};
    std::vector<float> got_readback;
    if (!read_test_buffer(gpu, transformed, got_readback, error)) return 1;
    const float* got = got_readback.data();
    for (size_t i = 0; i < 6; ++i) {
        if (std::fabs(got[i] - expected_transformed[i]) > 1e-6f) {
            std::fprintf(stderr, "matmul3: value %zu is %g, expected %g\n",
                         i, double(got[i]), double(expected_transformed[i]));
            return 1;
        }
    }
    // A 4x5 image sampled every second pixel becomes 2x3. This checks both
    // axes and the shader's bounds guard for its partial workgroup.
    float frame[4 * 5 * 3];
    for (size_t i = 0; i < 4 * 5; ++i)
        for (size_t c = 0; c < 3; ++c) frame[3 * i + c] = float(10 * i + c);
    const uint32_t sample_meta[] = {5, 2, 3, 2};
    auto frame_buffer = gpu->upload(frame, sizeof frame, error);
    auto sampled = gpu->alloc(2 * 3 * 3 * sizeof(float), error);
    if (!frame_buffer || !sampled ||
        !gpu->dispatch("spk_stride_sample",
                       {spk::gpu::Arg::buf(frame_buffer),
                        spk::gpu::Arg::inline_bytes(sample_meta, 4),
                        spk::gpu::Arg::buf(sampled)}, 6, error)) {
        std::fprintf(stderr, "stride_sample: %s\n", error.c_str());
        return 1;
    }
    std::vector<float> sample_readback;
    if (!read_test_buffer(gpu, sampled, sample_readback, error)) return 1;
    const float* sample = sample_readback.data();
    for (size_t y = 0; y < 2; ++y)
        for (size_t x = 0; x < 3; ++x)
            for (size_t c = 0; c < 3; ++c) {
                const size_t source = (y * 2) * 5 + x * 2;
                if (sample[3 * (y * 3 + x) + c] != frame[3 * source + c]) {
                    std::fprintf(stderr, "stride_sample: wrong sample (%zu,%zu,%zu)\n", y, x, c);
                    return 1;
                }
            }
    sampled.reset(); frame_buffer.reset();
    const float scales[] = {2.0f, -1.0f, 0.5f};
    const float offsets[] = {1.0f, 3.0f, -2.0f};
    const uint32_t affine_count[] = {6};
    auto scale_buffer = gpu->upload(scales, sizeof scales, error);
    auto offset_buffer = gpu->upload(offsets, sizeof offsets, error);
    auto affine = gpu->alloc(6 * sizeof(float), error);
    if (!scale_buffer || !offset_buffer || !affine ||
        !gpu->dispatch("spk_affine3",
                       {spk::gpu::Arg::buf(rgb), spk::gpu::Arg::buf(scale_buffer),
                        spk::gpu::Arg::buf(offset_buffer),
                        spk::gpu::Arg::inline_bytes(affine_count, 1),
                        spk::gpu::Arg::buf(affine)}, 6, error)) {
        std::fprintf(stderr, "affine3: %s\n", error.c_str());
        return 1;
    }
    const float affine_expected[] = {3, 1, -0.5f, 9, -2, 1};
    std::vector<float> affine_got_readback;
    if (!read_test_buffer(gpu, affine, affine_got_readback, error)) return 1;
    const float* affine_got = affine_got_readback.data();
    for (size_t i = 0; i < 6; ++i)
        if (std::fabs(affine_got[i] - affine_expected[i]) > 1e-6f) {
            std::fprintf(stderr, "affine3: wrong value %zu\n", i);
            return 1;
        }
    affine.reset(); offset_buffer.reset(); scale_buffer.reset();

    // Identity XYZ transform: one chromatic sample and black. This also
    // verifies the row-major matrix convention of this particular kernel.
    const float chromatic_rgb[] = {0.2f, 0.3f, 0.5f, 0, 0, 0};
    const float identity[] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    auto chromatic_input = gpu->upload(chromatic_rgb, sizeof chromatic_rgb, error);
    auto identity_buffer = gpu->upload(identity, sizeof identity, error);
    auto coordinates = gpu->alloc(4 * sizeof(float), error);
    auto brightness = gpu->alloc(2 * sizeof(float), error);
    if (!chromatic_input || !identity_buffer || !coordinates || !brightness ||
        !gpu->dispatch("spk_tc_b",
                       {spk::gpu::Arg::buf(chromatic_input), spk::gpu::Arg::buf(identity_buffer),
                        spk::gpu::Arg::inline_bytes(n, 1), spk::gpu::Arg::buf(coordinates),
                        spk::gpu::Arg::buf(brightness)}, 2, error)) {
        std::fprintf(stderr, "tc_b: %s\n", error.c_str());
        return 1;
    }
    const float expected_coordinates[] = {0.64f, 0.375f, 1.0f, 0.0f};
    const float expected_brightness[] = {1.0f, 0.0f};
    std::vector<float> coordinates_got_readback;
    if (!read_test_buffer(gpu, coordinates, coordinates_got_readback, error)) return 1;
    const float* coordinates_got = coordinates_got_readback.data();
    std::vector<float> brightness_got_readback;
    if (!read_test_buffer(gpu, brightness, brightness_got_readback, error)) return 1;
    const float* brightness_got = brightness_got_readback.data();
    for (size_t i = 0; i < 4; ++i)
        if (std::fabs(coordinates_got[i] - expected_coordinates[i]) > 1e-6f) {
            std::fprintf(stderr, "tc_b: wrong coordinate %zu: %g\n", i,
                         double(coordinates_got[i]));
            return 1;
        }
    for (size_t i = 0; i < 2; ++i)
        if (std::fabs(brightness_got[i] - expected_brightness[i]) > 1e-6f) {
            std::fprintf(stderr, "tc_b: wrong brightness %zu: %g\n", i,
                         double(brightness_got[i]));
            return 1;
        }
    brightness.reset(); coordinates.reset(); identity_buffer.reset(); chromatic_input.reset();

    // An affine LUT must reproduce its interior samples exactly under
    // Mitchell interpolation. Two positions also check LUT axis order.
    float lut[5 * 5 * 3];
    for (size_t x = 0; x < 5; ++x)
        for (size_t y = 0; y < 5; ++y) {
            const size_t offset = 3 * (x * 5 + y);
            lut[offset] = float(x) / 4.0f;
            lut[offset + 1] = float(y) / 4.0f;
            lut[offset + 2] = 1.0f;
        }
    const float lut_coordinates[] = {0.25f, 0.5f, 0.5f, 0.75f};
    const float lut_brightness[] = {2.0f, 3.0f};
    const uint32_t lut_meta[] = {5, 2};
    auto lut_coords_buffer = gpu->upload(lut_coordinates, sizeof lut_coordinates, error);
    auto lut_brightness_buffer = gpu->upload(lut_brightness, sizeof lut_brightness, error);
    auto lut_buffer = gpu->upload(lut, sizeof lut, error);
    auto lut_output = gpu->alloc(6 * sizeof(float), error);
    if (!lut_coords_buffer || !lut_brightness_buffer || !lut_buffer || !lut_output ||
        !gpu->dispatch("spk_lut2d_cubic",
                       {spk::gpu::Arg::buf(lut_coords_buffer),
                        spk::gpu::Arg::buf(lut_brightness_buffer), spk::gpu::Arg::buf(lut_buffer),
                        spk::gpu::Arg::inline_bytes(lut_meta, 2), spk::gpu::Arg::buf(lut_output)},
                       2, error)) {
        std::fprintf(stderr, "lut2d_cubic: %s\n", error.c_str());
        return 1;
    }
    const float lut_expected[] = {0.5f, 1.0f, 2.0f, 1.5f, 2.25f, 3.0f};
    std::vector<float> lut_got_readback;
    if (!read_test_buffer(gpu, lut_output, lut_got_readback, error)) return 1;
    const float* lut_got = lut_got_readback.data();
    for (size_t i = 0; i < 6; ++i)
        if (std::fabs(lut_got[i] - lut_expected[i]) > 2e-5f) {
            std::fprintf(stderr, "lut2d_cubic: wrong value %zu: %g expected %g\n", i,
                         double(lut_got[i]), double(lut_expected[i]));
            return 1;
        }
    lut_output.reset(); lut_buffer.reset(); lut_brightness_buffer.reset(); lut_coords_buffer.reset();

    // A 2x3 RGB image makes the two edge policies distinguishable. The
    // channel offsets also expose mistakes in the planar weight layout.
    float blur_input[2 * 3 * 3];
    for (size_t pixel = 0; pixel < 6; ++pixel)
        for (size_t channel = 0; channel < 3; ++channel)
            blur_input[3 * pixel + channel] = float(10 * pixel + 100 * channel);
    const float blur_weights[] = {
        0.25f, 0.5f, 0.25f, 0.25f, 0.5f, 0.25f, 0.25f, 0.5f, 0.25f
    };
    const float mix_weights[] = {2, 3, 4};
    float accumulated[2 * 3 * 3];
    for (size_t pixel = 0; pixel < 6; ++pixel)
        for (size_t channel = 0; channel < 3; ++channel)
            accumulated[3 * pixel + channel] = float(channel + 1);
    auto blur_input_buffer = gpu->upload(blur_input, sizeof blur_input, error);
    auto blur_weights_buffer = gpu->upload(blur_weights, sizeof blur_weights, error);
    auto mix_weights_buffer = gpu->upload(mix_weights, sizeof mix_weights, error);
    auto accumulated_buffer = gpu->upload(accumulated, sizeof accumulated, error);
    auto blur_output = gpu->alloc(sizeof blur_input, error);
    if (!blur_input_buffer || !blur_weights_buffer || !mix_weights_buffer ||
        !accumulated_buffer || !blur_output) {
        std::fprintf(stderr, "sep_fir_acc: %s\n", error.c_str());
        return 1;
    }
    const uint32_t reflect_vertical[] = {2, 3, 1, 0, 0, 0};
    if (!gpu->dispatch("spk_sep_fir_acc",
                       {spk::gpu::Arg::buf(blur_input_buffer),
                        spk::gpu::Arg::buf(blur_weights_buffer),
                        spk::gpu::Arg::buf(accumulated_buffer),
                        spk::gpu::Arg::buf(mix_weights_buffer),
                        spk::gpu::Arg::inline_bytes(reflect_vertical, 6),
                        spk::gpu::Arg::buf(blur_output)}, 6, error)) {
        std::fprintf(stderr, "sep_fir_acc reflect: %s\n", error.c_str());
        return 1;
    }
    std::vector<float> blurred_readback;
    if (!read_test_buffer(gpu, blur_output, blurred_readback, error)) return 1;
    const float* blurred = blurred_readback.data();
    for (size_t pixel = 0; pixel < 6; ++pixel)
        for (size_t channel = 0; channel < 3; ++channel) {
            const float expected = (pixel < 3 ? 7.5f : 22.5f) +
                                   float(10 * (pixel % 3) + 100 * channel);
            if (std::fabs(blurred[3 * pixel + channel] - expected) > 1e-5f) {
                std::fprintf(stderr, "sep_fir_acc reflect: wrong pixel %zu channel %zu\n",
                             pixel, channel);
                return 1;
            }
        }
    const uint32_t mirror_horizontal_acc[] = {2, 3, 1, 1, 1, 1};
    if (!gpu->dispatch("spk_sep_fir_acc",
                       {spk::gpu::Arg::buf(blur_input_buffer),
                        spk::gpu::Arg::buf(blur_weights_buffer),
                        spk::gpu::Arg::buf(accumulated_buffer),
                        spk::gpu::Arg::buf(mix_weights_buffer),
                        spk::gpu::Arg::inline_bytes(mirror_horizontal_acc, 6),
                        spk::gpu::Arg::buf(blur_output)}, 6, error)) {
        std::fprintf(stderr, "sep_fir_acc mirror/acc: %s\n", error.c_str());
        return 1;
    }
    if (!read_test_buffer(gpu, blur_output, blurred_readback, error)) return 1;
    blurred = blurred_readback.data();
    const float expected_red[] = {5, 10, 15, 35, 40, 45};
    for (size_t pixel = 0; pixel < 6; ++pixel)
        for (size_t channel = 0; channel < 3; ++channel) {
            const float convolution = expected_red[pixel] + float(100 * channel);
            const float expected = float(channel + 1) +
                                   convolution * mix_weights[channel];
            if (std::fabs(blurred[3 * pixel + channel] - expected) > 1e-5f) {
                std::fprintf(stderr, "sep_fir_acc mirror/acc: wrong pixel %zu channel %zu\n",
                             pixel, channel);
                return 1;
            }
        }
    blur_output.reset(); accumulated_buffer.reset(); mix_weights_buffer.reset();
    blur_weights_buffer.reset(); blur_input_buffer.reset();

    const float combination_a[] = {2, -1, 0.5f};
    const float combination_b[] = {-1, 3, 4};
    auto combination_a_buffer = gpu->upload(combination_a, sizeof combination_a, error);
    auto combination_b_buffer = gpu->upload(combination_b, sizeof combination_b, error);
    auto combination_output = gpu->alloc(6 * sizeof(float), error);
    if (!combination_a_buffer || !combination_b_buffer || !combination_output ||
        !gpu->dispatch("spk_lincomb3",
                       {spk::gpu::Arg::buf(rgb), spk::gpu::Arg::buf(transformed),
                        spk::gpu::Arg::buf(combination_a_buffer),
                        spk::gpu::Arg::buf(combination_b_buffer),
                        spk::gpu::Arg::inline_bytes(affine_count, 1),
                        spk::gpu::Arg::buf(combination_output)}, 6, error)) {
        std::fprintf(stderr, "lincomb3: %s\n", error.c_str());
        return 1;
    }
    const float combination_expected[] = {1, 10, 37.5f, 4, 25, 75};
    std::vector<float> combination_got_readback;
    if (!read_test_buffer(gpu, combination_output, combination_got_readback, error)) return 1;
    const float* combination_got = combination_got_readback.data();
    for (size_t i = 0; i < 6; ++i)
        if (std::fabs(combination_got[i] - combination_expected[i]) > 1e-6f) {
            std::fprintf(stderr, "lincomb3: wrong value %zu\n", i);
            return 1;
        }
    combination_output.reset(); combination_b_buffer.reset(); combination_a_buffer.reset();

    const float log_input[] = {1, -2, 0, 10, 100, 0.01f};
    const float log_gain[] = {10, 1, 100};
    auto log_input_buffer = gpu->upload(log_input, sizeof log_input, error);
    auto log_gain_buffer = gpu->upload(log_gain, sizeof log_gain, error);
    auto log_output = gpu->alloc(sizeof log_input, error);
    if (!log_input_buffer || !log_gain_buffer || !log_output ||
        !gpu->dispatch("spk_log10_guarded",
                       {spk::gpu::Arg::buf(log_input_buffer), spk::gpu::Arg::buf(log_gain_buffer),
                        spk::gpu::Arg::inline_bytes(affine_count, 1),
                        spk::gpu::Arg::buf(log_output)}, 6, error)) {
        std::fprintf(stderr, "log10_guarded: %s\n", error.c_str());
        return 1;
    }
    const float log_expected[] = {1, -10, -10, 2, 2, 0};
    std::vector<float> log_got_readback;
    if (!read_test_buffer(gpu, log_output, log_got_readback, error)) return 1;
    const float* log_got = log_got_readback.data();
    for (size_t i = 0; i < 6; ++i)
        if (std::fabs(log_got[i] - log_expected[i]) > 2e-5f) {
            std::fprintf(stderr, "log10_guarded: wrong value %zu: %g\n", i,
                         double(log_got[i]));
            return 1;
        }
    log_output.reset(); log_gain_buffer.reset(); log_input_buffer.reset();

    const float curve_x[] = {0, 0, 0, 1, 2, 3, 2, 4, 6};
    const float curve_inv[] = {1, 0.5f, 1.0f / 3.0f,
                               1, 0.5f, 1.0f / 3.0f};
    const float curve_y[] = {0, 10, 100, 10, 20, 200, 20, 30, 300};
    const float curve_input[] = {-1, 2, 7, 0.5f, 1, 1.5f, 2, 4, 6};
    const uint32_t curve_meta[] = {3, 3};
    auto curve_input_buffer = gpu->upload(curve_input, sizeof curve_input, error);
    auto curve_x_buffer = gpu->upload(curve_x, sizeof curve_x, error);
    auto curve_inv_buffer = gpu->upload(curve_inv, sizeof curve_inv, error);
    auto curve_y_buffer = gpu->upload(curve_y, sizeof curve_y, error);
    auto curve_output = gpu->alloc(sizeof curve_input, error);
    if (!curve_input_buffer || !curve_x_buffer || !curve_inv_buffer || !curve_y_buffer ||
        !curve_output ||
        !gpu->dispatch("spk_curves",
                       {spk::gpu::Arg::buf(curve_input_buffer), spk::gpu::Arg::buf(curve_x_buffer),
                        spk::gpu::Arg::buf(curve_inv_buffer), spk::gpu::Arg::buf(curve_y_buffer),
                        spk::gpu::Arg::inline_bytes(curve_meta, 2),
                        spk::gpu::Arg::buf(curve_output)}, 3, error)) {
        std::fprintf(stderr, "curves: %s\n", error.c_str());
        return 1;
    }
    const float curve_expected[] = {0, 20, 300, 5, 15, 150, 20, 30, 300};
    std::vector<float> curve_got_readback;
    if (!read_test_buffer(gpu, curve_output, curve_got_readback, error)) return 1;
    const float* curve_got = curve_got_readback.data();
    for (size_t i = 0; i < 9; ++i)
        if (std::fabs(curve_got[i] - curve_expected[i]) > 1e-5f) {
            std::fprintf(stderr, "curves: wrong value %zu: %g\n", i,
                         double(curve_got[i]));
            return 1;
        }
    curve_output.reset(); curve_y_buffer.reset(); curve_inv_buffer.reset();
    curve_x_buffer.reset(); curve_input_buffer.reset();

    const float coupler_matrix[] = {0, 1, 0, 0, 0, 1, 1, 0, 0};
    const float coupler_dmax[] = {4, 5, 6};
    const float coupler_shift[] = {0.1f};
    const uint32_t coupler_negative[] = {0};
    const uint32_t coupler_positive[] = {1};
    auto coupler_matrix_buffer = gpu->upload(coupler_matrix, sizeof coupler_matrix, error);
    auto coupler_dmax_buffer = gpu->upload(coupler_dmax, sizeof coupler_dmax, error);
    auto coupler_shift_buffer = gpu->upload(coupler_shift, sizeof coupler_shift, error);
    auto coupler_output = gpu->alloc(6 * sizeof(float), error);
    if (!coupler_matrix_buffer || !coupler_dmax_buffer || !coupler_shift_buffer ||
        !coupler_output) {
        std::fprintf(stderr, "couplers_correction: %s\n", error.c_str());
        return 1;
    }
    const uint32_t* coupler_modes[] = {coupler_negative, coupler_positive};
    const float coupler_expected[][6] = {
        {3.9f, 1.1f, 2.4f, 9.6f, 5.6f, 7.5f},
        {3.9f, 3.9f, 3.9f, 0, 0, 0}
    };
    for (size_t mode = 0; mode < 2; ++mode) {
        if (!gpu->dispatch("spk_couplers_correction",
                           {spk::gpu::Arg::buf(rgb), spk::gpu::Arg::buf(coupler_matrix_buffer),
                            spk::gpu::Arg::buf(coupler_dmax_buffer),
                            spk::gpu::Arg::inline_bytes(coupler_modes[mode], 1),
                            spk::gpu::Arg::buf(coupler_shift_buffer),
                            spk::gpu::Arg::inline_bytes(n, 1),
                            spk::gpu::Arg::buf(coupler_output)}, 2, error)) {
            std::fprintf(stderr, "couplers_correction: %s\n", error.c_str());
            return 1;
        }
        std::vector<float> coupler_got_readback;
        if (!read_test_buffer(gpu, coupler_output, coupler_got_readback, error)) return 1;
        const float* coupler_got = coupler_got_readback.data();
        for (size_t i = 0; i < 6; ++i)
            if (std::fabs(coupler_got[i] - coupler_expected[mode][i]) > 2e-5f) {
                std::fprintf(stderr, "couplers_correction: mode %zu value %zu: %g\n",
                             mode, i, double(coupler_got[i]));
                return 1;
            }
    }
    coupler_output.reset(); coupler_shift_buffer.reset(); coupler_dmax_buffer.reset();
    coupler_matrix_buffer.reset();

    // Two wavelengths with independent channel densities give closed-form
    // transmission values (1 and 0.1), then exercise both epilogue modes.
    const float spectral_input[] = {0, 0, 0, 1, 1, 0};
    const float spectral_characteristic[] = {1, 0, 0, 0, 1, 0};
    const float spectral_base[] = {0, 0};
    const float spectral_integral[] = {1, 2, 3, 4, 5, 6};
    const float spectral_epilogue[] = {2, 3, 4, 0, 1, -5};
    auto spectral_input_buffer = gpu->upload(spectral_input, sizeof spectral_input, error);
    auto spectral_characteristic_buffer =
        gpu->upload(spectral_characteristic, sizeof spectral_characteristic, error);
    auto spectral_base_buffer = gpu->upload(spectral_base, sizeof spectral_base, error);
    auto spectral_integral_buffer = gpu->upload(spectral_integral, sizeof spectral_integral, error);
    auto spectral_epilogue_buffer = gpu->upload(spectral_epilogue, sizeof spectral_epilogue, error);
    auto spectral_output = gpu->alloc(sizeof spectral_input, error);
    if (!spectral_input_buffer || !spectral_characteristic_buffer || !spectral_base_buffer ||
        !spectral_integral_buffer || !spectral_epilogue_buffer || !spectral_output) {
        std::fprintf(stderr, "spectral_epilogue: %s\n", error.c_str());
        return 1;
    }
    for (uint32_t mode = 0; mode < 2; ++mode) {
        const uint32_t spectral_meta[] = {2, 2, mode};
        if (!gpu->dispatch("spk_spectral_epilogue",
                           {spk::gpu::Arg::buf(spectral_input_buffer),
                            spk::gpu::Arg::buf(spectral_characteristic_buffer),
                            spk::gpu::Arg::buf(spectral_base_buffer),
                            spk::gpu::Arg::buf(spectral_integral_buffer),
                            spk::gpu::Arg::buf(spectral_epilogue_buffer),
                            spk::gpu::Arg::inline_bytes(spectral_meta, 3),
                            spk::gpu::Arg::buf(spectral_output)}, 2, error)) {
            std::fprintf(stderr, "spectral_epilogue: %s\n", error.c_str());
            return 1;
        }
        const float linear_expected[] = {10, 22, 31, 1, 3.1f, 1e-10f};
        std::vector<float> spectral_got_readback;
        if (!read_test_buffer(gpu, spectral_output, spectral_got_readback, error)) return 1;
        const float* spectral_got = spectral_got_readback.data();
        for (size_t i = 0; i < 6; ++i) {
            const float expected = mode == 0 ? std::log10(linear_expected[i])
                                             : linear_expected[i];
            if (std::fabs(spectral_got[i] - expected) > 3e-5f) {
                std::fprintf(stderr, "spectral_epilogue: mode %u value %zu: %g expected %g\n",
                             mode, i, double(spectral_got[i]), double(expected));
                return 1;
            }
        }
    }
    spectral_output.reset(); spectral_epilogue_buffer.reset(); spectral_integral_buffer.reset();
    spectral_base_buffer.reset(); spectral_characteristic_buffer.reset(); spectral_input_buffer.reset();

    const float print_input[] = {0, 0, 0, 1, -1, -2};
    auto print_input_buffer = gpu->upload(print_input, sizeof print_input, error);
    auto print_gain_buffer = gpu->upload(log_gain, sizeof log_gain, error);
    auto print_output = gpu->alloc(sizeof print_input, error);
    if (!print_input_buffer || !print_gain_buffer || !print_output ||
        !gpu->dispatch("spk_print_exposure",
                       {spk::gpu::Arg::buf(print_input_buffer), spk::gpu::Arg::buf(print_gain_buffer),
                        spk::gpu::Arg::inline_bytes(affine_count, 1),
                        spk::gpu::Arg::buf(print_output)}, 6, error)) {
        std::fprintf(stderr, "print_exposure: %s\n", error.c_str());
        return 1;
    }
    const float print_expected[] = {1, 0, 2, 2, -1, 0};
    std::vector<float> print_got_readback;
    if (!read_test_buffer(gpu, print_output, print_got_readback, error)) return 1;
    const float* print_got = print_got_readback.data();
    for (size_t i = 0; i < 6; ++i)
        if (std::fabs(print_got[i] - print_expected[i]) > 2e-5f) {
            std::fprintf(stderr, "print_exposure: wrong value %zu: %g\n", i,
                         double(print_got[i]));
            return 1;
        }
    print_output.reset(); print_gain_buffer.reset(); print_input_buffer.reset();

    // Compare the CAM16 shader with the core's independent float64 forward
    // and inverse functions, once without a knee and once with compression.
    const double white_xyz[] = {1, 1, 1};
    spk::Cam16Setup cam16;
    spk::cam16_setup(white_xyz, spk::kCam16LA, spk::kCam16Yb, cam16);
    double white_jab[3];
    spk::xyz_to_cam16ucs(cam16, white_xyz, white_jab);
    const float cam16_constants[] = {
        float(cam16.F_L), float(cam16.N_bb), float(cam16.N_cb), float(cam16.n),
        float(cam16.z), float(cam16.A_w), float(cam16.c), float(cam16.N_c),
        1, 110, -3.14159265358979323846f, 1.57079632679489661923f,
        0.7f, 1.0f, 2.2f, 0, 1, 1, float(white_jab[0]),
        float(cam16.D_rgb[0]), float(cam16.D_rgb[1]), float(cam16.D_rgb[2])
    };
    const float cam16_identity[] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    const float cam16_input[] = {0.2f, 0.2f, 0.2f, 0.7f, 0.2f, 0.1f};
    const uint32_t cam16_meta[] = {2, 2, 4, 0};
    auto cam16_input_buffer = gpu->upload(cam16_input, sizeof cam16_input, error);
    auto cam16_identity_buffer = gpu->upload(cam16_identity, sizeof cam16_identity, error);
    auto cam16_constants_buffer = gpu->upload(cam16_constants, sizeof cam16_constants, error);
    auto cam16_output = gpu->alloc(sizeof cam16_input, error);
    if (!cam16_input_buffer || !cam16_identity_buffer || !cam16_constants_buffer ||
        !cam16_output) {
        std::fprintf(stderr, "cam16 setup: %s\n", error.c_str());
        return 1;
    }
    for (size_t case_index = 0; case_index < 2; ++case_index) {
        const float cmax_value = case_index == 0 ? 1000.0f : 5.0f;
        const float cmax_table[] = {cmax_value, cmax_value, cmax_value, cmax_value,
                                    cmax_value, cmax_value, cmax_value, cmax_value};
        auto cmax_buffer = gpu->upload(cmax_table, sizeof cmax_table, error);
        if (!cmax_buffer ||
            !gpu->dispatch("spk_cam16ucs_compress",
                           {spk::gpu::Arg::buf(cam16_input_buffer),
                            spk::gpu::Arg::buf(cam16_identity_buffer),
                            spk::gpu::Arg::buf(cam16_identity_buffer),
                            spk::gpu::Arg::buf(cmax_buffer),
                            spk::gpu::Arg::buf(cam16_constants_buffer),
                            spk::gpu::Arg::inline_bytes(cam16_meta, 4),
                            spk::gpu::Arg::buf(cam16_output)}, 2, error)) {
            std::fprintf(stderr, "cam16 dispatch: %s\n", error.c_str());
            return 1;
        }
        std::vector<float> cam16_got_readback;
        if (!read_test_buffer(gpu, cam16_output, cam16_got_readback, error)) return 1;
        const float* cam16_got = cam16_got_readback.data();
        for (size_t pixel = 0; pixel < 2; ++pixel) {
            const double xyz[] = {cam16_input[3 * pixel], cam16_input[3 * pixel + 1],
                                  cam16_input[3 * pixel + 2]};
            double jab[3], expected_xyz[3];
            spk::xyz_to_cam16ucs(cam16, xyz, jab);
            const double chroma = std::hypot(jab[1], jab[2]);
            const double adjusted = spk::reinhard_knee(chroma / double(cmax_value),
                                                       0.7, 1.0, 2.2) * double(cmax_value);
            if (case_index == 1 && pixel == 1 && !(adjusted < chroma - 1.0)) {
                std::fprintf(stderr, "cam16 fixture did not enter the compression knee\n");
                return 1;
            }
            if (chroma > 0.0) {
                jab[1] *= adjusted / chroma;
                jab[2] *= adjusted / chroma;
            }
            spk::cam16ucs_to_xyz(cam16, jab, expected_xyz);
            for (size_t channel = 0; channel < 3; ++channel)
                if (!std::isfinite(cam16_got[3 * pixel + channel]) ||
                    std::fabs(cam16_got[3 * pixel + channel] - expected_xyz[channel]) > 5e-4) {
                    std::fprintf(stderr, "cam16 case %zu pixel %zu channel %zu: %g expected %g\n",
                                 case_index, pixel, channel,
                                 double(cam16_got[3 * pixel + channel]), expected_xyz[channel]);
                    return 1;
                }
        }
        cmax_buffer.reset();
    }
    cam16_output.reset(); cam16_constants_buffer.reset(); cam16_identity_buffer.reset();
    cam16_input_buffer.reset();

    const float cctf_input[] = {0.001f, 0.25f, 1.0f, -0.01f, 0.0001f, 0.5f};
    const float cctf_matrix[] = {2, 0, 0, 0, 0.5f, 0, 0, 0, 1};
    auto cctf_input_buffer = gpu->upload(cctf_input, sizeof cctf_input, error);
    auto cctf_matrix_buffer = gpu->upload(cctf_matrix, sizeof cctf_matrix, error);
    auto cctf_output = gpu->alloc(sizeof cctf_input, error);
    if (!cctf_input_buffer || !cctf_matrix_buffer || !cctf_output) {
        std::fprintf(stderr, "cctf setup: %s\n", error.c_str());
        return 1;
    }
    const float channel_scales[] = {2, 0.5f, 1};
    for (uint32_t mode = 0; mode < 2; ++mode) {
        const uint32_t cctf_meta[] = {2, mode};
        if (!gpu->dispatch("spk_cctf_encode_matrix",
                           {spk::gpu::Arg::buf(cctf_input_buffer),
                            spk::gpu::Arg::buf(cctf_matrix_buffer),
                            spk::gpu::Arg::inline_bytes(cctf_meta, 2),
                            spk::gpu::Arg::buf(cctf_output)}, 2, error)) {
            std::fprintf(stderr, "cctf encode: %s\n", error.c_str());
            return 1;
        }
        std::vector<float> cctf_got_readback;
        if (!read_test_buffer(gpu, cctf_output, cctf_got_readback, error)) return 1;
        const float* cctf_got = cctf_got_readback.data();
        for (size_t i = 0; i < 6; ++i) {
            const float value = cctf_input[i] * channel_scales[i % 3];
            const float expected = mode == 0
                ? (value <= 0.0031308f ? 12.92f * value
                   : 1.055f * std::pow(value, 1.0f / 2.4f) - 0.055f)
                : (value < 1.0f / 512.0f ? value * 16.0f
                   : std::pow(value, 1.0f / 1.8f));
            if (std::fabs(cctf_got[i] - expected) > 3e-5f) {
                std::fprintf(stderr, "cctf mode %u value %zu: %g expected %g\n", mode, i,
                             double(cctf_got[i]), double(expected));
                return 1;
            }
        }
    }
    cctf_output.reset(); cctf_matrix_buffer.reset(); cctf_input_buffer.reset();

    const float pack_input[] = {0, 0.5f, 1, 1.5f, -1, 0.25f,
                                0.1f, 0.2f, 0.3f, 0.7f, 0.8f, 0.9f};
    const uint32_t pack_meta[] = {4, 2, 3};
    auto pack_input_buffer = gpu->upload(pack_input, sizeof pack_input, error);
    auto pack_output = gpu->alloc(3 * 2 * 4 * sizeof(uint16_t), error);
    if (!pack_input_buffer || !pack_output ||
        !gpu->dispatch("spk_to_rgba16",
                       {spk::gpu::Arg::buf(pack_input_buffer),
                        spk::gpu::Arg::inline_bytes(pack_meta, 3),
                        spk::gpu::Arg::buf(pack_output)}, 4, error)) {
        std::fprintf(stderr, "to_rgba16: %s\n", error.c_str());
        return 1;
    }
    std::vector<uint16_t> packed_readback;
    if (!read_test_buffer(gpu, pack_output, packed_readback, error)) return 1;
    const uint16_t* packed = packed_readback.data();
    const uint16_t pack_first[] = {0, 32768, 65535, 65535, 65535, 0, 16384, 65535};
    for (size_t i = 0; i < 8; ++i)
        if (packed[i] != pack_first[i]) {
            std::fprintf(stderr, "to_rgba16: first row value %zu: %u expected %u\n", i,
                         unsigned(packed[i]), unsigned(pack_first[i]));
            return 1;
        }
    if (packed[3 * 4 + 3] != 65535 || packed[4 * 4 + 3] != 65535 ||
        packed[3 * 4] == 0 || packed[4 * 4] <= packed[3 * 4]) {
        std::fprintf(stderr, "to_rgba16: wrong second row or stride\n");
        return 1;
    }
    pack_output.reset(); pack_input_buffer.reset();

    transformed.reset(); m.reset(); rgb.reset(); input.reset();
    if (gpu->pool_stats().free_bytes == 0 || gpu->trim_pool(0) == 0 ||
        gpu->pool_stats().total_bytes != 0) {
        std::fprintf(stderr, "Vulkan buffer pool did not release idle buffers\n");
        delete gpu;
        return 1;
    }
    delete gpu;

    spk_engine* engine = spk_engine_create(resources.c_str(), nullptr);
    if (!engine) { std::fprintf(stderr, "engine create: %s\n", spk_last_error(nullptr)); return 1; }
    const char* capabilities = spk_capabilities(engine);
    if (!std::strstr(capabilities, "native-vulkan")) {
        std::fprintf(stderr, "engine capabilities: %s\n", capabilities);
        spk_engine_destroy(engine);
        return 1;
    }
    spk_image image{rgba, 2, 1, 4};
    char* reply = nullptr;
    spk_session* session = spk_open(engine, &image, nullptr, &reply);
    if (!session) {
        std::fprintf(stderr, "engine open: %s\n", spk_last_error(engine));
        spk_engine_destroy(engine);
        return 1;
    }
    std::printf("headless engine/session: ok\n");
    spk_result result{};
    const spk_status render_status = spk_render(session, "full", &result);
    if (render_status != SPK_OK || !result.rgba16 || result.width != 2 || result.height != 1) {
        std::fprintf(stderr, "default render failed: %d, %s\n",
                     int(render_status), spk_last_error(engine));
        spk_result_free(&result);
        spk_string_free(reply);
        spk_session_release(session);
        spk_engine_destroy(engine);
        return 1;
    }
    for (size_t pixel = 0; pixel < 2; ++pixel) {
        if (result.rgba16[4 * pixel + 3] != 65535) {
            std::fprintf(stderr, "default render alpha is wrong\n");
            return 1;
        }
    }
    std::printf("headless default render: grain and glare enabled, 2x1 RGBA16\n");
    spk_result_free(&result);
    spk_string_free(reply);
    spk_session_release(session);

    // The reference parity harness uses this deterministic baseline. It
    // isolates the physical film/print path from the stochastic grain port.
    constexpr const char* kParityDelta =
        "{\"grain_active\":false,\"glare_active\":false,\"auto_exposure\":false}";
    const float parity_pixels[] = {
        0.05f, 0.10f, 0.20f, 1, 0.18f, 0.18f, 0.18f, 1,
        0.50f, 0.30f, 0.10f, 1, 0.80f, 0.80f, 0.80f, 1
    };
    const spk_image parity_image{parity_pixels, 2, 2, 4};
    spk_session* parity_session = spk_open(engine, &parity_image, kParityDelta, nullptr);
    if (!parity_session) {
        std::fprintf(stderr, "parity session: %s\n", spk_last_error(engine));
        spk_engine_destroy(engine);
        return 1;
    }
    spk_result parity_result{};
    const spk_status parity_status = spk_render(parity_session, "full", &parity_result);
    if (parity_status != SPK_OK || !parity_result.texture || !parity_result.rgba16 ||
        parity_result.width != 2 || parity_result.height != 2 ||
        parity_result.row_stride_px != 2) {
        std::fprintf(stderr, "headless parity-path render: %d, %s\n", int(parity_status),
                     spk_last_error(engine));
        spk_result_free(&parity_result);
        spk_session_release(parity_session);
        spk_engine_destroy(engine);
        return 1;
    }
    uint16_t first_pixels[16];
    std::memcpy(first_pixels, parity_result.rgba16, sizeof first_pixels);
    bool varied = false;
    for (size_t pixel = 0; pixel < 4; ++pixel) {
        if (first_pixels[4 * pixel + 3] != 65535) {
            std::fprintf(stderr, "headless result alpha is wrong\n");
            return 1;
        }
        if (pixel > 0)
            for (size_t channel = 0; channel < 3; ++channel)
                varied |= first_pixels[4 * pixel + channel] != first_pixels[channel];
    }
    if (!varied) {
        std::fprintf(stderr, "headless result has no pixel variation\n");
        return 1;
    }
    spk_result second_result{};
    if (spk_render(parity_session, "full", &second_result) != SPK_OK ||
        !second_result.rgba16 ||
        std::memcmp(second_result.rgba16, first_pixels, sizeof first_pixels) != 0) {
        std::fprintf(stderr, "deterministic second render differs: %s\n", spk_last_error(engine));
        spk_result_free(&second_result);
        spk_result_free(&parity_result);
        spk_session_release(parity_session);
        spk_engine_destroy(engine);
        return 1;
    }
    std::printf("headless deterministic image: 2x2 RGBA16, first RGB = %u,%u,%u\n",
                unsigned(first_pixels[0]), unsigned(first_pixels[1]), unsigned(first_pixels[2]));
    spk_session_release(parity_session);
    spk_engine_destroy(engine);
    // Results must own their pixels after their session and device are gone.
    if (std::memcmp(parity_result.rgba16, first_pixels, sizeof first_pixels) != 0) {
        std::fprintf(stderr, "result pixels did not outlive the engine\n");
        return 1;
    }
    spk_result_free(&second_result);
    spk_result_free(&parity_result);
    if (parity_result.rgba16 || parity_result.texture) {
        std::fprintf(stderr, "result release did not clear ownership\n");
        return 1;
    }
    return 0;
}
