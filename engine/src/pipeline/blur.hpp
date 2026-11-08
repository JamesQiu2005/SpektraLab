// blur.hpp -- the host half of the separable blurs.
//
// A port of `src/spektrafilm/backends/metal/blur.py`'s dispatch: which of the
// two kernels runs, per channel, and how a Gaussian *mixture* is accumulated.
// The kernels are in `shaders/blur.metal`; nothing here touches a pixel.
//
// The dispatch rule is `utils/fast_gaussian_filter`'s, unchanged, because the
// numba reference is what parity is measured against: sigma <= 0 is identity,
// sigma < 3 is FIR with 'reflect' edges and truncate 3.0, sigma >= 3 is the
// Young & van Vliet IIR -- decided **per channel**, since halation's three
// channels routinely straddle the crossover.
#pragma once
#include <string>
#include <utility>
#include <vector>

#include "image.hpp"
#include "numeric.hpp"
#include "strip.hpp"

namespace spk {

class Blur {
public:
    Blur(gpu::Gpu* gpu) : gpu_(gpu) {}

    // Per-channel Gaussian. With `acc` and `weight`, returns
    // `acc + weight * G(img)` with the multiply-add fused into the last pass
    // -- which is what keeps a three-component exponential PSF at three blurs
    // instead of three blurs plus three full-frame adds.
    bool gaussian(const Image& img, const double sigma[3], Image& out, std::string& error,
                  double truncate = 3.0, const Image* acc = nullptr, const double* weight = nullptr);

    // --- class R, and what it turned out to be -----------------------------
    //
    // The IIR used to transpose the plane so that both passes could be one
    // kernel marching down contiguous memory. It now runs the *same* kernel
    // with an `axis`, and the two transposed copies plus the transpose back --
    // **three planes, all live at once** -- are gone. The arithmetic is
    // untouched: the same instructions in the same order at different
    // addresses.
    //
    // **This is a change to the shipping blur, not to the striped mode.** Every
    // render gets it, mode or no mode, because a recurrence over a plane that
    // is materialised anyway does not need to be cut up. RFC-020 §4.3's "one
    // plane, not two" was always a statement about the pass; reading it as a
    // striping rule is what made a carried-state kernel look necessary. It was
    // written, it compiled, and it had no caller that could exist while the
    // plane is whole -- so it was deleted, and §4.3's banded form waits for the
    // day a plane is not materialised.
    //
    // What that leaves for the striped executor is bookkeeping: such a stage is
    // `Swept` -- whole-plane by design and already minimal -- which is a
    // different fact from "not striped yet", and the one `band_able == false`
    // cannot express.
    struct SweepReport {
        std::vector<StripSpan> bands;  ///< the rows swept, in the order launched
        uint32_t launches = 0;         ///< kernel launches
    };
    void set_sweep_report(SweepReport* report) { sweep_report_ = report; }

    // `sum_k w_k * G(sigma_k)(img)`, accumulated in the reference's order, so
    // the difference from it is a rounding of the running sum and not a
    // different sum.
    struct Component {
        double weight[3];
        double sigma[3];
    };
    bool mixture(const Image& img, const std::vector<Component>& components, Image& out,
                 std::string& error, double truncate = 3.0);

    // --- the class of a sigma, and what it costs a strip boundary -----------
    //
    // Exposed because a striped executor has to know *before* it runs whether a
    // stage is a neighbourhood stage and how many rows of context it needs.
    // This is the one place the FIR/IIR split is decided -- `gaussian` below
    // reads the same predicate -- and the radius is obtained by asking
    // `gaussian_kernel_1d` for it rather than by repeating `truncate * sigma +
    // 0.5` here, because a second copy of that rounding is exactly how a halo
    // comes out a row short.
    static bool is_fir(double sigma) { return sigma > 0.0 && sigma < kSmallSigmaMax; }

    /// Rows (and columns) a FIR gaussian at this sigma reads. Zero when the
    /// sigma is not a FIR sigma.
    static uint32_t fir_radius(double sigma, double truncate = 3.0);

    /// What a blur needs from a strip boundary. `carried` means an active
    /// channel takes the IIR branch, whose recurrence cannot be cut.
    ///
    /// **The two composition rules, and they are not the same rule:**
    ///
    ///   * inside a `mixture`, the components are **alternatives** --
    ///     `G1 + G2 + ...` of one input -- so the widest radius covers them all
    ///     and `demand(components)` takes the max;
    ///   * two blurs in **sequence** are `G_b(G_a(x))`, whose output at row `y`
    ///     depends on the input out to `R_a + R_b`, so the caller **adds** the
    ///     two demands' `halo`s.
    ///
    /// `merge` is the first rule; `+` on `halo` is the second. Using `merge`
    /// where the sum belongs is exact in the middle of a band and one or two
    /// rows short at every boundary, which is a 1-LSB difference no plan, no
    /// pass count and no eye sees.
    struct Demand {
        bool carried = false;
        uint32_t halo = 0;
    };
    static Demand demand(const double sigma[3], double truncate = 3.0);
    /// The max over a mixture's components: they are alternatives of one input.
    static Demand demand(const std::vector<Component>& components, double truncate = 3.0);
    /// For **alternatives**: the wider halo, and a `carried` on either side.
    /// Not for sequence -- see the note above.
    static Demand merge(const Demand& a, const Demand& b);

    // The (weight, sigma) list `fast_exponential_filter` is a sum of: a
    // three-Gaussian surrogate for an isotropic 2-D exponential PSF.
    static void exponential_components(const double decay[3], const double weight[3],
                                       std::vector<Component>& out, int n_gaussians = 3);

    // `a * x + b * y` with per-channel scalars.
    bool lincomb(const Image& x, const Image& y, const double a[3], const double b[3],
                 Image& out, std::string& error);

    // A per-channel affine, `x * s + t` -- the exposure gain, the density_min
    // subtraction, the sub-layer division.
    bool affine(const Image& x, const double s[3], const double t[3], Image& out, std::string& error);

private:
    bool fir(const Image& img, const double sigmas[3], double truncate, const bool active[3],
             Image& out, std::string& error, const Image* acc, const double* weight);
    bool iir(const Image& img, const double sigmas[3], const bool active[3],
             Image& out, std::string& error, const Image* acc, const double* weight);
    bool alloc_like(const Image& img, Image& out, std::string& error);

    gpu::Gpu* gpu_;
    SweepReport* sweep_report_ = nullptr;
};

}  // namespace spk
