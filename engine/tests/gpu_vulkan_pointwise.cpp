// Independent headless checks for the Windows pointwise ports. Guard values
// exercise the rounded-up final workgroup, not just the visible image plane.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;
constexpr float kGuard = -12345.25f;
constexpr size_t kGuardCount = 11;
size_t cases = 0;
double maximum_error = 0;
double maximum_scaled_error = 0;

BufferRef output_buffer(Gpu* gpu, size_t count, std::string& error) {
    const std::vector<float> guarded(count + kGuardCount, kGuard);
    return gpu->upload(guarded.data(), guarded.size() * sizeof(float), error);
}

bool check_values(Gpu* gpu, const BufferRef& output, const std::vector<double>& expected,
                  const char* name, double absolute_tolerance, double relative_tolerance,
                  std::string& error) {
    if (!gpu->flush(error)) return false;
    std::vector<float> actual_readback;
    if (!read_test_buffer(gpu, output, actual_readback, error)) return false;
    const float* actual = actual_readback.data();
    for (size_t i = 0; i < expected.size(); ++i) {
        const double delta = std::fabs(double(actual[i]) - expected[i]);
        const double tolerance = absolute_tolerance + relative_tolerance * std::fabs(expected[i]);
        const bool ok = std::isnan(expected[i]) ? std::isnan(actual[i])
                      : std::isinf(expected[i]) ? double(actual[i]) == expected[i]
                      : std::isfinite(actual[i]) && delta <= tolerance;
        if (!ok) {
            char detail[320];
            std::snprintf(detail, sizeof detail,
                "%s case=%zu index=%zu got=%.9g expected=%.17g delta=%.9g tolerance=%.9g",
                name, cases, i, double(actual[i]), expected[i], delta, tolerance);
            error = detail;
            return false;
        }
        if (std::isfinite(delta)) {
            maximum_error = std::max(maximum_error, delta);
            maximum_scaled_error = std::max(maximum_scaled_error,
                                            delta / std::max(1.0, std::fabs(expected[i])));
        }
    }
    for (size_t i = expected.size(); i < expected.size() + kGuardCount; ++i) {
        if (actual[i] != kGuard) {
            error = std::string(name) + " wrote past its logical output count";
            return false;
        }
    }
    ++cases;
    return true;
}

bool check_mul_glare_boost(Gpu* gpu, std::string& error) {
    const uint32_t counts[] = {0, 1, 2, 255, 256, 257, 1025};
    const float illuminant[] = {0.96422f, 1.0f, 0.82521f};
    const float boost[] = {0.25f, 0.125f, 3.0f, 2.0f};
    auto illuminant_buffer = gpu->upload(illuminant, sizeof illuminant, error);
    auto boost_buffer = gpu->upload(boost, sizeof boost, error);
    if (!illuminant_buffer || !boost_buffer) return false;
    for (uint32_t count : counts) {
        std::vector<float> x(std::max(count, 1u)), y(x.size());
        for (uint32_t i = 0; i < x.size(); ++i) {
            x[i] = float(int(i % 37) - 9) / 8.0f;
            y[i] = float(int(i % 11) - 5) / 16.0f;
        }
        if (count > 1) {
            x[0] = boost[0];  // exact protection threshold must pass through
            x[1] = std::nextafter(boost[0], std::numeric_limits<float>::infinity());
        }
        auto input = gpu->upload(x.data(), x.size() * sizeof(float), error);
        auto field = gpu->upload(y.data(), y.size() * sizeof(float), error);
        auto output = output_buffer(gpu, count, error);
        if (!input || !field || !output) return false;
        const uint32_t n[] = {count};
        std::vector<double> expected(count);
        for (uint32_t i = 0; i < count; ++i) expected[i] = double(x[i]) * y[i];
        if (!gpu->dispatch("spk_mul", {Arg::buf(input), Arg::buf(field),
                           Arg::inline_bytes(n, 1), Arg::buf(output)},
                           std::max(count, 1u), error) ||
            !check_values(gpu, output, expected, "mul", 0, 0, error)) return false;

        output = output_buffer(gpu, count, error);
        for (uint32_t i = 0; i < count; ++i)
            expected[i] = double(x[i]) + double(y[i]) / 100.0 * illuminant[i % 3];
        if (!output || !gpu->dispatch("spk_glare_add", {Arg::buf(input), Arg::buf(field),
                           Arg::buf(illuminant_buffer), Arg::inline_bytes(n, 1), Arg::buf(output)},
                           std::max(count, 1u), error) ||
            !check_values(gpu, output, expected, "glare_add", 2e-7, 2e-7, error)) return false;

        output = output_buffer(gpu, count, error);
        for (uint32_t i = 0; i < count; ++i) {
            const double dx = (double(x[i]) - boost[0]) * boost[1];
            expected[i] = x[i] <= boost[0] ? double(x[i])
                : double(x[i]) + double(boost[3]) * (std::expm1(double(boost[2]) * dx) - double(boost[2]) * dx);
        }
        if (!output || !gpu->dispatch("spk_boost", {Arg::buf(input), Arg::buf(boost_buffer),
                           Arg::inline_bytes(n, 1), Arg::buf(output)},
                           std::max(count, 1u), error) ||
            !check_values(gpu, output, expected, "boost", 6e-7, 4e-7, error)) return false;
        std::vector<float> actual_readback;
        if (!read_test_buffer(gpu, output, actual_readback, error)) return false;
        const float* actual = actual_readback.data();
        for (uint32_t i = 0; i < count; ++i) {
            if (x[i] <= boost[0] && actual[i] != x[i]) {
                error = "boost changed a protected value";
                return false;
            }
        }
    }
    // Elementwise independence permits the pipeline to alias input/output.
    // Keep a guarded tail on this plane to exercise that path independently.
    const uint32_t alias_count = 257;
    std::vector<float> alias_values(alias_count + kGuardCount, kGuard);
    std::vector<float> alias_field(alias_count);
    std::vector<double> alias_expected(alias_count);
    for (uint32_t i = 0; i < alias_count; ++i) {
        alias_values[i] = float(int(i % 13) - 6) * 0.125f;
        alias_field[i] = float(int(i % 7) - 3) * 0.25f;
        alias_expected[i] = double(alias_values[i]) * alias_field[i];
    }
    auto alias_input = gpu->upload(alias_values.data(), alias_values.size() * sizeof(float), error);
    auto alias_field_buffer = gpu->upload(alias_field.data(), alias_field.size() * sizeof(float), error);
    const uint32_t alias_n[] = {alias_count};
    if (!alias_input || !alias_field_buffer ||
        !gpu->dispatch("spk_mul", {Arg::buf(alias_input), Arg::buf(alias_field_buffer),
                           Arg::inline_bytes(alias_n, 1), Arg::buf(alias_input)}, alias_count, error) ||
        !check_values(gpu, alias_input, alias_expected, "mul alias", 0, 0, error)) return false;
    return true;
}

bool check_reduce(Gpu* gpu, std::string& error) {
    const uint32_t counts[] = {0, 1, 255, 256, 257, 65537, 131083};
    const uint32_t groups[] = {1, 3, 256};
    for (uint32_t group_count : groups)
        for (uint32_t count : counts)
            for (uint32_t pattern = 0; pattern < 2; ++pattern) {
                std::vector<float> x(std::max(count, 1u));
                for (uint32_t i = 0; i < x.size(); ++i)
                    x[i] = pattern == 0 ? -float(1 + i % 8191) : float(int(i % 8191) - 4095);
                if (pattern == 1 && count > 0) x[count - 1] = std::numeric_limits<float>::infinity();
                auto input = gpu->upload(x.data(), x.size() * sizeof(float), error);
                auto output = output_buffer(gpu, group_count, error);
                if (!input || !output) return false;
                const uint32_t n[] = {count};
                std::vector<double> expected(group_count, -std::numeric_limits<double>::infinity());
                // The group assigned to a sample is analytic; no reduction
                // tree or GPU max primitive is copied into this reference.
                for (uint32_t i = 0; i < count; ++i) {
                    const uint32_t group = (i % (group_count * 256)) / 256;
                    expected[group] = std::max(expected[group], double(x[i]));
                }
                if (!gpu->dispatch("spk_reduce_max", {Arg::buf(input), Arg::inline_bytes(n, 1),
                                   Arg::buf(output)}, size_t(group_count) * 256, error) ||
                    !check_values(gpu, output, expected, "reduce_max", 0, 0, error)) return false;
            }
    return true;
}

bool check_bw(Gpu* gpu, std::string& error) {
    const uint32_t counts[] = {0, 1, 255, 256, 257};
    const float p[][2] = {{1.0f, 0.0f}, {1.5f, -0.1f}, {0.75f, 0.05f}};
    const float luminance[] = {-0.5f, -1e-10f, 0.0f, 1e-10f, 0.01f, 0.06666667f, 0.18f, 0.5f, 0.9f, 1.0f, 2.0f};
    for (const auto& parameters : p)
        for (uint32_t count : counts) {
            std::vector<float> xyz(std::max(count, 1u) * 3);
            std::vector<double> expected(size_t(count) * 3);
            for (uint32_t i = 0; i < std::max(count, 1u); ++i) {
                const float y = luminance[i % 11];
                xyz[3 * i] = 0.75f * y; xyz[3 * i + 1] = y; xyz[3 * i + 2] = 1.25f * y;
                if (i >= count) continue;
                const double corrected = std::clamp(double(parameters[0]) * y + parameters[1], 0.0, 1.0);
                const double scale = corrected / (double(y) + double(1e-10f));
                for (uint32_t ch = 0; ch < 3; ++ch) expected[3 * i + ch] = double(xyz[3 * i + ch]) * scale;
            }
            auto input = gpu->upload(xyz.data(), xyz.size() * sizeof(float), error);
            auto parameters_buffer = gpu->upload(parameters, sizeof parameters, error);
            auto output = output_buffer(gpu, size_t(count) * 3, error);
            const uint32_t n[] = {count};
            if (!input || !parameters_buffer || !output ||
                !gpu->dispatch("spk_bw_correct", {Arg::buf(input), Arg::buf(parameters_buffer),
                                   Arg::inline_bytes(n, 1), Arg::buf(output)}, std::max(count, 1u), error) ||
                !check_values(gpu, output, expected, "bw_correct", 2e-7, 4e-7, error)) return false;
        }
    return true;
}

bool check_edr(Gpu* gpu, std::string& error) {
    const uint32_t counts[] = {0, 1, 255, 256, 257};
    // Neutral input with Y=G makes exact joins independent of dot-product
    // rounding. LUT entries are samples of an analytic affine log-Y curve.
    const float y_values[] = {-1, 0, 1e-10f, 1.0f / 256, 0.03125f,
                             std::nextafter(0.125f, 0.0f), 0.125f, 0.18f,
                             0.5f, std::nextafter(0.5f, 1.0f), 1, 4, 16};
    const uint32_t lut_counts[] = {1, 2, 17};
    for (uint32_t lut_count : lut_counts)
        for (uint32_t count : counts) {
            const float p[] = {0, 1, 0, -8, 0.1f, 0.125f, 0.5f, float(lut_count)};
            const uint32_t effective_lut_count = std::max(lut_count, 2u);
            std::vector<float> lut(effective_lut_count), rgb(std::max(count, 1u) * 3);
            for (uint32_t i = 0; i < effective_lut_count; ++i)
                lut[i] = -7.0f + 0.75f * (10.0f * float(i) / float(effective_lut_count - 1));
            std::vector<double> expected(size_t(count) * 3);
            for (uint32_t i = 0; i < std::max(count, 1u); ++i) {
                const float raw = y_values[i % 13];
                rgb[3 * i] = 0.5f * raw; rgb[3 * i + 1] = raw; rgb[3 * i + 2] = 1.5f * raw;
                if (i >= count) continue;
                const double y = std::max(double(raw), 0.0);
                double mapped = y;
                if (y > 0 && (y < p[5] || y > p[6])) {
                    const double log_y = std::clamp(std::log2(y), -8.0, 2.0);
                    mapped = std::exp2(-7.0 + 0.75 * (log_y + 8.0));
                }
                const double scale = mapped / (y + double(1e-10f));
                for (uint32_t ch = 0; ch < 3; ++ch)
                    expected[3 * i + ch] = double(rgb[3 * i + ch]) * scale;
            }
            auto input = gpu->upload(rgb.data(), rgb.size() * sizeof(float), error);
            auto parameters = gpu->upload(p, sizeof p, error);
            auto lut_buffer = gpu->upload(lut.data(), lut.size() * sizeof(float), error);
            auto output = output_buffer(gpu, size_t(count) * 3, error);
            const uint32_t n[] = {count};
            if (!input || !parameters || !lut_buffer || !output ||
                !gpu->dispatch("spk_edr", {Arg::buf(input), Arg::buf(parameters), Arg::buf(lut_buffer),
                                   Arg::inline_bytes(n, 1), Arg::buf(output)}, std::max(count, 1u), error) ||
                !check_values(gpu, output, expected, "edr", 5e-7, 8e-7, error)) return false;
        }
    return true;
}

double reference_decode(float value, uint32_t mode, float bt_breakpoint) {
    const double v = value;
    if (mode == 0) return value <= 0.040449936f ? v / double(12.92f)
                        : std::pow((v + double(0.055f)) / double(1.055f), double(2.4f));
    if (mode == 1) return value < 0.03125f ? v / 16 : std::pow(v, double(1.8f));
    if (mode == 2) return v < 0 ? std::numeric_limits<double>::quiet_NaN()
                              : std::pow(v, double(563.0f / 256.0f));
    if (mode == 3) return value < bt_breakpoint ? v / 4.5
                        : std::pow((v + double(1.099f - 1.0f)) / double(1.099f), double(1.0f / 0.45f));
    return v;
}

bool check_decode(Gpu* gpu, std::string& error) {
    const float bt_breakpoint = 1.099f * std::pow(0.018f, 0.45f) - (1.099f - 1.0f);
    const float srgb_breakpoint = 0.040449936f;
    const std::vector<float> samples = {-0.25f, -0.0f, 0, 1e-10f, 1.0f / 512,
        std::nextafter(0.03125f, 0.0f), 0.03125f, std::nextafter(0.03125f, 1.0f),
        std::nextafter(srgb_breakpoint, 0.0f), srgb_breakpoint,
        std::nextafter(srgb_breakpoint, 1.0f), 0.04045f, 0.081f,
        std::nextafter(bt_breakpoint, 0.0f), bt_breakpoint,
        std::nextafter(bt_breakpoint, 1.0f), 0.18f, 0.5f, 1, 2, 8};
    const uint32_t counts[] = {0, 1, 255, 256, 257, 1025};
    for (uint32_t mode = 0; mode < 6; ++mode)
        for (uint32_t count : counts) {
            std::vector<float> input(std::max(count, 1u));
            std::vector<double> expected(count);
            for (uint32_t i = 0; i < input.size(); ++i) input[i] = samples[i % samples.size()];
            for (uint32_t i = 0; i < count; ++i) expected[i] = reference_decode(input[i], mode, bt_breakpoint);
            auto input_buffer = gpu->upload(input.data(), input.size() * sizeof(float), error);
            auto output = output_buffer(gpu, count, error);
            const uint32_t meta[] = {count, mode};
            if (!input_buffer || !output ||
                !gpu->dispatch("spk_cctf_decode", {Arg::buf(input_buffer), Arg::inline_bytes(meta, 2),
                                   Arg::buf(output)}, std::max(count, 1u), error) ||
                !check_values(gpu, output, expected, "cctf_decode", 1e-7, 7e-7, error)) return false;
        }
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_pointwise <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    if (!check_mul_glare_boost(gpu.get(), error) || !check_reduce(gpu.get(), error) ||
        !check_bw(gpu.get(), error) || !check_edr(gpu.get(), error) || !check_decode(gpu.get(), error)) {
        std::fprintf(stderr, "pointwise: %s\n", error.c_str()); return 1;
    }
    std::printf("pointwise: %zu analytic/float64 cases, max abs error %.9g, "
                "max error/max(1,abs(reference)) %.9g, all guards intact\n",
                cases, maximum_error, maximum_scaled_error);
    return 0;
}
