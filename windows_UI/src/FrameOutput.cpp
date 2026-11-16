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
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
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
    case Format::TIFF16: case Format::PNG8: case Format::PNG16:
    case Format::JPEG8: case Format::HEIF8: break;
    default: fail(QStringLiteral("Unsupported export format"));
    }
    if(options.jpegQuality < 1 || options.jpegQuality > 100)
        fail(QStringLiteral("JPEG quality must be between 1 and 100"));
    if(options.maxLongEdge < 0)
        fail(QStringLiteral("Export long edge cannot be negative"));
    switch(options.outputSpace) {
    case OutputSpace::SRGB: case OutputSpace::DisplayP3:
    case OutputSpace::AdobeRGB: case OutputSpace::ProPhoto: break;
    default: fail(QStringLiteral("Unsupported export colour space"));
    }
    if(options.format==Format::HEIF8&&options.outputSpace!=OutputSpace::SRGB)
        fail(QStringLiteral("Windows HEIF export supports sRGB only"));
}
void validateExtension(const QFileInfo& destination,Format format) {
    const QString suffix=destination.suffix().toLower();
    const bool matches=format==Format::TIFF16?(suffix=="tif" || suffix=="tiff"):
        format==Format::JPEG8?(suffix=="jpg" || suffix=="jpeg"):
        format==Format::HEIF8?(suffix=="heic" || suffix=="heif"):suffix=="png";
    if(!matches) {
        const QString expected=format==Format::TIFF16?QStringLiteral(".tif or .tiff"):
            format==Format::JPEG8?QStringLiteral(".jpg or .jpeg"):
            format==Format::HEIF8?QStringLiteral(".heic or .heif"):QStringLiteral(".png");
        fail(QStringLiteral("Export file extension must match the selected format: ")+expected);
    }
}
QColorSpace profile(const fs::path& resources, OutputSpace outputSpace) {
    switch(outputSpace) {
    case OutputSpace::DisplayP3: return QColorSpace(QColorSpace::DisplayP3);
    case OutputSpace::AdobeRGB: return QColorSpace(QColorSpace::AdobeRgb);
    case OutputSpace::ProPhoto: return QColorSpace(QColorSpace::ProPhotoRgb);
    case OutputSpace::SRGB: break;
    }
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

QImage sourceFramePixels(const FramePtr& frame) {
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

struct DiCube {
    int size=0;
    std::vector<float> values;
};

std::shared_ptr<const DiCube> diCube(const fs::path& path) {
    static std::mutex mutex;
    static std::map<fs::path,std::shared_ptr<const DiCube>> cache;
    std::lock_guard lock(mutex);
    if(const auto found=cache.find(path);found!=cache.end())return found->second;
    QFile file(pathText(path));
    if(!file.open(QIODevice::ReadOnly))fail(QStringLiteral("Cannot read the DI view table"));
    auto cube=std::make_shared<DiCube>();
    for(QByteArray line:file.readAll().split('\n')) {
        line=line.trimmed();
        if(line.isEmpty()||line.startsWith('#'))continue;
        if(line.startsWith("LUT_3D_SIZE")) {
            bool ok=false;
            cube->size=line.split(' ').last().toInt(&ok);
            if(!ok)cube->size=0;
            continue;
        }
        const auto parts=line.simplified().split(' ');
        if(parts.size()!=3)continue;
        bool ok[3]{};
        const float values[3]{parts[0].toFloat(&ok[0]),parts[1].toFloat(&ok[1]),parts[2].toFloat(&ok[2])};
        if(ok[0]&&ok[1]&&ok[2])cube->values.insert(cube->values.end(),std::begin(values),std::end(values));
    }
    const auto cells=std::size_t(cube->size)*cube->size*cube->size;
    if(cube->size<2||cube->values.size()!=cells*3)
        fail(QStringLiteral("The DI view table is malformed"));
    cache.emplace(path,cube);
    return cube;
}

QImage diToSrgb(const QImage& source,const fs::path& table) {
    const auto cube=diCube(table);
    const auto input=source.convertToFormat(QImage::Format_RGBA64);
    QImage output(input.size(),QImage::Format_RGBA64);
    if(input.isNull()||output.isNull())fail(QStringLiteral("Cannot allocate the DI view"));
    const int n=cube->size;
    const float top=n-1;
    const auto at=[&](int r,int g,int b,int channel) {
        const std::size_t index=3*(std::size_t(r)+std::size_t(n)*(std::size_t(g)+std::size_t(n)*b));
        return cube->values[index+std::size_t(channel)];
    };
    for(int y=0;y<input.height();++y) {
        const auto* src=reinterpret_cast<const QRgba64*>(input.constScanLine(y));
        auto* dst=reinterpret_cast<QRgba64*>(output.scanLine(y));
        for(int x=0;x<input.width();++x) {
            const float p[3]{float(src[x].red())/65535.0f*top,float(src[x].green())/65535.0f*top,
                             float(src[x].blue())/65535.0f*top};
            int low[3],high[3];
            float fraction[3];
            for(int channel=0;channel<3;++channel) {
                low[channel]=std::min(int(std::floor(p[channel])),n-2);
                high[channel]=low[channel]+1;
                fraction[channel]=p[channel]-low[channel];
            }
            quint16 rgb[3]{};
            for(int channel=0;channel<3;++channel) {
                const float x00=at(low[0],low[1],low[2],channel)*(1-fraction[0])+
                                at(high[0],low[1],low[2],channel)*fraction[0];
                const float x10=at(low[0],high[1],low[2],channel)*(1-fraction[0])+
                                at(high[0],high[1],low[2],channel)*fraction[0];
                const float x01=at(low[0],low[1],high[2],channel)*(1-fraction[0])+
                                at(high[0],low[1],high[2],channel)*fraction[0];
                const float x11=at(low[0],high[1],high[2],channel)*(1-fraction[0])+
                                at(high[0],high[1],high[2],channel)*fraction[0];
                const float y0=x00*(1-fraction[1])+x10*fraction[1];
                const float y1=x01*(1-fraction[1])+x11*fraction[1];
                rgb[channel]=quint16(std::lround(
                    std::clamp(y0*(1-fraction[2])+y1*fraction[2],0.0f,1.0f)*65535.0f));
            }
            dst[x]=QRgba64::fromRgba64(rgb[0],rgb[1],rgb[2],src[x].alpha());
        }
    }
    output.setColorSpace(QColorSpace::ProPhotoRgb);
    output.convertToColorSpace(QColorSpace::SRgb);
    return output.convertToFormat(QImage::Format_RGBA64);
}

QImage framePixels(const FramePtr& frame) {
    auto pixels=sourceFramePixels(frame);
    if(frame->digital_intermediate&&!frame->di_view_table.empty())
        pixels=diToSrgb(pixels,frame->di_view_table);
    return pixels;
}

#ifdef _WIN32
struct ComApartment {
    HRESULT result=CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    ~ComApartment() { if(SUCCEEDED(result))CoUninitialize(); }
};

Microsoft::WRL::ComPtr<IWICImagingFactory> wicFactory() {
    Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
    return SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,
                                     IID_PPV_ARGS(&factory)))?factory:nullptr;
}

bool heifEncoderAvailable() {
    ComApartment com;
    const auto factory=wicFactory();
    if(!factory)return false;
    Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder;
    return SUCCEEDED(factory->CreateEncoder(GUID_ContainerFormatHeif,nullptr,&encoder))&&encoder;
}

void writeHeif(const QImage& source,const fs::path& output,const QString& metadata,int quality) {
    ComApartment com;
    if(source.width()<16||source.height()<16)
        fail(QStringLiteral("HEIF export requires at least 16 by 16 pixels"));
    const auto factory=wicFactory();
    if(!factory)fail(QStringLiteral("HEIF export requires the Windows HEIF Image Extension"));
    const auto pixels=source.convertToFormat(QImage::Format_ARGB32);
    if(pixels.isNull())fail(QStringLiteral("Cannot allocate the HEIF export"));
    Microsoft::WRL::ComPtr<IStream> stream;
    if(FAILED(CreateStreamOnHGlobal(nullptr,TRUE,&stream)))
        fail(QStringLiteral("Cannot allocate the HEIF output stream"));
    Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder;
    HRESULT result=factory->CreateEncoder(GUID_ContainerFormatHeif,nullptr,&encoder);
    if(FAILED(result))fail(QStringLiteral("The Windows HEIF encoder is unavailable"));
    result=encoder->Initialize(stream.Get(),WICBitmapEncoderNoCache);
    Microsoft::WRL::ComPtr<IWICBitmapFrameEncode> frame;
    Microsoft::WRL::ComPtr<IPropertyBag2> properties;
    if(SUCCEEDED(result))result=encoder->CreateNewFrame(&frame,&properties);
    if(SUCCEEDED(result))result=frame->Initialize(properties.Get());
    if(FAILED(result))fail(QStringLiteral("Cannot initialize HEIF encoding"));
    PROPBAG2 option{};
    option.pstrName=const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);value.vt=VT_R4;value.fltVal=std::clamp(quality,1,100)/100.0f;
    properties->Write(1,&option,&value);
    VariantClear(&value);
    if(FAILED(frame->SetSize(UINT(pixels.width()),UINT(pixels.height())))||
       FAILED(frame->SetResolution(96,96)))
        fail(QStringLiteral("Cannot size the HEIF export"));
    Microsoft::WRL::ComPtr<IWICBitmap> bitmap;
    if(SUCCEEDED(result)&&factory->CreateBitmapFromMemory(
            UINT(pixels.width()),UINT(pixels.height()),GUID_WICPixelFormat32bppBGRA,
            UINT(pixels.bytesPerLine()),UINT(pixels.sizeInBytes()),
            const_cast<BYTE*>(pixels.bits()),&bitmap)==S_OK)
        result=frame->WriteSource(bitmap.Get(),nullptr);
    else result=E_FAIL;
    if(SUCCEEDED(result)&&!metadata.isEmpty()) {
        Microsoft::WRL::ComPtr<IWICMetadataQueryWriter> writer;
        if(SUCCEEDED(frame->GetMetadataQueryWriter(&writer))) {
            PROPVARIANT text{};
            text.vt=VT_LPWSTR;
            text.pwszVal=reinterpret_cast<PWSTR>(const_cast<ushort*>(
                metadata.utf16()));
            writer->SetMetadataByName(L"/app1/ifd/{ushort=270}",&text);
        }
    }
    if(SUCCEEDED(result))result=frame->Commit();
    if(SUCCEEDED(result))result=encoder->Commit();
    HGLOBAL storage=nullptr;
    SIZE_T size=0;
    if(SUCCEEDED(result))result=GetHGlobalFromStream(stream.Get(),&storage);
    if(SUCCEEDED(result)) {
        size=GlobalSize(storage);
        QFile file(pathText(output));
        if(!file.open(QIODevice::WriteOnly|QIODevice::NewOnly))fail(file.errorString());
        const auto* bytes=static_cast<const uchar*>(GlobalLock(storage));
        const bool wrote=bytes&&size<=std::size_t(std::numeric_limits<qint64>::max())&&
            file.write(reinterpret_cast<const char*>(bytes),qint64(size))==qint64(size);
        if(bytes)GlobalUnlock(storage);
        if(!wrote||!file.flush())fail(QStringLiteral("Cannot write the HEIF export"));
    }
    if(FAILED(result))fail(QStringLiteral("Cannot encode HEIF export (Windows error %1)").arg(quint32(result),8,16,QChar('0')));
}
#endif

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
    if(!options.copyMetadata)
        for(const auto& key:output.textKeys())output.setText(key,QString());
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

QImage workingFrame(const FramePtr& frame) {
    return framePixels(frame);
}

bool formatAvailable(Format format) {
    const auto formats=QImageWriter::supportedImageFormats();
    switch(format) {
    case Format::TIFF16: return true;
    case Format::PNG8: case Format::PNG16: return formats.contains("png");
    case Format::JPEG8: return formats.contains("jpeg") || formats.contains("jpg");
    case Format::HEIF8:
#ifdef _WIN32
        return heifEncoderAvailable();
#else
        return false;
#endif
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
    // copyMetadata=false means no source metadata reaches the encoded file,
    // even when the caller still carries the original description.
    const auto metadata=options.copyMetadata ? options.metadata : QString();
    auto pixels=exportImage(fullRgba64,geometry,options);
    const auto colorSpace=profile(resources,options.outputSpace);
    if(!colorSpace.isValid())fail(QStringLiteral("The selected export colour profile is invalid"));
    if(options.outputSpace==OutputSpace::SRGB)
        pixels.setColorSpace(colorSpace);
    else {
        pixels.setColorSpace(QColorSpace::SRgb);
        pixels.convertToColorSpace(colorSpace);
        pixels.setColorSpace(colorSpace);
    }
    QTemporaryDir staging(target.absoluteDir().filePath(QStringLiteral(".spektralab-export-XXXXXX")));
    if(!staging.isValid())fail(QStringLiteral("Cannot create an export temporary file in this folder"));
    const auto partial=nativePath(staging.filePath(QStringLiteral("output.partial")));
    if(options.format==Format::HEIF8) {
#ifdef _WIN32
        writeHeif(pixels,partial,metadata,options.jpegQuality);
#else
        fail(QStringLiteral("HEIF export is unavailable on this platform"));
#endif
    } else if(options.format==Format::TIFF16) {
        const auto icc=nativePath(staging.filePath(QStringLiteral("output.icc")));
        QFile profileFile(pathText(icc));
        if(!profileFile.open(QIODevice::WriteOnly|QIODevice::NewOnly))fail(profileFile.errorString());
        const auto profileBytes=colorSpace.iccProfile();
        if(profileFile.write(profileBytes)!=profileBytes.size()||!profileFile.flush())
            fail(QStringLiteral("Cannot write the export ICC profile"));
        profileFile.close();
        std::string error;
        if(!io::write_srgb_tiff(partial,reinterpret_cast<const std::uint16_t*>(pixels.constBits()),
                std::uint32_t(pixels.width()),std::uint32_t(pixels.height()),
                std::uint32_t(pixels.bytesPerLine()/8),icc,error))
            throw std::runtime_error(error);
    } else {
        const auto format=options.format==Format::JPEG8?QByteArray("jpeg"):QByteArray("png");
        // Closing the QFile before publication ensures no partially written
        // image can become the destination, including on encoder failure.
        QFile file(pathText(partial));
        if(!file.open(QIODevice::WriteOnly|QIODevice::NewOnly))fail(file.errorString());
        QImageWriter writer(&file,format);
        if(options.format==Format::JPEG8)writer.setQuality(options.jpegQuality);
        if(!metadata.isEmpty())writer.setText(QStringLiteral("Description"),metadata);
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
    auto effective=options;
    if(effective.copyMetadata&&effective.metadata.isEmpty()&&frame) {
        const auto& metadata=frame->metadata;
        if(!metadata.make.empty()||!metadata.model.empty())
            effective.metadata=QString::fromStdString(metadata.make+" "+metadata.model).trimmed();
    }
    exportImageFile(framePixels(frame),destination,geometry,effective,resources);
}
} // namespace spk::desktop::output
