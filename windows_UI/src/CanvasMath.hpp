#pragma once
// The canvas's view and crop arithmetic, pure and testable without a window:
// the Windows counterpart of macOS Canvas/ViewportState.swift (zoom, pan, the
// one clamp) and of the crop grips in Model/Geometry.swift (handle hit test,
// resize under an aspect lock, move, the straighten-by-a-line angle).
//
// Units. A zoom is device pixels per photo pixel, so 1 is 100 %: one physical
// pixel per photo pixel at any Windows scale factor (ViewportState's
// `hundredScale` is the same statement in points). Positions are the canvas
// item's logical pixels. Crop rectangles and points are normalised to the
// uncropped, unturned source, as output::Geometry::crop is.
#include <QPointF>
#include <QRectF>
#include <QSize>
#include <QSizeF>
#include <array>
#include <optional>

namespace spk::desktop::canvas {

// ViewportState.zoomSteps / minZoom / maxZoom, as fractions of 100 %.
inline constexpr std::array<double, 13> kZoomSteps{0.05, 0.1, 0.25, 0.33, 0.5, 0.66, 1, 1.5, 2, 3, 4, 6, 8};
inline constexpr double kMinZoom = 0.05, kMaxZoom = 8;
// The zoom pill's menu after Fit (TopBar.swift zoomPill: 25, 50, 100, 200, 400 %).
inline constexpr std::array<double, 5> kMenuZooms{0.25, 0.5, 1, 2, 4};

struct View {
    QSizeF canvas;          // the canvas item, logical px
    double dpr = 1;         // device px per logical px
    QSize image;            // the photo, px
    bool fit = true;        // fitted and centred; `zoom` and `offset` unused
    double zoom = 1;        // device px per photo px while not fitted
    QPointF offset;         // image origin in the item, logical px (clamped)
    QPointF sceneOrigin;    // the item's origin in the window, logical px
};

bool valid(const View& view);
// The zoom at which the whole photo fits the canvas (ViewportState.fitScale).
double fitZoom(const View& view);
// What is on screen: fitZoom while fitted, else `zoom`.
double zoomOf(const View& view);
// Integer zooms of at least 100 % map each photo pixel onto a whole block of
// device pixels -- if the image origin is on the physical grid, which
// imageRect() then puts it on.
bool pixelAligned(double zoom);
// The next step above or below `current` (ViewportState.stepZoom): the first
// step more than 0.1 % beyond it, else the limit.
double steppedZoom(double current, int direction);
// The zooms a gesture may reach: down to the smaller of fit and 5 %, up to 800 %.
double clampedZoom(const View& view, double zoom);

// The one clamp (ViewportState.clamp): along an axis where the photo is
// smaller than the canvas it is centred, where it is larger its edges stay
// outside the canvas.
View clamped(View view);
View fitted(View view);
// `zoom` keeping the photo point under `anchor` (item px) where it is.
View zoomedAbout(View view, double zoom, QPointF anchor);
View panned(View view, QPointF delta);
// A new canvas size or scale factor: fitted stays fitted, otherwise the photo
// point at the canvas's centre stays there (ViewportState.resize).
View resized(View view, QSizeF canvas, double dpr);
// The photo's rectangle in the item. At a pixel-aligned zoom its origin is
// rounded onto the physical pixel grid of the window (sceneOrigin included),
// so 100 % never resamples and grain never shifts by a fraction of a pixel.
QRectF imageRect(const View& view);

// --- the crop grips ---------------------------------------------------------

// Geometry.swift CropHandle, numbered for QML.
enum class CropHandle : int {
    none = -1, body = 0, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
};
// Smallest crop side in source px (Geometry.minSide).
inline constexpr double kMinCropSide = 16;
// Which grip `p` is on, `body` inside the rectangle, `none` outside it
// (Geometry.handle(at:)). Corners win over edges; `tolerancePx` is in source
// px, converted by the caller from a constant on-screen grab radius.
CropHandle cropHandleAt(QRectF crop, QPointF p, QSizeF sourcePx, double tolerancePx);
// The rectangle with `handle` dragged to `p` and the opposite corner or edge
// pinned (Geometry.resized). `ratio` (width / height in source px) locks the
// shape when positive: a corner follows whichever axis asks for more, an edge
// derives the other side. The point is clamped into the frame first, and a
// locked shape that still does not fit stops where it does.
QRectF resizedCrop(QRectF crop, CropHandle handle, QPointF p, QSizeF sourcePx, double ratio);
// Moved by `delta`, each axis clamped on its own so a crop pushed against an
// edge slides along it (Geometry.moved).
QRectF movedCrop(QRectF crop, QPointF delta);
// A rectangle drawn from `from` to `to`, grown from the corner the drag began
// at under `ratio` when positive, and kept inside the frame.
QRectF drawnCrop(QPointF from, QPointF to, QSizeF sourcePx, double ratio);
// The straighten, in output::Geometry's convention (degrees, clockwise), that
// makes the line a -> b level -- or plumb, when it is nearer vertical
// (Geometry.straightenAngle). The points are on the unstraightened source, so
// the result replaces the current angle rather than adding to it. nullopt for
// a line shorter than 8 source px (a click).
std::optional<double> straightenFromLine(QPointF a, QPointF b, QSizeF sourcePx);

}  // namespace spk::desktop::canvas
