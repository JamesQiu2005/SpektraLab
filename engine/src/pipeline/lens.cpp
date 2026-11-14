// lens.cpp -- API-SPEC §21.5-§21.6: the lens -- a 柔光镜 (diffusion filter) in front
// of it, then its aberrations -- as **a pass on the source**, before the film
// chain sees it (the owner, 2026-11-10: "the feed-in tiff already carries the
// lens effects"). `lens_source` runs on a tier's source image, once, and the
// session keeps the lensed copy per tier keyed by the lens's fields and the
// pitch (`engine.cpp`, `tier_image`); every develop, reprint, meter and band
// reads that copy, so the film side, its bands and its reach are what they are
// with the lens off.
//
//   1. The filter (§21.5): the oracle's PSF (`core/diffusion_psf`,
//      `spektrafilm/model/diffusion.py`) on a **Gaussian-pyramid basis** -- the
//      scatter source S taken down level by level and brought back up coarse
//      to fine, each level weighted, plus an 11 x 11 core FIR on S for the
//      exponentials' cusps: out = c_id E + core * S + up(A_1). The level
//      weights are a non-negative least-squares fit of the levels' measured
//      line-spread functions to the PSF's, the mass held; the core is the PSF
//      in two dimensions less the levels' response there
//      (`lens_pyramid_fit`), both made on the host per setting and pitch.
//      Levels fp16, a third of a plane; 29 ms at 48 MP on the M3 Max, where
//      the exact path (kept as the tests' reference, `lens_filter_exact`) was
//      twenty-odd full-resolution Gaussians, 253 ms.
//      **The filters are the binomial [1 5 10 10 5 1] / 32 and its transpose,
//      not the tent [1 3 3 1] / 8 and bilinear**: the tent pair's
//      response moves with a point's phase on a level's grid by 11-15 % of
//      the level's peak, the binomial's by 2-4 % (measured), and next to a
//      lamp that was 4,000 codes of error against 400.
//   2. The spherical glow (§21.6), its own pass (`lens_glow_fast`): a Gaussian
//      on one level of the frame's pyramid.
//   3. The aberrations (§21.6), in chunks of rows with
//      their reach: lateral CA (radial resample with the Jacobian), the LoCA
//      stand-in, field curvature + astigmatism + coma as two directional
//      gathers on a small mip pyramid.
//
// **Where.** On the source as handed in, before `decode_input` and
// `geometry`: the axis is the source frame's centre, h its half-diagonal, so a
// crop cannot move it. In linear light: an encoded input
// (`input_cctf_decoding`) is decoded, lensed and encoded again. The pitch is
// `fix_film_pitch`'s at the image's long edge (the format's gate under
// overscan), so every tier shows the same lens.
//
// **Chunks and strips** (2026-11-11): the engine has no RFC-035 band context,
// so the aberrations' chunks carry their own (`lens_chunk_`, `LensChunk`). The
// hook is one function: `tier_image` in `engine.cpp` hands every develop,
// reprint, meter and RFC-020 strip the lensed copy, so a striped render reads
// the lensed source as a whole one does (`lens_checks.py`, the strips cases).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>

#include "diffusion_psf.hpp"
#include "pipeline.hpp"
#include "timer.hpp"

namespace spk {

namespace {

constexpr double kMinLowSigma = 3.0;            // the coarse grid's lowest sigma (the exact path)
constexpr uint32_t kFieldFactor = 4;            // the exact path's coarse grid
constexpr double kMinEffectiveSigma = 0.4;      // `kMinEffectiveBlurSigma`
constexpr double kMid = 0.184;                  // mid grey (the LoCA gate's scale)
constexpr int kMaxLevel = 4;                    // the gathers' mip pyramid: 1 .. 16 px texels
constexpr double kLensReachSigmas = 7.0;        // an IIR blur's reach across a chunk edge
constexpr double kLineTruncate = 3.5;           // the gathers' Gaussian support, in sigmas
constexpr uint32_t kChunkRows = 512;            // the aberrations' rows per chunk, before their reach
constexpr int kMaxPyramidLevels = 14;           // the filter's pyramid: up to 8,192 px bumps
constexpr double kMinLevelPx = 3.0;             // its coarsest level's short side, at least
// The filter's core, an 11 x 11 FIR on the source: the exponentials' cusps,
// which no pyramid level is narrow enough for, and in place of level 1, whose
// response moves with a point's phase on its grid (4 % of its peak, next to a
// lamp the largest error left). The pyramid starts at level 2. Measured on the
// parity image against the PSF integrated over each pixel's cell: R = 2 from
// level 1, max 863 codes; R = 4 from level 2, 886; R = 5 from level 2, 424
// (the exact path: 1,030). R = 5 costs 15 ms of the filter's 29 at 48 MP.
constexpr int kMaxCoreRadius = 5;               // `spk_lens_pyr_out`'s threadgroup tile
constexpr int kCoreRadius = 5;
constexpr int kCoreLevel = 2;

double tent_variance(uint32_t f) {
    const double c = 0.5 * double(f - 1);
    double sw = 0.0, swd2 = 0.0;
    for (int p = -int(f); p < 2 * int(f); ++p) {
        const double d = double(p) - c;
        const double w = std::max(0.0, 1.0 - std::fabs(d) / double(f));
        sw += w;
        swd2 += w * d * d;
    }
    return swd2 / sw;
}

double narrowest(const Blur::Component& comp) {
    double s = 1e300;
    for (int c = 0; c < 3; ++c)
        if (comp.weight[c] != 0.0) s = std::min(s, comp.sigma[c]);
    return s;
}

double field_sigma_min() {
    const double f = double(kFieldFactor);
    return std::sqrt(kMinLowSigma * kMinLowSigma * f * f + 2.0 * tent_variance(kFieldFactor));
}

std::vector<Blur::Component> on_grid(const std::vector<Blur::Component>& comps, uint32_t f) {
    const double v2 = 2.0 * tent_variance(f);
    std::vector<Blur::Component> out;
    for (const Blur::Component& comp : comps) {
        Blur::Component lc = comp;
        for (int c = 0; c < 3; ++c) {
            const double s2 = comp.sigma[c] * comp.sigma[c] - v2;
            lc.sigma[c] = s2 > 0.0 ? std::sqrt(s2) / double(f) : 1e-6;
        }
        out.push_back(lc);
    }
    return out;
}

double reach_of(double sigma, double kreach) {
    if (!(sigma > 0.0)) return 0.0;
    return Blur::is_fir(sigma) ? double(Blur::fir_radius(sigma)) : kreach * sigma;
}

// The fits, kept for the process: a slider's drag refits once per value, and a
// tier change at one value refits for its pitch.
struct FitCache {
    std::mutex lock;
    std::unordered_map<std::string, diffusion::PyramidFit> fits;
};
FitCache& fit_cache() {
    // Never destroyed: a render may still be fitting while a quit's `exit()` tears the statics down (colour.cpp).
    static FitCache& c = *new FitCache;
    return c;
}

}  // namespace

// ---------------------------------------------------------------------------
// the frame: where the axis is, and the pitch
// ---------------------------------------------------------------------------

uint32_t Pipeline::lens_chunk_rows() const {
    return lens_chunk_rows_ ? lens_chunk_rows_ : kChunkRows;
}

bool Pipeline::film_lens_wanted() const {
    return params_.camera.diffusion_filter.active || params_.camera.lens_aberrations.active;
}

// The source frame's centre and half-diagonal in the image a pass is handed: a
// chunk of rows of the frame (`lens_chunk_` set by `lens_aberrate_frame`) or the
// whole of it.
Pipeline::LensGeom Pipeline::lens_geom(const Image& in) const {
    LensGeom G;
    uint32_t fw = in.w, fh = in.h;
    if (lens_chunk_.active) { fw = lens_chunk_.frame_w; fh = lens_chunk_.frame_h; G.row0 = lens_chunk_.row0; }
    G.plane_h = fh;
    G.pcx = 0.5 * (double(fw) - 1.0);
    G.pcy = 0.5 * (double(fh) - 1.0);
    G.hd = 0.5 * std::hypot(double(fw), double(fh));
    G.um_per_px = lens_um_per_px_;
    return G;
}

// ---------------------------------------------------------------------------
// the PSF: the filter's, with the glow composed in
// ---------------------------------------------------------------------------

bool Pipeline::diffusion_components(double um_per_px, double& p_s, std::vector<Blur::Component>& comps,
                                    std::string& error) const {
    comps.clear();
    diffusion::Psf psf;
    if (!diffusion::build_psf(params_.camera.diffusion_filter, psf, error)) return false;
    p_s = psf.p_s;
    if (!(p_s > 0.0) || !(um_per_px > 0.0)) { p_s = 0.0; return true; }
    for (const diffusion::Exponential& e : psf.exps) {
        const double lk = std::max(e.lambda_um / um_per_px, 1e-6);
        const double decay[3] = {lk, lk, lk};
        std::vector<Blur::Component> three;
        Blur::exponential_components(decay, e.weight, three);
        comps.insert(comps.end(), three.begin(), three.end());
    }
    for (int c = 0; c < 3; ++c) {
        double sum = 0.0;
        for (const Blur::Component& comp : comps) sum += comp.weight[c];
        if (sum > 0.0)
            for (Blur::Component& comp : comps) comp.weight[c] /= sum;
    }
    return true;
}

// **The filter and the spherical glow, one PSF.** Both are shift-invariant
// convolutions of the light (the filter in front of the lens, the glow in it),
// so they commute and compose exactly: with the filter (1 - p) E + p K * E and
// the glow (1 - w) X + w G * X,
//
//     glow(filter(E)) = (1 - w)(1 - p) E + (1 - w) p K * E + w (1 - p) G * E + w p (K * G) * E.
//
// The glow is a Gaussian of sigma R / 2 (a disc of radius R's second moment).
bool Pipeline::lens_glow(double um_per_px, double& w, double& sigma) const {
    const LensAberrationParams& la = params_.camera.lens_aberrations;
    w = 0.0; sigma = 0.0;
    if (!la.active || !(um_per_px > 0.0)) return false;
    w = std::clamp(la.spherical_amount, 0.0, 1.0);
    sigma = 0.5 * la.spherical_um / um_per_px;
    if (!(w > 0.0) || !(sigma >= kMinEffectiveSigma)) { w = 0.0; return false; }
    return true;
}

// The exact path's mixture (the tests' reference): every exponential as
// `Blur`'s three Gaussians, K * G as Gaussians widened by G.
bool Pipeline::lens_mixture_now(double um_per_px, double a[3], std::vector<Blur::Component>& comps,
                                std::string& error) const {
    comps.clear();
    a[0] = a[1] = a[2] = 1.0;
    double p = 0.0;
    std::vector<Blur::Component> K;
    if (params_.camera.diffusion_filter.active && !diffusion_components(um_per_px, p, K, error)) return false;
    double w = 0.0, sg = 0.0;
    lens_glow(um_per_px, w, sg);
    if (!(p > 0.0)) { p = 0.0; K.clear(); }
    if (p == 0.0 && w == 0.0) return true;
    a[0] = a[1] = a[2] = (1.0 - w) * (1.0 - p);
    for (Blur::Component k : K) {
        for (int c = 0; c < 3; ++c) k.weight[c] *= (1.0 - w) * p;
        comps.push_back(k);
    }
    if (w > 0.0) {
        comps.push_back(Blur::Component{{w * (1.0 - p), w * (1.0 - p), w * (1.0 - p)}, {sg, sg, sg}});
        for (Blur::Component k : K) {
            for (int c = 0; c < 3; ++c) {
                k.weight[c] *= w * p;
                k.sigma[c] = std::sqrt(k.sigma[c] * k.sigma[c] + sg * sg);
            }
            comps.push_back(k);
        }
    }
    return true;
}

// The pyramid's weights for this setting at this pitch: the target is the
// filter's line-spread function, exactly (each exponential's LSF over each
// pixel's cell), not the exact path's surrogates. The glow is its own pass
// (`lens_glow_fast`): a Gaussian is the one PSF octave-spaced levels fit badly.
bool Pipeline::lens_pyramid_fit(double um_per_px, uint32_t w, uint32_t h, double a_id[3],
                                diffusion::PyramidFit& fit, std::string& error) const {
    a_id[0] = a_id[1] = a_id[2] = 1.0;
    fit = diffusion::PyramidFit{};
    if (!params_.camera.diffusion_filter.active || !(um_per_px > 0.0)) return true;
    diffusion::Psf psf;
    if (!diffusion::build_psf(params_.camera.diffusion_filter, psf, error)) return false;
    const double p = psf.p_s;
    if (!(p > 0.0)) return true;
    for (int c = 0; c < 3; ++c) a_id[c] = 1.0 - p;
    // The coarsest level at least kMinLevelPx across its short side, the same
    // fraction of the frame on every tier. The levels' edges keep light only
    // nearly: a level of odd size puts half its last sample past the frame,
    // and its replicated edge counts the last pixel 21/32 for 16/32 -- so a
    // bump that reaches the frame's edge gains or loses a little there. On a
    // bloom the frame's size (cinebloom on a 13 mm crop) the widest level is
    // what carries the tail; one fewer moves 3 % of the light inside 400 px
    // (encircled energy against the analytic profile, 0.035 for 0.003), one
    // more loses 2e-4 of a centred lamp at the edges (5e-5 with 7 levels on
    // 1,201 px).
    const int max_levels = std::min(
        kMaxPyramidLevels,
        std::max(0, int(std::floor(std::log2(double(std::min(w, h)) / double(kMinLevelPx))))));
    char key[512];
    const DiffusionFilterParams& d = params_.camera.diffusion_filter;
    std::snprintf(key, sizeof key, "%.9g|%u|%u|%d|%s|%.9g|%.9g|%.9g|%.9g|%.9g|%.9g|%.9g|%.9g|%.9g", um_per_px, w, h,
                  max_levels, d.filter_family.c_str(), d.strength, d.spatial_scale, d.halo_warmth, d.core_intensity,
                  d.core_size, d.halo_intensity, d.halo_size, d.bloom_intensity, d.bloom_size);
    const std::string k = key;
    {
        std::lock_guard<std::mutex> guard(fit_cache().lock);
        auto it = fit_cache().fits.find(k);
        if (it != fit_cache().fits.end()) { fit = it->second; return true; }
    }
    // The target's reach: ten of the widest exponential.
    double lmax = 0.0;
    for (const diffusion::Exponential& e : psf.exps) lmax = std::max(lmax, e.lambda_um / um_per_px);
    const int cap = int(4 * std::max(w, h));
    const int X = std::clamp(int(std::ceil(10.0 * lmax)) + 4, 8, std::max(cap, 8));
    std::vector<double> target[3];
    for (int c = 0; c < 3; ++c) {
        std::vector<double>& t = target[c];
        t.assign(size_t(X + 1), 0.0);
        for (const diffusion::Exponential& e : psf.exps) {
            const double l = e.lambda_um / um_per_px;
            for (int x = 0; x <= X; ++x) t[size_t(x)] += p * e.weight[c] * diffusion::exp_lsf_cell(x, l);
        }
    }
    // The core's target: the PSF in two dimensions over the FIR's window, the
    // exponentials by their cells. One octant (0 <= dy <= dx), mirrored: the
    // PSF is radial.
    const int R = kCoreRadius, D = 2 * R + 1;
    std::vector<std::array<double, 3>> T2(size_t(D * D), {0.0, 0.0, 0.0});
    for (int dy = 0; dy <= R; ++dy)
        for (int dx = dy; dx <= R; ++dx) {
            std::array<double, 3> t{0.0, 0.0, 0.0};
            for (const diffusion::Exponential& e : psf.exps) {
                const double ec = diffusion::exp_cell_2d(dx, dy, e.lambda_um / um_per_px);
                for (int c = 0; c < 3; ++c) t[size_t(c)] += p * e.weight[c] * ec;
            }
            for (int sy : {-1, 1})
                for (int sx : {-1, 1}) {
                    T2[size_t((sy * dy + R) * D + sx * dx + R)] = t;
                    T2[size_t((sx * dx + R) * D + sy * dy + R)] = t;
                }
        }
    // The mass the pyramid and the core must carry: all of the scattered
    // light, exactly (not the target's, which stops at its reach), held in
    // the fit: sum_k a_k (1 - m_k) = M - T_window, m_k the share of level k's
    // response inside the window (the core takes the rest of it there). So
    // light the levels cannot carry as far as the PSF does goes to the
    // widest of them, not to the centre.
    diffusion::MassHold hold;
    for (int c = 0; c < 3; ++c) {
        double wsum = 0.0;
        for (const diffusion::Exponential& e : psf.exps) wsum += e.weight[c];
        const double M = p * wsum;
        double tw = 0.0;
        for (const std::array<double, 3>& t : T2) tw += t[size_t(c)];
        hold.value[c] = M - tw;
        hold.total[c] = M;
    }
    hold.inside.assign(size_t(kMaxPyramidLevels + 1), 0.0);
    for (int kk = 1; kk <= kMaxPyramidLevels; ++kk) {
        const std::vector<double>& B = diffusion::pyramid_basis(kk);
        double s1 = 0.0;
        for (int x = -R; x <= R; ++x) s1 += size_t(std::abs(x)) < B.size() ? B[size_t(std::abs(x))] : 0.0;
        hold.inside[size_t(kk)] = s1 * s1;
    }
    diffusion::fit_pyramid(target, max_levels, fit, kCoreLevel, R + 1, &hold);
    // The core: the target less what the pyramid puts in the window
    // (phase-averaged), its centre taking what is left of the mass.
    fit.fir_r = R;
    fit.fir.assign(size_t(D * D), {0.0, 0.0, 0.0});
    for (int dy = -R; dy <= R; ++dy)
        for (int dx = -R; dx <= R; ++dx)
            for (int c = 0; c < 3; ++c)
                fit.fir[size_t((dy + R) * D + dx + R)][size_t(c)] =
                    T2[size_t((dy + R) * D + dx + R)][size_t(c)] - diffusion::pyramid_response_2d(fit, c, dx, dy);
    for (int c = 0; c < 3; ++c) {
        double have = 0.0;
        for (int kk = 1; kk <= fit.levels; ++kk) have += fit.a[size_t(kk)][size_t(c)];
        for (const std::array<double, 3>& f : fit.fir) have += f[size_t(c)];
        fit.fir[size_t(R * D + R)][size_t(c)] += hold.total[c] - have;
    }
    std::lock_guard<std::mutex> guard(fit_cache().lock);
    fit_cache().fits[k] = fit;
    return true;
}

// ---------------------------------------------------------------------------
// the filter, fast: the pyramid
// ---------------------------------------------------------------------------

bool Pipeline::lens_scatter_source(const Image& E, float bp[5], std::string& error) {
    // `node_boost`'s lift on the light the filter scatters, so a clipped lamp
    // glows as the film side's highlight reconstruction would have it: the
    // frame's maximum, the protected level at mid grey x 2^protect_ev brought
    // to the source by the exposure compensation (auto exposure's EV is not
    // known before the meter reads the lensed frame). The unscattered light is
    // the source as it was. Off (the app never sends `halation_boost_ev`) it
    // is the source itself.
    for (int i = 0; i < 5; ++i) bp[i] = 0.0f;
    const HalationParams& hal = params_.film_render.halation;
    if (hal.boost_ev == 0.0) return true;
    double mx = 0.0;
    if (!device_max(E, mx, error)) return false;
    if (!(mx > 0.0)) return true;
    const double gain = std::pow(2.0, params_.camera.exposure_compensation_ev);
    const double x0 = std::min(std::max(kMid * std::pow(2.0, hal.protect_ev) / gain, 0.0), mx);
    if (x0 >= mx) return true;
    const double a = std::pow(28.0, 1.0 - hal.boost_range);
    const double xn = x0 / mx;
    const double denom = std::exp(a * (1.0 - xn)) - a * (1.0 - xn) - 1.0;
    if (denom <= 0.0) return true;
    const double kk = (std::pow(2.0, hal.boost_ev) - 1.0) / denom;
    bp[0] = 1.0f; bp[1] = float(x0); bp[2] = float(1.0 / mx); bp[3] = float(a); bp[4] = float(kk * mx);
    return true;
}

bool Pipeline::lens_filter_fast(const Image& E, Image& out, std::string& error) {
    double a_id[3];
    diffusion::PyramidFit fit;
    if (!lens_pyramid_fit(lens_um_per_px_, E.w, E.h, a_id, fit, error)) return false;
    if (fit.a.empty()) return true;
    float bp[5];
    if (!lens_scatter_source(E, bp, error)) return false;
    gpu::BufferRef bp_buf = gpu_->upload(bp, sizeof bp, error);
    if (!bp_buf) return false;
    // The levels, fp16, outside the pool at their own sizes (the pool hands a
    // request the smallest free buffer that fits: a quarter-plane level took a
    // whole plane, measured on the bands). At least one, so the combine has
    // its A_1.
    const int K = std::max(fit.levels, 1);
    auto weight = [&](int k, int c) { return k < int(fit.a.size()) ? fit.a[size_t(k)][size_t(c)] : 0.0; };
    std::vector<Image> L(size_t(K + 1));
    L[0] = E;
    for (int k = 1; k <= K; ++k) {
        const Image& in = L[size_t(k - 1)];
        Image& o = L[size_t(k)];
        o.h = (in.h + 1) / 2; o.w = (in.w + 1) / 2; o.c = 3;
        o.buf = gpu_->alloc_persistent(size_t(o.h) * o.w * 3u * 2u, error);
        if (!o.buf) return false;
        const uint32_t meta[4] = {in.h, in.w, o.h, o.w};
        const bool ok = k == 1
            ? gpu_->dispatch("spk_lens_pyr_down0", {gpu::Arg::buf(in.buf), gpu::Arg::buf(bp_buf),
                                                    gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(o.buf)},
                             o.pixels(), error)
            : gpu_->dispatch("spk_lens_pyr_down", {gpu::Arg::buf(in.buf), gpu::Arg::inline_bytes(meta, 4),
                                                   gpu::Arg::buf(o.buf)}, o.pixels(), error);
        if (!ok) return false;
    }
    for (int k = K; k >= 1; --k) {
        const float a[3] = {float(weight(k, 0)), float(weight(k, 1)), float(weight(k, 2))};
        const bool has = k < K;
        const Image& c = has ? L[size_t(k + 1)] : L[size_t(k)];
        const uint32_t meta[5] = {L[size_t(k)].h, L[size_t(k)].w, c.h, c.w, has ? 1u : 0u};
        if (!gpu_->dispatch("spk_lens_pyr_up",
                            {gpu::Arg::buf(L[size_t(k)].buf), gpu::Arg::buf(c.buf), gpu::Arg::inline_bytes(a, 3),
                             gpu::Arg::inline_bytes(meta, 5)}, L[size_t(k)].pixels(), error)) return false;
    }
    // The combine: c_id E + the core on S + up(A_1). Without the boost S is E
    // and the identity goes into the core's centre tap.
    // The identity (and a[0] without the boost: S is E) on E in fp32; the core
    // on S. The core is symmetric in x, y and their swap (a radial PSF less a
    // product of symmetric levels): the kernel takes one quadrant, (R + 1)^2.
    const int R = std::min(fit.fir_r, kMaxCoreRadius), D = 2 * fit.fir_r + 1, Q = R + 1;
    std::vector<float> taps(size_t(Q * Q) * 3u + 3u, 0.0f);
    for (int c = 0; c < 3; ++c) taps[size_t(c)] = float(a_id[c] + (bp[0] != 0.0f ? 0.0 : weight(0, c)));
    for (int dy = 0; dy <= R; ++dy)
        for (int dx = 0; dx <= R; ++dx)
            for (int c = 0; c < 3; ++c) {
                const size_t t = size_t((dy + fit.fir_r) * D + dx + fit.fir_r);
                double v = t < fit.fir.size() ? fit.fir[t][size_t(c)] : 0.0;
                if (dx == 0 && dy == 0 && bp[0] != 0.0f) v += weight(0, c);
                taps[3u + size_t(dy * Q + dx) * 3u + size_t(c)] = float(v);
            }
    gpu::BufferRef taps_buf = gpu_->upload(taps.data(), taps.size() * sizeof(float), error);
    if (!taps_buf) return false;
    auto combine = [&](uint32_t row0, uint32_t n, const gpu::BufferRef& dst) {
        const uint32_t meta[7] = {E.h, E.w, L[1].h, L[1].w, uint32_t(R), row0, n};
        const size_t tiles = ((size_t(E.w) + 31) / 32) * ((size_t(n) + 7) / 8);
        return gpu_->dispatch("spk_lens_pyr_out",
                              {gpu::Arg::buf(E.buf), gpu::Arg::buf(L[1].buf), gpu::Arg::buf(taps_buf),
                               gpu::Arg::buf(bp_buf), gpu::Arg::inline_bytes(meta, 7), gpu::Arg::buf(dst)},
                              tiles * 256u, error);
    };
    if (out.buf.get() != E.buf.get()) {
        if (!combine(0, E.h, out.buf)) return false;
    } else {
        // In place (an encoded source, decoded into the pass's one frame): in
        // bands, each written back once the band below it has read its last
        // rows -- two band buffers, not a second frame.
        // A multiple of 8 (the combine's tiles start on even rows).
        const uint32_t rows = (std::max<uint32_t>(lens_chunk_rows(), uint32_t(R)) + 7u) & ~7u;
        Image tmp[2];
        uint32_t pending_row = 0, pending_n = 0;
        int which = 0;
        auto put_back = [&](const Image& t, uint32_t row, uint32_t n) {
            const uint32_t pm[4] = {E.w, 0u, row, n * E.w * 3u};
            return gpu_->dispatch("spk_lens_rows_put", {gpu::Arg::buf(t.buf), gpu::Arg::inline_bytes(pm, 4),
                                                        gpu::Arg::buf(E.buf)}, size_t(n) * E.w * 3u, error);
        };
        for (uint32_t y0 = 0; y0 < E.h; y0 += rows) {
            const uint32_t n = std::min(rows, E.h - y0);
            Image& t = tmp[which];
            if (!t.buf) {
                t.h = rows; t.w = E.w; t.c = 3;
                t.buf = gpu_->alloc_persistent(t.bytes(), error);
                if (!t.buf) return false;
            }
            if (!combine(y0, n, t.buf)) return false;
            if (pending_n && !put_back(tmp[1 - which], pending_row, pending_n)) return false;
            pending_row = y0; pending_n = n;
            which = 1 - which;
        }
        if (pending_n && !put_back(tmp[1 - which], pending_row, pending_n)) return false;
    }
    return gpu_->flush(error);   // the levels go with this scope
}

// The spherical glow, (1 - w) X + w G * X with G a Gaussian of sigma = R / 2:
// on level k of X's pyramid (2^k <= sigma / 3), a separable Gaussian of the
// sigma left there once the pyramid's own response (its down and up,
// `pyramid_basis`) is taken out, brought back up the levels. Octave-spaced
// levels fit a single Gaussian badly (17 % of its peak at sigma 12 px, as the
// filter's fit; the filter's exponentials are a smooth spread of widths and
// fit well); this is one level's bump widened by a Gaussian. `out` may be X.
bool Pipeline::lens_glow_fast(const Image& X, Image& out, std::string& error) {
    double gw = 0.0, sg = 0.0;
    if (!lens_glow(lens_um_per_px_, gw, sg)) return true;
    int kmax = 1;
    while (kmax < kMaxPyramidLevels && (std::min(X.w, X.h) >> (kmax + 1)) >= 4u) ++kmax;
    const int k = std::clamp(int(std::floor(std::log2(sg / 3.0))), 1, kmax);
    const std::vector<double>& B = diffusion::pyramid_basis(k);
    double var = 0.0;
    for (size_t d = 1; d < B.size(); ++d) var += 2.0 * double(d * d) * B[d];
    const double s2 = (sg * sg - var) / double(1u << (2 * k));
    const double sk = s2 > 0.0 ? std::sqrt(s2) : 0.0;
    const int r = sk > 0.0 ? int(std::ceil(3.5 * sk)) : 0;
    std::vector<float> taps(size_t(r + 1), 0.0f), taps_w(size_t(r + 1), 0.0f);
    {
        double sum = 0.0;
        std::vector<double> t(size_t(r + 1));
        for (int i = 0; i <= r; ++i) { t[size_t(i)] = sk > 0.0 ? diffusion::gauss_lsf_cell(i, sk) : 1.0; sum += (i ? 2.0 : 1.0) * t[size_t(i)]; }
        for (int i = 0; i <= r; ++i) {
            taps[size_t(i)] = float(t[size_t(i)] / sum);
            taps_w[size_t(i)] = float(gw * t[size_t(i)] / sum);   // the second pass carries w
        }
    }
    gpu::BufferRef taps_buf = gpu_->upload(taps.data(), taps.size() * sizeof(float), error);
    gpu::BufferRef taps_w_buf = gpu_->upload(taps_w.data(), taps_w.size() * sizeof(float), error);
    const float off[5] = {0, 0, 0, 0, 0};
    gpu::BufferRef off_buf = gpu_->upload(off, sizeof off, error);
    if (!taps_buf || !taps_w_buf || !off_buf) return false;
    std::vector<Image> L(size_t(k + 1));
    L[0] = X;
    for (int j = 1; j <= k; ++j) {
        const Image& in = L[size_t(j - 1)];
        Image& o = L[size_t(j)];
        o.h = (in.h + 1) / 2; o.w = (in.w + 1) / 2; o.c = 3;
        o.buf = gpu_->alloc_persistent(size_t(o.h) * o.w * 3u * 2u, error);
        if (!o.buf) return false;
        const uint32_t meta[4] = {in.h, in.w, o.h, o.w};
        const bool ok = j == 1
            ? gpu_->dispatch("spk_lens_pyr_down0", {gpu::Arg::buf(in.buf), gpu::Arg::buf(off_buf),
                                                    gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(o.buf)},
                             o.pixels(), error)
            : gpu_->dispatch("spk_lens_pyr_down", {gpu::Arg::buf(in.buf), gpu::Arg::inline_bytes(meta, 4),
                                                   gpu::Arg::buf(o.buf)}, o.pixels(), error);
        if (!ok) return false;
    }
    {   // the Gaussian on level k, rows then columns, w folded into the second's taps
        const Image& Lk = L[size_t(k)];
        Image t;
        t.h = Lk.h; t.w = Lk.w; t.c = 3;
        t.buf = gpu_->alloc_persistent(size_t(t.h) * t.w * 3u * 2u, error);
        if (!t.buf) return false;
        const uint32_t m0[4] = {Lk.h, Lk.w, uint32_t(r), 0u}, m1[4] = {Lk.h, Lk.w, uint32_t(r), 1u};
        if (!gpu_->dispatch("spk_lens_gauss_1d", {gpu::Arg::buf(Lk.buf), gpu::Arg::buf(taps_buf),
                                                  gpu::Arg::inline_bytes(m0, 4), gpu::Arg::buf(t.buf)},
                            Lk.pixels(), error) ||
            !gpu_->dispatch("spk_lens_gauss_1d", {gpu::Arg::buf(t.buf), gpu::Arg::buf(taps_w_buf),
                                                  gpu::Arg::inline_bytes(m1, 4), gpu::Arg::buf(Lk.buf)},
                            Lk.pixels(), error)) return false;
    }
    const float zero[3] = {0.0f, 0.0f, 0.0f};
    for (int j = k - 1; j >= 1; --j) {   // A_j = up(A_{j+1})
        const uint32_t meta[5] = {L[size_t(j)].h, L[size_t(j)].w, L[size_t(j + 1)].h, L[size_t(j + 1)].w, 1u};
        if (!gpu_->dispatch("spk_lens_pyr_up",
                            {gpu::Arg::buf(L[size_t(j)].buf), gpu::Arg::buf(L[size_t(j + 1)].buf),
                             gpu::Arg::inline_bytes(zero, 3), gpu::Arg::inline_bytes(meta, 5)},
                            L[size_t(j)].pixels(), error)) return false;
    }
    // (1 - w) X + up(A_1): the combine with no core, pointwise (so in place).
    const float c[6] = {float(1.0 - gw), float(1.0 - gw), float(1.0 - gw), 0.0f, 0.0f, 0.0f};
    gpu::BufferRef c_buf = gpu_->upload(c, sizeof c, error);
    if (!c_buf) return false;
    const uint32_t meta[7] = {X.h, X.w, L[1].h, L[1].w, 0u, 0u, X.h};
    const size_t tiles = ((size_t(X.w) + 31) / 32) * ((size_t(X.h) + 7) / 8);
    if (!gpu_->dispatch("spk_lens_pyr_out",
                        {gpu::Arg::buf(X.buf), gpu::Arg::buf(L[1].buf), gpu::Arg::buf(c_buf), gpu::Arg::buf(off_buf),
                         gpu::Arg::inline_bytes(meta, 7), gpu::Arg::buf(out.buf)}, tiles * 256u, error))
        return false;
    return gpu_->flush(error);   // the levels go with this scope
}

// ---------------------------------------------------------------------------
// the filter, exactly: the tests' reference (the 2026-11-09 path, whole image)
// ---------------------------------------------------------------------------

bool Pipeline::lens_filter_exact(const Image& raw, Image& out, std::string& error) {
    const LensGeom G = lens_geom(raw);
    double a[3];
    std::vector<Blur::Component> comps;
    if (!lens_mixture_now(G.um_per_px, a, comps, error)) return false;
    if (comps.empty()) { out = raw; return true; }
    std::vector<Blur::Component> fine, broad;
    const double s_field = field_sigma_min();
    for (const Blur::Component& comp : comps) (narrowest(comp) >= s_field ? broad : fine).push_back(comp);
    Image field;
    if (!broad.empty()) {
        Image low;
        low.h = (raw.h + kFieldFactor - 1) / kFieldFactor; low.w = (raw.w + kFieldFactor - 1) / kFieldFactor; low.c = 3;
        low.buf = gpu_->alloc(low.bytes(), error);
        if (!low.buf) return false;
        const uint32_t smeta[9] = {raw.h, raw.w, 0u, raw.h, low.w, 0u, low.h, kFieldFactor, 0u};
        if (!gpu_->dispatch("spk_lens_splat",
                            {gpu::Arg::buf(raw.buf), gpu::Arg::inline_bytes(smeta, 9), gpu::Arg::buf(low.buf)},
                            low.pixels(), error)) return false;
        if (!blur_.mixture(low, on_grid(broad, kFieldFactor), field, error)) return false;
    }
    const float ab[6] = {float(a[0]), float(a[1]), float(a[2]), 1.0f, 1.0f, 1.0f};
    gpu::BufferRef ab_buf = gpu_->upload(ab, sizeof ab, error);
    Image acc;
    if (!ab_buf || !alloc_like(raw, acc, error)) return false;
    const uint32_t meta[12] = {raw.h, raw.w, 0u, 0u, 0u, 0u, 0u, 0u,
                               field.buf ? kFieldFactor : 0u, 0u, field.buf ? field.h : 0u, field.buf ? field.w : 0u};
    if (!gpu_->dispatch("spk_lens_mix",
                        {gpu::Arg::buf(raw.buf), gpu::Arg::buf(raw.buf), gpu::Arg::buf(raw.buf),
                         gpu::Arg::buf(field.buf ? field.buf : raw.buf), gpu::Arg::buf(ab_buf),
                         gpu::Arg::inline_bytes(meta, 12), gpu::Arg::buf(acc.buf)},
                        raw.pixels(), error)) return false;
    for (const Blur::Component& comp : fine) {
        Image next;
        if (!blur_.gaussian(raw, comp.sigma, next, error, 3.0, &acc, comp.weight)) return false;
        acc = next;
        if (!gpu_->flush(error)) return false;
    }
    out = acc;
    return true;
}

// ---------------------------------------------------------------------------
// the aberrations
// ---------------------------------------------------------------------------

Pipeline::LensFieldPx Pipeline::lens_field_px(double um_per_px) const {
    const LensAberrationParams& la = params_.camera.lens_aberrations;
    LensFieldPx F;
    if (!la.active || !(um_per_px > 0.0)) return F;
    F.sfc = la.field_curvature_um / um_per_px;
    F.sast = la.astigmatism_um / um_per_px;
    F.coma = la.coma_um / um_per_px;
    const double L = std::fabs(F.coma);
    F.var_t1 = F.sfc * F.sfc + (F.sast > 0 ? F.sast * F.sast : 0.0) + L * L / 54.0;
    F.var_r1 = F.sfc * F.sfc + (F.sast < 0 ? F.sast * F.sast : 0.0);
    const double st = std::sqrt(F.var_t1), sr = std::sqrt(F.var_r1 + L * L / 18.0);
    F.tangential = st >= kMinEffectiveSigma;
    F.radial = sr >= kMinEffectiveSigma;
    const double smax = std::max(F.tangential ? st : 0.0, F.radial ? sr : 0.0);
    F.lmax = smax > 4.0 ? std::min(kMaxLevel, int(std::ceil(std::log2(smax / 4.0)))) : 0;
    return F;
}

bool Pipeline::lens_aberrations_wanted(double um_per_px) const {
    const LensAberrationParams& la = params_.camera.lens_aberrations;
    if (!la.active || !(um_per_px > 0.0)) return false;
    const LensFieldPx F = lens_field_px(um_per_px);
    return la.lateral_ca_r != 0.0 || la.lateral_ca_b != 0.0 || la.loca_um / um_per_px >= kMinEffectiveSigma ||
           F.tangential || F.radial;
}

// The rows an aberration pass reads past a chunk's edges.
double Pipeline::lens_aberration_reach(double um_per_px, double hd) const {
    const LensAberrationParams& la = params_.camera.lens_aberrations;
    if (!la.active || !(um_per_px > 0.0)) return 0.0;
    double r = 0.0;
    const double ca = std::max(std::fabs(la.lateral_ca_r), std::fabs(la.lateral_ca_b)) * 1e-3;
    if (ca > 0.0) r += ca * hd + 3.0;
    const double sl = la.loca_um / um_per_px;
    if (sl >= kMinEffectiveSigma) r += reach_of(sl, kLensReachSigmas);
    const LensFieldPx F = lens_field_px(um_per_px);
    // A gather reads 3.5 sigma along its line, plus, in its coarser level's
    // texels T (<= sigma / 2): the tap grid's rounding, the pair across the
    // line, the bilinear and the pyramid's tents -- 5 T.
    auto texel = [](double s) { return std::clamp(s / 2.0, 1.0, double(1 << kMaxLevel)); };
    if (F.tangential) {
        const double st = std::sqrt(F.var_t1);
        r += kLineTruncate * st + 5.0 * texel(st) + 2.0;
    }
    if (F.radial) {
        const double L = std::fabs(F.coma), se = std::sqrt(F.var_r1 + L * L / 18.0);
        r += kLineTruncate * std::sqrt(F.var_r1) + L + 5.0 * texel(se) + 2.0;
    }
    return r;
}

bool Pipeline::lens_pyramid(const Image& base, const LensGeom& G, int lmax, LensPyramid& P,
                            std::string& error) {
    P = LensPyramid{};
    P.lv[0] = base;
    P.I0[0] = int(G.row0); P.LH[0] = int(base.h); P.LW[0] = int(base.w);
    P.levels = lmax;
    for (int l = 1; l <= lmax; ++l) {
        const uint32_t I0 = G.row0 >> l, last = (G.row0 + base.h - 1) >> l;
        Image& o = P.lv[l];
        o.h = last - I0 + 1; o.w = (uint32_t(P.LW[l - 1]) + 1) / 2; o.c = 3;
        // Outside the pool, at its own size (see `lens_filter_fast`).
        o.buf = gpu_->alloc_persistent(o.bytes(), error);
        if (!o.buf) return false;
        const uint32_t meta[6] = {uint32_t(P.LH[l - 1]), uint32_t(P.LW[l - 1]), uint32_t(P.I0[l - 1]),
                                  o.h, o.w, I0};
        if (!gpu_->dispatch("spk_lens_down2", {gpu::Arg::buf(P.lv[l - 1].buf), gpu::Arg::inline_bytes(meta, 6),
                                               gpu::Arg::buf(o.buf)}, o.pixels(), error)) return false;
        P.I0[l] = int(I0); P.LH[l] = int(o.h); P.LW[l] = int(o.w);
    }
    return true;
}

bool Pipeline::lens_line(const LensPyramid& P, const LensGeom& G, const LensFieldPx& F, uint32_t mode,
                         Image& out, std::string& error) {
    const Image& base = P.lv[0];
    const LensAberrationParams& la = params_.camera.lens_aberrations;
    int lv[15];
    for (int l = 0; l <= kMaxLevel; ++l) {
        const int k = l <= P.levels ? l : 0;
        lv[3 * l] = P.I0[k]; lv[3 * l + 1] = P.LH[k]; lv[3 * l + 2] = P.LW[k];
    }
    const float lp[8] = {float(G.pcx), float(G.pcy), float(1.0 / G.hd), float(la.sharp_radius),
                         float(la.field_exponent), float(F.sfc), float(F.sast), float(F.coma)};
    gpu::BufferRef lv_buf = gpu_->upload(lv, sizeof lv, error);
    gpu::BufferRef lp_buf = gpu_->upload(lp, sizeof lp, error);
    if (!lv_buf || !lp_buf || !alloc_like(base, out, error)) return false;
    const uint32_t meta[5] = {base.h, base.w, G.row0, mode, uint32_t(P.levels)};
    auto level = [&](int l) -> const gpu::BufferRef& { return l <= P.levels ? P.lv[l].buf : base.buf; };
    return gpu_->dispatch("spk_lens_line",
                          {gpu::Arg::buf(level(0)), gpu::Arg::buf(level(1)), gpu::Arg::buf(level(2)),
                           gpu::Arg::buf(level(3)), gpu::Arg::buf(level(4)), gpu::Arg::buf(lv_buf),
                           gpu::Arg::buf(lp_buf), gpu::Arg::inline_bytes(meta, 5), gpu::Arg::buf(out.buf)},
                          base.pixels(), error);
}

// Lateral CA, LoCA and the field's gathers on one image (a chunk, or the whole
// frame). Consumes its input.
bool Pipeline::lens_aberrate(Image in, Image& out, std::string& error) {
    const LensAberrationParams& la = params_.camera.lens_aberrations;
    const LensGeom G = lens_geom(in);
    const double upx = G.um_per_px;
    Image cur = std::move(in);

    // 1. lateral CA: R and B against G
    const double ar = la.lateral_ca_r * 1e-3, ablue = la.lateral_ca_b * 1e-3;
    if (ar != 0.0 || ablue != 0.0) {
        const float p[5] = {float(G.pcx), float(G.pcy), float(1.0 / G.hd), float(ar), float(ablue)};
        gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
        Image next;
        if (!p_buf || !alloc_like(cur, next, error)) return false;
        const uint32_t meta[3] = {cur.h, cur.w, G.row0};
        if (!gpu_->dispatch("spk_lens_tca", {gpu::Arg::buf(cur.buf), gpu::Arg::buf(p_buf),
                                             gpu::Arg::inline_bytes(meta, 3), gpu::Arg::buf(next.buf)},
                            cur.pixels(), error)) return false;
        cur = std::move(next);
    }

    // 2. LoCA: the soft channels' bright light scattered (spk_lens_loca_share)
    const double sl = la.loca_um / upx;
    if (sl >= kMinEffectiveSigma) {
        const bool purple = la.loca_sign != "green";
        const float p[5] = {purple ? 1.0f : 0.0f, purple ? 0.0f : 1.0f, purple ? 1.0f : 0.0f,
                            float(std::clamp(la.loca_highlight_gate, 0.0, 1.0)), float(kMid)};
        gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
        const uint32_t n[1] = {uint32_t(cur.pixels())};
        Image share, blurred, next;
        if (!p_buf || !alloc_like(cur, share, error)) return false;
        if (!gpu_->dispatch("spk_lens_loca_share", {gpu::Arg::buf(cur.buf), gpu::Arg::buf(p_buf),
                                                    gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(share.buf)},
                            cur.pixels(), error)) return false;
        const double sigma[3] = {purple ? sl : 0.0, purple ? 0.0 : sl, purple ? sl : 0.0};
        if (!blur_.gaussian(share, sigma, blurred, error)) return false;
        share = Image{};
        if (!alloc_like(cur, next, error)) return false;
        if (!gpu_->dispatch("spk_lens_loca_mix", {gpu::Arg::buf(cur.buf), gpu::Arg::buf(blurred.buf),
                                                  gpu::Arg::buf(p_buf), gpu::Arg::inline_bytes(n, 1),
                                                  gpu::Arg::buf(next.buf)}, cur.pixels(), error)) return false;
        cur = std::move(next);
    }

    // 3. field curvature, astigmatism, coma: tangential, then radial
    const LensFieldPx F = lens_field_px(upx);
    for (uint32_t mode : {0u, 1u}) {
        if (mode == 0u ? !F.tangential : !F.radial) continue;
        LensPyramid P;
        if (!lens_pyramid(cur, G, F.lmax, P, error)) return false;
        Image next;
        if (!lens_line(P, G, F, mode, next, error)) return false;
        P = LensPyramid{};
        cur = std::move(next);
    }
    out = std::move(cur);
    return true;
}

// The aberrations over a frame, a chunk of rows at a time with their reach
// either side, each chunk's interior written into `out` (already allocated, the
// frame's size) -- which may be `src` itself: a chunk's rows above its interior
// were overwritten by the chunk before, and are taken from that chunk's input
// (which holds them: a chunk is at least its reach tall). Every chunk but the
// last is one height, so the pool's planes are reused chunk to chunk.
bool Pipeline::lens_aberrate_frame(const Image& src, Image& out, std::string& error) {
    const uint32_t W = src.w, H = src.h;
    const bool in_place = out.buf.get() == src.buf.get();
    const double hd = 0.5 * std::hypot(double(W), double(H));
    const uint32_t reach = uint32_t(std::ceil(lens_aberration_reach(lens_um_per_px_, hd)));
    const uint32_t rows = std::max(lens_chunk_rows(), reach);
    const uint32_t full = rows + 2 * reach;
    struct Restore {
        Pipeline& p; LensChunk chunk;
        ~Restore() { p.lens_chunk_ = chunk; }
    } restore{*this, lens_chunk_};
    Image prev;            // the last chunk's input, original rows
    uint32_t prev_s0 = 0;
    for (uint32_t y0 = 0; y0 < H; y0 += rows) {
        const uint32_t n = std::min(rows, H - y0);
        const uint32_t s0 = y0 > reach ? y0 - reach : 0u;
        const uint32_t span = std::min(full, H - s0);
        Image chunk;
        chunk.h = span; chunk.w = W; chunk.c = 3;
        chunk.buf = gpu_->alloc(chunk.bytes(), error);
        if (!chunk.buf) return false;
        // rows [s0, y0) from the chunk before when they are already lensed
        const uint32_t above = in_place && prev.buf ? y0 - s0 : 0u;
        if (above) {
            const uint32_t m[4] = {W, s0 - prev_s0, 0u, above * W * 3u};
            if (!gpu_->dispatch("spk_lens_rows_put", {gpu::Arg::buf(prev.buf), gpu::Arg::inline_bytes(m, 4),
                                                      gpu::Arg::buf(chunk.buf)}, size_t(above) * W * 3u, error))
                return false;
        }
        const uint32_t m[4] = {W, s0 + above, above, (span - above) * W * 3u};
        if (!gpu_->dispatch("spk_lens_rows_put", {gpu::Arg::buf(src.buf), gpu::Arg::inline_bytes(m, 4),
                                                  gpu::Arg::buf(chunk.buf)}, size_t(span - above) * W * 3u, error))
            return false;
        prev = Image{};
        if (in_place) { prev = chunk; prev_s0 = s0; }
        lens_chunk_.active = true;
        lens_chunk_.frame_w = W; lens_chunk_.frame_h = H; lens_chunk_.row0 = s0;
        Image o;
        // Consumed (its plane back to the pool after the first pass) unless
        // the next chunk reads its rows.
        Image arg = in_place ? chunk : std::move(chunk);
        chunk = Image{};
        if (!lens_aberrate(std::move(arg), o, error)) return false;
        const uint32_t pmeta[4] = {W, y0 - s0, y0, n * W * 3u};
        if (!gpu_->dispatch("spk_lens_rows_put", {gpu::Arg::buf(o.buf), gpu::Arg::inline_bytes(pmeta, 4),
                                                  gpu::Arg::buf(out.buf)}, size_t(n) * W * 3u, error)) return false;
        o = Image{};
        if (!gpu_->flush(error)) return false;   // one chunk's planes at a time
    }
    return true;
}

// ---------------------------------------------------------------------------
// the pass on the source
// ---------------------------------------------------------------------------

double Pipeline::lens_pitch_um(uint32_t w, uint32_t h) const {
    // `fix_film_pitch`'s rule at this image's long edge.
    const double long_mm = overscan_wanted() ? overscan_gate_long_mm() : params_.camera.film_format_mm;
    return long_mm * 1000.0 / double(std::max(w, h));
}

bool Pipeline::lens_source(const Params& params, const Image& src, bool file_backed, Image& out,
                           std::string& error, bool exact, const Image* reuse) {
    out = src;
    params_ = params;
    input_cctf_mode_ = cctf_mode_for(params_.io.input_color_space);
    if (!film_lens_wanted()) return true;
    struct Restore {
        Pipeline& p; Progress* progress; double um;
        ~Restore() { p.progress_ = progress; p.lens_um_per_px_ = um; }
    } restore{*this, progress_, lens_um_per_px_};
    progress_ = nullptr;
    lens_um_per_px_ = lens_pitch_um(src.w, src.h);
    double a_id[3];
    diffusion::PyramidFit fit;
    if (!lens_pyramid_fit(lens_um_per_px_, src.w, src.h, a_id, fit, error)) return false;
    double gw = 0.0, sg = 0.0;
    const bool glow = lens_glow(lens_um_per_px_, gw, sg);
    // The exact path's mixture carries the glow folded into the filter (the
    // reference, 2026-11-09); the fast path runs it as its own pass.
    const bool filter = !fit.a.empty() || (exact && glow);
    const bool aberr = lens_aberrations_wanted(lens_um_per_px_);
    if (!filter && !glow && !aberr) return true;   // on, and every size 0: the source itself
    // One frame-sized copy, written in place by every step after the first:
    // the decode (an encoded input), or the filter's combine, or a copy for
    // the aberrations alone. File-backed for the full tier (the session
    // source's convention: its pages count once, as the source's do).
    Image F;
    F.h = src.h; F.w = src.w; F.c = 3;
    // A drag of a slider writes each value over the last one's copy: no new
    // pages to fault in (11 ms of the filter's 41 at 48 MP, measured).
    if (reuse && reuse->buf && reuse->buf.get() != src.buf.get() && reuse->h == F.h && reuse->w == F.w &&
        reuse->c == 3)
        F.buf = reuse->buf;
    else
        F.buf = file_backed ? gpu_->alloc_file_backed(F.bytes(), error) : gpu_->alloc_persistent(F.bytes(), error);
    if (!F.buf) return false;
    const bool encoded = params_.io.input_cctf_decoding;
    const uint32_t cmeta[2] = {uint32_t(src.elements()), input_cctf_mode_};
    bool fresh = false;   // F holds the source's light
    if (encoded) {
        if (!gpu_->dispatch("spk_cctf_decode", {gpu::Arg::buf(src.buf), gpu::Arg::inline_bytes(cmeta, 2),
                                                gpu::Arg::buf(F.buf)}, src.elements(), error)) return false;
        fresh = true;
    }
    if (filter) {
        const Image& E = fresh ? F : src;
        if (exact) {
            Image x;
            if (!lens_filter_exact(E, x, error) || !gpu_->flush(error)) return false;
            std::memcpy(gpu_->contents(F.buf.get()), gpu_->contents(x.buf.get()), F.bytes());
        } else if (!lens_filter_fast(E, F, error)) {
            return false;
        }
        fresh = true;
    }
    if (glow && !exact) {
        if (!lens_glow_fast(fresh ? F : src, F, error)) return false;
        fresh = true;
    }
    if (aberr && !lens_aberrate_frame(fresh ? F : src, F, error)) return false;
    if (encoded && !gpu_->dispatch("spk_lens_cctf_encode", {gpu::Arg::buf(F.buf), gpu::Arg::inline_bytes(cmeta, 2)},
                                   F.elements(), error)) return false;
    if (!gpu_->flush(error)) return false;
    out = F;
    return true;
}

// ---------------------------------------------------------------------------
// the test seam: the pass alone, on a linear image the caller hands it
// ---------------------------------------------------------------------------

#ifndef SPK_HARDENED
bool Pipeline::lens_probe(const Params& params, double pixel_um, const Image& in, bool exact, uint32_t chunk_rows,
                          Image& out, double* fit_info, std::string& error, const Image* reuse) {
    lens_chunk_rows_ = chunk_rows;
    Params p = params;
    // `pixel_um` stands for the pitch: the frame's long edge in mm is set so
    // `lens_pitch_um` gives it back.
    p.film_render.overscan.active = false;
    p.camera.film_format_mm = pixel_um * double(std::max(in.w, in.h)) / 1000.0;
    params_ = p;
    progress_ = nullptr;
    if (fit_info) {
        double a_id[3];
        diffusion::PyramidFit fit;
        if (!lens_pyramid_fit(lens_pitch_um(in.w, in.h), in.w, in.h, a_id, fit, error)) return false;
        fit_info[0] = fit.levels;
        for (int c = 0; c < 3; ++c) fit_info[1 + c] = fit.lsf_rms[c];
    }
    return lens_source(p, in, false, out, error, exact, reuse);
}
#endif

}  // namespace spk

#ifndef SPK_HARDENED
// `spk_lens_probe`: the lens pass alone on a linear float32 RGB image, for
// `engine/tests/lens_checks.py` and `diffusion_checks.py`. Not in the public
// header and not in a hardened (shipped) build. `params_json` is a wire delta
// (`diffusion_filter_*`, `lens_*`, and `input_cctf_decoding` /
// `input_color_space` for an encoded image); `opts_json` may carry `exact` (1:
// the filter by the exact path, the reference), `chunk_rows` (the rows the
// aberrations and an in-place combine take at a time; 0: 512) and `repeat` (the pass run n
// times, each over the last one's output as a slider's drag is, the fastest
// reported as `ms` -- the first, into fresh pages, as `ms_first`).
#include <chrono>

#include "gpu/gpu.hpp"
#include "json.hpp"
#include "params.hpp"

extern "C" int spk_lens_probe(const char* metallib, const char* params_json, const char* opts_json,
                              const float* in, uint32_t h, uint32_t w, double pixel_um, float* out,
                              char* err, size_t err_len) {
    using namespace spk;
    std::string error;
    static gpu::Gpu* g = nullptr;
    auto fail = [&](const std::string& e) {
        if (err && err_len) { std::snprintf(err, err_len, "%s", e.c_str()); }
        return 1;
    };
    if (!g) g = gpu::Gpu::create_metal(nullptr, metallib ? metallib : "", error);
    if (!g) return fail(error);
    Json pj, oj;
    if (!Json::parse(params_json ? params_json : "{}", pj, error)) return fail(error);
    if (!Json::parse(opts_json ? opts_json : "{}", oj, error)) return fail(error);
    Params params;
    apply_delta(params, pj);
    auto opt = [&](const char* key) -> double {
        for (const auto& kv : oj.fields()) if (kv.first == key) return kv.second.as_double();
        return 0.0;
    };
    g->begin_frame();
    bool ok = true;
    double info[4] = {0, 0, 0, 0};
    double ms = 1e300, ms_first = 0.0;
    {
        Pipeline pl(g, nullptr, nullptr, nullptr);
        Image img;
        img.h = h; img.w = w; img.c = 3;
        img.buf = g->upload_persistent(in, size_t(h) * w * 3 * sizeof(float), error);
        ok = bool(img.buf) && g->flush(error);
        const int repeat = std::max(1, int(opt("repeat")));
        Image last;   // each repeat writes over the last one's output, as a drag does
        for (int r = 0; ok && r < repeat; ++r) {
            Image o;
            const auto t0 = std::chrono::steady_clock::now();
            ok = pl.lens_probe(params, pixel_um, img, opt("exact") != 0.0,
                                uint32_t(std::max(0.0, opt("chunk_rows"))), o, info, error, &last) && g->flush(error);
            last = o;
            const double t = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            if (r == 0) ms_first = t;
            ms = std::min(ms, t);
            if (ok && r == repeat - 1) std::memcpy(out, g->contents(o.buf.get()), size_t(h) * w * 3 * sizeof(float));
        }
    }
    g->end_frame();
    if (ok && err && err_len)
        std::snprintf(err, err_len, "{\"levels\": %g, \"lsf_rms\": [%g, %g, %g], \"ms\": %.3f, \"ms_first\": %.3f}",
                      info[0], info[1], info[2], info[3], ms, ms_first);
    return ok ? 0 : fail(error);
}

// `spk_diffusion_psf_json`: the filter's host half -- p_s and every exponential
// (lambda in um with `spatial_scale` in, per-channel weight, group) -- for a
// wire delta, so `diffusion_checks.py` can hold it to the oracle's functions.
// %.17g: the comparison is of the doubles.
extern "C" int spk_diffusion_psf_json(const char* params_json, char* out, size_t out_len) {
    using namespace spk;
    std::string error, text;
    Json pj;
    if (!Json::parse(params_json ? params_json : "{}", pj, error)) {
        text = "{\"error\": \"bad json\"}";
    } else {
        Params params;
        apply_delta(params, pj);
        diffusion::Psf psf;
        if (!diffusion::build_psf(params.camera.diffusion_filter, psf, error)) {
            text = "{\"error\": \"" + error + "\"}";
        } else {
            char buf[256];
            std::snprintf(buf, sizeof buf, "{\"p_s\": %.17g, \"exps\": [", psf.p_s);
            text = buf;
            for (size_t k = 0; k < psf.exps.size(); ++k) {
                const diffusion::Exponential& e = psf.exps[k];
                std::snprintf(buf, sizeof buf, "%s[%.17g, %.17g, %.17g, %.17g, %d]", k ? ", " : "",
                              e.lambda_um, e.weight[0], e.weight[1], e.weight[2], e.group);
                text += buf;
            }
            text += "]}";
        }
    }
    if (!out || text.size() + 1 > out_len) return 1;
    std::memcpy(out, text.c_str(), text.size() + 1);
    return 0;
}
#endif
