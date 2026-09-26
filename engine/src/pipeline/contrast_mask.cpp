// contrast_mask.cpp -- RFC-024's virtual contrast mask, the host half.
//
// Kept out of `pipeline.cpp` on purpose: the print path there is untouched
// except for the one branch in `print_spectral` that picks this node instead
// of `node_enlarger_spectral`, the call that prepares it, and the band origin
// the striped executor now records. With the mask off none of this runs and
// the render is the same dispatches with the same arguments as before.
//
// The shape, per print run:
//
//   1. `prepare_contrast_mask` (whole frame, once): reduce the cached
//      negative's image-only paper exposure to a canonical grid of mean `x`
//      (`spk_mask_reduce`), extract a base on the host -- guided filter or
//      Gaussian -- and upload it as per-cell coefficients `(a, b)`.
//   2. `node_contrast_mask_epilogue` (pointwise, band-able): the enlarger's
//      spectral integral, `base = a * x + b`, the bounded curve, and the
//      gain on the image exposure before the pre-flash is added.
//
// **The grid is canonical, not per-tier.** Its long edge is set by the blur
// (`kCellsPerSigma` cells per sigma, at least `kGridMinLongEdge`) in the
// frame's own normalised coordinates, and the spatial scale is a fraction of
// the long edge, so the live tier and the full tier derive the same field
// from their own negatives -- no histogram, no percentile, nothing fitted per
// tier (RFC-024 §8). The exception is a very local scale on a small tier,
// where the grid is capped at the tier's own pixels.
//
// **Crop policy:** the negative this reads is already cropped (geometry runs
// in the film prefix), so the mask is analysed over the visible frame. The
// boundary rule is a truncated, renormalised window at the grid's edge --
// no reflection, no padding value -- for both base extractors.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <dispatch/dispatch.h>

#include "pipeline.hpp"

namespace spk {

namespace {

// The grid follows the blur: `kCellsPerSigma` cells per sigma on the long edge,
// never fewer than `kGridMinLongEdge` and never more than the frame's own
// pixels. A local blur therefore gets a fine grid, so the mask can follow the
// picture's structure rather than blocking it out -- and the grid is still a
// function of the frame's normalised coordinates and the scale, not of the
// tier, except where a small tier caps it at its own resolution.
constexpr double kCellsPerSigma = 4.0;
constexpr uint32_t kGridMinLongEdge = 512;

// Where each branch's amount is read off, in stops beyond its knee: an amount
// of N stops means a base exposure `kReach` stops outside the core is moved N
// stops toward it. Four stops past a one-stop core is five from mid-grey --
// the far end of a print's useful exposure range, where the mask matters.
constexpr double kReach = 4.0;

// The gain limit, in stops, as a smooth bound (RFC-023 §15's fix). The amount
// calibration below inverts it, so N stops at the reach is still N.
constexpr double kGainLimit = 6.0;

// The guided filter's edge threshold: a base variance of (0.5 stop)^2 inside
// the window is where the filter starts treating structure as edge rather
// than texture. In stops of paper exposure, not of the scene.
constexpr double kGuidedEps = 0.25;

// A box mean over a clamped window along one axis, normalised by the count the
// window actually holds -- the frozen boundary rule.
void box_1d(const std::vector<double>& in, std::vector<double>& out, uint32_t w, uint32_t h,
            int r, bool horizontal) {
    out.assign(in.size(), 0.0);
    const uint32_t len = horizontal ? w : h, lines = horizontal ? h : w;
    std::vector<double> prefix(len + 1);
    for (uint32_t line = 0; line < lines; ++line) {
        auto at = [&](uint32_t k) -> size_t {
            return horizontal ? size_t(line) * w + k : size_t(k) * w + line;
        };
        prefix[0] = 0.0;
        for (uint32_t k = 0; k < len; ++k) prefix[k + 1] = prefix[k] + in[at(k)];
        for (uint32_t k = 0; k < len; ++k) {
            const int lo = std::max(0, int(k) - r), hi = std::min(int(len) - 1, int(k) + r);
            out[at(k)] = (prefix[size_t(hi) + 1] - prefix[size_t(lo)]) / double(hi - lo + 1);
        }
    }
}

void box(const std::vector<double>& in, std::vector<double>& out, uint32_t w, uint32_t h, int r) {
    std::vector<double> tmp;
    box_1d(in, tmp, w, h, r, true);
    box_1d(tmp, out, w, h, r, false);
}

// `fn(line)` for every line, across the cores. Each line writes only its own
// outputs and reads only shared inputs, and each output is still accumulated
// in the same order by one thread -- so the result is bit-identical to the
// serial loop; only the wall time changes. Measured on a 45 MP frame at the
// live tier: the serial Gaussian was ~260 ms of a 275 ms reprint at scale
// 0.03 and ~600 of 631 at 0.093.
template <class F>
void for_each_line(uint32_t lines, F&& fn) {
    struct Ctx { F* fn; } ctx{&fn};
    dispatch_apply_f(lines, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), &ctx,
                     [](void* c, size_t line) { (*static_cast<Ctx*>(c)->fn)(uint32_t(line)); });
}

void gaussian(const std::vector<double>& in, std::vector<double>& out, uint32_t w, uint32_t h,
              double sigma) {
    const int r = std::max(1, int(std::ceil(4.0 * sigma)));
    std::vector<double> k(size_t(2 * r + 1));
    for (int i = -r; i <= r; ++i) k[size_t(i + r)] = std::exp(-0.5 * double(i * i) / (sigma * sigma));
    auto pass = [&](const std::vector<double>& src, std::vector<double>& dst, bool horizontal) {
        dst.assign(src.size(), 0.0);
        const uint32_t len = horizontal ? w : h, lines = horizontal ? h : w;
        for_each_line(lines, [&](uint32_t line) {
            for (uint32_t c = 0; c < len; ++c) {
                double acc = 0.0, wsum = 0.0;
                const int lo = std::max(0, int(c) - r), hi = std::min(int(len) - 1, int(c) + r);
                for (int t = lo; t <= hi; ++t) {
                    const double wt = k[size_t(t - int(c) + r)];
                    const size_t idx = horizontal ? size_t(line) * w + size_t(t)
                                                  : size_t(t) * w + line;
                    acc += wt * src[idx];
                    wsum += wt;
                }
                dst[horizontal ? size_t(line) * w + c : size_t(c) * w + line] = acc / wsum;
            }
        });
    };
    std::vector<double> tmp;
    pass(in, tmp, true);
    pass(tmp, out, false);
}

// The branch's room `H` such that, after the gain bound, a base `kReach` stops
// past the knee moves by exactly `amount` stops. Closed form both ways:
// invert the bound (`g_2` with asymptote `kGainLimit`), then solve
// `g_2(kReach, H) = kReach - delta` for `H`.
double room_for(double amount) {
    const double L = kGainLimit, R = kReach;
    const double delta = amount * L / std::sqrt(L * L - amount * amount);
    const double t = std::max(R - delta, 1e-3);   // delta >= R would need H <= 0
    return R * t / std::sqrt(R * R - t * t);
}

}  // namespace

bool Pipeline::contrast_mask_wanted() const {
    const ContrastMaskParams& m = params_.print_render.contrast_mask;
    // RFC-024 §7.5: a directly scanned negative is not printed, and V1 covers
    // ordinary negative-to-paper printing only -- a positive print material or
    // the LUT path gets the unmasked render, not an approximation of a mask.
    return m.active && (m.highlights > 0.0 || m.shadows > 0.0) && !params_.io.scan_film &&
           !params_.print.info.is_positive() && !params_.debug.lut_mode;
}

void Pipeline::release_contrast_mask() {
    mask_on_ = false;
    mask_coef_ = gpu::BufferRef{};
    band_row0_ = 0;
}

bool Pipeline::prepare_contrast_mask(const Image& cmy, std::string& error,
                                     std::vector<float>* delta_out) {
    release_contrast_mask();
    if (!contrast_mask_wanted()) return true;
    if (progress_ && progress_->cancelled) { error = "render cancelled"; return false; }
    if (progress_) progress_->stage = "printing.expose.contrast_mask_analysis";
    const ContrastMaskParams& m = params_.print_render.contrast_mask;

    // A_ref: the negative's own mid-grey through this enlarger, image exposure
    // only -- the same density the setup gain was normalised on, so with the
    // default normalisation its geometric mean is 1 and `x = 0` is mid-grey.
    const PrintConstants& pc = print_constants_;
    const Vec& mid = pc.has_comp ? pc.density_spectral_midgray_comp : pc.density_spectral_midgray;
    double a_ref[3] = {0, 0, 0};
    for (size_t l = 0; l < kNumWavelengths; ++l) {
        const double t = std::pow(10.0, -mid[l]);
        if (!std::isfinite(t)) continue;
        for (int c = 0; c < 3; ++c) a_ref[c] += t * pc.spectral.illum_x_sens[3 * l + size_t(c)];
    }
    for (int c = 0; c < 3; ++c) {
        a_ref[c] *= print_gain_[c];
        if (!(a_ref[c] > 0.0)) { error = "contrast mask: the mid-grey reference exposure is not positive"; return false; }
    }

    const double k_lo = -m.core, k_hi = m.core;
    const float p[16] = {
        float(print_gain_[0]), float(print_gain_[1]), float(print_gain_[2]),
        float(1.0 / a_ref[0]), float(1.0 / a_ref[1]), float(1.0 / a_ref[2]),
        float(print_offset_[0]), float(print_offset_[1]), float(print_offset_[2]),
        float(k_lo), float(m.highlights > 0.0 ? room_for(m.highlights) : 1.0), m.highlights > 0.0 ? 1.0f : 0.0f,
        float(k_hi), float(m.shadows > 0.0 ? room_for(m.shadows) : 1.0), m.shadows > 0.0 ? 1.0f : 0.0f,
        float(kGainLimit)};
    std::memcpy(mask_params_, p, sizeof p);

    // --- the grid ------------------------------------------------------------
    const uint32_t W = cmy.w, H = cmy.h, long_edge = std::max(W, H);
    const uint32_t wanted = std::max(kGridMinLongEdge,
                                     uint32_t(std::ceil(kCellsPerSigma / std::max(m.scale, 1e-4))));
    const uint32_t cells = std::min(wanted, long_edge);
    const uint32_t gw = std::max(1u, uint32_t(std::lround(double(W) * cells / long_edge)));
    const uint32_t gh = std::max(1u, uint32_t(std::lround(double(H) * cells / long_edge)));

    gpu::BufferRef p_buf = gpu_->upload(mask_params_, sizeof mask_params_, error);
    gpu::BufferRef grid = gpu_->alloc(size_t(gw) * gh * sizeof(float), error);
    if (!p_buf || !grid) return false;
    const uint32_t meta[5] = {W, H, gw, gh, uint32_t(kNumWavelengths)};
    if (!gpu_->dispatch("spk_mask_reduce",
                        {gpu::Arg::buf(cmy.buf), gpu::Arg::buf(print_chd_), gpu::Arg::buf(print_base_),
                         gpu::Arg::buf(print_ixs_), gpu::Arg::buf(p_buf),
                         gpu::Arg::inline_bytes(meta, 5), gpu::Arg::buf(grid)},
                        size_t(gw) * gh, error)) return false;
    // The host needs the values: the one flush this node cannot avoid.
    if (!gpu_->flush(error)) return false;
    const float* gx = static_cast<const float*>(gpu_->contents(grid.get()));
    std::vector<double> x(size_t(gw) * gh);
    for (size_t i = 0; i < x.size(); ++i) x[i] = double(gx[i]);

    // --- the base ------------------------------------------------------------
    const double sigma = std::max(0.5, m.scale * double(cells));   // in cells
    std::vector<double> a(x.size(), 0.0), b;
    // The self-guided base is research-only (RFC-024 §12.4, the user's
    // decision of 2026-09-24): at its fixed threshold it counted building
    // texture as edge and greyed the print like the per-pixel arm.
    if (std::getenv("SPEKTRAFILM_MASK_GUIDED")) {
        // He, Sun & Tang's guided filter, self-guided, on the grid. Two box
        // passes of radius r have a standard deviation of ~0.816 r, so r is
        // chosen to match the Gaussian's sigma at the same `scale`.
        const int r = std::max(1, int(std::lround(sigma / 0.816)));
        std::vector<double> mean_x, x2(x.size()), mean_x2;
        for (size_t i = 0; i < x.size(); ++i) x2[i] = x[i] * x[i];
        box(x, mean_x, gw, gh, r);
        box(x2, mean_x2, gw, gh, r);
        std::vector<double> ak(x.size()), bk(x.size());
        for (size_t i = 0; i < x.size(); ++i) {
            const double var = std::max(0.0, mean_x2[i] - mean_x[i] * mean_x[i]);
            ak[i] = var / (var + kGuidedEps);
            bk[i] = mean_x[i] - ak[i] * mean_x[i];
        }
        box(ak, a, gw, gh, r);
        box(bk, b, gw, gh, r);
    } else {
        gaussian(x, b, gw, gh, sigma);
    }

    // RFC-024 §9.1's pointwise comparator, for research only: `a = 1, b = 0`
    // makes the base every pixel's own `x`, i.e. the same curve with no
    // spatial structure. Not on the wire and not a product mode.
    if (std::getenv("SPEKTRAFILM_MASK_POINTWISE")) {
        std::fill(a.begin(), a.end(), 1.0);
        b.assign(x.size(), 0.0);
    }

    std::vector<float> coef(2 * x.size());
    for (size_t i = 0; i < x.size(); ++i) { coef[2 * i] = float(a[i]); coef[2 * i + 1] = float(b[i]); }
    mask_coef_ = gpu_->upload(coef.data(), coef.size() * sizeof(float), error);
    if (!mask_coef_) return false;
    mask_gw_ = gw; mask_gh_ = gh; mask_frame_w_ = W; mask_frame_h_ = H;
    mask_on_ = true;

    // The field at the grid's own cells: RFC-024's delta, in stops, after the
    // gain bound -- what `spk_contrast_mask_field` hands the canvas, and the
    // third plane of the research dump. Computed only when someone asks.
    auto delta_at = [&](size_t i) {
        const double bb = a[i] * x[i] + b[i];
        double d = 0.0;
        if (p[11] != 0.0f && bb < k_lo) { const double D = k_lo - bb; d = D - D * p[10] / std::sqrt(double(p[10]) * p[10] + D * D); }
        else if (p[14] != 0.0f && bb > k_hi) { const double D = bb - k_hi; d = D * p[13] / std::sqrt(double(p[13]) * p[13] + D * D) - D; }
        return float(d * kGainLimit / std::sqrt(kGainLimit * kGainLimit + d * d));
    };
    if (delta_out) {
        delta_out->resize(x.size());
        for (size_t i = 0; i < x.size(); ++i) (*delta_out)[i] = delta_at(i);
    }

    // A research instrument, off unless asked for: the grid's `x`, the base at
    // the grid's own `x`, and the delta there, as three float32 planes.
    if (const char* dump = std::getenv("SPEKTRAFILM_MASK_DUMP")) {
        if (FILE* f = std::fopen(dump, "wb")) {
            const uint32_t dims[2] = {gw, gh};
            std::fwrite(dims, sizeof dims, 1, f);
            std::vector<float> plane(x.size());
            for (size_t i = 0; i < x.size(); ++i) plane[i] = float(x[i]);
            std::fwrite(plane.data(), sizeof(float), plane.size(), f);
            for (size_t i = 0; i < x.size(); ++i) plane[i] = float(a[i] * x[i] + b[i]);
            std::fwrite(plane.data(), sizeof(float), plane.size(), f);
            for (size_t i = 0; i < x.size(); ++i) plane[i] = delta_at(i);
            std::fwrite(plane.data(), sizeof(float), plane.size(), f);
            std::fclose(f);
        }
    }
    if (progress_) progress_->fired += 1;
    return true;
}

bool Pipeline::contrast_mask_field(const Image& cmy, std::vector<float>& delta, uint32_t& gw,
                                   uint32_t& gh, std::string& error) {
    delta.clear();
    gw = gh = 0;
    if (!contrast_mask_wanted()) return true;
    // Only the enlarger's constants, not `print_prefix`: that draws the print
    // side's glare seed, and asking to see the mask must not change the next
    // print's realisation.
    if (!refresh_print_constants(error)) return false;
    Progress* const saved = progress_;
    progress_ = nullptr;
    const bool ok = prepare_contrast_mask(cmy, error, &delta);
    progress_ = saved;
    gw = mask_gw_;
    gh = mask_gh_;
    release_contrast_mask();
    return ok;
}

bool Pipeline::node_contrast_mask_epilogue(const Image& in, Image& out, std::string& error) {
    if (progress_) progress_->stage = "printing.expose.contrast_mask";
    if (!alloc_like(in, out, error)) return false;
    gpu::BufferRef p_buf = gpu_->upload(mask_params_, sizeof mask_params_, error);
    if (!p_buf) return false;
    const uint32_t meta[7] = {uint32_t(in.pixels()), uint32_t(kNumWavelengths), mask_frame_w_,
                              mask_frame_h_, band_row0_, mask_gw_, mask_gh_};
    if (in.w != mask_frame_w_ || band_row0_ + in.h > mask_frame_h_) {
        error = "contrast mask: the band does not lie inside the frame it was analysed on";
        return false;
    }
    const bool ok = gpu_->dispatch("spk_mask_epilogue",
                                   {gpu::Arg::buf(in.buf), gpu::Arg::buf(print_chd_),
                                    gpu::Arg::buf(print_base_), gpu::Arg::buf(print_ixs_),
                                    gpu::Arg::buf(p_buf), gpu::Arg::buf(mask_coef_),
                                    gpu::Arg::inline_bytes(meta, 7), gpu::Arg::buf(out.buf)},
                                   in.pixels(), error);
    if (progress_) progress_->fired += 1;
    return ok;
}

}  // namespace spk
