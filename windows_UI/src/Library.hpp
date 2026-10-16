#pragma once

#include "FrameOutput.hpp"
#include <QImage>
#include <QString>
#include <QStringList>
#include <QUrl>

// The library's file side, as the macOS app has it: what opens, how a folder
// is listed, the order a folder's frames were dragged into, and the crop
// mask the filmstrip draws over a whole-frame thumbnail. No controller, no
// engine: PreviewController uses these, and spk_qt_library tests them alone.
namespace spk::desktop::library {

// ImageDecoder.openable (ImageDecoder.swift:110-113) as this build reads them:
// LibRaw's RAWs and image_io's TIFF, JPEG and PNG. (HEIC and EXR, which Core
// Image opens on macOS, have no reader here.)
bool rawFile(const QString& path);
bool openable(const QString& path);

// Library.frames(at:) (Library.swift:8-21): a folder's openable files, not
// its subfolders' nor its hidden ones, in Finder's order (numbers compared as
// numbers, case ignored: localizedStandardCompare).
QStringList folderFiles(const QString& folder);
// Library.frames(from:) (Library.swift:35-44): folders listed, files passed,
// each file once, in the order given. Paths are canonical, '/'-separated.
// A file that does not open (by its extension) is left out unless `keepAll`.
QStringList expand(const QList<QUrl>& urls, bool keepAll = false);

// FrameOrder.swift: the order a folder's frames were dragged into, kept
// beside the edits -- one small JSON list of file names per folder, in
// <edit store>/Order/<folder name>-<sha256(folder)[:16]>.order.json -- and
// laid over the listing the next time the folder opens. Frames it does not
// name stay where the listing has them, after their own neighbour.
class FrameOrder {
public:
    explicit FrameOrder(QString storeDirectory = {});
    QString directory() const { return directory_; }
    // The one folder `frames` are from, or "" when they come from several
    // (an order is a folder's). Pairs are not asked: a pair's record lives in
    // the edit store, and it belongs to the folder of the frames beside it.
    static QString folderOf(const QStringList& frames);
    QString fileFor(const QString& folder) const;
    // Keeps `frames` as their folder's order; false (and nothing written)
    // when they are not one folder's or the file cannot be written.
    bool save(const QStringList& frames) const;
    // `listed` in the order kept for its folder.
    QStringList applied(const QStringList& listed) const;
    // FrameOrder.ordered: the named frames in the order named; each other one
    // after the frame it follows in `listed`, or first when it follows none.
    static QStringList ordered(const QStringList& listed, const QStringList& names);
private:
    QString directory_;
};

// CropMaskedThumbnail.swift: the whole photograph with everything outside the
// crop under a nearly opaque mask (CropMask.opacity 0.82), then turned and
// flipped as the canvas turns and flips it. `image` is the unturned,
// uncropped picture; the result keeps its colour space. An identity geometry
// returns the image itself.
constexpr double kCropMaskOpacity = 0.82;
QImage cropMasked(const QImage& image, const output::Geometry& geometry);
// The crop's four corners on the unturned picture, normalised, clockwise from
// the top left: the crop rectangle, turned by the straighten angle about its
// centre and shrunk by the zoom-to-fill FrameOutput applies (the corners of
// what the canvas shows).
std::array<QPointF, 4> cropCorners(QSizeF picture, const output::Geometry& geometry);

}  // namespace spk::desktop::library
