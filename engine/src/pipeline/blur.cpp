#include "blur.hpp"

#include <cmath>
#include <cstring>

namespace spk {

namespace {

// The reference splits every IIR coefficient into a (hi, lo) float pair on the
// host, so the kernel's double-float recurrence starts from the float64 value.
std::pair<float, float> split(double v) {
    const float hi = float(v);
    return {hi, float(v - double(hi))};
}

void broadcast3(const double* src, double dst[3], double fallback) {
    if (!src) { dst[0] = dst[1] = dst[2] = fallback; return; }
    dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
}

}  // namespace

bool Blur::alloc_like(const Image& img, Image& out, std::string& error) {
    out.h = img.h; out.w = img.w; out.c = img.c;
    out.buf = gpu_->alloc(img.bytes(), error);
    return static_cast<bool>(out.buf);
}

bool Blur::fir(const Image& img, const double sigmas[3], double truncate, const bool active[3],
               Image& out, std::string& error, const Image* acc, const double* weight) {
    // (3, 2R+1) weights, a delta for every inactive channel, so one kernel
    // handles a mix of blurred and pass-through channels in one pass.
    Vec kernels[3];
    size_t radii[3] = {0, 0, 0};
    for (int c = 0; c < 3; ++c) {
        if (active[c] && sigmas[c] > 0.0) radii[c] = gaussian_kernel_1d(sigmas[c], truncate, kernels[c]);
        else { kernels[c].assign(1, 1.0); radii[c] = 0; }
    }
    const size_t R = std::max(radii[0], std::max(radii[1], radii[2]));
    if (R == 0 && active[0] && active[1] && active[2] && !acc) { out = img; return true; }

    std::vector<float> table(3 * (2 * R + 1), 0.0f);
    for (int c = 0; c < 3; ++c) {
        const size_t r = radii[c];
        for (size_t i = 0; i < kernels[c].size(); ++i)
            table[size_t(c) * (2 * R + 1) + (R - r + i)] = float(kernels[c][i]);
    }
    gpu::BufferRef w = gpu_->upload(table.data(), table.size() * sizeof(float), error);
    if (!w) return false;

    double wt[3];
    broadcast3(weight, wt, 1.0);
    const float wtf[3] = {float(wt[0]), float(wt[1]), float(wt[2])};
    gpu::BufferRef wt_buf = gpu_->upload(wtf, sizeof wtf, error);
    if (!wt_buf) return false;

    // The reference runs vertical then horizontal, and the fused multiply-add
    // rides on the second pass.
    Image tmp;
    if (!alloc_like(img, tmp, error)) return false;
    if (!alloc_like(img, out, error)) return false;
    const gpu::BufferRef& dummy = acc ? acc->buf : img.buf;
    const uint32_t meta_v[6] = {img.h, img.w, uint32_t(R), 0, 0, 0};
    const uint32_t meta_h[6] = {img.h, img.w, uint32_t(R), 1, acc ? 1u : 0u, 0};
    const size_t n = img.pixels();
    if (!gpu_->dispatch("spk_sep_fir_acc",
                        {gpu::Arg::buf(img.buf), gpu::Arg::buf(w), gpu::Arg::buf(dummy),
                         gpu::Arg::buf(wt_buf), gpu::Arg::inline_bytes(meta_v, 6), gpu::Arg::buf(tmp.buf)},
                        n, error)) return false;
    return gpu_->dispatch("spk_sep_fir_acc",
                          {gpu::Arg::buf(tmp.buf), gpu::Arg::buf(w), gpu::Arg::buf(dummy),
                           gpu::Arg::buf(wt_buf), gpu::Arg::inline_bytes(meta_h, 6), gpu::Arg::buf(out.buf)},
                          n, error);
}

bool Blur::iir(const Image& img, const double sigmas[3], const bool active[3],
               Image& out, std::string& error, const Image* acc, const double* weight) {
    float coef[24] = {};
    uint32_t act[3] = {0, 0, 0};
    bool any = false;
    for (int c = 0; c < 3; ++c) {
        if (!(active[c] && sigmas[c] > 0.0)) continue;
        double b[4];
        yvv_coeffs(sigmas[c], b);
        for (int j = 0; j < 4; ++j) {
            const auto hl = split(b[j]);
            coef[8 * c + 2 * j] = hl.first;
            coef[8 * c + 2 * j + 1] = hl.second;
        }
        act[c] = 1;
        any = true;
    }
    if (!any && !acc) { out = img; return true; }

    gpu::BufferRef coef_buf = gpu_->upload(coef, sizeof coef, error);
    gpu::BufferRef act_buf = gpu_->upload_u32(act, 3, error);
    if (!coef_buf || !act_buf) return false;
    double wt[3];
    broadcast3(weight, wt, 1.0);
    const float wtf[3] = {float(wt[0]), float(wt[1]), float(wt[2])};
    gpu::BufferRef wt_buf = gpu_->upload(wtf, sizeof wtf, error);
    if (!wt_buf) return false;

    // **Two launches and one plane.** The vertical pass runs first, in place
    // over the destination; the horizontal pass is the *same kernel* with
    // `axis = 1`, marching along rows with stride 3 rather than down the
    // columns of a transposed copy. What the transposed path bought was
    // coalesced reads for the horizontal recurrence and it cost three extra
    // full planes to get them: the transpose, its result, and the transpose
    // back. Those are gone, and the arithmetic is untouched -- the same
    // instructions in the same order, at different addresses.
    if (!alloc_like(img, out, error)) return false;
    const Image* dummy = acc ? acc : &img;
    // **Horizontal first, and the order is not a detail.** The reference's
    // `_gaussian_filter_2d_large` is `_iir_horizontal` then `_iir_vertical`,
    // and a separable IIR's two passes commute in exact arithmetic and *not* in
    // floating point: run them the other way round and every value moves in the
    // last place. The transposed path was horizontal-first for this reason --
    // the transpose existed so that pass could be the vertical kernel -- and
    // the first draft of this rewrite had it vertical-first, with a comment
    // claiming the order was preserved. `iir_bitexact.py` against the previous
    // build said otherwise, which is what that gate is for: the parity
    // harnesses hold a 1e-5 tolerance and would have absorbed it.
    //
    // The first pass is plain and the second carries the mixture's multiply-add,
    // which is also where the fused multiply-add landed in the transposed path.
    const uint32_t meta_h[4] = {img.h, img.w, 0u, 1u};
    const uint32_t meta_v[4] = {img.h, img.w, acc ? 1u : 0u, 0u};
    if (!gpu_->dispatch("spk_iir_df_acc",
                        {gpu::Arg::buf(img.buf), gpu::Arg::buf(coef_buf), gpu::Arg::buf(act_buf),
                         gpu::Arg::buf(dummy->buf), gpu::Arg::buf(wt_buf),
                         gpu::Arg::inline_bytes(meta_h, 4), gpu::Arg::buf(out.buf)},
                        size_t(img.h) * 3, error)) return false;
    if (!gpu_->dispatch("spk_iir_df_acc",
                        {gpu::Arg::buf(out.buf), gpu::Arg::buf(coef_buf), gpu::Arg::buf(act_buf),
                         gpu::Arg::buf(dummy->buf), gpu::Arg::buf(wt_buf),
                         gpu::Arg::inline_bytes(meta_v, 4), gpu::Arg::buf(out.buf)},
                        size_t(img.w) * 3, error)) return false;
    // What a `Swept` stage reports: this pass covers the plane once, as one
    // span, whatever the executor's plan says -- the plan is about bands and
    // this never makes one. Filled here rather than by the caller, so the
    // report is what was launched and not what was intended.
    if (sweep_report_) {
        sweep_report_->bands.push_back({0, img.h});
        sweep_report_->launches += 2;
    }
    return true;
}

uint32_t Blur::fir_radius(double sigma, double truncate) {
    if (!is_fir(sigma)) return 0;
    // Asked of the kernel builder itself rather than recomputed: this function
    // exists so the executor knows how many rows of context to copy, and the
    // one thing it must not do is round `truncate * sigma + 0.5` differently
    // from the kernel that will read them.
    Vec ignored;
    return uint32_t(gaussian_kernel_1d(sigma, truncate, ignored));
}

Blur::Demand Blur::demand(const double sigma[3], double truncate) {
    Demand d;
    for (int c = 0; c < 3; ++c) {
        if (!(sigma[c] > 0.0)) continue;  // identity: no pass, no context
        if (is_fir(sigma[c])) d.halo = std::max(d.halo, fir_radius(sigma[c], truncate));
        else d.carried = true;
    }
    return d;
}

Blur::Demand Blur::demand(const std::vector<Component>& components, double truncate) {
    // Every component runs -- `mixture` does not skip one for a zero weight,
    // it blurs it and multiplies by zero -- so this is exact rather than
    // conservative. The components are **alternatives** of one input, which is
    // why this is a max: sequence is the caller's sum.
    Demand d;
    for (const Component& comp : components) d = merge(d, demand(comp.sigma, truncate));
    return d;
}

Blur::Demand Blur::merge(const Demand& a, const Demand& b) {
    Demand d;
    d.carried = a.carried || b.carried;
    d.halo = std::max(a.halo, b.halo);
    return d;
}

bool Blur::gaussian(const Image& img, const double sigma[3], Image& out, std::string& error,
                    double truncate, const Image* acc, const double* weight) {
    bool use_fir[3], use_iir[3];
    bool any_fir = false, any_iir = false;
    for (int c = 0; c < 3; ++c) {
        use_fir[c] = sigma[c] > 0.0 && sigma[c] < kSmallSigmaMax;
        use_iir[c] = sigma[c] >= kSmallSigmaMax;
        any_fir |= use_fir[c];
        any_iir |= use_iir[c];
    }
    if (!acc) {
        Image cur = img;
        if (any_fir) {
            Image next;
            if (!fir(cur, sigma, truncate, use_fir, next, error, nullptr, nullptr)) return false;
            cur = next;
        }
        if (any_iir) {
            Image next;
            if (!iir(cur, sigma, use_iir, next, error, nullptr, nullptr)) return false;
            cur = next;
        }
        out = cur;
        return true;
    }
    if (!any_iir) return fir(img, sigma, truncate, use_fir, out, error, acc, weight);
    if (!any_fir) return iir(img, sigma, use_iir, out, error, acc, weight);
    // Mixed FIR / IIR channels: blur fully, then one fused multiply-add.
    Image blurred;
    if (!gaussian(img, sigma, blurred, error, truncate)) return false;
    const double a[3] = {1.0, 1.0, 1.0};
    double b[3];
    broadcast3(weight, b, 1.0);
    return lincomb(*acc, blurred, a, b, out, error);
}

void Blur::exponential_components(const double decay[3], const double weight[3],
                                  std::vector<Component>& out, int n_gaussians) {
    std::vector<std::pair<double, double>> fit;
    exponential_gaussian_fit(n_gaussians, fit);
    out.clear();
    for (const auto& [amplitude, sigma_ratio] : fit) {
        Component comp{};
        for (int c = 0; c < 3; ++c) {
            comp.weight[c] = weight[c] * amplitude;
            comp.sigma[c] = sigma_ratio * decay[c];
        }
        out.push_back(comp);
    }
}

bool Blur::mixture(const Image& img, const std::vector<Component>& components, Image& out,
                   std::string& error, double truncate) {
    bool have_acc = false;
    Image acc;
    for (const Component& comp : components) {
        const bool identity = comp.sigma[0] <= 0.0 && comp.sigma[1] <= 0.0 && comp.sigma[2] <= 0.0;
        if (!have_acc) {
            if (identity) {
                // `G(0)` is the input; the reference still forms
                // `0 * img + weight * img` so the accumulator exists.
                const double a[3] = {0.0, 0.0, 0.0};
                if (!lincomb(img, img, a, comp.weight, acc, error)) return false;
            } else {
                Image zero;
                zero.h = img.h; zero.w = img.w; zero.c = img.c;
                zero.buf = gpu_->alloc_zeroed(img.bytes(), error);
                if (!zero.buf) return false;
                if (!gaussian(img, comp.sigma, acc, error, truncate, &zero, comp.weight)) return false;
            }
            have_acc = true;
        } else {
            Image next;
            if (!gaussian(img, comp.sigma, next, error, truncate, &acc, comp.weight)) return false;
            acc = next;
        }
        // A mixture is where one node holds the most memory: halation's
        // scatter is four components and each IIR pass needs a transpose, a
        // result, and a transpose back. Evaluating between components lets the
        // previous component's scratch be the next one's.
        if (!gpu_->flush(error)) return false;
    }
    if (!have_acc) { error = "blur mixture with no components"; return false; }
    out = acc;
    return true;
}

bool Blur::lincomb(const Image& x, const Image& y, const double a[3], const double b[3],
                   Image& out, std::string& error) {
    const float af[3] = {float(a[0]), float(a[1]), float(a[2])};
    const float bf[3] = {float(b[0]), float(b[1]), float(b[2])};
    gpu::BufferRef ab = gpu_->upload(af, sizeof af, error);
    gpu::BufferRef bb = gpu_->upload(bf, sizeof bf, error);
    if (!ab || !bb) return false;
    if (!alloc_like(x, out, error)) return false;
    const uint32_t n[1] = {uint32_t(x.elements())};
    return gpu_->dispatch("spk_lincomb3",
                          {gpu::Arg::buf(x.buf), gpu::Arg::buf(y.buf), gpu::Arg::buf(ab),
                           gpu::Arg::buf(bb), gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(out.buf)},
                          x.elements(), error);
}

bool Blur::affine(const Image& x, const double s[3], const double t[3], Image& out, std::string& error) {
    const float sf[3] = {float(s[0]), float(s[1]), float(s[2])};
    const float tf[3] = {float(t[0]), float(t[1]), float(t[2])};
    gpu::BufferRef sb = gpu_->upload(sf, sizeof sf, error);
    gpu::BufferRef tb = gpu_->upload(tf, sizeof tf, error);
    if (!sb || !tb) return false;
    if (!alloc_like(x, out, error)) return false;
    const uint32_t n[1] = {uint32_t(x.elements())};
    return gpu_->dispatch("spk_affine3",
                          {gpu::Arg::buf(x.buf), gpu::Arg::buf(sb), gpu::Arg::buf(tb),
                           gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(out.buf)},
                          x.elements(), error);
}

}  // namespace spk
