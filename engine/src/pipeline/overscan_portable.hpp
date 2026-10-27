// Portable coverage rasteriser for the original film-space imprint operations.
// Included inside overscan.cpp's anonymous namespace after Op/Group. Outlines
// come from the unmodified TeX Gyre Heros fonts (GUST Font License); stock/DX
// data, placement, exposure and projection softness remain in overscan.cpp.
// Cubic/quadratic outlines are flattened in canvas pixels, then scan-converted
// with nonzero winding and four subpixel rows. No platform text API is used.

struct PortableFace {
    stbtt_fontinfo info{};
    double unit = 0;
    explicit PortableFace(const unsigned char* data) {
        if (!stbtt_InitFont(&info, data, 0)) throw std::runtime_error("overscan: invalid bundled font");
        unit = stbtt_ScaleForMappingEmToPixels(&info, 1.0f);
    }
};

const PortableFace& portable_face(const char* name) {
    static const PortableFace regular(overscan_font_regular), bold(overscan_font_bold);
    return std::strstr(name, "Bold") ? bold : regular;
}

std::vector<int> portable_codepoints(const std::string& text) {
    std::vector<int> points;
    for (size_t i = 0; i < text.size();) {
        const unsigned char c = static_cast<unsigned char>(text[i++]);
        int cp = c, count = 0;
        if ((c & 0xe0) == 0xc0) { cp = c & 31; count = 1; }
        else if ((c & 0xf0) == 0xe0) { cp = c & 15; count = 2; }
        else if ((c & 0xf8) == 0xf0) { cp = c & 7; count = 3; }
        for (int k = 0; k < count && i < text.size(); ++k)
            cp = (cp << 6) | (static_cast<unsigned char>(text[i++]) & 63);
        points.push_back(cp);
    }
    return points;
}

template<class Emit>
double portable_glyphs(const char* font, double size, const std::string& text, double tracking, Emit emit) {
    const PortableFace& f = portable_face(font);
    const auto codepoints = portable_codepoints(text);
    double x = 0;
    for (size_t i = 0; i < codepoints.size(); ++i) {
        const int glyph = stbtt_FindGlyphIndex(&f.info, codepoints[i]);
        emit(f, glyph, x);
        int advance = 0, bearing = 0;
        stbtt_GetGlyphHMetrics(&f.info, glyph, &advance, &bearing);
        x += advance * f.unit * size;
        if (i + 1 < codepoints.size()) {
            x += tracking;
            x += stbtt_GetGlyphKernAdvance(&f.info, glyph,
                    stbtt_FindGlyphIndex(&f.info, codepoints[i + 1])) * f.unit * size;
        }
    }
    return x;
}

double portable_text_width(const char* font, double size, const std::string& text, double tracking) {
    return portable_glyphs(font, size, text, tracking, [](const PortableFace&, int, double) {});
}

struct OsPoint { double x, y; };
struct OsEdge { OsPoint a, b; };
using OsPath = std::vector<OsEdge>;
OsPoint os_mid(OsPoint a, OsPoint b) { return {(a.x + b.x) * 0.5, (a.y + b.y) * 0.5}; }
double os_line_error(OsPoint p, OsPoint a, OsPoint b) {
    const double dx = b.x - a.x, dy = b.y - a.y;
    const double cross = (p.x - a.x) * dy - (p.y - a.y) * dx;
    return cross * cross / std::max(1e-12, dx * dx + dy * dy);
}
void os_quad(OsPath& path, OsPoint a, OsPoint c, OsPoint b, int depth = 0) {
    if (depth == 12 || os_line_error(c, a, b) < 0.01) { path.push_back({a, b}); return; }
    const auto ac = os_mid(a, c), cb = os_mid(c, b), m = os_mid(ac, cb);
    os_quad(path, a, ac, m, depth + 1); os_quad(path, m, cb, b, depth + 1);
}
void os_cubic(OsPath& path, OsPoint a, OsPoint c, OsPoint d, OsPoint b, int depth = 0) {
    if (depth == 12 || std::max(os_line_error(c, a, b), os_line_error(d, a, b)) < 0.01) {
        path.push_back({a, b}); return;
    }
    const auto ac = os_mid(a, c), cd = os_mid(c, d), db = os_mid(d, b);
    const auto l = os_mid(ac, cd), r = os_mid(cd, db), m = os_mid(l, r);
    os_cubic(path, a, ac, l, m, depth + 1); os_cubic(path, m, r, db, b, depth + 1);
}

// Coverage in x is integrated exactly over each pixel; y uses four samples.
void os_paint(const OsPath& path, double gain, int w, int h, std::vector<float>& cov) {
    if (path.empty()) return;
    double top = h, bottom = 0;
    for (const auto& e : path) { top = std::min({top, e.a.y, e.b.y}); bottom = std::max({bottom, e.a.y, e.b.y}); }
    struct Crossing { double x; int winding; };
    std::vector<Crossing> xs;
    std::vector<double> row(size_t(w), 0);
    for (int y = std::max(0, int(std::floor(top))); y < std::min(h, int(std::ceil(bottom))); ++y) {
        std::fill(row.begin(), row.end(), 0.0);
        for (int sample = 0; sample < 4; ++sample) {
            const double yy = y + (sample + 0.5) * 0.25;
            xs.clear();
            for (const auto& e : path) {
                if ((e.a.y <= yy && yy < e.b.y) || (e.b.y <= yy && yy < e.a.y))
                    xs.push_back({e.a.x + (yy - e.a.y) * (e.b.x - e.a.x) / (e.b.y - e.a.y), e.b.y > e.a.y ? 1 : -1});
            }
            std::sort(xs.begin(), xs.end(), [](const Crossing& a, const Crossing& b) { return a.x < b.x; });
            int winding = 0;
            for (size_t k = 0; k + 1 < xs.size(); ++k) {
                winding += xs[k].winding;
                if (!winding) continue;
                const double a = std::max(0.0, xs[k].x), b = std::min(double(w), xs[k + 1].x);
                for (int x = int(std::floor(a)); x < int(std::ceil(b)); ++x)
                    if (x >= 0 && x < w) row[size_t(x)] += std::max(0.0, std::min(b, x + 1.0) - std::max(a, double(x))) * 0.25;
            }
        }
        for (int x = 0; x < w; ++x) {
            const double a = std::clamp(row[size_t(x)], 0.0, 1.0);
            float& dest = cov[size_t(y) * size_t(w) + size_t(x)];
            dest = float(dest * (1.0 - a) + std::clamp(gain, 0.0, 1.0) * a);
        }
    }
}

void portable_rasterise(const OverscanLayout& L, const Group& group, int x0, int y0,
                        int w, int h, std::vector<float>& cov) {
    cov.assign(size_t(w) * size_t(h), 0.0f);
    const double a = L.A[0], b = L.A[1], c = L.A[2], d = L.A[3], det = a * d - b * c;
    auto canvas = [&](double s, double t) -> OsPoint {
        return {((d * (s - L.cs) - b * (t - L.ct)) / det + L.cu) / L.px - x0,
                ((-c * (s - L.cs) + a * (t - L.ct)) / det + L.cv) / L.px - y0};
    };
    for (const Op& op : group.ops) {
        OsPath path;
        if (op.kind == Op::Poly) {
            const size_t n = op.pts.size() / 2;
            for (size_t i = 0; i < n; ++i) {
                const size_t j = (i + 1) % n;
                path.push_back({canvas(op.pts[2*i], op.pts[2*i+1]), canvas(op.pts[2*j], op.pts[2*j+1])});
            }
        } else if (op.kind == Op::Circle) {
            const int n = std::clamp(int(std::ceil(2 * M_PI * std::sqrt(std::max(1.0, op.size_mm / L.px)))), 32, 512);
            for (int i = 0; i < n; ++i) {
                const double u = 2 * M_PI * i / n, v = 2 * M_PI * (i + 1) / n;
                path.push_back({canvas(op.pts[0] + op.size_mm * std::cos(u), op.pts[1] + op.size_mm * std::sin(u)),
                                canvas(op.pts[0] + op.size_mm * std::cos(v), op.pts[1] + op.size_mm * std::sin(v))});
            }
        } else {
            const double angle = op.rot_deg * M_PI / 180.0, cs = std::cos(angle), sn = std::sin(angle);
            portable_glyphs(op.font, op.size_mm, op.text, op.tracking_mm,
                [&](const PortableFace& f, int glyph, double pen) {
                    stbtt_vertex* vertices = nullptr;
                    const int count = stbtt_GetGlyphShape(&f.info, glyph, &vertices);
                    auto point = [&](double x, double y) {
                        const double xx = x * f.unit * op.size_mm * op.hscale + pen * (op.scale_advances ? op.hscale : 1.0);
                        const double yy = -y * f.unit * op.size_mm;
                        return canvas(op.s + cs * xx - sn * yy, op.t + sn * xx + cs * yy);
                    };
                    OsPoint current{}, first{};
                    bool contour = false;
                    for (int i = 0; i < count; ++i) {
                        const auto& v = vertices[i]; const auto p = point(v.x, v.y);
                        if (v.type == STBTT_vmove) {
                            if (contour) path.push_back({current, first});
                            first = current = p; contour = true;
                        } else if (v.type == STBTT_vline) path.push_back({current, p});
                        else if (v.type == STBTT_vcurve) os_quad(path, current, point(v.cx, v.cy), p);
                        else if (v.type == STBTT_vcubic) os_cubic(path, current, point(v.cx, v.cy), point(v.cx1, v.cy1), p);
                        current = p;
                    }
                    if (contour) path.push_back({current, first});
                    stbtt_FreeShape(&f.info, vertices);
                });
        }
        os_paint(path, op.gain, w, h, cov);
    }
}

// The same normalised Gaussian and edge extension as the Apple vImage path.
void portable_blur(std::vector<float>& cov, std::vector<float>& tmp, int w, int h,
                   const std::vector<float>& kernel, int r) {
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        double sum = 0;
        for (int k = -r; k <= r; ++k) sum += cov[size_t(y) * w + std::clamp(x + k, 0, w - 1)] * kernel[size_t(k + r)];
        tmp[size_t(y) * w + x] = float(sum);
    }
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        double sum = 0;
        for (int k = -r; k <= r; ++k) sum += tmp[size_t(std::clamp(y + k, 0, h - 1)) * w + x] * kernel[size_t(k + r)];
        cov[size_t(y) * w + x] = float(sum);
    }
}
