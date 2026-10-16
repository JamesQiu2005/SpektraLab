#include "half_frame_pair.hpp"

#include "core/json.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <thread>

namespace spk::desktop {

PairPlacement clamped(PairPlacement p) {
    p.scale = std::isfinite(p.scale) ? std::clamp(p.scale, kPlacementScaleMin, kPlacementScaleMax) : 1.0;
    p.x = std::isfinite(p.x) ? std::clamp(p.x, -1.0, 1.0) : 0.0;
    p.y = std::isfinite(p.y) ? std::clamp(p.y, -1.0, 1.0) : 0.0;
    p.quarter_turns = ((p.quarter_turns % 4) + 4) % 4;
    return p;
}

PairRect PairLayout::rect(int side) const {
    const double d = side == 0 ? 0.0 : double(advance);
    return {turned ? 0.0 : d, turned ? d : 0.0, double(hole_w), double(hole_h)};
}

PairRect PairLayout::normalised(int side) const {
    const PairRect r = rect(side);
    const double w = std::max(1u, width()), h = std::max(1u, height());
    return {r.x / w, r.y / h, r.w / w, r.h / h};
}

PairLayout pair_layout(std::uint32_t across, double spacing_mm, bool turned) {
    // HalfFramePair.layout (HalfFramePair.swift:219-225).
    const std::uint32_t a = std::max(across, 8u);
    const std::uint32_t along = std::max<std::uint32_t>(std::uint32_t(std::lround(double(a) * kHoleAlongMM / kHoleAcrossMM)), 6u);
    const double spacing = std::isfinite(spacing_mm) ? spacing_mm : kPairStripSpacing;
    const std::uint32_t advance = std::uint32_t(std::lround(double(along) * (kHoleAlongMM + spacing) / kHoleAlongMM));
    PairLayout l;
    l.hole_w = turned ? a : along;
    l.hole_h = turned ? along : a;
    l.advance = advance;
    l.turned = turned;
    return l;
}

double pair_hole_aspect(bool turned) {
    return turned ? kHoleAcrossMM / kHoleAlongMM : kHoleAlongMM / kHoleAcrossMM;
}

double pair_split(const PairLayout& l) {
    // The middle of the gap (Session+FilmEdge.swift:290-295).
    const PairRect a = l.normalised(0), b = l.normalised(1);
    return l.turned ? (a.y + a.h + b.y) / 2.0 : (a.x + a.w + b.x) / 2.0;
}

double pair_piece_mm(double spacing_mm) { return 2.0 * kHoleAlongMM + spacing_mm; }

void pair_turned_size(const PairPlacement& p, double w, double h, double& tw, double& th) {
    const bool odd = (((p.quarter_turns % 4) + 4) % 4) % 2 == 1;
    tw = odd ? h : w;
    th = odd ? w : h;
}

PairRect pair_source_rect(const PairPlacement& placement, double sw, double sh, double aspect) {
    // HalfFramePair.sourceRect (HalfFramePair.swift:232-242).
    if (!(sw > 0) || !(sh > 0) || !(aspect > 0)) return {};
    double w = sw, h = sh;
    if (w / h > aspect) w = h * aspect; else h = w / aspect;
    const PairPlacement p = clamped(placement);
    w /= p.scale;
    h /= p.scale;
    const double cx = sw / 2 + p.x * (sw - w) / 2;
    const double cy = sh / 2 + p.y * (sh - h) / 2;
    return {cx - w / 2, cy - h / 2, w, h};
}

PairPlacement pair_placement_dragged(const PairPlacement& origin, double dx, double dy, double source_w,
                                     double source_h, double aspect) {
    // Session.placement(_:draggedBy:) (Session.swift:4559-4568): the picture
    // follows the pointer, so the cut moves the other way.
    double tw = 0, th = 0;
    pair_turned_size(origin, source_w, source_h, tw, th);
    const PairRect cut = pair_source_rect(origin, tw, th, aspect);
    PairPlacement p = clamped(origin);
    const double slack_x = (tw - cut.w) / 2, slack_y = (th - cut.h) / 2;
    if (slack_x > 0.5 && std::isfinite(dx)) p.x = std::clamp(p.x - dx * cut.w / slack_x, -1.0, 1.0);
    if (slack_y > 0.5 && std::isfinite(dy)) p.y = std::clamp(p.y - dy * cut.h / slack_y, -1.0, 1.0);
    return p;
}

PairPlacement pair_placement_zoomed(const PairPlacement& origin, double factor, double ax, double ay,
                                    double source_w, double source_h, double aspect) {
    // Session.placement(_:zoomedBy:about:) (Session.swift:4574-4591).
    double tw = 0, th = 0;
    pair_turned_size(origin, source_w, source_h, tw, th);
    const PairRect was = pair_source_rect(origin, tw, th, aspect);
    PairPlacement p = clamped(origin);
    const double from = p.scale;
    if (!std::isfinite(factor) || factor <= 0) return p;
    p.scale = std::clamp(from * factor, kPlacementScaleMin, kPlacementScaleMax);
    if (p.scale == from || was.w <= 0 || was.h <= 0) return clamped(origin);
    ax = std::clamp(std::isfinite(ax) ? ax : 0.5, 0.0, 1.0);
    ay = std::clamp(std::isfinite(ay) ? ay : 0.5, 0.0, 1.0);
    const double w = was.w * from / p.scale, h = was.h * from / p.scale;
    const double cx = was.x + ax * was.w - ax * w + w / 2;
    const double cy = was.y + ay * was.h - ay * h + h / 2;
    const double slack_x = (tw - w) / 2, slack_y = (th - h) / 2;
    p.x = slack_x > 0.5 ? std::clamp((cx - tw / 2) / slack_x, -1.0, 1.0) : 0.0;
    p.y = slack_y > 0.5 ? std::clamp((cy - th / 2) / slack_y, -1.0, 1.0) : 0.0;
    return p;
}

PairMotion pair_motion(const PairPlacement& from, const PairPlacement& to, double source_w, double source_h,
                       double aspect) {
    double tw = 0, th = 0;
    pair_turned_size(from, source_w, source_h, tw, th);
    const PairRect a = pair_source_rect(from, tw, th, aspect);
    double tw2 = 0, th2 = 0;
    pair_turned_size(to, source_w, source_h, tw2, th2);
    // Across a turn there is no motion to draw: the new picture is another one.
    if (tw2 != tw || th2 != th || (((from.quarter_turns - to.quarter_turns) % 4) + 4) % 4 != 0) return {};
    const PairRect b = pair_source_rect(to, tw, th, aspect);
    if (a.w <= 0 || b.w <= 0 || b.h <= 0) return {};
    // A source point p sits at u0 = (p - a.min) / a.size before and at
    // u1 = (p - b.min) / b.size after: u1 = u0 * a.size / b.size + (a.min - b.min) / b.size.
    return {a.w / b.w, (a.x - b.x) / b.w, (a.y - b.y) / b.h};
}

PairLayout pair_layout_for(const std::array<const PairPicture*, 2>& pictures,
                           const std::array<PairPlacement, 2>& placements, double spacing_mm, bool turned) {
    // PairComposer.layout (PairComposer.swift:88-111).
    const double aspect = pair_hole_aspect(turned);
    double across = 0, longest = 0;
    bool any = false;
    for (int side = 0; side < 2; ++side) {
        const PairPicture* picture = pictures[side];
        if (!picture || !picture->width || !picture->height) continue;
        // At the picture's own fit, whatever it is zoomed to: a zoom must not
        // resize the piece.
        PairPlacement fit = placements[side];
        fit.scale = 1;
        double tw = 0, th = 0;
        pair_turned_size(fit, picture->width, picture->height, tw, th);
        const PairRect cut = pair_source_rect(fit, tw, th, aspect);
        const double a = turned ? cut.w : cut.h;
        across = any ? std::min(across, a) : a;
        any = true;
        longest = std::max({longest, double(picture->width), double(picture->height)});
    }
    double a = any ? across : 2400.0;
    if (longest > 0) {
        // At the camera's own 1 mm whatever the spacing, so a hole's size does
        // not move with the gap.
        const double piece_long = (kHoleAlongMM * 2 + kPairStripSpacing) / kHoleAcrossMM;
        a = std::min(a, longest / piece_long);
    }
    return pair_layout(std::uint32_t(std::max(0.0, std::floor(a))), spacing_mm, turned);
}

namespace {
// Bilinear sample of a packed RGB picture at a continuous point (pixel
// centres at +0.5), clamped to the picture.
inline void sample(const PairPicture& p, double x, double y, float* out) {
    const double fx = std::clamp(x - 0.5, 0.0, double(p.width - 1));
    const double fy = std::clamp(y - 0.5, 0.0, double(p.height - 1));
    const std::uint32_t x0 = std::uint32_t(fx), y0 = std::uint32_t(fy);
    const std::uint32_t x1 = std::min(x0 + 1, p.width - 1), y1 = std::min(y0 + 1, p.height - 1);
    const double ax = fx - x0, ay = fy - y0;
    const float* a = p.rgb.data() + (std::size_t(y0) * p.width + x0) * 3;
    const float* b = p.rgb.data() + (std::size_t(y0) * p.width + x1) * 3;
    const float* c = p.rgb.data() + (std::size_t(y1) * p.width + x0) * 3;
    const float* d = p.rgb.data() + (std::size_t(y1) * p.width + x1) * 3;
    for (int k = 0; k < 3; ++k)
        out[k] = float((a[k] + (b[k] - a[k]) * ax) * (1 - ay) + (c[k] + (d[k] - c[k]) * ax) * ay);
}
// A point of the picture turned clockwise by `turns`, back in the picture
// before the turns (continuous coordinates).
inline void unturn(int turns, double pw, double ph, double tx, double ty, double& px, double& py) {
    switch (turns) {
    case 1: px = ty; py = ph - tx; break;
    case 2: px = pw - tx; py = ph - ty; break;
    case 3: px = pw - ty; py = tx; break;
    default: px = tx; py = ty; break;
    }
}
}  // namespace

std::vector<float> compose_pair(const PairLayout& layout, const std::array<const PairPicture*, 2>& pictures,
                                const std::array<PairPlacement, 2>& placements,
                                const std::array<double, 2>& gain_ev) {
    const std::uint32_t W = layout.width(), H = layout.height();
    if (!W || !H) throw std::runtime_error("Half-frame pair: empty layout");
    std::vector<float> out(std::size_t(W) * H * 3, 0.0f);
    const double aspect = pair_hole_aspect(layout.turned);
    for (int side = 0; side < 2; ++side) {
        const PairPicture* picture = pictures[side];
        if (!picture || !picture->width || !picture->height ||
            picture->rgb.size() != std::size_t(picture->width) * picture->height * 3)
            continue;
        const PairPlacement p = clamped(placements[side]);
        double tw = 0, th = 0;
        pair_turned_size(p, picture->width, picture->height, tw, th);
        const PairRect cut = pair_source_rect(p, tw, th, aspect);
        const PairRect hole = layout.rect(side);
        const std::uint32_t hx = std::uint32_t(hole.x), hy = std::uint32_t(hole.y);
        const std::uint32_t hw = std::uint32_t(hole.w), hh = std::uint32_t(hole.h);
        if (!hw || !hh || cut.w <= 0 || cut.h <= 0) continue;
        const double step_x = cut.w / hw, step_y = cut.h / hh;
        // A strong reduction averages a few samples per output pixel rather
        // than aliasing (the piece is at most the size of its pictures, so
        // this is a few percent at most for a RAW, more for a small one).
        const int taps = std::clamp(int(std::ceil(std::max(step_x, step_y) - 1e-9)), 1, 4);
        const float gain = float(std::exp2(std::isfinite(gain_ev[side]) ? std::clamp(gain_ev[side], -12.0, 12.0) : 0.0));
        const auto rows = [&](std::uint32_t y0, std::uint32_t y1) {
            for (std::uint32_t v = y0; v < y1; ++v)
                for (std::uint32_t u = 0; u < hw; ++u) {
                    double acc[3] = {};
                    for (int j = 0; j < taps; ++j)
                        for (int i = 0; i < taps; ++i) {
                            const double tx = cut.x + (u + (i + 0.5) / taps) * step_x;
                            const double ty = cut.y + (v + (j + 0.5) / taps) * step_y;
                            double px = 0, py = 0;
                            unturn(p.quarter_turns, picture->width, picture->height, tx, ty, px, py);
                            float s[3];
                            sample(*picture, px, py, s);
                            for (int k = 0; k < 3; ++k) acc[k] += s[k];
                        }
                    float* dst = out.data() + (std::size_t(hy + v) * W + hx + u) * 3;
                    for (int k = 0; k < 3; ++k) dst[k] = float(acc[k] / (taps * taps)) * gain;
                }
        };
        const std::uint32_t workers = std::clamp(std::thread::hardware_concurrency(), 1u, 8u);
        const std::uint32_t band = (hh + workers - 1) / workers;
        std::vector<std::thread> threads;
        for (std::uint32_t i = 0; i < workers; ++i) {
            const std::uint32_t y0 = i * band, y1 = std::min(hh, y0 + band);
            if (y0 < y1) threads.emplace_back(rows, y0, y1);
        }
        for (auto& t : threads) t.join();
    }
    return out;
}

bool pair_gate_rects(const std::string& overscan_geometry, bool turned, std::array<PairRect, 2>& out) {
    Json reply;
    std::string error;
    if (!Json::parse(overscan_geometry, reply, error) || !reply.at("valid").as_bool()) return false;
    const auto& gates = reply.at("gates").items();
    if (gates.size() != 2) return false;
    std::array<PairRect, 2> found;
    for (std::size_t g = 0; g < 2; ++g) {
        const auto& quad = gates[g].items();
        if (quad.size() != 8) return false;
        double x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        for (int i = 0; i < 4; ++i) {
            const double x = quad[2 * i].as_double(), y = quad[2 * i + 1].as_double();
            x0 = std::min(x0, x); x1 = std::max(x1, x);
            y0 = std::min(y0, y); y1 = std::max(y1, y);
        }
        found[g] = {x0, y0, x1 - x0, y1 - y0};
    }
    if (turned ? found[1].y < found[0].y : found[1].x < found[0].x) std::swap(found[0], found[1]);
    out = found;
    return true;
}

}  // namespace spk::desktop
