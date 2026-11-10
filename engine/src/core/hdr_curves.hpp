// hdr_curves.hpp -- Enable HDR's gain curve, made per session from the medium it prints.
//
// PRD/HDR-PORT-PLAN-2026-11-06.md D1. A fixed per-pair table baked at product defaults with minilab
// off would ignore Exp. Comp., print exposure and the enlarger. The Mac exposes all three and its
// default pair prints through minilab, so here the curve is the session's own: family A (the research's
// `rfc/audits/hdr-density-2026-11-03/research/model2.py` `model_A`, `gain_table`, `finish_table`,
// and model.py's `Medium`, `family_A`, `ease_top`), computed from the same medium ramp
// `spk_scene_latitude` measures and replies with. Nothing is shipped as data; the arithmetic is
// compiled. `spk_session_hdr_curve` (engine.cpp) is the entry point.
//
// The grain-aware tables over a curve (Ks, the curve smoothed by 0.12 stop in log2 Y; rho, its slope;
// kappa 1.0 and rho_max 2.0) are `HdrCurveStore::derive`'s, kept to the line: the same curve must give
// the kernels the same numbers wherever it is derived. No curve file or store sits around it -- the
// desktop ships no curve data -- so this file opens no path (and so needs no `file_path`).
//
// What family A is, in the research's words: M(EV) is log2 Y of the print against scene stops (the
// medium ramp); gamma0 = (M(+1) - M(-1)) / 2 is the print's gamma at mid-grey; the knee EV_k is the
// first EV > 0 where dM/dEV falls below 0.8 gamma0 (the slope crossing interpolated); delta solves
// H 2^M(EV_k - delta) = 2^M(EV_k). Below the knee M_H = M; above it
//     M_H(EV) = (1 - t) M(EV) + t (log2 H + M(EV - delta)),  t = smoothstep((EV - EV_k) / 1 EV),
// the medium's own shoulder moved right by delta and up by log2 H. The gain is a function of the SDR
// pixel's own luminance only: log2 gain(Y) = M_H(M^-1(log2 Y)) - log2 Y below the picture's white
// Y_w, exactly 0 below the knee, and a straight bridge in log2 Y from Y_w to exactly log2 H at Y = 1;
// clamped to [0, log2 H] and made monotone. 256 samples over log2 Y in [-12, 0].
#pragma once
#include <string>
#include <vector>

namespace spk {

// The two constants the per-pixel grain-gain kernel takes alongside the tables: kappa is the physics
// (the grain's full share of the slope), rho_max caps the restored highlight grain at the mid-tones'
// (`HDRGrainGain`, the owner's R, 2026-11-03).
inline constexpr double kHdrKappa = 1.0;
inline constexpr double kHdrRhoMax = 2.0;
// tau, the clamped base (2026-11-08: the owner chose it on an HDR screen, "C looks right";
// research/hdr-natural-transition-2026-11-08, candidate C): the kernels read the local tone no
// further than tau stops from the pixel's own, L' = own - clamp(own - L, -tau, tau). Inside grain (std
// <= 0.07 stop) nothing changes; across an edge (a branch against the sky) the pixel is read at its own
// tone, so a dark neighbour no longer pulls the sky's gain down (the ring, up to 1.6 stop without it).
// The kernels take it from the session curve's
// reply (`detail_clamp`, API-SPEC §19.2), beside kappa and rho_max. The curve itself is unchanged.
inline constexpr double kHdrDetailClamp = 0.10;
inline constexpr double kHdrSmoothingStops = 0.12;   // Ks: `derive`'s default sigma

// Family A, as `model2.py` writes it for the shipped `A_H4` curves.
inline constexpr double kHdrKneeFraction = 0.8;      // the knee: slope below 0.8 of mid-grey's
inline constexpr double kHdrBlendStops = 1.0;        // the smoothstep over one stop past the knee
inline constexpr double kHdrEaseStops = 0.75;        // `ease_top`'s width into the frame's clip (D2)
inline constexpr double kHdrDefaultHeadroom = 4.0;   // H: A_H4, two stops over SDR white
inline constexpr double kHdrMaxHeadroom = 16.0;      // the wire's `scan_hdr_headroom` ceiling
// The smallest H a request may ask: `derive` clamps Ks at log2 max(H, 1.0001), so
// from here up its `top` is log2 H itself and the reply's `top`, the table's last sample and the
// kernels' clamp are one number (below it the gain is under 1.5e-4 stop: nothing to show).
inline constexpr double kHdrMinHeadroom = 1.0001;
// gamma0 below this is no gamma: mid-grey sits on the medium's white plateau (or its floor), where the
// slope is float noise and the knee search would read noise (measured 2026-11-06 on the reviewers'
// sweep: gamma0 1.5e-7 put a knee at 8.4e8 EV). Every one of the 144 pairs measures 1.14 or more on
// its own axis, so the floor refuses only a medium with no mid-tone, never a real one.
inline constexpr double kHdrMinGamma0 = 0.1;
inline constexpr int kHdrSamples = 256;
inline constexpr double kHdrDomainLo = -12.0, kHdrDomainHi = 0.0;
// The EV grid the model is evaluated on (`model2.py`: np.linspace(-6, 8, 561)), 0.025 stop a step.
inline constexpr double kHdrGridLo = -6.0, kHdrGridHi = 8.0;
inline constexpr int kHdrGridSamples = 561;

inline constexpr const char* kHdrCurveVersion =
    "hdr_curve v1 (family A: knee 0.8 gamma0, 1 EV smoothstep, straight bridge Y_w -> H at Y = 1; "
    "ease_top 0.75 EV at clip_ev; Ks sigma 0.12 stop, kappa 1.0, rho_max 2.0, tau 0.10)";

// One curve as a curve file holds it: 256 log2-gain samples evenly over log2 Y, the headroom they
// were written for, and the domain they span.
struct HdrCurve {
    double domain_log2_y[2] = {kHdrDomainLo, kHdrDomainHi};
    double headroom = 1;
    std::vector<double> log2_gain;    // 256 values, each in 0 ... log2(headroom)
};

// The two tables a curve gives the grain-aware kernels: Ks, the curve smoothed in log2 Y, and rho,
// its slope -- **unclamped**: the kernel applies clamp(rho, 0, rho_max) per pixel
// (`log2 gain = Ks(L) + kappa clamp(rho(L), 0, rho_max) (log2 Y - L)`), so the table carries the
// slope itself. 256 each over the curve's own domain [lo, hi]; `top` is log2 H.
struct HdrTables {
    std::vector<float> ks;
    std::vector<float> slope;
    double lo = 0;
    double hi = 0;
    double top = 0;
};

// Ks and rho for one curve: `HdrCurveStore::derive`, line for line. Pure.
HdrTables hdr_derive_tables(const HdrCurve& curve, double sigma_stops = kHdrSmoothingStops);

// Family A on one medium, and the numbers behind it for a caller to report.
struct HdrFamilyA {
    // The medium as model.py's `Medium` reads it.
    double y_white = 0;          // the ramp's brightest Y (the picture's white)
    double gamma0 = 0;           // (M(+1) - M(-1)) / 2
    double knee_ev = 0;          // EV_k, on the ramp's own axis
    double knee_log2_y = 0;      // M(EV_k)
    double delta = 0;            // the shoulder's shift, stops
    bool eased = false;          // `ease_top` changed the ramp (clip_ev given, and on the grid)
    // The ramps on the model's EV grid (561 points, -6 ... +8 on the ramp's own axis): today's and the
    // expanded one.
    std::vector<double> ev, log2_y, log2_y_hdr;
    HdrCurve curve;              // the 256-sample table, headroom H
};

// `ramp_ev` / `ramp_y`: the medium on its own axis (stops over mid-grey as the probe exposed it -- the
// `spk_scene_latitude` reply's ramp + `medium_shift_ev`, so mid-grey's gamma and the knee are the
// medium's and not wherever Exp. Comp. put the scene; CIE Y of the print). `clip_ev` (may be null) is
// the frame's clip on that same axis; when
// given, `ease_top` flattens the expanded ramp into a plateau there with a C1 join (D2). False, with
// a message, when the medium has no mid-grey on the ramp, no gamma there, no knee past it, or a white
// at or above display white (no room for the bridge).
bool hdr_family_a(const std::vector<double>& ramp_ev, const std::vector<double>& ramp_y, double headroom,
                  const double* clip_ev, HdrFamilyA& out, std::string& error);

}  // namespace spk
