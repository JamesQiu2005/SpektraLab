#include "WhiteBalance.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace spk::desktop::predev {
namespace {

double clampedTo(const char* key, double value) {
    const auto* row = find_setting(key);
    return row ? std::clamp(value, row->low, row->high) : value;
}

// As Shot's stored numbers made the camera's, so an edit that leaves As Shot
// starts from the picture on screen.
WhiteBalance materialised(WhiteBalance value, const std::optional<AsShot>& camera) {
    if (value.as_shot() && camera) {
        value.temperature = clampedTo("white_balance_temperature", camera->temperature);
        value.tint = clampedTo("white_balance_tint", camera->tint);
    }
    return value;
}

}  // namespace

Boxes boxes(const WhiteBalance& value, const std::optional<AsShot>& camera) {
    if (!camera) return {};
    const bool following = value.as_shot();
    return {following || value.temperature == clampedTo("white_balance_temperature", camera->temperature),
            following || value.tint == clampedTo("white_balance_tint", camera->tint)};
}

WhiteBalance applyingBoxes(const WhiteBalance& value, std::optional<bool> temperature, std::optional<bool> tint,
                           const std::optional<AsShot>& camera) {
    if (!camera) return value;
    Boxes next = boxes(value, camera);
    if (temperature) next.temperature = *temperature;
    if (tint) next.tint = *tint;
    WhiteBalance out = materialised(value, camera);
    if (next.temperature) out.temperature = clampedTo("white_balance_temperature", camera->temperature);
    if (next.tint) out.tint = clampedTo("white_balance_tint", camera->tint);
    out.mode = next.temperature && next.tint ? "as_shot" : "custom";
    return out;
}

WhiteBalance withTemperature(const WhiteBalance& value, double kelvin, const std::optional<AsShot>& camera) {
    WhiteBalance out = materialised(value, camera);
    out.temperature = kelvin;
    out.mode = "custom";
    return out;
}

WhiteBalance withTint(const WhiteBalance& value, double tint, const std::optional<AsShot>& camera) {
    WhiteBalance out = materialised(value, camera);
    out.tint = tint;
    out.mode = "custom";
    return out;
}

std::optional<WhiteBalance> withPreset(const WhiteBalance& value, const std::string& id,
                                       const std::optional<AsShot>& camera) {
    for (const auto& preset : white_balance_presets()) {
        if (id != preset.id) continue;
        WhiteBalance out = value;
        out.mode = id;
        if (preset.kelvin > 0) {
            out.temperature = preset.kelvin;
            out.tint = 0.0;
        } else {
            out = materialised(out, camera);
        }
        return out;
    }
    return std::nullopt;
}

std::optional<QPointF> sourcePoint(QSize full, const output::Geometry& g, QPointF shown) {
    if (!(shown.x() >= 0.0 && shown.x() <= 1.0 && shown.y() >= 0.0 && shown.y() <= 1.0)) return std::nullopt;
    QRect rect;
    try {
        output::validateGeometry(full, g);
        rect = output::cropPixels(full, g.crop);
    } catch (const std::exception&) {
        return std::nullopt;
    }
    double u = shown.x(), v = shown.y();
    // Flips are in the output's axes, after the turns.
    if (g.flipHorizontal) u = 1.0 - u;
    if (g.flipVertical) v = 1.0 - v;
    // A clockwise quarter turn takes (s, t) to (1 - t, s); undo each.
    for (int i = 0; i < g.quarterTurns; ++i) {
        const double s = v, t = 1.0 - u;
        u = s;
        v = t;
    }
    // In the cropped frame's pixel indices, where straighten samples.
    const double w = rect.width(), h = rect.height();
    double x = u * w - 0.5, y = v * h - 0.5;
    if (g.straightenDegrees != 0.0) {
        // FrameOutput's straighten: the fixed rectangle inverse-mapped about
        // its centre, zoomed to keep the edges covered, clamped at the edge.
        const double angle = g.straightenDegrees * std::acos(-1.0) / 180.0;
        const double cosine = std::cos(angle), sine = std::sin(angle);
        const double zoom = std::max(std::abs(cosine) + std::abs(sine) * h / w, std::abs(cosine) + std::abs(sine) * w / h);
        const double c = cosine / zoom, s = sine / zoom;
        const double cx = (w - 1) * 0.5, cy = (h - 1) * 0.5;
        const double sx = std::clamp(cx + c * (x - cx) + s * (y - cy), 0.0, w - 1);
        const double sy = std::clamp(cy - s * (x - cx) + c * (y - cy), 0.0, h - 1);
        x = sx;
        y = sy;
    }
    return QPointF((rect.left() + x + 0.5) / full.width(), (rect.top() + y + 0.5) / full.height());
}

}  // namespace spk::desktop::predev
