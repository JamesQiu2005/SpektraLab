// spk_desktop_pair_test -- the Windows host's half-frame pair without a GPU or
// a RAW (desktop/half_frame_pair.hpp, preview_host.hpp wire_params): the
// piece's layout against the engine's 19 mm advance, the placement gestures
// (Session.placement(_:draggedBy:), (_:zoomedBy:about:)), the composition on
// synthetic pictures (each in its own hole, turned, placed and exposed; the
// gap black), the gates from a strip's geometry, and what a pair puts on the
// wire (overscan_pair, its second date, its second curve past the split).
#include "desktop/half_frame_pair.hpp"
#include "desktop/preview_host.hpp"

#include <cmath>
#include <cstdio>
#include <string>

using namespace spk::desktop;

namespace {
int failures = 0;
void check(bool ok, const std::string& what, const std::string& detail = {}) {
    std::printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.empty() ? "" : " -- ", detail.c_str());
    if (!ok) ++failures;
}
bool near(double a, double b, double tol = 1e-9) { return std::abs(a - b) <= tol; }
std::string fmt(const char* f, double a, double b = 0, double c = 0, double d = 0) {
    char buf[256];
    std::snprintf(buf, sizeof buf, f, a, b, c, d);
    return buf;
}
// A picture whose every pixel says where it is: R = x, G = y (pixel centres,
// normalised), B a constant.
PairPicture ramp(std::uint32_t w, std::uint32_t h, float b) {
    PairPicture p{w, h, std::vector<float>(std::size_t(w) * h * 3)};
    for (std::uint32_t y = 0; y < h; ++y)
        for (std::uint32_t x = 0; x < w; ++x) {
            float* q = p.rgb.data() + (std::size_t(y) * w + x) * 3;
            q[0] = (x + 0.5f) / w;
            q[1] = (y + 0.5f) / h;
            q[2] = b;
        }
    return p;
}
const float* at(const std::vector<float>& rgb, std::uint32_t w, std::uint32_t x, std::uint32_t y) {
    return rgb.data() + (std::size_t(y) * w + x) * 3;
}
}  // namespace

int main() {
    // --- the layout: two 18 x 24 holes, the second one advance along -------
    {
        const PairLayout l = pair_layout(2400, 1.0, false);
        check(l.hole_w == 1800 && l.hole_h == 2400 && l.advance == 1900 && l.width() == 3700 && l.height() == 2400,
              "level: holes 18 x 24, the second 19 mm along, a 37 x 24 piece",
              fmt("hole %.0f x %.0f, advance %.0f, piece width %.0f", l.hole_w, l.hole_h, l.advance, l.width()));
        const PairLayout t = pair_layout(2400, 1.0, true);
        check(t.hole_w == 2400 && t.hole_h == 1800 && t.width() == 2400 && t.height() == 3700 &&
                  t.rect(1).y == 1900 && t.rect(1).x == 0,
              "turned: the holes stacked, the film running down the piece");
        check(near(pair_split(l), (1800.0 + 1900.0) / 2 / 3700.0), "the split is the middle of the gap",
              fmt("%.6f", pair_split(l)));
        check(near(pair_piece_mm(1.0), 37.0) && near(pair_hole_aspect(false), 0.75) && near(pair_hole_aspect(true), 4.0 / 3),
              "the piece is 37 mm long on a strip; the hole 3:4, 4:3 turned");
        const PairLayout wide = pair_layout(2400, 2.0, false);
        check(wide.advance == 2000 && wide.hole_w == 1800, "a wider gap moves the second hole, not the holes' size");
        // The engine's own test lays the second picture at lround(19 / (18 / w)).
        const PairLayout engine = pair_layout(600, 1.0, false);
        check(engine.hole_w == 450 && engine.advance == std::uint32_t(std::lround(19.0 / (18.0 / 450))),
              "the advance is the engine's 19.00 mm (film_edge_render's pair)");
        check(l.normalised(1).contains(0.75, 0.5) && !l.normalised(0).contains(0.75, 0.5) &&
                  !l.normalised(0).contains(0.495, 0.5) && !l.normalised(1).contains(0.495, 0.5),
              "a point in the gap is in neither hole");
    }

    // --- the source rectangle and the gestures ------------------------------
    {
        const double aspect = 0.75;
        PairPlacement fit;
        const PairRect r = pair_source_rect(fit, 6000, 4000, aspect);
        check(near(r.w, 3000) && near(r.h, 4000) && near(r.x, 1500) && near(r.y, 0),
              "a landscape picture fills a portrait hole at its middle", fmt("%.1f %.1f %.1f %.1f", r.x, r.y, r.w, r.h));
        PairPlacement left;
        left.x = -1;
        check(near(pair_source_rect(left, 6000, 4000, aspect).x, 0), "x -1 is the picture's left edge");
        // A drag to the right by a tenth of the hole moves the picture right:
        // the cut moves left by a tenth of its width.
        const PairPlacement dragged = pair_placement_dragged(fit, 0.1, 0.0, 6000, 4000, aspect);
        const PairRect d = pair_source_rect(dragged, 6000, 4000, aspect);
        check(near(d.x, 1500 - 300, 1e-6) && near(dragged.y, 0), "a drag moves the picture with the pointer",
              fmt("cut x %.2f", d.x));
        const PairPlacement far = pair_placement_dragged(fit, 5.0, 5.0, 6000, 4000, aspect);
        check(far.x == -1 && far.y == 0, "a drag stops at the picture's edge (no slack across: y stays)");
        // Zoom about a point keeps what is under it there.
        const double ax = 0.25, ay = 0.4;
        const PairPlacement z = pair_placement_zoomed(fit, 2.0, ax, ay, 6000, 4000, aspect);
        const PairRect zr = pair_source_rect(z, 6000, 4000, aspect);
        const double before_x = r.x + ax * r.w, before_y = r.y + ay * r.h;
        const double after_x = zr.x + ax * zr.w, after_y = zr.y + ay * zr.h;
        check(near(z.scale, 2) && near(before_x, after_x, 1e-6) && near(before_y, after_y, 1e-6),
              "a zoom about the pointer keeps the point under it", fmt("%.3f,%.3f -> %.3f,%.3f", before_x, before_y, after_x, after_y));
        check(pair_placement_zoomed(fit, 0.5, 0.5, 0.5, 6000, 4000, aspect) == fit, "the picture never shrinks below the hole");
        check(near(pair_placement_zoomed(fit, 100, 0.5, 0.5, 6000, 4000, aspect).scale, kPlacementScaleMax), "nor grows past 4x");
        const PairMotion m = pair_motion(fit, z, 6000, 4000, aspect);
        check(near(m.scale, 2) && near(ax * m.scale + m.offset_x, ax, 1e-9) && near(ay * m.scale + m.offset_y, ay, 1e-9),
              "the gesture's motion maps the anchor onto itself");
        PairPlacement turned;
        turned.quarter_turns = 1;
        double tw = 0, th = 0;
        pair_turned_size(turned, 6000, 4000, tw, th);
        check(tw == 4000 && th == 6000, "a quarter turn swaps the picture's sides");
    }

    // --- composition ----------------------------------------------------------
    {
        // Landscape frames long enough that the piece (37:24) needs no
        // reduction: each hole is the picture's own middle 300 x 400.
        const PairPicture a = ramp(640, 400, 0.25f), b = ramp(640, 400, 0.75f);
        std::array<PairPlacement, 2> placements{};
        const PairLayout l = pair_layout_for({&a, &b}, placements, 1.0, false);
        check(l.hole_h == 400 && l.hole_w == 300, "two frames fill their holes at their own size",
              fmt("hole %.0f x %.0f", l.hole_w, l.hole_h));
        const PairPicture portrait = ramp(300, 400, 0.5f);
        check(pair_layout_for({&portrait, &portrait}, placements, 1.0, false).hole_h == 259,
              "the piece is never longer than the longer picture (400 px: holes 259 px across)");
        const auto piece = compose_pair(l, {&a, &b}, placements, {0.0, 1.0});
        const std::uint32_t W = l.width();
        const float* first = at(piece, W, 10, 200);
        const float* second = at(piece, W, l.advance + 10, 200);
        const float* gap = at(piece, W, 300 + (l.advance - 300) / 2, 200);
        check(near(first[2], 0.25, 1e-5) && near(second[2], 1.5, 1e-5),
              "each hole holds its own picture, the second exposed one stop up", fmt("%.4f / %.4f", first[2], second[2]));
        check(gap[0] == 0 && gap[1] == 0 && gap[2] == 0, "the gap between the holes is unexposed (black)");
        check(near(first[0], (170 + 10 + 0.5) / 640.0, 1e-4) && near(first[1], (200 + 0.5) / 400.0, 1e-4),
              "a filled hole is the picture's own pixels, unscaled", fmt("%.5f %.5f", first[0], first[1]));
        // An empty hole is black too.
        const auto alone = compose_pair(l, {&a, nullptr}, placements, {0.0, 0.0});
        const float* empty = at(alone, W, l.advance + 150, 200);
        check(empty[0] == 0 && empty[2] == 0, "an empty hole is unexposed film");
        // A quarter turn: the picture's top edge is on the hole's right.
        const PairPicture land = ramp(400, 300, 0.5f);
        std::array<PairPlacement, 2> turn{};
        turn[0].quarter_turns = 1;
        const PairLayout lt = pair_layout_for({&land, nullptr}, turn, 1.0, false);
        const auto turned = compose_pair(lt, {&land, nullptr}, turn, {0.0, 0.0});
        const float* right_edge = at(turned, lt.width(), lt.hole_w - 1, lt.hole_h / 2);
        check(right_edge[1] < 0.05, "turned clockwise, the picture's top is at the hole's right",
              fmt("G (the source's y) %.3f at the right edge", right_edge[1]));
        // Scaled 2x about the middle: the hole shows the middle half.
        std::array<PairPlacement, 2> zoom{};
        zoom[0].scale = 2;
        const auto zoomed = compose_pair(l, {&a, nullptr}, zoom, {0.0, 0.0});
        const float* corner = at(zoomed, W, 0, 0);
        check(near(corner[0], 245.0 / 640, 0.01) && near(corner[1], 0.25, 0.01),
              "scaled 2x about the middle, the hole's corner is a quarter of the cut in",
              fmt("%.3f %.3f", corner[0], corner[1]));
        // A large picture is reduced, never enlarged; the piece is never longer
        // than the longer picture.
        const PairPicture big = ramp(1200, 1600, 0.5f), small = ramp(300, 400, 0.5f);
        const PairLayout mixed = pair_layout_for({&big, &small}, placements, 1.0, false);
        check(mixed.hole_h == 400, "the holes are as large as the smaller picture across its hole");
        const PairPicture wide = ramp(6000, 4000, 0.5f);
        const PairLayout capped = pair_layout_for({&wide, &wide}, placements, 1.0, false);
        check(capped.width() <= 6000 + 2, "two half frames are one frame's worth: the piece is no longer than the picture",
              fmt("piece %.0f px for a %.0f px picture", capped.width(), 6000));
    }

    // --- the gates of a strip -------------------------------------------------
    {
        const std::string geometry =
            "{\"valid\":true,\"gates\":[[0.55,0.1,0.95,0.1,0.95,0.9,0.55,0.9],[0.05,0.1,0.45,0.1,0.45,0.9,0.05,0.9]]}";
        std::array<PairRect, 2> gates;
        check(pair_gate_rects(geometry, false, gates) && near(gates[0].x, 0.05) && near(gates[1].x, 0.55) &&
                  near(gates[0].w, 0.4) && near(gates[1].h, 0.8),
              "the gates are read in film order");
        check(!pair_gate_rects("{\"valid\":false}", false, gates), "no strip, no gates");
    }

    // --- the wire -------------------------------------------------------------
    {
        const Catalog catalog;
        RenderSettings s;
        s.film_format_mm = 37;
        PhotoInfo photo;
        photo.pair.active = true;
        photo.pair.split = 0.5;
        photo.pair.second.year = 2026;
        photo.pair.second.month = 10;
        photo.pair.second.day = 3;
        photo.shooting.year = 2026;
        photo.shooting.month = 10;
        photo.shooting.day = 1;
        photo.pair.latitude_b.active = true;
        photo.pair.latitude_b.highlight_room = 1.5;
        const auto plain = wire_params(s, catalog, &photo);
        check(!plain.has("overscan_pair") || !plain.at("overscan_pair").as_bool(),
              "no film edge and no date: the piece is just the frame");
        check(near(plain.at("scene_latitude_split").as_double(), 0.5) && plain.at("scene_latitude_b_active").as_bool() &&
                  near(plain.at("scene_latitude_b_highlight_room").as_double(), 1.5),
              "the second frame's Scene Placement rides past the split");
        RenderSettings edged = s;
        edged.set("overscan_active", true);
        edged.set("overscan_format", std::string("135"));
        const auto strip = wire_params(edged, catalog, &photo);
        check(strip.at("overscan_pair").as_bool() && strip.at("overscan_format").as_string() == "135_half",
              "with a film edge the pair is 135 half exposed twice");
        RenderSettings dated = s;
        dated.set("date_imprint_active", true);
        const auto date = wire_params(dated, catalog, &photo);
        check(date.at("date_imprint_active").as_bool() && date.at("overscan_pair").as_bool() &&
                  date.at("overscan_format").as_string() == "135_half" && date.at("date_imprint_text").as_string() == "'26 10 1" &&
                  date.at("date_imprint_text_b").as_string() == "'26 10 3",
              "the date alone: each frame carries its own date on a half-frame back",
              date.at("date_imprint_text").as_string() + " / " + date.at("date_imprint_text_b").as_string());
        PhotoInfo other = photo;
        other.pair.latitude_b.highlight_room = 2.5;
        const auto delta = changed_params(s, s, catalog, photo, other);
        check(delta.fields().size() == 1 && near(delta.at("scene_latitude_b_highlight_room").as_double(), 2.5),
              "a change of the second curve alone is a one-field delta");
        PhotoInfo frame;
        check(!wire_params(s, catalog, &frame).has("scene_latitude_split"), "a frame carries no pair fields");
        RenderSettings cutting = s;
        cutting.set("overscan_active", true);
        check(!cuts_frame(cutting, photo), "a pair's piece is never cut (it is the gate's shape)");
    }

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
