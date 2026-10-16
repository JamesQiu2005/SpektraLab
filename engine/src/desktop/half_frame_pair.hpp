// half_frame_pair.hpp -- two half frames on one frame's worth of 135, as the
// engine is handed them: the macOS app's HalfFramePair (Model/HalfFramePair
// .swift) and PairComposer (Import/PairComposer.swift), for the Windows host.
//
// A pair is two pictures laid on 37 mm of film: each under its 18 x 24 hole,
// the second one advance (18 mm + the gap) along, the gap and an empty hole
// black -- no light reached them, and the engine develops them to the stock's
// own base. The piece is then an ordinary frame for the engine
// (API-SPEC "overscan_pair": the input carries both pictures at the gate's
// height, the second starting 19.00 mm along). Held level the holes are side
// by side and portrait; turned (a landscape camera) they are stacked.
//
// Everything here is arithmetic on plain pixels -- no engine, no RAW -- so the
// layout, the placement gestures and the composition are tested without a GPU
// (spk_desktop_pair_test). The host decodes each frame and calls compose_pair
// (preview_host.cpp PreviewHost::render_pair).
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace spk::desktop {

// One hole, held level: 18 mm along the film, 24 mm across it.
inline constexpr double kHoleAlongMM = 18.0, kHoleAcrossMM = 24.0;
// The unexposed film between the holes, mm (HalfFramePair.spacingRange). A
// real camera's advance of four perforations leaves 1.00, which is what a
// strip (Film Edge on) always uses.
inline constexpr double kPairSpacingMin = 0.5, kPairSpacingMax = 2.0, kPairStripSpacing = 1.0;
// How far a picture may be enlarged under its hole (Placement.scaleRange):
// 1 fills the hole and it never goes below, so no base shows in a filled hole.
inline constexpr double kPlacementScaleMin = 1.0, kPlacementScaleMax = 4.0;

// A rectangle, top-left origin, y down: pixels or normalised to a frame.
struct PairRect {
    double x = 0, y = 0, w = 0, h = 0;
    bool contains(double px, double py) const { return px >= x && py >= y && px <= x + w && py <= y + h; }
    bool operator==(const PairRect&) const = default;
};

// Where a picture sits under its hole (HalfFramePair.Placement). The hole
// never moves; the picture does. x and y are -1..1 across the slack the fit
// leaves; quarter turns are clockwise, applied before the fit.
struct PairPlacement {
    double scale = 1.0, x = 0.0, y = 0.0;
    int quarter_turns = 0;
    bool operator==(const PairPlacement&) const = default;
};
// The placement within its ranges, the turns 0..3.
PairPlacement clamped(PairPlacement placement);

// The piece in pixels (HalfFramePair.Layout): two holes `hole_w` x `hole_h`,
// the second `advance` along the film -- across the piece held level, down it
// when turned. Side 0 is the first hole (left, or upper when turned).
struct PairLayout {
    std::uint32_t hole_w = 0, hole_h = 0, advance = 0;
    bool turned = false;
    std::uint32_t width() const { return turned ? hole_w : advance + hole_w; }
    std::uint32_t height() const { return turned ? advance + hole_h : hole_h; }
    PairRect rect(int side) const;         // pixels
    PairRect normalised(int side) const;   // 0..1 of the piece
    bool operator==(const PairLayout&) const = default;
};
// Holes `across` pixels across the film (their height held level, their width
// turned), `spacing_mm` apart (HalfFramePair.layout).
PairLayout pair_layout(std::uint32_t across, double spacing_mm, bool turned);
// A hole's width over its height: 18:24 level, 24:18 turned.
double pair_hole_aspect(bool turned);
// The middle of the gap along the piece's long edge, as a fraction of it:
// where the second frame's Scene Placement takes over (scene_latitude_split,
// Session+FilmEdge.swift resolved()).
double pair_split(const PairLayout& layout);
// The piece's long edge in mm, as film_format_mm takes it: both holes and the
// gap between them (37 mm for a strip's 1 mm).
double pair_piece_mm(double spacing_mm);

// A picture's size after the placement's quarter turns.
void pair_turned_size(const PairPlacement& placement, double width, double height, double& turned_w,
                      double& turned_h);
// The rectangle of the (already turned) source that fills a hole of `aspect`
// (width / height) at this placement, in source pixels (sourceRect).
PairRect pair_source_rect(const PairPlacement& placement, double source_w, double source_h, double aspect);

// The placement gestures (Session.placement(_:draggedBy:) and
// (_:zoomedBy:about:)), on a picture `source_w` x `source_h` before its turns.
// A drag of (dx, dy) fractions of the hole moves the picture with the pointer;
// a zoom by `factor` about (ax, ay) -- a point of the hole, 0..1 -- keeps what
// is under the anchor there while the picture still covers the hole.
PairPlacement pair_placement_dragged(const PairPlacement& origin, double dx, double dy, double source_w,
                                     double source_h, double aspect);
PairPlacement pair_placement_zoomed(const PairPlacement& origin, double factor, double ax, double ay,
                                    double source_w, double source_h, double aspect);
// How the hole's picture moves from `from` to `to`, for drawing a gesture
// before its develop lands: a point at u (0..1 of the hole) under `from` is
// at u * scale + offset under `to`.
struct PairMotion {
    double scale = 1.0, offset_x = 0.0, offset_y = 0.0;
};
PairMotion pair_motion(const PairPlacement& from, const PairPlacement& to, double source_w, double source_h,
                       double aspect);

// A picture as the composer takes it: packed top-down linear RGB floats.
struct PairPicture {
    std::uint32_t width = 0, height = 0;
    std::vector<float> rgb;
};

// The layout for these pictures (PairComposer.layout): the holes as large as
// the smaller picture is across its hole at its own fit, so neither is
// enlarged, and the piece never longer than the longer picture. An empty pair
// takes a nominal 2400 px. A null picture is an empty hole.
PairLayout pair_layout_for(const std::array<const PairPicture*, 2>& pictures,
                           const std::array<PairPlacement, 2>& placements, double spacing_mm, bool turned);

// The piece: each picture turned, cut to its placement's rectangle and scaled
// into its hole, multiplied by 2^gain_ev (PairComposer.exposed: the engine's
// meter is exactly this gain on the frame it is handed); the gap and an empty
// hole are 0. Returns width x height x 3 floats.
std::vector<float> compose_pair(const PairLayout& layout, const std::array<const PairPicture*, 2>& pictures,
                                const std::array<PairPlacement, 2>& placements,
                                const std::array<double, 2>& gain_ev);

// The two gates of a strip render, normalised to the frame and in film order
// (left to right held level, top to bottom turned), from spk_overscan_geometry's
// reply: each gate quad's bounding box. False when the reply has no two gates.
bool pair_gate_rects(const std::string& overscan_geometry, bool turned, std::array<PairRect, 2>& out);

}  // namespace spk::desktop
