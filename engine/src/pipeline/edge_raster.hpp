// edge_raster.hpp -- the film edge's imprints drawn without Apple's frameworks (Linux).
//
// overscan.cpp rasterises the edge print and the date back through CoreText,
// CoreGraphics and vImage on the Mac. Off Apple this stands in (engine/PORT_PLAN.md §4):
//   - shapes and glyph outlines filled by one exact-area coverage rasteriser
//     (nonzero, antialiased), drawn op over op as CoreGraphics composites an
//     opaque grey fill (dst = gain c + dst (1 - c));
//   - glyphs from stb_truetype, in the closest free faces this system has:
//     HelveticaNeue -> Nimbus Sans (URW's Helvetica, fonts-urw-base35; there is
//     no Medium, so Medium is Bold), ArialNarrow -> Liberation Sans Narrow,
//     Menlo-Bold -> DejaVu Sans Mono Bold (Menlo's own ancestor). Positions,
//     sizes and tracking stay overscan.cpp's numbers; glyph shapes differ from
//     the Mac's at the 0.1 mm scale of an edge print;
//   - the mask's softening, a separable Gaussian with the edges extended
//     (vImageConvolve_PlanarF + kvImageEdgeExtend), threaded over lines.
#pragma once
#include <string>
#include <vector>

namespace spk::edge_raster {

// x' = a x + c y + e, y' = b x + d y + f (CoreGraphics' order): user space to bitmap pixels.
struct Affine {
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;
    void apply(double x, double y, double& X, double& Y) const { X = a * x + c * y + e; Y = b * x + d * y + f; }
    Affine then(const Affine& o) const;   // this, then o
};

class Bitmap {
public:
    Bitmap(int w, int h) : w_(w), h_(h), px_(size_t(w) * size_t(h), 0.0f) {}
    void fill_polygon(const std::vector<double>& xy, const Affine& m, double gain);
    void fill_ellipse(double cx, double cy, double rx, double ry, const Affine& m, double gain);
    // A line of text with its baseline start at the text-space origin, glyphs y-up in font units scaled
    // to `size` (the em) and widened by `glyph_x` along the baseline; advances and `tracking` are not
    // widened. Text space maps to user space through (x, -y), then `m`.
    bool fill_text(const char* font, double size, const std::string& text, double tracking, double glyph_x,
                   const Affine& m, double gain, std::string& error);
    // Coverage quantised to 8 bits, as the Mac's grey bitmap holds it.
    std::vector<float> coverage() const;

private:
    struct Pt { double x, y; };
    void fill(const std::vector<std::vector<Pt>>& contours, double gain);
    int w_, h_;
    std::vector<float> px_;
};

// The string's advance in user units (CTLineGetTypographicBounds' width), tracking after every glyph.
double text_width(const char* font, double size, const std::string& text, double tracking);

// `img` (w x h) through a separable kernel `k` (odd length) along x, then y, edges extended.
void soften(std::vector<float>& img, int w, int h, const std::vector<float>& k);

}  // namespace spk::edge_raster
