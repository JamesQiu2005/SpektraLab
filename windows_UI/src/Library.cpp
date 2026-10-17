#include "Library.hpp"
#include "HalfFramePair.hpp"

#include <QCollator>
#include <vector>
#include <QColorSpace>
#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QPainter>
#include <QPainterPath>
#include <QSaveFile>
#include <QSet>
#include <QTransform>
#include <algorithm>
#include <cmath>

namespace spk::desktop::library {
namespace {
// ImageDecoder.rawExtensions (ImageDecoder.swift:110-111), with the Nikon
// .nrw the Windows import dialog has always offered.
const QStringList& rawExtensions() {
    static const QStringList list{"nef", "nrw", "arw", "dng", "cr2", "cr3", "raf", "rw2", "orf", "pef", "srw", "3fr", "iiq"};
    return list;
}
const QStringList& flatExtensions() {
    static const QStringList list{"tif", "tiff", "png", "jpg", "jpeg"};
    return list;
}
QString canonical(const QString& path) {
    const QFileInfo info(path);
    const QString real = info.canonicalFilePath();
    return QDir::cleanPath(real.isEmpty() ? info.absoluteFilePath() : real);
}
// Windows paths are one file whatever their case.
QString key(const QString& path) { return QDir::cleanPath(path).toCaseFolded(); }
}  // namespace

bool rawFile(const QString& path) { return rawExtensions().contains(QFileInfo(path).suffix().toLower()); }
bool openable(const QString& path) {
    const auto suffix = QFileInfo(path).suffix().toLower();
    return rawExtensions().contains(suffix) || flatExtensions().contains(suffix);
}

QStringList folderFiles(const QString& folder) {
    const QDir dir(folder);
    // The folder is made canonical once and its entries joined to it -- a
    // canonical path per file is a walk of every component, ~0.3 ms each on
    // Windows, which a folder of hundreds felt -- except a link, which is
    // resolved to what it names as before. Sorted on the names themselves.
    const QString root = canonical(dir.absolutePath());
    struct Entry { QString name, path; };
    std::vector<Entry> entries;
    for (const auto& info : dir.entryInfoList(QDir::Files | QDir::NoDotAndDotDot, QDir::NoSort))
        if (!info.isHidden() && openable(info.fileName()))
            entries.push_back({info.fileName(), info.isSymLink() ? canonical(info.filePath())
                                                                 : QDir::cleanPath(root + QLatin1Char('/') + info.fileName())});
    QCollator collator;
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::stable_sort(entries.begin(), entries.end(),
                     [&](const Entry& a, const Entry& b) { return collator.compare(a.name, b.name) < 0; });
    QStringList files;
    files.reserve(qsizetype(entries.size()));
    for (const auto& entry : entries) files.push_back(entry.path);
    return files;
}

QStringList expand(const QList<QUrl>& urls, bool keepAll) {
    QStringList out;
    QSet<QString> seen;
    const auto add = [&](const QString& path) {
        const auto k = key(path);
        if (seen.contains(k)) return;
        seen.insert(k);
        out.push_back(path);
    };
    for (const auto& url : urls) {
        if (!url.isLocalFile()) continue;
        const QFileInfo info(url.toLocalFile());
        if (info.isDir()) {
            for (const auto& file : folderFiles(info.filePath())) add(file);
        } else if (info.isFile() && (keepAll || openable(info.filePath()) || pairs::isPairFile(info.filePath()))) {
            add(canonical(info.filePath()));
        }
    }
    return out;
}

FrameOrder::FrameOrder(QString storeDirectory) : directory_(std::move(storeDirectory)) {}

QString FrameOrder::folderOf(const QStringList& frames) {
    QString folder;
    QSet<QString> parents;
    for (const auto& frame : frames) {
        if (pairs::isPairFile(frame)) continue;
        const QString parent = QFileInfo(frame).absolutePath();
        if (!parents.contains(key(parent))) {
            parents.insert(key(parent));
            folder = QDir::cleanPath(parent);
        }
    }
    return parents.size() == 1 ? folder : QString();
}

QString FrameOrder::fileFor(const QString& folder) const {
    // FrameOrder.url(for:): the folder's name and the first 16 hex digits of
    // the SHA-256 of its path -- here both case-folded: one folder on Windows
    // whatever its case.
    const QString folded = key(folder);
    const QByteArray digest = QCryptographicHash::hash(folded.toUtf8(), QCryptographicHash::Sha256).toHex().left(16);
    return QDir(directory_).filePath(QFileInfo(folded).fileName() + "-" + QString::fromLatin1(digest) + ".order.json");
}

bool FrameOrder::save(const QStringList& frames) const {
    const QString folder = folderOf(frames);
    if (folder.isEmpty() || directory_.isEmpty()) return false;
    QJsonArray names;
    for (const auto& frame : frames) names.push_back(QFileInfo(frame).fileName());
    if (!QDir().mkpath(directory_)) return false;
    // A failure is not reported to the user: the order is a convenience, and
    // the frames are where they were (FrameOrder.save).
    QSaveFile file(fileFor(folder));
    if (!file.open(QIODevice::WriteOnly)) return false;
    file.write(QJsonDocument(names).toJson(QJsonDocument::Compact));
    return file.commit();
}

QStringList FrameOrder::applied(const QStringList& listed) const {
    const QString folder = folderOf(listed);
    if (folder.isEmpty() || directory_.isEmpty()) return listed;
    QFile file(fileFor(folder));
    if (!file.open(QIODevice::ReadOnly)) return listed;
    const auto document = QJsonDocument::fromJson(file.readAll());
    if (!document.isArray()) return listed;
    QStringList names;
    for (const auto& value : document.array())
        if (value.isString()) names.push_back(value.toString());
    return ordered(listed, names);
}

QStringList FrameOrder::ordered(const QStringList& listed, const QStringList& names) {
    QHash<QString, int> rank;
    for (int i = 0; i < names.size(); ++i)
        if (!rank.contains(names[i].toCaseFolded())) rank.insert(names[i].toCaseFolded(), i);
    const auto rankOf = [&](const QString& path) { return rank.value(QFileInfo(path).fileName().toCaseFolded(), -1); };
    QStringList out;
    for (const auto& frame : listed)
        if (rankOf(frame) >= 0) out.push_back(frame);
    std::stable_sort(out.begin(), out.end(), [&](const QString& a, const QString& b) { return rankOf(a) < rankOf(b); });
    for (int i = 0; i < listed.size(); ++i) {
        if (rankOf(listed[i]) >= 0) continue;
        const int before = i > 0 ? int(out.indexOf(listed[i - 1])) : -1;
        out.insert(before >= 0 ? before + 1 : 0, listed[i]);
    }
    return out;
}

std::array<QPointF, 4> cropCorners(QSizeF picture, const output::Geometry& g) {
    const double W = std::max(1.0, picture.width()), H = std::max(1.0, picture.height());
    const double w = g.crop.width() * W, h = g.crop.height() * H;
    const double angle = g.straightenDegrees * std::acos(-1.0) / 180.0;
    const double cosine = std::cos(angle), sine = std::sin(angle);
    // FrameOutput.cpp straighten: the fixed output rectangle maps back into
    // the crop by a rotation shrunk by the zoom that keeps it covered.
    const double zoom = std::max(std::abs(cosine) + std::abs(sine) * h / std::max(w, 1e-9),
                                 std::abs(cosine) + std::abs(sine) * w / std::max(h, 1e-9));
    const double c = cosine / zoom, s = sine / zoom;
    const double cx = g.crop.center().x() * W, cy = g.crop.center().y() * H;
    std::array<QPointF, 4> out;
    const double dx[4] = {-w / 2, w / 2, w / 2, -w / 2}, dy[4] = {-h / 2, -h / 2, h / 2, h / 2};
    for (int i = 0; i < 4; ++i)
        out[i] = QPointF((cx + c * dx[i] + s * dy[i]) / W, (cy - s * dx[i] + c * dy[i]) / H);
    return out;
}

QImage cropMasked(const QImage& image, const output::Geometry& g) {
    if (image.isNull()) return image;
    const bool fullCrop = g.crop == QRectF(0, 0, 1, 1) && g.straightenDegrees == 0;
    if (fullCrop && g.quarterTurns == 0 && !g.flipHorizontal && !g.flipVertical) return image;
    QImage out = image;
    if (!fullCrop) {
        // Painted in the picture's own format (the raster engine paints the
        // half floats the rendered thumbnails are), else through RGBA64.
        out = image.copy();
        if (out.isNull()) return image;
        QPainter painter(&out);
        if (!painter.isActive()) {
            out = image.convertToFormat(QImage::Format_RGBX64);
            if (out.isNull() || !painter.begin(&out)) return image;
        }
        painter.setRenderHint(QPainter::Antialiasing);
        const auto corners = cropCorners(QSizeF(out.size()), g);
        QPainterPath path;
        path.setFillRule(Qt::OddEvenFill);
        path.addRect(QRectF(QPointF(0, 0), QSizeF(out.size())));
        QPolygonF inner;
        for (const auto& p : corners) inner << QPointF(p.x() * out.width(), p.y() * out.height());
        path.addPolygon(inner);
        path.closeSubpath();
        painter.fillPath(path, QColor::fromRgbF(0, 0, 0, float(kCropMaskOpacity)));
        painter.end();
        out.setColorSpace(image.colorSpace());
    }
    // The turns and flips as FrameOutput applyGeometry makes them.
    if (g.quarterTurns) out = out.transformed(QTransform().rotate(90 * g.quarterTurns), Qt::FastTransformation);
    if (g.flipHorizontal || g.flipVertical) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 9, 0)
        Qt::Orientations axes;
        if (g.flipHorizontal) axes |= Qt::Horizontal;
        if (g.flipVertical) axes |= Qt::Vertical;
        out = out.flipped(axes);
#else
        out = out.mirrored(g.flipHorizontal, g.flipVertical);
#endif
    }
    out.setColorSpace(image.colorSpace());
    return out;
}

}  // namespace spk::desktop::library
