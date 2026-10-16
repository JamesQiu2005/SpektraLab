// The portable imprint raster (src/pipeline/edge_raster.hpp and
// overscan_raster_portable.cpp) against references that share none of its
// code. CPU only: no Vulkan device is opened.
//
//   filler     every pixel of convex shapes against a Sutherland-Hodgman clip
//              of the shape to the pixel square and its shoelace area; the
//              nonzero rule against shapes cut into disjoint convex pieces
//   circle     the polygon's area against pi r^2, and every pixel against the
//              exact circle-square area to within the flattening tolerance
//   composite  CGBitmapContext's 8-bit source-over, by hand
//   blur       a direct 2-D double convolution with clamped indices, and
//              bit-identity across thread counts
//   text       Kodak-style lines in the bundled TeX Gyre Heros: widths
//              against strip measurements, cap height and ink area through
//              the real `imprint::rasterise`, and a clear refusal without
//              the font
#include "pipeline/edge_raster.hpp"
#include "pipeline/overscan_raster.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace spk;
using edge_raster::Affine;
using edge_raster::Coverage;
using edge_raster::Path;

int checks = 0;
double worst_filler = 0.0;

void require(bool ok, const std::string& what) {
    if (!ok) throw std::runtime_error(what);
    ++checks;
}

// For a call that reports through error: taken by reference, so it is read
// after the call has run (a message built in the argument list may be built
// before it -- the order of evaluation is unspecified).
void require_call(bool ok, const std::string& what, const std::string& error) {
    if (!ok) throw std::runtime_error(what + ": " + error);
    ++checks;
}

struct P2 { double x, y; };
using Poly = std::vector<P2>;

// Sutherland-Hodgman: a convex polygon clipped to one half-plane.
Poly clip(const Poly& in, int axis, double bound, bool keep_below) {
    Poly out;
    auto inside = [&](const P2& p) { const double v = axis ? p.y : p.x; return keep_below ? v <= bound : v >= bound; };
    for (size_t i = 0; i < in.size(); ++i) {
        const P2& a = in[i];
        const P2& b = in[(i + 1) % in.size()];
        const bool ia = inside(a), ib = inside(b);
        if (ia) out.push_back(a);
        if (ia != ib) {
            const double va = axis ? a.y : a.x, vb = axis ? b.y : b.x, t = (bound - va) / (vb - va);
            out.push_back({a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)});
        }
    }
    return out;
}

double area(const Poly& p) {
    double s = 0.0;
    for (size_t i = 0; i < p.size(); ++i) {
        const P2& a = p[i];
        const P2& b = p[(i + 1) % p.size()];
        s += a.x * b.y - b.x * a.y;
    }
    return 0.5 * s;
}

double area_in_pixel(const Poly& convex, int i, int j) {
    Poly p = clip(convex, 0, double(i), false);
    p = clip(p, 0, double(i + 1), true);
    p = clip(p, 1, double(j), false);
    p = clip(p, 1, double(j + 1), true);
    return p.size() < 3 ? 0.0 : std::fabs(area(p));
}

// The intersection of two convex polygons (clip one by each edge of the other).
Poly intersect(const Poly& a, const Poly& b) {
    Poly out = a;
    const double orient = area(b) > 0 ? 1.0 : -1.0;
    for (size_t i = 0; i < b.size() && out.size() >= 3; ++i) {
        const P2 p = b[i], q = b[(i + 1) % b.size()];
        Poly next;
        auto side = [&](const P2& r) { return orient * ((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)); };
        for (size_t k = 0; k < out.size(); ++k) {
            const P2 u = out[k], v = out[(k + 1) % out.size()];
            const double su = side(u), sv = side(v);
            if (su >= 0) next.push_back(u);
            if ((su >= 0) != (sv >= 0)) {
                const double t = su / (su - sv);
                next.push_back({u.x + t * (v.x - u.x), u.y + t * (v.y - u.y)});
            }
        }
        out = next;
    }
    return out;
}

Path path_of(const std::vector<Poly>& contours) {
    Path p;
    for (const Poly& c : contours) {
        for (size_t k = 0; k < c.size(); ++k) {
            if (k == 0) p.move_to(c[k].x, c[k].y); else p.line_to(c[k].x, c[k].y);
        }
        p.close();
    }
    return p;
}

double at(const Coverage& c, int i, int j) {
    if (i < c.x0 || j < c.y0 || i >= c.x0 + c.w || j >= c.y0 + c.h) return 0.0;
    return c.a[size_t(j - c.y0) * size_t(c.w) + size_t(i - c.x0)];
}

// Every pixel of a grid against `expected(i, j)`.
void compare_pixels(const Coverage& c, int gw, int gh, double tol, const std::string& name,
                    const std::function<double(int, int)>& expected) {
    double worst = 0.0, sum_got = 0.0, sum_ref = 0.0;
    for (int j = 0; j < gh; ++j)
        for (int i = 0; i < gw; ++i) {
            const double got = at(c, i, j), ref = std::clamp(expected(i, j), 0.0, 1.0);
            worst = std::max(worst, std::fabs(got - ref));
            sum_got += got; sum_ref += ref;
        }
    worst_filler = std::max(worst_filler, worst);
    char buf[256];
    std::snprintf(buf, sizeof buf, "%s: worst pixel error %.3g (bound %.3g), area %.12g vs %.12g", name.c_str(), worst,
                  tol, sum_got, sum_ref);
    require(worst <= tol, buf);
}

Poly rect(double x0, double y0, double x1, double y1) { return {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}}; }

Poly rotated_rect(double cx, double cy, double w, double h, double deg) {
    const double r = deg * M_PI / 180.0, c = std::cos(r), s = std::sin(r);
    const double us[4] = {-w / 2, w / 2, w / 2, -w / 2}, vs[4] = {-h / 2, -h / 2, h / 2, h / 2};
    Poly p;
    for (int k = 0; k < 4; ++k) p.push_back({cx + c * us[k] - s * vs[k], cy + s * us[k] + c * vs[k]});
    return p;
}

void check_filler() {
    const int W = 48, H = 40;
    Coverage c;
    auto convex_case = [&](const Poly& shape, const std::string& name) {
        edge_raster::fill_coverage(path_of({shape}), W, H, c);
        compare_pixels(c, W, H, 1e-12, name, [&](int i, int j) { return area_in_pixel(shape, i, j); });
    };
    convex_case(rect(3.25, 4.6, 29.9, 17.05), "axis-aligned rectangle");
    convex_case(rotated_rect(24.3, 19.1, 30.7, 11.2, 17.0), "rectangle turned 17 degrees");
    convex_case(rotated_rect(20.0, 20.0, 25.0, 3.3, -61.3), "rectangle turned -61.3 degrees");
    convex_case({{2.2, 3.1}, {40.7, 9.9}, {13.4, 35.6}}, "triangle");
    convex_case({{5.5, 30.25}, {30.5, 30.75}, {44.0, 31.0}}, "flat triangle (a sliver 0.5 px thick)");
    convex_case(rotated_rect(23.7, 14.2, 31.0, 0.013, 23.0), "sliver 0.013 px wide");
    convex_case(rect(10.45, 10.45, 10.55, 10.55), "0.1 x 0.1 inside one pixel");
    {
        // Reversed orientation: the nonzero rule does not care which way round.
        Poly t = {{2.2, 3.1}, {13.4, 35.6}, {40.7, 9.9}};
        convex_case(t, "triangle, wound the other way");
    }
    edge_raster::fill_coverage(path_of({rect(10.45, 10.45, 10.55, 10.55)}), W, H, c);
    require(std::fabs(at(c, 10, 10) - 0.01) < 1e-15, "a 0.1 x 0.1 square covers 0.01 of its pixel");

    // Two overlapping squares in one path. Wound the same way the overlap has
    // winding 2 and is filled (even-odd would leave a hole); wound opposite
    // ways it has winding 0 and is a hole.
    const Poly a = rotated_rect(18.2, 17.4, 20.0, 14.0, 9.0);
    const Poly b = rotated_rect(26.9, 22.3, 16.0, 18.0, -14.0);
    const Poly ab = intersect(a, b);
    require(std::fabs(area(ab)) > 50.0, "the two squares overlap");
    edge_raster::fill_coverage(path_of({a, b}), W, H, c);
    compare_pixels(c, W, H, 1e-11, "overlap, same winding (nonzero fills it)", [&](int i, int j) {
        return area_in_pixel(a, i, j) + area_in_pixel(b, i, j) - area_in_pixel(ab, i, j);
    });
    Poly b_rev(b.rbegin(), b.rend());
    edge_raster::fill_coverage(path_of({a, b_rev}), W, H, c);
    compare_pixels(c, W, H, 1e-11, "overlap, opposite winding (a hole)", [&](int i, int j) {
        return area_in_pixel(a, i, j) + area_in_pixel(b, i, j) - 2.0 * area_in_pixel(ab, i, j);
    });

    // A pentagram drawn as one self-crossing contour: its centre has winding 2.
    // Reference: the inner pentagon and the five points, disjoint and convex.
    {
        const double cx = 23.6, cy = 20.3, R = 17.2, deg = M_PI / 180.0;
        Poly star, outer, inner;
        for (int k = 0; k < 5; ++k) outer.push_back({cx + R * std::cos((90 + 72 * k) * deg), cy - R * std::sin((90 + 72 * k) * deg)});
        for (int k = 0; k < 5; ++k) star.push_back(outer[size_t((2 * k) % 5)]);
        const double r_in = R * std::cos(72 * deg) / std::cos(36 * deg);
        for (int k = 0; k < 5; ++k)
            inner.push_back({cx + r_in * std::cos((90 + 36 + 72 * k) * deg), cy - r_in * std::sin((90 + 36 + 72 * k) * deg)});
        std::vector<Poly> pieces = {inner};
        for (int k = 0; k < 5; ++k) pieces.push_back({outer[size_t(k)], inner[size_t((k + 4) % 5)], inner[size_t(k)]});
        edge_raster::fill_coverage(path_of({star}), W, H, c);
        compare_pixels(c, W, H, 1e-11, "pentagram (nonzero)", [&](int i, int j) {
            double s = 0.0;
            for (const Poly& p : pieces) s += area_in_pixel(p, i, j);
            return s;
        });
    }

    // Off the grid: nothing outside it is drawn, and what is inside is exact.
    convex_case(rotated_rect(2.0, 38.5, 30.0, 9.0, 31.0), "rectangle running off two edges");
    edge_raster::fill_coverage(path_of({rect(-20, -20, -1, -1)}), W, H, c);
    require(c.w == 0 && c.h == 0, "a path wholly off the grid covers nothing");
}

// The exact area of a circle inside a square, by integrating its chord.
double circle_in_pixel(double cx, double cy, double r, int i, int j) {
    const int n = 4000;
    double s = 0.0;
    for (int k = 0; k < n; ++k) {
        const double x = i + (k + 0.5) / n, dx = x - cx;
        if (std::fabs(dx) >= r) continue;
        const double h = std::sqrt(r * r - dx * dx);
        s += std::max(0.0, std::min(cy + h, j + 1.0) - std::max(cy - h, double(j)));
    }
    return s / n;
}

void check_circle() {
    const int W = 40, H = 40;
    const double tol = 0.02;
    for (double r : {0.37, 2.6, 7.3, 15.9}) {
        Path p;
        edge_raster::append_circle(p, 20.4, 19.7, r, Affine{}, tol);
        Coverage c;
        edge_raster::fill_coverage(p, W, H, c);
        double sum = 0.0;
        for (double v : c.a) sum += v;
        char buf[160];
        std::snprintf(buf, sizeof buf, "circle r=%.2f: area %.15g vs pi r^2 %.15g", r, sum, M_PI * r * r);
        require(std::fabs(sum - M_PI * r * r) <= 1e-11 * std::max(1.0, M_PI * r * r), buf);
        // No pixel strays from the true circle by more than the chords can:
        // `tol` of edge across a pixel's width.
        double worst = 0.0;
        for (int j = 0; j < H; ++j)
            for (int i = 0; i < W; ++i) worst = std::max(worst, std::fabs(at(c, i, j) - circle_in_pixel(20.4, 19.7, r, i, j)));
        std::snprintf(buf, sizeof buf, "circle r=%.2f: worst pixel %.4f against the true circle", r, worst);
        require(worst <= 1.5 * tol, buf);
    }
    // Mapped from film millimetres: a disc 0.114 mm across at 0.0044 mm/px,
    // turned 0.3 degrees -- the scale and turn of the edge print's dots.
    const double px = 0.0044, rot = 0.3 * M_PI / 180.0;
    Affine m;
    m.a = std::cos(rot) / px; m.b = std::sin(rot) / px; m.c = -std::sin(rot) / px; m.d = std::cos(rot) / px;
    m.e = 20.0 - (std::cos(rot) * 3.0 - std::sin(rot) * 1.5) / px;
    m.f = 20.0 - (std::sin(rot) * 3.0 + std::cos(rot) * 1.5) / px;
    Path p;
    edge_raster::append_circle(p, 3.0, 1.5, 0.057, m, tol);
    Coverage c;
    edge_raster::fill_coverage(p, W, H, c);
    double sum = 0.0;
    for (double v : c.a) sum += v;
    const double expect = M_PI * (0.057 / px) * (0.057 / px);
    require(std::fabs(sum - expect) <= 1e-10 * expect, "a disc mapped from film mm keeps its area");
}

void check_composite() {
    // Grey 0.92 is 234.6, which the 8-bit context holds as 235.
    std::vector<uint8_t> px = {0, 100, 200, 50, 7};
    Coverage c;
    c.x0 = 0; c.y0 = 0; c.w = 5; c.h = 1;
    c.a = {1.0, 0.5, 0.25, 0.0, 1e-9};
    edge_raster::composite(px, 5, c, 0.92);
    const int expect[5] = {235, int(std::floor(235 * 0.5 + 100 * 0.5 + 0.5)), int(std::floor(235 * 0.25 + 200 * 0.75 + 0.5)), 50, 7};
    for (int i = 0; i < 5; ++i) require(px[size_t(i)] == expect[i], "8-bit source-over, pixel " + std::to_string(i));
    // A second fill over the first, and a gain above 1 held at white.
    c.a = {0.5, 0.5, 0.5, 0.5, 0.5};
    std::vector<uint8_t> before = px;
    edge_raster::composite(px, 5, c, 1.7);
    for (int i = 0; i < 5; ++i)
        require(px[size_t(i)] == uint8_t(std::floor(255 * 0.5 + before[size_t(i)] * 0.5 + 0.5)), "second fill, pixel " + std::to_string(i));
    // A box placed inside a wider bitmap touches only its own pixels.
    std::vector<uint8_t> wide(6 * 3, 9);
    Coverage box;
    box.x0 = 2; box.y0 = 1; box.w = 2; box.h = 1; box.a = {1.0, 1.0};
    edge_raster::composite(wide, 6, box, 1.0);
    for (int k = 0; k < 18; ++k) require(wide[size_t(k)] == ((k == 8 || k == 9) ? 255 : 9), "box placement, pixel " + std::to_string(k));
}

void check_blur() {
    const std::vector<float> taps = edge_raster::gaussian_taps(2.3);
    require(taps.size() == 2 * size_t(std::ceil(3 * 2.3)) + 1, "radius ceil(3 sigma)");
    double sum = 0.0;
    for (size_t i = 0; i < taps.size(); ++i) {
        sum += taps[i];
        require(taps[i] == taps[taps.size() - 1 - i], "taps symmetric");
    }
    require(std::fabs(sum - 1.0) < 1e-6, "taps sum to 1");
    require(edge_raster::gaussian_taps(0.3).empty(), "no blur at sigma 0.3");

    const int W = 97, H = 61, r = int(taps.size() / 2);
    std::mt19937 rng(20261016u);
    std::uniform_real_distribution<float> u(0.0f, 1.0f);
    std::vector<float> img(size_t(W) * H);
    for (float& v : img) v = u(rng) < 0.7f ? 0.0f : u(rng);
    img[0] = 1.0f; img[size_t(W) * H - 1] = 1.0f;        // corners: the edge extension's worst case
    std::vector<float> out = img;
    edge_raster::gaussian_blur(out, W, H, taps, 1);
    double worst = 0.0;
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            double ref = 0.0;
            for (int j = 0; j < int(taps.size()); ++j)
                for (int i = 0; i < int(taps.size()); ++i)
                    ref += double(taps[size_t(j)]) * double(taps[size_t(i)]) *
                           double(img[size_t(std::clamp(y + j - r, 0, H - 1)) * W + size_t(std::clamp(x + i - r, 0, W - 1))]);
            worst = std::max(worst, std::fabs(double(out[size_t(y) * W + size_t(x)]) - ref));
        }
    char buf[128];
    std::snprintf(buf, sizeof buf, "blur vs direct 2-D double convolution: worst %.3g", worst);
    // Two float roundings of values below 1: the row pass's and the output's.
    require(worst <= 1.2e-7, buf);
    std::printf("%s\n", buf);

    // Every thread count gives the same bits.
    std::vector<float> big(size_t(301) * 203);
    for (float& v : big) v = u(rng);
    const std::vector<float> wide_taps = edge_raster::gaussian_taps(5.1);
    std::vector<float> one = big;
    edge_raster::gaussian_blur(one, 301, 203, wide_taps, 1);
    for (unsigned t : {2u, 3u, 7u, 16u, 0u}) {
        std::vector<float> many = big;
        edge_raster::gaussian_blur(many, 301, 203, wide_taps, t);
        require(std::memcmp(one.data(), many.data(), one.size() * sizeof(float)) == 0,
                "blur differs between 1 and " + std::to_string(t) + " threads");
    }
}

// --- the text path, through the real imprint raster ----------------------
std::string dump_dir;   // argv[2]: where to leave the coverage as 8-bit BMPs, to look at

void dump(const std::string& name, const std::vector<float>& cov, int w, int h) {
    if (dump_dir.empty()) return;
    const uint32_t row = (uint32_t(w) * 3 + 3) & ~3u, size = 54 + row * uint32_t(h);
    std::vector<unsigned char> b(size, 0);
    auto le32 = [&](size_t o, uint32_t v) { for (int k = 0; k < 4; ++k) b[o + size_t(k)] = (unsigned char)(v >> (8 * k)); };
    b[0] = 'B'; b[1] = 'M'; le32(2, size); le32(10, 54); le32(14, 40); le32(18, uint32_t(w)); le32(22, uint32_t(h));
    b[26] = 1; b[28] = 24; le32(34, row * uint32_t(h));
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            for (int c = 0; c < 3; ++c)
                b[54 + size_t(h - 1 - y) * row + size_t(x) * 3 + size_t(c)] =
                    (unsigned char)std::lround(255.0f * (1.0f - std::clamp(cov[size_t(y) * size_t(w) + size_t(x)], 0.0f, 1.0f)));
    FILE* f = std::fopen((dump_dir + "/" + name + ".bmp").c_str(), "wb");
    if (f) { std::fwrite(b.data(), 1, b.size(), f); std::fclose(f); }
}

OverscanLayout plain_layout(double px, uint32_t w, uint32_t h) {
    OverscanLayout L;
    L.px = px;
    L.canvas_w = w; L.canvas_h = h;
    L.A[0] = 1; L.A[1] = 0; L.A[2] = 0; L.A[3] = 1;
    L.cu = L.cv = L.cs = L.ct = 0;
    return L;
}

void check_text(const std::string& fonts) {
    imprint::set_font_directory(fonts);
    edge_raster::Font bold, regular;
    std::string error;
    require_call(bold.load(fonts + "/texgyreheros-bold.otf", error), "bold face", error);
    require_call(regular.load(fonts + "/texgyreheros-regular.otf", error), "regular face", error);
    require(bold.units_per_em() == 1000 && bold.cap_height() == 729, "TeX Gyre Heros: 1000 units, caps 729");

    // Kodak 120 (overscan.cpp): "KODAK" in Helvetica Neue Bold scaled x1.3,
    // advances and all, measured 7.28 mm long at caps 1.10 mm on
    // Gold200_6x7.png; the stock's "200" in bold x1.05, 0.03 mm tracking,
    // 2.75 mm at caps 1.13. Our face is not Helvetica Neue, so this asks
    // only that it sets those strings to within 5 % of the strips.
    const double kCap = 0.714;
    const double kodak = imprint::text_width("HelveticaNeue-Bold", 1.10 / kCap, "KODAK", 0.0, 1.3);
    const double two_hundred = imprint::text_width("HelveticaNeue-Bold", 1.13 / kCap, "200", 0.03, 1.05);
    std::printf("text: \"KODAK\" %.3f mm (strip 7.28), \"200\" %.3f mm (strip 2.75)\n", kodak, two_hundred);
    require(std::fabs(kodak / 7.28 - 1.0) < 0.05, "KODAK's width is not the strip's");
    require(std::fabs(two_hundred / 2.75 - 1.0) < 0.05, "200's width is not the strip's");
    // The width is the sum of the advances at caps scaled to 0.714 em, and a
    // zero tracking sets no pair kerning (CoreText's kern attribute of 0).
    {
        const double k = (1.10 / kCap) * kCap / 729.0;
        double sum = 0.0;
        for (char ch : std::string("KODAK")) sum += bold.advance(bold.glyph(uint32_t(ch))) * k;
        require(std::fabs(kodak - 1.3 * sum) < 1e-12, "text width is the advances' sum");
        double kerned = 0.0;
        int prev = -1;
        for (char ch : std::string("KODAK")) {
            const int g = bold.glyph(uint32_t(ch));
            if (prev >= 0) kerned += bold.kern(prev, g) * k;
            kerned += bold.advance(g) * k + 0.05;
            prev = g;
        }
        require(std::fabs(imprint::text_width("HelveticaNeue-Bold", 1.10 / kCap, "KODAK", 0.05, 1.3) - 1.3 * kerned) < 1e-12,
                "a non-zero tracking adds to the kerned advances");
    }

    // Rasterised at 100 px/mm, unblurred: the K's stem stands exactly the
    // cap height, every mark stays inside the line's advance, and the ink is
    // the glyphs' own area.
    const double px = 0.01, s0 = 1.0, base = 2.0, size = 1.10 / kCap;
    OverscanLayout L = plain_layout(px, 1100, 300);
    imprint::Group g;
    imprint::Op op;
    op.text = "KODAK"; op.font = "HelveticaNeue-Bold"; op.size_mm = size; op.hscale = 1.3; op.scale_advances = true;
    op.s = s0; op.t = base; op.gain = 1.0;
    g.ops.push_back(op);
    g.blur_mm = 0.0;
    std::vector<float> cov;
    int x0, y0, w, h;
    error.clear();
    require_call(imprint::rasterise(L, g, cov, x0, y0, w, h, error) && error.empty(), "Kodak line rasterises", error);
    dump("kodak_120_name", cov, w, h);
    auto cv =[&](int x, int y) { return cov[size_t(y - y0) * size_t(w) + size_t(x - x0)]; };
    int left = 1 << 30, right = -1;
    for (int y = y0; y < y0 + h; ++y)
        for (int x = x0; x < x0 + w; ++x)
            if (cv(x, y) > 0.0f) { left = std::min(left, x); right = std::max(right, x); }
    require(left >= int(s0 / px) && right < int(std::ceil((s0 + kodak) / px)), "the ink stays inside the line's advance");
    // The K's stem: the first column whose middle row is fully covered.
    int stem = -1;
    for (int x = left; x < left + 40 && stem < 0; ++x) if (cv(x, int((base - 0.5) / px)) > 0.99f) stem = x + 3;
    require(stem > 0, "found the K's stem");
    int top = -1, bottom = -1;
    for (int y = y0; y < y0 + h; ++y) if (cv(stem, y) > 0.5f) { if (top < 0) top = y; bottom = y; }
    const double cap_px = bottom - top + 1;
    std::printf("text: K stem %d..%d, %.0f px for caps of %.0f px\n", top, bottom, cap_px, 1.10 / px);
    require(std::fabs(cap_px - 1.10 / px) <= 1.0, "the caps are not 1.10 mm tall");
    require(std::abs(bottom + 1 - int(std::lround(base / px))) <= 1, "the caps do not stand on the baseline");
    // Ink area: the coverage sum against the glyphs' own outlines (shoelace
    // over the same flattening), to the 8-bit quantisation.
    double ink = 0.0;
    for (float v : cov) ink += v;
    double outline_area = 0.0;
    {
        const double k = size * kCap / 729.0;
        double pen = 0.0;
        for (char ch : std::string("KODAK")) {
            const int gl = bold.glyph(uint32_t(ch));
            Affine m;
            m.a = 1.3 * k / px; m.d = -k / px; m.e = (s0 + 1.3 * pen) / px - x0; m.f = base / px - y0;
            Path p;
            bold.outline(gl, m, 0.02, p);
            size_t start = 0;
            for (size_t end : p.ends) {
                double s = 0.0;
                for (size_t i = start; i < end; ++i) {
                    const size_t j = i + 1 < end ? i + 1 : start;
                    s += p.xy[2 * i] * p.xy[2 * j + 1] - p.xy[2 * j] * p.xy[2 * i + 1];
                }
                outline_area += 0.5 * s;
                start = end;
            }
            pen += bold.advance(gl) * k;
        }
        outline_area = std::fabs(outline_area);
    }
    char buf[160];
    std::snprintf(buf, sizeof buf, "text: ink %.1f px^2 against the outlines' %.1f px^2", ink, outline_area);
    std::printf("%s\n", buf);
    require(std::fabs(ink / outline_area - 1.0) < 0.003, buf);

    // Kodak 135's numbers: bold widened x1.25 in shape only, 0.25 mm apart,
    // and the C200 tail in the regular face, turned a quarter (the Ilford and
    // vertical layouts turn their lines). Both draw, and the turned line's ink
    // matches the upright one's to the quantisation.
    imprint::Group nums;
    imprint::Op n = op;
    n.text = "24"; n.hscale = 1.25; n.scale_advances = false; n.tracking_mm = 0.25; n.size_mm = 1.22 / kCap;
    nums.ops.push_back(n);
    nums.blur_mm = 0.022;
    require_call(imprint::rasterise(L, nums, cov, x0, y0, w, h, error) && error.empty(), "Kodak 135 numbers rasterise", error);
    dump("kodak_135_numbers", cov, w, h);
    imprint::Group upright, turned;
    imprint::Op tail = op;
    tail.font = "HelveticaNeue"; tail.text = "200"; tail.hscale = 1.0; tail.scale_advances = false; tail.tracking_mm = 0.04;
    tail.s = 5.0; tail.t = 2.0;
    upright.ops.push_back(tail);
    tail.rot_deg = 90.0; tail.s = 5.0; tail.t = 0.2;
    turned.ops.push_back(tail);
    double ink_up = 0.0, ink_turned = 0.0;
    require_call(imprint::rasterise(L, upright, cov, x0, y0, w, h, error), "regular face rasterises", error);
    for (float v : cov) ink_up += v;
    require_call(imprint::rasterise(L, turned, cov, x0, y0, w, h, error), "turned line rasterises", error);
    for (float v : cov) ink_turned += v;
    dump("c200_tail_turned", cov, w, h);
    require(std::fabs(ink_turned / ink_up - 1.0) < 0.003, "a quarter turn changed the ink");

    // Without the faces: the text group is refused by name, and a group of
    // polygons and dots -- the date back, the dot faces -- still draws.
    imprint::set_font_directory(fonts + "/does-not-exist");
    error.clear();
    require(!imprint::rasterise(L, g, cov, x0, y0, w, h, error), "text drew without its font");
    std::printf("text: without the font: %s\n", error.c_str());
    require(error.find("HelveticaNeue-Bold") != std::string::npos && error.find("texgyreheros-bold.otf") != std::string::npos,
            "the refusal does not name the face and its file: " + error);
    imprint::Group shapes;
    imprint::Op dot;
    dot.kind = imprint::Op::Circle; dot.pts = {3.0, 1.0}; dot.size_mm = 0.057;
    shapes.ops.push_back(dot);
    imprint::Op seg;
    seg.kind = imprint::Op::Poly; seg.pts = {4.0, 0.5, 4.6, 0.5, 4.62, 0.65, 4.02, 0.65};
    shapes.ops.push_back(seg);
    error.clear();
    require_call(imprint::rasterise(L, shapes, cov, x0, y0, w, h, error) && error.empty(), "shapes need no font", error);
    imprint::Op odd = op;
    odd.font = "Futura";
    imprint::Group futura;
    futura.ops.push_back(odd);
    imprint::set_font_directory(fonts);
    error.clear();
    require(!imprint::rasterise(L, futura, cov, x0, y0, w, h, error) && error.find("Futura") != std::string::npos,
            "a face with no stand-in is refused by name");
}

// What a Kodak 135 edge band costs at the full tier of a 45 MP frame (0.0044
// mm/px): two frames' numbers, the name, DX bars and arrows along 40 mm of
// film, sigma 5 px. Reported, not bounded -- this machine is not a benchmark
// (AGENTS.md trap 17); the Mac's vImage figure for the same band is 2026-10-03's.
void time_band() {
    const double px = 0.0044, kCap = 0.714;
    OverscanLayout L = plain_layout(px, 9100, 600);
    imprint::Group g;
    g.blur_mm = 0.022;
    for (int m = 0; m < 2; ++m) {
        const double s = -2.0 + 19.0 * m;
        imprint::Op n;
        n.font = "HelveticaNeue-Bold"; n.size_mm = 1.22 / kCap; n.hscale = 1.25; n.tracking_mm = 0.25;
        n.text = m ? "24A" : "24"; n.s = s + 16.9; n.t = 1.53;
        g.ops.push_back(n);
        imprint::Op name = n;
        name.text = "KODAK PORTRA 400"; name.hscale = 1.0; name.tracking_mm = 0.06; name.s = s + 6.4;
        g.ops.push_back(name);
        for (int k = 0; k < 16; ++k) {
            imprint::Op bar;
            bar.kind = imprint::Op::Poly;
            const double a = s + k * 0.82, b = a + 0.41;
            bar.pts = {a, 0.2, b, 0.2, b, 1.3, a, 1.3};
            g.ops.push_back(bar);
        }
    }
    std::vector<float> cov;
    int x0, y0, w, h;
    std::string error;
    const auto t0 = std::chrono::steady_clock::now();
    require_call(imprint::rasterise(L, g, cov, x0, y0, w, h, error), "edge band", error);
    const double total = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    std::vector<float> again(cov.size(), 0.5f);
    const auto t1 = std::chrono::steady_clock::now();
    edge_raster::gaussian_blur(again, w, h, edge_raster::gaussian_taps(0.022 / px));
    const double blur = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count();
    std::printf("edge band: %d x %d px, %zu ops, rasterised in %.1f ms (its blur alone %.1f ms on %u threads)\n", w, h,
                g.ops.size(), total, blur, std::thread::hardware_concurrency());
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) { std::fprintf(stderr, "usage: spk_edge_raster <resources> [bmp-dir]\n"); return 2; }
    if (argc == 3) dump_dir = argv[2];
    try {
        check_filler();
        check_circle();
        check_composite();
        check_blur();
        check_text(std::string(argv[1]) + "/fonts");
        time_band();
    } catch (const std::exception& e) {
        std::fprintf(stderr, "edge raster: %s\n", e.what());
        return 1;
    }
    std::printf("edge raster: %d checks passed; filler worst pixel error %.3g against exact areas\n", checks, worst_filler);
    return 0;
}
