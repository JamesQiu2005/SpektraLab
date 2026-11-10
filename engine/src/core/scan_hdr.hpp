// scan_hdr.hpp -- the HDR scan of a slide, per dye layer (2026-11-03).
//
// 2026-11-06, PRD/HDR-PORT-PLAN-2026-11-06.md D4. The research paths below
// are not in this repository.
//
// `rfc/audits/hdr-density-2026-11-03/HANDOFF.md` §6 and SPEC.md §6: a reversal
// film's exposure sets each dye layer's density, so the scan can be made again
// with every layer's characteristic curve moved above its own knee and the
// layer lifted **inside the spectral scan** by a density below the clear base
// -- a gain on that dye's band, integrated with the dyes' spectra, so the
// layers' cross-talk is modelled (the study's after-scan approximation lifted
// each output channel instead).
//
// A named implementation of the scan, never an edited profile (AGENTS.md rule
// 1): the shift is a render-time parameter (`scan_hdr_headroom`), the profile
// is read and never written, and below the first knee every table this makes
// is the film's own, value for value.
//
//   per layer l:  knee_l   the exposure (log10 H) past the layer's mid-grey
//                          where |dD/dlogH| falls to kappa of its slope there
//                 L_l      the layer's lift in density. The three are solved
//                          together on the host so the clear base scans to
//                          its own colour times k (XYZ, every component): the
//                          lamp brighter, never tinted -- one lift for all
//                          three, log10 H, turns a slide's white yellow,
//                          because the dyes' bands do not weigh X, Y and Z
//                          alike (measured: blue 8 % short at H = 4).
//                          k = H, or 0.98 / Y_white when the SDR rendition is
//                          stretched (`scan_hdr_stretch`, the page's white)
//                 delta_l  the shift that puts D_l(logH - delta_l) - L_l
//                          through the knee's density (family A)
//                 D''_l    the HDR density: D_l blended over one stop above the
//                          knee (smoothstep t) into D_l(logH - delta_l) - L_l.
//                          Monotone; the knee's density dk_l at the knee, the
//                          clear base less L_l past the shoulder
//
// **Why the develop does not read D'' itself.** Grain reads the developed
// density as particles between the clear base and D-max: a density below the
// base is a base (measured by the study: "the scan clamps density at zero",
// the lift lost). So the develop reads D''_l mapped linearly from
// [D''_min, dk_l] onto [D_min, dk_l] -- a film's own density range, a shoulder
// grain knows -- and the scan maps it back, `c -> dk - (dk - c) * s_l` for
// c < dk_l, s_l = (dk_l - D''_min) / (dk_l - D_min): exactly D'' for a uniform
// field, the grain's spread widened with the tones it sits on. At and above
// dk_l (below the knee in exposure) the scan reads c as ever.
//
// The model's numbers follow `slides/tools/run_slides.py` (the study) line for
// line: the same 5-tap smoothing of the slope, the same knee interpolation,
// the same delta search; mid-grey is log10 H = 0 (the study measured +0.011 to
// -0.028 through the engine).
#pragma once
#include <string>
#include <vector>

#include "numeric.hpp"

namespace spk {

struct ScanHdrModel {
    static constexpr const char* kVersion =
        "scan_hdr v1 (family A, kappa 0.8, one-stop blend, per-layer lift in the scan, neutral lamp)";
    static constexpr double kKappa = 0.8;
    static constexpr double kPageWhite = 0.98;

    bool active = false;
    double headroom = 0.0;       // k: the clear base x k (H, or the stretch's 0.98 / Y_white)
    bool stretch = false;        // the clear base at the page's white
    double output_scale = 1.0;   // the rendition's gain after the gamut compression
    double y_white = 0.0;        // the film's clear base, scanned today (XYZ Y, the illuminant's = 1)
    double y_target = 0.0;       // where the clear base is put
    double y_reached = 0.0;      // where it lands
    double tint = 0.0;           // max |log(XYZ_c / (k XYZ_white_c))| reached: 0 is a neutral lamp
    double lift[3] = {0, 0, 0};          // L_l, density
    double knee[3] = {0, 0, 0};          // log10 H
    double delta[3] = {0, 0, 0};         // log10 H
    bool shifted_ok[3] = {false, false, false};
    double density_at_knee[3] = {0, 0, 0};   // dk
    double density_min[3] = {0, 0, 0};       // D_min of the film's curve
    double hdr_min[3] = {0, 0, 0};           // D''_min
    Vec develop;                 // (K, 3) row-major: the curves the develop reads (D'' mapped)
};

// The knees and the shifts for the lifts `model.lift`, and the curves the
// develop reads, from a positive film's normalised curves (K, 3), density
// falling with exposure. False, with a message, when a layer has no knee past
// mid-grey.
bool scan_hdr_shift(const Vec& log_exposure, const Vec& curves, ScanHdrModel& model, std::string& error);

// The scanner's integral on one pixel of per-layer densities: XYZ, the
// illuminant's Y = 1.
using ScanXYZ = void (*)(const double cmy[3], const void* context, double xyz[3]);

// Y_white, k and the three lifts: the clear base's densities lowered by L_l
// scan to k x the clear base's XYZ (Newton on log XYZ). `model.headroom` and
// `stretch` set.
bool scan_hdr_lift(const Vec& curves, ScanXYZ scan_xyz, const void* context, ScanHdrModel& model,
                   std::string& error);

// The kernel's table: {dk_l, s_l} x 3.
void scan_hdr_scan_table(const ScanHdrModel& model, double out[6]);

}  // namespace spk
