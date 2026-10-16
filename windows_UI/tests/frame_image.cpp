// The canvas images, without a RAW or a GPU. The colour-space table is held
// against the engine itself: every output space baked into the resources it
// is given, with the primaries, white point and transfer function the engine
// renders with (core/colour.cpp over the blob), so a tag that disagrees with
// the pixels' real encoding fails here and not on someone's monitor.
#include "FrameImage.hpp"
#include "display_checks.hpp"
#include "core/blob.hpp"
#include "core/colour.hpp"
#include <QColorTransform>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QRgbaFloat>
#include <QtCore/qfloat16.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace display=spk::desktop::display;
using spk::desktop::OutputEncoding;

namespace {
int checks=0;
bool primaryPointsNoted=false;
void check(bool value,const std::string& message) {++checks;if(!value)throw std::runtime_error(message);}
template<class F> std::string refused(F&& action,const std::string& message) {
    try{action();}catch(const std::exception& e){++checks;return e.what();}
    throw std::runtime_error(message);
}
// Half of one half-float step at `value`, plus the float product's own
// rounding (one float ulp): how far the conversion may land from code/65535.
// It rounds float(code) * (1/65535) to the nearest half, as Qt does, so a
// code within a float ulp of a half midpoint can land one way or the other
// (65519 is 3.7e-9 below one and goes up: 0.500015 of a half step).
double halfTolerance(double value) {
    const double step=value<std::ldexp(1.0,-14)?std::ldexp(1.0,-24):std::ldexp(1.0,std::ilogb(value)-10);
    return step*0.5+value*std::ldexp(1.0,-23)+1e-12;
}
std::vector<float> floats(const QImage& image,int y) {
    std::vector<float> row(std::size_t(image.width())*4);
    qFloatFromFloat16(row.data(),reinterpret_cast<const qfloat16*>(image.constScanLine(y)),qsizetype(row.size()));
    return row;
}

// --- the colour-space table against the engine ---------------------------

// What Qt decodes an encoded grey to under a space: `toLinear` maps it to the
// same primaries with a linear transfer function.
double qtDecode(const QColorTransform& toLinear,float encoded) {
    return toLinear.map(QRgbaFloat32{encoded,encoded,encoded,1.0f}).g;
}
// Whether QColorSpace can hold these primaries at all: Qt 6.11 accepts a
// chromaticity only with x >= 0, 0 < y and x + y <= 1. The slack is for
// ProPhoto's green, which sits on x + y = 1 exactly (Qt's own named
// ProPhotoRgb is built without that check).
bool qtCanHold(const std::vector<double>& primaries) {
    for(int i=0;i<3;++i) {
        const double x=primaries[std::size_t(2*i)],y=primaries[std::size_t(2*i+1)];
        if(x<0||y<=0||x+y>1+1e-9)return false;
    }
    return true;
}

void colourSpaces(const std::filesystem::path& resources) {
    spk::Blob blob;std::string error;
    check(blob.open((resources/"spektrafilm_constants.bin").string(),error),"open the engine's resource blob: "+error);
    spk::Colour colour;
    check(colour.init(blob,error),"engine colour data: "+error);
    std::set<std::string> baked;
    const std::string prefix="colour/cs/",suffix="/primaries";
    for(const auto& key:blob.names())
        if(key.rfind(prefix,0)==0&&key.size()>prefix.size()+suffix.size()&&key.compare(key.size()-suffix.size(),suffix.size(),suffix)==0)
            baked.insert(key.substr(prefix.size(),key.size()-prefix.size()-suffix.size()));
    check(baked.count("sRGB")&&baked.count("ProPhoto RGB")&&baked.size()>=4,"the engine bakes fewer output spaces than expected");
    std::printf("engine output spaces: %zu\n",baked.size());
    for(const auto& name:baked) {
        const spk::Colour::Colourspace* cs=nullptr;
        check(colour.colourspace(name,cs,error)&&cs->primaries.size()==6,"engine colourspace "+name+": "+error);
        check(colour.known_cctf(name),"the engine renders into "+name+" but has no transfer function for it");
        for(const bool encoded:{true,false}) {
            const OutputEncoding encoding{name,encoded};
            const std::string label=name+(encoded?"":" (linear)");
            if(!qtCanHold(cs->primaries)) {
                // Refused -- and only where the engine's own primaries are
                // ones QColorSpace cannot hold.
                const auto why=refused([&]{display::colorSpace(encoding);},label+" tagged although QColorSpace cannot hold its primaries");
                check(why.find(name)!=std::string::npos,"the refusal of "+label+" does not name it");
                std::printf("  %-22s refused: %s\n",label.c_str(),why.c_str());
                continue;
            }
            QColorSpace space;
            try{space=display::colorSpace(encoding);}
            catch(const std::exception& e){throw std::runtime_error("the engine bakes "+label+" but the display does not tag it: "+e.what());}
            check(space.isValid(),label+" is not a valid QColorSpace");
            // Every tag uses one of Qt's named primary sets. Read them through
            // fromPrimaries and whitePoint(): Qt 6.11.3's primaryPoints()
            // returns its four members rotated (measured below).
            check(space.primaries()!=QColorSpace::Primaries::Custom,label+" has no named primaries");
            auto points=QColorSpace::PrimaryPoints::fromPrimaries(space.primaries());
            const auto near=[](QPointF a,QPointF b){return std::abs(a.x()-b.x())<1e-6&&std::abs(a.y()-b.y())<1e-6;};
            check(near(points.whitePoint,space.whitePoint()),label+": named primaries and whitePoint() disagree");
            const auto reported=space.primaryPoints();
            if(!near(reported.redPoint,points.redPoint)&&!primaryPointsNoted) {
                primaryPointsNoted=true;
                std::printf("  note: QColorSpace::primaryPoints() reports white (%.4f, %.4f) red (%.4f, %.4f) for %s, "
                            "whose white is (%.4f, %.4f) and red (%.4f, %.4f)\n",reported.whitePoint.x(),reported.whitePoint.y(),
                            reported.redPoint.x(),reported.redPoint.y(),label.c_str(),points.whitePoint.x(),points.whitePoint.y(),
                            points.redPoint.x(),points.redPoint.y());
            }
            const QPointF engine[4]={{cs->primaries[0],cs->primaries[1]},{cs->primaries[2],cs->primaries[3]},
                                     {cs->primaries[4],cs->primaries[5]},{cs->whitepoint[0],cs->whitepoint[1]}};
            const QPointF qt[4]={points.redPoint,points.greenPoint,points.bluePoint,points.whitePoint};
            double primaryError=0;
            for(int i=0;i<4;++i)primaryError=std::max({primaryError,std::abs(qt[i].x()-engine[i].x()),std::abs(qt[i].y()-engine[i].y())});
            if(primaryError>=1e-4)
                for(int i=0;i<4;++i)std::printf("  %s %s: Qt (%.5f, %.5f) engine (%.5f, %.5f)\n",label.c_str(),
                    i==0?"red":i==1?"green":i==2?"blue":"white",qt[i].x(),qt[i].y(),engine[i].x(),engine[i].y());
            // Qt's D65 is (0.31271, 0.32902) and its D50 (0.34567, 0.35850),
            // colour-science's (0.3127, 0.3290) and (0.3457, 0.3585): 3e-5.
            check(primaryError<1e-4,label+": primaries or white point differ from the engine's");
            const auto linear=space.withTransferFunction(QColorSpace::TransferFunction::Linear);
            check(linear.isValid(),label+": no linear twin to measure the transfer function against");
            const auto toLinear=space.transformationToColorSpace(linear);
            double transferError=0;
            for(int i=0;i<=1024;++i) {
                const double x=i/1024.0;
                const double expected=encoded?colour.cctf_decode(x,name):x;
                transferError=std::max(transferError,std::abs(qtDecode(toLinear,float(x))-expected));
            }
            check(transferError<2e-5,label+": transfer function differs from the engine's");
            std::printf("  %-22s primaries/white max |dxy| %.2e  transfer max |dlinear| %.2e\n",label.c_str(),primaryError,transferError);
        }
    }
    // The spaces a canvas will compare against keep Qt's own names.
    check(display::colorSpace({"sRGB",true})==QColorSpace(QColorSpace::SRgb),"sRGB is not Qt's sRGB");
    check(display::colorSpace({"ProPhoto RGB",true})==QColorSpace(QColorSpace::ProPhotoRgb),"ProPhoto RGB is not Qt's");
    check(display::colorSpace({"Display P3",true})==QColorSpace(QColorSpace::DisplayP3),"Display P3 is not Qt's");
    check(display::colorSpace({"sRGB",false})==QColorSpace(QColorSpace::SRgbLinear),"linear sRGB is not Qt's");
    // Never a default for a name the engine does not use.
    for(const char* unknown:{"","srgb","sRGB ","Bogus RGB","ProPhoto","Display P3 (D65)","DCI-P3","Rec. 2020"})
        refused([&]{display::colorSpace({unknown,true});},std::string("unknown output space tagged: \"")+unknown+"\"");
}

// --- RGBA16 to half floats ----------------------------------------------

void halfConversion() {
    // Every code in R, mirrored in G, scattered in B; a padded stride whose
    // padding holds transparent garbage that must be ignored.
    constexpr int width=65536,stride=width+3;
    std::vector<std::uint16_t> rgba(std::size_t(stride)*4*2,7);
    for(int y=0;y<2;++y)for(int v=0;v<width;++v) {
        auto* p=rgba.data()+(std::size_t(y)*stride+v)*4;
        p[0]=std::uint16_t(v);p[1]=std::uint16_t(65535-v);p[2]=std::uint16_t((v*17)&65535);p[3]=65535;
    }
    const QColorSpace prophoto(QColorSpace::ProPhotoRgb);
    const auto image=display::halfImage(rgba.data(),width,2,stride,prophoto);
    check(image.format()==QImage::Format_RGBX16FPx4&&image.size()==QSize(width,2)&&image.colorSpace()==prophoto,
          "half image has the wrong format, size or tag");
    check(qsizetype(image.bytesPerLine())==qsizetype(width)*8,"half image is not 8 bytes per pixel");
    const auto row=floats(image,1);
    const auto* bits=reinterpret_cast<const qfloat16*>(image.constScanLine(1));
    double previous=-1,worst=0;int worstBack=0,offNearest=0;std::set<float> distinct;
    for(int v=0;v<width;++v) {
        const float* p=row.data()+std::size_t(v)*4;
        const int codes[3]={v,65535-v,(v*17)&65535};
        for(int c=0;c<3;++c) {
            const double expected=codes[c]/65535.0;
            // Exactly the specified arithmetic, bit for bit ...
            const qfloat16 specified(float(codes[c])*(1.0f/65535.0f));
            if(std::memcmp(&bits[std::size_t(v)*4+c],&specified,sizeof specified)!=0)
                throw std::runtime_error("code "+std::to_string(codes[c])+" is not float(code)/65535 rounded to half");
            // ... and within half a half step (plus a float ulp) of the code.
            const double error=std::abs(double(p[c])-expected);
            if(error>halfTolerance(expected))
                throw std::runtime_error("code "+std::to_string(codes[c])+" is further than half a half step from code/65535");
            if(c==0&&error>halfTolerance(expected)-expected*std::ldexp(1.0,-23)-1e-12)++offNearest;
            worst=std::max(worst,error);
        }
        check(p[3]==1.0f,"half alpha is not exactly 1");
        check(p[0]>=previous,"half conversion is not monotonic");
        previous=p[0];distinct.insert(p[0]);
        worstBack=std::max(worstBack,std::abs(int(std::lround(double(p[0])*65535.0))-v));
    }
    check(row[0]==0.0f&&row[std::size_t(65535)*4]==1.0f,"black or white is not exact");
    // The same arithmetic as Qt's own RGBA64 conversion, bit for bit.
    QImage ramp(width,1,QImage::Format_RGBA64);
    std::memcpy(ramp.scanLine(0),rgba.data(),std::size_t(width)*8);
    const auto mine=display::halfImage(ramp,prophoto);
    const auto qt=ramp.convertToFormat(QImage::Format_RGBX16FPx4);
    check(std::memcmp(mine.constScanLine(0),qt.constScanLine(0),std::size_t(width)*8)==0,
          "half conversion differs from Qt's RGBA64 -> RGBX16FPx4");
    std::printf("half conversion: all 65536 codes are float(code)/65535 rounded to half, max |error| %.3g "
                "(%d codes past the exact midpoint by under a float ulp); %zu distinct values; "
                "back to 16 bits within %d codes\n",worst,offNearest,distinct.size(),worstBack);

    const std::uint16_t opaque[4]{1,2,3,65535},translucent[4]{1,2,3,65534};
    refused([&]{display::halfImage(nullptr,1,1,1,prophoto);},"null pixels accepted");
    refused([&]{display::halfImage(opaque,0,1,1,prophoto);},"zero width accepted");
    refused([&]{display::halfImage(opaque,1,0,1,prophoto);},"zero height accepted");
    refused([&]{display::halfImage(opaque,2,1,1,prophoto);},"stride below width accepted");
    refused([&]{display::halfImage(translucent,1,1,1,prophoto);},"translucent pixel accepted");
    refused([&]{display::halfImage(opaque,1,1,1,QColorSpace());},"untagged display image accepted");
    refused([&]{display::halfImage(QImage(2,2,QImage::Format_ARGB32),prophoto);},"8-bit source accepted");
}

// --- the navigator and the thumbnail ------------------------------------

QImage synthetic(int width,int height,const QColorSpace& space) {
    std::vector<std::uint16_t> rgba(std::size_t(width)*height*4);
    std::uint32_t seed=12345;
    for(int y=0;y<height;++y)for(int x=0;x<width;++x) {
        auto* p=rgba.data()+(std::size_t(y)*width+x)*4;
        seed=seed*1664525u+1013904223u;
        p[0]=std::uint16_t(65535.0*x/(width-1));
        p[1]=std::uint16_t(65535.0*y/(height-1));
        p[2]=std::uint16_t(seed>>16);
        p[3]=65535;
    }
    return display::halfImage(rgba.data(),width,height,width,space);
}
std::array<double,3> mean(const QImage& image) {
    std::array<double,3> sum{};
    for(int y=0;y<image.height();++y) {
        const auto row=floats(image,y);
        for(int x=0;x<image.width();++x)for(int c=0;c<3;++c)sum[c]+=row[std::size_t(x)*4+c];
    }
    for(auto& s:sum)s/=double(image.width())*image.height();
    return sum;
}
// One output pixel of an exact area average, in double, by brute force.
double areaMean(const QImage& source,QSize out,int ox,int oy,int c) {
    const double sx=double(source.width())/out.width(),sy=double(source.height())/out.height();
    double sum=0,area=0;
    for(int y=int(std::floor(oy*sy));y<std::min(source.height(),int(std::ceil((oy+1)*sy)));++y) {
        const double wy=std::min(y+1.0,(oy+1)*sy)-std::max(double(y),oy*sy);
        const auto row=floats(source,y);
        for(int x=int(std::floor(ox*sx));x<std::min(source.width(),int(std::ceil((ox+1)*sx)));++x) {
            const double w=wy*(std::min(x+1.0,(ox+1)*sx)-std::max(double(x),ox*sx));
            sum+=w*row[std::size_t(x)*4+c];area+=w;
        }
    }
    return sum/area;
}

void reduction() {
    const QColorSpace space(QColorSpace::ProPhotoRgb);
    for(const auto [size,expected]:{std::pair{QSize(3001,2001),QSize(1024,683)},std::pair{QSize(2001,3001),QSize(683,1024)},
                                    std::pair{QSize(5000,3),QSize(1024,1)},std::pair{QSize(1025,1025),QSize(1024,1024)}}) {
        const auto source=synthetic(size.width(),size.height(),space);
        const auto navigator=display::navigatorImage(source);
        check(navigator.size()==expected,"navigator size for "+std::to_string(size.width())+"x"+std::to_string(size.height()));
        check(navigator.format()==QImage::Format_RGBX16FPx4&&navigator.colorSpace()==space,"navigator lost its format or tag");
        const auto a=mean(source),b=mean(navigator);
        for(int c=0;c<3;++c)check(std::abs(a[c]-b[c])<1e-4,"navigator moved the mean colour");
        std::uint32_t seed=99;
        for(int i=0;i<24;++i) {
            seed=seed*1664525u+1013904223u;const int ox=int(seed%std::uint32_t(expected.width()));
            seed=seed*1664525u+1013904223u;const int oy=int(seed%std::uint32_t(expected.height()));
            const auto row=floats(navigator,oy);
            for(int c=0;c<3;++c) {
                const double exact=areaMean(source,expected,ox,oy,c);
                check(std::abs(row[std::size_t(ox)*4+c]-exact)<=halfTolerance(exact)+1e-6,"navigator pixel is not the area mean");
            }
            check(row[std::size_t(ox)*4+3]==1.0f,"navigator alpha is not 1");
        }
        const auto thumbnail=display::thumbnailImage(navigator);
        check(thumbnail.format()==QImage::Format_RGBX16FPx4&&thumbnail.colorSpace()==space&&
              thumbnail.width()<=display::kThumbnailBox.width()&&thumbnail.height()<=display::kThumbnailBox.height()&&
              (thumbnail.width()==display::kThumbnailBox.width()||thumbnail.height()==display::kThumbnailBox.height()),
              "thumbnail does not fit the strip box as 16-bit-class pixels");
    }
    // A flat field stays exactly that colour.
    std::vector<std::uint16_t> flat(std::size_t(1500)*900*4);
    for(std::size_t i=0;i<flat.size();i+=4){flat[i]=12345;flat[i+1]=40000;flat[i+2]=65535;flat[i+3]=65535;}
    const auto field=display::halfImage(flat.data(),1500,900,1500,space);
    const auto reduced=display::navigatorImage(field);
    const auto first=floats(field,0);
    for(int y=0;y<reduced.height();++y) {
        const auto row=floats(reduced,y);
        for(int x=0;x<reduced.width();++x)for(int c=0;c<4;++c)
            if(row[std::size_t(x)*4+c]!=first[std::size_t(c)])throw std::runtime_error("a flat field changed colour when reduced");
    }
    ++checks;
    // Small enough already: the same image, not a copy.
    const auto small=synthetic(800,600,space);
    check(display::navigatorImage(small).cacheKey()==small.cacheKey(),"a small image was copied for the navigator");
    refused([&]{display::navigatorImage(QImage(2000,10,QImage::Format_ARGB32));},"8-bit image reduced as if half float");
    refused([&]{display::downscaled(small,QSize(0,10));},"empty bound accepted");
}

// --- the cost at 33 MP ---------------------------------------------------

void timing() {
    // The ARW gate's frame size, a non-trivial pattern, best of three.
    constexpr int width=4688,height=7028;
    std::vector<std::uint16_t> rgba(std::size_t(width)*height*4);
    for(std::size_t i=0;i<rgba.size();i+=4){rgba[i]=std::uint16_t(i*7);rgba[i+1]=std::uint16_t(i*13);rgba[i+2]=std::uint16_t(i>>5);rgba[i+3]=65535;}
    const QColorSpace space(QColorSpace::SRgb);
    double convert=1e30,navigate=1e30,thumb=1e30;QImage image,navigator;
    for(int run=0;run<3;++run) {
        image=QImage();navigator=QImage();   // one 264 MB image alive at a time
        QElapsedTimer clock;clock.start();
        image=display::halfImage(rgba.data(),width,height,width,space);
        convert=std::min(convert,clock.nsecsElapsed()/1e6);clock.restart();
        navigator=display::navigatorImage(image);
        navigate=std::min(navigate,clock.nsecsElapsed()/1e6);clock.restart();
        const auto thumbnail=display::thumbnailImage(navigator);
        thumb=std::min(thumb,clock.nsecsElapsed()/1e6);
    }
    check(image.sizeInBytes()==qsizetype(width)*height*8,"33 MP half image is not 8 bytes per pixel");
    std::printf("33 MP (%dx%d) best of 3: RGBA16->RGBX16FPx4 %.1f ms, navigator %dx%d %.1f ms, thumbnail %.1f ms; "
                "half image %.1f MB (RGBA16 frame %.1f MB, navigator %.2f MB)\n",
                width,height,convert,navigator.width(),navigator.height(),navigate,thumb,
                image.sizeInBytes()/1048576.0,double(rgba.size())*2/1048576.0,navigator.sizeInBytes()/1048576.0);
}

// --- geometry on a half-float display image ------------------------------

void geometry() {
    // Orthogonal geometry on a published image moves pixels exactly and keeps
    // the tag: a crop of the half image is the half image of the crop.
    std::vector<std::uint16_t> rgba(std::size_t(9)*7*4);
    for(int i=0;i<9*7;++i){rgba[i*4]=std::uint16_t(i*1031);rgba[i*4+1]=std::uint16_t(65535-i*977);rgba[i*4+2]=std::uint16_t(i*i*13);rgba[i*4+3]=65535;}
    const QColorSpace space(QColorSpace::ProPhotoRgb);
    const auto full=display::halfImage(rgba.data(),9,7,9,space);
    QImage rgba64(9,7,QImage::Format_RGBA64);std::memcpy(rgba64.bits(),rgba.data(),rgba.size()*2);
    const QRectF crop(1.0/9,1.0/7,6.0/9,4.0/7);
    for(int turns=0;turns<4;++turns)for(bool flipX:{false,true}) {
        const spk::desktop::output::Geometry g{crop,turns,flipX,false,0};
        const auto shown=spk::desktop::output::displayImage(full,g);
        const auto expected=display::halfImage(spk::desktop::output::exportImage(rgba64,g,{}),space);
        check(display_checks::sameImage(shown,expected),"orthogonal geometry changed half-float pixels or the tag");
    }
}
}

int main(int argc,char** argv) {
    QCoreApplication app(argc,argv);
    try {
        check(argc==2,"usage: spk_qt_frame_image_test <resources>");
        const std::filesystem::path resources(QString::fromLocal8Bit(argv[1]).toStdWString());
        colourSpaces(resources);
        halfConversion();
        reduction();
        geometry();
        timing();
        std::printf("Frame image: %d checks passed\n",checks);
        return 0;
    } catch(const std::exception& error) {
        std::fprintf(stderr,"%s\n",error.what());
        return 1;
    }
}
