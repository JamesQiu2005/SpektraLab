// halation_psf.hpp -- the back-reflection halo of a film with no anti-halation
// layer, as a fixed Gaussian mixture in units of the base thickness.
//
// **The physics** (`engine/tests/halation_psf_fit.py` integrates it and fits
// these numbers; rerun it rather than editing them by hand):
//
//   * light the emulsion scatters into the base leaves it Lambertian, and
//     reaches the base's rear face at polar angle theta;
//   * the face reflects R(theta), Fresnel from n = 1.48 (cellulose triacetate)
//     into air -- 4 % at normal incidence, rising to **1 past the critical
//     angle** theta_c = asin(1/n) = 42.5 deg, total internal reflection;
//   * the light re-enters the emulsion at r = 2 d tan(theta), so one bounce
//     exposes E(r) = R(theta) cos^4(theta) / (4 pi d^2): a faint disc, a jump
//     at r_c = 2 d tan(theta_c) = 1.83 d, and a cos^4 tail;
//   * plus the unscattered 15 % (the lens's cone at f/2.8, refracted, 4 %);
//   * the emulsion it returns to re-scatters 35 % back down, Lambertian again,
//     so the halo is the Neumann series h + rho h*h + ... (an FFT);
//   * softened by the emulsion's own thickness (sigma 0.08 d).
//
// Half the halo's energy lands within 3.3 d and 90 % within 8.5 d -- about a
// millimetre on a 120 um base, which is why a Gaussian with a 50 um sigma never
// looked like CineStill. The ring is what a point light shows; an edge shows a
// flat band out to r_c that the film's shoulder turns into the orange stripe
// beside a tube light.
//
// **The fit** is four Gaussians with signed weights, constrained to stay
// non-negative everywhere, to sum to 1, and to sum(|w|) <= 2 with sigmas at
// least 1.35x apart -- because the GPU blur's IIR branch is an approximation,
// and a mixture that cancels large weights (an unconstrained fit wanted
// +56/-113/+58) would amplify its error a hundredfold. The edge response it
// gives is within 0.004 of the integral's out to 4 d.
#pragma once

namespace spk {

constexpr int kBackReflectionComponents = 4;
constexpr double kBackReflectionSigmaOverBase[kBackReflectionComponents] = {
    0.499839, 0.836956, 1.751281, 4.772816};
constexpr double kBackReflectionWeight[kBackReflectionComponents] = {
    0.152870, -0.500000, 0.912306, 0.434824};

// The halo's total, per layer, as a fraction of the layer's own exposure: the
// light that reaches the base times the series' return (0.60 of it) times what
// the layer absorbs on the way back up, relative to what it absorbed going
// down. Red is bottom-most and takes it first; green has to pass the red
// layer's coloured masking coupler; blue is behind the yellow filter.
constexpr double kBackReflectionStrength[3] = {0.30, 0.03, 0.003};

// The headroom gate's clip band, in stops under the frame's own maximum: full
// headroom from a quarter stop under it, none a stop under. Core Image's RAW
// decode reconstructs a clipped lamp into a soft dome rather than a plateau,
// so "clipped" is a band near the maximum, not a value.
constexpr double kHeadroomClipFromEv = -1.0;
constexpr double kHeadroomClipToEv = -0.25;

}  // namespace spk
