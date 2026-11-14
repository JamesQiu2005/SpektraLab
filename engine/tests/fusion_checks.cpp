// Compare the float32 intermediates of each fusion against its original kernels.
// Optional width allows the same check at photographic sizes. Native GPU times
// are printed separately from wall time; initialization is outside both.
#include "gpu/gpu.hpp"
#include "core/blob.hpp"
#include "core/colour.hpp"
#include "core/cam16.hpp"
#include <chrono>
#include <cmath>
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

    // --- 2026-11-11: the passes that ran back to back, as one kernel each -----------------
    //
    // Each of these replaced two or three consecutive kernels in the film or print chain. The
    // claim is not "close": the fused kernel forms every value by the same operations on the
    // same float32s, so the planes must compare equal byte for byte.
    const uint32_t H = w * 2 / 3, Wd = w;
    auto second = allocate();
    // upsample: `spk_tc_b` -> `spk_lut2d_cubic` -> the exposure's `spk_affine3`
    const uint32_t L = 33;
    std::vector<float> lut(size_t(L) * L * 3);
    for (size_t i = 0; i < lut.size(); ++i) lut[i] = .02f + float((i * 37) % 211) / 230.f;
    auto lut_b = upload(lut.data(), lut.size() * sizeof(float));
    const float tcm[9] = {.49f, .31f, .2f, .18f, .81f, .01f, 0.f, .01f, .99f};
    const float gain[3] = {1.3195f, 1.3195f, 1.3195f}, zero3[3] = {0, 0, 0};
    const float st[6] = {gain[0], gain[1], gain[2], 0, 0, 0};
    auto tcm_b = upload(tcm, sizeof tcm), gain_b = upload(gain, sizeof gain), zero_b = upload(zero3, sizeof zero3),
         st_b = upload(st, sizeof st);
    const uint32_t lut_meta[2] = {L, uint32_t(n)};
    compare("upsample_expose", [&](bool optimized, const spk::gpu::BufferRef& out) {
        if (optimized) {
            require(gpu->dispatch("spk_upsample_expose", {A::buf(input), A::buf(tcm_b), A::buf(lut_b), A::buf(st_b),
                A::inline_bytes(lut_meta, 2), A::buf(out)}, n, error));
        } else {
            require(gpu->dispatch("spk_tc_b", {A::buf(input), A::buf(tcm_b), A::inline_bytes(pixels, 1),
                A::buf(temporary), A::buf(second)}, n, error));
            require(gpu->dispatch("spk_lut2d_cubic", {A::buf(temporary), A::buf(second), A::buf(lut_b),
                A::inline_bytes(lut_meta, 2), A::buf(out)}, n, error));
            require(gpu->flush(error));
            require(gpu->dispatch("spk_affine3", {A::buf(out), A::buf(gain_b), A::buf(zero_b),
                A::inline_bytes(elems, 1), A::buf(out)}, n * 3, error));
        }
    });
    // log + curves: both outputs, one at a time
    const float one3[3] = {1, 1, 1};
    auto one_b = upload(one3, sizeof one3);
    compare("log_curves.density", [&](bool optimized, const spk::gpu::BufferRef& out) {
        if (optimized) {
            require(gpu->dispatch("spk_log_curves", {A::buf(input), A::buf(one_b), A::buf(xb), A::buf(ib), A::buf(yb),
                A::inline_bytes(curve_meta, 2), A::buf(temporary), A::buf(out)}, n, error));
        } else {
            require(gpu->dispatch("spk_log10_guarded", {A::buf(input), A::buf(one_b), A::inline_bytes(elems, 1),
                A::buf(temporary)}, n * 3, error));
            require(gpu->dispatch("spk_curves", {A::buf(temporary), A::buf(xb), A::buf(ib), A::buf(yb),
                A::inline_bytes(curve_meta, 2), A::buf(out)}, n, error));
        }
    });
    compare("log_curves.log", [&](bool optimized, const spk::gpu::BufferRef& out) {
        if (optimized) {
            require(gpu->dispatch("spk_log_curves", {A::buf(input), A::buf(one_b), A::buf(xb), A::buf(ib), A::buf(yb),
                A::inline_bytes(curve_meta, 2), A::buf(out), A::buf(temporary)}, n, error));
        } else {
            require(gpu->dispatch("spk_log10_guarded", {A::buf(input), A::buf(one_b), A::inline_bytes(elems, 1),
                A::buf(out)}, n * 3, error));
        }
    });
    // output: `spk_cctf_encode_matrix` -> `spk_to_rgba16`, every transfer function
    for (uint32_t mode = 0; mode <= 4; ++mode) {
        const uint32_t enc_meta[2] = {uint32_t(n), mode}, q_meta[3] = {uint32_t(n), Wd, Wd},
                       both[4] = {uint32_t(n), Wd, Wd, mode};
        compare("cctf_rgba16", [&](bool optimized, const spk::gpu::BufferRef& out) {
            if (optimized) {
                require(gpu->dispatch("spk_cctf_to_rgba16", {A::buf(input), A::buf(mb), A::inline_bytes(both, 4),
                    A::buf(out)}, n, error));
            } else {
                require(gpu->dispatch("spk_cctf_encode_matrix", {A::buf(input), A::buf(mb), A::inline_bytes(enc_meta, 2),
                    A::buf(temporary)}, n, error));
                require(gpu->dispatch("spk_to_rgba16", {A::buf(temporary), A::inline_bytes(q_meta, 3), A::buf(out)}, n, error));
            }
        });
    }
    // a blur's last pass with the mix that followed it (`Blur::Mix`), on a running sum (1) and
    // on the first component (2)
    const float mix_a[3] = {.74f, 1.f, 1.22f}, mix_b[3] = {.26f, -1.f, -.22f};
    const float mix_ab[6] = {mix_a[0], mix_a[1], mix_a[2], mix_b[0], mix_b[1], mix_b[2]};
    const float wt[3] = {.5067f, .4222f, .4352f};
    auto mix_a_b = upload(mix_a, sizeof mix_a), mix_b_b = upload(mix_b, sizeof mix_b), mix_ab_b = upload(mix_ab, sizeof mix_ab),
         wt_b = upload(wt, sizeof wt);
    const int R = 4;
    float taps[27];
    for (int c = 0; c < 3; ++c) {
        float sum = 0;
        for (int k = -R; k <= R; ++k) sum += (taps[9 * c + k + R] = std::exp(-.5f * float(k * k) / (1.2f + .3f * c)));
        for (int k = 0; k < 9; ++k) taps[9 * c + k] /= sum;
    }
    auto taps_b = upload(taps, sizeof taps);
    // a stable third-order recurrence with unit gain; the low words are there to be carried
    float coef[24];
    for (int c = 0; c < 3; ++c) {
        const float bq[4] = {.1f, 1.2f, -.5f, .2f};
        for (int q = 0; q < 4; ++q) { coef[8 * c + 2 * q] = bq[q]; coef[8 * c + 2 * q + 1] = 1e-9f * float(q + c - 2); }
    }
    const uint32_t act[3] = {1, 1, 1};
    auto coef_b = upload(coef, sizeof coef), act_b = upload(act, sizeof act);
    for (uint32_t accumulate : {1u, 2u}) {
        const uint32_t fir_v[6] = {H, Wd, uint32_t(R), 0, 0, 0}, fir_h[6] = {H, Wd, uint32_t(R), 1, accumulate, 0};
        auto finish = [&](const spk::gpu::BufferRef& blurred, const spk::gpu::BufferRef& out) {
            // what used to follow: `spk_lincomb3`
            require(gpu->flush(error));
            require(gpu->dispatch("spk_lincomb3", {A::buf(input), A::buf(blurred), A::buf(mix_a_b), A::buf(mix_b_b),
                A::inline_bytes(elems, 1), A::buf(out)}, n * 3, error));
        };
        compare("fir_fin", [&](bool optimized, const spk::gpu::BufferRef& out) {
            require(gpu->dispatch("spk_sep_fir_acc", {A::buf(input), A::buf(taps_b), A::buf(corr), A::buf(wt_b),
                A::inline_bytes(fir_v, 6), A::buf(temporary)}, n, error));
            if (optimized) {
                require(gpu->dispatch("spk_sep_fir_fin", {A::buf(temporary), A::buf(taps_b), A::buf(corr), A::buf(wt_b),
                    A::inline_bytes(fir_h, 6), A::buf(out), A::buf(input), A::buf(mix_ab_b)}, n, error));
            } else {
                require(gpu->dispatch("spk_sep_fir_acc", {A::buf(temporary), A::buf(taps_b), A::buf(corr), A::buf(wt_b),
                    A::inline_bytes(fir_h, 6), A::buf(second)}, n, error));
                finish(second, out);
            }
        });
        const uint32_t iir_h[4] = {H, Wd, 0, 1}, iir_v[4] = {H, Wd, accumulate, 0};
        compare("iir_fin", [&](bool optimized, const spk::gpu::BufferRef& out) {
            // as `Blur::iir` runs it: horizontal into the destination, vertical in place
            const spk::gpu::BufferRef& plane = optimized ? out : second;
            require(gpu->dispatch("spk_iir_df_acc", {A::buf(input), A::buf(coef_b), A::buf(act_b), A::buf(corr), A::buf(wt_b),
                A::inline_bytes(iir_h, 4), A::buf(plane)}, size_t(H) * 3, error));
            require(gpu->flush(error));
            if (optimized) {
                require(gpu->dispatch("spk_iir_df_fin", {A::buf(plane), A::buf(coef_b), A::buf(act_b), A::buf(corr), A::buf(wt_b),
                    A::inline_bytes(iir_v, 4), A::buf(plane), A::buf(input), A::buf(mix_ab_b)}, size_t(Wd) * 3, error));
            } else {
                require(gpu->dispatch("spk_iir_df_acc", {A::buf(plane), A::buf(coef_b), A::buf(act_b), A::buf(corr), A::buf(wt_b),
                    A::inline_bytes(iir_v, 4), A::buf(plane)}, size_t(Wd) * 3, error));
                finish(second, out);
            }
        });
    }
    return 0;
}
