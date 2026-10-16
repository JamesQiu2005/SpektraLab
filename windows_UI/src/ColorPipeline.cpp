#include "ColorPipeline.hpp"

#include <QQuickWindow>
#include <QVariant>

// Placeholder implementation: no display is managed yet, every source gets
// the identity LUT unless a test forces one. The colour core replaces this
// file (display discovery, LUT builds); the contract is ColorPipeline.hpp.

struct ColorPipeline::Impl {
    QString mode = QStringLiteral("srgb");
    QString customProfilePath;
    bool dither = true;
    std::shared_ptr<const ColorLut> override;
};

namespace {
const char* const kWindowProperty = "_spektralab_color_pipeline";
}

ColorPipeline* ColorPipeline::forWindow(QQuickWindow* window) {
    if (!window) return nullptr;
    if (auto* existing = window->property(kWindowProperty).value<ColorPipeline*>()) return existing;
    auto* pipeline = new ColorPipeline(window);
    window->setProperty(kWindowProperty, QVariant::fromValue(pipeline));
    return pipeline;
}

ColorPipeline::ColorPipeline(QQuickWindow* window) : QObject(window), d_(std::make_unique<Impl>()) {}

ColorPipeline::~ColorPipeline() = default;

std::shared_ptr<const ColorLut> ColorPipeline::lut(const QColorSpace&) const {
    static const auto identity = std::make_shared<const ColorLut>();
    return d_->override ? d_->override : identity;
}

QString ColorPipeline::mode() const { return d_->mode; }
void ColorPipeline::setMode(const QString& mode) {
    if (mode == d_->mode) return;
    d_->mode = mode;
    emit changed();
}
QString ColorPipeline::customProfilePath() const { return d_->customProfilePath; }
void ColorPipeline::setCustomProfilePath(const QString& path) {
    if (path == d_->customProfilePath) return;
    d_->customProfilePath = path;
    emit changed();
}
QString ColorPipeline::displayName() const { return QStringLiteral("sRGB (assumed)"); }
QString ColorPipeline::status() const { return {}; }
bool ColorPipeline::dither() const { return d_->dither; }
void ColorPipeline::setDither(bool dither) {
    if (dither == d_->dither) return;
    d_->dither = dither;
    emit changed();
}

void ColorPipeline::setLutOverrideForTesting(std::shared_ptr<const ColorLut> lut) {
    d_->override = std::move(lut);
    emit changed();
}
