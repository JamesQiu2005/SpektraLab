// Film Edge (RFC-031/032: overscan) end to end on the Windows Vulkan engine,
// through the exported C ABI only. These are the checks of
// tests/overscan_checks.py that say most about whether the film around the
// frame is laid out and rendered where it should be -- that suite needs
// Python and numpy, which the Windows build machine does not have -- recast so
// that every expectation comes from `spk_overscan_geometry` or from the layout
// overscan.cpp documents, never from a Mac render (none is compared here).
//
// Every format, several stocks with edge prints of their own (Kodak's text
// and DX bars, Fujifilm's dot faces on slides, negatives and 120, Eastman's
// cine line), the strip running across the picture and down it:
//   - the render is the canvas the geometry reports: the film's width across,
//     the frame and a part-gap at each end along, the gate inside it;
//   - inside the gate the picture is the render without film edge, sampled
//     where the gate's quad puts it, to a few codes;
//   - 135 perforations are where overscan.cpp punches them: 1.98 x 2.80 mm,
//     every 4.75 mm, both rows in step, 2.00 mm from the edge, on the phase
//     that keeps the edge print inside the frame; the scan's light through
//     them, or black on request; no light anywhere on 120;
//   - the edge print is on the rebate, never inside the gate's span, and the
//     frame number changes it; the DX code reads back as the stock's;
//   - the date back on 120 prints in the margin beside the frame, with the
//     shooting data beside it; on 135 the data goes between the frames while
//     the date stays in the picture;
//   - a half-frame pair is two gates one advance apart, each picture its own,
//     the second taking its own Scene Placement and date; turned, one above
//     the other;
//   - renders reproduce run to run and session to session, reprints reuse
//     the cached negative where they should and equal a fresh render, the
//     carriers show black or light past the film, and what overscan cannot do
//     is refused by name (the striped executor among it).
// Effects that would carry one region into another are off, as in
// date_back_render.cpp -- grain, glare, halation, couplers' diffusion, lens and
// scanner blur, the meter, and the spool's fog and leaks unless a check is
// about them; the scanner's unsharp mask stays on, which is why picture
// comparisons keep a few pixels from the gate.
#include "spektrafilm/spk_engine.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

int g_checks = 0, g_failures = 0;

void check(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_checks;
    if (!ok) ++g_failures;
    std::cout << (ok ? "PASS " : "FAIL ") << what << (detail.empty() ? "" : " -- " + detail) << '\n';
}

[[noreturn]] void fail(const std::string& what) { throw std::runtime_error(what); }

template <typename... A>
std::string fmt(const char* f, A... a) {
    char b[600];
    std::snprintf(b, sizeof b, f, a...);
    return b;
}

struct EngineDeleter { void operator()(spk_engine* e) const { spk_engine_destroy(e); } };
struct SessionDeleter { void operator()(spk_session* s) const { spk_session_release(s); } };
using Engine = std::unique_ptr<spk_engine, EngineDeleter>;
using Session = std::unique_ptr<spk_session, SessionDeleter>;

// The fixture's colour setup (tests/fixtures/windows/abi_probe_params.json)
// with the spatial and stochastic effects off; the stocks are each case's.
const char* kBase =
    "\"input_color_space\":\"ProPhoto RGB\",\"input_cctf_decoding\":false,"
    "\"output_color_space\":\"ProPhoto RGB\",\"output_cctf_encoding\":true,"
    "\"grain_active\":false,\"glare_active\":false,\"halation_active\":false,"
    "\"dir_couplers_active\":false,\"lens_blur_um\":0,\"scanner_lens_blur\":0,\"auto_exposure\":false";

constexpr double kWhite = 65535.0;

struct Frame {
    uint32_t w = 0, h = 0;
    std::vector<float> rgb;
};

// A mid-toned gradient with slow ripples on it: smooth enough that sampling it
// a fraction of a pixel off costs nothing measurable, structured enough that a
// picture placed even a fraction of a millimetre off shows.
Frame synthetic(uint32_t w, uint32_t h, float gain = 1.0f) {
    Frame f{w, h, std::vector<float>(size_t(w) * h * 3)};
    const double k = 6.283185307179586;
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = 0; x < w; ++x) {
            const double u = (x + 0.5) / w, v = (y + 0.5) / h;
            float* p = &f.rgb[(size_t(y) * w + x) * 3];
            p[0] = gain * float(0.05 + 0.28 * u + 0.04 * std::sin(k * (2.5 * u + 0.3)) * std::cos(k * 1.5 * v) +
                                0.015 * std::sin(k * x / 97.0));
            p[1] = gain * float(0.05 + 0.10 * u + 0.10 * v + 0.04 * std::sin(k * (1.7 * v + 0.1)) +
                                0.015 * std::cos(k * y / 89.0));
            p[2] = gain * float(0.06 + 0.16 * v + 0.03 * std::cos(k * 2.2 * u) + 0.015 * std::sin(k * (x + y) / 113.0));
        }
    return f;
}

Frame transposed(const Frame& f) {
    Frame t{f.h, f.w, std::vector<float>(f.rgb.size())};
    for (uint32_t y = 0; y < f.h; ++y)
        for (uint32_t x = 0; x < f.w; ++x)
            std::copy_n(&f.rgb[(size_t(y) * f.w + x) * 3], 3, &t.rgb[(size_t(x) * t.w + y) * 3]);
    return t;
}

struct Img {
    uint32_t w = 0, h = 0;
    std::vector<uint16_t> px;   // RGBA, rows packed
    int negative_cached = 0;
    const uint16_t* at(uint32_t x, uint32_t y) const { return &px[(size_t(y) * w + x) * 4]; }
    double lum(uint32_t x, uint32_t y) const {
        const uint16_t* p = at(x, y);
        return (double(p[0]) + p[1] + p[2]) / 3.0;
    }
    bool same(const Img& o) const { return w == o.w && h == o.h && px == o.px; }
};

std::string delta_of(const std::string& extra) {
    return "{" + std::string(kBase) + (extra.empty() ? "" : "," + extra) + "}";
}

Session open(spk_engine* e, const Frame& f, const std::string& extra) {
    const std::string delta = delta_of(extra);
    const spk_image img{f.rgb.data(), f.w, f.h, 3};
    Session s(spk_open(e, &img, delta.c_str(), nullptr));
    if (!s) fail("open refused " + delta + ": " + spk_last_error(e));
    return s;
}

Img render(spk_engine* e, spk_session* s, const char* tier = "full", bool reprint = false) {
    spk_result r{};
    const spk_status st = reprint ? spk_reprint(s, tier, &r) : spk_render(s, tier, &r);
    if (st != SPK_OK || !r.rgba16) {
        const std::string error = spk_last_error(e);
        spk_result_free(&r);
        fail(std::string(tier) + (reprint ? " reprint" : " render") + " failed: " + error);
    }
    Img out;
    out.w = r.width;
    out.h = r.height;
    out.negative_cached = r.negative_was_cached;
    out.px.resize(size_t(r.width) * r.height * 4);
    for (uint32_t y = 0; y < r.height; ++y)
        std::copy_n(r.rgba16 + size_t(y) * r.row_stride_px * 4, size_t(r.width) * 4, out.px.data() + size_t(y) * r.width * 4);
    spk_result_free(&r);
    return out;
}

Img shot(spk_engine* e, const Frame& f, const std::string& extra, const char* tier = "full") {
    Session s = open(e, f, extra);
    return render(e, s.get(), tier);
}

// What a render that must be refused says ("" when it rendered).
std::string refusal(spk_engine* e, const Frame& f, const std::string& extra) {
    const std::string delta = delta_of(extra);
    const spk_image img{f.rgb.data(), f.w, f.h, 3};
    Session s(spk_open(e, &img, delta.c_str(), nullptr));
    if (!s) return spk_last_error(e);
    spk_result r{};
    const spk_status st = spk_render(s.get(), "full", &r);
    const std::string error = st == SPK_OK ? std::string() : std::string(spk_last_error(e));
    spk_result_free(&r);
    return error;
}

// --- spk_overscan_geometry, read the way a host reads it --------------------
struct Geometry {
    bool valid = false, vertical = false;
    uint32_t cw = 0, ch = 0;
    double px = 0, gate_along = 0, gate_across = 0, penumbra = 0;
    std::string format, json;
    std::vector<std::array<double, 8>> gates;
};

double number_after(const std::string& j, const std::string& key) {
    const size_t at = j.find("\"" + key + "\":");
    if (at == std::string::npos) return NAN;
    const char* p = j.c_str() + at + key.size() + 3;
    char* end = nullptr;
    const double v = std::strtod(p, &end);
    return end == p ? NAN : v;
}

// Every number inside the bracketed value of `key`.
std::vector<double> numbers_in(const std::string& j, const std::string& key) {
    std::vector<double> out;
    const size_t at = j.find("\"" + key + "\":[");
    if (at == std::string::npos) return out;
    int depth = 0;
    for (size_t i = at + key.size() + 3; i < j.size(); ++i) {
        const char c = j[i];
        if (c == '[') ++depth;
        else if (c == ']') { if (--depth == 0) break; }
        else if (c == '-' || (c >= '0' && c <= '9')) {
            char* end = nullptr;
            out.push_back(std::strtod(j.c_str() + i, &end));
            i = size_t(end - j.c_str()) - 1;
        }
    }
    return out;
}

Geometry geometry(spk_engine* e, spk_session* s) {
    char* text = nullptr;
    if (spk_overscan_geometry(s, &text) != SPK_OK || !text) fail(std::string("overscan geometry failed: ") + spk_last_error(e));
    Geometry g;
    g.json = text;
    spk_string_free(text);
    g.valid = g.json.find("\"valid\":true") != std::string::npos;
    if (!g.valid) return g;
    g.vertical = g.json.find("\"vertical\":true") != std::string::npos;
    g.cw = uint32_t(number_after(g.json, "canvas_w"));
    g.ch = uint32_t(number_after(g.json, "canvas_h"));
    g.px = number_after(g.json, "mm_per_px");
    g.penumbra = number_after(g.json, "penumbra_mm");
    const std::vector<double> gm = numbers_in(g.json, "gate_mm");
    if (gm.size() == 2) { g.gate_along = gm[0]; g.gate_across = gm[1]; }
    const std::vector<double> q = numbers_in(g.json, "gates");
    for (size_t k = 0; k + 8 <= q.size(); k += 8) {
        std::array<double, 8> a{};
        std::copy_n(q.begin() + std::ptrdiff_t(k), 8, a.begin());
        g.gates.push_back(a);
    }
    const size_t f = g.json.find("\"format\":\"");
    if (f != std::string::npos) g.format = g.json.substr(f + 10, g.json.find('"', f + 10) - f - 10);
    return g;
}

// One gate's film frame on the canvas: film mm from the gate's (s0, t0)
// corner -- s along the film, t across it -- to canvas pixels (pixel i's
// centre at i + 0.5, as overscan.cpp's film_to_canvas_px has it) and back.
struct GateFrame {
    double ox = 0, oy = 0, sx = 0, sy = 0, tx = 0, ty = 0, gw = 0, gh = 0;
    void canvas(double s, double t, double& x, double& y) const {
        x = ox + s * sx + t * tx;
        y = oy + s * sy + t * ty;
    }
    void film(double x, double y, double& s, double& t) const {
        const double det = sx * ty - tx * sy, dx = x - ox, dy = y - oy;
        s = (dx * ty - tx * dy) / det;
        t = (sx * dy - sy * dx) / det;
    }
};

GateFrame gate_frame(const Geometry& g, size_t k) {
    const std::array<double, 8>& q = g.gates[k];
    GateFrame f;
    f.ox = q[0] * g.cw; f.oy = q[1] * g.ch;
    f.sx = (q[2] * g.cw - f.ox) / g.gate_along; f.sy = (q[3] * g.ch - f.oy) / g.gate_along;
    f.tx = (q[6] * g.cw - f.ox) / g.gate_across; f.ty = (q[7] * g.ch - f.oy) / g.gate_across;
    f.gw = g.gate_along; f.gh = g.gate_across;
    return f;
}

// Bilinear RGB at frame coordinates (pixel centres on integers), clamped at
// the edges -- spk_overscan_canvas's own sampling of the frame.
void sample(const Img& im, double fx, double fy, double out[3]) {
    fx = std::clamp(fx, 0.0, double(im.w) - 1.0);
    fy = std::clamp(fy, 0.0, double(im.h) - 1.0);
    const uint32_t x0 = uint32_t(fx), y0 = uint32_t(fy);
    const uint32_t x1 = std::min(x0 + 1, im.w - 1), y1 = std::min(y0 + 1, im.h - 1);
    const double ax = fx - x0, ay = fy - y0;
    for (int c = 0; c < 3; ++c) {
        const double a = im.at(x0, y0)[c], b = im.at(x1, y0)[c], d = im.at(x0, y1)[c], e = im.at(x1, y1)[c];
        out[c] = (a + (b - a) * ax) * (1 - ay) + (d + (e - d) * ax) * ay;
    }
}

double lum_at(const Img& im, double x, double y) {   // canvas coordinates, centres at i + 0.5
    double v[3];
    sample(im, x - 0.5, y - 0.5, v);
    return (v[0] + v[1] + v[2]) / 3.0;
}

// The canvas's extent along the film, in a gate frame's s.
void along_extent(const Img& im, const GateFrame& f, double& lo, double& hi) {
    lo = 1e30; hi = -1e30;
    for (double x : {0.0, double(im.w)})
        for (double y : {0.0, double(im.h)}) {
            double s, t;
            f.film(x, y, s, t);
            lo = std::min(lo, s); hi = std::max(hi, s);
        }
}

struct Diff { double max = 0, mean = 0; size_t n = 0; };

// The canvas inside gate `k`, `inset` mm in from its sides, against `plain`
// -- the same frame rendered without film edge -- sampled where
// spk_overscan_canvas samples the frame for that point: s counts from the
// first gate, so a pair's second picture is the frame's second half. Codes
// of 65535, any channel.
Diff interior(const Img& canvas, const Geometry& g, size_t k, const Img& plain, double inset) {
    const GateFrame f = gate_frame(g, k), f0 = gate_frame(g, 0);
    double s_off, t_unused;
    f0.film(f.ox, f.oy, s_off, t_unused);
    Diff d;
    double sum = 0;
    for (uint32_t y = 0; y < canvas.h; ++y)
        for (uint32_t x = 0; x < canvas.w; ++x) {
            double s, t;
            f.film(x + 0.5, y + 0.5, s, t);
            if (s < inset || s > f.gw - inset || t < inset || t > f.gh - inset) continue;
            const double S = s + s_off;
            const double fx = g.vertical ? (f.gh - t) / g.px - 0.5 : S / g.px - 0.5;
            const double fy = g.vertical ? S / g.px - 0.5 : t / g.px - 0.5;
            double want[3];
            sample(plain, fx, fy, want);
            const uint16_t* p = canvas.at(x, y);
            for (int c = 0; c < 3; ++c) {
                const double e = std::fabs(double(p[c]) - want[c]);
                d.max = std::max(d.max, e);
                sum += e;
            }
            ++d.n;
        }
    d.mean = d.n ? sum / (3.0 * d.n) : 0.0;
    return d;
}

// Two canvases of one layout, inside gate `k`, `inset` mm in.
Diff gate_diff(const Img& a, const Img& b, const Geometry& g, size_t k, double inset) {
    const GateFrame f = gate_frame(g, k);
    Diff d;
    double sum = 0;
    for (uint32_t y = 0; y < a.h; ++y)
        for (uint32_t x = 0; x < a.w; ++x) {
            double s, t;
            f.film(x + 0.5, y + 0.5, s, t);
            if (s < inset || s > f.gw - inset || t < inset || t > f.gh - inset) continue;
            for (int c = 0; c < 3; ++c) {
                const double e = std::fabs(double(a.at(x, y)[c]) - double(b.at(x, y)[c]));
                d.max = std::max(d.max, e);
                sum += e;
            }
            ++d.n;
        }
    d.mean = d.n ? sum / (3.0 * d.n) : 0.0;
    return d;
}

// Where two renders of one canvas differ by more than `codes` in a channel.
std::vector<uint8_t> changed(const Img& a, const Img& b, int codes = 2000) {
    std::vector<uint8_t> m(size_t(a.w) * a.h, 0);
    if (!(a.w == b.w && a.h == b.h)) return m;
    for (size_t i = 0; i < m.size(); ++i)
        for (int c = 0; c < 3; ++c)
            if (std::abs(int(a.px[i * 4 + size_t(c)]) - int(b.px[i * 4 + size_t(c)])) > codes) { m[i] = 1; break; }
    return m;
}

// The film-frame box of a mask's pixels, and how many fall inside a box.
struct Spread {
    size_t n = 0, inside = 0;
    double s0 = 1e30, s1 = -1e30, t0 = 1e30, t1 = -1e30;
    std::string str() const { return fmt("%zu px over s %.2f..%.2f, t %.2f..%.2f mm", n, s0, s1, t0, t1); }
};
Spread spread(const std::vector<uint8_t>& m, uint32_t w, const GateFrame& f, double bs0 = 0, double bs1 = 0,
              double bt0 = 0, double bt1 = 0) {
    Spread r;
    for (size_t i = 0; i < m.size(); ++i) {
        if (!m[i]) continue;
        double s, t;
        f.film(double(i % w) + 0.5, double(i / w) + 0.5, s, t);
        ++r.n;
        r.s0 = std::min(r.s0, s); r.s1 = std::max(r.s1, s);
        r.t0 = std::min(r.t0, t); r.t1 = std::max(r.t1, t);
        if (s >= bs0 && s <= bs1 && t >= bt0 && t <= bt1) ++r.inside;
    }
    return r;
}

// Lit stretches along a line through the canvas, in film mm: the line is s
// from `lo` to `hi` at t = `fixed` (along) or t from `lo` to `hi` at s =
// `fixed`, read every quarter pixel; a stretch is where the luminance is
// above half way between the line's darkest and brightest, its ends found
// to a fraction of a sample. Stretches cut by the line's ends are dropped.
struct Run { double a, b; };
std::vector<Run> runs_on(const Img& im, const GateFrame& f, double px, bool along, double fixed, double lo, double hi,
                         double* dark = nullptr, double* bright = nullptr) {
    std::vector<double> pos, val;
    for (double q = lo; q <= hi; q += 0.25 * px) {
        double x, y;
        if (along) f.canvas(q, fixed, x, y); else f.canvas(fixed, q, x, y);
        if (x < 0.5 || y < 0.5 || x > im.w - 0.5 || y > im.h - 0.5) continue;
        pos.push_back(q);
        val.push_back(lum_at(im, x, y));
    }
    std::vector<Run> out;
    if (val.size() < 3) return out;
    const double mn = *std::min_element(val.begin(), val.end()), mx = *std::max_element(val.begin(), val.end());
    if (dark) *dark = mn;
    if (bright) *bright = mx;
    const double thr = 0.5 * (mn + mx);
    double start = NAN;
    for (size_t i = 1; i < val.size(); ++i) {
        const bool up = val[i - 1] < thr && val[i] >= thr, down = val[i - 1] >= thr && val[i] < thr;
        if (!up && !down) continue;
        const double at = pos[i - 1] + (thr - val[i - 1]) / (val[i] - val[i - 1]) * (pos[i] - pos[i - 1]);
        if (up) start = at;
        else if (!std::isnan(start)) { out.push_back({start, at}); start = NAN; }
    }
    return out;
}

// --- the DX code, read back as a reader reads it (overscan_checks.py) ------
// A canvas's luminance as the film lies: rows across from its t = 0 edge,
// columns along it. A strip down the picture is turned back (there s = v and
// t = -u, so t = 0 is the canvas's right edge).
std::vector<double> film_lum(const Img& im, bool vertical, uint32_t& rows, uint32_t& cols) {
    rows = vertical ? im.w : im.h;
    cols = vertical ? im.h : im.w;
    std::vector<double> L(size_t(rows) * cols);
    for (uint32_t r = 0; r < rows; ++r)
        for (uint32_t c = 0; c < cols; ++c)
            L[size_t(r) * cols + c] = vertical ? im.lum(im.w - 1 - r, c) : im.lum(c, r);
    return L;
}

double percentile(std::vector<double> v, double q) {   // numpy's linear interpolation
    if (v.empty()) return 0.0;
    std::sort(v.begin(), v.end());
    const double i = q / 100.0 * double(v.size() - 1);
    const size_t a = size_t(i), b = std::min(a + 1, v.size() - 1);
    return v[a] + (v[b] - v[a]) * (i - double(a));
}

struct Dx { bool found = false; int number = 0, frame = 0; bool half = false, parity = false; };

// Find the clock track (a 5-module bar, 23 alternating singles, a 3-module
// bar) 1.59 mm from the film's bottom edge, then sample the data track 0.49
// mm from it at the clock's module centres; the first complete code wins.
Dx decode_dx(const std::vector<double>& L, uint32_t rows, uint32_t cols, double px) {
    Dx out;
    const auto row = [&](double mm) {
        const long r = long(rows) - 1 - std::lround(mm / px);
        return std::vector<double>(L.begin() + std::ptrdiff_t(size_t(r) * cols), L.begin() + std::ptrdiff_t(size_t(r + 1) * cols));
    };
    const std::vector<double> clock = row(1.59), data = row(0.49);
    const auto threshold = [](const std::vector<double>& v) {
        std::vector<double> ink;
        for (double x : v) if (x < 0.9 * kWhite) ink.push_back(x);   // the scan's light through a hole is not ink
        return 0.5 * (percentile(ink, 98) + percentile(ink, 5));
    };
    const double thr = threshold(clock), dthr = threshold(data);
    struct R { size_t start, len; bool on; };
    std::vector<R> runs;
    for (size_t i = 0; i < cols; ++i) {
        const bool on = clock[i] > thr;
        if (runs.empty() || runs.back().on != on) runs.push_back({i, 1, on});
        else ++runs.back().len;
    }
    for (size_t i = 0; i + 25 < runs.size(); ++i) {
        if (!runs[i].on) continue;
        double total = 0;
        for (size_t k = 0; k < 25; ++k) total += double(runs[i + k].len);
        const double mod = total / 31.0;
        if (std::fabs(runs[i].len - 5 * mod) > 1.3 * mod || std::fabs(runs[i + 24].len - 3 * mod) > 1.1 * mod) continue;
        bool regular = true;
        for (size_t k = 1; k < 24; ++k)
            regular = regular && runs[i + k].len >= 0.45 * mod && runs[i + k].len <= 1.7 * mod;
        if (!regular) continue;
        int bits[31];
        bool inside = true;
        for (int k = 0; k < 31; ++k) {
            const size_t c = size_t(double(runs[i].start) + (k + 0.5) * mod);
            inside = inside && c < cols;
            bits[k] = c < cols && data[c] > dthr ? 1 : 0;
        }
        if (!inside) continue;
        if (!(bits[0] == 1 && bits[1] == 0 && bits[2] == 1 && bits[3] == 0 && bits[4] == 1 && bits[28] == 1 &&
              bits[29] == 0 && bits[30] == 1)) continue;
        const int* d = bits + 5;
        const auto val = [&](int a, int n) { int v = 0; for (int k = 0; k < n; ++k) v = 2 * v + d[a + k]; return v; };
        int sum = 0;
        for (int k = 0; k < 21; ++k) sum += d[k];
        out.found = true;
        out.number = val(1, 7) * 16 + val(9, 4);
        out.frame = val(13, 6);
        out.half = d[19] != 0;
        out.parity = sum % 2 == d[21] && d[0] == 0 && d[8] == 0 && d[20] == 0 && d[22] == 0;
        return out;
    }
    return out;
}

// 8-bit BMP of a render, for looking at; only with an output directory.
void write_bmp(const std::string& path, const Img& im) {
    const uint32_t row = (im.w * 3 + 3) & ~3u, size = 54 + row * im.h;
    std::vector<unsigned char> b(size, 0);
    auto le32 = [&](size_t o, uint32_t v) { for (int k = 0; k < 4; ++k) b[o + size_t(k)] = (unsigned char)(v >> (8 * k)); };
    b[0] = 'B'; b[1] = 'M'; le32(2, size); le32(10, 54); le32(14, 40); le32(18, im.w); le32(22, im.h);
    b[26] = 1; b[28] = 24; le32(34, row * im.h);
    for (uint32_t y = 0; y < im.h; ++y)
        for (uint32_t x = 0; x < im.w; ++x)
            for (int c = 0; c < 3; ++c)
                b[54 + size_t(im.h - 1 - y) * row + x * 3 + size_t(2 - c)] = (unsigned char)(im.at(x, y)[c] >> 8);
    std::ofstream(path, std::ios::binary).write(reinterpret_cast<const char*>(b.data()), std::streamsize(b.size()));
}

// --- the cases ---------------------------------------------------------------
// Gate sizes and film widths are overscan.cpp's `kFormats`; the strip runs
// down the picture when the frame's width is the gate's size across the film.
struct Case {
    const char* name;
    const char* format;
    const char* stock;
    const char* edge_text;
    bool slide;          // scanned, not printed
    uint32_t w, h;       // the frame: the gate's shape, long edge 1200 px (6x6: 1000)
    bool vertical;       // the strip runs down the picture
    bool square_gate;    // gate = square; auto draws the format's own family
    double gate_long;    // the gate's long edge, mm: the plain render's film_format_mm
    double film_w;       // nominal film width, mm
    bool perforated;
    const char* camera;  // other bodies than seed 1: another perforation phase, gate offset and shape
};

const Case kCases[] = {
    {"135 Portra 400, strip across", "135", "kodak_portra_400", "KODAK PORTRA 400", false, 1200, 804, false, true, 36.25, 35.0, true, ""},
    {"135 X-Tra 400, camera turned (strip down)", "135", "fujifilm_xtra_400", "S-400", false, 804, 1200, true, true, 36.25, 35.0, true,
     ",\"overscan_camera_seed\":7"},
    {"135 half Provia 100F, held level (strip across)", "135_half", "fujifilm_provia_100f", "FUJI RDPIII", true, 900, 1200, false, true, 24.0, 35.0, true, ""},
    {"135 half Gold 200, camera turned (strip down)", "135_half", "kodak_gold_200", "KODAK GOLD 200", false, 1200, 900, true, true, 24.0, 35.0, true,
     ",\"overscan_camera_seed\":3"},
    {"XPan Vision3 250D", "135_xpan", "kodak_vision3_250d", "EASTMAN 5207 250D", false, 1200, 443, false, true, 65.0, 35.0, true,
     ",\"overscan_camera_seed\":12"},
    {"645 Pro 400H, landscape (strip down)", "120_645", "fujifilm_pro_400h", "FUJI PRO400H", false, 1200, 889, true, false, 56.0, 61.0, false, ""},
    {"6x6 Portra 400", "120_6x6", "kodak_portra_400", "KODAK PORTRA 400", false, 1000, 1000, false, false, 56.0, 61.0, false,
     ",\"overscan_camera_seed\":4"},
    {"6x7 Gold 200, portrait (strip down)", "120_6x7", "kodak_gold_200", "KODAK 200", false, 967, 1200, true, true, 69.5, 61.0, false, ""},
    {"6x7 Velvia 100, landscape", "120_6x7", "fujifilm_velvia_100", "FUJI RVP100", true, 1200, 967, false, true, 69.5, 61.0, false,
     ",\"overscan_camera_seed\":9"},
    {"6x9 Ektar 100", "120_6x9", "kodak_ektar_100", "KODAK EKTAR 100", false, 1200, 800, false, true, 84.0, 61.0, false, ""},
    {"6x12 Portra 160", "120_6x12", "kodak_portra_160", "KODAK PORTRA 160", false, 1200, 600, false, true, 112.0, 61.0, false, ""},
    {"6x17 Portra 800", "120_6x17", "kodak_portra_800", "KODAK PORTRA 800", false, 1200, 400, false, true, 168.0, 61.0, false, ""},
};
constexpr size_t kPortra135 = 0, kXtra = 1, kProvia = 2, kXpan = 4, k645 = 5, k6x6 = 6, k6x7 = 7, k6x9 = 9, k6x17 = 11;

std::string film_of(const Case& c, const char* print = "kodak_portra_endura") {
    return fmt("\"film_stock\":\"%s\",\"print_stock\":\"%s\",\"scan_film\":%s", c.stock, print, c.slide ? "true" : "false");
}
// The film edge without its text: the spool's fog off unless a check is about
// it (leaks are off by default).
std::string edge_of(const Case& c, const char* print = "kodak_portra_endura", int fog = 0) {
    return film_of(c, print) + fmt(",\"overscan_active\":true,\"overscan_format\":\"%s\",\"overscan_fog\":%d,\"overscan_gate\":\"%s\"",
                                   c.format, fog, c.square_gate ? "square" : "auto") + c.camera;
}
std::string text_of(const Case& c, const char* print = "kodak_portra_endura", int fog = 0) {
    return edge_of(c, print, fog) + ",\"overscan_edge_text\":\"" + c.edge_text + "\"";
}

// Largest picture difference allowed inside the gate, in codes of 65535.
// The frame is copied onto the canvas when the scan sits square and resampled
// bilinearly when it is tilted (up to 0.35 degrees), and the plain render is
// resampled here the same way after the print rather than before it. On an
// RTX 3070 that measured a maximum of 4-25 codes (25 on the Velvia slide) and
// a mean of 0.30-0.36 over every case; the bars are two and a half to three
// times that. A gate placed wrong by its own P slots (gate_along and
// gate_across swapped in overscan_params_block) measured a maximum of
// 23,805-37,993 codes, on every case but the square 6x6.
constexpr double kInteriorMax = 64.0, kInteriorMean = 1.0;

struct Rendered {
    Img on;
    Geometry g;
};

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) { std::cerr << "usage: spk_film_edge <resources> [bmp-dir]\n"; return 2; }
    const std::string dump = argc == 3 ? argv[2] : "";
    const auto started = std::chrono::steady_clock::now();
    try {
        Engine engine(spk_engine_create(argv[1], nullptr));
        if (!engine) fail(std::string("engine: ") + spk_last_error(nullptr));
        spk_engine* e = engine.get();
        const std::string caps = spk_capabilities(e);
        const size_t list = caps.find("\"unsupported_features\"");
        check(list != std::string::npos && caps.find("\"overscan\"", list) > caps.find(']', list),
              "capabilities do not list overscan as unsupported");

        std::vector<Rendered> done;
        for (const Case& c : kCases) {
            const std::string name = c.name;
            const Frame f = synthetic(c.w, c.h);
            const std::string with_text = text_of(c);
            Session s = open(e, f, with_text);
            check(!geometry(e, s.get()).valid, name + ": no geometry before the first render");
            Img on = render(e, s.get());
            const Geometry g = geometry(e, s.get());
            if (!dump.empty()) {
                std::string file = name;
                for (char& ch : file) if (!std::isalnum((unsigned char)ch)) ch = '_';
                write_bmp(dump + "/film_edge_" + file + ".bmp", on);
            }
            check(on.same(shot(e, f, with_text)), name + ": a fresh session renders the same bits");

            // The canvas the geometry reports.
            const bool shape = g.valid && g.gates.size() == 1 && g.format == c.format && g.vertical == c.vertical &&
                               on.w == g.cw && on.h == g.ch;
            check(shape, name + ": the render is the canvas the geometry reports", g.json.substr(0, 160));
            if (!shape) { done.push_back({on, g}); continue; }
            const uint32_t along_px = c.vertical ? on.h : on.w, across_px = c.vertical ? on.w : on.h;
            const uint32_t frame_along = c.vertical ? c.h : c.w, frame_across = c.vertical ? c.w : c.h;
            const double px = g.px;
            check(std::fabs(px - c.gate_long / std::max(c.w, c.h)) < 1e-6 &&
                      std::fabs(g.gate_along - frame_along * px) < 1e-3 && std::fabs(g.gate_across - frame_across * px) < 1e-3,
                  name + ": the frame is the gate, at the gate's own pitch",
                  fmt("%.5f mm/px, gate %.3f x %.3f mm", px, g.gate_along, g.gate_across));
            const double across_mm = across_px * px;
            const double margin = 0.5 * (along_px - frame_along) * px;
            const double m_lo = std::string(c.format) == "135_half" ? 0.40 : c.perforated ? 0.75 : 1.05;
            const double m_hi = std::string(c.format) == "135_half" ? 0.50 : c.perforated ? 0.95 : 2.35;
            check(std::fabs(across_mm - c.film_w) <= (c.perforated ? 0.0 : 0.15) + 0.5 * px + 0.01 && along_px > frame_along &&
                      margin >= m_lo - 0.5 * px - 0.01 && margin <= m_hi + 0.5 * px + 0.01,
                  name + ": the canvas is the film's width across, the frame and a part-gap each end along",
                  fmt("%u x %u px for a %u x %u frame: %.2f mm across, %.2f mm a part-gap", on.w, on.h, c.w, c.h, across_mm, margin));
            const GateFrame gf = gate_frame(g, 0);
            const double es = std::hypot(gf.sx, gf.sy) * px, et = std::hypot(gf.tx, gf.ty) * px;
            double xs[4], ys[4];
            gf.canvas(0, 0, xs[0], ys[0]); gf.canvas(gf.gw, 0, xs[1], ys[1]);
            gf.canvas(gf.gw, gf.gh, xs[2], ys[2]); gf.canvas(0, gf.gh, xs[3], ys[3]);
            bool inside = true;
            for (int k = 0; k < 4; ++k) inside = inside && xs[k] >= 0 && ys[k] >= 0 && xs[k] <= on.w && ys[k] <= on.h;
            // The gate's distance from the film's two edges -- the canvas's
            // long edges, with no carrier: centred to the camera's 0.1 mm on
            // 135 (0.45 on 120), plus the weave, the scan's offset and tilt.
            const double d_top = c.vertical ? (on.w - xs[0]) * px : ys[0] * px;
            const double d_bot = c.vertical ? xs[3] * px : (on.h - ys[3]) * px;
            const double nominal = 0.5 * (c.film_w - g.gate_across);
            check(std::fabs(es - 1.0) < 2e-3 && std::fabs(et - 1.0) < 2e-3 && std::fabs(gf.sx * gf.tx + gf.sy * gf.ty) * px * px < 1e-3 &&
                      inside && std::fabs(0.5 * (d_top + d_bot) - nominal) < 0.25 &&
                      std::fabs(d_top - nominal) < (c.perforated ? 0.45 : 0.85) &&
                      std::fabs(d_bot - nominal) < (c.perforated ? 0.45 : 0.85),
                  name + ": the gate is the frame's size, square, inside the canvas, centred across the film",
                  fmt("%.2f mm and %.2f mm from the film's edges (%.2f nominal), penumbra %.3f mm", d_top, d_bot, nominal, g.penumbra));

            // Inside the gate, the picture without film edge.
            const Img plain = shot(e, f, film_of(c) + fmt(",\"film_format_mm\":%g", c.gate_long));
            const double inset = (c.square_gate ? 0.5 : 1.8) + 3.0 * px;
            const Diff d = interior(on, g, 0, plain, inset);
            check(d.n > 1000 && d.max <= kInteriorMax && d.mean <= kInteriorMean,
                  name + ": inside the gate the picture is the render without film edge",
                  fmt("%zu px from %.2f mm in: max %.0f, mean %.2f codes", d.n, inset, d.max, d.mean));

            // The edge print is on the rebate: its text changes nothing in
            // the gate's span across the film.
            const Img bare = shot(e, f, edge_of(c));
            const std::vector<uint8_t> text = changed(on, bare);
            const Spread sp = spread(text, on.w, gf, -1e9, 1e9, 0.0, gf.gh);
            // On 135 the print's bands are the film's outer 2.2 mm each side
            // (names and numbers within 1.8 mm, the DX clock track from 2.17
            // mm), read here with the gate's 0.2 mm of camera centring and
            // weave and the unsharp mask's reach on top.
            size_t off_band = 0;
            if (c.perforated)
                for (size_t i = 0; i < text.size(); ++i) {
                    if (!text[i]) continue;
                    double s_, t_;
                    gf.film(double(i % on.w) + 0.5, double(i / on.w) + 0.5, s_, t_);
                    const double ta = t_ + nominal;
                    if (ta > 2.6 && ta < c.film_w - 2.6) ++off_band;
                }
            check(sp.n >= 200 && sp.inside == 0 && off_band == 0, name + ": the edge text prints on the rebate and nowhere else",
                  sp.str() + fmt(" from the gate's corner; %zu in the gate's span, %zu off the print's bands", sp.inside, off_band));

            if (c.perforated) {
                // The holes along each row's middle (2.0 + 1.4 mm from each edge).
                double s_lo, s_hi;
                along_extent(on, gf, s_lo, s_hi);
                std::vector<Run> rows[2];
                rows[0] = runs_on(on, gf, px, true, 3.4 - nominal, s_lo, s_hi);
                rows[1] = runs_on(on, gf, px, true, c.film_w - 3.4 - nominal, s_lo, s_hi);
                const size_t want = size_t(std::max(0.0, std::floor((s_hi - s_lo) / 4.75) - 1.0));
                bool widths = true, pitch = true, phase = true, paired = true;
                double w_lo = 9, w_hi = 0, p_lo = 9, p_hi = 0, ph_lo = 9, ph_hi = -9;
                for (int r = 0; r < 2; ++r)
                    for (size_t k = 0; k < rows[r].size(); ++k) {
                        const Run& h = rows[r][k];
                        const double wd = h.b - h.a;
                        w_lo = std::min(w_lo, wd); w_hi = std::max(w_hi, wd);
                        widths = widths && wd >= 1.85 && wd <= 2.10;
                        if (k) {
                            const double p = h.a - rows[r][k - 1].a;
                            p_lo = std::min(p_lo, p); p_hi = std::max(p_hi, p);
                            pitch = pitch && p >= 4.68 && p <= 4.82;
                        }
                        // overscan.cpp holds the camera's perforation phase to
                        // -4.1..-2.6 mm of the gate's start, so the edge print
                        // falls inside the frame: a hole's leading edge is
                        // 0.65-2.15 mm past a multiple of the pitch.
                        const double m = std::fmod(std::fmod(h.a, 4.75) + 4.75, 4.75);
                        ph_lo = std::min(ph_lo, m); ph_hi = std::max(ph_hi, m);
                        phase = phase && m >= 0.55 && m <= 2.25;
                        // Both rows in step: every hole of the row with fewer
                        // whole holes (the scan's tilt can cut one row's last
                        // hole at the canvas's end) has its twin across the film.
                        const int few = rows[0].size() <= rows[1].size() ? 0 : 1;
                        if (r == few) {
                            bool twin = false;
                            for (const Run& o : rows[1 - few]) twin = twin || std::fabs(o.a - h.a) < 0.1;
                            paired = paired && twin;
                        }
                    }
                check(rows[0].size() >= want && rows[1].size() >= want && widths && pitch && phase && paired,
                      name + ": perforations every 4.75 mm, 1.98 mm long, both rows in step, on the camera's phase",
                      fmt("%zu + %zu holes (>= %zu), %.3f-%.3f mm long, pitch %.3f-%.3f, leading edges %.2f-%.2f mm past the pitch",
                          rows[0].size(), rows[1].size(), want, w_lo, w_hi, p_lo, p_hi, ph_lo, ph_hi));
                if (!rows[0].empty()) {
                    const Run& h = rows[0][0];
                    const double sc = 0.5 * (h.a + h.b);
                    const std::vector<Run> across = runs_on(on, gf, px, false, sc, 0.3 - nominal, 6.0 - nominal);
                    double x, y;
                    gf.canvas(sc, 3.4 - nominal, x, y);
                    const uint16_t* p = on.at(uint32_t(x), uint32_t(y));
                    const double lit = std::min({double(p[0]), double(p[1]), double(p[2])});
                    check(across.size() == 1 && std::fabs(across[0].a + nominal - 2.0) < 0.25 &&
                              std::fabs(across[0].b + nominal - 4.8) < 0.25 && lit > 0.9 * kWhite,
                          name + ": a hole is 2.80 mm across from 2.00 mm in, and the scan's light shows through it",
                          across.size() == 1 ? fmt("%.2f..%.2f mm from the edge, its middle %.0f of 65535",
                                                   across[0].a + nominal, across[0].b + nominal, lit)
                                             : fmt("%zu stretches", across.size()));
                }
            } else {
                // 120 has no holes: nowhere off the picture is the scan's
                // white (a hole's light is 65535 in every channel; the
                // brightest edge print, a slide's, is not white).
                size_t lit = 0;
                double brightest = 0;
                for (uint32_t y = 0; y < on.h; ++y)
                    for (uint32_t x = 0; x < on.w; ++x) {
                        double s_, t_;
                        gf.film(x + 0.5, y + 0.5, s_, t_);
                        if (s_ > -0.3 && s_ < gf.gw + 0.3 && t_ > -0.3 && t_ < gf.gh + 0.3) continue;
                        const uint16_t* p = on.at(x, y);
                        const double m = std::min({double(p[0]), double(p[1]), double(p[2])});
                        brightest = std::max(brightest, m);
                        if (m > 0.97 * kWhite) ++lit;
                    }
                check(lit == 0, name + ": no light through the film off the picture (120 is not perforated)",
                      fmt("%zu px; the brightest off the picture %.0f of 65535 in its dimmest channel", lit, brightest));
            }
            done.push_back({on, g});
        }

        // --- 135 Portra: seeds, fog, the holes' black, the DX code, the date ----
        {
            const Case& c = kCases[kPortra135];
            const Frame f = synthetic(c.w, c.h);
            const std::string P = text_of(c);
            const Img& on = done[kPortra135].on;
            const Geometry& g = done[kPortra135].g;
            const GateFrame gf = gate_frame(g, 0);
            const double nominal = 0.5 * (c.film_w - g.gate_across);
            {
                Session s = open(e, f, P);
                const Img a = render(e, s.get()), b = render(e, s.get());
                check(a.same(b) && a.same(on), "135: a session renders the same bits twice");
            }
            check(!on.same(shot(e, f, P + ",\"overscan_frame_seed\":2")), "135: another frame seed moves the film");

            // Fog from the spool lifts the film's edges; what reaches the
            // picture's middle, 11 mm and more in, is the tail of its decay.
            const Img fog = shot(e, f, text_of(c, "kodak_portra_endura", 1));
            double edge_sum = 0, mid_sum = 0;
            size_t edge_n = 0, mid_n = 0;
            for (uint32_t y = 0; y < on.h; ++y)
                for (uint32_t x = 0; x < on.w; ++x) {
                    double s_, t_;
                    gf.film(x + 0.5, y + 0.5, s_, t_);
                    const double ta = t_ + nominal, dd = std::fabs(on.lum(x, y) - fog.lum(x, y));
                    if (ta < 0.6 || ta > c.film_w - 0.6) { edge_sum += dd; ++edge_n; }
                    else if (s_ > 0.25 * gf.gw && s_ < 0.75 * gf.gw && t_ > 0.25 * gf.gh && t_ < 0.75 * gf.gh) { mid_sum += dd; ++mid_n; }
                }
            const double fog_edge = edge_n ? edge_sum / edge_n : 0, fog_mid = mid_n ? mid_sum / mid_n : 0;
            check(fog_edge > 200.0 && fog_edge > 20.0 * fog_mid, "135: edge fog lifts the film's outer 0.6 mm, not the picture",
                  fmt("mean change %.0f codes at the edges, %.2f in the picture's middle", fog_edge, fog_mid));

            // Black holes: dark, and darker than the rebate around them.
            const Img black = shot(e, f, P + ",\"overscan_holes\":\"black\"");
            double s_lo, s_hi;
            along_extent(on, gf, s_lo, s_hi);
            const std::vector<Run> holes = runs_on(on, gf, g.px, true, 3.4 - nominal, s_lo, s_hi);
            std::vector<double> band, inner, rebate;
            for (uint32_t y = 0; y < black.h; ++y)
                for (uint32_t x = 0; x < black.w; ++x) {
                    double s_, t_;
                    gf.film(x + 0.5, y + 0.5, s_, t_);
                    const double ta = t_ + nominal;
                    if (ta < 2.3 || ta > 4.5) continue;
                    band.push_back(black.lum(x, y));
                    bool in_hole = false, near_hole = false;
                    for (const Run& h : holes) {
                        in_hole = in_hole || (s_ > h.a + 0.3 && s_ < h.b - 0.3);
                        near_hole = near_hole || (s_ > h.a - 0.4 && s_ < h.b + 0.4);
                    }
                    if (in_hole && ta > 2.6 && ta < 4.2) inner.push_back(black.lum(x, y));
                    if (!near_hole) rebate.push_back(black.lum(x, y));
                }
            const double hi99 = percentile(band, 99), hole_lum = percentile(inner, 50), reb = percentile(rebate, 50);
            check(!holes.empty() && hi99 < 0.25 * kWhite && hole_lum < 0.5 * reb,
                  "135: holes = black leaves them dark, darker than the rebate",
                  fmt("the band's 99th percentile %.0f, a hole %.0f against the rebate %.0f", hi99, hole_lum, reb));

            uint32_t rows = 0, cols = 0;
            const std::vector<double> L = film_lum(on, false, rows, cols);
            const Dx dx = decode_dx(L, rows, cols, g.px);
            check(dx.found && dx.number == 1277 && dx.parity, "135: the DX code reads back as Portra 400's (1277), parity good",
                  dx.found ? fmt("%d, frame %d%s, parity %s", dx.number, dx.frame, dx.half ? "A" : "", dx.parity ? "good" : "bad")
                           : std::string("no code found"));

            // The date in the picture; the shooting data between the frames as
            // well, at the same time, without moving the date.
            const std::string D = P + ",\"date_imprint_active\":true,\"date_imprint_text\":\"'26 10 4\"";
            const std::vector<uint8_t> d_only = changed(shot(e, f, D), on);
            const std::vector<uint8_t> d_both = changed(shot(e, f, D + ",\"date_imprint_data_text\":\"1/125 F2.8 A 50mm\""), on);
            // overscan.cpp: lower right of the film's frame, 3.0 mm in from the
            // side and 2.4 from the bottom, 1.3 mm tall, "'26 10 4" 6.5 mm long.
            const Spread so = spread(d_only, on.w, gf, gf.gw - 3.0 - 6.5 - 1.0, gf.gw - 3.0 + 1.0, gf.gh - 2.4 - 1.3 - 1.0, gf.gh - 2.4 + 1.0);
            size_t moved = 0, before_frame = 0, elsewhere = 0;
            for (size_t i = 0; i < d_both.size(); ++i) {
                double s_, t_;
                gf.film(double(i % on.w) + 0.5, double(i / on.w) + 0.5, s_, t_);
                const bool in_gate = s_ >= 0 && s_ <= gf.gw && t_ >= 0 && t_ <= gf.gh;
                if (in_gate && d_both[i] != d_only[i]) ++moved;
                if (d_both[i] && !in_gate) { if (s_ < 0.05) ++before_frame; else ++elsewhere; }
            }
            check(so.n > 200 && so.inside == so.n, "135: the date prints in the picture's lower right", so.str());
            check(moved == 0 && before_frame > 60 && elsewhere == 0,
                  "135: with the data asked for, the date stays and the data prints in the gap before the frame",
                  fmt("%zu date pixels moved, %zu data pixels before the frame, %zu elsewhere", moved, before_frame, elsewhere));
        }

        // --- the DX code on other stocks and the strip turned ----------------
        {
            const Rendered& r = done[kXtra];
            uint32_t rows = 0, cols = 0;
            const std::vector<double> L = film_lum(r.on, r.g.vertical, rows, cols);
            const Dx dx = decode_dx(L, rows, cols, r.g.px);
            check(dx.found && dx.number == 628 && dx.parity,
                  "135 turned: X-Tra 400's own, longer DX code reads back along the strip (628)",
                  dx.found ? fmt("%d, frame %d, parity %s", dx.number, dx.frame, dx.parity ? "good" : "bad") : std::string("no code found"));
            const Rendered& v = done[kXpan];
            const std::vector<double> V = film_lum(v.on, v.g.vertical, rows, cols);
            check(!decode_dx(V, rows, cols, v.g.px).found, "XPan: a cine stock carries no DX code, and the reader finds none");
        }

        // --- black and white: Tri-X has an edge look of its own (Kodak's
        // layout, one emulsion, no DX bars), but its profile lives in
        // engine/resources_product, which the Windows build does not stage.
        // Said, not skipped quietly: when it is staged this checks it.
        {
            const Case c{"135 Tri-X 400", "135", "kodak_tri_x_400", "KODAK 400TX", false, 1200, 804, false, true, 36.25, 35.0, true, ""};
            const Frame f = synthetic(c.w, c.h);
            const std::string delta = delta_of(text_of(c, "kodak_portra_endura"));
            const spk_image img{f.rgb.data(), f.w, f.h, 3};
            Session s(spk_open(e, &img, delta.c_str(), nullptr));
            if (!s) {
                std::cout << "NOTE not checked: black and white edge print (" << c.stock << " is not in this build's catalogue: "
                          << std::string(spk_last_error(e)).substr(0, 90) << ")\n";
            } else {
                const Img bw = render(e, s.get());
                const Geometry g = geometry(e, s.get());
                uint32_t rows = 0, cols = 0;
                const std::vector<double> L = film_lum(bw, g.vertical, rows, cols);
                const Spread sp = spread(changed(bw, shot(e, f, edge_of(c))), bw.w, gate_frame(g, 0), -1e9, 1e9, 0.0, g.gate_across);
                check(g.valid && sp.n >= 200 && sp.inside == 0 && !decode_dx(L, rows, cols, g.px).found,
                      "135 Tri-X: the edge text prints on the rebate, and no DX code", sp.str());
            }
        }

        // --- the frame number: 0 is the seed's draw; 7 and 8 differ, on the rebate
        for (size_t idx : {kPortra135, kProvia, k6x7, k645}) {
            const Case& c = kCases[idx];
            const Frame f = synthetic(c.w, c.h);
            const std::string P = text_of(c);
            const Img n0 = shot(e, f, P + ",\"overscan_frame_number\":0");
            const Img n7 = shot(e, f, P + ",\"overscan_frame_number\":7");
            const Img n8 = shot(e, f, P + ",\"overscan_frame_number\":8");
            const GateFrame gf = gate_frame(done[idx].g, 0);
            const Spread sp = spread(changed(n7, n8), n7.w, gf, -1e9, 1e9, 0.0, gf.gh);
            check(n0.same(done[idx].on) && !n7.same(done[idx].on) && sp.n > 50 && sp.inside == 0,
                  std::string(c.name) + ": frame number 0 is the seeded draw; 7 and 8 differ, on the rebate only",
                  sp.str() + fmt(", %zu in the gate's span", sp.inside));
        }

        // --- the date back on 120: in the margin beside the frame, the data beside it
        for (size_t idx : {k645, k6x6, k6x7, k6x9}) {
            const Case& c = kCases[idx];
            const Frame f = synthetic(c.w, c.h);
            const std::string D = text_of(c) + ",\"date_imprint_active\":true,\"date_imprint_text\":\"'26 10 4\"";
            const Img& base = done[idx].on;
            const GateFrame gf = gate_frame(done[idx].g, 0);
            const std::vector<uint8_t> dd = changed(shot(e, f, D), base);
            const std::vector<uint8_t> both = changed(shot(e, f, D + ",\"date_imprint_data_text\":\"1/125 F2.8 A 50mm\""), base);
            // overscan.cpp: one line 0.55 mm tall, 0.30 mm past the gate's t+
            // side; the date ends at 0.92 of the gate, the data starts at 0.08.
            const double t0 = gf.gh + 0.1, t1 = gf.gh + 1.2;
            const Spread sd = spread(dd, base.w, gf, 0.45 * gf.gw, gf.gw + 0.1, t0, t1);
            std::vector<uint8_t> extra(both.size(), 0);
            size_t lost = 0;
            for (size_t i = 0; i < both.size(); ++i) {
                if (dd[i] && !both[i]) ++lost;
                extra[i] = both[i] && !dd[i];
            }
            const Spread sx = spread(extra, base.w, gf, -0.1, 0.55 * gf.gw, t0, t1);
            check(sd.n > 40 && sd.inside == sd.n, std::string(c.name) + ": the date prints in the margin beside the frame's far end",
                  sd.str());
            check(lost == 0 && sx.n > 60 && sx.inside == sx.n,
                  std::string(c.name) + ": the shooting data prints beside it, from the frame's near end, without moving the date",
                  sx.str() + fmt(", %zu date pixels lost", lost));
        }

        // --- the long formats: the carrier, and no date -------------------------
        for (size_t idx : {kXpan, k6x17}) {
            const Case& c = kCases[idx];
            const Frame f = synthetic(c.w, c.h);
            const std::string P = text_of(c);
            const Img& r0 = done[idx].on;
            const double px = done[idx].g.px;
            std::vector<double> top, bottom;
            for (uint32_t x = 0; x < r0.w; ++x) { top.push_back(r0.lum(x, 0)); bottom.push_back(r0.lum(x, r0.h - 1)); }
            check(percentile(top, 50) > 0.02 * kWhite && percentile(bottom, 50) > 0.02 * kWhite,
                  std::string(c.name) + ": the canvas's long edges are film, not a black band",
                  fmt("medians %.0f, %.0f", percentile(top, 50), percentile(bottom, 50)));
            const Img black = shot(e, f, P + ",\"overscan_carrier\":\"black\"");
            const Img open_ = shot(e, f, P + ",\"overscan_carrier\":\"open\"");
            double b_max = 0, o_min = kWhite;
            for (uint32_t x = 0; x < black.w; ++x) {
                b_max = std::max({b_max, black.lum(x, 0), black.lum(x, black.h - 1)});
                o_min = std::min({o_min, open_.lum(x, 0), open_.lum(x, open_.h - 1)});
            }
            const double across = black.h * px;
            // The film, 1.5 mm in from both long edges, is the carrier's
            // business only through spk_overscan_light's final
            // mix(carrier, film, on_strip): at on_strip = 1 that is
            // carrier + (film - carrier), and with the open carrier's 1.0 the
            // subtraction drops a low bit of a dark value. Measured on XPan:
            // 94 pixels, all on the holes' soft outer edges where the values
            // vary continuously, differ by exactly 1 code; none on 6x17's
            // unperforated, flat rebate. Hence one code, not zero.
            const uint32_t in = uint32_t(1.5 / px);
            int film_worst = 0;
            size_t film_n = 0;
            for (uint32_t y = in; y + in < black.h && black.w == open_.w && black.h == open_.h; ++y)
                for (uint32_t x = 0; x < black.w; ++x) {
                    int d = 0;
                    for (int k = 0; k < 3; ++k) d = std::max(d, std::abs(int(black.at(x, y)[k]) - int(open_.at(x, y)[k])));
                    film_worst = std::max(film_worst, d);
                    film_n += d > 0;
                }
            check(across > c.film_w + 0.5 && across < c.film_w + 1.0 && b_max < 0.02 * kWhite && o_min > 0.9 * kWhite &&
                      black.w == open_.w && black.h == open_.h && film_worst <= 1,
                  std::string(c.name) + ": a carrier shows black, or the scan's light, past both long edges and changes no film",
                  fmt("%.2f mm across, black rows at most %.0f, open rows at least %.0f; on the film %zu px differ, by at most %d code",
                      across, b_max, o_min, film_n, film_worst));
            check(shot(e, f, P + ",\"date_imprint_active\":true,\"date_imprint_text\":\"'26 10 1\"").same(r0),
                  std::string(c.name) + ": the panoramic formats carry no date");
        }

        // --- a half-frame pair: two exposures of one gate on one strip --------
        {
            const uint32_t hw = 450, hh = 600, adv = uint32_t(std::lround(19.0 / (18.0 / hw)));
            Frame both{adv + hw, hh, std::vector<float>(size_t(adv + hw) * hh * 3, 0.0f)};
            const Frame left = synthetic(hw, hh), right = synthetic(hw, hh, 0.6f);
            for (uint32_t y = 0; y < hh; ++y) {
                std::copy_n(&left.rgb[size_t(y) * hw * 3], hw * 3, &both.rgb[size_t(y) * both.w * 3]);
                std::copy_n(&right.rgb[size_t(y) * hw * 3], hw * 3, &both.rgb[(size_t(y) * both.w + adv) * 3]);
            }
            const Case& c = kCases[kPortra135];
            const std::string PAIR = film_of(c) + ",\"overscan_active\":true,\"overscan_format\":\"135_half\",\"overscan_pair\":true,"
                                                  "\"overscan_fog\":0,\"overscan_gate\":\"square\",\"overscan_edge_text\":\"KODAK PORTRA 400\"";
            Session s = open(e, both, PAIR);
            const Img pr = render(e, s.get());
            const Geometry pg = geometry(e, s.get());
            if (!dump.empty()) write_bmp(dump + "/film_edge_pair.bmp", pr);
            const bool two = pg.valid && pg.gates.size() == 2 && pr.w == pg.cw && pr.h == pg.ch && !pg.vertical;
            check(two, "pair: one strip with two gates", pg.json.substr(0, 160));
            if (two) {
                const GateFrame g0 = gate_frame(pg, 0), g1 = gate_frame(pg, 1);
                const double w0 = std::hypot(g0.sx, g0.sy) * g0.gw, h0 = std::hypot(g0.tx, g0.ty) * g0.gh;
                const double w1 = std::hypot(g1.sx, g1.sy) * g1.gw, h1 = std::hypot(g1.tx, g1.ty) * g1.gh;
                const double step = std::hypot(g1.ox - g0.ox, g1.oy - g0.oy);
                check(std::fabs(w0 - hw) < 2 && std::fabs(w1 - hw) < 2 && std::fabs(h0 - hh) < 2 && std::fabs(h1 - hh) < 2 &&
                          std::fabs(step - adv) < 2,
                      "pair: each gate is one half frame, one advance (19 mm) apart",
                      fmt("gates %.1f x %.1f and %.1f x %.1f px, %.1f px apart for %u", w0, h0, w1, h1, step, adv));
                // The gap between them is film no light reached.
                std::vector<double> gap, pic;
                for (double t = 1.0; t < g0.gh - 1.0; t += pg.px) {
                    double x, y;
                    g0.canvas(0.5 * (g0.gw + 19.0), t, x, y);
                    gap.push_back(lum_at(pr, x, y));
                    g0.canvas(0.5 * g0.gw, t, x, y);
                    pic.push_back(lum_at(pr, x, y));
                }
                const double gap_m = percentile(gap, 50), pic_m = percentile(pic, 50);
                check(gap_m < 0.35 * pic_m, "pair: the gap between the frames is unexposed film",
                      fmt("gap %.0f, picture %.0f", gap_m, pic_m));
                const Img plain = shot(e, both, film_of(c) + ",\"film_format_mm\":37");
                const Diff d0 = interior(pr, pg, 0, plain, 0.5 + 3 * pg.px), d1 = interior(pr, pg, 1, plain, 0.5 + 3 * pg.px);
                check(d0.max <= kInteriorMax && d1.max <= kInteriorMax && d0.mean <= kInteriorMean && d1.mean <= kInteriorMean &&
                          d0.n > 1000 && d1.n > 1000,
                      "pair: each gate holds its own picture, the second from the frame's second half",
                      fmt("max %.0f / %.0f, mean %.2f / %.2f codes", d0.max, d1.max, d0.mean, d1.mean));
                // The second frame's own Scene Placement (the latitude's second
                // pair, split in the middle of the gap) changes the second
                // picture only.
                const double split = (adv - 0.5 * (adv - hw)) / double(adv + hw);
                const Img second = shot(e, both, PAIR + fmt(",\"scene_latitude_split\":%.9g,\"scene_latitude_b_active\":true,"
                                                            "\"scene_latitude_b_highlight_knee\":0.5,\"scene_latitude_b_highlight_room\":1.0,"
                                                            "\"scene_latitude_b_shadow_knee\":-0.5,\"scene_latitude_b_shadow_room\":1.0",
                                                            split));
                const Diff a0 = gate_diff(second, pr, pg, 0, 0.5), a1 = gate_diff(second, pr, pg, 1, 0.5);
                check(a0.max <= 8 && a1.max > 500, "pair: the second frame's Scene Placement changes the second picture only",
                      fmt("first picture max %.0f codes, second %.0f", a0.max, a1.max));
                // ... and its own date, in its own gate.
                const std::string DP = PAIR + ",\"date_imprint_active\":true,\"date_imprint_text\":\"'26 10 1\"";
                const std::vector<uint8_t> dd = changed(shot(e, both, DP + ",\"date_imprint_text_b\":\"'26 10 3\""), shot(e, both, DP));
                const Spread sb = spread(dd, pr.w, g1, 0, g1.gw, 0, g1.gh);
                check(sb.n > 30 && sb.inside == sb.n, "pair: the second frame carries its own date, in its own gate",
                      sb.str() + " from the second gate's corner");
            }
            // The camera turned: the film runs down the picture, the first frame at the top.
            {
                Session t = open(e, transposed(both), PAIR);
                const Img tr = render(e, t.get());
                const Geometry tg = geometry(e, t.get());
                const bool ok = tg.valid && tg.vertical && tg.gates.size() == 2 && tr.w == tg.cw && tr.h == tg.ch;
                double step = 0, gap_m = 0, pic_m = 1;
                if (ok) {
                    const GateFrame g0 = gate_frame(tg, 0), g1 = gate_frame(tg, 1);
                    step = g1.oy - g0.oy;
                    std::vector<double> gap, pic;
                    for (double tt = 1.0; tt < g0.gh - 1.0; tt += tg.px) {
                        double x, y;
                        g0.canvas(0.5 * (g0.gw + 19.0), tt, x, y);
                        gap.push_back(lum_at(tr, x, y));
                        g0.canvas(0.5 * g0.gw, tt, x, y);
                        pic.push_back(lum_at(tr, x, y));
                    }
                    gap_m = percentile(gap, 50);
                    pic_m = percentile(pic, 50);
                }
                check(ok && std::fabs(step - adv) < 2 && gap_m < 0.35 * pic_m,
                      "pair, camera turned: two gates one above the other, the gap between them unexposed",
                      fmt("the second %.1f px below the first (advance %u), gap %.0f against %.0f", step, adv, gap_m, pic_m));
            }
            const std::string err = refusal(e, both, PAIR.substr(0, PAIR.find("135_half")) + "135" +
                                                      PAIR.substr(PAIR.find("135_half") + 8));
            check(err.find("135_half") != std::string::npos, "a pair on another format is refused", err.substr(0, 100));
        }

        // --- reprints of a film canvas --------------------------------------
        // Larger than the live tier (preview_long_edge 800), so the tiers'
        // canvases differ; each reprint against a fresh session's render.
        {
            const Case& c = kCases[kPortra135];
            const Frame f = synthetic(c.w, c.h);
            const std::string P = text_of(c) + ",\"preview_long_edge\":800";
            Session s = open(e, f, P);
            const Img live = render(e, s.get(), "live");
            const Img full = render(e, s.get(), "full");
            check(live.w < full.w && full.same(done[kPortra135].on), "reprint: the live canvas is the smaller one",
                  fmt("live %u x %u, full %u x %u", live.w, live.h, full.w, full.h));
            const Img r1 = render(e, s.get(), "live", true);
            check(r1.negative_cached == 1 && r1.same(live), "reprint: the live tier reprints its cached negative after the full tier");
            const std::string pe = ",\"print_exposure\":0.7";
            if (spk_set_params(s.get(), "{\"print_exposure\":0.7}", nullptr) != SPK_OK) fail(spk_last_error(e));
            const Img r2 = render(e, s.get(), "live", true), r3 = render(e, s.get(), "full", true);
            check(r2.negative_cached == 1 && r3.negative_cached == 1 && r2.same(shot(e, f, P + pe, "live")) &&
                      r3.same(shot(e, f, P + pe)),
                  "reprint: a print edit reprints both tiers from their cached negatives, as a fresh session renders them");
            if (spk_set_params(s.get(), "{\"print_stock\":\"kodak_supra_endura\"}", nullptr) != SPK_OK) fail(spk_last_error(e));
            const Img r4 = render(e, s.get(), "full", true);
            check(r4.negative_cached == 1 && r4.same(shot(e, f, text_of(c, "kodak_supra_endura") + ",\"preview_long_edge\":800" + pe)),
                  "reprint: after a print stock change has rebuilt the pipeline, still from the cached negative");
            char* reply = nullptr;
            if (spk_set_params(s.get(), "{\"overscan_frame_number\":5}", &reply) != SPK_OK) fail(spk_last_error(e));
            const std::string invalidated = reply ? reply : "";
            spk_string_free(reply);
            const Img r5 = render(e, s.get(), "full", true);
            check(invalidated.find("\"invalidated\":\"shoot\"") != std::string::npos && r5.negative_cached == 0 &&
                      r5.same(shot(e, f, text_of(c, "kodak_supra_endura") + ",\"preview_long_edge\":800" + pe +
                                             ",\"overscan_frame_number\":5")),
                  "reprint: a film edge edit re-develops the negative (it is exposure on the film)");
        }

        // --- what overscan refuses, by name --------------------------------------
        {
            const Case& c = kCases[kPortra135];
            const Frame f = synthetic(c.w, c.h);
            const std::string P = text_of(c);
            // RFC-032 §27: the striped executor does not lay out a canvas, so
            // striped and whole-frame cannot be compared -- it must refuse.
            std::string err = refusal(e, f, P + ",\"striped\":true");
            check(err.find("striped") != std::string::npos, "the striped executor refuses overscan", err.substr(0, 100));
            const std::string FE = film_of(c) + ",\"overscan_active\":true";
            err = refusal(e, f, FE + ",\"overscan_format\":\"110\"");
            check(err.find("format") != std::string::npos, "an unknown format is refused", err.substr(0, 100));
            err = refusal(e, synthetic(1800, 600), FE);
            check(err.find("gate's shape") != std::string::npos, "a frame that is not the gate's shape is refused", err.substr(0, 100));
            for (const char* bad : {"\"overscan_gate\":\"hexagon\"", "\"overscan_holes\":\"light\"", "\"overscan_carrier\":\"grey\""}) {
                err = refusal(e, f, FE + "," + bad);
                const std::string word = std::string(bad).substr(std::string(bad).find(":\"") + 2,
                                                                 std::string(bad).size() - std::string(bad).find(":\"") - 3);
                check(err.find(word) != std::string::npos, std::string("an unknown value is refused: ") + bad, err.substr(0, 100));
            }
            Session off = open(e, f, film_of(c));
            render(e, off.get());
            check(!geometry(e, off.get()).valid, "no geometry with overscan off");
        }

        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
        std::cout << "film edge: " << g_checks << " checks, " << g_failures << " failed, " << fmt("%.1f s", secs) << '\n';
        return g_failures ? 1 : 0;
    } catch (const std::exception& error) {
        std::cerr << "film edge: " << error.what() << '\n';
        return 1;
    }
}
