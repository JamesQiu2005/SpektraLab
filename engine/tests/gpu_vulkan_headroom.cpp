// Independent headless probe for Vulkan highlight headroom compression kernel.
// Validates spk_highlight_headroom against an independent float64 reference.
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
constexpr size_t kGuardCount = 16;
constexpr double kTolerance = 1e-5;

void headroom_reference(const std::vector<float>& in, const float p[7], size_t n, std::vector<double>& expected) {
    expected.resize(n * 3);
    auto smoothstep01 = [](double t) {
        t = std::clamp(t, 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    };
    for (size_t i = 0; i < n; ++i) {
        double vx = double(in[3 * i]);
        double vy = double(in[3 * i + 1]);
        double vz = double(in[3 * i + 2]);
        double m = std::max(vx, std::max(vy, vz));
        double g = 1.0;
        if (m > 0.0) {
            double lm = std::log2(m);
            double near_clip = smoothstep01((lm + std::log2(double(p[0])) - double(p[1])) * double(p[2]));
            double over_floor = smoothstep01((lm + std::log2(double(p[4])) - double(p[5])) * double(p[6]));
            g = std::exp2(double(p[3]) * near_clip * over_floor);
        }
        expected[3 * i] = vx * g;
        expected[3 * i + 1] = vy * g;
        expected[3 * i + 2] = vz * g;
    }
}

bool check_case(Gpu* gpu, const std::string& case_name, const float p[7],
                const std::vector<float>& input, size_t n, double& max_error,
                std::string& error) {
    auto p_buf = gpu->upload(p, 7 * sizeof(float), error);
    if (!p_buf) return false;
    auto in_buf = gpu->upload(input.data(), input.size() * sizeof(float), error);
    if (!in_buf) return false;

    const size_t output_elements = n * 3;
    std::vector<float> guarded_output(output_elements + kGuardCount, kGuard);
    auto out_buf = gpu->upload(guarded_output.data(), guarded_output.size() * sizeof(float), error);
    if (!out_buf) return false;

    const uint32_t count_arg[1] = {uint32_t(n)};
    if (!gpu->dispatch("spk_highlight_headroom",
                       {Arg::buf(in_buf), Arg::buf(p_buf),
                        Arg::inline_bytes(count_arg, 1), Arg::buf(out_buf)},
                       std::max(n, size_t(1)), error)) {
        return false;
    }
    if (!gpu->flush(error)) return false;

    std::vector<float> actual;
    if (!read_test_buffer(gpu, out_buf, actual, error)) return false;

    std::vector<double> expected;
    headroom_reference(input, p, n, expected);

    for (size_t i = 0; i < expected.size(); ++i) {
        const double delta = std::abs(double(actual[i]) - expected[i]);
        const double tolerance = kTolerance * std::max(1.0, std::abs(expected[i]));
        max_error = std::max(max_error, delta);
        if (!std::isfinite(actual[i]) || delta > tolerance) {
            char detail[320];
            std::snprintf(detail, sizeof detail,
                          "%s: index=%zu got=%.9g expected=%.12g delta=%.9g tolerance=%.9g",
                          case_name.c_str(), i, double(actual[i]), expected[i], delta, tolerance);
            error = detail;
            return false;
        }
    }

    // Vulkan buffer 按 512B 对齐放大，只检查实际上传的 guard 窗口
    for (size_t i = output_elements; i < actual.size() && i < output_elements + kGuardCount; ++i) {
        if (actual[i] != kGuard) {
            error = case_name + ": kernel wrote beyond allocated count";
            return false;
        }
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: spk_vulkan_headroom <resources>\n");
        return 2;
    }

    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) {
        std::fprintf(stderr, "Vulkan device: %s\n", error.c_str());
        return 1;
    }
    std::printf("Vulkan headroom device: %s\n", gpu->device_name().c_str());

    constexpr double kHeadroomClipFromEv = -1.0;
    constexpr double kHeadroomClipToEv = -0.25;
    constexpr double kMidgray = 0.184;
    const double clip = 4.0;
    const double headroom_ev = 1.5;
    const double headroom_from_ev = 0.5;
    const double headroom_to_ev = 2.0;

    const float p[7] = {
        float(1.0 / clip),
        float(kHeadroomClipFromEv),
        float(1.0 / (kHeadroomClipToEv - kHeadroomClipFromEv)),
        float(headroom_ev),
        float(1.0 / kMidgray),
        float(headroom_from_ev),
        float(1.0 / (headroom_to_ev - headroom_from_ev))
    };

    double max_error = 0.0;
    size_t passed = 0;

    // Test across several sizes: single element, boundary workgroup, and large size
    const size_t pixel_counts[] = {1, 13, 128, 256, 1025};
    for (size_t n : pixel_counts) {
        std::vector<float> input(n * 3);
        for (size_t i = 0; i < n; ++i) {
            // Sweep through shadow, midtone, highlight and near-clip/over-clip values
            const double s = double(i) / double(std::max(n - 1, size_t(1)));
            const double val = -0.2 + 5.0 * s;
            input[3 * i] = float(val);
            input[3 * i + 1] = float(val * 0.8 + 0.1);
            input[3 * i + 2] = float(val * 1.1 - 0.05);
        }

        if (!check_case(gpu.get(), "headroom-n" + std::to_string(n), p, input, n, max_error, error)) {
            std::fprintf(stderr, "headroom gate failed: %s\n", error.c_str());
            return 1;
        }
        ++passed;
    }

    // Edge case: zero and negative inputs (boundary handling m <= 0)
    {
        const size_t n = 8;
        std::vector<float> edge_input(n * 3, 0.0f);
        edge_input[0] = -1.0f; edge_input[1] = -0.5f; edge_input[2] = 0.0f;
        edge_input[3] = 0.0f;  edge_input[4] = 0.0f;  edge_input[5] = 0.0f;
        edge_input[6] = 0.184f; // exactly midgray
        edge_input[9] = 4.0f;   // exactly clip
        if (!check_case(gpu.get(), "headroom-edge", p, edge_input, n, max_error, error)) {
            std::fprintf(stderr, "headroom edge case failed: %s\n", error.c_str());
            return 1;
        }
        ++passed;
    }

    std::printf("headroom: %zu GPU cases passed; float64 headroom compression reference; max delta %.9g\n",
                passed, max_error);
    return 0;
}
