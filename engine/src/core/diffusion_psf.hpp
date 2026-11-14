// diffusion_psf.hpp -- the diffusion filter's (柔光镜) point spread function,
// host side: a literal port of upstream `spektrafilm/model/diffusion.py`
// (API-SPEC §21.5).
//
// The model, unchanged:
//
//     E_out = (1 - p_s) * E + p_s * (K_c * E),   K = w_c K_core + w_h K_halo + w_b K_bloom
//
// Each group is a sum of 2-D exponentials E(r; lambda) = exp(-r / lambda) /
// (2 pi lambda^2) on a geometric progression of lambdas; core and halo weights
// are uniform, bloom weights follow lambda^(2 - alpha); only the halo is per
// channel (the energy-conserving "warmth" redistribution). Every table, the
// strength -> p_s map, `_expand_group`, `_halo_channel_weights` and the
// override renormalisation below are the oracle's, line for line, so the host
// numbers are its numbers (`diffusion_checks.py` holds them to 1e-12).
//
// What is *not* the oracle's is how the kernel is applied: the oracle samples
// the PSF on a (2R+1)^2 grid and runs an FFT; the engine replaces each
// exponential by `Blur::exponential_components`' three-Gaussian surrogate and
// sums them at the resolution each one needs (`pipeline/lens.cpp`). That is
// the only approximation, and the checks measure it.
//
// Families: the oracle's four only (decision 13: new ones later, native-only).
#pragma once
#include <array>
#include <string>
#include <vector>

#include "params.hpp"

namespace spk::diffusion {

struct GroupShape {
    double lambda_um = 0.0;
    double spread = 1.0;
    int n_components = 1;
    double alpha = 3.0;   // bloom only
};

struct FamilyShape {
    GroupShape core, halo, bloom;
    double w_c = 0.0, w_h = 0.0, w_b = 0.0;
    double halo_warmth_base = 0.0;
};

/// The oracle's `_DIFFUSION_FILTER_SHAPES[family]`, or nullptr for a name it
/// does not have.
const FamilyShape* family_shape(const std::string& family);
/// `_DIFFUSION_FAMILY_TOTAL_GAIN.get(family, 1.0)`.
double family_gain(const std::string& family);
/// The four names, in the oracle's order.
const std::vector<std::string>& families();

/// `_strength_to_scatter`: the deflected fraction p_s.
double strength_to_scatter(double strength, const std::string& family);

/// `_expand_group(group_cfg, kind=...)`: lambdas (um) and weights summing to 1.
void expand_group(const GroupShape& group, bool bloom, std::vector<double>& lambdas,
                  std::vector<double>& weights);

/// `_halo_channel_weights(weights, warmth)`: (3, N), each row summing to
/// sum(weights).
void halo_channel_weights(const std::vector<double>& weights, double warmth,
                          std::vector<double> out[3]);

/// `_resolve_family_cfg(family, overrides)`: the intensities renormalised, the
/// sizes applied.
FamilyShape resolve_family(const FamilyShape& base, const DiffusionFilterParams& p);

/// The whole PSF as a list of exponentials: lambda in um on the film (with
/// `spatial_scale` in), per-channel weight with the family weight in. The
/// weights of each channel sum to 1 (the groups' w_x do, and each group's do).
struct Exponential {
    double lambda_um = 0.0;
    double weight[3] = {0, 0, 0};
    int group = 0;   // 0 core, 1 halo, 2 bloom
};
struct Psf {
    double p_s = 0.0;   // 0: the filter does nothing (strength or scale <= 0)
    std::vector<Exponential> exps;
};
/// False with `error` for an unknown family.
bool build_psf(const DiffusionFilterParams& p, Psf& out, std::string& error);

// --- the fast application: a Gaussian-pyramid basis ---------------------------
//
// The PSF is applied as out = c0 E + up(A_1), A_k = a_k L_k + up(A_{k+1}),
// where L_k is the source taken down k times by the tent [1 3 3 1] / 8 and
// up is the centred 2x bilinear (pipeline/lens.cpp, shaders/lens.metal). Each
// level's response to a point is a smooth bump about 2^k px wide; the weights
// are fitted so the bumps' sum is the PSF. The fit is in one dimension, on
// line-spread functions: the pyramid is separable, so a level's 2-D response
// is the product of its 1-D one along each axis and its LSF *is* that 1-D
// response, and the LSF of a sum of 2-D convolutions is the sum of theirs.

/// A unit-mass 2-D exponential's LSF, integrated over the pixel cell at x.
double exp_lsf_cell(double x, double lambda_px);
/// A unit-mass 2-D Gaussian's LSF over the cell at x.
double gauss_lsf_cell(double x, double sigma_px);
/// Level k's LSF (k >= 1): an impulse taken down k times and up k times by the
/// GPU's own two filters, averaged over the impulse's phase. Index d = |x|,
/// d = 0 .. size - 1. Unit mass. Cached for the process.
const std::vector<double>& pyramid_basis(int k);

/// Per-level, per-channel weights: a[0] multiplies the source itself, a[k]
/// level k. Non-negative. With a core (`fit_pyramid`'s `inner` > 0) a[0] and
/// the levels below `min_level` are 0 and the core is the FIR `fir`.
struct PyramidFit {
    int levels = 0;                        ///< the coarsest level with a weight
    std::vector<std::array<double, 3>> a;  ///< a[0 .. levels]
    double lsf_rms[3] = {0, 0, 0};         ///< the fit's residual, relative to the target's peak
    /// The core: a (2 R + 1)^2 FIR, row-major, per channel, on the source
    /// itself (made by the caller, which knows the PSF in two dimensions).
    int fir_r = 0;
    std::vector<std::array<double, 3>> fir;
};
/// `target[c][x]`, x = 0 .. X, the LSF (cells) to reproduce, symmetric; up to
/// `max_levels` levels. Non-negative least squares (Lawson-Hanson). With
/// `inner` = 0: the source itself and every level, the mass held by a heavily
/// weighted row. With `inner` > 0: levels `min_level` and up, fitted at
/// x >= inner only -- inside, the caller's core FIR makes up the PSF in two
/// dimensions, and the mass.
/// A mass row for `fit_pyramid` with a core: sum_k a_k (1 - inside[k]) =
/// value[c], heavily weighted (`total` is the caller's, for its own use).
struct MassHold {
    double value[3] = {0, 0, 0};
    double total[3] = {0, 0, 0};
    std::vector<double> inside;   ///< by level k
};
void fit_pyramid(const std::vector<double> target[3], int max_levels, PyramidFit& out,
                 int min_level = 1, int inner = 0, const MassHold* hold = nullptr);
/// The pyramid's phase-averaged response in two dimensions at (dx, dy): the
/// product of the levels' one-dimensional ones (every filter is separable).
double pyramid_response_2d(const PyramidFit& fit, int c, int dx, int dy);
/// A 2-D exponential e^(-r / lambda) / (2 pi lambda^2) over the pixel cell at
/// (dx, dy), integrated numerically (finely where lambda is small).
double exp_cell_2d(int dx, int dy, double lambda_px);

}  // namespace spk::diffusion
