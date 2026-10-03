// Stock-LUT/DI gates: analytic multi-affine tables, an independent eight-corner
// float64 reference, channel-asymmetric axes, exceptional inputs and guards.
// This is local kernel validation, not a claim of whole-frame Metal parity.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::Gpu;
constexpr float kGuard = -654321.0f;
constexpr size_t kGuards = 19;
size_t cases = 0;
double largest_error = 0;

double normalised(float value, float lower, float inverse_span) {
    // Independent float64 arithmetic. Metal precise clamp is fmin(fmax(x,0),1),
    // including NaN -> 0; C++ fmin/fmax specify the same non-NaN preference.
    const double x = (double(value) - double(lower)) * double(inverse_span);
    return std::fmin(std::fmax(x, 0.0), 1.0);
}

double analytic(unsigned channel, const std::array<double, 3>& p, unsigned pattern) {
    const double x = p[0], y = p[1], z = p[2];
    if (pattern == 0) return p[channel];
    if (channel == 0) return -0.125 + 0.25*x + 0.5*y + 0.75*z + 0.125*x*y + 0.25*y*z;
    if (channel == 1) return 0.375 - 0.5*x + 0.125*y + 0.25*z + 0.5*x*z - 0.25*x*y*z;
    return -0.25 + 0.125*x + 0.75*y - 0.5*z + 0.375*x*y + 0.25*x*y*z;
}

std::vector<float> make_table(uint32_t size, unsigned pattern) {
    std::vector<float> table;
    table.reserve(size_t(size) * size * size * 3);
    // Deliberately append nested axes instead of reusing the shader's offsets.
    for (uint32_t x = 0; x < size; ++x)
        for (uint32_t y = 0; y < size; ++y)
            for (uint32_t z = 0; z < size; ++z)
                for (unsigned channel = 0; channel < 3; ++channel) {
                    if (pattern < 2) {
                        table.push_back(float(analytic(channel, {double(x)/(size-1),
                            double(y)/(size-1), double(z)/(size-1)}, pattern)));
                    } else {
                        // Nonlinear asymmetric cells expose wrong corner choices;
                        // a globally affine/identity table alone cannot do that.
                        const uint32_t bits = (x * 73856093u) ^ (y * 19349663u) ^
                                              (z * 83492791u) ^ ((channel + 1u) * 2654435761u);
                        table.push_back(float(int(bits % 4093u) - 1300) / 1024.0f);
                    }
                }
    return table;
}

double corner_reference(const std::vector<float>& table, uint32_t size,
                        const std::array<double, 3>& p, unsigned channel) {
    std::array<uint32_t, 3> low, high;
    std::array<double, 3> fraction;
    for (unsigned axis = 0; axis < 3; ++axis) {
        const double coordinate = p[axis] * (size - 1);
        low[axis] = uint32_t(std::floor(coordinate));
        high[axis] = std::min(low[axis] + 1, size - 1);
        fraction[axis] = coordinate - low[axis];
    }
    const size_t strides[3] = {size_t(size) * size * 3, size_t(size) * 3, 3};
    double value = 0;
    // Sum the eight independently weighted corners in float64, rather than
    // copying the GPU's nested z/y/x interpolation expression.
    for (unsigned corner = 0; corner < 8; ++corner) {
        size_t offset = channel;
        double weight = 1;
        for (unsigned axis = 0; axis < 3; ++axis) {
            const bool upper = (corner & (1u << axis)) != 0;
            offset += (upper ? high[axis] : low[axis]) * strides[axis];
            weight *= upper ? fraction[axis] : 1 - fraction[axis];
        }
        value += weight * table[offset];
    }
    return value;
}

bool check_result(Gpu* gpu, const spk::gpu::BufferRef& output,
                  const std::vector<double>& expected, double tolerance,
                  const std::string& label, std::string& error) {
    std::vector<float> actual;
    if (!read_test_buffer(gpu, output, actual, error)) return false;
    for (size_t i = 0; i < expected.size(); ++i) {
        const double delta = std::abs(double(actual[i]) - expected[i]);
        largest_error = std::max(largest_error, delta);
        if (!std::isfinite(actual[i]) || delta > tolerance * std::max(1.0, std::abs(expected[i]))) {
            char detail[256];
            std::snprintf(detail, sizeof detail, " index=%zu got=%.9g expected=%.17g error=%.9g bar=%.9g",
                          i, double(actual[i]), expected[i], delta, tolerance);
            error = label + detail;
            return false;
        }
    }
    for (size_t i = expected.size(); i < expected.size() + kGuards; ++i)
        if (actual[i] != kGuard) { error = label + " wrote outside the logical output"; return false; }
    ++cases;
    return true;
}

bool check_lut(Gpu* gpu, std::string& error) {
    const float lower[3] = {-0.75f, 0.125f, 3.0f};
    const float inverse[3] = {0.5f, 2.0f, 0.25f};
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    const uint32_t sizes[] = {2, 3, 5, 33};
    const uint32_t counts[] = {0, 1, 255, 256, 257, 1025};
    const double positions[] = {-0.5, 0, 0.125, 0.2, 1.0/3, 0.5, 0.7, 0.875, 1, 1.5};
    for (uint32_t size : sizes) for (unsigned pattern = 0; pattern < 3; ++pattern) {
        const auto table = make_table(size, pattern);
        auto lut = gpu->upload(table.data(), table.size() * sizeof(float), error);
        if (!lut) return false;
        for (uint32_t count : counts) {
            std::vector<float> input(size_t(std::max(count, 1u)) * 3);
            std::vector<double> expected(size_t(count) * 3);
            for (uint32_t i = 0; i < std::max(count, 1u); ++i) {
                std::array<double, 3> p;
                for (unsigned channel = 0; channel < 3; ++channel) {
                    const double q = i < 8 ? double((i >> channel) & 1u) :
                        i < 24 ? double((i * (channel + 1) + channel) % size) / (size - 1) :
                        positions[(i * (2 * channel + 1) + channel * 3) % 10];
                    float value = float(double(lower[channel]) + q / inverse[channel]);
                    if (i >= 24 && i % 29 == 0) value = channel == 0 ? nan : channel == 1 ? inf : -inf;
                    if (i >= 24 && i % 31 == 0) value = std::nextafter(lower[channel], -inf);
                    if (i >= 24 && i % 37 == 0) value = std::nextafter(lower[channel] + 1 / inverse[channel], inf);
                    input[3 * i + channel] = value;
                    p[channel] = normalised(value, lower[channel], inverse[channel]);
                }
                if (i < count) for (unsigned channel = 0; channel < 3; ++channel)
                    expected[3 * i + channel] = pattern < 2 ? analytic(channel, p, pattern)
                        : corner_reference(table, size, p, channel);
            }
            std::vector<float> initial(expected.size() + kGuards, kGuard);
            auto density = gpu->upload(input.data(), input.size() * sizeof(float), error);
            auto output = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
            const uint32_t meta[2] = {count, size};
            if (!density || !output ||
                !gpu->dispatch("spk_lut3d_trilinear", {Arg::buf(density), Arg::buf(lut),
                    Arg::inline_bytes(lower, 3), Arg::inline_bytes(inverse, 3),
                    Arg::inline_bytes(meta, 2), Arg::buf(output)}, std::max(count, 1u), error) ||
                !check_result(gpu, output, expected, pattern < 2 ? 8e-7 : 1.5e-5,
                    "LUT S=" + std::to_string(size) + " pattern=" + std::to_string(pattern) +
                    " pixels=" + std::to_string(count), error)) return false;
        }
    }
    return true;
}

bool check_di(Gpu* gpu, std::string& error) {
    const std::array<float, 3> lowers[] = {{{-0.75f, 0.125f, 3}}, {{-0.1337f, 0.01234f, 1.11f}}, {{0, 0, 0}}};
    const std::array<float, 3> inverses[] = {{{0.5f, 2, 0.25f}}, {{0.17f, 1.3333f, 16.123f}}, {{0, 1, 2}}};
    const uint32_t counts[] = {0, 1, 2, 3, 255, 256, 257, 1025};
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();
    const float positions[] = {-1000, -0.5f, -0.0f, 0, 1e-7f, 0.125f, 0.5f, 0.9999999f, 1, 1.5f, 1000};
    for (unsigned axis_case = 0; axis_case < 3; ++axis_case) for (uint32_t count : counts) {
        const auto& lower = lowers[axis_case];
        const auto& inverse = inverses[axis_case];
        std::vector<float> input(std::max(count, 1u));
        std::vector<double> expected(count);
        for (uint32_t i = 0; i < input.size(); ++i) {
            const unsigned channel = i % 3;
            const float divisor = inverse[channel] == 0 ? 1 : inverse[channel];
            input[i] = lower[channel] + positions[(i / 3) % 11] / divisor;
            if (i % 23 == 0) input[i] = nan;
            else if (i % 23 == 1) input[i] = inf;
            else if (i % 23 == 2) input[i] = -inf;
            else if (i % 23 == 3) input[i] = std::nextafter(lower[channel], -inf);
            else if (i % 23 == 4) input[i] = std::nextafter(lower[channel] + 1 / divisor, inf);
            if (i < count) expected[i] = normalised(input[i], lower[channel], inverse[channel]);
        }
        std::vector<float> initial(expected.size() + kGuards, kGuard);
        auto density = gpu->upload(input.data(), input.size() * sizeof(float), error);
        auto output = gpu->upload(initial.data(), initial.size() * sizeof(float), error);
        const uint32_t meta[1] = {count};
        if (!density || !output ||
            !gpu->dispatch("spk_di_normalise", {Arg::buf(density), Arg::inline_bytes(lower.data(), 3),
                Arg::inline_bytes(inverse.data(), 3), Arg::inline_bytes(meta, 1), Arg::buf(output)},
                std::max(count, 1u), error) ||
            !check_result(gpu, output, expected, 3 * std::numeric_limits<float>::epsilon(),
                "DI axes=" + std::to_string(axis_case) + " elements=" + std::to_string(count), error)) return false;
    }
    return true;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_lut_di <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    if (!check_lut(gpu.get(), error) || !check_di(gpu.get(), error)) {
        std::fprintf(stderr, "LUT/DI: %s\n", error.c_str()); return 1;
    }
    std::printf("LUT/DI: %zu analytic/float64 cases, max abs error %.9g; NaN/Inf and guards passed\n",
                cases, largest_error);
    return 0;
}
