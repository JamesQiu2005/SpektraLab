#pragma once
// Post-Dev where the frame's geometry and encoding are known: the map from a
// displayed (cropped, straightened, turned, flipped) image to the uncropped
// source that PostDevView's surfaces grade against, and the export hook that
// grades the uncropped frame before geometry (RecipeExport.hpp Job::grade,
// FrameOutput.hpp exportFrame). PostDev.hpp's integration note says why each
// surface grades where it does.
#include "FrameOutput.hpp"
#include "PostDevView.hpp"
#include <QSize>
#include <functional>

namespace spk::desktop::postdev {

// Where the picture FrameOutput's displayImage / displayFrame make of a
// `full`-sized frame under `geometry` sits on the frame: the inverse of
// crop -> straighten about the crop's centre with its zoom to fill -> turns
// -> flips, the arithmetic of predev::sourcePoint without its edge clamp
// (zoom-to-fill keeps every displayed pixel inside the crop to within half a
// pixel). Affine, so exact as six numbers. An invalid geometry is the
// identity.
SourceMap sourceMap(QSize full, const output::Geometry& geometry);
// The map for the picture the canvas shows of `frame` under the editor's
// `geometry`: sourceMap above, or the identity for a cut frame (a film edge,
// a date under a crop), whose print is the whole film canvas drawn with no
// geometry of its own (Session.canvasGeometry). The Mac grades that canvas
// whole, rebate included, its vignette about the canvas's centre: Layer 2
// runs on the engine's print (Renderer.draw encodeLayer2(src: base);
// Exporter.filePixels applyLayer2(to: full) before printGeometry, which is
// .default for a cut frame, Session+FilmEdge.swift:459).
SourceMap shownSourceMap(const FramePtr& frame, const output::Geometry& geometry);

// Grade::apply on the uncropped RGBA64 frame in its own encoding (row
// v = (y + 0.5) / H, column u = (x + 0.5) / W, Exporter.swift:374-401),
// before geometry -- or an empty function when `params` change no pixel
// (bypassed or identity), so an ungraded export is the print byte for byte.
// The hook throws std::runtime_error for an encoding Post-Dev cannot grade.
using FrameGrade = std::function<void(QImage& uncroppedRgba64, const OutputEncoding& encoding)>;
FrameGrade exportGrade(const Params& params);

} // namespace spk::desktop::postdev
