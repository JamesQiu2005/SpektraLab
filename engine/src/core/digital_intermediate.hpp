// digital_intermediate.hpp -- RFC-028's Digital Intermediate: the constants.
//
// The DI replaces the paper. It reads the developed negative the way the
// paper would -- in *printing density*, through the film's own target paper's
// spectral sensitivity under that paper's enlarger lamp -- but with the film
// base (the orange mask) removed wavelength by wavelength, which no physical
// scanner can do. It then reverses each channel on the film's own neutral
// curve, so a grey is exactly neutral at every exposure, maps the film's
// channels to the working space with one 3x3, and writes Cineon-style log.
//
// Everything here is derived from data at build time; nothing is estimated
// from the picture (RFC-028 §3 is the comparison with NLP / negadoctor).
//
// Per pixel the pipeline then runs three kernels it already has plus one:
//   spk_spectral_epilogue (base 0, `ixs` below, log out)  -> log10 T per channel
//   spk_curves            (`curve` below)                 -> log10 positive
//   spk_di_encode         (`matrix`, the blue compensation, the log encode)
#pragma once
#include <cmath>
#include <string>

#include "blob.hpp"
#include "colour.hpp"
#include "curves.hpp"
#include "numeric.hpp"
#include "params.hpp"

namespace spk {

// Kodak's Cineon convention, exactly as the standard decoders apply it
// (Kodak's log-to-linear, Nuke, colour-science's `log_encoding_Cineon`):
//
//     code = (685 + 300 * log10(L * (1 - b) + b)) / 1023,  b = 10^((95 - 685) / 300)
//
// reference white 685 (L = 1), reference black 95 (L = 0: the film base),
// 0.002 density per code and a negative gamma of 0.6 (300 codes per decade).
// L is the DI's positive with the film base subtracted, so the base lands on
// code 95 exactly as it does on a scanned negative, mid grey near 467, and a
// standard Cineon decode returns L. It holds up to ~+6.2 stops over grey.
constexpr double kDiCineonWhite = 685.0;
constexpr double kDiCineonBlack = 95.0;
constexpr double kDiCineonPerDecade = 300.0;
constexpr double kDiCineonMax = 1023.0;
// b above: the linear value of the black code before the offset is removed.
inline double di_cineon_black_offset() {
    return std::pow(10.0, (kDiCineonBlack - kDiCineonWhite) / kDiCineonPerDecade);
}
inline double di_cineon_decode(double code01) {
    const double b = di_cineon_black_offset();
    return (std::pow(10.0, (code01 * kDiCineonMax - kDiCineonWhite) / kDiCineonPerDecade) - b) / (1.0 - b);
}

// The blue-sector window of the optional compensation, in Oklab hue degrees.
// Centred between blue (~264) and the violet the DI drifts toward; wide enough
// to take sky and purplish blue, narrow enough to leave skin, green and red.
constexpr double kDiBlueHueCentre = 280.0;
constexpr double kDiBlueHueHalfWidth = 55.0;
// Oklab chroma below which the compensation fades out, so greys are exact.
constexpr double kDiBlueChromaLo = 0.02;
constexpr double kDiBlueChromaHi = 0.08;

struct DiConstants {
    std::string paper;            // the stock whose sensitivity defines printing density
    Vec chd;                      // (81, 3) the film's dye spectra, invalid wavelengths zeroed
    Vec ixs;                      // (81, 3) printing-density responsivity, each column sums to 1
    InterpTables curve;           // x: log10 T (ascending), y: log10 positive, per channel
    double matrix[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};   // film RGB -> working RGB, x @ M
    double matrix_fit_rms = 0.0;  // relative, over the fit set; a sanity figure
    double positive_floor = 0.0;  // the positive of clear film base, subtracted so the base is black
    double gamma_green = 0.0;     // the reversal's gamma (green, over -2..+2 stops)
    double density_green_mid = 0.0;
    // The optional blue-sector correction, fitted per film on the chain itself.
    double blue_delta_deg = 0.0;
    double blue_kappa = 1.0;
    double to_lms[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};    // working linear RGB -> Oklab LMS, M @ v
    double from_lms[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
};

// `tc_lut` / `side` and `tc_b` are the pipeline's own (the same film eye and
// input adaptation the image goes through), so the neutral wedge and the
// colour fit see exactly what a uniform patch of the image would.
bool di_constants(const Colour& colour, const Blob& blob, const Params& params,
                  const Vec& tc_lut, size_t side, const Mat3& tc_b, const Vec& film_sensitivity,
                  DiConstants& out, std::string& error);

// The per-channel log10 offset the live print controls give the DI positive:
// print brightness as true stops, and the two filter shifts matched to the
// print's own mid-grey response (+1 -> +0.05 stop of blue, +0.03 of green).
void di_live_offsets(const Params& params, double out[3]);

}  // namespace spk
