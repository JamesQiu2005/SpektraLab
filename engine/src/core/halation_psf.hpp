// halation_psf.hpp -- the back-reflection halo of a film with no anti-halation
// layer, as a fixed Gaussian mixture per sensitive layer, in units of the
// base thickness.
//
// **The physics** (`engine/tests/halation_psf_fit.py` integrates it and fits
// these numbers; rerun it rather than editing them by hand):
//
//   * light the emulsion scatters into the base leaves it Lambertian, and
//     reaches the base's rear face at polar angle theta;
//   * the face reflects Fresnel from n = 1.48 (cellulose triacetate) into air
//     -- 4 % at normal incidence, rising to **1 past the critical angle**
//     theta_c = asin(1/n) = 42.5 deg, total internal reflection;
//   * inside theta_c most of the light leaves the base, and the camera's
//     **pressure plate** sends 10 % of it back (CineStill's own account of its
//     halation names base and plate): that fills the gap inside the ring, so a
//     point light shows a disc with a brighter rim rather than a donut;
//   * the light re-enters the emulsion at r = 2 d tan(theta): one bounce
//     exposes R(theta) cos^4(theta) / (4 pi d^2), a jump at
//     r_c = 2 d tan(theta_c) = 1.83 d and a cos^4 tail;
//   * **per layer, the slant path back** (after GPT Astra's study of the
//     sample scans, 2026-10-23): green returns through the red layer and its
//     coloured masking coupler, blue through red, green and the yellow filter,
//     each at theta, so they lose exp(-tau (1/cos theta - 1)) against normal
//     incidence -- tau 0 / 1.2 / 3.0. The far, oblique part of the halo is
//     red's alone, which is why every CineStill scan's red reaches 1.5-2.7x
//     as far as its green, at any brightness;
//   * plus the unscattered 15 % (the lens's cone at f/2.8, refracted);
//   * the emulsion it returns to re-scatters 35 % back down, Lambertian again,
//     so the halo is the Neumann series h + rho h*h + ... (an FFT);
//   * softened by the emulsion's own thickness (sigma 0.08 d), unit mass.
//
// Red: half the halo's energy within 3.1 d and 90 % within 8.2 d -- about a
// millimetre on a 120 um base, which is why a Gaussian with a 50 um sigma never
// looked like CineStill. Green's 90 % is within 3.8 d, blue's 2.7 d. An edge
// shows a flat band out to r_c that the film's shoulder turns into the orange
// stripe beside a tube light.
//
// **The fit** is four Gaussians per layer with signed weights, constrained to
// stay non-negative everywhere, to sum to 1, and to sum(|w|) <= 2 with sigmas at
// least 1.35x apart -- because the GPU blur's IIR branch is an approximation,
// and a mixture that cancels large weights (an unconstrained fit wanted
// +56/-113/+58) would amplify its error a hundredfold. Each layer's edge
// response is within 0.0051 of its integral's out to 4 d.
#pragma once

namespace spk {

constexpr int kBackReflectionComponents = 4;
// [component][red, green, blue]
constexpr double kBackReflectionSigmaOverBase[kBackReflectionComponents][3] = {
    {0.184586, 0.178469, 0.170237},
    {1.121207, 1.000078, 0.546805},
    {1.651048, 1.581389, 0.808738},
    {4.677567, 9.448921, 1.340598},
};
constexpr double kBackReflectionWeight[kBackReflectionComponents][3] = {
    {+0.041510, +0.106789, +0.202791},
    {-0.500000, -0.500000, +0.156578},
    {+1.034500, +1.384389, -0.500000},
    {+0.423990, +0.008822, +1.140631},
};

// The halo's total, per layer, as a fraction of the layer's own exposure.
// Red is bottom-most and takes the returning light first; green and blue keep
// what their slant path leaves (the kernels above are unit mass, so this is
// where that loss lives). Matched to the scans' red/green reach and the halo's
// red-orange.
constexpr double kBackReflectionStrength[3] = {0.30, 0.03, 0.003};

// The headroom gate's clip band, in stops under the frame's own maximum: full
// headroom from a quarter stop under it, none a stop under. Core Image's RAW
// decode reconstructs a clipped lamp into a soft dome rather than a plateau,
// so "clipped" is a band near the maximum, not a value.
constexpr double kHeadroomClipFromEv = -1.0;
constexpr double kHeadroomClipToEv = -0.25;

}  // namespace spk
