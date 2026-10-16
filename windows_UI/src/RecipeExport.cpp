#include "RecipeExport.hpp"
#include "FrameImage.hpp"
#include "io/image_writer.hpp"
#include "output.hpp"
#include "image_io.hpp"
#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageWriter>
#include <QTemporaryDir>
#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace spk::desktop::exporting {
namespace {
namespace fs = std::filesystem;
using recipes::Format;

[[noreturn]] void fail(const QString& message) { throw std::runtime_error(message.toUtf8().toStdString()); }
QString pathText(const fs::path& p) { return QString::fromStdWString(p.wstring()); }
fs::path nativePath(const QString& p) { return fs::path(p.toStdWString()); }
QString text(const std::string& s) { return QString::fromUtf8(s.data(), qsizetype(s.size())); }

// The engine frame's own RGBA16 as an RGBA64 view (FrameOutput's rule: the
// caller keeps the FramePtr alive for every use of the view).
QImage framePixels(const FramePtr& frame) {
    if(!frame)fail(QStringLiteral("No rendered photograph to export"));
    const auto& r=frame->pixels();
    if(!r.rgba16||r.width==0||r.height==0||r.row_stride_px<r.width||
       r.width>std::uint32_t(std::numeric_limits<int>::max())||r.height>std::uint32_t(std::numeric_limits<int>::max()))
        fail(QStringLiteral("The rendered photograph has invalid storage"));
    return QImage(reinterpret_cast<const uchar*>(r.rgba16),int(r.width),int(r.height),
                  qsizetype(r.row_stride_px)*8,QImage::Format_RGBA64);
}

std::uint32_t crc32(const std::uint8_t* d,std::size_t n) {
    static const auto table=[]{
        std::array<std::uint32_t,256> t{};
        for(std::uint32_t i=0;i<256;++i){std::uint32_t c=i;for(int k=0;k<8;++k)c=c&1?0xEDB88320u^(c>>1):c>>1;t[i]=c;}
        return t;
    }();
    std::uint32_t c=0xFFFFFFFFu;
    for(std::size_t i=0;i<n;++i)c=table[(c^d[i])&0xFF]^(c>>8);
    return ~c;
}
void put32be(QByteArray& b,std::uint32_t v){b.append(char(v>>24));b.append(char(v>>16));b.append(char(v>>8));b.append(char(v));}

// EXIF into a finished JPEG: an APP1 "Exif" segment after SOI and, when the
// encoder wrote one, after the JFIF APP0 that must stay first.
QByteArray withJpegExif(const QByteArray& jpeg,const std::vector<std::uint8_t>& block) {
    if(jpeg.size()<4||std::uint8_t(jpeg[0])!=0xFF||std::uint8_t(jpeg[1])!=0xD8)fail(QStringLiteral("JPEG encode produced no image"));
    if(block.size()+8>65535)return jpeg;
    qsizetype at=2;
    if(std::uint8_t(jpeg[2])==0xFF&&std::uint8_t(jpeg[3])==0xE0&&jpeg.size()>6)
        at=4+((std::uint8_t(jpeg[4])<<8)|std::uint8_t(jpeg[5]));
    QByteArray seg;
    seg.append(char(0xFF));seg.append(char(0xE1));
    const auto len=std::uint16_t(block.size()+8);
    seg.append(char(len>>8));seg.append(char(len&0xFF));
    seg.append("Exif",4);seg.append('\0');seg.append('\0');
    seg.append(reinterpret_cast<const char*>(block.data()),qsizetype(block.size()));
    QByteArray out=jpeg.left(at);out+=seg;out+=jpeg.mid(at);
    return out;
}
// EXIF into a finished PNG: an eXIf chunk straight after IHDR.
QByteArray withPngExif(const QByteArray& png,const std::vector<std::uint8_t>& block) {
    if(png.size()<33||png.mid(12,4)!="IHDR")fail(QStringLiteral("PNG encode produced no image"));
    QByteArray chunk("eXIf");chunk.append(reinterpret_cast<const char*>(block.data()),qsizetype(block.size()));
    QByteArray seg;put32be(seg,std::uint32_t(block.size()));seg+=chunk;
    put32be(seg,crc32(reinterpret_cast<const std::uint8_t*>(chunk.constData()),std::size_t(chunk.size())));
    QByteArray out=png.left(33);out+=seg;out+=png.mid(33);
    return out;
}

std::vector<std::uint8_t> bytes(const QByteArray& b) { return {b.begin(),b.end()}; }

// The partial file, published by one move: without overwrite the filesystem
// (no MOVEFILE_REPLACE_EXISTING), not an exists check, is the arbiter.
Published publish(const fs::path& partial,const fs::path& destination,bool overwrite) {
#ifdef _WIN32
    DWORD flags=MOVEFILE_WRITE_THROUGH|(overwrite?MOVEFILE_REPLACE_EXISTING:0);
    if(!MoveFileExW(partial.c_str(),destination.c_str(),flags)) {
        const DWORD error=GetLastError();
        if(!overwrite&&(error==ERROR_ALREADY_EXISTS||error==ERROR_FILE_EXISTS))return Published::exists;
        fail(QStringLiteral("Cannot publish the export (Windows error %1)").arg(error));
    }
#else
    if(!overwrite&&QFileInfo::exists(pathText(destination)))return Published::exists;
    if(overwrite)QFile::remove(pathText(destination));
    if(!QFile::rename(pathText(partial),pathText(destination)))fail(QStringLiteral("Cannot publish the export"));
#endif
    return Published::written;
}

void writeBytes(const fs::path& partial,const QByteArray& data) {
    QFile file(pathText(partial));
    if(!file.open(QIODevice::WriteOnly|QIODevice::NewOnly))fail(file.errorString());
    if(file.write(data)!=data.size()||!file.flush())fail(QStringLiteral("Cannot write export: ")+file.errorString());
    file.close();
}

std::vector<std::uint16_t> interleaved16(const QImage& rgba64) {
    std::vector<std::uint16_t> out(std::size_t(rgba64.width())*rgba64.height()*3);
    for(int y=0;y<rgba64.height();++y) {
        const auto* row=reinterpret_cast<const std::uint16_t*>(rgba64.constScanLine(y));
        auto* dst=out.data()+std::size_t(y)*rgba64.width()*3;
        for(int x=0;x<rgba64.width();++x){dst[3*x]=row[4*x];dst[3*x+1]=row[4*x+1];dst[3*x+2]=row[4*x+2];}
    }
    return out;
}
std::vector<std::uint8_t> interleaved8(const QImage& rgb888) {
    std::vector<std::uint8_t> out(std::size_t(rgb888.width())*rgb888.height()*3);
    for(int y=0;y<rgb888.height();++y)
        std::memcpy(out.data()+std::size_t(y)*rgb888.width()*3,rgb888.constScanLine(y),std::size_t(rgb888.width())*3);
    return out;
}

// The preview page: the file's own pixels, smaller (Exporter.preview(of:)),
// long edge at most 2048.
constexpr int kPreviewLongEdge=2048;
QImage previewOf(const QImage& image) {
    const int edge=std::max(image.width(),image.height());
    if(edge<=kPreviewLongEdge)return image;
    const double s=double(kPreviewLongEdge)/edge;
    return image.scaled(std::max(1,int(std::lround(image.width()*s))),std::max(1,int(std::lround(image.height()*s))),
                        Qt::IgnoreAspectRatio,Qt::SmoothTransformation);
}

// Whether every colour of `inner` lies inside `outer`'s gamut, for the
// engine spaces an export meets (their chromaticity triangles, the CIE
// values: each of the left is contained in each of the right).
bool holds(const std::string& outer,const std::string& inner) {
    if(outer==inner)return true;
    if(outer=="ProPhoto RGB")return inner=="sRGB"||inner=="Display P3"||inner=="Adobe RGB (1998)"||
                                     inner=="ITU-R BT.709"||inner=="ITU-R BT.2020";
    if(outer=="ITU-R BT.2020")return inner=="sRGB"||inner=="Display P3"||inner=="ITU-R BT.709"||inner=="Adobe RGB (1998)";
    if(outer=="Display P3"||outer=="Adobe RGB (1998)")return inner=="sRGB"||inner=="ITU-R BT.709";
    if(outer=="sRGB")return inner=="ITU-R BT.709";
    return false;
}

// The Cineon-to-ProPhoto view LUT, parsed once.
struct Cube { int size=0; std::vector<float> rgb; };
const Cube& diViewCube(const fs::path& resources) {
    static std::once_flag once;
    static Cube cube;
    std::call_once(once,[&resources]{
        QFile file(pathText(resources/"di"/"SpektraLab DI view, Cineon to ProPhoto RGB.cube"));
        if(!file.open(QIODevice::ReadOnly))return;
        const QByteArray all=file.readAll();
        const char* p=all.constData();const char* end=p+all.size();
        Cube c;
        while(p<end) {
            const char* eol=static_cast<const char*>(std::memchr(p,'\n',std::size_t(end-p)));if(!eol)eol=end;
            if(p<eol&&(std::isdigit(static_cast<unsigned char>(*p))||*p=='-'||*p=='.')) {
                char* q=nullptr;
                const float r=std::strtof(p,&q),g=std::strtof(q,&q),b=std::strtof(q,&q);
                c.rgb.push_back(r);c.rgb.push_back(g);c.rgb.push_back(b);
            } else if(eol-p>11&&std::strncmp(p,"LUT_3D_SIZE",11)==0) c.size=std::atoi(p+11);
            p=eol+1;
        }
        if(c.size>1&&c.rgb.size()==std::size_t(c.size)*c.size*c.size*3)cube=std::move(c);
    });
    return cube;
}
}

QByteArray iccProfile(const std::string& space,const fs::path& resources) {
    if(space=="sRGB") {
        QFile file(pathText(resources/"io"/"sRGB.icc"));
        if(!file.open(QIODevice::ReadOnly)||file.size()<132||file.size()>4*1024*1024)
            fail(QStringLiteral("Cannot read the bundled sRGB ICC profile"));
        return file.readAll();
    }
    QColorSpace tag=display::colorSpace({space,true});
    for(const auto& e:recipes::colorSpaces())if(e.engine==space)tag.setDescription(e.name);
    if(tag.description().isEmpty())tag.setDescription(text(space));
    const auto icc=tag.iccProfile();
    if(icc.size()<132)fail(QStringLiteral("Cannot make an ICC profile for ")+text(space));
    return icc;
}

spkhost::OutputTransform exportTransform(const std::string& from,const std::string& to,spk_engine* engine) {
    if(!engine)fail(QStringLiteral("No engine to convert the export with"));
    spkhost::OutputTransform transform;
    std::string error;
    // Gamut-mapped once (ARCHITECTURE.md 7.5): the engine already mapped the
    // frame into its own space, so a destination that holds all of that
    // space (sRGB into Display P3, anything into ProPhoto) takes a plain
    // colorimetric conversion -- a second CAM16-UCS pass would roll the
    // highlights and the saturated colours a second time. Out of a wider
    // space (the working space into sRGB, Milestone B) it is the macOS
    // export's setting: CAM16-UCS's chroma knee into the recipe's gamut, and
    // *not* its lightness shoulder, which the engine already ran before it
    // encoded the working space (ColourManagement.swift:153-164,
    // gamutCompressionWithoutLightness).
    const char* spec=holds(to,from)?R"({"algorithm":"off","lightness_compression_active":false})"
                                   :R"({"lightness_compression_active":false})";
    if(!transform.fetch(engine,from,to,error,spec))
        fail(QStringLiteral("Could not convert to the recipe's colour space: ")+text(error));
    return transform;
}

Converted convert(const QImage& rgba64,const OutputEncoding& from,const std::string& to,spk_engine* engine) {
    if(rgba64.isNull()||rgba64.format()!=QImage::Format_RGBA64)fail(QStringLiteral("Conversion needs an RGBA16 image"));
    Converted out;
    if(from.color_space==to&&from.cctf_encoding){out.rgba64=rgba64;out.identity=true;return out;}
    if(!from.cctf_encoding)fail(QStringLiteral("The frame is linear %1; the export converts encoded frames").arg(text(from.color_space)));
    const auto transform=exportTransform(from.color_space,to,engine);
    const int w=rgba64.width(),h=rgba64.height();
    out.rgba64=QImage(w,h,QImage::Format_RGBA64);
    if(out.rgba64.isNull())fail(QStringLiteral("Cannot allocate the converted export"));
    // In bands: a 45 MP frame as one float buffer would be half a gigabyte.
    constexpr int band=256;
    std::vector<float> linear;std::vector<std::uint16_t> encoded;
    std::uint64_t clipped=0;
    const auto stride=std::uint32_t(rgba64.bytesPerLine()/8);
    for(int y0=0;y0<h;y0+=band) {
        const int rows=std::min(band,h-y0);
        transform.to_linear(reinterpret_cast<const std::uint16_t*>(rgba64.constScanLine(y0)),std::uint32_t(w),
                            std::uint32_t(rows),stride,linear);
        for(std::size_t p=0;p<linear.size();p+=3) {
            const float r=linear[p],g=linear[p+1],b=linear[p+2];
            constexpr float lo=-1e-4f,hi=1.0f+1e-4f;
            if(r<lo||g<lo||b<lo||r>hi||g>hi||b>hi)++clipped;
        }
        transform.encode_rgba16(linear,encoded);
        for(int y=0;y<rows;++y)
            std::memcpy(out.rgba64.scanLine(y0+y),encoded.data()+std::size_t(y)*w*4,std::size_t(w)*8);
    }
    out.clippedFraction=double(clipped)/(double(w)*h);
    return out;
}

Published writeImage(const QImage& pixels,const std::string& space,const fs::path& destination,
                     const WriteOptions& o,const fs::path& resources) {
    if(pixels.isNull()||pixels.format()!=QImage::Format_RGBA64)fail(QStringLiteral("The writer needs RGBA16 pixels"));
    if(destination.empty()||destination.filename().empty())fail(QStringLiteral("Choose an export file name"));
    const QFileInfo target(pathText(destination));
    if(!o.overwrite&&(target.exists()||target.isSymLink()))return Published::exists;
    if(!target.absoluteDir().exists())fail(QStringLiteral("The export folder does not exist"));
    const QByteArray icc=o.untagged?QByteArray():iccProfile(space,resources);
    const std::vector<std::uint8_t> exifBlock=o.exif?spkhost::exif_block(*o.exif,std::uint32_t(pixels.width()),
                                                                         std::uint32_t(pixels.height()))
                                                   :std::vector<std::uint8_t>{};
    QTemporaryDir staging(target.absoluteDir().filePath(QStringLiteral(".spektralab-export-XXXXXX")));
    if(!staging.isValid())fail(QStringLiteral("Cannot create an export temporary file in this folder"));
    const auto partial=nativePath(staging.filePath(QStringLiteral("output.partial")));
    const bool tiff=o.format==Format::tiff||o.format==Format::di;
    if(tiff) {
        const bool legacy=space=="sRGB"&&!o.untagged&&!o.exif&&!o.preview;
        if(legacy) {
            // FrameOutput's own writer: the same bytes an sRGB export has
            // always produced.
            std::string error;
            if(!io::write_srgb_tiff(partial,reinterpret_cast<const std::uint16_t*>(pixels.constBits()),
                    std::uint32_t(pixels.width()),std::uint32_t(pixels.height()),std::uint32_t(pixels.bytesPerLine()/8),
                    resources/"io"/"sRGB.icc",error))
                throw std::runtime_error(error);
        } else {
            const auto rgb=interleaved16(pixels);
            spkhost::TiffPreview page;std::vector<std::uint8_t> pageRgb;
            if(o.preview) {
                QImage reduced=previewOf(o.previewImage.isNull()?pixels:o.previewImage).convertToFormat(QImage::Format_RGB888);
                pageRgb=interleaved8(reduced);
                page.rgb=pageRgb.data();page.width=std::uint32_t(reduced.width());page.height=std::uint32_t(reduced.height());
                const QColorSpace tag=o.previewImage.isNull()?QColorSpace():o.previewImage.colorSpace();
                page.icc=bytes(tag.isValid()?tag.iccProfile():icc);
            }
            std::vector<std::uint8_t> file;std::string error;
            if(!spkhost::encode_tiff(rgb.data(),std::uint32_t(pixels.width()),std::uint32_t(pixels.height()),16,
                                     bytes(icc),file,error,o.exif,o.preview?&page:nullptr))
                throw std::runtime_error(error);
            writeBytes(partial,QByteArray(reinterpret_cast<const char*>(file.data()),qsizetype(file.size())));
        }
    } else {
        // Qt's encoders, as FrameOutput has always used them: the depth
        // reduction is QImage's, the profile travels as the colour space.
        QImage eight=pixels.convertToFormat(QImage::Format_RGB888);
        if(eight.isNull())fail(QStringLiteral("Cannot allocate the export pixels"));
        eight.setColorSpace(QColorSpace::fromIccProfile(icc));
        QBuffer buffer;buffer.open(QIODevice::WriteOnly);
        QImageWriter writer(&buffer,o.format==Format::jpeg?QByteArray("jpeg"):QByteArray("png"));
        if(o.format==Format::jpeg)writer.setQuality(o.jpegQuality);
        if(!writer.write(eight))fail(QStringLiteral("Cannot encode export: ")+writer.errorString());
        QByteArray data=buffer.data();
        if(!exifBlock.empty())data=o.format==Format::jpeg?withJpegExif(data,exifBlock):withPngExif(data,exifBlock);
        writeBytes(partial,data);
    }
    return publish(partial,nativePath(target.absoluteFilePath()),o.overwrite);
}

std::optional<spkhost::Exif> exifFor(const fs::path& source,const recipes::Metadata& m,const std::string& space,bool di) {
    if(!m.exif)return std::nullopt;
    spkhost::Probe probe;std::string error;
    if(!spkhost::probe_file(source,probe,error))return std::nullopt;
    const auto& meta=probe.metadata;
    spkhost::Exif e;
    if(m.camera){e.make=meta.make;e.model=meta.model;}
    if(m.lens)e.lens=meta.lens;
    if(m.exposure){e.iso=meta.iso.value_or(0);e.shutter_s=meta.shutter_s.value_or(0);
                   e.aperture=meta.aperture.value_or(0);e.focal_mm=meta.focal_mm.value_or(0);}
    if(m.date)e.datetime_original=meta.datetime_original;
    // EXIF's ColorSpace: 1 is sRGB, anything else is "uncalibrated" -- and the
    // DI, Cineon codes rather than colours, is marked so on the Mac too.
    e.color_space=!di&&space=="sRGB"?1:0xFFFF;
    return e;
}

QStringList copyDiViewLuts(const QString& directory,const fs::path& resources) {
    QStringList written;
    for(const char* name:{"SpektraLab DI view, Cineon to ProPhoto RGB.cube","SpektraLab DI view, Cineon to Rec709.cube"}) {
        const QString target=QDir(directory).filePath(QLatin1String(name));
        if(QFileInfo::exists(target))continue;
        if(!QFile::copy(pathText(resources/"di"/name),target))continue;
        QFile::setPermissions(target,QFileDevice::ReadOwner|QFileDevice::WriteOwner|QFileDevice::ReadGroup|QFileDevice::ReadOther);
        written.append(target);
    }
    return written;
}

QImage diViewPreview(const QImage& cineon,const fs::path& resources) {
    const Cube& cube=diViewCube(resources);
    if(cube.size<2||cineon.isNull())return {};
    const QImage reduced=previewOf(cineon.convertToFormat(QImage::Format_RGBA64));
    QImage out(reduced.size(),QImage::Format_RGBA64);
    const int n=cube.size;const float scale=float(n-1);
    auto at=[&](int r,int g,int b,int c){return cube.rgb[(std::size_t(b)*n*n+std::size_t(g)*n+r)*3+c];};
    for(int y=0;y<reduced.height();++y) {
        const auto* src=reinterpret_cast<const std::uint16_t*>(reduced.constScanLine(y));
        auto* dst=reinterpret_cast<std::uint16_t*>(out.scanLine(y));
        for(int x=0;x<reduced.width();++x) {
            float f[3];int i0[3],i1[3];
            for(int c=0;c<3;++c) {
                const float v=std::clamp(src[4*x+c]/65535.0f,0.0f,1.0f)*scale;
                i0[c]=std::min(int(v),n-2);i1[c]=i0[c]+1;f[c]=v-float(i0[c]);
            }
            for(int c=0;c<3;++c) {
                const float c00=at(i0[0],i0[1],i0[2],c)*(1-f[0])+at(i1[0],i0[1],i0[2],c)*f[0];
                const float c10=at(i0[0],i1[1],i0[2],c)*(1-f[0])+at(i1[0],i1[1],i0[2],c)*f[0];
                const float c01=at(i0[0],i0[1],i1[2],c)*(1-f[0])+at(i1[0],i0[1],i1[2],c)*f[0];
                const float c11=at(i0[0],i1[1],i1[2],c)*(1-f[0])+at(i1[0],i1[1],i1[2],c)*f[0];
                const float v=(c00*(1-f[1])+c10*f[1])*(1-f[2])+(c01*(1-f[1])+c11*f[1])*f[2];
                dst[4*x+c]=std::uint16_t(std::lround(std::clamp(v,0.0f,1.0f)*65535.0f));
            }
            dst[4*x+3]=65535;
        }
    }
    out.setColorSpace(QColorSpace(QColorSpace::ProPhotoRgb));
    return out;
}

QImage framed(const Job& job,const FramePtr& frame) {
    QImage source=framePixels(frame);
    // Post-Dev never reaches the Digital Intermediate: it is where a grade
    // starts (Exporter.exportDigitalIntermediate).
    if(job.grade&&job.recipe.format!=Format::di) {
        source=source.copy();   // own the pixels before grading them
        job.grade(source,frame->encoding);
    }
    output::ExportOptions options;
    options.format=output::Format::TIFF16;   // keeps RGBA64: the depth comes last
    options.maxLongEdge=job.recipe.longEdge>0?recipes::Recipe::clampEdge(job.recipe.longEdge):0;
    QImage out=output::exportImage(source,job.geometry,options);
    // exportImage may return a view of a cropless frame; own it.
    if(out.constBits()==source.constBits())out=out.copy();
    return out;
}

Outcome run(const Job& job,const FramePtr& frame,spk_engine* engine) {
    const auto& r=job.recipe;
    const bool di=r.format==Format::di;
    bool fellBack=false;
    const std::string space=di?std::string():r.engineSpace(&fellBack);
    const QString dir=r.directory(job.source);
    if(!QDir().mkpath(dir))
        fail(QStringLiteral("Could not create %1. Choose another folder in the export recipe.").arg(QDir::toNativeSeparators(dir)));
    auto exists=[](const QString& p){return QFileInfo::exists(p)||QFileInfo(p).isSymLink();};
    Outcome outcome;
    auto destination=recipes::resolveDestination(r,job.source,job.name,exists);
    if(!destination) {
        outcome.kind=Outcome::skipped;
        outcome.files={r.destinationPath(job.source,r.naming.stem(job.name))};
        return outcome;
    }
    const QImage pixels=framed(job,frame);
    WriteOptions options;
    options.format=r.format;
    options.jpegQuality=std::clamp(int(std::lround(r.quality*100)),1,100);
    options.overwrite=r.existing==recipes::Existing::overwrite;
    const auto exif=exifFor(nativePath(job.source),r.metadata,space,di);
    options.exif=exif?&*exif:nullptr;
    Converted converted;
    if(di) {
        converted.rgba64=pixels;converted.identity=true;
        options.untagged=true;
        options.preview=true;
        options.previewImage=diViewPreview(pixels,job.resources);
        const auto primaries=frame->encoding.color_space;
        if(primaries.find("ProPhoto RGB")==std::string::npos)
            outcome.note=QStringLiteral("This session renders in %1, so the Digital Intermediate carries %1 "
                                        "primaries rather than ProPhoto's; the view LUTs assume ProPhoto.")
                             .arg(text(primaries.substr(primaries.find('/')+1)));
    } else {
        converted=convert(pixels,frame->encoding,space,engine);
        if(r.embedsPreview&&recipes::carriesPreviewPage(r.format)) {
            options.preview=true;
            QImage page=converted.rgba64;page.setColorSpace(QColorSpace::fromIccProfile(iccProfile(space,job.resources)));
            options.previewImage=page;
        }
    }
    // Publication re-checks: a file that appeared since the policy looked is
    // never replaced unless the recipe overwrites; a suffix moves on.
    for(int attempt=0;;++attempt) {
        const auto published=writeImage(converted.rgba64,space,nativePath(*destination),options,job.resources);
        if(published==Published::written)break;
        if(r.existing==recipes::Existing::skip||attempt>64) {
            outcome.kind=Outcome::skipped;outcome.files={*destination};return outcome;
        }
        destination=recipes::resolveDestination(r,job.source,job.name,exists);
        if(!destination){outcome.kind=Outcome::skipped;outcome.files={r.destinationPath(job.source,r.naming.stem(job.name))};return outcome;}
    }
    outcome.files={*destination};
    if(di)outcome.files+=copyDiViewLuts(QFileInfo(*destination).absolutePath(),job.resources);
    outcome.clippedFraction=converted.clippedFraction;
    outcome.width=converted.rgba64.width();outcome.height=converted.rgba64.height();
    if(fellBack) {
        const QString asked=r.colorSpaceName();
        outcome.note+=(outcome.note.isEmpty()?QString():QStringLiteral(" "))+
            QStringLiteral("%1 has no colour space in the engine, so the perceptual transform cannot be built for it. "
                           "The file is in Display P3.").arg(asked);
    }
    return outcome;
}

void exportLegacy(const FramePtr& frame,const fs::path& destination,const output::Geometry& geometry,
                  const output::ExportOptions& options,const fs::path& resources,
                  const std::function<void(QImage&,const OutputEncoding&)>& grade,spk_engine* engine) {
    if(!frame)fail(QStringLiteral("No rendered photograph to export"));
    // An sRGB session: the writer's own path, byte for byte the old file.
    if(frame->encoding.is_encoded_srgb()){output::exportFrame(frame,destination,geometry,options,resources,grade);return;}
    // Anything else: framed() as a recipe frames it -- grade on the uncropped
    // frame in its own encoding, geometry, size, 16 bits kept -- then one
    // conversion into sRGB, then the depth the format asks for.
    QImage source=framePixels(frame);
    if(grade) {
        source=source.copy();
        if(source.isNull())fail(QStringLiteral("Cannot allocate the graded photograph"));
        grade(source,frame->encoding);
    }
    output::ExportOptions sized;
    sized.format=output::Format::TIFF16;
    sized.maxLongEdge=options.maxLongEdge;
    QImage pixels=output::exportImage(source,geometry,sized);
    if(pixels.constBits()==source.constBits())pixels=pixels.copy();
    const auto converted=convert(pixels,frame->encoding,"sRGB",engine);
    output::ExportOptions write=options;
    write.maxLongEdge=0;   // already sized
    output::exportImageFile(converted.rgba64,destination,output::Geometry{},write,resources);
}

}  // namespace spk::desktop::exporting
