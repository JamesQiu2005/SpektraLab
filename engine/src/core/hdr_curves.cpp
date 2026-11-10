#include "hdr_curves.hpp"

#include <algorithm>
#include <cmath>

#include "numeric.hpp"

namespace spk {

namespace {

// numpy's `np.gradient(d, x)`: second order inside on a non-uniform axis, first order at the ends
// (`edge_order=1`, numpy's default). The same function `scan_hdr.cpp` carries; the ramp's axis is
// uniform in exact arithmetic but not in its doubles, so numpy took this branch on it too.
Vec gradient(const Vec& d, const Vec& x) {
    const size_t k = d.size();
    Vec g(k, 0.0);
    if (k < 2) return g;
    g[0] = (d[1] - d[0]) / (x[1] - x[0]);
    g[k - 1] = (d[k - 1] - d[k - 2]) / (x[k - 1] - x[k - 2]);
    for (size_t i = 1; i + 1 < k; ++i) {
        const double hd = x[i] - x[i - 1], hs = x[i + 1] - x[i];
        const double a = -hs / (hd * (hd + hs)), b = (hs - hd) / (hd * hs), c = hd / (hs * (hd + hs));
        g[i] = a * d[i - 1] + b * d[i] + c * d[i + 1];
    }
    return g;
}

// numpy's `np.linspace(lo, hi, n)`: `arange(n) * step + lo`, the last sample set to `hi` exactly.
Vec linspace(double lo, double hi, int n) {
    Vec v(static_cast<size_t>(n));
    const double step = (hi - lo) / double(n - 1);
    for (int i = 0; i < n; ++i) v[size_t(i)] = double(i) * step + lo;
    v[size_t(n - 1)] = hi;
    return v;
}

double smoothstep01(double t) {
    t = std::clamp(t, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

double at(const Vec& x, const Vec& y, double v) { return interp(v, x.data(), y.data(), x.size()); }

}  // namespace

// `HdrCurveStore::derive` (the Swift `HDRGrainGain.tables` it replaced): Ks is the
// curve smoothed by `sigma_stops` in log2 Y with its ends held, rho its slope. In double throughout,
// cast to float at the door, so the kernels read the reference's numbers to float rounding.
HdrTables hdr_derive_tables(const HdrCurve& curve, double sigma_stops) {
    const int n = static_cast<int>(curve.log2_gain.size());
    const double lo = curve.domain_log2_y[0], hi = curve.domain_log2_y[1];
    const double step = (hi - lo) / std::max(n - 1, 1);
    const double top = std::log2(std::max(curve.headroom, 1.0001));
    const double s = sigma_stops / step;
    const int r = static_cast<int>(std::ceil(3 * s));
    const double two_s2 = 2 * std::max(s, 1e-6) * std::max(s, 1e-6);

    std::vector<double> w(size_t(2 * r + 1), 0.0);
    double ws = 0;
    for (int j = -r; j <= r; ++j) { const double v = std::exp(-double(j * j) / two_s2); w[size_t(j + r)] = v; ws += v; }

    std::vector<double> ks(size_t(n), 0.0);
    for (int i = 0; i < n; ++i) {
        double acc = 0;
        for (int j = -r; j <= r; ++j) acc += w[size_t(j + r)] * curve.log2_gain[size_t(std::min(std::max(i + j, 0), n - 1))];
        ks[size_t(i)] = std::min(std::max(acc / ws, 0.0), top);
    }
    std::vector<double> slope(size_t(n), 0.0);
    for (int i = 0; i < n; ++i) {
        const int a = std::max(i - 1, 0), b = std::min(i + 1, n - 1);
        slope[size_t(i)] = (ks[size_t(b)] - ks[size_t(a)]) / (double(b - a) * step);
    }

    HdrTables t;
    t.ks.resize(size_t(n));
    t.slope.resize(size_t(n));
    for (int i = 0; i < n; ++i) { t.ks[size_t(i)] = float(ks[size_t(i)]); t.slope[size_t(i)] = float(slope[size_t(i)]); }
    t.lo = lo;
    t.hi = hi;
    t.top = top;
    return t;
}

// model.py's `Medium`, `family_A` and `ease_top`, and model2.py's `gain_table` and `finish_table`,
// statement for statement (numpy's `interp`, `gradient` and `linspace` as above). Where the Python
// would raise -- an IndexError for a medium with no knee, the `assert` on the table's ends -- this
// refuses with the reason.
bool hdr_family_a(const std::vector<double>& ramp_ev, const std::vector<double>& ramp_y, double headroom,
                  const double* clip_ev, HdrFamilyA& out, std::string& error) {
    out = HdrFamilyA{};
    const size_t n = ramp_ev.size();
    if (n < 3 || ramp_y.size() != n) { error = "hdr curve: the medium has no ramp"; return false; }
    if (!(headroom >= kHdrMinHeadroom) || !(headroom <= kHdrMaxHeadroom)) {
        error = "hdr curve: headroom must be in [1.0001, 16]";
        return false;
    }
    for (size_t i = 0; i < n; ++i) {
        if (!std::isfinite(ramp_ev[i]) || !std::isfinite(ramp_y[i]) || (i && !(ramp_ev[i] > ramp_ev[i - 1]))) {
            error = "hdr curve: the medium's ramp is not finite and increasing in EV";
            return false;
        }
    }

    // --- the medium (model.py `Medium`, knee_frac 0.8) ----------------------------------------------
    const Vec& ev = ramp_ev;
    Vec ly(n);
    double yw = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const double y = std::max(ramp_y[i], 1e-7);
        ly[i] = std::log2(y);
        yw = std::max(yw, y);
    }
    const double lyw = std::log2(yw);
    const Vec s = gradient(ly, ev);
    const double g0 = (at(ev, ly, 1.0) - at(ev, ly, -1.0)) / 2.0;
    if (!(ev.front() <= 0.0)) { error = "hdr curve: the medium's ramp starts above mid-grey"; return false; }
    // A floor, not `> 0`: on the white plateau the slope is float noise, and an exact test made one
    // physical case refuse or return a knee 1e8 EV out depending on that noise (kHdrMinGamma0).
    if (!(g0 >= kHdrMinGamma0)) { error = "hdr curve: the medium has no gamma at mid-grey"; return false; }
    size_t ik = 0;
    for (size_t i = 0; i < n; ++i)
        if (ev[i] > 0.0 && s[i] < kHdrKneeFraction * g0) { ik = i; break; }
    if (ik == 0) { error = "hdr curve: the medium has no knee past mid-grey"; return false; }
    // The knee, refined by interpolating the slope crossing -- held to its own bracket [e0, e1]. Where
    // the sample before it (at or below EV 0) is already under 0.8 gamma0 there is no crossing inside
    // the bracket, and model.py's formula extrapolates without limit (s1 ~ s0 gave 8.4e8 EV here, numpy
    // inf). Inside the bracket the clamp is the identity, so every curve the model gives is unchanged
    // (hdr_curve_checks.py check 2 holds the table to model2.py on all 144 pairs).
    const double e0 = ev[ik - 1], e1 = ev[ik], s0 = s[ik - 1], s1 = s[ik];
    const double ev_k = std::clamp(s1 != s0 ? e0 + (kHdrKneeFraction * g0 - s0) / (s1 - s0) * (e1 - e0) : e1,
                                   e0, e1);
    const double ly_k = at(ev, ly, ev_k);
    // M^-1 on the rising part only: up to the first brightest sample.
    const size_t imax = size_t(std::max_element(ly.begin(), ly.end()) - ly.begin());
    const Vec inv_x(ly.begin(), ly.begin() + long(imax) + 1), inv_y(ev.begin(), ev.begin() + long(imax) + 1);
    auto inv = [&](double v) { return interp(v, inv_x.data(), inv_y.data(), inv_x.size()); };

    // --- family A (model.py `family_A`, w = 1) -------------------------------------------------------
    const double log2H = std::log2(headroom);
    const double delta = ev_k - inv(ly_k - log2H);
    const Vec grid = linspace(kHdrGridLo, kHdrGridHi, kHdrGridSamples);
    Vec m(grid.size()), hdr(grid.size());
    for (size_t i = 0; i < grid.size(); ++i) {
        m[i] = at(ev, ly, grid[i]);
        if (grid[i] <= ev_k) { hdr[i] = m[i]; continue; }
        const double t = smoothstep01((grid[i] - ev_k) / kHdrBlendStops);
        hdr[i] = (1.0 - t) * m[i] + t * (log2H + at(ev, ly, grid[i] - delta));
    }

    // --- D2: ease into the frame's clip (model.py `ease_top`, w 0.75) -------------------------------
    // A cubic Hermite from (a, M_H(a), M_H'(a)) to (clip, top, 0), top = M_H(a) + M_H'(a) w / 2, and
    // the plateau at `top` from the clip on: a clipped region ends flat with a C1 join, never a crease.
    bool eased = false;
    if (clip_ev) {
        const double w = kHdrEaseStops, a = *clip_ev - w;
        const Vec dh = gradient(hdr, grid);           // of the un-eased ramp, as `np.gradient(ly, ev)`
        const double la = at(grid, hdr, a), sa = at(grid, dh, a);
        const double top = la + sa * w / 2.0;
        for (size_t i = 0; i < grid.size(); ++i) {
            if (!(grid[i] > a)) continue;
            const double t = std::clamp((grid[i] - a) / w, 0.0, 1.0);
            const double h00 = 2 * t * t * t - 3 * t * t + 1, h10 = t * t * t - 2 * t * t + t,
                         h01 = -2 * t * t * t + 3 * t * t;
            hdr[i] = h00 * la + h10 * sa * w + h01 * top;
            eased = true;
        }
        for (size_t i = 0; i < grid.size(); ++i)
            if (grid[i] >= *clip_ev) hdr[i] = top;
    }

    // --- the table (model2.py `gain_table` + `finish_table`) -----------------------------------------
    if (!(lyw < kHdrDomainHi)) {
        error = "hdr curve: the medium's white reaches display white, so there is no bridge to H";
        return false;
    }
    const Vec tab = linspace(kHdrDomainLo, kHdrDomainHi, kHdrSamples);
    Vec g(tab.size());
    for (size_t j = 0; j < tab.size(); ++j) {
        const double e = inv(std::min(tab[j], lyw - 1e-6));
        g[j] = tab[j] < ly_k ? 0.0 : at(grid, hdr, e) - tab[j];
    }
    // gw: the gain at the last sample below the picture's white.
    size_t last_below = tab.size();
    for (size_t j = 0; j < tab.size(); ++j) if (tab[j] < lyw) last_below = j;
    if (last_below == tab.size()) { error = "hdr curve: the medium's white is below the table's domain"; return false; }
    const double gw = g[last_below];
    // From Y_w up to Y = 1 (a film edge's hole, a slide's clear base, the bare pad) a straight bridge
    // in log2 Y to exactly log2 H, so the lamp is reached at the lamp.
    const double span = std::max(0.0 - lyw, 1e-6);
    for (size_t j = 0; j < tab.size(); ++j)
        if (tab[j] >= lyw) g[j] = gw + (log2H - gw) * (tab[j] - lyw) / span;
    double run = 0.0;
    for (size_t j = 0; j < tab.size(); ++j) {
        g[j] = std::clamp(g[j], 0.0, log2H);
        run = j ? std::max(run, g[j]) : g[j];        // monotone, as the model is (np.maximum.accumulate)
        g[j] = run;
    }
    g.back() = log2H;                                 // exactly, as `curve_file` writes it

    out.y_white = yw;
    out.gamma0 = g0;
    out.knee_ev = ev_k;
    out.knee_log2_y = ly_k;
    out.delta = delta;
    out.eased = eased;
    out.ev = grid;
    out.log2_y = std::move(m);
    out.log2_y_hdr = std::move(hdr);
    out.curve.headroom = headroom;
    out.curve.log2_gain = std::move(g);
    for (double v : out.curve.log2_gain)
        if (!std::isfinite(v)) { error = "hdr curve: the table is not finite"; return false; }
    return true;
}

}  // namespace spk
