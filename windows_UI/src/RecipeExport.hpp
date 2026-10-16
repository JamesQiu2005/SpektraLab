#pragma once
// Delivery under a recipe: the macOS Exporter.swift's one chain -- render,
// grade, frame, size, convert, write -- for an engine frame in whatever space
// Frame::encoding reports (encoded sRGB today, ProPhoto RGB once the session
// moves to the working space, ARCHITECTURE.md 7.5). Each file leaves that
// space exactly once, through the engine's own output transform
// (spk_output_transform: CAT02 matrix, CAM16-UCS gamut compression, target
// curve -- engine/host/output.cpp is the per-pixel arithmetic, shared with the
// portable host), and is tagged with an ICC profile describing the space the
// pixels were encoded in.
//
// A frame already in the requested space is not converted at all: an sRGB
// session exported as sRGB, without EXIF or a preview page, goes through the
// very writers FrameOutput.hpp has always used and is byte-identical to the
// old export (spk_qt_recipe_export pins it).
//
// Order, as Exporter.filePixels: [Post-Dev grade on the uncropped frame] ->
// crop/straighten/turn/flip -> long-edge resize -> output transform -> depth
// -> file. The grade is a hook (Job::grade) a later lane fills with
// postdev::Grade(params, midGrey).apply(...) on the uncropped RGBA64 frame in
// its own encoding; identity params must leave the pixels untouched.
#include "ExportRecipe.hpp"
#include "FrameOutput.hpp"
#include "desktop/preview_host.hpp"
#include <QByteArray>
#include <QColorSpace>
#include <QImage>
#include <QString>
#include <QStringList>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>

#include "output.hpp"

namespace spk::desktop::exporting {

// The ICC profile a file in `engineSpace` carries: the bundled sRGB.icc for
// sRGB (what FrameOutput has always embedded), otherwise the profile of the
// QColorSpace FrameImage tags the canvas with (display::colorSpace: Qt's
// named spaces where their curve is the engine's, the engine's own curve as
// a table for the BT spaces), named for the space. Throws for a space the
// display cannot tag.
QByteArray iccProfile(const std::string& engineSpace, const std::filesystem::path& resources);

// One conversion out of `from` into `to`, on opaque RGBA64 in `from`'s
// encoding. Same space: the image itself, untouched. Otherwise the engine's
// transform, encoded to 16 bits. `clippedFraction` is the share of pixels
// with a channel the gamut map left outside [0, 1] (and the quantiser
// clipped); `engine` may be null only when no conversion is needed.
struct Converted {
    QImage rgba64;
    bool identity = false;
    double clippedFraction = 0;
};
Converted convert(const QImage& rgba64, const OutputEncoding& from, const std::string& to, spk_engine* engine);

// The engine transform convert() runs from encoded `from` into `to`, fetched
// with the export's gamut-compression setting: off when `to` holds all of
// `from` (a plain colorimetric conversion), else CAM16-UCS's chroma knee
// without its lightness shoulder (ColourManagement.swift:153-164). The soft
// proof evaluates this same object on its LUT grid, so the canvas proof and
// the file cannot disagree about which transform they mean. Throws.
spkhost::OutputTransform exportTransform(const std::string& from, const std::string& to, spk_engine* engine);

// The legacy single-file and batch export (PreviewController::exportImage /
// exportBatch): FrameOutput's writers, which embed sRGB.icc. A frame encoded
// in sRGB goes through output::exportFrame unchanged, byte for byte; any other
// encoding (the ProPhoto working space) is graded, framed and sized in its own
// encoding, converted into sRGB once by convert() -- the recipe export's
// conversion, so the file equals an sRGB recipe export's pixels -- and only
// then written, never sRGB-tagged working-space codes. Throws.
void exportLegacy(const FramePtr& frame, const std::filesystem::path& destination, const output::Geometry& geometry,
                  const output::ExportOptions& options, const std::filesystem::path& resources,
                  const std::function<void(QImage&, const OutputEncoding&)>& grade, spk_engine* engine);

// What the writer is asked for. `exif` may be empty; `preview` (TIFF only)
// writes the macOS preview page; `untagged` writes no profile (the DI).
struct WriteOptions {
    recipes::Format format = recipes::Format::tiff;
    int jpegQuality = 95;
    const spkhost::Exif* exif = nullptr;
    bool preview = false;
    QImage previewImage;                 // 8-bit-able picture for the page; tagged
    bool untagged = false;
    bool overwrite = false;
};
enum class Published { written, exists };
// Writes `pixels` (RGBA64 encoded in `space`) to `destination` through a
// private temporary directory beside it and publishes atomically: without
// `overwrite` an existing file is never replaced (Published::exists, nothing
// written); with it the old file is swapped for the new one in one move.
Published writeImage(const QImage& pixels, const std::string& space, const std::filesystem::path& destination,
                     const WriteOptions& options, const std::filesystem::path& resources);

// EXIF fields for a photograph, read from its file (LibRaw through the
// portable host's probe), filtered by the recipe. Empty when the recipe copies
// none or the file has none.
std::optional<spkhost::Exif> exifFor(const std::filesystem::path& source, const recipes::Metadata& metadata,
                                     const std::string& space, bool digitalIntermediate);

// The macOS DI's two view LUTs (Resources/DI, laid out by the build as
// <resources>/di; CineonLUT.copyBeside), copied
// into `directory` once: an existing file of that name is kept. Returns the
// paths written.
QStringList copyDiViewLuts(const QString& directory, const std::filesystem::path& resources);
// The DI preview page: Cineon codes through the shipped Cineon-to-ProPhoto
// view LUT (trilinear), long edge at most 2048, tagged ProPhoto RGB.
QImage diViewPreview(const QImage& cineonRgba64, const std::filesystem::path& resources);

// One photograph under one recipe.
struct Job {
    recipes::Recipe recipe;
    QString source;                       // the photograph's path
    recipes::NameContext name;
    output::Geometry geometry;
    std::filesystem::path resources;
    // Optional Post-Dev hook, called on the uncropped RGBA64 frame in its own
    // encoding before geometry. Unset: no grade.
    std::function<void(QImage& uncropped, const OutputEncoding& encoding)> grade;
};
struct Outcome {
    enum Kind { written, skipped } kind = written;
    QStringList files;                    // the image first, then any LUTs
    QString note;                         // fall-backs and caveats, for the page
    double clippedFraction = 0;
    int width = 0, height = 0;
};
// The frame is the developed print (or, for a DI recipe, the frame
// PreviewHost::render_digital_intermediate returned). Creates the directory,
// resolves the existing-file policy against the filesystem (and again at
// publication, so a file appearing meanwhile is never clobbered unless the
// recipe overwrites), converts and writes. Throws std::runtime_error.
Outcome run(const Job& job, const FramePtr& frame, spk_engine* engine);

// The frame's pixels after the grade, geometry and size, still in the
// frame's encoding (the export's first half; the proof uses it too).
QImage framed(const Job& job, const FramePtr& frame);

}  // namespace spk::desktop::exporting
