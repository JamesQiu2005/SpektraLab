// diffusion_psf.cpp -- see diffusion_psf.hpp. Every function here is the
// oracle's (`spektrafilm/model/diffusion.py`) of the same name, in its order of
// operations, including numpy's: `sum` is `a[0] + (a[1] + ...)` as numpy's
// reduction is, `linspace` sets its last point to the stop exactly, `interp`
// is numpy's C loop.
#include "diffusion_psf.hpp"

#include <algorithm>
#include <cmath>

namespace spk::diffusion {

namespace {

// `_DIFFUSION_FILTER_SHAPES`, in the oracle's order.
struct Named { const char* name; FamilyShape shape; double gain; };
const Named kFamilies[] = {
    {"glimmerglass",   {{10.0, 1.5, 2, 3.0}, {50.0, 2.0, 3, 3.0}, {260.0, 2.5, 4, 3.2}, 0.60, 0.30, 0.10, 0.0}, 0.65},
    {"black_pro_mist", {{16.0, 1.5, 2, 3.0}, {95.0, 2.0, 3, 3.0}, {380.0, 2.5, 4, 3.5}, 0.40, 0.47, 0.13, 0.65}, 0.75},
    {"pro_mist",       {{14.0, 1.5, 2, 3.0}, {150.0, 2.0, 3, 3.0}, {650.0, 2.5, 4, 2.9}, 0.28, 0.42, 0.30, 0.40}, 1.05},
    {"cinebloom",      {{20.0, 1.5, 2, 3.0}, {200.0, 2.0, 3, 3.0}, {1000.0, 2.5, 4, 2.5}, 0.22, 0.30, 0.48, 0.85}, 1.00},
};

// `_DIFFUSION_STRENGTH_BREAKPOINTS`, `_DIFFUSION_STRENGTH_TOTAL_FRACTION`.
constexpr double kBreaks[5] = {0.125, 0.25, 0.5, 1.0, 2.0};
constexpr double kFraction[5] = {0.10, 0.20, 0.35, 0.55, 0.75};

// `_HALO_CHANNEL_WARMTH_AXIS`.
constexpr double kWarmthAxis[3] = {+1.30, +0.15, -1.45};

// numpy's `ndarray.sum()` of a short 1-D float64 array: the reduction seeds
// with the first element and adds the pairwise sum of the rest, which below 8
// elements is a plain loop from 0.
double np_sum(const std::vector<double>& v) {
    if (v.empty()) return 0.0;
    double rest = 0.0;
    for (size_t i = 1; i < v.size(); ++i) rest += v[i];
    return v[0] + rest;
}

// `np.linspace(lo, hi, n)` (endpoint, n > 1).
std::vector<double> np_linspace(double lo, double hi, int n) {
    std::vector<double> y(static_cast<size_t>(n));
    const double step = (hi - lo) / double(n - 1);
    for (int i = 0; i < n; ++i) y[size_t(i)] = double(i) * step + lo;
    y[size_t(n - 1)] = hi;
    return y;
}

// `np.interp(x, xp, fp)` for a scalar x, numpy's compiled loop.
double np_interp(double x, const double* xp, const double* fp, int n) {
    if (x < xp[0]) return fp[0];
    if (x > xp[n - 1]) return fp[n - 1];
    int j = 0;
    while (j + 1 < n && xp[j + 1] <= x) ++j;   // xp[j] <= x < xp[j + 1]
    if (j == n - 1) return fp[j];
    if (xp[j] == x) return fp[j];
    const double slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j]);
    return slope * (x - xp[j]) + fp[j];
}

}  // namespace

const FamilyShape* family_shape(const std::string& family) {
    for (const Named& f : kFamilies)
        if (family == f.name) return &f.shape;
    return nullptr;
}

double family_gain(const std::string& family) {
    for (const Named& f : kFamilies)
        if (family == f.name) return f.gain;
    return 1.0;
}

const std::vector<std::string>& families() {
    // Never destroyed: read by a render, which may still run while `exit()` tears the statics down (colour.cpp).
    static const auto& names = *new const std::vector<std::string>([] {
        std::vector<std::string> n;
        for (const Named& f : kFamilies) n.push_back(f.name);
        return n;
    }());
    return names;
}

double strength_to_scatter(double strength, const std::string& family) {
    if (strength <= 0) return 0.0;
    const double log_strength = std::log2(std::max(strength, 1e-6));
    double log_breaks[5];
    for (int i = 0; i < 5; ++i) log_breaks[i] = std::log2(kBreaks[i]);
    const double base_total = np_interp(log_strength, log_breaks, kFraction, 5);
    const double gain = family_gain(family);
    return std::clamp(base_total * gain, 0.0, 0.99);
}

void expand_group(const GroupShape& group, bool bloom, std::vector<double>& lambdas,
                  std::vector<double>& weights) {
    const double lambda_center = group.lambda_um;
    const double spread = group.spread;
    const int n = std::max(group.n_components, 1);
    if (n == 1 || spread <= 1.0) {
        lambdas = {lambda_center};
        weights = {1.0};
        return;
    }
    const double log_lo = std::log(lambda_center / spread);
    const double log_hi = std::log(lambda_center * spread);
    lambdas = np_linspace(log_lo, log_hi, n);
    for (double& l : lambdas) l = std::exp(l);
    weights.assign(size_t(n), 1.0);
    if (bloom)
        for (int k = 0; k < n; ++k) weights[size_t(k)] = std::pow(lambdas[size_t(k)], 2.0 - group.alpha);
    const double total = np_sum(weights);
    for (double& w : weights) w = w / total;
}

void halo_channel_weights(const std::vector<double>& weights, double warmth,
                          std::vector<double> out[3]) {
    const size_t n = weights.size();
    if (n < 2) {
        for (int c = 0; c < 3; ++c) out[c] = weights;
        return;
    }
    warmth = std::clamp(warmth, -1.5, 1.5);
    std::vector<double> g = np_linspace(-1.0, 1.0, int(n));
    // `np.average(g, weights=weights)`: (g * w).sum() / w.sum()
    std::vector<double> gw(n);
    for (size_t k = 0; k < n; ++k) gw[k] = g[k] * weights[k];
    const double avg = np_sum(gw) / np_sum(weights);
    for (double& v : g) v = v - avg;
    const double target_total = np_sum(weights);
    for (int c = 0; c < 3; ++c) {
        std::vector<double> raw(n);
        for (size_t k = 0; k < n; ++k)
            raw[k] = std::max(weights[k] * (1.0 + warmth * kWarmthAxis[c] * g[k]), 0.0);
        const double s = np_sum(raw);
        if (s > 0.0) {
            out[c].resize(n);
            for (size_t k = 0; k < n; ++k) out[c][k] = raw[k] * (target_total / s);
        } else {
            out[c] = weights;
        }
    }
}

FamilyShape resolve_family(const FamilyShape& base, const DiffusionFilterParams& p) {
    const double ci = p.core_intensity, hi = p.halo_intensity, bi = p.bloom_intensity;
    const double cs = p.core_size, hs = p.halo_size, bs = p.bloom_size;
    if (ci == 1.0 && hi == 1.0 && bi == 1.0 && cs == 1.0 && hs == 1.0 && bs == 1.0) return base;
    const double w_c = base.w_c * std::max(ci, 0.0);
    const double w_h = base.w_h * std::max(hi, 0.0);
    const double w_b = base.w_b * std::max(bi, 0.0);
    const double total = w_c + w_h + w_b;
    if (total <= 0.0) return base;
    FamilyShape out = base;
    out.core.lambda_um = base.core.lambda_um * std::max(cs, 1e-6);
    out.halo.lambda_um = base.halo.lambda_um * std::max(hs, 1e-6);
    out.bloom.lambda_um = base.bloom.lambda_um * std::max(bs, 1e-6);
    out.w_c = w_c / total;
    out.w_h = w_h / total;
    out.w_b = w_b / total;
    return out;
}

bool build_psf(const DiffusionFilterParams& p, Psf& out, std::string& error) {
    out = Psf{};
    const FamilyShape* base = family_shape(p.filter_family);
    if (!base) {
        error = "diffusion filter: unknown family '" + p.filter_family + "'";
        return false;
    }
    if (!p.active || p.strength <= 0 || p.spatial_scale <= 0) return true;
    out.p_s = strength_to_scatter(p.strength, p.filter_family);
    if (out.p_s <= 0) { out.p_s = 0.0; return true; }

    const FamilyShape cfg = resolve_family(*base, p);
    const double warmth = cfg.halo_warmth_base + p.halo_warmth;
    const double scale = std::max(p.spatial_scale, 1e-6);
    std::vector<double> cl, cw, hl, hw, bl, bw;
    expand_group(cfg.core, false, cl, cw);
    expand_group(cfg.halo, false, hl, hw);
    expand_group(cfg.bloom, true, bl, bw);
    std::vector<double> halo_ch[3];
    halo_channel_weights(hw, warmth, halo_ch);

    auto push = [&](double lambda_um, const double w[3], int group) {
        Exponential e;
        e.lambda_um = lambda_um * scale;
        for (int c = 0; c < 3; ++c) e.weight[c] = w[c];
        e.group = group;
        out.exps.push_back(e);
    };
    for (size_t k = 0; k < cl.size(); ++k) {
        const double w[3] = {cfg.w_c * cw[k], cfg.w_c * cw[k], cfg.w_c * cw[k]};
        push(cl[k], w, 0);
    }
    for (size_t k = 0; k < hl.size(); ++k) {
        const double w[3] = {cfg.w_h * halo_ch[0][k], cfg.w_h * halo_ch[1][k], cfg.w_h * halo_ch[2][k]};
        push(hl[k], w, 1);
    }
    for (size_t k = 0; k < bl.size(); ++k) {
        const double w[3] = {cfg.w_b * bw[k], cfg.w_b * bw[k], cfg.w_b * bw[k]};
        push(bl[k], w, 2);
    }
    return true;
}


// --- the fast application: line-spread functions and the pyramid fit --------

namespace {

constexpr double kPi = 3.14159265358979323846;

// u K1(u), Abramowitz & Stegun 9.8.3 (I1), 9.8.7 and 9.8.8: |error| < 1e-7.
double u_k1(double u) {
    if (u <= 0.0) return 1.0;
    if (u <= 2.0) {
        const double t = u / 3.75, t2 = t * t;
        const double i1 = u * (0.5 + t2 * (0.87890594 + t2 * (0.51498869 + t2 * (0.15084934 +
                          t2 * (0.02658733 + t2 * (0.00301532 + t2 * 0.00032411))))));
        const double y = (u / 2.0) * (u / 2.0);
        return u * std::log(u / 2.0) * i1 + 1.0 + y * (0.15443144 + y * (-0.67278579 + y * (-0.18156897 +
               y * (-0.01919402 + y * (-0.00110404 + y * (-0.00004686))))));
    }
    const double z = 2.0 / u;
    const double s = 1.25331414 + z * (0.23498619 + z * (-0.03655620 + z * (0.01504268 + z * (-0.00780353 +
                     z * (0.00325614 + z * (-0.00068245))))));
    return std::sqrt(u) * std::exp(-u) * s;
}

// Simpson over a pixel's cell, 16 intervals.
template <typename F>
double cell(double x, F f) {
    const int n = 16;
    const double a = x - 0.5, h = 1.0 / n;
    double s = f(a) + f(a + 1.0);
    for (int i = 1; i < n; ++i) s += (i % 2 ? 4.0 : 2.0) * f(a + i * h);
    return s * h / 3.0;
}

// The GPU's two 1-D filters, on a line (shaders/lens.metal `spk_lens_pyr_down`,
// `pyr_up`): down by the binomial [1 5 10 10 5 1] / 32 on samples 2i - 2 ..
// 2i + 3 (centred on 2i + 1/2), up by its transpose x 2 -- an even fine sample
// 2b takes (5, 10, 1) / 16 of coarse b - 1, b, b + 1, an odd one (1, 10, 5) / 16
// -- indices clamped at the line's ends. A sixth of the tent-and-bilinear
// pair's response's movement with a point's phase on the grid (2 % of a
// level's peak, not 11 %), which next to a lamp is the difference.
std::vector<double> down1(const std::vector<double>& v) {
    const int n = int(v.size()), m = (n + 1) / 2;
    std::vector<double> o(size_t(m), 0.0);
    const double c[6] = {1.0 / 32, 5.0 / 32, 10.0 / 32, 10.0 / 32, 5.0 / 32, 1.0 / 32};
    for (int i = 0; i < m; ++i)
        for (int t = 0; t < 6; ++t) o[size_t(i)] += c[t] * v[size_t(std::clamp(2 * i - 2 + t, 0, n - 1))];
    return o;
}
std::vector<double> up1(const std::vector<double>& c, int n) {
    std::vector<double> o(size_t(n), 0.0);
    const int m = int(c.size());
    const double ev[3] = {5.0 / 16, 10.0 / 16, 1.0 / 16}, od[3] = {1.0 / 16, 10.0 / 16, 5.0 / 16};
    for (int j = 0; j < n; ++j) {
        const int b = j / 2;
        const double* w = (j % 2) ? od : ev;
        for (int t = 0; t < 3; ++t) o[size_t(j)] += w[t] * c[size_t(std::clamp(b - 1 + t, 0, m - 1))];
    }
    return o;
}

}  // namespace

double exp_lsf_cell(double x, double lambda_px) {
    const double l = std::max(lambda_px, 1e-6);
    return cell(x, [l](double t) { return u_k1(std::fabs(t) / l) / (kPi * l); });
}

double gauss_lsf_cell(double x, double sigma_px) {
    const double s = std::max(sigma_px, 1e-6);
    return 0.5 * (std::erf((x + 0.5) / (s * std::sqrt(2.0))) - std::erf((x - 0.5) / (s * std::sqrt(2.0))));
}

const std::vector<double>& pyramid_basis(int k) {
    // Never destroyed: read by a render, which may still run while `exit()` tears the statics down (colour.cpp).
    static auto& cache = *new std::vector<std::vector<double>>(32);
    static bool made[32] = {};
    k = std::clamp(k, 1, 31);
    if (made[k]) return cache[size_t(k)];
    const int span = 1 << k;
    const int n = span * 24 + 64, centre = (n / 2) / span * span;
    const int phases = std::min(span, 32);
    const int half = span * 10;
    std::vector<double> acc(size_t(half + 1), 0.0);
    for (int ph = 0; ph < phases; ++ph) {
        const int q = centre + ph * span / phases;
        std::vector<double> v(size_t(n), 0.0);
        v[size_t(q)] = 1.0;
        std::vector<std::vector<double>> lv{v};
        for (int l = 1; l <= k; ++l) lv.push_back(down1(lv.back()));
        std::vector<double> u = lv.back();
        for (int l = k; l >= 1; --l) u = up1(u, int(lv[size_t(l - 1)].size()));
        for (int d = -half; d <= half; ++d) {
            const int j = q + d;
            if (j < 0 || j >= n) continue;
            acc[size_t(std::abs(d))] += (d == 0 ? 1.0 : 0.5) * u[size_t(j)];
        }
    }
    double mass = acc[0];
    for (size_t d = 1; d < acc.size(); ++d) mass += 2.0 * acc[d];
    for (double& a : acc) a /= mass;
    cache[size_t(k)] = acc;
    made[k] = true;
    return cache[size_t(k)];
}

namespace {

// min ||A x - b|| subject to x >= 0 (Lawson & Hanson), A row-major m x n.
std::vector<double> nnls(const std::vector<double>& A, const std::vector<double>& b, int m, int n) {
    std::vector<double> x(size_t(n), 0.0);
    std::vector<bool> P(size_t(n), false);
    auto grad = [&](std::vector<double>& w) {
        w.assign(size_t(n), 0.0);
        for (int i = 0; i < m; ++i) {
            double r = b[size_t(i)];
            for (int j = 0; j < n; ++j) r -= A[size_t(i * n + j)] * x[size_t(j)];
            for (int j = 0; j < n; ++j) w[size_t(j)] += A[size_t(i * n + j)] * r;
        }
    };
    // least squares on the passive set, by the normal equations (n <= 32)
    auto solve_p = [&](std::vector<double>& z) {
        std::vector<int> idx;
        for (int j = 0; j < n; ++j) if (P[size_t(j)]) idx.push_back(j);
        const int p = int(idx.size());
        std::vector<double> M(size_t(p * p), 0.0), r(size_t(p), 0.0);
        for (int i = 0; i < m; ++i)
            for (int a = 0; a < p; ++a) {
                const double va = A[size_t(i * n + idx[size_t(a)])];
                r[size_t(a)] += va * b[size_t(i)];
                for (int c = 0; c < p; ++c) M[size_t(a * p + c)] += va * A[size_t(i * n + idx[size_t(c)])];
            }
        for (int a = 0; a < p; ++a) M[size_t(a * p + a)] *= 1.0 + 1e-12;
        // Gaussian elimination with partial pivoting
        for (int c = 0; c < p; ++c) {
            int piv = c;
            for (int a = c + 1; a < p; ++a) if (std::fabs(M[size_t(a * p + c)]) > std::fabs(M[size_t(piv * p + c)])) piv = a;
            if (piv != c) { for (int t = 0; t < p; ++t) std::swap(M[size_t(c * p + t)], M[size_t(piv * p + t)]); std::swap(r[size_t(c)], r[size_t(piv)]); }
            const double d = M[size_t(c * p + c)];
            if (std::fabs(d) < 1e-300) continue;
            for (int a = c + 1; a < p; ++a) {
                const double f = M[size_t(a * p + c)] / d;
                for (int t = c; t < p; ++t) M[size_t(a * p + t)] -= f * M[size_t(c * p + t)];
                r[size_t(a)] -= f * r[size_t(c)];
            }
        }
        std::vector<double> s(size_t(p), 0.0);
        for (int a = p - 1; a >= 0; --a) {
            double v = r[size_t(a)];
            for (int t = a + 1; t < p; ++t) v -= M[size_t(a * p + t)] * s[size_t(t)];
            const double d = M[size_t(a * p + a)];
            s[size_t(a)] = std::fabs(d) > 1e-300 ? v / d : 0.0;
        }
        z.assign(size_t(n), 0.0);
        for (int a = 0; a < p; ++a) z[size_t(idx[size_t(a)])] = s[size_t(a)];
    };
    std::vector<double> w, z;
    double scale = 0.0;
    for (double v : b) scale = std::max(scale, std::fabs(v));
    const double tol = 1e-12 * std::max(scale, 1e-300);
    for (int outer = 0; outer < 3 * n; ++outer) {
        grad(w);
        int j = -1;
        double best = tol;
        for (int t = 0; t < n; ++t) if (!P[size_t(t)] && w[size_t(t)] > best) { best = w[size_t(t)]; j = t; }
        if (j < 0) break;
        P[size_t(j)] = true;
        for (int inner = 0; inner < 3 * n; ++inner) {
            solve_p(z);
            bool ok = true;
            for (int t = 0; t < n; ++t) if (P[size_t(t)] && z[size_t(t)] <= 0.0) ok = false;
            if (ok) { x = z; break; }
            double alpha = 1.0;
            for (int t = 0; t < n; ++t)
                if (P[size_t(t)] && z[size_t(t)] <= 0.0) {
                    const double den = x[size_t(t)] - z[size_t(t)];
                    if (den > 0.0) alpha = std::min(alpha, x[size_t(t)] / den);
                }
            for (int t = 0; t < n; ++t) x[size_t(t)] += alpha * (z[size_t(t)] - x[size_t(t)]);
            for (int t = 0; t < n; ++t) if (P[size_t(t)] && x[size_t(t)] <= 1e-15) { P[size_t(t)] = false; x[size_t(t)] = 0.0; }
        }
    }
    return x;
}

}  // namespace

void fit_pyramid(const std::vector<double> target[3], int max_levels, PyramidFit& out, int min_level,
                 int inner, const MassHold* hold) {
    out = PyramidFit{};
    const int X = int(target[0].size()) - 1;
    if (X < 0) return;
    // The basis: the identity (without a core), then each level that a target
    // this wide can use.
    int K = 0;
    while (K < max_levels && (1 << (K + 1)) <= std::max(2 * X, 2)) ++K;
    std::vector<int> cols;
    if (inner == 0) cols.push_back(0);
    for (int k = std::max(1, min_level); k <= K; ++k) cols.push_back(k);
    const int n = int(cols.size());
    out.a.assign(size_t(K + 1), {0.0, 0.0, 0.0});
    if (n == 0) { out.a.resize(1); return; }
    // Rows: every pixel to 64, then every x / 16 -- each weighted by the cells
    // it stands for and by (1 + x / 8), so the long tail (where a mist filter
    // keeps half its light) counts for what it carries, not for its height.
    std::vector<int> xs;
    std::vector<double> span;
    for (int x = inner; x <= X;) {
        const int s = x < 64 ? 1 : std::max(1, x / 16);
        xs.push_back(x);
        span.push_back(x == 0 ? 1.0 : 2.0 * double(std::min(s, X - x + 1)));
        x += s;
    }
    const bool hold_mass = inner == 0 || hold != nullptr;
    const int m = int(xs.size()) + (hold_mass ? 1 : 0);
    if (m == 0) { out.a.resize(1); return; }
    auto basis = [&](int k, int x) {
        if (k == 0) return x == 0 ? 1.0 : 0.0;
        const std::vector<double>& B = pyramid_basis(k);
        return size_t(x) < B.size() ? B[size_t(x)] : 0.0;
    };
    for (int ch = 0; ch < 3; ++ch) {
        double mass = target[ch][0];
        for (int x = 1; x <= X; ++x) mass += 2.0 * target[ch][size_t(x)];
        std::vector<double> A(size_t(m * n), 0.0), b(size_t(m), 0.0);
        double peak = 0.0;
        for (double v : target[ch]) peak = std::max(peak, v);
        for (int r = 0; r < int(xs.size()); ++r) {
            const int x = xs[size_t(r)];
            const double w = std::sqrt(span[size_t(r)] * (1.0 + x / 8.0));
            for (int j = 0; j < n; ++j) A[size_t(r * n + j)] = w * basis(cols[size_t(j)], x);
            b[size_t(r)] = w * target[ch][size_t(x)];
        }
        if (hold_mass) {   // every basis has unit mass
            const double wm = 1e3 * std::sqrt(double(m));
            for (int j = 0; j < n; ++j) {
                const int k = cols[size_t(j)];
                const double in = hold && size_t(k) < hold->inside.size() ? hold->inside[size_t(k)] : 0.0;
                A[size_t((m - 1) * n + j)] = wm * (hold ? 1.0 - in : 1.0);
            }
            b[size_t(m - 1)] = wm * (hold ? hold->value[ch] : mass);
        }
        const std::vector<double> sol = nnls(A, b, m, n);
        for (int j = 0; j < n; ++j) out.a[size_t(cols[size_t(j)])][size_t(ch)] = sol[size_t(j)];
        double se = 0.0, cnt = 0.0;
        for (int x = inner; x <= X; ++x) {
            double v = 0.0;
            for (int j = 0; j < n; ++j) v += sol[size_t(j)] * basis(cols[size_t(j)], x);
            se += (v - target[ch][size_t(x)]) * (v - target[ch][size_t(x)]);
            cnt += 1.0;
        }
        out.lsf_rms[ch] = peak > 0.0 && cnt > 0.0 ? std::sqrt(se / cnt) / peak : 0.0;
    }
    out.levels = 0;
    for (int k = 1; k <= K; ++k)
        for (int ch = 0; ch < 3; ++ch) if (out.a[size_t(k)][size_t(ch)] > 0.0) out.levels = k;
    out.a.resize(size_t(out.levels + 1));
}

double pyramid_response_2d(const PyramidFit& fit, int c, int dx, int dy) {
    double v = (dx == 0 && dy == 0 && !fit.a.empty()) ? fit.a[0][size_t(c)] : 0.0;
    for (int k = 1; k <= fit.levels; ++k) {
        const double a = fit.a[size_t(k)][size_t(c)];
        if (a == 0.0) continue;
        const std::vector<double>& B = pyramid_basis(k);
        const size_t x = size_t(std::abs(dx)), y = size_t(std::abs(dy));
        if (x < B.size() && y < B.size()) v += a * B[x] * B[y];
    }
    return v;
}

double exp_cell_2d(int dx, int dy, double lambda_px) {
    const double l = std::max(lambda_px, 1e-6);
    const bool centre = dx == 0 && dy == 0;
    if (l < 24.0 / 512.0) return centre ? 1.0 : 0.0;   // all of it in its own cell, to < 1e-9
    const int n = std::clamp(int(std::ceil((centre ? 24.0 : 8.0) / l)), 8, centre ? 512 : 128);
    const double h = 1.0 / n;
    double s = 0.0;
    for (int i = 0; i < n; ++i) {
        const double y = dy - 0.5 + (i + 0.5) * h;
        for (int j = 0; j < n; ++j) {
            const double x = dx - 0.5 + (j + 0.5) * h;
            s += std::exp(-std::sqrt(x * x + y * y) / l);
        }
    }
    return s * h * h / (2.0 * kPi * l * l);
}

}  // namespace spk::diffusion
