// overscan_raster_portable.cpp -- the imprint raster off Apple
// (overscan_raster.hpp), on edge_raster.hpp and the bundled TeX Gyre Heros.
//
// It draws what overscan_raster_apple.cpp draws, through the same transform:
// user space is film millimetres with t downward, mapped into the group's box
// of canvas pixels by the layout's inverse scan registration. Where CoreText
// leaves a choice unstated, the choice made is written beside it; none of the
// text path has been compared with a Mac render yet (PORT_PLAN.md §4 asks for
// a coverage dump from one), so treat glyph-scale agreement as unmeasured.
// The dot faces, the DX bars, the date back's segments and dots are polygons
// and circles and need no font at all.
//
// build.sh globs src/pipeline/*.cpp, so the whole translation unit is guarded.
#ifndef __APPLE__
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>

#include "edge_raster.hpp"
#include "overscan_raster.hpp"

namespace spk::imprint {

namespace {

using edge_raster::Affine;
using edge_raster::Font;

// Helvetica Neue is Apple's and cannot be redistributed. TeX Gyre Heros
// (GUST Font License; engine/resources_portable/fonts/NOTICE.md) is the
// freely licensed Helvetica that is closest in shape and metrics. It has no
// medium weight: Kodak 120's Portra tail, the one medium string, takes Bold.
struct Face { const char* name; const char* file; };
constexpr Face kFaces[] = {
    {"HelveticaNeue",        "texgyreheros-regular.otf"},
    {"HelveticaNeue-Bold",   "texgyreheros-bold.otf"},
    {"HelveticaNeue-Medium", "texgyreheros-bold.otf"},
};

// Every Helvetica size in overscan.cpp is a measured cap height divided by
// Helvetica Neue's cap per em (`kCap`, 0.714). A face whose caps are a
// different fraction of its em is scaled so its caps land on the measured
// height, which is the quantity the edge-print layout was read off strips in.
constexpr double kNeueCapPerEm = 0.714;

// The furthest a chord may stray from a glyph's curve or a dot's circle, px.
// CoreGraphics' own flattening is not documented; 0.02 px is far below what
// the 8-bit coverage can show (1/255 of a pixel's area is 0.004 px of edge).
constexpr double kFlatten = 0.02;

struct Fonts {
    std::mutex lock;
    std::string dir;
    std::map<std::string, std::shared_ptr<const Font>> by_path;
};
Fonts& fonts() {
    static Fonts f;
    return f;
}

// The face standing in for a CoreText font name, read on first use. A face
// that cannot be read is not remembered, so one added later is found.
std::shared_ptr<const Font> face(const char* name, std::string& error) {
    const Face* entry = nullptr;
    for (const Face& f : kFaces)
        if (std::strcmp(f.name, name) == 0) entry = &f;
    if (!entry) {
        error = std::string("overscan: the portable build has no font standing in for '") + name + "'";
        return nullptr;
    }
    Fonts& fs = fonts();
    std::lock_guard<std::mutex> guard(fs.lock);
    if (fs.dir.empty()) {
        error = std::string("overscan: '") + name + "' needs " + entry->file +
                ", and no font directory was set (spk_engine_create sets <resources>/fonts)";
        return nullptr;
    }
    const std::string path = fs.dir + "/" + entry->file;
    if (auto it = fs.by_path.find(path); it != fs.by_path.end()) return it->second;
    auto font = std::make_shared<Font>();
    std::string why;
    if (!font->load(path, why)) {
        error = std::string("overscan: the edge print's '") + name + "' text needs its font: " + why;
        return nullptr;
    }
    fs.by_path.emplace(path, font);
    return font;
}

// A line as CoreText sets it, in film mm along an unscaled baseline: each
// glyph's origin, and the advance of the whole.
//
// Pair kerning: CTStringAttributes.h says a kern attribute of 0.0 means "no
// kerning will be done at all" and that any other value shifts each next
// character from "its default offset as defined by the current character's
// font" -- read here as the font's kerned offset plus the value. overscan.cpp
// always sets the attribute (`make_text`), so a zero tracking switches pair
// kerning off and a non-zero one keeps it. The attribute is added after every
// character, the last one included, which is the trailing space CoreText is
// known for and is part of the typographic width.
struct Line {
    std::vector<int> glyphs;
    std::vector<double> pen;
    double width = 0.0, k = 0.0;     // k: mm per font unit
};

void lay_out(const Font& f, double size_mm, const std::string& text, double tracking_mm, Line& line) {
    line = Line{};
    line.k = size_mm * kNeueCapPerEm / f.cap_height();
    double pen = 0.0;
    int prev = -1;
    for (uint32_t cp : edge_raster::utf8_codepoints(text)) {
        const int g = f.glyph(cp);
        if (prev >= 0 && tracking_mm != 0.0) pen += f.kern(prev, g) * line.k;
        line.glyphs.push_back(g);
        line.pen.push_back(pen);
        pen += f.advance(g) * line.k + tracking_mm;
        prev = g;
    }
    line.width = pen;
}

}  // namespace

void set_font_directory(const std::string& dir) {
    Fonts& fs = fonts();
    std::lock_guard<std::mutex> guard(fs.lock);
    if (dir == fs.dir) return;
    fs.dir = dir;
    fs.by_path.clear();
}

double text_width(const char* font, double size_mm, const std::string& text, double tracking_mm, double hscale) {
    std::string error;
    const std::shared_ptr<const Font> f = face(font, error);
    // Without the face this only places other marks: the op that needs the
    // face fails in `rasterise`, so the estimate (overscan.cpp's own, for
    // fitting edge text) never reaches a picture.
    if (!f) return (0.68 * size_mm + tracking_mm) * double(edge_raster::utf8_codepoints(text).size()) * hscale;
    Line line;
    lay_out(*f, size_mm, text, tracking_mm, line);
    return line.width * hscale;
}

bool rasterise(const OverscanLayout& L, const Group& g, std::vector<float>& cov, int& x0, int& y0, int& w,
               int& h, std::string& error) {
    if (!group_bounds(L, g, x0, y0, w, h)) return false;
    // Film (s, t) mm -> pixels of this box: film_to_canvas_px as one affine.
    Affine dev;
    {
        const double a = L.A[0], b = L.A[1], c = L.A[2], d = L.A[3], det = a * d - b * c;
        dev.a = d / det / L.px;  dev.c = -b / det / L.px;
        dev.b = -c / det / L.px; dev.d = a / det / L.px;
        dev.e = ((-d * L.cs + b * L.ct) / det + L.cu) / L.px - x0;
        dev.f = ((c * L.cs - a * L.ct) / det + L.cv) / L.px - y0;
    }
    std::vector<uint8_t> px(size_t(w) * size_t(h), 0);
    edge_raster::Path path;
    edge_raster::Coverage c;
    auto fill = [&](double gain) {
        path.close();
        edge_raster::fill_coverage(path, w, h, c);
        edge_raster::composite(px, w, c, gain);
        path = edge_raster::Path{};
    };
    for (const Op& op : g.ops) {
        if (op.kind == Op::Poly) {
            for (size_t k = 0; k + 1 < op.pts.size(); k += 2) {
                double x, y;
                dev.apply(op.pts[k], op.pts[k + 1], x, y);
                if (k == 0) path.move_to(x, y); else path.line_to(x, y);
            }
            fill(op.gain);
            continue;
        }
        if (op.kind == Op::Circle) {
            edge_raster::append_circle(path, op.pts[0], op.pts[1], op.size_mm, dev, kFlatten);
            fill(op.gain);
            continue;
        }
        const std::shared_ptr<const Font> f = face(op.font, error);
        if (!f) return false;
        Line line;
        lay_out(*f, op.size_mm, op.text, op.tracking_mm, line);
        // CoreGraphics' chain for a line: translate to (s, t), rotate, and with
        // `scale_advances` widen the whole line; the text matrix then widens
        // each glyph's shape by `hscale` otherwise, and flips it upright.
        const double r = op.rot_deg * M_PI / 180.0, cr = std::cos(r), sr = std::sin(r);
        const double hs_line = op.scale_advances ? op.hscale : 1.0, hs_shape = op.scale_advances ? 1.0 : op.hscale;
        Affine film_from_line;
        film_from_line.a = cr * hs_line; film_from_line.c = -sr; film_from_line.e = op.s;
        film_from_line.b = sr * hs_line; film_from_line.d = cr;  film_from_line.f = op.t;
        const Affine dev_from_line = dev.then(film_from_line);
        // Glyph by glyph, as CoreGraphics composites a line: where widened
        // letters overlap, their edges are laid twice.
        for (size_t i = 0; i < line.glyphs.size(); ++i) {
            Affine line_from_font;
            line_from_font.a = line.k * hs_shape; line_from_font.d = -line.k; line_from_font.e = line.pen[i];
            f->outline(line.glyphs[i], dev_from_line.then(line_from_font), kFlatten, path);
            fill(op.gain);
        }
    }

    cov.resize(px.size());
    for (size_t i = 0; i < px.size(); ++i) cov[i] = float(px[i]) * (1.0f / 255.0f);
    // The projection's softness (RFC-031 §3.4): the same Gaussian the Mac
    // runs through vImage, edges extended. Threaded: the full-width edge-print
    // bands are 8,189 x 512 px at the full tier of a 45 MP frame.
    const std::vector<float> taps = edge_raster::gaussian_taps(g.blur_mm / L.px);
    edge_raster::gaussian_blur(cov, w, h, taps);
    return true;
}

}  // namespace spk::imprint
#endif  // !__APPLE__
