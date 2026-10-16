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

}  // namespace spk::desktop::display
