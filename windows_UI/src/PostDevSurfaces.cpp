#include "PostDevSurfaces.hpp"
#include "FrameImage.hpp"
#include <QPointF>
#include <cmath>
#include <stdexcept>

namespace spk::desktop::postdev {

SourceMap sourceMap(QSize full, const output::Geometry& g) {
    QRect rect;
    try {
        output::validateGeometry(full, g);
        rect = output::cropPixels(full, g.crop);
    } catch (const std::exception&) {
        return {};
    }
    const double w = rect.width(), h = rect.height();
    const double angle = g.straightenDegrees * std::acos(-1.0) / 180.0;
    const double cosine = std::cos(angle), sine = std::sin(angle);
    const double zoom = std::max(std::abs(cosine) + std::abs(sine) * h / w, std::abs(cosine) + std::abs(sine) * w / h);
    const double c = cosine / zoom, s = sine / zoom;
    const double cx = (w - 1) * 0.5, cy = (h - 1) * 0.5;
    // predev::sourcePoint step by step, unclamped: every step is affine.
    auto at = [&](double u, double v) {
        if (g.flipHorizontal) u = 1.0 - u;
        if (g.flipVertical) v = 1.0 - v;
        for (int i = 0; i < g.quarterTurns; ++i) {
            const double nu = v, nv = 1.0 - u;
            u = nu;
            v = nv;
        }
        double x = u * w - 0.5, y = v * h - 0.5;
        if (g.straightenDegrees != 0.0) {
            const double sx = cx + c * (x - cx) + s * (y - cy);
            const double sy = cy - s * (x - cx) + c * (y - cy);
            x = sx;
            y = sy;
        }
        return QPointF((rect.left() + x + 0.5) / full.width(), (rect.top() + y + 0.5) / full.height());
    };
    const QPointF o = at(0, 0), du = at(1, 0) - o, dv = at(0, 1) - o;
    return {du.x(), dv.x(), o.x(), du.y(), dv.y(), o.y()};
}

SourceMap shownSourceMap(const FramePtr& frame, const output::Geometry& geometry) {
    if (!frame || frame->cut) return {};
    return sourceMap(QSize(int(frame->width()), int(frame->height())), geometry);
}

FrameGrade exportGrade(const Params& params) {
    if (Grade(params).isIdentity()) return {};
    return [params](QImage& image, const OutputEncoding& encoding) {
        const auto midGrey = midGreyFor(display::colorSpace(encoding));
        if (!midGrey)
            throw std::runtime_error("Post-Dev cannot grade a frame encoded in " + encoding.color_space +
                                     (encoding.cctf_encoding ? std::string() : std::string(" (linear)")));
        Grade(params, *midGrey).apply(image);
    };
}

} // namespace spk::desktop::postdev
