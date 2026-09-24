// latitude_fit.hpp -- RFC-023's Scene Latitude Mapping, the host half.
//
// Everything here is plain arithmetic on the stop axis, with no GPU and no
// pipeline: the curve the kernel evaluates (as the double-precision reference
// the kernel is checked against), the knee solve that turns a pull-back into
// a knee and a room (§9.2), the ISO 6846-style boundaries read off the
// medium probe (§8.2), the scene statistic (§9.1) and the Fit (§9.3).
//
// The split this file keeps is §8.3's: the **descriptor** (the medium's
// boundaries) and the **scene statistic** are measurements, the **pull-backs**
// are UI state, and only the resolved `SceneLatitudeParams` are render state.
// Nothing in here writes a render parameter on its own; `fit()` returns the
// values and the caller sends them as an ordinary params delta.
#pragma once
#include <optional>
#include <string>
#include <vector>

#include "params.hpp"

namespace spk::slm {

// The metered mid-grey every stop on this axis is relative to -- the same
// constant the meter normalises to (`pipeline.cpp`'s `kMidgray`).
constexpr double kMidgray = 0.184;
// The domain guard (§11): `E` is clamped here before the curve.
constexpr double kDomainStops = 24.0;
// The curvature floor on a branch's room (§7.3). `max|f''| = 0.8587/H` at
// m = 2, so half a stop is a peak curvature of 1.7 stop^-2 -- already far
// above the film's own (~0.2), which is why it refuses rather than warns.
constexpr double kMinRoom = 0.5;

// f(E) - E in stops, the lift bounded by `max_lift` through the same
// smooth-min (§15.5). Exactly 0.0 in the core and on a side that is off.
double delta(double E, const SceneLatitudeParams& p);
inline double mapped(double E, const SceneLatitudeParams& p) { return E + delta(E, p); }
// d f / dE, central difference -- a readout, not a render quantity.
double slope(double E, const SceneLatitudeParams& p);

// §9.2's solve, in the highlight orientation: the knee `K` (with room
// `H = C - K`) that lands the scene extreme `a` at `a - N`, under the
// boundary `C`. `nullopt` when the landing is not strictly inside `C`.
// The shadow side is the same call on negated arguments.
std::optional<double> solve_knee(double a, double C, double N, double m);

// The medium, measured by a neutral ramp through the real pipeline (§8.1).
struct Medium {
    std::vector<double> ev;   // the ramp's stops
    std::vector<double> y;    // relative luminance of the finished print
    double y_black = 0.0, y_white = 0.0;
    double shadow_ev = 0.0, highlight_ev = 0.0;   // ISO 6846 boundaries
    bool valid = false;
};
// Fills the boundaries of `m` from its ramp: the highlight end where the
// print reaches 90 % of the way from its black to its white, the shadow end
// 0.04 density above its black (§8.2, and the criterion §15.2 measured).
bool read_boundaries(Medium& m, std::string& error);

// The scene, on the node's own axis (§9.1).
struct SceneStats {
    double p01 = 0, p1 = 0, p50 = 0, p99 = 0, p999 = 0;   // P0.1 ... P99.9
    static constexpr int kBins = 128;
    static constexpr double kLo = -16.0, kHi = 16.0;
    std::vector<double> histogram;   // fraction of the frame per quarter stop
    size_t samples = 0;
};
SceneStats scene_stats(std::vector<double> E);

struct Side {
    bool on = false;
    double pull_back = 0.0;     // N, stops
    double minimum = 0.0;       // a - C: below this the extreme lands past the medium
    double extreme = 0.0;       // a, the scene's robust extreme
    double boundary = 0.0;      // C, the medium's
    double knee = 0.0, room = 0.0;
    double landing = 0.0, slope = 0.0;   // f(a) and f'(a), with the lift bound
};

struct FitIssue { std::string code, side, message; };

struct Fit {
    SceneLatitudeParams params;   // the resolved curve -- what goes on the wire
    Side highlight, shadow;
    std::optional<double> core;   // K_h - K_s, when both sides are on
    std::vector<FitIssue> issues; // empty means valid
    std::vector<FitIssue> warnings; // valid, but read out: the subject is no longer untouched
    bool valid() const { return issues.empty(); }
};

// Which robust extreme each side is fitted to (§9.2, §9.3). The defaults are
// the RFC's P0.1 / P99.9. P99 is §9.3's "protect speculars" variant; P1 on the
// shadow side is what §15.6 measured as the better landing on a real frame,
// where P0.1 took the knee above mid-grey.
struct Extremes {
    bool shadow_p1 = false;
    bool highlight_p99 = false;
};

// The pull-backs, solved against a measured medium and scene. A pull-back of
// 0 (or less) turns that side off. `base` carries the norm, roll-off and lift
// bound through unchanged. The shadow pull-back is the *bounded* lift at the
// extreme -- where the render really lands it -- so the curve is solved for
// the lift the bound brings back to it, and a pull-back at or beyond
// `max_lift` is refused.
Fit fit(const Medium& medium, const SceneStats& scene, double highlight_pull_back,
        double shadow_pull_back, const SceneLatitudeParams& base, const Extremes& at = {});

// §9.3's default policy, which is only a suggestion: land each robust extreme
// `margin` stops inside the medium, turn a side off when the scene already
// fits it, and spend less margin when the knees would cross or a room would
// fall under `kMinRoom`. `margin_used` reports what it spent.
struct Suggestion {
    double highlight_pull_back = 0.0, shadow_pull_back = 0.0;
    double margin_used = 0.0;
    bool found = false;
};
Suggestion suggest(const Medium& medium, const SceneStats& scene, double margin,
                   const SceneLatitudeParams& base, const Extremes& at = {});

}  // namespace spk::slm
