// overscan_raster.hpp -- the seam between the imprint layout in overscan.cpp
// and the 2-D rasteriser that turns it into coverage (RFC-031, RFC-032 §27).
//
// overscan.cpp lays every mark out in film millimetres as `Op`s. Turning one
// group of them into a canvas-aligned coverage bitmap, and measuring a
// Helvetica-family string, are the only two things in the stage that need a
// graphics library, so they are the whole of this interface:
//
//   macOS      overscan_raster_apple.cpp -- CoreGraphics, CoreText, vImage,
//              moved out of overscan.cpp unchanged, so the Mac's output is
//              the same bytes it was.
//   elsewhere  overscan_raster_portable.cpp -- edge_raster.hpp (an exact-area
//              scanline filler, CGBitmapContext's 8-bit source-over, a
//              separable Gaussian with vImage's edge extension) and
//              stb_truetype outlines of the bundled TeX Gyre Heros faces
//              (engine/resources_portable/fonts/NOTICE.md).
#pragma once
#include <string>
#include <vector>

#include "pipeline.hpp"

namespace spk::imprint {

// --- imprint drawing ops, in film millimetres (s along, t across, t down) ----
struct Op {
    enum Kind { Text, Poly, Circle } kind = Text;   // Circle: pts = {s, t}, radius = size_mm
    std::string text;
    const char* font = "HelveticaNeue-Bold";
    double size_mm = 1.0;       // font size (em), mm
    double s = 0, t = 0;        // baseline start (Text) in film mm
    double rot_deg = 0;         // about (s, t)
    double tracking_mm = 0;
    double skew = 0;            // horizontal shear (seven-segment slant)
    double hscale = 1.0;        // Text: glyphs widened along the baseline (Kodak's wide numerals)
    // Text: `hscale` widens the glyphs' shapes only -- CoreText places them at
    // their own advances, so widened letters close up on each other. With this
    // set the whole line is scaled, advances and tracking with it, and the
    // string is `hscale` times as long (Kodak 120's extended face).
    bool scale_advances = false;
    std::vector<double> pts;    // Poly: s0,t0,s1,t1,... in film mm
    double gain = 1.0;          // this mark's share of the group's exposure (printing variance)
};

struct Group {
    std::vector<Op> ops;
    double exposure[3] = {0, 0, 0};   // raw exposure at full coverage, per layer
    double blur_mm = 0.0;
};

// Film (s, t) mm -> canvas pixels: the inverse of the layout's canvas -> film.
void film_to_canvas_px(const OverscanLayout& L, double s, double t, double& x, double& y);

// The canvas box a group's coverage occupies, from each op's film-space
// extent (generous for text) plus the blur's reach, clipped to the canvas.
// False when nothing of it lands on the canvas.
bool group_bounds(const OverscanLayout& L, const Group& g, int& x0, int& y0, int& w, int& h);

// Rasterise one group into a canvas-aligned coverage bitmap (its bounding
// box), blurred by the group's `blur_mm`. False with `error` empty: nothing to
// draw, and the caller skips the group. False with `error` set: the group
// cannot be drawn (a face the portable build has no font for), and the render
// must fail rather than lose the mark.
bool rasterise(const OverscanLayout& L, const Group& g, std::vector<float>& cov, int& x0, int& y0, int& w,
               int& h, std::string& error);

// A Helvetica-family string's advance in film mm, as CoreText lays it out.
double text_width(const char* font, double size_mm, const std::string& text, double tracking_mm, double hscale);

#ifndef __APPLE__
// Where the portable build's faces are: `<resources>/fonts`, set by
// spk_engine_create. One directory per process -- the faces are immutable
// data, and every engine a process opens reads the same resources. Fonts are
// read on first use; changing the directory drops what was read.
void set_font_directory(const std::string& dir);
#endif

}  // namespace spk::imprint
