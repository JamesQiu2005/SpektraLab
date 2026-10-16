// edge_raster.cpp -- see edge_raster.hpp. Off Apple only: build.sh globs
// src/pipeline/*.cpp, and the Mac draws its imprints with CoreGraphics.
#ifndef __APPLE__
#include "edge_raster.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <thread>

// stb_truetype is compiled here and nowhere else in the engine, its functions
// static to this file so a host that links its own copy cannot collide.
#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#if defined(_MSC_VER)
#pragma warning(push, 0)
#endif
#include "../../third_party/stb/stb_truetype.h"
#if defined(_MSC_VER)
#pragma warning(pop)
#endif

namespace spk::edge_raster {

// ---------------------------------------------------------------------------
// paths
// ---------------------------------------------------------------------------
Affine Affine::then(const Affine& m) const {
    Affine r;
    r.a = a * m.a + c * m.b;
    r.b = b * m.a + d * m.b;
    r.c = a * m.c + c * m.d;
    r.d = b * m.c + d * m.d;
    r.e = a * m.e + c * m.f + e;
    r.f = b * m.e + d * m.f + f;
    return r;
}

void Path::move_to(double x, double y) {
    close();
    xy.push_back(x);
    xy.push_back(y);
}

void Path::line_to(double x, double y) {
    xy.push_back(x);
    xy.push_back(y);
}

void Path::close() {
    const size_t start = ends.empty() ? 0 : ends.back();
    if (points() > start) ends.push_back(points());
}

// A Bezier segment's chords stray from it by at most |B''| / (8 n^2) for n
// equal steps in its parameter; the step counts below hold that under `tol`.
void Path::quad_to(double cx, double cy, double x, double y, double tol) {
    const double x0 = xy[xy.size() - 2], y0 = xy[xy.size() - 1];
    const double dd = std::hypot(x0 - 2 * cx + x, y0 - 2 * cy + y);          // B'' = 2 dd
    const int n = std::clamp(int(std::ceil(std::sqrt(dd / (4.0 * tol)))), 1, 1024);
    for (int k = 1; k <= n; ++k) {
        const double t = double(k) / n, u = 1.0 - t;
        line_to(u * u * x0 + 2 * u * t * cx + t * t * x, u * u * y0 + 2 * u * t * cy + t * t * y);
    }
}

void Path::cubic_to(double c1x, double c1y, double c2x, double c2y, double x, double y, double tol) {
    const double x0 = xy[xy.size() - 2], y0 = xy[xy.size() - 1];
    const double dd = std::max(std::hypot(x0 - 2 * c1x + c2x, y0 - 2 * c1y + c2y),
                               std::hypot(c1x - 2 * c2x + x, c1y - 2 * c2y + y));   // |B''| <= 6 dd
    const int n = std::clamp(int(std::ceil(std::sqrt(3.0 * dd / (4.0 * tol)))), 1, 1024);
    for (int k = 1; k <= n; ++k) {
        const double t = double(k) / n, u = 1.0 - t;
        const double b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
        line_to(b0 * x0 + b1 * c1x + b2 * c2x + b3 * x, b0 * y0 + b1 * c1y + b2 * c2y + b3 * y);
    }
}

void append_circle(Path& p, double cx, double cy, double r, const Affine& m, double tol) {
    if (!(r > 0.0)) return;
    // The map's largest stretch decides how far a chord may sag.
    const double s2 = m.a * m.a + m.b * m.b + m.c * m.c + m.d * m.d, det = m.a * m.d - m.b * m.c;
    const double stretch = std::sqrt(0.5 * (s2 + std::sqrt(std::max(0.0, s2 * s2 - 4.0 * det * det))));
    const double rp = r * stretch;
    int n = 8;
    if (rp > tol) n = int(std::ceil(M_PI / std::acos(1.0 - tol / rp)));
    n = std::clamp(n, 8, 4096);
    // A regular n-gon of circumradius R has area (n/2) R^2 sin(2 pi / n).
    const double R = r * std::sqrt(2.0 * M_PI / (n * std::sin(2.0 * M_PI / n)));
    for (int k = 0; k < n; ++k) {
        const double th = 2.0 * M_PI * k / n;
        double x, y;
        m.apply(cx + R * std::cos(th), cy + R * std::sin(th), x, y);
        if (k == 0) p.move_to(x, y); else p.line_to(x, y);
    }
    p.close();
}

// ---------------------------------------------------------------------------
// the filler
// ---------------------------------------------------------------------------
namespace {

struct Edge {
    double x0, y0, x1, y1;   // y0 < y1
    double dxdy;
    int dir;                 // +1 drawn downward (y increasing), -1 upward
    double x_at(double y) const { return x0 + (y - y0) * dxdy; }
};

// The area, per unit of height, between an edge running linearly from xa to
// xb and the vertical line x = c, on the edge's left of c. A pixel column
// [i, i+1) right of the edge holds G(i+1) - G(i) of it, because
// clamp(i + 1 - x, 0, 1) = max(0, i + 1 - x) - max(0, i - x) for every x.
double left_area(double c, double xa, double xb) {
    const double lo = std::min(xa, xb), hi = std::max(xa, xb);
    if (c <= lo) return 0.0;
    if (c >= hi) return c - 0.5 * (xa + xb);
    return (c - lo) * (c - lo) / (2.0 * (hi - lo));
}

// One trapezoid of the region, between a left and a right edge over a band
// of height dy, added into one row of the box.
void add_span(double* row, int bx0, int bw, double la, double lb, double ra, double rb, double dy) {
    const int lo = std::max(bx0, int(std::floor(std::min(la, lb))));
    const int hi = std::min(bx0 + bw, int(std::ceil(std::max(ra, rb))));
    const double inner_lo = std::ceil(std::max(la, lb)), inner_hi = std::floor(std::min(ra, rb));
    for (int i = lo; i < hi; ++i) {
        double v;
        if (double(i) >= inner_lo && double(i) + 1.0 <= inner_hi) {
            v = dy;     // wholly inside: both closed forms reduce to the band's height
        } else {
            const double c0 = double(i), c1 = c0 + 1.0;
            v = dy * ((left_area(c1, la, lb) - left_area(c0, la, lb)) - (left_area(c1, ra, rb) - left_area(c0, ra, rb)));
        }
        row[i - bx0] += v;
    }
}

}  // namespace

void fill_coverage(const Path& p, int grid_w, int grid_h, Coverage& out) {
    out = Coverage{};
    std::vector<Edge> edges;
    double xmin = 1e300, xmax = -1e300, ymin = 1e300, ymax = -1e300;
    size_t start = 0;
    for (size_t end : p.ends) {
        for (size_t i = start; i < end; ++i) {
            const size_t j = i + 1 < end ? i + 1 : start;
            const double ax = p.xy[2 * i], ay = p.xy[2 * i + 1], bx = p.xy[2 * j], by = p.xy[2 * j + 1];
            if (!std::isfinite(ax) || !std::isfinite(ay) || !std::isfinite(bx) || !std::isfinite(by)) continue;
            xmin = std::min({xmin, ax, bx}); xmax = std::max({xmax, ax, bx});
            ymin = std::min({ymin, ay, by}); ymax = std::max({ymax, ay, by});
            if (ay == by) continue;                       // horizontal: bounds nothing
            Edge e;
            if (ay < by) { e.x0 = ax; e.y0 = ay; e.x1 = bx; e.y1 = by; e.dir = 1; }
            else         { e.x0 = bx; e.y0 = by; e.x1 = ax; e.y1 = ay; e.dir = -1; }
            e.dxdy = (e.x1 - e.x0) / (e.y1 - e.y0);
            edges.push_back(e);
        }
        start = end;
    }
    if (edges.empty()) return;
    const int bx0 = std::max(0, int(std::floor(xmin))), bx1 = std::min(grid_w, int(std::ceil(xmax)));
    const int by0 = std::max(0, int(std::floor(ymin))), by1 = std::min(grid_h, int(std::ceil(ymax)));
    if (bx1 <= bx0 || by1 <= by0) return;
    out.x0 = bx0; out.y0 = by0; out.w = bx1 - bx0; out.h = by1 - by0;
    out.a.assign(size_t(out.w) * size_t(out.h), 0.0);

    std::sort(edges.begin(), edges.end(), [](const Edge& a, const Edge& b) { return a.y0 < b.y0; });
    std::vector<const Edge*> active;
    std::vector<double> cuts;
    struct Cross { double xm, xa, xb; int dir; };
    std::vector<Cross> band;
    size_t next = 0;
    for (int j = by0; j < by1; ++j) {
        const double Y0 = j, Y1 = j + 1.0;
        while (next < edges.size() && edges[next].y0 < Y1) active.push_back(&edges[next++]);
        active.erase(std::remove_if(active.begin(), active.end(), [&](const Edge* e) { return e->y1 <= Y0; }),
                     active.end());
        if (active.empty()) continue;
        // Cut the row wherever an edge starts, ends or crosses another:
        // between cuts no two edges swap order, so the region is trapezoids.
        cuts.assign({Y0, Y1});
        for (const Edge* e : active) {
            if (e->y0 > Y0 && e->y0 < Y1) cuts.push_back(e->y0);
            if (e->y1 > Y0 && e->y1 < Y1) cuts.push_back(e->y1);
        }
        for (size_t a = 0; a < active.size(); ++a)
            for (size_t b = a + 1; b < active.size(); ++b) {
                const Edge& p0 = *active[a];
                const Edge& p1 = *active[b];
                if (p0.dxdy == p1.dxdy) continue;
                const double lo = std::max({Y0, p0.y0, p1.y0}), hi = std::min({Y1, p0.y1, p1.y1});
                if (!(hi > lo)) continue;
                // Both edges' x at the overlap's top, then where they meet.
                const double y = lo + (p1.x_at(lo) - p0.x_at(lo)) / (p0.dxdy - p1.dxdy);
                if (y > lo && y < hi) cuts.push_back(y);
            }
        std::sort(cuts.begin(), cuts.end());
        cuts.erase(std::unique(cuts.begin(), cuts.end()), cuts.end());
        double* row = out.a.data() + size_t(j - by0) * size_t(out.w);
        for (size_t k = 0; k + 1 < cuts.size(); ++k) {
            const double ya = cuts[k], yb = cuts[k + 1];
            if (!(yb > ya)) continue;
            const double ym = 0.5 * (ya + yb);
            band.clear();
            for (const Edge* e : active)
                if (e->y0 < yb && e->y1 > ya) band.push_back({e->x_at(ym), e->x_at(ya), e->x_at(yb), e->dir});
            std::sort(band.begin(), band.end(), [](const Cross& a, const Cross& b) { return a.xm < b.xm; });
            int winding = 0;
            const Cross* left = nullptr;
            for (const Cross& c : band) {
                const int before = winding;
                winding += c.dir;
                if (before == 0 && winding != 0) left = &c;
                else if (before != 0 && winding == 0 && left)
                    add_span(row, bx0, out.w, left->xa, left->xb, c.xa, c.xb, yb - ya);
            }
        }
    }
    for (double& v : out.a) v = std::clamp(v, 0.0, 1.0);
}

void composite(std::vector<uint8_t>& px, int w, const Coverage& c, double grey) {
    const double g8 = std::round(std::clamp(grey, 0.0, 1.0) * 255.0);
    for (int y = 0; y < c.h; ++y)
        for (int x = 0; x < c.w; ++x) {
            const double cv = c.a[size_t(y) * size_t(c.w) + size_t(x)];
            if (!(cv > 0.0)) continue;
            uint8_t& d = px[size_t(c.y0 + y) * size_t(w) + size_t(c.x0 + x)];
            const double v = g8 * cv + double(d) * (1.0 - cv);
            d = uint8_t(std::clamp(std::floor(v + 0.5), 0.0, 255.0));
        }
}

// ---------------------------------------------------------------------------
// the blur
// ---------------------------------------------------------------------------
std::vector<float> gaussian_taps(double sigma) {
    if (!(sigma > 0.3)) return {};
    const int r = int(std::ceil(3.0 * sigma));
    std::vector<float> k(size_t(2 * r + 1));
    double sum = 0.0;
    for (int i = -r; i <= r; ++i) { k[size_t(i + r)] = float(std::exp(-0.5 * i * i / (sigma * sigma))); sum += k[size_t(i + r)]; }
    for (float& v : k) v = float(v / sum);
    return k;
}

namespace {

template <class Fn>
void for_rows(int h, unsigned threads, Fn fn) {
    const unsigned n = std::max(1u, std::min(threads, unsigned(h)));
    if (n == 1) { fn(0, h); return; }
    std::vector<std::thread> pool;
    pool.reserve(n);
    for (unsigned t = 0; t < n; ++t) {
        const int a = int(int64_t(h) * t / n), b = int(int64_t(h) * (t + 1) / n);
        pool.emplace_back([=] { fn(a, b); });
    }
    for (std::thread& th : pool) th.join();
}

}  // namespace

void gaussian_blur(std::vector<float>& img, int w, int h, const std::vector<float>& taps, unsigned threads) {
    if (taps.empty() || w <= 0 || h <= 0) return;
    const int r = int(taps.size() / 2);
    if (threads == 0) {
        // Spawning costs ~50 us a thread; below a few hundred thousand taps
        // (a date's box, ~200 x 60 px) one thread is the faster.
        const double work = double(w) * double(h) * double(taps.size());
        threads = work < 4.0e5 ? 1u : std::max(1u, std::thread::hardware_concurrency());
    }
    std::vector<float> tmp(img.size());
    // Along rows: vImage's kernel_height 1, kernel_width taps.
    for_rows(h, threads, [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const float* src = img.data() + size_t(y) * size_t(w);
            float* dst = tmp.data() + size_t(y) * size_t(w);
            for (int x = 0; x < w; ++x) {
                double acc = 0.0;
                if (x >= r && x + r < w) {
                    const float* s = src + (x - r);
                    for (size_t j = 0; j < taps.size(); ++j) acc += double(taps[j]) * double(s[j]);
                } else {
                    for (int j = 0; j < int(taps.size()); ++j)
                        acc += double(taps[size_t(j)]) * double(src[std::clamp(x + j - r, 0, w - 1)]);
                }
                dst[x] = float(acc);
            }
        }
    });
    // Down columns: kernel_height taps, kernel_width 1.
    for_rows(h, threads, [&](int y0, int y1) {
        std::vector<double> acc(static_cast<size_t>(w));
        for (int y = y0; y < y1; ++y) {
            std::fill(acc.begin(), acc.end(), 0.0);
            for (int j = 0; j < int(taps.size()); ++j) {
                const double k = taps[size_t(j)];
                const float* s = tmp.data() + size_t(std::clamp(y + j - r, 0, h - 1)) * size_t(w);
                for (int x = 0; x < w; ++x) acc[size_t(x)] += k * double(s[x]);
            }
            float* dst = img.data() + size_t(y) * size_t(w);
            for (int x = 0; x < w; ++x) dst[x] = float(acc[size_t(x)]);
        }
    });
}

// ---------------------------------------------------------------------------
// fonts
// ---------------------------------------------------------------------------
struct Font::Impl {
    std::vector<unsigned char> data;
    stbtt_fontinfo info{};
    double upem = 1000.0, cap = 700.0;
};

bool Font::load(const std::string& path, std::string& error) {
    impl_.reset();
    auto impl = std::make_shared<Impl>();
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) { error = "cannot open " + path; return false; }
    const std::streamoff size = file.tellg();
    if (size <= 0 || size > (64 << 20)) { error = path + " is empty or too large to be a font"; return false; }
    impl->data.resize(size_t(size));
    file.seekg(0);
    if (!file.read(reinterpret_cast<char*>(impl->data.data()), std::streamsize(size))) {
        error = "cannot read " + path;
        return false;
    }
    const int offset = stbtt_GetFontOffsetForIndex(impl->data.data(), 0);
    if (offset < 0 || !stbtt_InitFont(&impl->info, impl->data.data(), offset)) {
        error = path + " is not a TrueType or OpenType font stb_truetype can read";
        return false;
    }
    // unitsPerEm, big-endian at byte 18 of 'head'; stbtt_ScaleForMappingEmToPixels
    // would hand it back only as a float reciprocal.
    const unsigned char* head = impl->data.data() + impl->info.head;
    impl->upem = double((unsigned(head[18]) << 8) | head[19]);
    if (!(impl->upem > 0)) { error = path + " has no units per em"; return false; }
    int x0, y0, x1, y1;
    const int h = stbtt_FindGlyphIndex(&impl->info, 'H');
    if (h == 0 || !stbtt_GetGlyphBox(&impl->info, h, &x0, &y0, &x1, &y1) || y1 <= 0) {
        error = path + " has no 'H' to measure its cap height by";
        return false;
    }
    impl->cap = double(y1);
    impl_ = std::move(impl);
    return true;
}

int Font::glyph(uint32_t codepoint) const { return stbtt_FindGlyphIndex(&impl_->info, int(codepoint)); }
double Font::units_per_em() const { return impl_->upem; }
double Font::cap_height() const { return impl_->cap; }

double Font::advance(int g) const {
    int adv = 0, lsb = 0;
    stbtt_GetGlyphHMetrics(&impl_->info, g, &adv, &lsb);
    return double(adv);
}

double Font::kern(int left, int right) const {
    return double(stbtt_GetGlyphKernAdvance(&impl_->info, left, right));
}

void Font::outline(int g, const Affine& m, double tol, Path& out) const {
    stbtt_vertex* v = nullptr;
    const int n = stbtt_GetGlyphShape(&impl_->info, g, &v);
    for (int i = 0; i < n; ++i) {
        double x, y, c1x, c1y, c2x, c2y;
        m.apply(v[i].x, v[i].y, x, y);
        switch (v[i].type) {
            case STBTT_vmove: out.move_to(x, y); break;
            case STBTT_vline: out.line_to(x, y); break;
            case STBTT_vcurve:
                m.apply(v[i].cx, v[i].cy, c1x, c1y);
                out.quad_to(c1x, c1y, x, y, tol);
                break;
            case STBTT_vcubic:
                m.apply(v[i].cx, v[i].cy, c1x, c1y);
                m.apply(v[i].cx1, v[i].cy1, c2x, c2y);
                out.cubic_to(c1x, c1y, c2x, c2y, x, y, tol);
                break;
            default: break;
        }
    }
    out.close();
    stbtt_FreeShape(&impl_->info, v);
}

std::vector<uint32_t> utf8_codepoints(const std::string& text) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < text.size();) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        int extra = c >= 0xF0 && c < 0xF8 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (c >= 0x80 && c < 0xC0) extra = 0;
        uint32_t cp = extra == 0 ? c : extra == 1 ? (c & 0x1Fu) : extra == 2 ? (c & 0x0Fu) : (c & 0x07u);
        bool ok = i + size_t(extra) < text.size() || extra == 0;
        for (int k = 1; ok && k <= extra; ++k) {
            const unsigned char cc = static_cast<unsigned char>(text[i + size_t(k)]);
            if ((cc & 0xC0u) != 0x80u) ok = false;
            else cp = (cp << 6) | (cc & 0x3Fu);
        }
        if (!ok) { out.push_back(c); ++i; continue; }
        out.push_back(cp);
        i += size_t(extra) + 1;
    }
    return out;
}

}  // namespace spk::edge_raster
#endif  // !__APPLE__
