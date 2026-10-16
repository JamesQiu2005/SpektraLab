// edge_raster.hpp -- the 2-D raster the portable build draws the film edge
// and the date back with (overscan_raster_portable.cpp; RFC-031, RFC-032 §27).
//
// What macOS gets from CoreGraphics, CoreText and vImage, rebuilt on plain
// C++ so the imprints need nothing from the platform:
//
//   fill_coverage  the exact area of a path's nonzero-winding region in each
//                  pixel. Not sampled: every row is cut where an edge starts,
//                  ends or crosses another, so between cuts the region is a
//                  set of trapezoids whose area per pixel column has a closed
//                  form. Overlapping contours (a glyph's, or two of a seven-
//                  segment digit's) count once, as the nonzero rule says.
//   composite      CGBitmapContext's source-over into an 8-bit grey bitmap
//                  with no alpha: the fill grey at coverage c over what is
//                  there, rounded to 8 bits after every fill.
//   gaussian_blur  vImageConvolve_PlanarF twice with kvImageEdgeExtend: the
//                  same float taps, clamp-to-edge, each output a double sum
//                  rounded once. Threaded over rows; every output is the same
//                  sum in the same order whatever the thread count.
//   Font           stb_truetype outlines (TrueType or CFF), drawn through the
//                  full affine by the same filler -- stbtt_Rasterize cannot
//                  rotate or shear a glyph.
//
// Built everywhere but Apple: build.sh globs src/pipeline/*.cpp, so the
// translation unit is guarded and the Mac keeps its own raster.
#pragma once
#ifndef __APPLE__
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace spk::edge_raster {

// x' = a x + c y + e, y' = b x + d y + f -- CGAffineTransform's convention.
struct Affine {
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;
    void apply(double x, double y, double& ox, double& oy) const {
        ox = a * x + c * y + e;
        oy = b * x + d * y + f;
    }
    // this o m: m first, then this.
    Affine then(const Affine& m) const;
};

// Closed contours in pixel space: pixel (i, j) is the square [i, i+1) x
// [j, j+1). Each contour closes from its last point back to its first.
struct Path {
    std::vector<double> xy;              // x0, y0, x1, y1, ...
    std::vector<size_t> ends;            // one past each contour's last point (in points)
    void move_to(double x, double y);
    void line_to(double x, double y);
    // Curves flattened to chords no further than `tol` px from the curve.
    void quad_to(double cx, double cy, double x, double y, double tol);
    void cubic_to(double c1x, double c1y, double c2x, double c2y, double x, double y, double tol);
    void close();                         // ends the current contour
    size_t points() const { return xy.size() / 2; }
};

// A circle of radius `r` about (cx, cy) in some space, mapped by `m` into
// pixels: a polygon whose vertices sit on a circle widened just enough that
// the polygon's area is the circle's exactly, with enough vertices that no
// edge strays more than `tol` px from the true circle.
void append_circle(Path& p, double cx, double cy, double r, const Affine& m, double tol);

// Coverage of one fill, kept only over the path's box in the grid.
struct Coverage {
    int x0 = 0, y0 = 0, w = 0, h = 0;
    std::vector<double> a;               // w * h, row-major, each in [0, 1]
};

// The exact area of `p`'s nonzero-winding region in each pixel of a grid_w x
// grid_h grid. Non-finite points are dropped with their edges.
void fill_coverage(const Path& p, int grid_w, int grid_h, Coverage& out);

// Source-over into an 8-bit grey bitmap (w wide) with no alpha, as
// CGBitmapContext does it: the fill grey is the colour's 8-bit value, and
// each touched pixel becomes round(grey8 * c + dst * (1 - c)).
void composite(std::vector<uint8_t>& px, int w, const Coverage& c, double grey);

// overscan.cpp's taps for a Gaussian of `sigma` px: radius ceil(3 sigma),
// float weights normalised by their double sum. Empty below sigma 0.3, where
// the stage does not blur.
std::vector<float> gaussian_taps(double sigma);

// Two passes of `taps` (odd, centred), along rows then columns, edges
// extended. In place; `threads` 0 is the machine's count.
void gaussian_blur(std::vector<float>& img, int w, int h, const std::vector<float>& taps, unsigned threads = 0);

// One face, read whole and kept: stb_truetype reads the bytes it was handed
// for as long as the face is used.
class Font {
public:
    bool load(const std::string& path, std::string& error);
    bool loaded() const { return bool(impl_); }
    int glyph(uint32_t codepoint) const;            // 0 (.notdef) when absent
    double units_per_em() const;
    double advance(int glyph) const;                // font units
    double kern(int left, int right) const;         // font units, from 'kern' or GPOS pairs
    double cap_height() const;                      // font units: the top of 'H'
    // The glyph's contours (font units, y up), each point mapped by `m`.
    void outline(int glyph, const Affine& m, double tol, Path& out) const;

private:
    struct Impl;
    std::shared_ptr<const Impl> impl_;
};

// UTF-8 to code points; a malformed byte stands for itself (Latin-1).
std::vector<uint32_t> utf8_codepoints(const std::string& text);

}  // namespace spk::edge_raster
#endif  // !__APPLE__
