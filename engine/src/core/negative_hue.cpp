#include "negative_hue.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

#include "digital_intermediate.hpp"   // film_host_develop

namespace spk {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kLog2Of10 = 3.321928094887362;

// Björn Ottosson's Oklab (2020), XYZ (D65) <-> LMS <-> Lab. The same constants
// as `spk_negative_hue`; the kernel and this file must not drift apart.
const double kOkM1[9] = {0.8189330101, 0.3618667424, -0.1288597137,
                         0.0329845436, 0.9293118715, 0.0361456387,
                         0.0482003018, 0.2643662691, 0.6338517070};
const double kOkM2[9] = {0.2104542553, 0.7936177850, -0.0040720468,
                         1.9779984951, -2.4285922050, 0.4505937099,
                         0.0259040371, 0.7827717662, -0.8086757660};
const double kOkM1Inv[9] = {1.2270138511, -0.5577999807, 0.2812561490,
                            -0.0405801784, 1.1122568696, -0.0716766787,
                            -0.0763812845, -0.4214819784, 1.5861632204};
const double kOkM2Inv[9] = {1.0, 0.3963377774, 0.2158037573,
                            1.0, -0.1055613458, -0.0638541728,
                            1.0, -0.0894841775, -1.2914855480};

void mul3(const double* m, const double* v, double* out) {
    for (int i = 0; i < 3; ++i) out[i] = m[3 * i] * v[0] + m[3 * i + 1] * v[1] + m[3 * i + 2] * v[2];
}

void oklab_from_xyz(const double xyz[3], double lab[3]) {
    double lms[3];
    mul3(kOkM1, xyz, lms);
    for (double& v : lms) v = std::cbrt(std::fmax(v, 0.0));
    mul3(kOkM2, lms, lab);
}

void xyz_from_oklab(const double lab[3], double xyz[3]) {
    double l[3];
    mul3(kOkM2Inv, lab, l);
    for (double& v : l) v = v * v * v;
    mul3(kOkM1Inv, l, xyz);
}

double wrap180(double d) {
    d = std::fmod(d + 180.0, 360.0);
    if (d < 0.0) d += 360.0;
    return d - 180.0;
}

// The scanner's integral on one paper pixel, in double, with the baked constants.
void scan_xyz(const SpectralConstants& k, const double cmy[3], double xyz[3]) {
    xyz[0] = xyz[1] = xyz[2] = 0.0;
    for (size_t l = 0; l < kNumWavelengths; ++l) {
        double d = k.base_density[l];
        for (int c = 0; c < 3; ++c) d += cmy[c] * k.channel_density[3 * l + size_t(c)];
        const double t = std::exp2(-d * kLog2Of10);
        for (int c = 0; c < 3; ++c) xyz[c] += t * k.illum_x_sens[3 * l + size_t(c)];
    }
}

void read_knots(const NegativeHue& k, int c, double density, double& le, double& u);

// --- the per-layer inverse of the characteristic curve ----------------------
// A measured toe wobbles and a shoulder flattens; the inverse needs a strictly
// increasing axis. The running maximum is the curve with its wobble removed, and a
// flat run is nudged by 1e-7 a sample -- there the slope table says the reading is
// worthless, which is the truth about a layer that has stopped responding.
void build_inverse(const Profile& film, double gamma, NegativeHue& out) {
    const size_t k = film.data.n_exposure;
    out.inverse.k = k;
    out.inverse.x.assign(k * 3, 0.0);
    out.inverse.y.assign(k * 3, 0.0);
    out.inverse.inv.assign((k - 1) * 3, 0.0);
    out.unreliability.assign(k * 3, 0.0);
    const size_t w = std::max<size_t>(2, k / 64);
    for (int c = 0; c < 3; ++c) {
        std::vector<double> d(k), x(k), slope(k);
        for (size_t i = 0; i < k; ++i) {
            x[i] = film.data.log_exposure[i] / gamma;
            double v = film.normalized_curves[3 * i + size_t(c)];
            if (is_nan(v)) v = i ? d[i - 1] : 0.0;
            d[i] = i ? std::fmax(v, d[i - 1] + 1e-7) : v;
        }
        double peak = 0.0;
        for (size_t i = 0; i < k; ++i) {
            const size_t a = i >= w ? i - w : 0, b = std::min(k - 1, i + w);
            slope[i] = (d[b] - d[a]) / std::fmax(x[b] - x[a], 1e-12);
            peak = std::fmax(peak, slope[i]);
        }
        // The straight part's own slope: the median of everything at least half as steep as the steepest.
        std::vector<double> straight;
        for (double s : slope) if (s >= 0.5 * peak) straight.push_back(s);
        std::sort(straight.begin(), straight.end());
        const double ref = straight.empty() ? 1.0 : straight[straight.size() / 2];
        out.gamma_ref[c] = ref;
        for (size_t i = 0; i < k; ++i) {
            out.inverse.x[3 * i + size_t(c)] = d[i];
            out.inverse.y[3 * i + size_t(c)] = x[i];
            out.unreliability[3 * i + size_t(c)] =
                std::clamp(ref / std::fmax(slope[i], ref / 101.0) - 1.0, 0.0, 100.0);
        }
        for (size_t i = 0; i + 1 < k; ++i) out.inverse.inv[3 * i + size_t(c)] = 1.0 / (d[i + 1] - d[i]);
    }
    // The even table. Finer than the curve's own knots over its straight part (a
    // film's range in 1023 steps is ~0.003 D); coarser only where the curve is
    // flat, which is where the unreliability column already says not to listen.
    const uint32_t N = kNegativeHueLayerSamples;
    out.layers.assign(size_t(N) * 3 * 2, 0.0);
    for (int c = 0; c < 3; ++c) {
        const double d0 = out.inverse.x[size_t(c)], d1 = out.inverse.x[3 * (k - 1) + size_t(c)];
        out.layer_lo[c] = d0;
        out.layer_scale[c] = double(N - 1) / std::fmax(d1 - d0, 1e-9);
        for (uint32_t j = 0; j < N; ++j) {
            const double density = d0 + (d1 - d0) * double(j) / double(N - 1);
            double le, u;
            read_knots(out, c, density, le, u);
            out.layers[(size_t(j) * 3 + size_t(c)) * 2] = le;
            out.layers[(size_t(j) * 3 + size_t(c)) * 2 + 1] = u;
        }
    }
}

// One layer: density -> (log10 exposure, unreliability), by index: `spk_read_layer`'s arithmetic,
// here for the map's build, which must read the film exactly as the pixels will.
void read_layer(const NegativeHue& k, int c, double density, double& le, double& u) {
    const uint32_t N = kNegativeHueLayerSamples;
    const double f = std::clamp((density - k.layer_lo[c]) * k.layer_scale[c], 0.0, double(N - 1));
    const uint32_t j = std::min(uint32_t(f), N - 2);
    const double t = f - double(j);
    const double* a = &k.layers[(size_t(j) * 3 + size_t(c)) * 2];
    const double* b = a + 6;
    le = a[0] + t * (b[0] - a[0]);
    u = a[1] + t * (b[1] - a[1]);
}

// One layer on the curve's own knots: density -> (log10 exposure, unreliability).
void read_knots(const NegativeHue& k, int c, double density, double& le, double& u) {
    const size_t n = k.inverse.k;
    const auto X = [&](size_t i) { return k.inverse.x[3 * i + size_t(c)]; };
    const auto Y = [&](size_t i) { return k.inverse.y[3 * i + size_t(c)]; };
    const auto U = [&](size_t i) { return k.unreliability[3 * i + size_t(c)]; };
    if (!(density > X(0))) { le = Y(0); u = U(0); return; }
    if (density >= X(n - 1)) { le = Y(n - 1); u = U(n - 1); return; }
    size_t lo = 0, hi = n;
    while (lo < hi) {
        const size_t mid = lo + ((hi - lo) >> 1);
        if (X(mid) <= density) lo = mid + 1; else hi = mid;
    }
    const size_t low = lo - 1;
    const double t = (density - X(low)) * k.inverse.inv[3 * low + size_t(c)];
    le = Y(low) + t * (Y(low + 1) - Y(low));
    u = U(low) + t * (U(low + 1) - U(low));
}

// The table at one exposure chromaticity, bilinear.
void map_at(const NegativeHue& k, double er, double eg, double& a, double& b) {
    const uint32_t S = kNegativeHueMapSide;
    const double fx = std::clamp(er, 0.0, 1.0) * double(S - 1), fy = std::clamp(eg, 0.0, 1.0) * double(S - 1);
    const uint32_t x0 = std::min(uint32_t(fx), S - 2), y0 = std::min(uint32_t(fy), S - 2);
    const double tx = fx - double(x0), ty = fy - double(y0);
    const auto at = [&](uint32_t x, uint32_t y, int c) { return k.map[(size_t(x) * S + y) * 2 + size_t(c)]; };
    const auto lerp2 = [&](int c) {
        const double p = at(x0, y0, c) + (at(x0, y0 + 1, c) - at(x0, y0, c)) * ty;
        const double q = at(x0 + 1, y0, c) + (at(x0 + 1, y0 + 1, c) - at(x0 + 1, y0, c)) * ty;
        return p + (q - p) * tx;
    };
    a = lerp2(0);
    b = lerp2(1);
}

// --- the film's exposure map, inverted -----------------------------------------
// Which colour puts the three layers in this ratio? The forward answer is the
// engine's own chain: the upsampler, the curves and the DIR couplers at the
// session's amount (`film_host_develop`), read back layer by layer. In the straight
// part of the curves that ratio does not depend on how bright the colour is (the
// couplers add a fixed linear map of the log-exposure differences), so one sheet at
// mid-grey's lightness is the whole answer; the toe and the shoulder are the film's
// own behaviour and stay in the reading.
//
// The sheet is a polar grid in Oklab around grey. Each cell of it is two triangles
// in the layers' exposure chromaticity, rasterised into the table with the colour's
// (a, b). Where the film folds two colours onto one ratio the less saturated one is
// kept; a ratio no colour produces takes its nearest neighbour's.
//
// No 3x3 can do this: film sensitivities are not a linear map of the eye's, and the
// best matrix leaves +-10 degrees by sector on every stock (measured 2026-11-11, a
// 864-patch chart through the engine: Portra 400, Gold 200, Pro 400H, Vision3 250D).
bool build_map(const Colour& colour, const Blob& blob, const Params& params, const Vec& tc_lut,
               size_t side, const Mat3& tc_b, NegativeHue& out, std::string& error) {
    Vec d65;
    if (!standard_illuminant(colour, blob, "D65", d65, error)) return false;
    double d65_xy[2];
    illuminant_to_xy(colour, d65, d65_xy);
    Mat3 in_to_xyz;
    if (!colour.matrix_RGB_to_XYZ(params.io.input_color_space, d65_xy, "CAT02", in_to_xyz, error)) return false;
    const Mat3 xyz_to_in = in_to_xyz.inverse();

    const int NH = 180, NC = 56;          // 2 degrees, chroma to 0.42 in 0.0075 steps
    const double dc = 0.0075;
    const size_t n = size_t(NH) * NC + 1; // index 0 is grey
    std::vector<double> rgb(n * 3), ab(n * 2, 0.0), cmy(n * 3);
    std::vector<char> valid(n, 0);
    const auto idx = [&](int ih, int ic) { return ic == 0 ? size_t(0) : size_t(1) + size_t(ic - 1) * NH + size_t((ih % NH + NH) % NH); };
    for (int ic = 0; ic <= NC; ++ic)
        for (int ih = 0; ih < (ic == 0 ? 1 : NH); ++ih) {
            const size_t i = idx(ih, ic);
            const double h = double(ih) * 2.0 * kPi / NH, C = dc * ic;
            const double lab[3] = {kNegativeHueLightness, C * std::cos(h), C * std::sin(h)};
            double xyz[3];
            xyz_from_oklab(lab, xyz);
            const double sum = xyz[0] + xyz[1] + xyz[2];
            valid[i] = xyz[0] > 0.0 && xyz[1] > 1e-6 && xyz[2] > 0.0 && sum > 0.0;
            xyz_to_in.apply(xyz, &rgb[3 * i]);
            if (!valid[i]) { const double g = 0.184; rgb[3 * i] = rgb[3 * i + 1] = rgb[3 * i + 2] = g; }
            ab[2 * i] = lab[1];
            ab[2 * i + 1] = lab[2];
        }
    film_host_develop(params, tc_lut, side, tc_b, rgb.data(), n, cmy.data());
    std::vector<double> ec(n * 2);        // exposure chromaticity (red share, green share)
    for (size_t i = 0; i < n; ++i) {
        double e[3];
        for (int c = 0; c < 3; ++c) {
            double le, u;
            read_layer(out, c, cmy[3 * i + size_t(c)], le, u);
            e[c] = std::pow(10.0, le);
        }
        if (i == 0) for (int c = 0; c < 3; ++c) out.neutral[c] = e[c];
        double sum = 0.0;
        for (int c = 0; c < 3; ++c) { e[c] /= out.neutral[c]; sum += e[c]; }
        if (!(sum > 0.0) || !std::isfinite(sum)) { valid[i] = 0; continue; }
        ec[2 * i] = e[0] / sum;
        ec[2 * i + 1] = e[1] / sum;
    }
    if (!valid[0]) { error = "negative hue: the film does not record a grey"; return false; }

    const uint32_t S = kNegativeHueMapSide;
    out.map.assign(size_t(S) * S * 2, 0.0);
    std::vector<double> best(size_t(S) * S, -1.0);   // the chroma kept so far; < 0 is empty
    const auto raster = [&](size_t ia, size_t ib, size_t ic_) {
        if (!valid[ia] || !valid[ib] || !valid[ic_]) return;
        const double ax = ec[2 * ia] * (S - 1), ay = ec[2 * ia + 1] * (S - 1);
        const double bx = ec[2 * ib] * (S - 1), by = ec[2 * ib + 1] * (S - 1);
        const double cx = ec[2 * ic_] * (S - 1), cy = ec[2 * ic_ + 1] * (S - 1);
        const double det = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
        if (std::fabs(det) < 1e-14) return;
        const int x0 = std::max(0, int(std::ceil(std::min({ax, bx, cx}) - 1e-9)));
        const int x1 = std::min(int(S) - 1, int(std::floor(std::max({ax, bx, cx}) + 1e-9)));
        const int y0 = std::max(0, int(std::ceil(std::min({ay, by, cy}) - 1e-9)));
        const int y1 = std::min(int(S) - 1, int(std::floor(std::max({ay, by, cy}) + 1e-9)));
        for (int x = x0; x <= x1; ++x)
            for (int y = y0; y <= y1; ++y) {
                const double u = ((x - ax) * (cy - ay) - (cx - ax) * (y - ay)) / det;
                const double v = ((bx - ax) * (y - ay) - (x - ax) * (by - ay)) / det;
                if (u < -1e-7 || v < -1e-7 || u + v > 1.0 + 1e-7) continue;
                const double a = ab[2 * ia] + u * (ab[2 * ib] - ab[2 * ia]) + v * (ab[2 * ic_] - ab[2 * ia]);
                const double b = ab[2 * ia + 1] + u * (ab[2 * ib + 1] - ab[2 * ia + 1]) + v * (ab[2 * ic_ + 1] - ab[2 * ia + 1]);
                const double chroma = std::hypot(a, b);
                const size_t cell = size_t(x) * S + size_t(y);
                if (best[cell] >= 0.0 && best[cell] <= chroma) continue;
                best[cell] = chroma;
                out.map[2 * cell] = a;
                out.map[2 * cell + 1] = b;
            }
    };
    for (int ic = 0; ic < NC; ++ic)
        for (int ih = 0; ih < NH; ++ih) {
            const size_t p00 = idx(ih, ic), p01 = idx(ih + 1, ic), p10 = idx(ih, ic + 1), p11 = idx(ih + 1, ic + 1);
            if (ic == 0) { raster(p00, p10, p11); continue; }   // the fan round grey
            raster(p00, p10, p11);
            raster(p00, p11, p01);
        }
    // A ratio no colour on the sheet produces: the nearest one that some colour does.
    {
        std::vector<int> frontier, next;
        size_t covered = 0;
        for (size_t c = 0; c < best.size(); ++c) if (best[c] >= 0.0) { frontier.push_back(int(c)); ++covered; }
        out.map_filled = best.size() - covered;
        if (covered == 0) { error = "negative hue: the film's exposure map is empty"; return false; }
        while (!frontier.empty()) {
            next.clear();
            for (int c : frontier) {
                const int x = c / int(S), y = c % int(S);
                const int nb[4][2] = {{x - 1, y}, {x + 1, y}, {x, y - 1}, {x, y + 1}};
                for (const auto& q : nb) {
                    if (q[0] < 0 || q[1] < 0 || q[0] >= int(S) || q[1] >= int(S)) continue;
                    const size_t m = size_t(q[0]) * S + size_t(q[1]);
                    if (best[m] >= 0.0) continue;
                    best[m] = best[size_t(c)];
                    out.map[2 * m] = out.map[2 * size_t(c)];
                    out.map[2 * m + 1] = out.map[2 * size_t(c) + 1];
                    next.push_back(int(m));
                }
            }
            frontier.swap(next);
        }
    }
    // The table read back at the colours it was built from.
    double se = 0.0, worst = 0.0;
    size_t used = 0;
    for (size_t i = 1; i < n; ++i) {
        if (!valid[i]) continue;
        const double c_true = std::hypot(ab[2 * i], ab[2 * i + 1]);
        if (c_true < 0.04 || c_true > 0.25) continue;
        double a, b;
        map_at(out, ec[2 * i], ec[2 * i + 1], a, b);
        const double dh = wrap180((std::atan2(b, a) - std::atan2(ab[2 * i + 1], ab[2 * i])) * 180.0 / kPi);
        se += dh * dh;
        worst = std::fmax(worst, std::fabs(dh));
        ++used;
    }
    out.map_samples = n;
    out.map_hue_rms_deg = used ? std::sqrt(se / double(used)) : 0.0;
    out.map_hue_max_deg = worst;
    return true;
}

// --- the paper's gamut --------------------------------------------------------
// Every colour the paper can make is some (c, m, y) inside its curves' range; the
// boundary is the image of that box's six faces. Each face is sampled, scanned
// and rasterised onto a (lightness, hue) grid keeping the largest chroma. From
// the paper's dyes, its base and its Dmin/Dmax: nothing about any film.
void build_gamut(const SpectralConstants& scan, const double lo[3], const double hi[3], NegativeHue& out) {
    const uint32_t nh = kNegativeHueGamutHues, nl = kNegativeHueGamutLevels;
    const Mat3 to65 = Mat3::from_row_major(out.scan_to_d65);
    const auto lab_of = [&](const double cmy[3], double lab[3]) {
        double xyz[3], x65[3];
        scan_xyz(scan, cmy, xyz);
        to65.apply(xyz, x65);
        oklab_from_xyz(x65, lab);
    };
    double lab_white[3], lab_black[3];
    lab_of(lo, lab_white);
    lab_of(hi, lab_black);
    out.gamut_l_lo = lab_black[0];
    out.gamut_l_hi = lab_white[0];
    const double l_span = std::fmax(out.gamut_l_hi - out.gamut_l_lo, 1e-6);
    out.gamut.assign(size_t(nl) * nh, -1.0);

    const int S = 40;   // samples per face edge
    std::vector<double> face(size_t(S + 1) * (S + 1) * 3);   // (L, C, h in degrees)
    for (int axis = 0; axis < 3; ++axis)
        for (int end = 0; end < 2; ++end) {
            const int a1 = (axis + 1) % 3, a2 = (axis + 2) % 3;
            for (int i = 0; i <= S; ++i)
                for (int j = 0; j <= S; ++j) {
                    double cmy[3], lab[3];
                    cmy[axis] = end ? hi[axis] : lo[axis];
                    cmy[a1] = lo[a1] + (hi[a1] - lo[a1]) * double(i) / S;
                    cmy[a2] = lo[a2] + (hi[a2] - lo[a2]) * double(j) / S;
                    lab_of(cmy, lab);
                    double* p = &face[(size_t(i) * (S + 1) + size_t(j)) * 3];
                    p[0] = lab[0];
                    p[1] = std::hypot(lab[1], lab[2]);
                    p[2] = std::atan2(lab[2], lab[1]) * 180.0 / kPi;
                }
            const auto raster = [&](const double* A, const double* B, const double* C) {
                if (A[1] < 1e-4 || B[1] < 1e-4 || C[1] < 1e-4) return;   // hue undefined at the neutral corners
                const double h0 = A[2], h1 = h0 + wrap180(B[2] - h0), h2 = h0 + wrap180(C[2] - h0);
                const double hmin = std::min({h0, h1, h2}), hmax = std::max({h0, h1, h2});
                if (hmax - hmin > 90.0) return;
                const double step_h = 360.0 / nh;
                const double lmin = std::min({A[0], B[0], C[0]}), lmax = std::max({A[0], B[0], C[0]});
                const int ih0 = int(std::ceil(hmin / step_h - 1e-9)), ih1 = int(std::floor(hmax / step_h + 1e-9));
                const int il0 = std::max(0, int(std::ceil((lmin - out.gamut_l_lo) / l_span * (nl - 1) - 1e-9)));
                const int il1 = std::min(int(nl) - 1, int(std::floor((lmax - out.gamut_l_lo) / l_span * (nl - 1) + 1e-9)));
                const double det = (h1 - h0) * (C[0] - A[0]) - (h2 - h0) * (B[0] - A[0]);
                if (std::fabs(det) < 1e-12) return;
                for (int ih = ih0; ih <= ih1; ++ih)
                    for (int il = il0; il <= il1; ++il) {
                        const double h = ih * step_h, L = out.gamut_l_lo + l_span * double(il) / (nl - 1);
                        const double u = ((h - h0) * (C[0] - A[0]) - (h2 - h0) * (L - A[0])) / det;
                        const double v = ((h1 - h0) * (L - A[0]) - (h - h0) * (B[0] - A[0])) / det;
                        if (u < -1e-6 || v < -1e-6 || u + v > 1.0 + 1e-6) continue;
                        const double chroma = A[1] + u * (B[1] - A[1]) + v * (C[1] - A[1]);
                        const int col = ((ih % int(nh)) + int(nh)) % int(nh);
                        double& cell = out.gamut[size_t(il) * nh + size_t(col)];
                        cell = std::fmax(cell, chroma);
                    }
            };
            for (int i = 0; i < S; ++i)
                for (int j = 0; j < S; ++j) {
                    const double* p00 = &face[(size_t(i) * (S + 1) + size_t(j)) * 3];
                    const double* p01 = p00 + 3;
                    const double* p10 = p00 + size_t(S + 1) * 3;
                    const double* p11 = p10 + 3;
                    raster(p00, p10, p01);
                    raster(p11, p01, p10);
                }
        }
    // The ends: chroma is zero at the paper's black and at its white, and a cell
    // no triangle reached lies on the line to its covered neighbour.
    for (uint32_t ih = 0; ih < nh; ++ih) {
        std::vector<double> col(nl);
        for (uint32_t il = 0; il < nl; ++il) col[il] = out.gamut[size_t(il) * nh + ih];
        col[0] = 0.0;
        col[nl - 1] = 0.0;
        uint32_t prev = 0;
        for (uint32_t il = 1; il < nl; ++il) {
            if (col[il] < 0.0) continue;
            for (uint32_t m = prev + 1; m < il; ++m)
                col[m] = col[prev] + (col[il] - col[prev]) * double(m - prev) / double(il - prev);
            prev = il;
        }
        for (uint32_t il = 0; il < nl; ++il) out.gamut[size_t(il) * nh + ih] = col[il];
    }
}

// --- the two halves, remembered -------------------------------------------------
// The pipeline is rebuilt on every edit that is not live-mutable, and this setup is
// 12-19 ms of host arithmetic (measured 2026-11-11): a slider step would pay it each
// time for an answer that did not change. The film's half (the inverse curves and the
// exposure map) depends on the film's chain; the paper's half (the gamut) on the
// paper's dyes and range. Each is kept under a hash of exactly the numbers it was
// computed from, so a stock with the same name and different data is a different key.
struct Fnv {
    uint64_t h = 1469598103934665603ull;
    void bytes(const void* p, size_t n) {
        const unsigned char* b = static_cast<const unsigned char*>(p);
        size_t i = 0;
        for (; i + 8 <= n; i += 8) { uint64_t w; std::memcpy(&w, b + i, 8); h = (h ^ w) * 1099511628211ull; h ^= h >> 29; }
        for (; i < n; ++i) h = (h ^ b[i]) * 1099511628211ull;
    }
    void vec(const Vec& v) { const uint64_t n = v.size(); bytes(&n, 8); if (n) bytes(v.data(), size_t(n) * sizeof(double)); }
    void num(double v) { bytes(&v, 8); }
    void str(const std::string& v) { const uint64_t n = v.size(); bytes(&n, 8); bytes(v.data(), v.size()); }
};

struct FilmHalf {
    uint64_t key = 0;
    InterpTables inverse;
    Vec unreliability, map, layers;
    double gamma_ref[3], neutral[3], layer_lo[3], layer_scale[3];
    size_t map_samples = 0, map_filled = 0;
    double map_hue_rms_deg = 0.0, map_hue_max_deg = 0.0;
};
struct PaperHalf {
    uint64_t key = 0;
    double scan_to_d65[9], d65_to_scan[9];
    Vec gamut;
    double gamut_l_lo = 0.0, gamut_l_hi = 1.0;
};
constexpr size_t kRemembered = 4;   // a few stocks in rotation; ~0.5 MB each
// Never destroyed: a render may still be in here while a quit's `exit()` tears the statics down (a destroyed mutex
// throws "mutex lock failed"; colour.cpp, app/SpektraLab/tools/exit_render_check.swift).
std::mutex& g_memo_lock = *new std::mutex;
std::vector<FilmHalf>& g_films = *new std::vector<FilmHalf>;      // most recently used first
std::vector<PaperHalf>& g_papers = *new std::vector<PaperHalf>;

}  // namespace

bool negative_hue_constants(const Colour& colour, const Blob& blob, const Params& params,
                            const Vec& tc_lut, size_t tc_lut_side, const Mat3& tc_b,
                            const SpectralConstants& scan, const double scan_illuminant_xy[2],
                            const Vec& paper_curves, NegativeHue& out, std::string& error) {
    out = NegativeHue{};
    const Profile& film = params.film;
    if (film.data.n_exposure < 8 || film.normalized_curves.size() < film.data.n_exposure * 3) {
        error = "negative hue: film '" + film.info.stock + "' has no usable density curves";
        return false;
    }

    // --- the film's half ---------------------------------------------------
    Fnv fk;
    fk.num(2.0);   // this file's arithmetic; bump when it changes
    fk.vec(film.data.log_exposure);
    fk.vec(film.normalized_curves);
    fk.num(params.film_render.density_curve_gamma);
    {
        double dir[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
        if (params.film_render.dir_couplers.active) dir_couplers_matrix(params.film_render.dir_couplers, dir);
        fk.bytes(dir, sizeof dir);
        fk.num(params.film_render.dir_couplers.active ? 1.0 : 0.0);
        fk.num(film.info.is_positive() ? 1.0 : 0.0);
    }
    fk.vec(tc_lut);
    fk.num(double(tc_lut_side));
    fk.bytes(tc_b.m, sizeof tc_b.m);
    fk.str(params.io.input_color_space);
    bool have_film = false;
    {
        std::lock_guard<std::mutex> guard(g_memo_lock);
        for (size_t i = 0; i < g_films.size(); ++i) {
            if (g_films[i].key != fk.h) continue;
            if (i != 0) std::rotate(g_films.begin(), g_films.begin() + long(i), g_films.begin() + long(i) + 1);
            const FilmHalf& f = g_films.front();
            out.inverse = f.inverse; out.unreliability = f.unreliability; out.map = f.map; out.layers = f.layers;
            for (int c = 0; c < 3; ++c) {
                out.gamma_ref[c] = f.gamma_ref[c]; out.neutral[c] = f.neutral[c];
                out.layer_lo[c] = f.layer_lo[c]; out.layer_scale[c] = f.layer_scale[c];
            }
            out.map_samples = f.map_samples; out.map_filled = f.map_filled;
            out.map_hue_rms_deg = f.map_hue_rms_deg; out.map_hue_max_deg = f.map_hue_max_deg;
            have_film = true;
            break;
        }
    }
    if (!have_film) {
        build_inverse(film, params.film_render.density_curve_gamma, out);
        if (!build_map(colour, blob, params, tc_lut, tc_lut_side, tc_b, out, error)) return false;
        FilmHalf f;
        f.key = fk.h;
        f.inverse = out.inverse; f.unreliability = out.unreliability; f.map = out.map; f.layers = out.layers;
        for (int c = 0; c < 3; ++c) {
            f.gamma_ref[c] = out.gamma_ref[c]; f.neutral[c] = out.neutral[c];
            f.layer_lo[c] = out.layer_lo[c]; f.layer_scale[c] = out.layer_scale[c];
        }
        f.map_samples = out.map_samples; f.map_filled = out.map_filled;
        f.map_hue_rms_deg = out.map_hue_rms_deg; f.map_hue_max_deg = out.map_hue_max_deg;
        std::lock_guard<std::mutex> guard(g_memo_lock);
        g_films.insert(g_films.begin(), std::move(f));
        if (g_films.size() > kRemembered) g_films.pop_back();
    }

    // --- the paper's half --------------------------------------------------
    const size_t k = paper_curves.size() / 3;
    double lo[3] = {1e30, 1e30, 1e30}, hi[3] = {-1e30, -1e30, -1e30};
    for (size_t i = 0; i < k; ++i)
        for (int c = 0; c < 3; ++c) {
            const double v = paper_curves[3 * i + size_t(c)];
            if (is_nan(v)) continue;
            lo[c] = std::fmin(lo[c], v);
            hi[c] = std::fmax(hi[c], v);
        }
    for (int c = 0; c < 3; ++c)
        if (!(hi[c] > lo[c])) { error = "negative hue: the paper's curves have no range"; return false; }
    Fnv pk;
    pk.num(1.0);
    pk.vec(scan.channel_density); pk.vec(scan.base_density); pk.vec(scan.illum_x_sens);
    pk.bytes(scan_illuminant_xy, 2 * sizeof(double));
    pk.bytes(lo, sizeof lo); pk.bytes(hi, sizeof hi);
    {
        std::lock_guard<std::mutex> guard(g_memo_lock);
        for (size_t i = 0; i < g_papers.size(); ++i) {
            if (g_papers[i].key != pk.h) continue;
            if (i != 0) std::rotate(g_papers.begin(), g_papers.begin() + long(i), g_papers.begin() + long(i) + 1);
            const PaperHalf& q = g_papers.front();
            std::memcpy(out.scan_to_d65, q.scan_to_d65, sizeof q.scan_to_d65);
            std::memcpy(out.d65_to_scan, q.d65_to_scan, sizeof q.d65_to_scan);
            out.gamut = q.gamut; out.gamut_l_lo = q.gamut_l_lo; out.gamut_l_hi = q.gamut_l_hi;
            return true;
        }
    }
    // The scan's XYZ is under the paper's viewing illuminant; Oklab is defined at D65.
    Vec d65;
    if (!standard_illuminant(colour, blob, "D65", d65, error)) return false;
    double d65_xy[2];
    illuminant_to_xy(colour, d65, d65_xy);
    Mat3 cat;
    if (!colour.matrix_chromatic_adaptation(scan_illuminant_xy, d65_xy, "CAT02", cat, error)) return false;
    cat.to_row_major(out.scan_to_d65);
    cat.inverse().to_row_major(out.d65_to_scan);
    build_gamut(scan, lo, hi, out);
    PaperHalf q;
    q.key = pk.h;
    std::memcpy(q.scan_to_d65, out.scan_to_d65, sizeof q.scan_to_d65);
    std::memcpy(q.d65_to_scan, out.d65_to_scan, sizeof q.d65_to_scan);
    q.gamut = out.gamut; q.gamut_l_lo = out.gamut_l_lo; q.gamut_l_hi = out.gamut_l_hi;
    std::lock_guard<std::mutex> guard(g_memo_lock);
    g_papers.insert(g_papers.begin(), std::move(q));
    if (g_papers.size() > kRemembered) g_papers.pop_back();
    return true;
}

}  // namespace spk
