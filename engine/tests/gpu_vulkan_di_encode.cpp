// Independent headless probe for Vulkan Digital Intermediate encode kernel.
// Validates spk_di_encode against an independent float64 reference.
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
constexpr double kTolerance = 3e-5;

double mod360(double x) {
    return x - std::floor(x / 360.0) * 360.0;
}

void di_encode_reference(const std::vector<float>& in, const float* p, size_t n, std::vector<double>& expected) {
    expected.resize(n * 3);
    const double live[3] = {
        std::pow(10.0, double(p[9])),
        std::pow(10.0, double(p[10])),
        std::pow(10.0, double(p[11]))
    };
    const double p40 = double(p[40]);
    const double p41 = double(p[41]);
    const double p37 = double(p[37]);
    const double p38 = double(p[38]);
    const double p39 = double(p[39]);
    const bool comp = (p[30] != 0.0f);

    for (size_t i = 0; i < n; ++i) {
        double y[3] = {double(in[3 * i]), double(in[3 * i + 1]), double(in[3 * i + 2])};
        double pos[3] = {
            std::pow(10.0, y[0] + double(p[9])) - p40 * live[0],
            std::pow(10.0, y[1] + double(p[10])) - p40 * live[1],
            std::pow(10.0, y[2] + double(p[11])) - p40 * live[2]
        };

        double lin[3] = {
            pos[0] * double(p[0]) + pos[1] * double(p[3]) + pos[2] * double(p[6]),
            pos[0] * double(p[1]) + pos[1] * double(p[4]) + pos[2] * double(p[7]),
            pos[0] * double(p[2]) + pos[1] * double(p[5]) + pos[2] * double(p[8])
        };

        if (comp) {
            double lms[3] = {
                double(p[12]) * lin[0] + double(p[13]) * lin[1] + double(p[14]) * lin[2],
                double(p[15]) * lin[0] + double(p[16]) * lin[1] + double(p[17]) * lin[2],
                double(p[18]) * lin[0] + double(p[19]) * lin[1] + double(p[20]) * lin[2]
            };
            lms[0] = std::pow(std::max(lms[0], 0.0), 1.0 / 3.0);
            lms[1] = std::pow(std::max(lms[1], 0.0), 1.0 / 3.0);
            lms[2] = std::pow(std::max(lms[2], 0.0), 1.0 / 3.0);

            double L = 0.2104542553 * lms[0] + 0.7936177850 * lms[1] - 0.0040720468 * lms[2];
            double a = 1.9779984951 * lms[0] - 2.4285922050 * lms[1] + 0.4505937099 * lms[2];
            double b = 0.0259040371 * lms[0] + 0.7827717662 * lms[1] - 0.8086757660 * lms[2];
            double C = std::sqrt(a * a + b * b);
            double h = std::atan2(b, a) * 57.29577951308232;
            double d = mod360(h - double(p[33]) + 540.0) - 180.0;
            double w = std::abs(d) < double(p[34]) ? 0.5 * (1.0 + std::cos(3.14159265358979 * d / double(p[34]))) : 0.0;
            double g = std::clamp((C - double(p[35])) / (double(p[36]) - double(p[35])), 0.0, 1.0);
            w *= g * g * (3.0 - 2.0 * g);
            if (w > 0.0) {
                double h2 = (h + w * double(p[31])) * 0.017453292519943295;
                double C2 = C * (1.0 + w * (double(p[32]) - 1.0));
                a = C2 * std::cos(h2);
                b = C2 * std::sin(h2);
                double l_[3] = {
                    L + 0.3963377774 * a + 0.2158037573 * b,
                    L - 0.1055613458 * a - 0.0638541728 * b,
                    L - 0.0894841775 * a - 1.2914855480 * b
                };
                lms[0] = l_[0] * l_[0] * l_[0];
                lms[1] = l_[1] * l_[1] * l_[1];
                lms[2] = l_[2] * l_[2] * l_[2];
                lin[0] = double(p[21]) * lms[0] + double(p[22]) * lms[1] + double(p[23]) * lms[2];
                lin[1] = double(p[24]) * lms[0] + double(p[25]) * lms[1] + double(p[26]) * lms[2];
                lin[2] = double(p[27]) * lms[0] + double(p[28]) * lms[1] + double(p[29]) * lms[2];
            }
        }

        auto cineon = [&](double v) {
            double arg = std::max(v, 0.0) * (1.0 - p41) + p41;
            double log10_val = std::log(arg) * 0.4342944819032518;
            double code = (p37 + p38 * log10_val) / p39;
            return std::clamp(code, 0.0, 1.0);
        };
        expected[3 * i] = cineon(lin[0]);
        expected[3 * i + 1] = cineon(lin[1]);
        expected[3 * i + 2] = cineon(lin[2]);
    }
}

bool check_case(Gpu* gpu, const std::string& case_name, const float p[42],
                const std::vector<float>& input, size_t n, double& max_error,
                std::string& error) {
    auto p_buf = gpu->upload(p, 42 * sizeof(float), error);
    if (!p_buf) return false;
    auto in_buf = gpu->upload(input.data(), input.size() * sizeof(float), error);
    if (!in_buf) return false;

    const size_t output_elements = n * 3;
    std::vector<float> guarded_output(output_elements + kGuardCount, kGuard);
    auto out_buf = gpu->upload(guarded_output.data(), guarded_output.size() * sizeof(float), error);
    if (!out_buf) return false;

    const uint32_t count_arg[1] = {uint32_t(n)};
    if (!gpu->dispatch("spk_di_encode",
                       {Arg::buf(in_buf), Arg::buf(p_buf),
                        Arg::inline_bytes(count_arg, 1), Arg::buf(out_buf)},
                       std::max(n, size_t(1)), error)) {
        return false;
    }
    if (!gpu->flush(error)) return false;

    std::vector<float> actual;
    if (!read_test_buffer(gpu, out_buf, actual, error)) return false;

    std::vector<double> expected;
    di_encode_reference(input, p, n, expected);

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

    // Vulkan buffer 按 512B 对齐放大，read 回来的 actual 尾部是未初始化垃圾；只检查实际上传的 guard 窗口
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
        std::fprintf(stderr, "usage: spk_vulkan_di_encode <resources>\n");
        return 2;
    }

    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) {
        std::fprintf(stderr, "Vulkan device: %s\n", error.c_str());
        return 1;
    }
    std::printf("Vulkan di_encode device: %s\n", gpu->device_name().c_str());

    // Construct standard parameters (42 floats)
    float p[42] = {};
    // matrix: 3x3 identity
    p[0] = 1.0f; p[1] = 0.0f; p[2] = 0.0f;
    p[3] = 0.0f; p[4] = 1.0f; p[5] = 0.0f;
    p[6] = 0.0f; p[7] = 0.0f; p[8] = 1.0f;
    // live offsets
    p[9] = 0.02f; p[10] = -0.01f; p[11] = 0.03f;
    // to_lms: standard Oklab M1
    p[12] = 0.4122214708f; p[13] = 0.5363325363f; p[14] = 0.0514459929f;
    p[15] = 0.2119034982f; p[16] = 0.6806995451f; p[17] = 0.1073969566f;
    p[18] = 0.0883024619f; p[19] = 0.2817188376f; p[20] = 0.6299787005f;
    // from_lms: standard Oklab M1 inverse
    p[21] = 4.0767416621f; p[22] = -3.3077115913f; p[23] = 0.2309699292f;
    p[24] = -1.2684380046f; p[25] = 2.6097574011f; p[26] = -0.3413193965f;
    p[27] = -0.0041960863f; p[28] = -0.7034186147f; p[29] = 1.7076147010f;
    // comp
    p[30] = 0.0f;  // start with comp off
    p[31] = 15.0f; // blue_delta_deg
    p[32] = 1.25f; // blue_kappa
    p[33] = 280.0f; // kDiBlueHueCentre
    p[34] = 55.0f;  // kDiBlueHueHalfWidth
    p[35] = 0.02f;  // kDiBlueChromaLo
    p[36] = 0.08f;  // kDiBlueChromaHi
    p[37] = 685.0f; // kDiCineonWhite
    p[38] = 300.0f; // kDiCineonPerDecade
    p[39] = 1023.0f;// kDiCineonMax
    p[40] = 0.005f; // positive_floor
    p[41] = float(std::pow(10.0, (95.0 - 685.0) / 300.0)); // black offset

    double max_error = 0.0;
    size_t passed = 0;

    // Test cases: single pixel, small batch, large batch
    const size_t pixel_counts[] = {1, 7, 64, 256, 1025};
    for (size_t n : pixel_counts) {
        std::vector<float> input(n * 3);
        for (size_t i = 0; i < n; ++i) {
            input[3 * i] = float(-1.5 + 2.5 * (double(i % 17) / 16.0));
            input[3 * i + 1] = float(-1.2 + 2.0 * (double((i + 5) % 19) / 18.0));
            input[3 * i + 2] = float(-0.8 + 1.8 * (double((i + 11) % 23) / 22.0));
        }

        // Case A: comp = 0
        p[30] = 0.0f;
        if (!check_case(gpu.get(), "di_encode-nocomp-n" + std::to_string(n), p, input, n, max_error, error)) {
            std::fprintf(stderr, "di_encode gate failed: %s\n", error.c_str());
            return 1;
        }
        ++passed;

        // Case B: comp = 1
        p[30] = 1.0f;
        if (!check_case(gpu.get(), "di_encode-comp-n" + std::to_string(n), p, input, n, max_error, error)) {
            std::fprintf(stderr, "di_encode gate failed: %s\n", error.c_str());
            return 1;
        }
        ++passed;
    }

    std::printf("di_encode: %zu GPU cases passed; float64 Cineon/Oklab reference; max delta %.9g\n",
                passed, max_error);
    return 0;
}
