// Compare the float32 intermediates of each fusion against its original kernels.
// Optional width allows the same check at photographic sizes. Native GPU times
// are printed separately from wall time; initialization is outside both.
#include "gpu/gpu.hpp"
#include "core/blob.hpp"
#include "core/colour.hpp"
#include "core/cam16.hpp"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2 || argc > 3) return 2;
    const unsigned w = argc == 3 ? std::strtoul(argv[2], nullptr, 10) : 1200;
    if (w < 3 || w > 16000) return 2;
    const size_t n = size_t(w) * (w * 2 / 3), bytes = n * 3 * sizeof(float);
    std::string error;
    std::unique_ptr<spk::gpu::Gpu> gpu(spk::gpu::Gpu::create_metal(nullptr, std::string(argv[1]) + "/spektralab.metallib", error));
    auto require = [&](bool ok) {
        if (!ok) { std::fprintf(stderr, "%s\n", error.c_str()); std::exit(1); }
    };
    require(bool(gpu));
    auto upload = [&](const void* data, size_t size) {
        auto b = gpu->upload_persistent(data, size, error);
        require(bool(b));
        return b;
    };
    auto allocate = [&] {
        auto b = gpu->alloc_persistent(bytes, error);
        require(bool(b));
        return b;
    };
    std::vector<float> x(n * 3), correction(n * 3);
    for (size_t i = 0; i < x.size(); ++i) {
        x[i] = float(i % 2309) / 1700.f - .03f;
        correction[i] = float(i % 307) / 1900.f;
    }
    auto input = upload(x.data(), bytes), corr = upload(correction.data(), bytes);
    x.clear(); x.shrink_to_fit(); correction.clear(); correction.shrink_to_fit();
    auto temporary = allocate(), plain = allocate(), fused = allocate();
    const float a[3] = {1, 1, 1}, b[3] = {-1, -1, -1};
    auto ab = upload(a, sizeof(a)), bb = upload(b, sizeof(b));
    const uint32_t elems[1] = {uint32_t(n * 3)}, curve_meta[2] = {256, uint32_t(n)}, pixels[1] = {uint32_t(n)};
    float xa[768], yv[768], inv[765];
    for (unsigned i = 0; i < 256; ++i) for (unsigned c = 0; c < 3; ++c) {
        xa[3*i+c] = -5.f + float(i)*.04f;
        yv[3*i+c] = float(i*i)*(.0001f+.00001f*c);
        if (i < 255) inv[3*i+c] = 1.f/((-5.f+float(i+1)*.04f)-xa[3*i+c]);
    }
    auto xb = upload(xa, sizeof(xa)), yb = upload(yv, sizeof(yv)), ib = upload(inv, sizeof(inv));
    using A = spk::gpu::Arg;
    auto compare = [&](const char* name, auto dispatch) {
        for (int iteration = 0; iteration < 5; ++iteration) for (bool optimized : {false, true, true, false}) {
            gpu->begin_frame();
            const auto start = std::chrono::steady_clock::now();
            dispatch(optimized, optimized ? fused : plain);
            require(gpu->flush(error));
            const double wall = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            const auto stats = gpu->frame_stats();
            gpu->end_frame();
            if (optimized && std::memcmp(gpu->contents(plain.get()), gpu->contents(fused.get()), bytes) != 0) {
                std::fprintf(stderr, "%s float32 output differs\n", name);
                std::exit(1);
            }
            std::printf("{\"test\":\"%s\",\"iteration\":%d,\"optimized\":%s,\"gpu_ms\":%.6f,\"wall_ms\":%.6f}\n",
                        name, iteration, optimized ? "true" : "false", stats.gpu_ms, wall);
        }
    };
    compare("dir", [&](bool optimized, const spk::gpu::BufferRef& out) {
        if (optimized) {
            require(gpu->dispatch("spk_dir_finish", {A::buf(input), A::buf(xb), A::buf(ib), A::buf(yb),
                A::inline_bytes(curve_meta, 2), A::buf(out), A::buf(corr)}, n, error));
        } else {
            require(gpu->dispatch("spk_lincomb3", {A::buf(input), A::buf(corr), A::buf(ab), A::buf(bb),
                A::inline_bytes(elems, 1), A::buf(temporary)}, n*3, error));
            require(gpu->dispatch("spk_curves", {A::buf(temporary), A::buf(xb), A::buf(ib), A::buf(yb),
                A::inline_bytes(curve_meta, 2), A::buf(out)}, n, error));
        }
    });
    spk::Blob blob;
    spk::Colour colour;
    spk::Cam16Setup setup;
    require(blob.open(std::string(argv[1]) + "/spektralab_constants.bin", error) && colour.init(blob, error) &&
            spk::cam16_setup_for(colour, "sRGB", setup, error));
    double m1[9], m2[9];
    setup.m_to_xyz.to_row_major(m1); setup.m_to_rgb.to_row_major(m2);
    auto m2x = gpu->upload_persistent_f32(m1, 9, error), m2r = gpu->upload_persistent_f32(m2, 9, error);
    auto cmax = gpu->upload_persistent_f32(setup.c_max_table.data(), setup.c_max_table.size(), error);
    const double k[] = {setup.F_L, setup.N_bb, setup.N_cb, setup.n, setup.z, setup.A_w, setup.c, setup.N_c,
        setup.l_grid.front(), setup.l_grid.back(), setup.h_grid.front(), setup.h_grid[1]-setup.h_grid[0],
        .8, 1., 1.2, .9, 1., 1.2, setup.white_Jp, setup.D_rgb[0], setup.D_rgb[1], setup.D_rgb[2]};
    auto kb = gpu->upload_persistent_f32(k, 22, error);
    require(bool(m2x) && bool(m2r) && bool(cmax) && bool(kb));
    const uint32_t gamut_meta[4] = {uint32_t(n), 64, 720, 1};
    const float matrix[] = {.8, .1, .03, .1, .8, .08, .1, .1, .89};
    auto mb = upload(matrix, sizeof(matrix));
    compare("gamut", [&](bool optimized, const spk::gpu::BufferRef& out) {
        if (optimized) {
            require(gpu->dispatch("spk_xyz_cam16_compress", {A::buf(input), A::buf(m2x), A::buf(m2r), A::buf(cmax),
                A::buf(kb), A::inline_bytes(gamut_meta, 4), A::buf(out), A::buf(mb)}, n, error));
        } else {
            require(gpu->dispatch("spk_matmul3", {A::buf(input), A::buf(mb), A::inline_bytes(pixels, 1), A::buf(temporary)}, n, error));
            require(gpu->dispatch("spk_cam16ucs_compress", {A::buf(temporary), A::buf(m2x), A::buf(m2r), A::buf(cmax),
                A::buf(kb), A::inline_bytes(gamut_meta, 4), A::buf(out)}, n, error));
        }
    });
    return 0;
}
