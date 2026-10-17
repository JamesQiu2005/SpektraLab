#pragma once

#include "desktop/preview_host.hpp"
#include <QImage>
#include <QRectF>
#include <filesystem>
#include <functional>

// Geometry belongs after the engine. Every output surface uses these same
// pixel edges; cropping never changes the emulsion or re-renders its grain.
namespace spk::desktop::output {

enum class Format { TIFF16, PNG8, PNG16, JPEG8 };
struct ExportOptions {
    Format format = Format::TIFF16;
    int jpegQuality = 95;
    int maxLongEdge = 0; // zero preserves the cropped size; never upscale
};

struct Geometry {
    // Crop coordinates always refer to the original, unturned source.
    QRectF crop{0,0,1,1};
    int quarterTurns = 0; // clockwise, 0 through 3
    bool flipHorizontal = false; // in the final output axes
    bool flipVertical = false;
    double straightenDegrees = 0; // clockwise, -45 through +45
    bool operator==(const Geometry&) const = default;
};

// Normalized top-left crop in [0,1]. All fields must be finite, its area
// positive, and it must fit inside the full frame. Both edges round to the
// nearest pixel, with a minimum extent of one pixel for a valid small crop.
// Invalid input throws std::runtime_error; an empty rectangle is not "full".
QRect cropPixels(QSize fullSize, QRectF normalizedCrop);
void validateGeometry(QSize fullSize, const Geometry& geometry);
// Geometry on an already published display image (FrameImage.hpp); the
// result keeps its format and colour space. Crops copy pixels exactly.
QImage displayImage(const QImage& full, QRectF normalizedCrop);
QImage displayImage(const QImage& full, const Geometry& geometry);
// Use this for transformed rendered previews: geometry is applied to the
// original RGBA16 before the display conversion, as it is for an exported
// file. RGBX16FPx4 tagged with the frame's encoding (display::colorSpace).
QImage displayFrame(const FramePtr& frame, const Geometry& geometry);

// The source is opaque, already encoded sRGB RGBA64. Processing order is
// original-space crop -> bilinear straighten with zoom-to-fill (fixed crop
// dimensions) -> clockwise quarter turns -> output-axis flips -> optional
// downsize -> output depth. Identity and orthogonal geometry are lossless;
// straightening interpolates 16-bit samples without a colour transform.
QImage exportImage(const QImage& fullRgba64, QRectF normalizedCrop,
                   const ExportOptions& options);
QImage exportImage(const QImage& fullRgba64, const Geometry& geometry,
                   const ExportOptions& options);
bool formatAvailable(Format format);

// The private folder an export is written in beside its destination, removed
// with anything left in it when this goes. It takes the folder's inherited
// permissions: QTemporaryDir asks for owner-only ones, which an SMB share (a
// NAS) can refuse after the folder is made -- the export failed and left the
// folder behind. Throws std::runtime_error with the system's reason.
class StagingDir {
public:
    explicit StagingDir(const QString& folder);
    ~StagingDir();
    StagingDir(const StagingDir&) = delete;
    StagingDir& operator=(const StagingDir&) = delete;
    std::filesystem::path filePath(const QString& name) const;
private:
    std::filesystem::path path_;
};

// Uses the explicitly bundled resources/io/sRGB.icc. Writes a complete file
// in a private temporary directory beside the destination, then publishes it
// atomically with no replacement, including if another writer wins a race.
// The caller's frame/image and any existing destination stay untouched.
// The final suffix must match the format (case insensitive); a missing suffix
// is rejected rather than creating an ambiguously typed image file.
void exportImageFile(const QImage& fullRgba64,
                     const std::filesystem::path& destination,
                     QRectF normalizedCrop, const ExportOptions& options,
                     const std::filesystem::path& resources);
void exportImageFile(const QImage& fullRgba64,
                     const std::filesystem::path& destination,
                     const Geometry& geometry, const ExportOptions& options,
                     const std::filesystem::path& resources);
// The frame's own RGBA16, never a display image, so a file does not depend on
// how the canvas is fed. Refuses a frame not encoded in sRGB (the writers
// embed sRGB.icc) instead of mislabelling it.
void exportFrame(const FramePtr& frame, const std::filesystem::path& destination,
                 QRectF normalizedCrop, const ExportOptions& options,
                 const std::filesystem::path& resources);
void exportFrame(const FramePtr& frame, const std::filesystem::path& destination,
                 const Geometry& geometry, const ExportOptions& options,
                 const std::filesystem::path& resources);
// The same with Post-Dev (postdev::exportGrade): `grade` runs on a private
// copy of the uncropped RGBA64 frame, in the frame's encoding, before the
// geometry -- the order of RecipeExport and the Mac's Exporter.filePixels.
// An empty `grade` is the overload above, byte for byte.
void exportFrame(const FramePtr& frame, const std::filesystem::path& destination,
                 const Geometry& geometry, const ExportOptions& options,
                 const std::filesystem::path& resources,
                 const std::function<void(QImage&, const OutputEncoding&)>& grade);

} // namespace spk::desktop::output
