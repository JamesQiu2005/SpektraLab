#include "digital_intermediate.hpp"

#include <algorithm>
#include <cmath>

#include "hanatos.hpp"
#include "latitude_fit.hpp"   // slm::kMidgray
#include "printing.hpp"
#include "spectral.hpp"

namespace spk {

namespace {

constexpr double kPi = 3.14159265358979323846;

// Pointer's gamut of real surface colours (Pointer 1980), xy, as colour-science
// ships it (`CCS_POINTER_GAMUT_BOUNDARY`). The colour matrix is fitted only on
// spectra inside it: the upsampling table spans the whole spectral locus, and
// near-monochromatic spectra no 3x3 can reach would otherwise dominate the fit
// (relative rms 0.77 against 0.15 with the gate; RFC-028 §7).
const double kPointer[32][2] = {
    {0.6590, 0.3160}, {0.6340, 0.3510}, {0.5940, 0.3910}, {0.5570, 0.4270}, {0.5230, 0.4620},
    {0.4820, 0.4910}, {0.4440, 0.5150}, {0.4090, 0.5460}, {0.3710, 0.5580}, {0.3320, 0.5730},
    {0.2880, 0.5840}, {0.2420, 0.5760}, {0.2020, 0.5300}, {0.1770, 0.4540}, {0.1510, 0.3890},
    {0.1510, 0.3300}, {0.1620, 0.2950}, {0.1570, 0.2660}, {0.1590, 0.2450}, {0.1420, 0.2140},
    {0.1410, 0.1950}, {0.1290, 0.1680}, {0.1380, 0.1410}, {0.1450, 0.1290}, {0.1450, 0.1060},
    {0.1610, 0.0940}, {0.1880, 0.0840}, {0.2520, 0.1040}, {0.3240, 0.1270}, {0.3930, 0.1650},
    {0.4510, 0.1990}, {0.5080, 0.2260}};

bool inside_pointer(double x, double y) {
    bool in = false;
    for (int i = 0, j = 31; i < 32; j = i++) {
        const double xi = kPointer[i][0], yi = kPointer[i][1];
        const double xj = kPointer[j][0], yj = kPointer[j][1];
        if (((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) in = !in;
    }
    return in;
}

// Björn Ottosson's Oklab (2020): LMS' -> Lab and back. M1 (XYZ D65 -> LMS) is
// composed with the working space's own matrix at build time.
const double kOkM1[9] = {0.8189330101, 0.3618667424, -0.1288597137,
                         0.0329845436, 0.9293118715, 0.0361456387,
                         0.0482003018, 0.2643662691, 0.6338517070};
const double kOkM2[9] = {0.2104542553, 0.7936177850, -0.0040720468,
                         1.9779984951, -2.4285922050, 0.4505937099,
                         0.0259040371, 0.7827717662, -0.8086757660};

void mul(const double* m, const double* v, double* out) {
    for (int i = 0; i < 3; ++i) out[i] = m[3 * i] * v[0] + m[3 * i + 1] * v[1] + m[3 * i + 2] * v[2];
}

void oklab(const double* to_lms, const double rgb[3], double lab[3]) {
    double lms[3];
    mul(to_lms, rgb, lms);
    for (double& v : lms) v = std::cbrt(std::fmax(v, 0.0));
    mul(kOkM2, lms, lab);
}

double wrap180(double d) {
    d = std::fmod(d + 180.0, 360.0);
    if (d < 0.0) d += 360.0;
    return d - 180.0;
}

// The window the kernel applies, on the *output* hue and chroma.
double blue_weight(double h_deg, double chroma) {
    const double d = wrap180(h_deg - kDiBlueHueCentre);
    if (std::fabs(d) >= kDiBlueHueHalfWidth) return 0.0;
    const double w = 0.5 * (1.0 + std::cos(kPi * d / kDiBlueHueHalfWidth));
    double g = (chroma - kDiBlueChromaLo) / (kDiBlueChromaHi - kDiBlueChromaLo);
    g = std::clamp(g, 0.0, 1.0);
    return w * g * g * (3.0 - 2.0 * g);
}

// One uniform patch through the film, on the host: exactly the per-pixel chain
// a flat field goes through (halation and every blur are identities on it; the
// highlight boost is image-global and off by default; grain is a zero-mean
// realisation and is left out).
struct FilmHost {
    const Params& p;
    const Vec& tc_lut;
    size_t side;
    Mat3 tc_b;
    Vec x;          // (K, 3) log exposure / gamma
    Vec curves0;    // (K, 3) the curves before DIR couplers, when they are on
    double dir[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    bool dir_on = false;

    FilmHost(const Params& params, const Vec& lut, size_t s, const Mat3& m)
        : p(params), tc_lut(lut), side(s), tc_b(m) {
        const Profile& film = p.film;
        const size_t k = film.data.n_exposure;
        x.assign(k * 3, 0.0);
        for (size_t i = 0; i < k; ++i)
            for (int c = 0; c < 3; ++c)
                x[3 * i + size_t(c)] = film.data.log_exposure[i] / p.film_render.density_curve_gamma;
        dir_on = p.film_render.dir_couplers.active;
        if (dir_on) {
            dir_couplers_matrix(p.film_render.dir_couplers, dir);
            density_curves_before_dir_couplers(film.normalized_curves, film.data.log_exposure, dir,
                                               film.info.is_positive(), curves0);
        }
    }

    double curve(const Vec& ys, int c, double v) const {
        const size_t k = p.film.data.n_exposure;
        std::vector<double> xs(k), yv(k);
        for (size_t i = 0; i < k; ++i) { xs[i] = x[3 * i + size_t(c)]; yv[i] = ys[3 * i + size_t(c)]; }
        return interp(v, xs.data(), yv.data(), k);
    }

    // input-space linear RGB -> the film's raw exposure (`node_upsample`)
    void raw(const double rgb[3], double out[3]) const {
        double xyz[3];
        tc_b.apply(rgb, xyz);
        const double b = xyz[0] + xyz[1] + xyz[2];
        const double denom = b > 1e-10 ? b : 1e-10;
        const double xy[2] = {xyz[0] / denom, xyz[1] / denom};
        double tc[2];
        tri2quad(xy, tc);
        lut2d_cubic_host(tc_lut, side, tc, out);
        for (int c = 0; c < 3; ++c) out[c] *= b;
    }

    // raw -> developed layer density (`expose.log`, `develop.curves`, `dir_couplers`)
    void develop(const double raw[3], double cmy[3]) const {
        double lr[3], c0[3];
        for (int c = 0; c < 3; ++c) {
            lr[c] = std::log10(std::fmax(raw[c], 0.0) + 1e-10);
            c0[c] = curve(p.film.normalized_curves, c, lr[c]);
        }
        if (!dir_on) { for (int c = 0; c < 3; ++c) cmy[c] = c0[c]; return; }
        for (int j = 0; j < 3; ++j) {
            const double corr = c0[0] * dir[j] + c0[1] * dir[3 + j] + c0[2] * dir[6 + j];
            cmy[j] = curve(curves0, j, lr[j] - corr);
        }
    }
};

// log10 of the base-free transmittance, per channel, through `ixs`.
void read_log_t(const DiConstants& k, const double cmy[3], double out[3]) {
    double acc[3] = {0, 0, 0};
    for (size_t l = 0; l < kNumWavelengths; ++l) {
        const double d = cmy[0] * k.chd[3 * l] + cmy[1] * k.chd[3 * l + 1] + cmy[2] * k.chd[3 * l + 2];
        const double t = std::pow(10.0, -d);
        for (int c = 0; c < 3; ++c) acc[c] += t * k.ixs[3 * l + size_t(c)];
    }
    for (int c = 0; c < 3; ++c) out[c] = std::log10(std::fmax(acc[c], 0.0) + 1e-10);
}

// The whole per-pixel DI, on the host, up to the working-space linear value.
void di_linear(const DiConstants& k, const double log_t[3], double lin[3]) {
    double pos[3];
    for (int c = 0; c < 3; ++c) {
        std::vector<double> xs(k.curve.k), ys(k.curve.k);
        for (size_t i = 0; i < k.curve.k; ++i) {
            xs[i] = k.curve.x[3 * i + size_t(c)];
            ys[i] = k.curve.y[3 * i + size_t(c)];
        }
        pos[c] = std::pow(10.0, interp(log_t[c], xs.data(), ys.data(), k.curve.k));
    }
    for (int j = 0; j < 3; ++j)
        lin[j] = pos[0] * k.matrix[j] + pos[1] * k.matrix[3 + j] + pos[2] * k.matrix[6 + j];
}

}  // namespace

bool di_constants(const Colour& colour, const Blob& blob, const Params& params,
                  const Vec& tc_lut, size_t side, const Mat3& tc_b, const Vec& film_sensitivity,
                  DiConstants& out, std::string& error) {
    const Profile& film = params.film;
    const Profile& paper = params.di_paper;
    out = DiConstants{};
    out.paper = paper.info.stock;

    // --- the printing-density read, base removed --------------------------
    // A wavelength with any undefined value is dropped from the integral, as
    // `prepare_spectral_constants` drops it for the scan and the enlarger.
    Vec lamp;
    if (!standard_illuminant(colour, blob, paper.info.reference_illuminant, lamp, error)) return false;
    out.chd.assign(kNumWavelengths * 3, 0.0);
    out.ixs.assign(kNumWavelengths * 3, 0.0);
    double colsum[3] = {0, 0, 0};
    for (size_t l = 0; l < kNumWavelengths; ++l) {
        bool valid = !is_nan(film.data.base_density[l]);
        for (int c = 0; c < 3 && valid; ++c) valid = !is_nan(film.data.channel_density[3 * l + size_t(c)]);
        if (!valid) continue;
        for (int c = 0; c < 3; ++c) {
            out.chd[3 * l + size_t(c)] = film.data.channel_density[3 * l + size_t(c)];
            const double s = std::pow(10.0, paper.data.log_sensitivity[3 * l + size_t(c)]);
            const double w = is_nan(s) ? 0.0 : s * lamp[l];
            out.ixs[3 * l + size_t(c)] = w;
            colsum[c] += w;
        }
    }
    for (int c = 0; c < 3; ++c) {
        if (!(colsum[c] > 0.0)) {
            error = "digital intermediate: paper '" + paper.info.stock + "' has no sensitivity where '" +
                    film.info.stock + "' is defined";
            return false;
        }
    }
    for (size_t l = 0; l < kNumWavelengths; ++l)
        for (int c = 0; c < 3; ++c) out.ixs[3 * l + size_t(c)] /= colsum[c];

    // --- the neutral wedge, and the reversal on the film's own curve -------
    const FilmHost host(params, tc_lut, side, tc_b);
    const double lo = -14.0, hi = 14.0, step = 0.05;
    const size_t n = size_t(std::lround((hi - lo) / step)) + 1;
    std::vector<double> stops(n), dens(n * 3);
    for (size_t i = 0; i < n; ++i) {
        stops[i] = lo + step * double(i);
        const double g = slm::kMidgray * std::pow(2.0, stops[i]);
        const double rgb[3] = {g, g, g};
        double raw[3], cmy[3], lt[3];
        host.raw(rgb, raw);
        host.develop(raw, cmy);
        read_log_t(out, cmy, lt);
        for (int c = 0; c < 3; ++c) dens[3 * i + size_t(c)] = -lt[c];
    }
    // green's gamma over -2..+2 stops, least squares, and its density at grey
    {
        double sx = 0, sy = 0, sxx = 0, sxy = 0, m = 0;
        for (size_t i = 0; i < n; ++i) {
            if (stops[i] < -2.0 - 1e-9 || stops[i] > 2.0 + 1e-9) continue;
            const double xv = stops[i] * std::log10(2.0), yv = dens[3 * i + 1];
            sx += xv; sy += yv; sxx += xv * xv; sxy += xv * yv; m += 1.0;
        }
        out.gamma_green = (m * sxy - sx * sy) / (m * sxx - sx * sx);
        out.density_green_mid = dens[3 * size_t(std::lround(-lo / step)) + 1];
    }
    if (!(out.gamma_green > 0.05)) {
        error = "digital intermediate: '" + film.info.stock + "' has no usable neutral contrast";
        return false;
    }
    // Tables: x = log10 T ascending (so the wedge runs from dense to clear),
    // y = the positive, the same for every channel at a given stop -- which is
    // what makes a grey exactly neutral. A flat run at the film's own ends is
    // nudged strictly increasing; there the output is the end value anyway.
    out.curve.k = n;
    out.curve.x.assign(n * 3, 0.0);
    out.curve.y.assign(n * 3, 0.0);
    out.curve.inv.assign((n - 1) * 3, 0.0);
    for (size_t r = 0; r < n; ++r) {
        const size_t i = n - 1 - r;   // descending stops
        const double y = std::log10(slm::kMidgray) + (dens[3 * i + 1] - out.density_green_mid) / out.gamma_green;
        for (int c = 0; c < 3; ++c) {
            double xv = -dens[3 * i + size_t(c)];
            if (r > 0) xv = std::fmax(xv, out.curve.x[3 * (r - 1) + size_t(c)] + 1e-9);
            out.curve.x[3 * r + size_t(c)] = xv;
            out.curve.y[3 * r + size_t(c)] = y;
        }
    }
    for (size_t r = 0; r + 1 < n; ++r)
        for (int c = 0; c < 3; ++c) {
            const double dx = out.curve.x[3 * (r + 1) + size_t(c)] - out.curve.x[3 * r + size_t(c)];
            out.curve.inv[3 * r + size_t(c)] = dx != 0.0 ? 1.0 / dx : 0.0;
        }

    // --- the colour step: film RGB -> working RGB --------------------------
    // Least squares over the upsampler's own spectra inside Pointer's gamut,
    // through the same film eye the tc_lut uses, with the neutral pinned
    // (M @ [1,1,1] = [1,1,1]). Not fitted to any chart.
    Vec spectra;
    uint32_t dims[4] = {0, 0, 0, 0};
    uint32_t ndim = 0;
    if (!blob.get("hanatos/spectra_lut", spectra, dims, ndim, error)) return false;
    Vec weights;
    if (!tc_lut_weights(colour, blob, film, params.settings, film_sensitivity, weights, error)) return false;
    Vec ref;
    if (!standard_illuminant(colour, blob, film.info.reference_illuminant, ref, error)) return false;
    const Vec& cmfs = colour.cmfs_1931_2deg();
    double e_white[3] = {0, 0, 0}, x_white[3] = {0, 0, 0};
    for (size_t l = 0; l < kNumWavelengths; ++l)
        for (int c = 0; c < 3; ++c) {
            e_white[c] += ref[l] * weights[3 * l + size_t(c)];
            x_white[c] += ref[l] * cmfs[3 * l + size_t(c)];
        }
    double ref_xy[2];
    Colour::XYZ_to_xy(x_white, ref_xy);
    Mat3 xyz_to_work;
    if (!colour.matrix_XYZ_to_RGB(params.io.output_color_space, ref_xy, "CAT02", xyz_to_work, error))
        return false;
    // Normal equations per output row: G = E^T E, b_j = E^T r_j.
    double G[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}}, B[3][3] = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
    double rr = 0.0;
    size_t used = 0;
    const size_t cells = size_t(dims[0]) * size_t(dims[1]);
    std::vector<double> fitE, fitR;
    fitE.reserve(cells * 3);
    fitR.reserve(cells * 3);
    for (size_t cell = 0; cell < cells; ++cell) {
        const double* sp = &spectra[cell * kNumWavelengths];
        double e[3] = {0, 0, 0}, X[3] = {0, 0, 0};
        for (size_t l = 0; l < kNumWavelengths; ++l)
            for (int c = 0; c < 3; ++c) {
                e[c] += sp[l] * weights[3 * l + size_t(c)];
                X[c] += sp[l] * cmfs[3 * l + size_t(c)];
            }
        const double sum = X[0] + X[1] + X[2];
        if (!(X[1] > 1e-9) || !(sum > 0.0)) continue;
        if (!(e[0] > 0.0 && e[1] > 0.0 && e[2] > 0.0)) continue;
        if (!inside_pointer(X[0] / sum, X[1] / sum)) continue;
        double en[3], xn[3], r[3];
        for (int c = 0; c < 3; ++c) {
            en[c] = e[c] / e_white[c] / (X[1] / x_white[1]);
            xn[c] = X[c] / X[1];
        }
        xyz_to_work.apply(xn, r);
        for (int a = 0; a < 3; ++a)
            for (int b = 0; b < 3; ++b) { G[a][b] += en[a] * en[b]; B[a][b] += en[a] * r[b]; }
        for (int c = 0; c < 3; ++c) { fitE.push_back(en[c]); fitR.push_back(r[c]); rr += r[c] * r[c]; }
        ++used;
    }
    if (used < 100) {
        error = "digital intermediate: too few spectra to fit the colour step";
        return false;
    }
    const Mat3 Gi = Mat3::from_row_major(&G[0][0]).inverse();
    double gi1[3];
    const double one[3] = {1, 1, 1};
    Gi.apply(one, gi1);
    const double denom = gi1[0] + gi1[1] + gi1[2];
    double M[3][3];   // M[j][i]: working channel j from film channel i
    for (int j = 0; j < 3; ++j) {
        const double b[3] = {B[0][j], B[1][j], B[2][j]};
        double m0[3];
        Gi.apply(b, m0);
        const double lambda = (1.0 - (m0[0] + m0[1] + m0[2])) / denom;
        for (int i = 0; i < 3; ++i) M[j][i] = m0[i] + lambda * gi1[i];
    }
    double ee = 0.0;
    for (size_t s = 0; s < used; ++s)
        for (int j = 0; j < 3; ++j) {
            const double pred = M[j][0] * fitE[3 * s] + M[j][1] * fitE[3 * s + 1] + M[j][2] * fitE[3 * s + 2];
            const double d = pred - fitR[3 * s + size_t(j)];
            ee += d * d;
        }
    out.matrix_fit_rms = std::sqrt(ee / rr);
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) out.matrix[3 * i + j] = M[j][i];   // x @ M convention

    // --- Oklab, for the optional blue-sector compensation ------------------
    {
        double d65_xy[2];
        Vec d65;
        if (!standard_illuminant(colour, blob, "D65", d65, error)) return false;
        illuminant_to_xy(colour, d65, d65_xy);
        Mat3 work_to_xyz65;
        if (!colour.matrix_RGB_to_XYZ(params.io.output_color_space, d65_xy, "CAT02", work_to_xyz65, error))
            return false;
        const Mat3 lms = Mat3::from_row_major(kOkM1) * work_to_xyz65;
        lms.to_row_major(out.to_lms);
        lms.inverse().to_row_major(out.from_lms);
    }

    // --- the blue-sector fit: this film's own chain against its input ------
    // Synthetic blues at 0 EV, generated in Oklab around the window, through
    // the host film and the DI above; one hue rotation and one chroma scale,
    // weighted by the window on the output. Camera-independent by design: it
    // corrects the reconstruct -> film -> scan chain, which is the part that
    // is certain, and not any camera's guess at the scene.
    Mat3 work_to_input;
    if (!colour.matrix_RGB_to_RGB(params.io.output_color_space, params.io.input_color_space, "CAT02",
                                  work_to_input, error)) return false;
    const Mat3 lms_to_work = Mat3::from_row_major(out.from_lms);
    const double m2i[9] = {1.0, 0.3963377774, 0.2158037573, 1.0, -0.1055613458, -0.0638541728,
                           1.0, -0.0894841775, -1.2914855480};
    double sw = 0.0, sdh = 0.0, slogc = 0.0;
    for (double L : {0.50, 0.62, 0.74})
        for (double C : {0.06, 0.10, 0.14, 0.18})
            for (double h = kDiBlueHueCentre - kDiBlueHueHalfWidth - 20.0;
                 h <= kDiBlueHueCentre + kDiBlueHueHalfWidth + 20.0 + 1e-9; h += 7.5) {
                const double lab[3] = {L, C * std::cos(h * kPi / 180.0), C * std::sin(h * kPi / 180.0)};
                double l_[3], lms[3], work[3], in[3];
                mul(m2i, lab, l_);
                for (int c = 0; c < 3; ++c) lms[c] = l_[c] * l_[c] * l_[c];
                lms_to_work.apply(lms, work);
                work_to_input.apply(work, in);
                if (!(in[0] > 0.0 && in[1] > 0.0 && in[2] > 0.0)) continue;
                double raw[3], cmy[3], lt[3], lin[3], lab_in[3], lab_out[3];
                host.raw(in, raw);
                host.develop(raw, cmy);
                read_log_t(out, cmy, lt);
                di_linear(out, lt, lin);
                oklab(out.to_lms, work, lab_in);
                oklab(out.to_lms, lin, lab_out);
                const double c_in = std::hypot(lab_in[1], lab_in[2]);
                const double c_out = std::hypot(lab_out[1], lab_out[2]);
                const double h_in = std::atan2(lab_in[2], lab_in[1]) * 180.0 / kPi;
                const double h_out = std::atan2(lab_out[2], lab_out[1]) * 180.0 / kPi;
                const double w = blue_weight(h_out, c_out) * c_out;
                if (!(w > 0.0) || !(c_in > 0.0)) continue;
                sw += w;
                sdh += w * wrap180(h_in - h_out);
                slogc += w * std::log(c_in / c_out);
            }
    if (sw > 0.0) {
        out.blue_delta_deg = std::clamp(sdh / sw, -30.0, 30.0);
        out.blue_kappa = std::clamp(std::exp(slogc / sw), 0.5, 1.5);
    }
    return true;
}

void di_live_offsets(const Params& params, double out[3]) {
    // log10 units. Print brightness: `print_exposure = 2^-stops`, so one UI
    // stop is one stop of the positive. The filter shifts: per unit, the print
    // moves blue against green by 0.050 stop (Y) and green against red and blue
    // by ~0.03 stop (M) at mid grey -- measured on Portra 400 / Portra Endura
    // through the shipping dylib, 2026-09-29 -- so the DI does the same.
    const double k = -std::log10(std::fmax(params.enlarger.print_exposure, 1e-6));
    const double stop = std::log10(2.0);
    out[0] = k;
    out[1] = k + params.enlarger.m_filter_shift * 0.03 * stop;
    out[2] = k + params.enlarger.y_filter_shift * 0.05 * stop;
}

}  // namespace spk
