#include "FrameOutput.hpp"
#include "io/image_writer.hpp"
#include <QColorSpace>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageWriter>
#include <QTemporaryDir>
#include <QTransform>
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace spk::desktop::output {
namespace {
namespace fs = std::filesystem;
[[noreturn]] void fail(const QString& message) {
    throw std::runtime_error(message.toUtf8().toStdString());
}
QString pathText(const fs::path& path) {
#ifdef _WIN32
    return QString::fromStdWString(path.wstring());
#else
    return QString::fromStdString(path.string());
#endif
}
fs::path nativePath(const QString& path) {
#ifdef _WIN32
    return fs::path(path.toStdWString());
#else
    return fs::path(path.toStdString());
#endif
}
void validateOptions(const ExportOptions& options) {
    switch(options.format) {
    case Format::TIFF16: case Format::PNG8: case Format::PNG16: case Format::JPEG8: break;
    default: fail(QStringLiteral("Unsupported export format"));
    }
    if(options.jpegQuality < 1 || options.jpegQuality > 100)
        fail(QStringLiteral("JPEG quality must be between 1 and 100"));
    if(options.maxLongEdge < 0)
        fail(QStringLiteral("Export long edge cannot be negative"));
}
void validateExtension(const QFileInfo& destination,Format format) {
    const QString suffix=destination.suffix().toLower();
    const bool matches=format==Format::TIFF16?(suffix=="tif" || suffix=="tiff"):
        format==Format::JPEG8?(suffix=="jpg" || suffix=="jpeg"):suffix=="png";
    if(!matches) {
        const QString expected=format==Format::TIFF16?QStringLiteral(".tif or .tiff"):
            format==Format::JPEG8?QStringLiteral(".jpg or .jpeg"):QStringLiteral(".png");
        fail(QStringLiteral("Export file extension must match the selected format: ")+expected);
    }
}
QColorSpace profile(const fs::path& resources) {
    QFile file(pathText(resources / "io" / "sRGB.icc"));
    if(!file.open(QIODevice::ReadOnly) || file.size() < 132 || file.size() > 4*1024*1024)
        fail(QStringLiteral("Cannot read the bundled sRGB ICC profile"));
    const auto bytes=file.readAll();
    if(bytes.size()!=file.size())fail(QStringLiteral("Cannot read the complete sRGB ICC profile"));
    const auto space=QColorSpace::fromIccProfile(bytes);
    if(!space.isValid())fail(QStringLiteral("The bundled sRGB ICC profile is invalid"));
    return space;
}
void publish(const fs::path& partial,const fs::path& destination) {
#ifdef _WIN32
    // No MOVEFILE_REPLACE_EXISTING: the filesystem, not a racy exists check,
    // is the final arbiter. Same-directory staging keeps this on one volume.
    if(!MoveFileExW(partial.c_str(),destination.c_str(),MOVEFILE_WRITE_THROUGH))
        fail(QStringLiteral("Cannot publish export without replacing an existing file (Windows error %1)")
             .arg(GetLastError()));
#else
    if(!QFile::rename(pathText(partial),pathText(destination)))
        fail(QStringLiteral("Cannot publish export without replacing an existing file"));
#endif
}

QImage framePixels(const FramePtr& frame) {
    if(!frame)fail(QStringLiteral("No rendered photograph to export"));
    const auto& result=frame->pixels();
    if(!result.rgba16 || result.width==0 || result.height==0 || result.row_stride_px<result.width ||
       result.width>std::uint32_t(std::numeric_limits<int>::max()) ||
       result.height>std::uint32_t(std::numeric_limits<int>::max()))
        fail(QStringLiteral("The rendered photograph has invalid storage"));
    // The caller retains its immutable FramePtr for every use of this view.
    return QImage(reinterpret_cast<const uchar*>(result.rgba16),int(result.width),int(result.height),
                  qsizetype(result.row_stride_px)*8,QImage::Format_RGBA64);
}

QImage straighten(const QImage& source,double degrees) {
    if(degrees==0)return source;
    const auto pixels=source.convertToFormat(QImage::Format_RGBA64);
    QImage output(pixels.size(),QImage::Format_RGBA64);
    if(output.isNull() || pixels.isNull())fail(QStringLiteral("Cannot allocate the straightened photograph"));
    const int width=pixels.width(),height=pixels.height();
    const double angle=degrees*std::acos(-1.0)/180.0;
    const double cosine=std::cos(angle),sine=std::sin(angle);
    // Inverse-map the fixed output rectangle into the cropped source. The
    // larger projection determines the zoom that keeps all four image edges
    // covered. Edge-clamping is the usual half-pixel image sampling boundary.
    const double zoom=std::max(std::abs(cosine)+std::abs(sine)*height/width,
                               std::abs(cosine)+std::abs(sine)*width/height);
    const double c=cosine/zoom,s=sine/zoom;
    const double centerX=(width-1)*.5,centerY=(height-1)*.5;
    for(int y=0;y<height;++y) {
        auto* row=reinterpret_cast<QRgba64*>(output.scanLine(y));
        for(int x=0;x<width;++x) {
            const double sourceX=std::clamp(centerX+c*(x-centerX)+s*(y-centerY),0.0,double(width-1));
            const double sourceY=std::clamp(centerY-s*(x-centerX)+c*(y-centerY),0.0,double(height-1));
            const int x0=int(sourceX),y0=int(sourceY),x1=std::min(x0+1,width-1),y1=std::min(y0+1,height-1);
            const double fx=sourceX-x0,fy=sourceY-y0;
            const auto* top=reinterpret_cast<const QRgba64*>(pixels.constScanLine(y0));
            const auto* bottom=reinterpret_cast<const QRgba64*>(pixels.constScanLine(y1));
            auto channel=[&](quint16 a,quint16 b,quint16 d,quint16 e) {
                return quint16(std::clamp(std::lround((a+(b-a)*fx)*(1-fy)+(d+(e-d)*fx)*fy),0L,65535L));
            };
            row[x]=QRgba64::fromRgba64(channel(top[x0].red(),top[x1].red(),bottom[x0].red(),bottom[x1].red()),
                channel(top[x0].green(),top[x1].green(),bottom[x0].green(),bottom[x1].green()),
                channel(top[x0].blue(),top[x1].blue(),bottom[x0].blue(),bottom[x1].blue()),
                channel(top[x0].alpha(),top[x1].alpha(),bottom[x0].alpha(),bottom[x1].alpha()));
        }
    }
    output.setColorSpace(source.colorSpace());
    return output;
}

QImage applyGeometry(const QImage& source,const Geometry& geometry) {
    validateGeometry(source.size(),geometry);
    const auto rect=cropPixels(source.size(),geometry.crop);
    QImage output=rect==source.rect()?source:source.copy(rect);
    if(output.isNull())fail(QStringLiteral("Cannot allocate the cropped photograph"));
    output=straighten(output,geometry.straightenDegrees);
    if(geometry.quarterTurns)
        output=output.transformed(QTransform().rotate(90*geometry.quarterTurns),Qt::FastTransformation);
    if(geometry.flipHorizontal || geometry.flipVertical) {
#if QT_VERSION >= QT_VERSION_CHECK(6, 9, 0)
        Qt::Orientations axes;
        if(geometry.flipHorizontal)axes|=Qt::Horizontal;
        if(geometry.flipVertical)axes|=Qt::Vertical;
        output=output.flipped(axes);
#else
        output=output.mirrored(geometry.flipHorizontal,geometry.flipVertical);
#endif
    }
    if(output.isNull())fail(QStringLiteral("Cannot allocate the transformed photograph"));
    return output;
}
}

QRect cropPixels(QSize fullSize,QRectF crop) {
    if(fullSize.width() <= 0 || fullSize.height() <= 0 ||
       !std::isfinite(crop.x()) || !std::isfinite(crop.y()) ||
       !std::isfinite(crop.width()) || !std::isfinite(crop.height()) ||
       crop.width() <= 0 || crop.height() <= 0 || crop.x() < 0 || crop.y() < 0 ||
       crop.right() > 1 || crop.bottom() > 1)
        fail(QStringLiteral("Crop must be a finite, positive rectangle inside the photograph"));
    const int left=std::clamp(int(std::lround(crop.left()*fullSize.width())),0,fullSize.width()-1);
    const int top=std::clamp(int(std::lround(crop.top()*fullSize.height())),0,fullSize.height()-1);
    const int right=std::clamp(int(std::lround(crop.right()*fullSize.width())),left+1,fullSize.width());
    const int bottom=std::clamp(int(std::lround(crop.bottom()*fullSize.height())),top+1,fullSize.height());
    return {left,top,right-left,bottom-top};
}

QImage displayImage(const QImage& full8,QRectF crop) {
    return displayImage(full8,Geometry{crop});
}

void validateGeometry(QSize size,const Geometry& geometry) {
    cropPixels(size,geometry.crop);
    if(geometry.quarterTurns<0 || geometry.quarterTurns>3)
        fail(QStringLiteral("Quarter turns must be between 0 and 3"));
    if(!std::isfinite(geometry.straightenDegrees) || std::abs(geometry.straightenDegrees)>45)
        fail(QStringLiteral("Straightening must be between -45 and +45 degrees"));
}

QImage displayImage(const QImage& full8,const Geometry& geometry) {
    auto output=applyGeometry(full8,geometry);
    if(output.format()!=full8.format())output=output.convertToFormat(full8.format());
    if(output.isNull())fail(QStringLiteral("Cannot allocate the transformed preview"));
    return output;
}

QImage exportImage(const QImage& fullRgba64,QRectF crop,const ExportOptions& options) {
    return exportImage(fullRgba64,Geometry{crop},options);
}

QImage exportImage(const QImage& fullRgba64,const Geometry& geometry,const ExportOptions& options) {
    validateOptions(options);
    if(fullRgba64.isNull() || fullRgba64.format()!=QImage::Format_RGBA64)
        fail(QStringLiteral("Export requires an RGBA16 frame"));
    validateGeometry(fullRgba64.size(),geometry);
    const auto rect=cropPixels(fullRgba64.size(),geometry.crop);
    // Validate only the exported region: padding is not part of the image.
    for(int y=rect.top();y<=rect.bottom();++y) {
        const auto* row=reinterpret_cast<const QRgba64*>(fullRgba64.constScanLine(y));
        for(int x=rect.left();x<=rect.right();++x)
            if(row[x].alpha()!=65535)fail(QStringLiteral("Export requires opaque pixels"));
    }
    QImage output=applyGeometry(fullRgba64,geometry);
    if(options.maxLongEdge && std::max(output.width(),output.height())>options.maxLongEdge) {
        const double ratio=double(options.maxLongEdge)/std::max(output.width(),output.height());
        const QSize size(std::max(1,int(std::lround(output.width()*ratio))),
                         std::max(1,int(std::lround(output.height()*ratio))));
        output=output.scaled(size,Qt::IgnoreAspectRatio,Qt::SmoothTransformation);
        if(output.isNull())fail(QStringLiteral("Cannot allocate the resized export"));
    }
    if(options.format==Format::PNG8 || options.format==Format::JPEG8)
        output=output.convertToFormat(QImage::Format_RGB888);
    if(output.isNull())fail(QStringLiteral("Cannot allocate the export pixels"));
    return output;
}

QImage displayFrame(const FramePtr& frame,const Geometry& geometry) {
    const auto pixels=exportImage(framePixels(frame),geometry,{});
    auto output=pixels.convertToFormat(QImage::Format_ARGB32);
    if(output.isNull())fail(QStringLiteral("Cannot allocate the transformed preview"));
    output.setColorSpace(QColorSpace::SRgb);
    return output;
}

bool formatAvailable(Format format) {
    const auto formats=QImageWriter::supportedImageFormats();
    switch(format) {
    case Format::TIFF16: return true;
    case Format::PNG8: case Format::PNG16: return formats.contains("png");
    case Format::JPEG8: return formats.contains("jpeg") || formats.contains("jpg");
    }
    return false;
}

void exportImageFile(const QImage& fullRgba64,const fs::path& destination,
                     QRectF crop,const ExportOptions& options,const fs::path& resources) {
    exportImageFile(fullRgba64,destination,Geometry{crop},options,resources);
}

void exportImageFile(const QImage& fullRgba64,const fs::path& destination,
                     const Geometry& geometry,const ExportOptions& options,const fs::path& resources) {
    validateOptions(options);
    if(!formatAvailable(options.format))fail(QStringLiteral("This export format is not installed"));
    if(destination.empty() || destination.filename().empty())fail(QStringLiteral("Choose an export file name"));
    const QFileInfo target(pathText(destination));
    validateExtension(target,options.format);
    if(target.exists() || target.isSymLink())fail(QStringLiteral("The export file already exists"));
    if(!target.absoluteDir().exists())fail(QStringLiteral("The export folder does not exist"));
    auto pixels=exportImage(fullRgba64,geometry,options);
    pixels.setColorSpace(profile(resources));
    QTemporaryDir staging(target.absoluteDir().filePath(QStringLiteral(".spektralab-export-XXXXXX")));
    if(!staging.isValid())fail(QStringLiteral("Cannot create an export temporary file in this folder"));
    const auto partial=nativePath(staging.filePath(QStringLiteral("output.partial")));
    if(options.format==Format::TIFF16) {
        std::string error;
        if(!io::write_srgb_tiff(partial,reinterpret_cast<const std::uint16_t*>(pixels.constBits()),
                std::uint32_t(pixels.width()),std::uint32_t(pixels.height()),
                std::uint32_t(pixels.bytesPerLine()/8),resources/"io"/"sRGB.icc",error))
            throw std::runtime_error(error);
    } else {
        const auto format=options.format==Format::JPEG8?QByteArray("jpeg"):QByteArray("png");
        // Closing the QFile before publication ensures no partially written
        // image can become the destination, including on encoder failure.
        QFile file(pathText(partial));
        if(!file.open(QIODevice::WriteOnly|QIODevice::NewOnly))fail(file.errorString());
        QImageWriter writer(&file,format);
        if(options.format==Format::JPEG8)writer.setQuality(options.jpegQuality);
        if(!writer.write(pixels))fail(QStringLiteral("Cannot encode export: ")+writer.errorString());
        if(!file.flush())fail(QStringLiteral("Cannot flush export: ")+file.errorString());
        file.close();
    }
    publish(partial,nativePath(target.absoluteFilePath()));
}

void exportFrame(const FramePtr& frame,const fs::path& destination,QRectF crop,
                 const ExportOptions& options,const fs::path& resources) {
    exportFrame(frame,destination,Geometry{crop},options,resources);
}

void exportFrame(const FramePtr& frame,const fs::path& destination,const Geometry& geometry,
                 const ExportOptions& options,const fs::path& resources) {
    // The caller's immutable FramePtr stays alive throughout this synchronous
    // function; crop/downsize/detach cannot modify its retained RGBA16 result.
    exportImageFile(framePixels(frame),destination,geometry,options,resources);
}
} // namespace spk::desktop::output
