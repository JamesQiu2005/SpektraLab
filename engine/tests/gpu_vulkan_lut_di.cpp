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

std::array<double, 3> cineon_reference(const float* density, const std::vector<float>& p) {
    std::array<double, 3> positive{}, linear{};
    for (int c = 0; c < 3; ++c)
        positive[c] = std::pow(10.0, double(density[c]) + p[9+c]) - double(p[40]) * std::pow(10.0, p[9+c]);
    for (int c = 0; c < 3; ++c) for (int j = 0; j < 3; ++j) linear[c] += positive[j] * p[3*j+c];
    if (p[30] != 0) {
        std::array<double, 3> lms{};
        for (int c = 0; c < 3; ++c) {
            for (int j = 0; j < 3; ++j) lms[c] += p[12+3*c+j] * linear[j];
            lms[c] = std::cbrt(std::fmax(lms[c], 0.0));
        }
        const double L = 0.2104542553*lms[0] + 0.7936177850*lms[1] - 0.0040720468*lms[2];
        double a = 1.9779984951*lms[0] - 2.4285922050*lms[1] + 0.4505937099*lms[2];
        double b = 0.0259040371*lms[0] + 0.7827717662*lms[1] - 0.8086757660*lms[2];
        const double C = std::hypot(a,b), pi = std::acos(-1.0), h = std::atan2(b,a)*180/pi;
        const double distance = std::fmod(h-p[33]+540,360)-180;
        double weight = std::abs(distance) < p[34] ? 0.5*(1+std::cos(pi*distance/p[34])) : 0;
        const double chroma = std::clamp((C-p[35])/(p[36]-p[35]),0.0,1.0);
        weight *= chroma*chroma*(3-2*chroma);
        if (weight > 0) {
            const double hue = (h+weight*p[31])*pi/180, saturation = C*(1+weight*(p[32]-1));
            a = saturation*std::cos(hue); b = saturation*std::sin(hue);
            lms = {L+0.3963377774*a+0.2158037573*b,
                   L-0.1055613458*a-0.0638541728*b,
                   L-0.0894841775*a-1.2914855480*b};
            for (double& v : lms) v = v*v*v;
            linear = {};
            for (int c = 0; c < 3; ++c) for (int j = 0; j < 3; ++j) linear[c] += p[21+3*c+j]*lms[j];
        }
    }
    for (double& v : linear) v = std::clamp((p[37]+p[38]*std::log10(std::fmax(v,0.0)*(1-p[41])+p[41]))/p[39],0.0,1.0);
    return linear;
}

bool check_cineon(Gpu* gpu, std::string& error) {
    const float to_lms[9] = {0.4122214708f,0.5363325363f,0.0514459929f,0.2119034982f,0.6806995451f,0.1073969566f,0.0883024619f,0.2817188376f,0.6299787005f};
    const float from_lms[9] = {4.0767416621f,-3.3077115913f,0.2309699292f,-1.2684380046f,2.6097574011f,-0.3413193965f,-0.0041960863f,-0.7034186147f,1.7076147010f};
    for (int variant=0;variant<3;++variant) for (bool blue : {false,true}) for (bool asymmetric : {false,true}) for (float floor : {0.0f,0.001f})
        for (uint32_t count : {0u,1u,255u,256u,257u,1025u}) {
            std::vector<float> p(42,0);
            const float matrix[9] = {0.93f,0.04f,0.03f,-0.07f,1.11f,-0.04f,0.02f,-0.03f,1.01f};
            if (asymmetric) std::copy_n(matrix,9,p.begin()); else p[0]=p[4]=p[8]=1;
            p[9]=0.12f; p[10]=-0.07f; p[11]=0.03f;
            std::copy_n(to_lms,9,p.begin()+12); std::copy_n(from_lms,9,p.begin()+21);
            p[30]=blue ? 1.0f : 0; p[31]=-8; p[32]=0.9f; p[33]=280; p[34]=55; p[35]=0.02f; p[36]=0.08f;
            if (variant==1) { p[31]=-30; p[32]=0.5f; }
            if (variant==2) { p[31]=30; p[32]=1.5f; }
            p[37]=685; p[38]=300; p[39]=1023; p[40]=floor; p[41]=float(std::pow(10.0,(95.0-685)/300));
            std::vector<float> input(size_t(std::max(count,1u))*3);
            std::vector<double> expected(size_t(count)*3);
            for (uint32_t i = 0; i < std::max(count,1u); ++i) {
                for (int c = 0; c < 3; ++c) input[3*i+c] = -5.0f+float((i*(17+7*c)+11*c)%107)*0.07f;
                if (i==0) input[0]=input[1]=input[2]=-std::numeric_limits<float>::infinity();
                if (i==1) input[3]=input[4]=input[5]=2;
                if (i<count) { const auto ref=cineon_reference(input.data()+3*i,p); std::copy(ref.begin(),ref.end(),expected.begin()+3*i); }
            }
            auto data=gpu->upload(input.data(),input.size()*sizeof(float),error);
            auto params=gpu->upload(p.data(),p.size()*sizeof(float),error);
            const std::vector<float> guarded(expected.size()+kGuards,kGuard);
            auto output=gpu->upload(guarded.data(),guarded.size()*sizeof(float),error);
            const uint32_t n[] = {count};
            if (!data || !params || !output ||
                !gpu->dispatch("spk_di_encode", {Arg::buf(data),Arg::buf(params),Arg::inline_bytes(n,1),Arg::buf(output)},std::max(count,1u),error) ||
                !check_result(gpu,output,expected,1e-6,"Cineon count="+std::to_string(count)+" blue="+std::to_string(blue),error)) return false;
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
    if (!check_lut(gpu.get(), error) || !check_di(gpu.get(), error) || !check_cineon(gpu.get(), error)) {
        std::fprintf(stderr, "LUT/DI: %s\n", error.c_str()); return 1;
    }
    std::printf("LUT/DI: %zu analytic/float64 cases, max abs error %.9g; NaN/Inf and guards passed\n",
                cases, largest_error);
    return 0;
}
