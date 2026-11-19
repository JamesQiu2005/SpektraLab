// edge_raster.cpp -- see edge_raster.hpp. Off Apple only (the Mac's build globs pipeline/*.cpp and keeps
// CoreText), so the whole translation unit is guarded.
#ifndef __APPLE__
#include "edge_raster.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

namespace spk::edge_raster {

Affine Affine::then(const Affine& o) const {
    Affine r;
    r.a = o.a * a + o.c * b;
    r.b = o.b * a + o.d * b;
    r.c = o.a * c + o.c * d;
    r.d = o.b * c + o.d * d;
    r.e = o.a * e + o.c * f + o.e;
    r.f = o.b * e + o.d * f + o.f;
    return r;
}

namespace {

// --- fonts ----------------------------------------------------------------------------------------

struct Face {
    std::vector<unsigned char> data;
    stbtt_fontinfo info{};
    float units_per_em = 1000;
};

// The free face for each name overscan.cpp asks for, file names in search order.
const std::vector<std::string>& files_for(const std::string& name) {
    static const std::map<std::string, std::vector<std::string>> kFaces = {
        {"HelveticaNeue", {"NimbusSans-Regular.otf", "TeXGyreHeros-Regular.otf", "texgyreheros-regular.otf",
                           "LiberationSans-Regular.ttf"}},
        {"HelveticaNeue-Medium", {"NimbusSans-Bold.otf", "TeXGyreHeros-Bold.otf", "texgyreheros-bold.otf",
                                  "LiberationSans-Bold.ttf"}},
        {"HelveticaNeue-Bold", {"NimbusSans-Bold.otf", "TeXGyreHeros-Bold.otf", "texgyreheros-bold.otf",
                                "LiberationSans-Bold.ttf"}},
        {"ArialNarrow", {"LiberationSansNarrow-Regular.ttf", "NimbusSansNarrow-Regular.otf", "NimbusSans-Regular.otf"}},
        {"Menlo-Bold", {"DejaVuSansMono-Bold.ttf", "LiberationMono-Bold.ttf", "NimbusMonoPS-Bold.otf"}},
    };
    static const std::vector<std::string> kDefault = {"NimbusSans-Regular.otf", "LiberationSans-Regular.ttf"};
    auto it = kFaces.find(name);
    return it == kFaces.end() ? kDefault : it->second;
}

const std::vector<std::string>& font_dirs() {
    static const std::vector<std::string> dirs = [] {
        std::vector<std::string> d;
        if (const char* env = std::getenv("SPEKTRALAB_FONT_DIR"); env && *env) d.emplace_back(env);
        // A snap's own fonts first, then the system's.
        if (const char* snap = std::getenv("SNAP"); snap && *snap) {
            d.push_back(std::string(snap) + "/usr/share/fonts/opentype/urw-base35");
            d.push_back(std::string(snap) + "/usr/share/fonts/truetype/liberation");
            d.push_back(std::string(snap) + "/usr/share/fonts/truetype/dejavu");
        }
        for (const char* s : {"/usr/share/fonts/opentype/urw-base35", "/usr/share/fonts/truetype/liberation",
                              "/usr/share/fonts/truetype/liberation2", "/usr/share/fonts/truetype/dejavu",
                              "/usr/share/fonts/opentype/tex-gyre", "/usr/share/texmf/fonts/opentype/public/tex-gyre",
                              "/usr/share/fonts/truetype/msttcorefonts"})
            d.emplace_back(s);
        return d;
    }();
    return dirs;
}

bool read_file(const std::string& path, std::vector<unsigned char>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return !out.empty();
}

std::mutex& face_lock() {
    static std::mutex m;
    return m;
}

// Loaded once per name and kept (never freed: a render may be drawing while the process exits).
const Face* face(const char* name, std::string& error) {
    std::lock_guard<std::mutex> lock(face_lock());
    static std::map<std::string, Face*>& cache = *new std::map<std::string, Face*>;
    const std::string key = name ? name : "";
    if (auto it = cache.find(key); it != cache.end()) {
        if (!it->second) error = "no font for '" + key + "' (install fonts-urw-base35, fonts-liberation-sans-narrow, fonts-dejavu-core)";
        return it->second;
    }
    Face* found = nullptr;
    for (const std::string& file : files_for(key)) {
        for (const std::string& dir : font_dirs()) {
            auto* f = new Face;
            if (!read_file(dir + "/" + file, f->data) ||
                !stbtt_InitFont(&f->info, f->data.data(), stbtt_GetFontOffsetForIndex(f->data.data(), 0))) {
                delete f;
                continue;
            }
            const float s = stbtt_ScaleForMappingEmToPixels(&f->info, 1.0f);
            f->units_per_em = s > 0 ? 1.0f / s : 1000.0f;
            found = f;
            break;
        }
        if (found) break;
    }
    cache[key] = found;
    if (!found) error = "no font for '" + key + "' (install fonts-urw-base35, fonts-liberation-sans-narrow, fonts-dejavu-core)";
    return found;
}

// UTF-8 to code points (a malformed byte stands for itself).
std::vector<int> codepoints(const std::string& s) {
    std::vector<int> out;
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        const int n = c >= 0xF0 && c < 0xF8 ? 3 : c >= 0xE0 && c < 0xF0 ? 2 : c >= 0xC0 && c < 0xE0 ? 1 : 0;
        int cp = n == 3 ? (c & 0x07) : n == 2 ? (c & 0x0F) : n == 1 ? (c & 0x1F) : c;
        bool ok = n > 0 && i + size_t(n) < s.size();
        for (int k = 1; ok && k <= n; ++k) {
            const unsigned char cc = static_cast<unsigned char>(s[i + size_t(k)]);
            if ((cc & 0xC0) != 0x80) ok = false;
            else cp = (cp << 6) | (cc & 0x3F);
        }
        if (ok) { out.push_back(cp); i += size_t(n) + 1; }
        else { out.push_back(c); ++i; }
    }
    return out;
}

// --- layout ----------------------------------------------------------------------------------------

struct Placed { int glyph; double x; };

// Each glyph's pen position along the baseline (user units), and the line's advance.
double layout(const Face& f, double size, const std::string& text, double tracking, std::vector<Placed>* out) {
    const double sc = size / f.units_per_em;
    double pen = 0;
    int prev = 0;
    for (int cp : codepoints(text)) {
        const int g = stbtt_FindGlyphIndex(&f.info, cp);
        if (prev && g) pen += sc * stbtt_GetGlyphKernAdvance(&f.info, prev, g);
        if (out) out->push_back({g, pen});
        int adv = 0, lsb = 0;
        stbtt_GetGlyphHMetrics(&f.info, g, &adv, &lsb);
        pen += sc * adv + tracking;
        prev = g;
    }
    return pen;
}

}  // namespace

// --- the rasteriser ---------------------------------------------------------------------------------
//
// Signed-area accumulation (as font-rs): every edge adds its covered area to the pixel it crosses and
// its cover to the next, and a running sum along each row gives the coverage. Rows are accumulated
// on their own with x clamped to [0, w], so geometry past the bitmap's sides lands at its edges and
// never in the next row; |sum| clamped to 1 is the nonzero rule for the shapes drawn here.

void Bitmap::fill(const std::vector<std::vector<Pt>>& contours, double gain) {
    double xmin = 1e300, xmax = -1e300, ymin = 1e300, ymax = -1e300;
    for (const auto& c : contours)
        for (const Pt& p : c) { xmin = std::min(xmin, p.x); xmax = std::max(xmax, p.x); ymin = std::min(ymin, p.y); ymax = std::max(ymax, p.y); }
    if (!(xmax > xmin) || !(ymax > ymin)) return;
    // This op's own box inside the bitmap.
    const int bx0 = std::clamp(int(std::floor(xmin)), 0, w_), bx1 = std::clamp(int(std::ceil(xmax)) + 1, 0, w_);
    const int by0 = std::clamp(int(std::floor(ymin)), 0, h_), by1 = std::clamp(int(std::ceil(ymax)) + 1, 0, h_);
    const int bw = bx1 - bx0, bh = by1 - by0;
    if (bw <= 0 || bh <= 0) return;
    const int stride = bw + 3;
    std::vector<float> acc(size_t(stride) * size_t(bh), 0.0f);
    auto line = [&](Pt p0, Pt p1) {
        double x0 = std::clamp(p0.x - bx0, 0.0, double(bw)), y0 = p0.y - by0;
        double x1 = std::clamp(p1.x - bx0, 0.0, double(bw)), y1 = p1.y - by0;
        if (y0 == y1) return;
        double dir = 1.0;
        if (y0 > y1) { std::swap(x0, x1); std::swap(y0, y1); dir = -1.0; }
        const double dxdy = (x1 - x0) / (y1 - y0);
        double x = x0;
        if (y0 < 0) x -= y0 * dxdy;
        const int ys = std::max(0, int(std::floor(y0)));
        const int ye = std::min(bh, int(std::ceil(y1)));
        for (int y = ys; y < ye; ++y) {
            float* row = acc.data() + size_t(y) * size_t(stride);
            const double dy = std::min(double(y + 1), y1) - std::max(double(y), y0);
            const double xnext = x + dxdy * dy;
            const double d = dy * dir;
            const double xa = std::min(x, xnext), xb = std::max(x, xnext);
            const double xaf = std::floor(xa);
            const int xai = int(xaf);
            const double xbc = std::ceil(xb);
            const int xbi = int(xbc);
            if (xbi <= xai + 1) {
                const double xmf = 0.5 * (x + xnext) - xaf;
                row[xai] += float(d - d * xmf);
                row[xai + 1] += float(d * xmf);
            } else {
                const double s = 1.0 / (xb - xa);
                const double x0f = xa - xaf;
                const double a0 = 0.5 * s * (1.0 - x0f) * (1.0 - x0f);
                const double x1f = xb - xbc + 1.0;
                const double am = 0.5 * s * x1f * x1f;
                row[xai] += float(d * a0);
                if (xbi == xai + 2) {
                    row[xai + 1] += float(d * (1.0 - a0 - am));
                } else {
                    const double a1 = s * (1.5 - x0f);
                    row[xai + 1] += float(d * (a1 - a0));
                    for (int xi = xai + 2; xi < xbi - 1; ++xi) row[xi] += float(d * s);
                    const double a2 = a1 + double(xbi - xai - 3) * s;
                    row[xbi - 1] += float(d * (1.0 - a2 - am));
                }
                row[xbi] += float(d * am);
            }
            x = xnext;
        }
    };
    for (const auto& c : contours) {
        if (c.size() < 2) continue;
        for (size_t i = 0; i < c.size(); ++i) line(c[i], c[(i + 1) % c.size()]);
    }
    const float g = float(std::clamp(gain, 0.0, 1.0));
    for (int y = 0; y < bh; ++y) {
        const float* row = acc.data() + size_t(y) * size_t(stride);
        float* dst = px_.data() + size_t(by0 + y) * size_t(w_) + size_t(bx0);
        float sum = 0;
        for (int x = 0; x < bw; ++x) {
            sum += row[x];
            const float cov = std::min(1.0f, std::fabs(sum));
            if (cov > 0) dst[x] = g * cov + dst[x] * (1.0f - cov);   // an opaque grey over what is there
        }
    }
}

void Bitmap::fill_polygon(const std::vector<double>& xy, const Affine& m, double gain) {
    std::vector<Pt> c;
    for (size_t k = 0; k + 1 < xy.size(); k += 2) {
        Pt p;
        m.apply(xy[k], xy[k + 1], p.x, p.y);
        c.push_back(p);
    }
    fill({c}, gain);
}

void Bitmap::fill_ellipse(double cx, double cy, double rx, double ry, const Affine& m, double gain) {
    // As a polygon fine enough that its sagitta is far below a pixel.
    double X0, Y0, X1, Y1;
    m.apply(cx, cy, X0, Y0);
    m.apply(cx + rx, cy + ry, X1, Y1);
    const double rpx = std::max(std::fabs(X1 - X0), std::fabs(Y1 - Y0)) + 1.0;
    const int n = std::clamp(int(std::ceil(M_PI / std::acos(std::max(0.0, 1.0 - 0.02 / rpx)))), 16, 1024);
    std::vector<Pt> c(static_cast<size_t>(n));
    for (int k = 0; k < n; ++k) {
        const double a = 2.0 * M_PI * k / n;
        m.apply(cx + rx * std::cos(a), cy + ry * std::sin(a), c[size_t(k)].x, c[size_t(k)].y);
    }
    fill({c}, gain);
}

bool Bitmap::fill_text(const char* font, double size, const std::string& text, double tracking, double glyph_x,
                       const Affine& m, double gain, std::string& error) {
    const Face* f = face(font, error);
    if (!f) return false;
    std::vector<Placed> placed;
    layout(*f, size, text, tracking, &placed);
    const double sc = size / f->units_per_em;
    std::vector<std::vector<Pt>> contours;
    for (const Placed& p : placed) {
        if (!p.glyph) continue;
        stbtt_vertex* v = nullptr;
        const int n = stbtt_GetGlyphShape(&f->info, p.glyph, &v);
        // font units, y up -> text space -> user (x, -y) -> bitmap
        auto map = [&](double gx, double gy) {
            Pt q;
            m.apply(p.x + gx * sc * glyph_x, -gy * sc, q.x, q.y);
            return q;
        };
        Pt cur{0, 0};
        double cx = 0, cy = 0;   // the pen in font units
        for (int i = 0; i < n; ++i) {
            const stbtt_vertex& e = v[i];
            if (e.type == STBTT_vmove) {
                contours.emplace_back();
                cx = e.x; cy = e.y;
                cur = map(cx, cy);
                contours.back().push_back(cur);
            } else if (e.type == STBTT_vline) {
                cx = e.x; cy = e.y;
                cur = map(cx, cy);
                if (!contours.empty()) contours.back().push_back(cur);
            } else if (e.type == STBTT_vcurve || e.type == STBTT_vcubic) {
                // Flattened in bitmap space, about a tenth of a pixel from the curve.
                const Pt p0 = cur, p3 = map(e.x, e.y);
                const Pt c1 = map(e.cx, e.cy);
                const Pt c2 = e.type == STBTT_vcubic ? map(e.cx1, e.cy1) : c1;
                const double len = std::hypot(c1.x - p0.x, c1.y - p0.y) + std::hypot(c2.x - c1.x, c2.y - c1.y) +
                                   std::hypot(p3.x - c2.x, p3.y - c2.y);
                const int steps = std::clamp(int(std::ceil(std::sqrt(len * 4.0))), 1, 64);
                for (int k = 1; k <= steps; ++k) {
                    const double t = double(k) / steps, u = 1.0 - t;
                    Pt q;
                    if (e.type == STBTT_vcurve) {
                        q.x = u * u * p0.x + 2 * u * t * c1.x + t * t * p3.x;
                        q.y = u * u * p0.y + 2 * u * t * c1.y + t * t * p3.y;
                    } else {
                        q.x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x;
                        q.y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y;
                    }
                    if (!contours.empty()) contours.back().push_back(q);
                }
                cx = e.x; cy = e.y;
                cur = p3;
            }
        }
        stbtt_FreeShape(&f->info, v);
    }
    fill(contours, gain);
    return true;
}

std::vector<float> Bitmap::coverage() const {
    std::vector<float> out(px_.size());
    for (size_t i = 0; i < px_.size(); ++i) out[i] = std::round(std::clamp(px_[i], 0.0f, 1.0f) * 255.0f) * (1.0f / 255.0f);
    return out;
}

double text_width(const char* font, double size, const std::string& text, double tracking) {
    std::string error;
    const Face* f = face(font, error);
    return f ? layout(*f, size, text, tracking, nullptr) : 0.0;
}

void soften(std::vector<float>& img, int w, int h, const std::vector<float>& k) {
    const int r = int(k.size() / 2);
    if (r <= 0 || w <= 0 || h <= 0) return;
    std::vector<float> tmp(img.size());
    const unsigned threads = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
    auto run = [&](int n, auto&& fn) {
        std::vector<std::thread> pool;
        for (unsigned t = 0; t < threads; ++t)
            pool.emplace_back([&, t] { for (int i = int(t); i < n; i += int(threads)) fn(i); });
        for (auto& th : pool) th.join();
    };
    // along x, edges extended
    run(h, [&](int y) {
        const float* src = img.data() + size_t(y) * size_t(w);
        float* dst = tmp.data() + size_t(y) * size_t(w);
        for (int x = 0; x < w; ++x) {
            float s = 0;
            for (int j = -r; j <= r; ++j) s += k[size_t(j + r)] * src[std::clamp(x + j, 0, w - 1)];
            dst[x] = s;
        }
    });
    // along y
    run(w, [&](int x) {
        for (int y = 0; y < h; ++y) {
            float s = 0;
            for (int j = -r; j <= r; ++j) s += k[size_t(j + r)] * tmp[size_t(std::clamp(y + j, 0, h - 1)) * size_t(w) + size_t(x)];
            img[size_t(y) * size_t(w) + size_t(x)] = s;
        }
    });
}

}  // namespace spk::edge_raster
#endif  // !__APPLE__
