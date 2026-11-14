// negative_hue.hpp -- the print's hue, taken from the negative (2026-11-11).
//
// The optical print is two sets of steep per-layer curves in series. A saturated
// colour puts its weak layers in the paper's toe or shoulder, where they stop
// separating, and the print collapses toward the nearest primary: a violet coat
// prints blue, measured at -12..-25 degrees of Oklab hue on every film/paper pair
// (research/Metamerism, 2026-10-24). The negative itself holds the hue.
//
// The calibrated "minilab" tables fix that for one pair at a time, and each table
// is a bake, a solver and a review. This is the same decision made analytically,
// from the two profiles and nothing else, so it holds for every pair:
//
//   lightness, chroma  the optical print's own (the look: film and paper curves)
//   hue                the negative's, read layer by layer through the film's own
//                      characteristic curve and then through the inverse of this
//                      film's own exposure map (which colour puts the three layers
//                      in that ratio), tabulated from the film's chain at setup
//   limit              the paper's gamut, from its dyes and its density range
//
// Nothing here edits a profile. The print stage is where the hue was lost, so the
// print stage is what reads it back.
//
// Measured 2026-11-11 through the shipping dylib, a 366-patch Oklab chart, every colour
// negative on every paper (127 pairs): mean hue error 0.72 degrees (worst pair 1.40)
// against the optical print's 10.6 (7.2..23.4), lightness within 0.004 of the optical
// print's, a grey ramp identical to it to the bit. The approved Portra 400 table measures
// 6.8 on the same chart. `engine/tests/negative_hue_checks.py` holds all of it, and is the
// only description of the per-pixel arithmetic besides `shaders/negative_hue.metal` itself.
#pragma once
#include <string>

#include "blob.hpp"
#include "colour.hpp"
#include "curves.hpp"
#include "numeric.hpp"
#include "params.hpp"
#include "spectral.hpp"

namespace spk {

// Oklab chroma of the negative's reading, at the print's luminance, over which the
// negative's hue takes over from the optical print's. Below `kNegativeHueChromaLo`
// a near-neutral keeps the paper's own neutral exactly (the print is bit-identical
// there); the two values are the approved Portra 400 table's (`c3_lib.targets3`).
constexpr double kNegativeHueChromaLo = 0.005;
constexpr double kNegativeHueChromaHi = 0.020;
// How fast the reading is distrusted where a layer has left the straight part of
// its curve: weight = 1 / (1 + (k u)^2), u the exposure-weighted mean of
// (gamma_ref / gamma_local - 1). A layer at a third of its slope carrying the whole
// exposure halves the weight.
constexpr double kNegativeHueUnreliability = 0.5;
// Below this weight the reading is not consulted at all, and the weights above it are
// stretched to start from zero, so the fall to "the optical print, to the bit" is continuous.
// Without it a grey at -7 or +7 EV -- every layer off the end of its curve, weight 4e-4 --
// came back one 16-bit code away from the optical print on one pair in five.
constexpr double kNegativeHueWeightFloor = 0.02;
// The paper's gamut: chroma is compressed from this fraction of the boundary.
constexpr double kNegativeHueGamutKnee = 0.85;
constexpr uint32_t kNegativeHueGamutHues = 120;
constexpr uint32_t kNegativeHueGamutLevels = 48;
// The film's exposure map, inverted: a square table over the layers' exposure
// chromaticity (red share, green share), holding the Oklab (a, b) of the colour
// that produces it at `kNegativeHueLightness` (mid-grey's own lightness).
constexpr uint32_t kNegativeHueMapSide = 160;
// The per-layer inverse curve, resampled evenly in density so a pixel reads it by
// index and not by search (three searches were ~6 ms of a 45 MP print).
constexpr uint32_t kNegativeHueLayerSamples = 1024;
constexpr double kNegativeHueLightness = 0.5687;   // cbrt(0.184)

struct NegativeHue {
    // Per layer, the characteristic curve inverted: density -> log10 exposure, on
    // the curve's own knots ((K, 3) / (K-1, 3) row-major) ...
    InterpTables inverse;
    Vec unreliability;          // (K, 3) at `inverse.x`: gamma_ref / gamma_local - 1, >= 0
    // ... and what the pixels read: both, evenly spaced in density from the
    // layer's least to its most. (samples, 3, 2) row-major: [log10 exposure, unreliability].
    Vec layers;
    double layer_lo[3] = {0, 0, 0}, layer_scale[3] = {1, 1, 1};   // index = (density - lo) * scale
    double gamma_ref[3] = {1, 1, 1};
    double neutral[3] = {1, 1, 1};   // a grey's three layer exposures, relative: the map's white point
    Vec map;                    // (side, side, 2) row-major [red share][green share] -> Oklab (a, b)
    double scan_to_d65[9] = {}; // row-major, the scan illuminant's XYZ -> D65 (CAT02)
    double d65_to_scan[9] = {};
    Vec gamut;                  // (levels, hues) row-major: the paper's max Oklab chroma
    double gamut_l_lo = 0.0, gamut_l_hi = 1.0;
    // The map read back on the colours it was built from: what tabulation costs.
    size_t map_samples = 0, map_filled = 0;
    double map_hue_rms_deg = 0.0, map_hue_max_deg = 0.0;
};

// `scan` is the paper's scanning constants (its dyes and base under the viewing
// illuminant, as the pipeline bakes them), `scan_illuminant_xy` that illuminant's
// chromaticity, `paper_curves` the (K, 3) print curves the session develops on.
bool negative_hue_constants(const Colour& colour, const Blob& blob, const Params& params,
                            const Vec& tc_lut, size_t tc_lut_side, const Mat3& tc_b,
                            const SpectralConstants& scan, const double scan_illuminant_xy[2],
                            const Vec& paper_curves, NegativeHue& out, std::string& error);

}  // namespace spk
