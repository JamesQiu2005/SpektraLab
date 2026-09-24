#include "latitude_fit.hpp"

#include <algorithm>
#include <cmath>

namespace spk::slm {

namespace {

// `g_m(D) = D H / (H^m + D^m)^(1/m) - D`, the branch's departure from the
// identity, in the forms that do not cancel near the knee (§5.6): at m = 2
// `-D^3 / (r (H + r))` with `r = sqrt(H^2 + D^2)`, at m = 1 `-D^2 / (H + D)`.
// Negative for every D > 0, and exactly 0 at D = 0.
double departure(double D, double H, double m) {
    if (!(D > 0.0)) return 0.0;
    if (m == 2.0) {
        const double r = std::sqrt(H * H + D * D);
        return -(D * D * D) / (r * (H + r));
    }
    if (m == 1.0) return -(D * D) / (H + D);
    return D * (H / std::pow(std::pow(H, m) + std::pow(D, m), 1.0 / m) - 1.0);
}

double g(double D, double H, double m) { return D + departure(D, H, m); }

// The lift bound: the same smooth-min at m = 2, so the curve stays C1 and
// relaxes to slope 1 once the gain reaches `L` (§15.5).
double bound_lift(double d, double L) { return d > 0.0 ? d * L / std::sqrt(L * L + d * d) : d; }

// `P(q)` at 0-based rank `q * (n - 1) / 10000` in exact integer division --
// the meter's discipline (`exposure_evs_from`), one decimal finer.
double rank(std::vector<double>& v, int per_ten_thousand) {
    const size_t k = (size_t(per_ten_thousand) * (v.size() - 1)) / 10000u;
    std::nth_element(v.begin(), v.begin() + std::ptrdiff_t(k), v.end());
    return v[k];
}

}  // namespace

double delta(double E, const SceneLatitudeParams& p) {
    const double Ep = std::clamp(E, -kDomainStops, kDomainStops);
    double d = 0.0;
    if (p.highlight_room > 0.0 && Ep > p.highlight_knee)
        d = departure(Ep - p.highlight_knee, p.highlight_room, p.rolloff);
    else if (p.shadow_room > 0.0 && Ep < p.shadow_knee)
        d = -departure(p.shadow_knee - Ep, p.shadow_room, p.rolloff);
    return bound_lift(d, p.max_lift);
}

double slope(double E, const SceneLatitudeParams& p) {
    constexpr double h = 1e-4;
    return (mapped(E + h, p) - mapped(E - h, p)) / (2.0 * h);
}

std::optional<double> solve_knee(double a, double C, double N, double m) {
    const double t = a - N;
    if (!(N > 0.0) || !(t < C)) return std::nullopt;
    // f(a) = K + g(a - K, C - K) rises monotonically with K, from -inf toward
    // C as K -> t, and equals t nowhere above t: bracketed, so bisection
    // cannot fail. The m = 1 closed form is the seed's neighbourhood (§9.2).
    auto landing = [&](double K) { return K + g(a - K, C - K, m); };
    const double seed = t - std::sqrt(std::max(0.0, (a - t) * (C - t)));
    double lo = seed - 64.0, hi = t;
    if (!(landing(lo) < t)) return std::nullopt;
    for (int i = 0; i < 200 && hi - lo > 1e-12; ++i) {
        const double mid = 0.5 * (lo + hi);
        (landing(mid) > t ? hi : lo) = mid;
    }
    return 0.5 * (lo + hi);
}

bool read_boundaries(Medium& m, std::string& error) {
    m.valid = false;
    const size_t n = m.ev.size();
    if (n < 2 || m.y.size() != n) { error = "scene latitude: the medium probe returned no ramp"; return false; }
    m.y_black = *std::min_element(m.y.begin(), m.y.end());
    m.y_white = *std::max_element(m.y.begin(), m.y.end());
    if (!(m.y_black > 0.0) || !(m.y_white > m.y_black)) {
        error = "scene latitude: the medium probe's print has no tonal range";
        return false;
    }
    const double t_hi = m.y_black + 0.90 * (m.y_white - m.y_black);
    const double t_lo = m.y_black * std::pow(10.0, 0.04);
    auto cross = [&](double target, double& at) {
        for (size_t i = 0; i + 1 < n; ++i) {
            const double a = m.y[i], b = m.y[i + 1];
            if ((a - target) * (b - target) <= 0.0 && b != a) {
                at = m.ev[i] + (target - a) / (b - a) * (m.ev[i + 1] - m.ev[i]);
                return true;
            }
        }
        return false;
    };
    if (!cross(t_lo, m.shadow_ev) || !cross(t_hi, m.highlight_ev) || !(m.shadow_ev < m.highlight_ev)) {
        error = "scene latitude: the medium's boundaries do not lie inside the probe's range";
        return false;
    }
    m.valid = true;
    return true;
}

SceneStats scene_stats(std::vector<double> E) {
    SceneStats s;
    s.samples = E.size();
    s.histogram.assign(SceneStats::kBins, 0.0);
    if (E.empty()) return s;
    const double width = (SceneStats::kHi - SceneStats::kLo) / SceneStats::kBins;
    for (double e : E) {
        const int b = std::clamp(int(std::floor((e - SceneStats::kLo) / width)), 0, SceneStats::kBins - 1);
        s.histogram[size_t(b)] += 1.0 / double(E.size());
    }
    s.p01 = rank(E, 10);
    s.p1 = rank(E, 100);
    s.p50 = rank(E, 5000);
    s.p99 = rank(E, 9900);
    s.p999 = rank(E, 9990);
    return s;
}

Fit fit(const Medium& medium, const SceneStats& scene, double highlight_pull_back,
        double shadow_pull_back, const SceneLatitudeParams& base, const Extremes& at) {
    Fit out;
    out.params = base;
    out.params.active = true;
    out.params.highlight_room = 0.0;
    out.params.shadow_room = 0.0;
    const double m = base.rolloff;

    Side& hs = out.highlight;
    hs.extreme = at.highlight_p99 ? scene.p99 : scene.p999;
    hs.boundary = medium.highlight_ev;
    hs.minimum = hs.extreme - hs.boundary;
    hs.pull_back = highlight_pull_back;
    if (highlight_pull_back > 0.0) {
        if (auto K = solve_knee(hs.extreme, hs.boundary, highlight_pull_back, m)) {
            hs.on = true;
            hs.knee = *K;
            hs.room = hs.boundary - *K;
        } else {
            out.issues.push_back({"pull_back_below_minimum", "highlight",
                                  "the highlight pull-back lands the scene's top at or past the "
                                  "medium's boundary; it must exceed the minimum"});
        }
    }

    Side& ss = out.shadow;
    ss.extreme = at.shadow_p1 ? scene.p1 : scene.p01;
    ss.boundary = medium.shadow_ev;
    ss.minimum = ss.boundary - ss.extreme;
    ss.pull_back = shadow_pull_back;
    // The lift is bounded after the curve (§15.5), so the landing the user asks
    // for is the *bounded* one: invert the bound first, and solve the curve for
    // the unbounded lift that the bound then brings back to `N`. Without this
    // the readout promises a landing the render does not make -- on a real frame
    // a 3.24-stop pull-back landed 0.72 stop short, outside the medium.
    std::optional<double> shadow_lift;
    if (shadow_pull_back > 0.0 && !(shadow_pull_back > ss.minimum)) {
        // Checked here, on the bounded landing, because the solve below sees
        // only the inverted lift and would accept a landing past the medium.
        out.issues.push_back({"pull_back_below_minimum", "shadow",
                              "the shadow pull-back lands the scene's bottom at or past the "
                              "medium's boundary; it must exceed the minimum"});
    } else if (shadow_pull_back > 0.0) {
        const double L = base.max_lift;
        if (shadow_pull_back < L)
            shadow_lift = shadow_pull_back * L / std::sqrt(L * L - shadow_pull_back * shadow_pull_back);
        else
            out.issues.push_back({"pull_back_exceeds_max_lift", "shadow",
                                  "the shadow pull-back is at or beyond the lift bound; raise "
                                  "max_lift or pull back less"});
    }
    if (shadow_lift) {
        if (auto K = solve_knee(-ss.extreme, -ss.boundary, *shadow_lift, m)) {
            ss.on = true;
            ss.knee = -*K;
            ss.room = ss.knee - ss.boundary;
        } else {
            out.issues.push_back({"pull_back_below_minimum", "shadow",
                                  "the shadow pull-back lands the scene's bottom at or past the "
                                  "medium's boundary; it must exceed the minimum"});
        }
    }

    for (Side* s : {&hs, &ss}) {
        if (!s->on) continue;
        const char* name = s == &hs ? "highlight" : "shadow";
        if (s->room < kMinRoom)
            out.issues.push_back({"room_below_minimum", name,
                                  "the knee sits too close to the medium's boundary: the turn "
                                  "would be sharper than the curvature floor allows"});
        if (s->room > kDomainStops || std::fabs(s->knee) > kDomainStops)
            out.issues.push_back({"out_of_range", name, "the solved knee or room is outside the wire's range"});
    }
    if (hs.on && ss.on) {
        out.core = hs.knee - ss.knee;
        if (!(ss.knee < hs.knee))
            out.issues.push_back({"knees_cross", "both",
                                  "the two knees cross: the pull-backs ask for more than the "
                                  "medium holds; back one of them off"});
    }

    // §15.6: "at K_s = +0.94 the knee has climbed above mid-grey and the
    // picture starts to go flat". The metered mid-grey is where the subject was
    // placed, so a knee past it means the curve now moves the subject -- legal,
    // and read out rather than refused.
    if (hs.on && hs.knee < 0.0)
        out.warnings.push_back({"knee_past_midgrey", "highlight",
                                "the highlight knee is below the metered mid-grey: the subject "
                                "is no longer in the untouched core"});
    if (ss.on && ss.knee > 0.0)
        out.warnings.push_back({"knee_past_midgrey", "shadow",
                                "the shadow knee is above the metered mid-grey: the subject is "
                                "no longer in the untouched core"});

    if (hs.on) { out.params.highlight_knee = hs.knee; out.params.highlight_room = hs.room; }
    if (ss.on) { out.params.shadow_knee = ss.knee; out.params.shadow_room = ss.room; }
    for (Side* s : {&hs, &ss}) {
        s->landing = mapped(s->extreme, out.params);
        s->slope = slope(s->extreme, out.params);
    }
    return out;
}

Suggestion suggest(const Medium& medium, const SceneStats& scene, double margin,
                   const SceneLatitudeParams& base, const Extremes& at) {
    Suggestion best;
    const double over_h = (at.highlight_p99 ? scene.p99 : scene.p999) - medium.highlight_ev;
    const double over_s = medium.shadow_ev - (at.shadow_p1 ? scene.p1 : scene.p01);
    // Walk the margin down from what was asked: less margin lands the extremes
    // nearer the boundary, which widens the core and narrows the rooms, so the
    // first valid step is the most margin that works.
    constexpr int kSteps = 64;
    for (int i = 0; i <= kSteps; ++i) {
        const double mg = margin * double(kSteps - i) / double(kSteps);
        const double nh = over_h > 0.0 ? over_h + mg : 0.0;
        const double ns = over_s > 0.0 ? over_s + mg : 0.0;
        const Fit f = fit(medium, scene, nh, ns, base, at);
        if (f.valid()) {
            best = {nh, ns, mg, true};
            return best;
        }
    }
    best.highlight_pull_back = over_h > 0.0 ? over_h + margin : 0.0;
    best.shadow_pull_back = over_s > 0.0 ? over_s + margin : 0.0;
    best.margin_used = margin;
    return best;
}

}  // namespace spk::slm
