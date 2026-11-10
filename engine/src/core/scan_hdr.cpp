// scan_hdr.cpp -- the HDR scan of a slide (scan_hdr.hpp says why).
#include "scan_hdr.hpp"

#include <algorithm>
#include <cmath>

namespace spk {

namespace {

constexpr double kOneStop = 0.30102999566398120;   // log10 2

double smoothstep(double t) {
    t = std::clamp(t, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// numpy's `np.gradient(d, x)`: second order inside on a non-uniform axis, first order at the ends.
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

}  // namespace

bool scan_hdr_shift(const Vec& log_exposure, const Vec& curves, ScanHdrModel& model, std::string& error) {
    const size_t k = log_exposure.size();
    if (k < 8 || curves.size() != k * 3) { error = "scan_hdr: the film's curves are not (K, 3)"; return false; }
    if (!(model.lift[0] > 0.0 && model.lift[1] > 0.0 && model.lift[2] > 0.0)) {
        error = "scan_hdr: no lift to make";
        return false;
    }
    const Vec& x = log_exposure;
    model.develop.assign(k * 3, 0.0);
    for (int c = 0; c < 3; ++c) {
        Vec d(k), nd(k);
        for (size_t i = 0; i < k; ++i) { d[i] = curves[3 * i + size_t(c)]; nd[i] = -d[i]; }
        // |dD/dlogH|, smoothed over five samples with the ends repeated (the study's
        // `np.convolve(np.pad(slope, 2, mode="edge"), ones(5) / 5, "valid")`).
        const Vec raw = gradient(d, x);
        Vec slope(k);
        for (size_t i = 0; i < k; ++i) {
            double s = 0.0;
            for (int j = -2; j <= 2; ++j) {
                const long at = std::clamp<long>(long(i) + j, 0, long(k) - 1);
                s += std::fabs(raw[size_t(at)]);
            }
            slope[i] = s / 5.0;
        }
        const double xm = 0.0;   // mid-grey's exposure (the study: +0.011 to -0.028 by probe)
        const double sm = interp(xm, x.data(), slope.data(), k);
        size_t i = 0;
        for (size_t j = 0; j < k; ++j)
            if (x[j] > xm && slope[j] <= ScanHdrModel::kKappa * sm) { i = j; break; }
        if (i == 0) {
            error = "scan_hdr: layer " + std::to_string(c) + " has no knee past mid-grey";
            return false;
        }
        const double s0 = slope[i - 1], s1 = slope[i];
        const double xk = s0 != s1 ? x[i - 1] + (x[i] - x[i - 1]) * (s0 - ScanHdrModel::kKappa * sm) / (s0 - s1) : x[i];
        const double dk = interp(xk, x.data(), d.data(), k);
        // The lifted curve, D(logH - delta) - L, goes through the knee: D(xk - delta) = dk + L.
        const double lift = model.lift[c];
        const double dmax = *std::max_element(d.begin(), d.end());
        const double target = dk + lift;
        const bool ok = target <= dmax;
        const double xt = interp(-std::min(target, dmax), nd.data(), x.data(), k);   // D falls with x
        const double delta = xk - xt;
        model.knee[c] = xk;
        model.delta[c] = delta;
        model.shifted_ok[c] = ok;
        model.density_at_knee[c] = dk;
        // D'' = (1 - t) D(x) + t (D(x - delta) - L): below the knee t = 0 and this is D, exactly.
        Vec hdr(k);
        for (size_t j = 0; j < k; ++j) {
            const double t = smoothstep((x[j] - xk) / kOneStop);
            if (t == 0.0) { hdr[j] = d[j]; continue; }
            const double moved = interp(x[j] - delta, x.data(), d.data(), k) - lift;
            hdr[j] = (1.0 - t) * d[j] + t * moved;
        }
        const double dmin = *std::min_element(d.begin(), d.end());
        const double hmin = *std::min_element(hdr.begin(), hdr.end());
        model.density_min[c] = dmin;
        model.hdr_min[c] = hmin;
        if (!(dk - dmin > 1e-6) || !(dk - hmin > 1e-6)) {
            error = "scan_hdr: layer " + std::to_string(c) + " has no range past its knee";
            return false;
        }
        // What the develop reads: D'' below the knee's density mapped from [D''_min, dk] onto
        // [D_min, dk] (grain knows no density below the base); the scan maps it back.
        const double squeeze = (dk - dmin) / (dk - hmin);
        for (size_t j = 0; j < k; ++j) {
            const double v = hdr[j];
            model.develop[3 * j + size_t(c)] = v < dk ? dk - (dk - v) * squeeze : v;
        }
    }
    return true;
}

bool scan_hdr_lift(const Vec& curves, ScanXYZ scan_xyz, const void* context, ScanHdrModel& model,
                   std::string& error) {
    const size_t k = curves.size() / 3;
    if (k == 0) { error = "scan_hdr: no curves"; return false; }
    double base[3];
    for (int c = 0; c < 3; ++c) {
        base[c] = curves[size_t(c)];
        for (size_t i = 0; i < k; ++i) base[c] = std::min(base[c], curves[3 * i + size_t(c)]);
    }
    double white[3];
    scan_xyz(base, context, white);
    model.y_white = white[1];
    if (!(white[0] > 0.0 && white[1] > 0.0 && white[2] > 0.0)) { error = "scan_hdr: the clear base scans black"; return false; }
    if (model.stretch) model.headroom = ScanHdrModel::kPageWhite / model.y_white;
    model.y_target = model.headroom * model.y_white;
    if (!(model.headroom > 1.0)) { error = "scan_hdr: a headroom above 1 is needed"; return false; }
    // F(L) = log XYZ(base - L) - log(k XYZ_white): Newton with a forward-difference Jacobian,
    // from one lift for all three (log10 k). A step is halved until it lowers |F|.
    const double goal[3] = {std::log(model.headroom * white[0]), std::log(model.headroom * white[1]),
                            std::log(model.headroom * white[2])};
    auto residual = [&](const double L[3], double f[3]) {
        const double cmy[3] = {base[0] - L[0], base[1] - L[1], base[2] - L[2]};
        double xyz[3];
        scan_xyz(cmy, context, xyz);
        double worst = 0.0;
        for (int i = 0; i < 3; ++i) {
            f[i] = std::log(std::max(xyz[i], 1e-30)) - goal[i];
            worst = std::max(worst, std::fabs(f[i]));
        }
        return worst;
    };
    double L[3] = {std::log10(model.headroom), std::log10(model.headroom), std::log10(model.headroom)};
    double f[3];
    double worst = residual(L, f);
    for (int it = 0; it < 60 && worst > 1e-12; ++it) {
        Mat3 J;
        const double h = 1e-6;
        for (int j = 0; j < 3; ++j) {
            double Lh[3] = {L[0], L[1], L[2]}, fh[3];
            Lh[j] += h;
            residual(Lh, fh);
            for (int i = 0; i < 3; ++i) J.m[i][j] = (fh[i] - f[i]) / h;
        }
        const Mat3 inv = J.inverse();
        double step[3];
        for (int i = 0; i < 3; ++i) step[i] = -(inv.m[i][0] * f[0] + inv.m[i][1] * f[1] + inv.m[i][2] * f[2]);
        double scale = 1.0, next[3], fn[3], w = worst;
        for (int tries = 0; tries < 30; ++tries, scale *= 0.5) {
            for (int i = 0; i < 3; ++i) next[i] = L[i] + scale * step[i];
            w = residual(next, fn);
            if (w < worst) break;
        }
        if (!(w < worst)) break;
        for (int i = 0; i < 3; ++i) { L[i] = next[i]; f[i] = fn[i]; }
        worst = w;
    }
    if (!(worst < 1e-6) || !(L[0] > 0.0 && L[1] > 0.0 && L[2] > 0.0)) {
        error = "scan_hdr: the clear base cannot be lifted to its target without a tint";
        return false;
    }
    for (int c = 0; c < 3; ++c) model.lift[c] = L[c];
    model.tint = worst;
    const double cmy[3] = {base[0] - L[0], base[1] - L[1], base[2] - L[2]};
    double xyz[3];
    scan_xyz(cmy, context, xyz);
    model.y_reached = xyz[1];
    return true;
}

void scan_hdr_scan_table(const ScanHdrModel& model, double out[6]) {
    for (int c = 0; c < 3; ++c) {
        const double dk = model.density_at_knee[c];
        out[2 * c] = dk;
        out[2 * c + 1] = (dk - model.hdr_min[c]) / (dk - model.density_min[c]);
    }
}

}  // namespace spk
