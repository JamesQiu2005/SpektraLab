#include "CanvasMath.hpp"
#include <algorithm>
#include <cmath>

namespace spk::desktop::canvas {

bool valid(const View& v) {
    return v.image.width() > 0 && v.image.height() > 0 && v.canvas.width() > 0 && v.canvas.height() > 0 && v.dpr > 0;
}
double fitZoom(const View& v) {
    if (!valid(v)) return 1;
    return std::min(v.canvas.width() * v.dpr / v.image.width(), v.canvas.height() * v.dpr / v.image.height());
}
double zoomOf(const View& v) { return v.fit ? fitZoom(v) : v.zoom; }
bool pixelAligned(double zoom) {
    return zoom >= 1 - 1e-12 && std::abs(zoom - std::round(zoom)) < 1e-9;
}
double steppedZoom(double current, int direction) {
    if (direction > 0) {
        for (const double step : kZoomSteps)
            if (step > current + 1e-3) return step;
        return kMaxZoom;
    }
    for (auto it = kZoomSteps.rbegin(); it != kZoomSteps.rend(); ++it)
        if (*it < current - 1e-3) return *it;
    return kMinZoom;
}
double clampedZoom(const View& v, double zoom) {
    const double low = std::min(fitZoom(v), kMinZoom);
    return std::clamp(zoom, low, kMaxZoom);
}

namespace {
// Logical size of the photo at the view's zoom.
QSizeF shown(const View& v) {
    const double z = zoomOf(v);
    return {v.image.width() * z / v.dpr, v.image.height() * z / v.dpr};
}
double clampAxis(double offset, double extent, double canvas) {
    if (extent <= canvas) return (canvas - extent) * 0.5;
    return std::clamp(offset, canvas - extent, 0.0);
}
}  // namespace

View clamped(View v) {
    if (!valid(v)) return v;
    const auto size = shown(v);
    v.offset = {clampAxis(v.offset.x(), size.width(), v.canvas.width()),
                clampAxis(v.offset.y(), size.height(), v.canvas.height())};
    return v;
}
View fitted(View v) {
    v.fit = true;
    v.zoom = fitZoom(v);
    return clamped(v);
}
View zoomedAbout(View v, double zoom, QPointF anchor) {
    if (!valid(v)) return v;
    const QRectF before = imageRect(v);
    const double old = zoomOf(v);
    const double next = clampedZoom(v, zoom);
    // The photo point under the anchor, in photo px, from what is on screen.
    const QPointF photo = (anchor - before.topLeft()) * v.dpr / old;
    v.fit = false;
    v.zoom = next;
    v.offset = anchor - photo * next / v.dpr;
    return clamped(v);
}
View panned(View v, QPointF delta) {
    if (!valid(v) || v.fit) return v;
    v.offset += delta;
    return clamped(v);
}
View resized(View v, QSizeF canvas, double dpr) {
    if (v.fit || !valid(v)) {
        v.canvas = canvas;
        v.dpr = dpr;
        return clamped(v);
    }
    const QRectF before = imageRect(v);
    const QPointF centre(v.canvas.width() * 0.5, v.canvas.height() * 0.5);
    const QPointF photo = (centre - before.topLeft()) * v.dpr / v.zoom;
    v.canvas = canvas;
    v.dpr = dpr;
    v.offset = QPointF(canvas.width() * 0.5, canvas.height() * 0.5) - photo * v.zoom / dpr;
    return clamped(v);
}
QRectF imageRect(const View& v) {
    if (!valid(v)) return {};
    const View c = clamped(v);
    const auto size = shown(c);
    double x = c.offset.x(), y = c.offset.y();
    if (pixelAligned(zoomOf(c))) {
        // On the window's grid, not the item's: the item itself may sit at a
        // fractional physical position (a rail width at 125 %). A photo larger
        // than the canvas rounds inwards where rounding would pull an edge
        // inside the canvas, so the clamp still holds to the physical pixel.
        auto snap = [&](double offset, double origin, double extent, double canvasExtent) {
            const double at = (origin + offset) * c.dpr;
            double snapped = std::round(at);
            if (extent > canvasExtent) {
                const double low = (origin + canvasExtent - extent) * c.dpr, high = origin * c.dpr;
                if (snapped > high && std::floor(high) >= low) snapped = std::floor(high);
                else if (snapped < low && std::ceil(low) <= high) snapped = std::ceil(low);
            }
            return snapped / c.dpr - origin;
        };
        x = snap(x, c.sceneOrigin.x(), size.width(), c.canvas.width());
        y = snap(y, c.sceneOrigin.y(), size.height(), c.canvas.height());
    }
    return {x, y, size.width(), size.height()};
}

// --- the crop grips ---------------------------------------------------------

namespace {
struct Grip {
    CropHandle handle;
    double x, y;  // position in the crop's own 0..1 frame
};
constexpr Grip kGrips[] = {
    {CropHandle::topLeft, 0, 0},     {CropHandle::top, 0.5, 0},       {CropHandle::topRight, 1, 0},
    {CropHandle::right, 1, 0.5},     {CropHandle::bottomRight, 1, 1}, {CropHandle::bottom, 0.5, 1},
    {CropHandle::bottomLeft, 0, 1},  {CropHandle::left, 0, 0.5}};
bool isCorner(CropHandle h) {
    return h == CropHandle::topLeft || h == CropHandle::topRight || h == CropHandle::bottomLeft ||
           h == CropHandle::bottomRight;
}
bool movesLeading(CropHandle h) {
    return h == CropHandle::topLeft || h == CropHandle::left || h == CropHandle::bottomLeft;
}
bool movesTrailing(CropHandle h) {
    return h == CropHandle::topRight || h == CropHandle::right || h == CropHandle::bottomRight;
}
bool movesTop(CropHandle h) {
    return h == CropHandle::topLeft || h == CropHandle::top || h == CropHandle::topRight;
}
bool movesBottom(CropHandle h) {
    return h == CropHandle::bottomLeft || h == CropHandle::bottom || h == CropHandle::bottomRight;
}
bool inside(const QRectF& r) {
    constexpr double e = 1e-9;
    return r.left() >= -e && r.top() >= -e && r.right() <= 1 + e && r.bottom() <= 1 + e;
}
}  // namespace

CropHandle cropHandleAt(QRectF crop, QPointF p, QSizeF size, double tolerance) {
    const double w = std::max(size.width(), 1.0), h = std::max(size.height(), 1.0);
    const double dx = (p.x() - crop.x()) * w, dy = (p.y() - crop.y()) * h;
    const double cw = crop.width() * w, ch = crop.height() * h;
    CropHandle best = CropHandle::none;
    double bestRank = 0;
    for (const auto& grip : kGrips) {
        const double d = std::hypot(dx - grip.x * cw, dy - grip.y * ch);
        if (d > tolerance) continue;
        const double rank = isCorner(grip.handle) ? d : d + tolerance;  // corners win ties
        if (best == CropHandle::none || rank < bestRank) {
            best = grip.handle;
            bestRank = rank;
        }
    }
    if (best != CropHandle::none) return best;
    // The edges between the grips resize too: a 1 px line is a hard target,
    // and on Windows a whole edge is the grip (Lightroom, Capture One).
    const bool alongX = dx >= -tolerance && dx <= cw + tolerance;
    const bool alongY = dy >= -tolerance && dy <= ch + tolerance;
    if (alongX && alongY) {
        if (std::abs(dx) <= tolerance) return CropHandle::left;
        if (std::abs(dx - cw) <= tolerance) return CropHandle::right;
        if (std::abs(dy) <= tolerance) return CropHandle::top;
        if (std::abs(dy - ch) <= tolerance) return CropHandle::bottom;
        return CropHandle::body;
    }
    return CropHandle::none;
}

QRectF resizedCrop(QRectF crop, CropHandle handle, QPointF point, QSizeF size, double ratio) {
    if (handle == CropHandle::none || handle == CropHandle::body) return crop;
    const double w = std::max(size.width(), 1.0), h = std::max(size.height(), 1.0);
    const QPointF from(movesLeading(handle) ? crop.left() : crop.right(), movesTop(handle) ? crop.top() : crop.bottom());
    // The rectangle the handle asks for at `p`.
    auto asked = [&](QPointF p) {
        double minX = crop.left(), minY = crop.top(), maxX = crop.right(), maxY = crop.bottom();
        if (movesLeading(handle)) minX = p.x();
        if (movesTrailing(handle)) maxX = p.x();
        if (movesTop(handle)) minY = p.y();
        if (movesBottom(handle)) maxY = p.y();
        // Past the opposite edge the rectangle flips rather than inverts.
        QRectF r(std::min(minX, maxX), std::min(minY, maxY), std::max(std::abs(maxX - minX), kMinCropSide / w),
                 std::max(std::abs(maxY - minY), kMinCropSide / h));
        if (ratio > 0) {
            // The corner (or edge) opposite the dragged one stays pinned. Which
            // one that is follows the pointer's side of the pinned edge, so a
            // flipped rectangle keeps its anchor.
            const double ax = movesLeading(handle) ? (p.x() <= crop.right() ? 1.0 : 0.0)
                            : movesTrailing(handle) ? (p.x() >= crop.left() ? 0.0 : 1.0) : 0.5;
            const double ay = movesTop(handle) ? (p.y() <= crop.bottom() ? 1.0 : 0.0)
                            : movesBottom(handle) ? (p.y() >= crop.top() ? 0.0 : 1.0) : 0.5;
            const double pw = r.width() * w, ph = r.height() * h;
            double nw = pw, nh = ph;
            if (isCorner(handle)) {
                nw = std::max(pw, ph * ratio);
                nh = nw / ratio;
                if (nh < kMinCropSide) { nh = kMinCropSide; nw = nh * ratio; }
            } else if (movesLeading(handle) || movesTrailing(handle)) {
                nh = pw / ratio;
            } else {
                nw = ph * ratio;
            }
            const double px = r.x() + r.width() * ax, py = r.y() + r.height() * ay;
            r = QRectF(px - nw / w * ax, py - nh / h * ay, nw / w, nh / h);
        }
        return r;
    };
    // A drag past the frame stops at it: clamp the point, each axis on its own.
    const QPointF target(std::clamp(point.x(), 0.0, 1.0), std::clamp(point.y(), 0.0, 1.0));
    const QRectF want = asked(target);
    if (inside(want)) return want;
    // With a lock the derived side can still leave the frame: walk the drag
    // back along its own direction to the furthest shape that fits.
    double lo = 0, hi = 1;
    auto at = [&](double t) { return from + (target - from) * t; };
    for (int i = 0; i < 40; ++i) {
        const double mid = (lo + hi) / 2;
        if (inside(asked(at(mid)))) lo = mid; else hi = mid;
    }
    QRectF stop = asked(at(lo));
    // The minimum side may still overhang a frame edge on a tiny photo.
    stop = stop.intersected(QRectF(0, 0, 1, 1));
    return stop;
}

QRectF movedCrop(QRectF crop, QPointF delta) {
    auto axis = [](double start, double extent, double d) {
        if (extent >= 1) return start;
        return std::clamp(start + d, 0.0, 1.0 - extent);
    };
    return {axis(crop.x(), crop.width(), delta.x()), axis(crop.y(), crop.height(), delta.y()), crop.width(),
            crop.height()};
}

QRectF drawnCrop(QPointF from, QPointF to, QSizeF size, double ratio) {
    const double w = std::max(size.width(), 1.0), h = std::max(size.height(), 1.0);
    const QPointF a(std::clamp(from.x(), 0.0, 1.0), std::clamp(from.y(), 0.0, 1.0));
    const QPointF b(std::clamp(to.x(), 0.0, 1.0), std::clamp(to.y(), 0.0, 1.0));
    if (ratio <= 0) return QRectF(a, b).normalized();
    // Grown from the corner the drag began at: the larger pixel extent wins,
    // then both shrink to the room on that side of the start point.
    const double sx = b.x() >= a.x() ? 1 : -1, sy = b.y() >= a.y() ? 1 : -1;
    double pw = std::abs(b.x() - a.x()) * w, ph = std::abs(b.y() - a.y()) * h;
    pw = std::max(pw, ph * ratio);
    const double roomW = (sx > 0 ? 1 - a.x() : a.x()) * w, roomH = (sy > 0 ? 1 - a.y() : a.y()) * h;
    pw = std::min({pw, roomW, roomH * ratio});
    ph = pw / ratio;
    const double nw = pw / w, nh = ph / h;
    return QRectF(sx > 0 ? a.x() : a.x() - nw, sy > 0 ? a.y() : a.y() - nh, nw, nh);
}

std::optional<double> straightenFromLine(QPointF a, QPointF b, QSizeF size) {
    const double w = std::max(size.width(), 1.0), h = std::max(size.height(), 1.0);
    const double dx = (b.x() - a.x()) * w, dy = (b.y() - a.y()) * h;
    if (std::hypot(dx, dy) <= 8) return std::nullopt;
    // The line's bearing, clockwise from east (y grows downward), folded
    // into the nearest axis.
    double deg = std::atan2(dy, dx) * 180 / std::acos(-1.0);
    if (std::abs(deg) > 90) deg += deg > 0 ? -180 : 180;
    if (std::abs(deg) > 45) deg += deg > 0 ? -90 : 90;
    // output::Geometry turns the picture clockwise by a positive angle
    // (FrameOutput.cpp straighten), so a line falling to the right at +deg is
    // levelled by turning the picture back: -deg.
    return std::clamp(-deg, -45.0, 45.0) + 0.0;
}

}  // namespace spk::desktop::canvas
