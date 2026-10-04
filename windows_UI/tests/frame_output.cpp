// Real encoders, real files and an asymmetric 16-bit fixture. The TIFF reader
// below is independent of the writer and Qt's image plugins. No RAW/GPU needed.
#include "FrameOutput.hpp"
#include <QColorSpace>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QImageReader>
#include <QTemporaryDir>
#include <algorithm>
#include <atomic>
#include <barrier>
#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <stdexcept>
#include <thread>

namespace output=spk::desktop::output;
namespace fs=std::filesystem;
namespace {
void check(bool value,const char* message) {if(!value)throw std::runtime_error(message);}
template<class Function> void rejects(Function action,const char* message) {
    try{action();}catch(const std::exception&){return;}throw std::runtime_error(message);
}
fs::path native(const QString& path){return fs::path(path.toStdWString());}
QByteArray read(const QString& path) {
    QFile file(path);check(file.open(QIODevice::ReadOnly),"cannot read test file");return file.readAll();
}
quint16 le16(const QByteArray& bytes,qsizetype offset) {
    check(offset>=0 && offset+2<=bytes.size(),"TIFF short beyond file");
    return quint16(uchar(bytes[offset])) | (quint16(uchar(bytes[offset+1]))<<8);
}
quint32 le32(const QByteArray& bytes,qsizetype offset) {
    return quint32(le16(bytes,offset)) | (quint32(le16(bytes,offset+2))<<16);
}
struct Tag {quint16 type;quint32 count;quint32 payload;};
void verifyTiff(const QString& path,const QImage& expected,const QByteArray& icc) {
    const auto bytes=read(path);check(bytes.startsWith("II") && le16(bytes,2)==42,"TIFF header differs");
    const quint32 offset=le32(bytes,4);const quint16 count=le16(bytes,offset);
    std::map<quint16,Tag> tags;
    for(quint32 i=0;i<count;++i) {
        const auto entry=offset+2+i*12;const auto type=le16(bytes,entry+2);const auto n=le32(bytes,entry+4);
        const quint64 size=quint64(n)*(type==3?2:type==4?4:type==5?8:1);
        tags.emplace(le16(bytes,entry),Tag{type,n,size<=4?entry+8:le32(bytes,entry+8)});
    }
    auto value=[&](int tag,int index=0) {
        const auto& t=tags.at(quint16(tag));check(quint32(index)<t.count,"TIFF tag index invalid");
        return t.type==3?quint32(le16(bytes,t.payload+index*2)):le32(bytes,t.payload+index*4);
    };
    check(value(256)==quint32(expected.width()) && value(257)==quint32(expected.height()),"TIFF size differs");
    check(value(259)==1 && value(262)==2 && value(274)==1 && value(277)==3,"TIFF layout differs");
    check(tags.at(258).count==3,"TIFF channel depths missing");
    for(int c=0;c<3;++c)check(value(258,c)==16,"TIFF lost 16-bit depth");
    const auto& tag=tags.at(34675);
    check(bytes.mid(tag.payload,tag.count)==icc,"TIFF ICC changed");
    const int rows=int(value(278));
    for(int y=0;y<expected.height();++y) {
        const auto start=value(273,y/rows);const auto* row=reinterpret_cast<const QRgba64*>(expected.constScanLine(y));
        for(int x=0;x<expected.width();++x) {
            const auto at=start+(quint32(y%rows)*expected.width()+x)*6;
            check(le16(bytes,at)==row[x].red() && le16(bytes,at+2)==row[x].green() &&
                  le16(bytes,at+4)==row[x].blue(),"TIFF sample changed or channels swapped");
        }
    }
}
QImage fixture(int width=9,int height=7) {
    QImage image(width,height,QImage::Format_RGBA64);
    for(int y=0;y<height;++y) {
        auto* row=reinterpret_cast<QRgba64*>(image.scanLine(y));
        for(int x=0;x<width;++x)row[x]=QRgba64::fromRgba64(
            quint16((1973*x+113*y+17)%65536),quint16((257*x+7001*y+128)%65536),
            quint16((5101*x+919*y+65535)%65536),65535);
    }
    return image;
}
void compare64(const QImage& actual,const QImage& expected) {
    check(actual.size()==expected.size(),"roundtrip size changed");
    const auto converted=actual.convertToFormat(QImage::Format_RGBA64);
    for(int y=0;y<actual.height();++y) {
        const auto* a=reinterpret_cast<const QRgba64*>(converted.constScanLine(y));
        const auto* e=reinterpret_cast<const QRgba64*>(expected.constScanLine(y));
        for(int x=0;x<actual.width();++x)check(a[x]==e[x],"lossless 16-bit pixel changed");
    }
}
void compare8(const QImage& actual,const QImage& expected64) {
    check(actual.size()==expected64.size(),"8-bit roundtrip size changed");
    for(int y=0;y<actual.height();++y) {
        const auto* row=reinterpret_cast<const QRgba64*>(expected64.constScanLine(y));
        for(int x=0;x<actual.width();++x) {
            const auto pixel=actual.pixelColor(x,y);
            check(pixel.red()==(row[x].red()+128)/257 && pixel.green()==(row[x].green()+128)/257 &&
                  pixel.blue()==(row[x].blue()+128)/257 && pixel.alpha()==255,"8-bit quantization changed");
        }
    }
}
QImage load(const QString& path,const QByteArray& profile) {
    QImageReader reader(path);auto image=reader.read();
    check(!image.isNull(),"image encoder output cannot be read");
    check(image.colorSpace().isValid(),"export has no readable ICC profile");
    check(image.colorSpace().iccProfile()==profile,"export changed the bundled ICC profile");return image;
}
void cleanPartials(const QString& folder) {
    const auto entries=QDir(folder).entryList({".spektralab-export-*"},QDir::Dirs|QDir::Hidden|QDir::NoDotAndDotDot);
    check(entries.isEmpty(),"export leaked a partial directory");
}
QImage expectedOrthogonal(const QImage& cropped,int turns,bool flipX,bool flipY) {
    const bool portrait=turns%2;
    QImage result(portrait?cropped.height():cropped.width(),portrait?cropped.width():cropped.height(),QImage::Format_RGBA64);
    for(int y=0;y<cropped.height();++y)for(int x=0;x<cropped.width();++x) {
        int tx=x,ty=y;
        if(turns==1){tx=cropped.height()-1-y;ty=x;}
        if(turns==2){tx=cropped.width()-1-x;ty=cropped.height()-1-y;}
        if(turns==3){tx=y;ty=cropped.width()-1-x;}
        if(flipX)tx=result.width()-1-tx;
        if(flipY)ty=result.height()-1-ty;
        reinterpret_cast<QRgba64*>(result.scanLine(ty))[tx]=reinterpret_cast<const QRgba64*>(cropped.constScanLine(y))[x];
    }
    return result;
}
QRgba64 sample(const QImage& image,int x,int y) {
    return reinterpret_cast<const QRgba64*>(image.constScanLine(y))[x];
}
void verifyGeometry(const QImage& original,const QString& folder,const fs::path& resources,const QByteArray& icc) {
    const QRectF crop(1.0/9,1.0/7,6.0/9,4.0/7);
    const auto cropped=original.copy(1,1,6,4);
    const auto original8=original.convertToFormat(QImage::Format_ARGB32);
    for(int turns=0;turns<4;++turns)for(bool flipX:{false,true})for(bool flipY:{false,true}) {
        output::Geometry geometry{crop,turns,flipX,flipY,0};
        const auto expected=expectedOrthogonal(cropped,turns,flipX,flipY);
        compare64(output::exportImage(original,geometry,{}),expected);
        compare8(output::displayImage(original8,geometry),expected);
        const output::ExportOptions options{output::Format::PNG8,95,0};
        compare8(output::exportImage(original,geometry,options),expected);
    }
    compare64(output::exportImage(original,output::Geometry{},{}),original);
    check(output::Geometry{}==output::Geometry{},"default geometry is not comparable");
    check(output::Geometry{}!=output::Geometry{crop},"different crops compare equal");

    // A 45-degree turn on a square has a sqrt(2) fill zoom. Its corner
    // centers land exactly on the four source edge centers, independently
    // pinning angle direction, zoom and the fixed-size output rectangle.
    const QImage square=fixture(3,3);
    output::Geometry angle;angle.straightenDegrees=45;
    const auto straightened=output::exportImage(square,angle,{});
    check(straightened.size()==square.size(),"straightening changes the crop dimensions");
    check(sample(straightened,0,0)==sample(square,0,1) && sample(straightened,2,0)==sample(square,1,0) &&
          sample(straightened,0,2)==sample(square,1,2) && sample(straightened,2,2)==sample(square,2,1),
          "straightening has wrong direction, center or fill zoom");
    check(sample(straightened,1,1)==sample(square,1,1),"straightening moves the center pixel");
    auto average=[](quint16 a,quint16 b,quint16 c,quint16 d){return quint16((quint32(a)+b+c+d+2)/4);};
    const auto a=sample(square,0,0),b=sample(square,1,0),c=sample(square,0,1),d=sample(square,1,1);
    const auto middle=QRgba64::fromRgba64(average(a.red(),b.red(),c.red(),d.red()),
        average(a.green(),b.green(),c.green(),d.green()),average(a.blue(),b.blue(),c.blue(),d.blue()),65535);
    check(sample(straightened,1,0)==middle,"straightening did not interpolate the original 16-bit samples");
    angle.straightenDegrees=-45;
    const auto anticlockwise=output::exportImage(square,angle,{});
    check(sample(anticlockwise,0,0)==sample(square,1,0) && sample(anticlockwise,2,0)==sample(square,2,1),
          "negative straightening has wrong direction");
    for(const auto size:{QSize(19,11),QSize(1,17),QSize(17,1),QSize(1,1)}) {
        QImage solid(size,QImage::Format_RGBA64);
        const auto colour=QRgba64::fromRgba64(19743,39751,61529,65535);
        solid.fill(QColor::fromRgba64(colour));
        for(const double degrees:{-45.0,-23.5,-.001,.001,23.5,45.0}) {
            output::Geometry g;g.straightenDegrees=degrees;
            const auto image=output::exportImage(solid,g,{});
            compare64(image,solid); // includes every edge and opaque alpha
        }
    }

    // Combined order: original-space crop, straighten, quarter turn, then
    // output-axis flips. File/display all derive from that same 16-bit image.
    output::Geometry combined{crop,1,true,false,17.5};
    auto straightenOnly=combined;straightenOnly.quarterTurns=0;straightenOnly.flipHorizontal=false;
    const auto expected=expectedOrthogonal(output::exportImage(original,straightenOnly,{}),1,true,false);
    compare64(output::exportImage(original,combined,{}),expected);
    compare64(output::displayImage(original,combined),expected);
    const auto preview=output::displayImage(original,combined).convertToFormat(QImage::Format_ARGB32);
    compare8(preview,expected);
    for(const auto [format,name]:{std::pair{output::Format::PNG8,"geometry8.png"},
                                  std::pair{output::Format::PNG16,"geometry16.png"},
                                  std::pair{output::Format::TIFF16,"geometry16.tif"}}) {
        const auto path=QDir(folder).filePath(name);
        output::ExportOptions options;options.format=format;
        output::exportImageFile(original,native(path),combined,options,resources);
        if(format==output::Format::TIFF16)verifyTiff(path,expected,icc);
        else if(format==output::Format::PNG16)compare64(load(path,icc),expected);
        else compare8(load(path,icc),expected);
    }
    output::ExportOptions resized;resized.maxLongEdge=3;
    const auto small=output::exportImage(original,combined,resized);
    check(small.size()==QSize(2,3),"resize ignored final turned aspect ratio");
    for(const int turns:{-1,4,999}) {
        output::Geometry invalid;invalid.quarterTurns=turns;
        rejects([&]{output::exportImage(original,invalid,{});},"invalid quarter turn accepted");
        rejects([&]{output::displayImage(original8,invalid);},"preview accepted invalid quarter turn");
    }
    for(const double degrees:{-45.001,45.001,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()}) {
        output::Geometry invalid;invalid.straightenDegrees=degrees;
        rejects([&]{output::validateGeometry(original.size(),invalid);},"invalid straightening accepted");
        rejects([&]{output::exportImage(original,invalid,{});},"export accepted invalid straightening");
    }
    auto invalid=combined;invalid.crop={-.1,0,1,1};
    rejects([&]{output::displayImage(original8,invalid);},"geometry accepted invalid source crop");
    rejects([&]{output::displayFrame({},combined);},"empty display frame accepted");
    check(original.size()==QSize(9,7),"geometry changed source dimensions");
}
}

int main(int argc,char** argv) {
    QCoreApplication app(argc,argv);
    try {
        check(argc>=2,"usage: spk_qt_frame_output_test <resources> [output-directory]");
        const fs::path resources=native(QString::fromLocal8Bit(argv[1]));
        QTemporaryDir temporary;check(temporary.isValid(),"cannot create test folder");
        const QString folder=argc>=3?QString::fromLocal8Bit(argv[2]):temporary.path();
        check(QDir().mkpath(folder),"cannot create evidence folder");
        const auto icc=read(QString::fromStdWString((resources/"io"/"sRGB.icc").wstring()));
        const QImage original=fixture();const auto originalBytes=QByteArray(reinterpret_cast<const char*>(original.constBits()),original.sizeInBytes());
        const QRectF crop(.17,.19,.62,.66);
        // Independent expected edges: (1.53,1.33)-(7.11,5.95) -> (2,1)-(7,6).
        const QRect expectedRect(2,1,5,5);const QImage expected=original.copy(expectedRect);
        check(output::cropPixels(original.size(),crop)==expectedRect,"fractional crop uses wrong pixel edges");
        check(output::cropPixels(original.size(),{0,0,1,1})==original.rect(),"full crop changes dimensions");
        check(output::cropPixels(original.size(),{.9999,.9999,.0001,.0001})==QRect(8,6,1,1),"tiny edge crop is not one pixel");
        for(const auto invalid:{QRectF(),QRectF(-.1,0,.5,.5),QRectF(0,0,1.1,1),QRectF(.5,0,-.1,1),
                               QRectF(0,0,1,0),QRectF(0,0,std::numeric_limits<double>::infinity(),1),
                               QRectF(std::numeric_limits<double>::quiet_NaN(),0,1,1)})
            rejects([&]{output::cropPixels(original.size(),invalid);},"invalid crop accepted");
        rejects([&]{output::cropPixels(QSize(),{0,0,1,1});},"empty image accepted");
        const auto display=output::displayImage(original.convertToFormat(QImage::Format_ARGB32),crop);
        compare8(display,expected);
        verifyGeometry(original,folder,resources,icc);

        for(const auto [format,name]:{std::pair{output::Format::PNG8,"crop8.png"},
                                     std::pair{output::Format::PNG16,"crop16.png"},
                                     std::pair{output::Format::TIFF16,"crop16.tif"}}) {
            check(output::formatAvailable(format),"required encoder missing");
            output::ExportOptions options;options.format=format;
            const auto destination=QDir(folder).filePath(name);
            output::exportImageFile(original,native(destination),crop,options,resources);
            if(format==output::Format::TIFF16)verifyTiff(destination,expected,icc);
            else {
                const auto encoded=read(destination);check(encoded.startsWith(QByteArray::fromHex("89504e470d0a1a0a")),"PNG signature missing");
                check(uchar(encoded[24])==(format==output::Format::PNG16?16:8),"PNG encoder changed bit depth");
                const auto decoded=load(destination,icc);
                if(format==output::Format::PNG16)compare64(decoded,expected);else compare8(decoded,expected);
            }
            const auto before=read(destination);
            rejects([&]{output::exportImageFile(fixture(3,2),native(destination),{0,0,1,1},options,resources);},"existing file overwritten");
            check(read(destination)==before,"failed overwrite changed original bytes");
            cleanPartials(folder);
        }

        output::ExportOptions resize;resize.format=output::Format::PNG16;resize.maxLongEdge=4;
        auto resized=output::exportImage(original,{0,0,1,1},resize);
        check(resized.size()==QSize(4,3) && resized.format()==QImage::Format_RGBA64,"resize changed aspect or depth");
        output::exportImageFile(original,native(QDir(folder).filePath("resized16.png")),{0,0,1,1},resize,resources);
        compare64(load(QDir(folder).filePath("resized16.png"),icc),resized);
        resize.maxLongEdge=100;compare64(output::exportImage(original,{0,0,1,1},resize),original);
        resize.maxLongEdge=1;check(output::exportImage(fixture(1,20),{0,0,1,1},resize).size()==QSize(1,1),"narrow resize rounded to zero");

        QImage gradient(96,64,QImage::Format_RGBA64);
        for(int y=0;y<gradient.height();++y) {
            auto* row=reinterpret_cast<QRgba64*>(gradient.scanLine(y));
            for(int x=0;x<gradient.width();++x)row[x]=QRgba64::fromRgba64(quint16(x*65535/95),quint16(y*65535/63),quint16((x+y)*65535/158),65535);
        }
        output::ExportOptions jpeg;jpeg.format=output::Format::JPEG8;
        check(output::formatAvailable(jpeg.format),"JPEG encoder missing");
        QByteArray low;
        for(const int quality:{25,95}) {
            jpeg.jpegQuality=quality;const auto filename=QDir(folder).filePath(QString("quality%1.jpg").arg(quality));
            output::exportImageFile(gradient,native(filename),{0,0,1,1},jpeg,resources);
            const auto decoded=load(filename,icc);check(decoded.size()==gradient.size(),"JPEG size changed");
            if(quality==25)low=read(filename);
            else {
                check(low!=read(filename) && low.size()<read(filename).size(),"JPEG quality setting has no effect");
                double squared=0;int maxError=0;
                for(int y=0;y<gradient.height();++y)for(int x=0;x<gradient.width();++x) {
                    const auto expected8=gradient.pixelColor(x,y),actual=decoded.pixelColor(x,y);
                    for(const int delta:{expected8.red()-actual.red(),expected8.green()-actual.green(),expected8.blue()-actual.blue()}) {
                        squared+=double(delta)*delta;maxError=std::max(maxError,std::abs(delta));
                    }
                }
                const double rms=std::sqrt(squared/(gradient.width()*gradient.height()*3));
                check(rms<3 && maxError<12,"high quality JPEG has excessive sample error");
                std::printf("JPEG quality95 rms=%.6f max_channel_error=%d\n",rms,maxError);
            }
        }

        // Competing complete files must yield one winner, not two successful
        // overwrites. A private image per writer also checks no global encoder.
        output::ExportOptions raceOptions;raceOptions.format=output::Format::PNG16;
        QImage red(64,48,QImage::Format_RGBA64),blue(red.size(),QImage::Format_RGBA64);red.fill(Qt::red);blue.fill(Qt::blue);
        const auto racePath=QDir(folder).filePath("race.png");
        std::barrier ready(3);std::atomic<int> successes=0;
        auto race=[&](const QImage& pixels){ready.arrive_and_wait();try{output::exportImageFile(pixels,native(racePath),{0,0,1,1},raceOptions,resources);++successes;}catch(const std::exception&){};};
        std::thread first(race,std::cref(red)),second(race,std::cref(blue));ready.arrive_and_wait();first.join();second.join();
        check(successes==1,"concurrent exports overwrote each other");
        const auto winner=load(racePath,icc);check(winner.pixelColor(0,0)==QColor(Qt::red)||winner.pixelColor(0,0)==QColor(Qt::blue),"racing output corrupted");
        compare64(winner,winner.pixelColor(0,0)==QColor(Qt::red)?red:blue);cleanPartials(folder);

        output::ExportOptions bad;bad.jpegQuality=101;
        rejects([&]{output::exportImage(original,crop,bad);},"invalid quality accepted");
        bad={};bad.maxLongEdge=-1;rejects([&]{output::exportImage(original,crop,bad);},"invalid resize accepted");
        bad={};bad.format=static_cast<output::Format>(999);rejects([&]{output::exportImage(original,crop,bad);},"invalid format accepted");
        rejects([&]{output::exportImage(original.convertToFormat(QImage::Format_ARGB32),crop,{});},"8-bit source silently exported as 16-bit");
        auto transparent=original.copy();reinterpret_cast<QRgba64*>(transparent.scanLine(1))[2]=QRgba64::fromRgba64(1,2,3,0);
        rejects([&]{output::exportImage(transparent,crop,{});},"transparent export accepted");
        rejects([&]{output::exportImageFile(original,native(QDir(folder).filePath("missing/no.png")),crop,raceOptions,resources);},"missing folder accepted");
        rejects([&]{output::exportImageFile(original,native(QDir(folder).filePath("bad-profile.png")),crop,raceOptions,native(folder));},"missing ICC accepted");
        rejects([&]{output::exportImageFile(original,native(folder),crop,raceOptions,resources);},"directory destination accepted");
        check(!QFile::exists(QDir(folder).filePath("bad-profile.png")),"failed export left a destination");
        for(const auto [format,name]:{std::pair{output::Format::PNG8,"wrong-png.jpg"},
                                      std::pair{output::Format::PNG16,"wrong-png16.tif"},
                                      std::pair{output::Format::TIFF16,"wrong-tiff.png"},
                                      std::pair{output::Format::JPEG8,"wrong-jpeg.png"},
                                      std::pair{output::Format::PNG8,"missing-extension"}}) {
            output::ExportOptions options;options.format=format;
            const auto target=QDir(folder).filePath(name);
            rejects([&]{output::exportImageFile(original,native(target),crop,options,resources);},"mismatched or missing extension accepted");
            check(!QFile::exists(target),"extension rejection created a destination");
        }
        for(const auto [format,name]:{std::pair{output::Format::PNG8,"uppercase.PNG"},
                                      std::pair{output::Format::PNG16,"uppercase16.PnG"},
                                      std::pair{output::Format::TIFF16,"uppercase.TIFF"},
                                      std::pair{output::Format::JPEG8,"uppercase.JPEG"}}) {
            output::ExportOptions options;options.format=format;
            const auto target=QDir(folder).filePath(name);
            output::exportImageFile(original,native(target),crop,options,resources);
            if(format==output::Format::TIFF16)verifyTiff(target,expected,icc);
            else {
                const auto decoded=load(target,icc);
                check(decoded.size()==expected.size(),"uppercase extension changed output dimensions");
                if(format==output::Format::PNG8)compare8(decoded,expected);
                else if(format==output::Format::PNG16)compare64(decoded,expected);
            }
        }
        cleanPartials(folder);
        check(QByteArray(reinterpret_cast<const char*>(original.constBits()),original.sizeInBytes())==originalBytes,"crop/export mutated source pixels");
        std::printf("PASS crop/geometry-order/quarter-turns/flips/straighten/zoom-fill/16-bit-interpolation/display/PNG8/PNG16/TIFF16/ICC/JPEG/resize/no-overwrite/race/cleanup/extensions/source-immutability\n");
        return 0;
    } catch(const std::exception& e) {std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
