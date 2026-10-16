#pragma once
// Post-Dev on the surfaces that show the frame -- the canvas, the navigator,
// the crop editor, the filmstrip thumbnail, the export proof (PostDev.hpp's
// integration note; AGENTS.md trap 33). Every one of them grades the same
// source with the same Grade before its own geometry, so each needs two
// things: the grade, and where each of its pixels sits on the uncropped,
// unturned source (the vignette is the print's, Shaders.metal:340).
//
// The canvas shows images that are already cropped, straightened, turned and
// flipped (PreviewController's previewImage), so the second is an affine map
// from the displayed image's own normalised position to the source's. Grading
// a displayed pixel at its source position is the Mac's picture wherever the
// geometry resampled nothing (crop, turns, flips: Layer 2 per source texel,
// then a copy) and differs only by the order of filtering and grading where it
// interpolates (straighten, a reduced navigator or thumbnail) -- the same
// trade the canvas makes when it filters below 100 % (PostDev.hpp, "Canvas").
//
// No engine types here: FrameCanvas and its tests link this without the
// desktop host. PostDevSurfaces.hpp derives a SourceMap from a Geometry.
#include "PostDev.hpp"
#include <QImage>
#include <QString>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <optional>
#include <utility>

class QColorSpace;

namespace spk::desktop::postdev {

// su = a u + b v + c, sv = d u + e v + f, with (u, v) the displayed image's
// position (u right, v down, [0, 1] across it) and (su, sv) the source's.
struct SourceMap {
    double a = 1, b = 0, c = 0, d = 0, e = 1, f = 0;
    std::pair<double, double> operator()(double u, double v) const { return {a * u + b * v + c, d * u + e * v + f}; }
    bool operator==(const SourceMap&) const = default;
};
// QML's form: [a, b, c, d, e, f]. Anything else -- an empty list included --
// reads as the identity (the image is the whole source).
QVariantList toVariant(const SourceMap& map);
SourceMap sourceMapFrom(const QVariant& value);

// The controller's QML map (toJson's shape) back to Params. An invalid map
// is refused as the store refuses one (fromJson's message in `error`) and
// reads as the defaults; keys this build does not know are ignored.
Params paramsFrom(const QVariantMap& map, QString* error = nullptr);

// The grade a surface applies to an image in `space`: nullopt when there is
// nothing to apply (bypassed or identity params) or when the encoding is one
// Post-Dev must not grade (midGreyFor: linear data, an unknown curve). An
// invalid (untagged) space is sRGB, as the canvas draws it.
std::optional<Grade> gradeFor(const Params& params, const QColorSpace& space);

// Grade::pixel over every pixel of `image` in place, each at the source
// position `map` gives its centre ((x + 0.5) / W, (y + 0.5) / H). Half float
// (RGBX16FPx4, RGBA16FPx4, rounded to the nearest half), float (RGBX32FPx4,
// RGBA32FPx4) and 16-bit (RGBX64, RGBA64, rounded to nearest) images; colour
// straight, alpha untouched. Rows are the unit of work, so the result is the
// same for any thread count (`threads` 0: every hardware thread). Any other
// format throws std::invalid_argument; an identity grade returns at once.
void gradeImage(QImage& image, const Grade& grade, const SourceMap& map, int threads = 0);

} // namespace spk::desktop::postdev
