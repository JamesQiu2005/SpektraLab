#pragma once
// The images the canvases draw, made from an engine frame (ColorPipeline.hpp
// is the contract they feed: a QImage whose colorSpace() says how its pixels
// are encoded). Every function here is pure, allocates its result and is safe
// on any thread; the controller calls them on its worker so a 33 MP frame is
// never converted on the GUI thread.
//
// Pixels stay in the session's own encoding and gain no precision they did
// not have: RGBX16FPx4 holds value/65535 of each RGBA16 code as a half float,
// 8 bytes per pixel like the engine's RGBA16. Half floats carry 11 significant
// bits, so codes 1/2048 apart near white share a value; the colour transform
// to the display runs after sampling, on the GPU (FrameCanvas).
#include "desktop/preview_host.hpp"
#include <QColorSpace>
#include <QImage>
#include <QSize>
#include <vector>

namespace spk::desktop::display {

// The QColorSpace a session's code values are encoded in. Every output space
// the engine bakes is mapped explicitly, with the engine's own transfer
// function (core/colour.cpp); a name this build does not know, or a space
// QColorSpace cannot represent (ACES2065-1's AP0 blue lies below y = 0,
// ACEScg's AP1 red beyond x + y = 1), is refused with std::runtime_error.
// Never a default.
QColorSpace colorSpace(const OutputEncoding& encoding);

// RGBA16 rows (top-down, `strideInPixels` >= width) to RGBX16FPx4 tagged
// `space`. Each channel is float(code) * (1/65535) rounded to the nearest
// half, the arithmetic Qt's own RGBA64 conversion uses. Throws on invalid
// dimensions, a non-opaque pixel or a failed allocation.
QImage halfImage(const std::uint16_t* rgba16, int width, int height, qsizetype strideInPixels,
                 const QColorSpace& space);
// An opaque Format_RGBA64 image (an export-path intermediate) the same way.
QImage halfImage(const QImage& rgba64, const QColorSpace& space);
// The whole engine frame: halfImage(frame->pixels(), colorSpace(frame->encoding)).
QImage frameImage(const FramePtr& frame);

// The navigator's picture: long edge at most this, never the full frame.
inline constexpr int kNavigatorLongEdge = 1024;
// The filmstrip's box (as the 8-bit thumbnail was scaled before).
inline constexpr QSize kThumbnailBox{180, 120};

// Area-averaged reduction of an RGBX16FPx4 image to fit inside `bound`,
// keeping its aspect ratio (each edge rounded, at least 1 px). Each output
// pixel is the exact area-weighted mean of the source pixels it covers,
// accumulated in float over the encoded values, then rounded to half; the
// colour space tag is kept. An image already inside `bound` is returned
// as is (shared, not copied): this never enlarges.
QImage downscaled(const QImage& image, QSize bound);
inline QImage navigatorImage(const QImage& visible) {
    return downscaled(visible, {kNavigatorLongEdge, kNavigatorLongEdge});
}
inline QImage thumbnailImage(const QImage& navigator) { return downscaled(navigator, kThumbnailBox); }

// The Original: the photograph before any film simulation (macOS TopBar
// "Original" and Space, ImageDecoder.swift's `display` decode), made from the
// host's own decode -- packed linear LibRaw ProPhoto RGB, the engine's input
// -- and *not* the negative. It is put into `encoding`, the space and curve
// the print is in, so the print and the Original are tagged alike and go
// through the same display LUT: a before/after split compares two renderings,
// never two colour spaces (Renderer.swift's header makes the same rule).
//
// A camera RAW (metadata.camera_raw) is first rendered for the eye, standing
// in for Apple's default RAW rendering, which the Mac shows and LibRaw has no
// equivalent of: the DNG baseline exposure, then a fixed camera-style tone
// curve (RAW 0.10 to 18 % grey, a toe and a soft shoulder to the RAW's white),
// hue-preserving in linear ProPhoto. Like Apple's it is not metered, so an
// under-exposed shot still reads under-exposed. Without it the Original was
// the sensor's linear response, dark and flat beside the print. A flat file
// is already a rendering and skips it. Then a colorimetric conversion (Qt's,
// ProPhoto's D50 to the target's white by Qt's Bradford adaptation) and the
// space's own transfer function, clipped to [0,1]. Geometry is the decode's
// (RAW orientation applied, as the engine received it), so it has the
// frame's size.
//
// RGBX16FPx4, alpha 1. Rows run on up to eight threads. Throws on an empty or
// inconsistent decode or an encoding colorSpace() refuses.
QImage originalImage(const io::DecodedRaw& decoded, const OutputEncoding& encoding);

// The canvas histogram (macOS Renderer.encodeHistogram + publishHistogram):
// 4 x 256 bins -- R, G, B, then Rec. 709 luma -- of the *encoded* values,
// each channel clamped to [0,1] and binned at round(v * 255). One pixel in
// `stride` along each axis, stride = max(1, floor(sqrt(w h / 200 000))) as the
// Mac's kernel takes it, so a 33 MP frame costs ~200 000 samples. Normalised
// to the tallest bin outside the two at each end (clipped black and white
// would flatten everything else), then capped at 1. All zeros for a null
// image. Any thread.
inline constexpr int kHistogramBins = 256;
inline constexpr double kHistogramSamples = 200000;
std::vector<float> histogram(const QImage& rgbx16fp);

}  // namespace spk::desktop::display
