// Independent headless checks for the Windows pointwise ports. Guard values
// exercise the rounded-up final workgroup, not just the visible image plane.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"
#include "core/latitude_fit.hpp"

#include <algorithm>
#include <array>
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
// Independent integer-geometry oracles for the overscan SSBO boundary.
// These deliberately avoid the shader's SDF/noise implementation: a hard
// rectangle must copy its known source cells, and the other cases have
// analytic zero/one coverage or explicitly listed clipped mask writes.
bool check_contrast_mask(Gpu* gpu, std::string& error) {
    for (uint32_t nl : {1u,5u}) for (bool one : {true,false}) for (uint32_t flags=0;flags<4;++flags) {
        const uint32_t W=one ? 1:17, H=one ? 1:13, gw=one ? 1:4, gh=one ? 1:3;
        std::vector<float> cmy(size_t(W)*H*3),chd(size_t(nl)*3),base(nl),ixs(size_t(nl)*3);
        for (size_t i=0;i<cmy.size();++i) cmy[i]=float((i*13+7)%137)*0.005f;
        for (uint32_t l=0;l<nl;++l) {
            base[l]=float(l)*0.01f;
            for (uint32_t c=0;c<3;++c) { chd[3*l+c]=0.04f*float((c+1)*(l+1)); ixs[3*l+c]=float(l+c+1)/float(nl*(nl+5)); }
        }
        const float p[16]={0.9f,1.2f,0.7f,1.1f,0.8f,1.4f,0,0.05f,0.11f,-0.5f,1.1f,float(flags&1),0.5f,0.9f,float(flags&2),3};
        auto exposure=[&](uint32_t i) {
            std::array<double,3> a{};
            for (uint32_t l=0;l<nl;++l) {
                double d=base[l]; for (uint32_t c=0;c<3;++c) d+=double(cmy[3*i+c])*chd[3*l+c];
                const double t=std::pow(10.0,-d);
                for (uint32_t c=0;c<3;++c) a[c]+=t*ixs[3*l+c];
            }
            for (uint32_t c=0;c<3;++c) a[c]*=p[c]; return a;
        };
        auto mask_x=[&](const std::array<double,3>& a) {
            double sum=0; for (uint32_t c=0;c<3;++c) sum+=std::max(std::log2(std::max(a[c]*p[3+c],0.0)),-20.0); return sum/3;
        };
        auto dyes=gpu->upload(chd.data(),chd.size()*sizeof(float),error);
        auto basebuf=gpu->upload(base.data(),base.size()*sizeof(float),error);
        auto sensitivity=gpu->upload(ixs.data(),ixs.size()*sizeof(float),error);
        auto parameters=gpu->upload(p,sizeof p,error);
        auto input=gpu->upload(cmy.data(),cmy.size()*sizeof(float),error);
        auto output=output_buffer(gpu,size_t(gw)*gh,error);
        const uint32_t reduce_meta[5]={W,H,gw,gh,nl};
        std::vector<double> expected(size_t(gw)*gh);
        for (uint32_t gy=0;gy<gh;++gy) for (uint32_t gx=0;gx<gw;++gx) {
            const uint32_t x0=gx*W/gw,x1=(gx+1)*W/gw,y0=gy*H/gh,y1=(gy+1)*H/gh;
            double sum=0; for (uint32_t y=y0;y<y1;++y) for (uint32_t x=x0;x<x1;++x) sum+=mask_x(exposure(y*W+x));
            expected[gy*gw+gx]=sum/double((x1-x0)*(y1-y0));
        }
        if (!dyes || !basebuf || !sensitivity || !parameters || !input || !output ||
            !gpu->dispatch("spk_mask_reduce",{Arg::buf(input),Arg::buf(dyes),Arg::buf(basebuf),Arg::buf(sensitivity),Arg::buf(parameters),Arg::inline_bytes(reduce_meta,5),Arg::buf(output)},gw*gh,error) ||
            !check_values(gpu,output,expected,"mask reduce double reference",2e-7,1e-6,error)) return false;
        std::vector<float> coef(size_t(gw)*gh*2);
        for (uint32_t i=0;i<gw*gh;++i) { coef[2*i]=float(i%5)*0.125f; coef[2*i+1]=-1.5f+float(i%7)*0.5f; }
        auto coefficients=gpu->upload(coef.data(),coef.size()*sizeof(float),error);
        for (uint32_t row0 : {0u,1u,7u,H-1}) {
            if (row0>=H) continue;
            const uint32_t rows=row0==0 ? H:std::min(4u,H-row0), n=W*rows;
            input=gpu->upload(cmy.data()+size_t(row0)*W*3,size_t(n)*3*sizeof(float),error);
            output=output_buffer(gpu,size_t(n)*3,error); expected.assign(size_t(n)*3,0);
            for (uint32_t y=row0;y<row0+rows;++y) for (uint32_t x=0;x<W;++x) {
                const auto a=exposure(y*W+x);
                const double u=std::clamp((x+0.5)*gw/W-0.5,0.0,double(gw-1)), v=std::clamp((y+0.5)*gh/H-0.5,0.0,double(gh-1));
                const uint32_t u0=uint32_t(std::floor(u)),v0=uint32_t(std::floor(v)),u1=std::min(u0+1,gw-1),v1=std::min(v0+1,gh-1);
                const double tu=u-u0,tv=v-v0;
                auto interp=[&](uint32_t c) { return (1-tv)*((1-tu)*coef[2*(v0*gw+u0)+c]+tu*coef[2*(v0*gw+u1)+c])+tv*((1-tu)*coef[2*(v1*gw+u0)+c]+tu*coef[2*(v1*gw+u1)+c]); };
                const double b=interp(0)*mask_x(a)+interp(1);
                double delta=0;
                if (p[11]!=0 && b<p[9]) { const double d=p[9]-b; delta=d-d*p[10]/std::sqrt(double(p[10])*p[10]+d*d); }
                else if (p[14]!=0 && b>p[12]) { const double d=b-p[12]; delta=d*p[13]/std::sqrt(double(p[13])*p[13]+d*d)-d; }
                delta=delta*p[15]/std::sqrt(double(p[15])*p[15]+delta*delta);
                for (uint32_t c=0;c<3;++c) expected[3*((y-row0)*W+x)+c]=std::log10(std::max(std::exp2(delta)*a[c]+p[6+c],0.0)+1e-10);
            }
            const uint32_t meta[7]={n,nl,W,H,row0,gw,gh};
            if (!input || !output || !coefficients ||
                !gpu->dispatch("spk_mask_epilogue",{Arg::buf(input),Arg::buf(dyes),Arg::buf(basebuf),Arg::buf(sensitivity),Arg::buf(parameters),Arg::buf(coefficients),Arg::inline_bytes(meta,7),Arg::buf(output)},n,error) ||
                !check_values(gpu,output,expected,"mask epilogue band/flash double reference",2e-7,1e-6,error)) return false;
        }
        const uint32_t empty[7]={0,nl,W,H,0,gw,gh};
        output=output_buffer(gpu,0,error);
        if (!output || !gpu->dispatch("spk_mask_epilogue",{Arg::buf(input),Arg::buf(dyes),Arg::buf(basebuf),Arg::buf(sensitivity),Arg::buf(parameters),Arg::buf(coefficients),Arg::inline_bytes(empty,7),Arg::buf(output)},0,error) ||
            !check_values(gpu,output,{},"mask zero work",0,0,error)) return false;
    }
    return true;
}

bool check_scene_latitude(Gpu* gpu, std::string& error) {
    constexpr uint32_t count = 19 * 17;
    std::vector<float> rgb(size_t(count) * 3);
    for (uint32_t i = 0; i < count; ++i) {
        const double E = -24.0 + 48.0 * i / (count - 1);
        const float v = float(0.184 * std::exp2(E));
        rgb[3*i] = v; rgb[3*i+1] = v * 0.53f; rgb[3*i+2] = (i % 7 == 0 ? -0.2f : 1.27f) * v;
    }
    rgb[0] = rgb[1] = rgb[2] = 0;
    rgb[3] = rgb[4] = rgb[5] = -1;
    rgb[6] = std::numeric_limits<float>::infinity();
    rgb[9] = std::numeric_limits<float>::quiet_NaN();
    const auto input = gpu->upload(rgb.data(), rgb.size() * sizeof(float), error);
    const uint32_t n[] = {count};
    for (float shape : {1.0f, 2.0f, 1.5f, 3.0f}) for (int norm = 0; norm < 3; ++norm)
        for (int portrait = 0; portrait < 2; ++portrait) {
            const float p[19] = {2, 1.5f, -3, 2, shape, 6, float(norm), 0.2126f, 0.7152f, 0.0722f,
                                 0.184f, 19, portrait ? 101.0f : 17.0f, 0.45f, 1, 2.5f, -2, 1,
                                 portrait ? 37.0f : 0.0f};
            const auto parameters = gpu->upload(p, sizeof p, error);
            auto output = output_buffer(gpu, rgb.size(), error);
            std::vector<double> expected(rgb.size());
            for (uint32_t i = 0; i < count; ++i) {
                const double r = std::fmax(rgb[3*i], 0.0f), g = std::fmax(rgb[3*i+1], 0.0f), b = std::fmax(rgb[3*i+2], 0.0f);
                const double s2 = r*r + g*g + b*b;
                const double v = norm == 1 ? p[7]*r + p[8]*g + p[9]*b : norm == 2 ? std::max({r,g,b}) : s2 > 0 ? (r*r*r+g*g*g+b*b*b)/s2 : 0;
                double gain = 1;
                if (v > 0 && std::isfinite(v)) {
                    const double along = portrait ? (double(i / 19) + p[18] + 0.5) / p[12] : (double(i % 19) + 0.5) / 19;
                    const int base = along >= p[13] ? 14 : 0;
                    spk::SceneLatitudeParams q;
                    q.active = true; q.highlight_knee = p[base]; q.highlight_room = p[base+1];
                    q.shadow_knee = p[base+2]; q.shadow_room = p[base+3]; q.rolloff = shape; q.max_lift = p[5];
                    const double E = std::clamp(std::log2(std::max(v, double(p[10])*std::exp2(-24.0)) / p[10]), -24.0, 24.0);
                    gain = std::clamp(std::exp2(spk::slm::delta(E, q)), std::exp2(-30.0), std::exp2(30.0));
                }
                for (int c = 0; c < 3; ++c) expected[3*i+c] = double(rgb[3*i+c]) * gain;
            }
            if (!input || !parameters || !output ||
                !gpu->dispatch("spk_scene_latitude", {Arg::buf(input), Arg::buf(parameters), Arg::inline_bytes(n, 1), Arg::buf(output)}, count, error) ||
                !check_values(gpu, output, expected, "scene latitude double reference", 2e-7, 1e-6, error)) return false;
        }
    return true;
}

bool check_overscan(Gpu* gpu, std::string& error) {
    std::vector<float> p(261, 0.0f);
    p[0] = 18; p[1] = 12; p[2] = 1; p[3] = 8; p[4] = 6;
    p[5] = p[8] = 1;  // identity canvas-to-film transform
    p[14] = 4; p[15] = 3; p[16] = 8; p[17] = 6;
    p[44] = 12; p[199] = 2;  // carrier does not clip the rectangle
    std::vector<float> source(8 * 6 * 3);
    for (size_t i = 0; i < source.size(); ++i) source[i] = float(i % 17) / 16.0f;
    auto input = gpu->upload(source.data(), source.size() * sizeof(float), error);
    auto parameters = gpu->upload(p.data(), p.size() * sizeof(float), error);
    const uint32_t n[] = {18 * 12};
    auto output = output_buffer(gpu, size_t(n[0]) * 3, error);
    std::vector<double> expected(size_t(n[0]) * 3, 0.0);
    for (uint32_t y = 3; y < 9; ++y)
        for (uint32_t x = 4; x < 12; ++x)
            for (uint32_t c = 0; c < 3; ++c)
                expected[3 * (y * 18 + x) + c] = source[3 * ((y - 3) * 8 + x - 4) + c];
    if (!input || !parameters || !output ||
        !gpu->dispatch("spk_overscan_canvas", {Arg::buf(input), Arg::buf(parameters),
                           Arg::inline_bytes(n, 1), Arg::buf(output)}, n[0], error) ||
        !check_values(gpu, output, expected, "overscan hard gate", 0, 0, error)) return false;

    const float coverage[] = {0, 0.25f, 0.5f, 1};
    const float mask_meta[] = {-1, 1, 2, 2, 3, 3, 0.5f, 1, 2};
    std::vector<float> canvas(27 + kGuardCount, kGuard);
    std::fill_n(canvas.begin(), 27, 0.125f);
    input = gpu->upload(coverage, sizeof coverage, error);
    parameters = gpu->upload(mask_meta, sizeof mask_meta, error);
    output = gpu->upload(canvas.data(), canvas.size() * sizeof(float), error);
    const uint32_t mn[] = {4};
    expected.assign(27, 0.125);
    expected[9] += 0.125; expected[10] += 0.25; expected[11] += 0.5;
    expected[18] += 0.5; expected[19] += 1; expected[20] += 2;
    if (!input || !parameters || !output ||
        !gpu->dispatch("spk_overscan_add_mask", {Arg::buf(input), Arg::buf(parameters),
                           Arg::inline_bytes(mn, 1), Arg::buf(output)}, mn[0], error) ||
        !check_values(gpu, output, expected, "overscan clipped mask", 0, 0, error)) return false;

    p.assign(261, 0.0f);
    p[0] = 3; p[1] = 4; p[2] = 1; p[5] = p[8] = 1;
    p[44] = 2; p[90] = 0.125f; p[91] = 0.25f; p[92] = 0.5f;
    p[184] = p[185] = p[186] = 1;
    source.resize(36);
    for (size_t i = 0; i < source.size(); ++i) source[i] = float(i % 13) / 8.0f;
    input = gpu->upload(source.data(), source.size() * sizeof(float), error);
    parameters = gpu->upload(p.data(), p.size() * sizeof(float), error);
    const uint32_t sn[] = {12};
    for (const char* name : {"spk_overscan_film_present", "spk_overscan_light"}) {
        output = output_buffer(gpu, source.size(), error);
        expected.assign(source.begin(), source.end());
        for (size_t i = 18; i < source.size(); ++i)
            expected[i] = std::string(name) == "spk_overscan_film_present" ? p[90 + i % 3] : 0;
        if (!input || !parameters || !output ||
            !gpu->dispatch(name, {Arg::buf(input), Arg::buf(parameters),
                               Arg::inline_bytes(sn, 1), Arg::buf(output)}, sn[0], error) ||
            !check_values(gpu, output, expected, name, 0, 0, error)) return false;
        // The zero-work dispatch must leave every element and rounded tail alone.
        const uint32_t zero[] = {0};
        output = output_buffer(gpu, source.size(), error);
        expected.assign(source.size(), kGuard);
        if (!output || !gpu->dispatch(name, {Arg::buf(input), Arg::buf(parameters),
                               Arg::inline_bytes(zero, 1), Arg::buf(output)}, 1, error) ||
            !check_values(gpu, output, expected, "overscan zero work", 0, 0, error)) return false;
    }
    // Endpoint invariance: an opaque film pixel must not change when the
    // carrier outside it changes. Non-dyadic inputs expose FMix cancellation.
    for (size_t i = 0; i < source.size(); ++i) source[i] = float(i + 1) * 0.0137f;
    input = gpu->upload(source.data(), source.size() * sizeof(float), error);
    for (float carrier : {0.0f, 1.0f}) {
        p[199] = carrier;
        parameters = gpu->upload(p.data(), p.size() * sizeof(float), error);
        output = output_buffer(gpu, source.size(), error);
        expected.assign(source.begin(), source.end());
        for (size_t i = 18; i < source.size(); ++i) expected[i] = carrier;
        if (!input || !parameters || !output ||
            !gpu->dispatch("spk_overscan_light", {Arg::buf(input), Arg::buf(parameters),
                               Arg::inline_bytes(sn, 1), Arg::buf(output)}, sn[0], error) ||
            !check_values(gpu, output, expected, "overscan carrier endpoint", 0, 0, error)) return false;
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
        !check_bw(gpu.get(), error) || !check_edr(gpu.get(), error) || !check_decode(gpu.get(), error) ||
        !check_overscan(gpu.get(), error) || !check_scene_latitude(gpu.get(), error) || !check_contrast_mask(gpu.get(), error)) {
        std::fprintf(stderr, "pointwise: %s\n", error.c_str()); return 1;
    }
    std::printf("pointwise: %zu analytic/float64 cases, max abs error %.9g, "
                "max error/max(1,abs(reference)) %.9g, all guards intact\n",
                cases, maximum_error, maximum_scaled_error);
    return 0;
}
