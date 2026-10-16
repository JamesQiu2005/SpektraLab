#include "FrameImage.hpp"
#include "core/colour.hpp"
#include <QList>
#include <QtCore/qfloat16.h>
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace spk::desktop::display {
namespace {
[[noreturn]] void fail(const std::string& message) { throw std::runtime_error(message); }

// A transfer function Qt has no named equivalent for, as a curve table over
// the encoded range: 4096 nodes, linear between them, 16-bit linear values.
// The values are the engine's own decode (core/colour.cpp), not a copy of
// its constants -- Colour's transfer functions need no baked data.
QList<uint16_t> engineCurve(const char* engineName) {
    const spk::Colour colour{};
    if(!colour.known_cctf(engineName))fail(std::string("The engine has no transfer function for ")+engineName);
    constexpr int nodes=4096;
    QList<uint16_t> table(nodes);
    for(int i=0;i<nodes;++i) {
        const double linear=colour.cctf_decode(double(i)/(nodes-1),engineName);
        table[i]=uint16_t(std::lround(std::clamp(linear,0.0,1.0)*65535.0));
    }
    return table;
}

// Rows of RGBA floats (alpha already 1) into one RGBX16FPx4 scanline.
void storeHalfRow(QImage& image,int y,const float* rgba) {
    qFloatToFloat16(reinterpret_cast<qfloat16*>(image.scanLine(y)),rgba,qsizetype(image.width())*4);
}

// One axis of an exact area average: output i covers source [i*s, (i+1)*s),
// s = from/to, and source pixel j counts by its overlap with that interval,
// divided by s so the weights of each output sum to one.
struct Axis {
    std::vector<int> first, count;
    std::vector<float> weight;   // flattened, count[i] per output
    std::vector<int> offset;     // into weight
};
Axis areaAxis(int from,int to) {
    Axis axis;
    axis.first.resize(to);axis.count.resize(to);axis.offset.resize(to);
    const double scale=double(from)/to;
    for(int i=0;i<to;++i) {
        const double lo=i*scale,hi=std::min(double(from),(i+1)*scale);
        const int j0=std::clamp(int(std::floor(lo)),0,from-1);
        const int j1=std::clamp(int(std::ceil(hi))-1,j0,from-1);
        axis.first[i]=j0;axis.count[i]=j1-j0+1;axis.offset[i]=int(axis.weight.size());
        for(int j=j0;j<=j1;++j)
            axis.weight.push_back(float((std::min(double(j+1),hi)-std::max(double(j),lo))/scale));
    }
    return axis;
}
}

QColorSpace colorSpace(const OutputEncoding& encoding) {
    const auto& name=encoding.color_space;
    const bool encoded=encoding.cctf_encoding;
    using P=QColorSpace::Primaries;
    using T=QColorSpace::TransferFunction;
    // Qt's named spaces where their curve is the engine's: sRGB (Display P3
    // shares it), ProPhoto RGB's 1.8 with the 1/16 toe below 16/512, and
    // Adobe RGB's 563/256. Qt's Bt2020 curve is not the engine's BT one
    // (exponent 2.2 against 1/0.45, alpha 1.0993 against 1.099), so both BT
    // spaces carry the engine's curve as a table.
    QColorSpace space;
    if(name=="sRGB")space=encoded?QColorSpace(QColorSpace::SRgb):QColorSpace(QColorSpace::SRgbLinear);
    else if(name=="Display P3")space=encoded?QColorSpace(QColorSpace::DisplayP3):QColorSpace(P::DciP3D65,T::Linear);
    else if(name=="ProPhoto RGB")space=encoded?QColorSpace(QColorSpace::ProPhotoRgb):QColorSpace(P::ProPhotoRgb,T::Linear);
    else if(name=="Adobe RGB (1998)")space=encoded?QColorSpace(QColorSpace::AdobeRgb):QColorSpace(P::AdobeRgb,T::Linear);
    else if(name=="ITU-R BT.709")space=encoded?QColorSpace(P::SRgb,engineCurve("ITU-R BT.709")):QColorSpace(P::SRgb,T::Linear);
    else if(name=="ITU-R BT.2020")space=encoded?QColorSpace(P::Bt2020,engineCurve("ITU-R BT.2020")):QColorSpace(P::Bt2020,T::Linear);
    // QColorSpace accepts a primary only with x >= 0, y > 0 and x + y <= 1
    // (Qt 6.11 QColorVector::isValidChromaticity, measured: it reports such
    // a space invalid). Both ACES spaces have one outside, so neither can be
    // a tag; they are refused by name rather than approximated.
    else if(name=="ACES2065-1")
        fail("The display cannot tag frames encoded in ACES2065-1: its AP0 blue primary (y < 0) lies "
             "outside the chromaticities QColorSpace accepts");
    else if(name=="ACEScg")
        fail("The display cannot tag frames encoded in ACEScg: its AP1 red primary (x + y > 1) lies "
             "outside the chromaticities QColorSpace accepts");
    else fail("The display has no colour space for the engine's output space \""+name+"\"");
    // Untouched otherwise (no description): a named space stays equal to
    // QColorSpace(QColorSpace::SRgb) etc. for whoever compares against it.
    if(!space.isValid())fail("The display colour space for \""+name+"\" is invalid");
    return space;
}

QImage halfImage(const std::uint16_t* rgba16,int width,int height,qsizetype strideInPixels,const QColorSpace& space) {
    if(!rgba16||width<=0||height<=0||strideInPixels<width)fail("Invalid RGBA16 display dimensions or row pitch");
    if(qsizetype(height)>std::numeric_limits<qsizetype>::max()/strideInPixels/4)
        fail("RGBA16 display dimensions overflow address space");
    if(!space.isValid())fail("The display image needs a valid colour space");
    QImage image(width,height,QImage::Format_RGBX16FPx4);
    if(image.isNull())fail("Cannot allocate the display image");
    std::vector<float> row(std::size_t(width)*4);
    // Qt's own RGBA64 -> float conversion (QRgbaFloat::fromRgba64) multiplies
    // by this float; matching it keeps a converted RGBA64 image identical.
    constexpr float scale=1.0f/65535.0f;
    for(int y=0;y<height;++y) {
        const auto* source=rgba16+qsizetype(y)*strideInPixels*4;
        for(int x=0;x<width;++x) {
            const auto* p=source+std::size_t(x)*4;
            if(p[3]!=65535)fail("Display requires opaque RGBA16 pixels");
            float* q=row.data()+std::size_t(x)*4;
            q[0]=float(p[0])*scale;q[1]=float(p[1])*scale;q[2]=float(p[2])*scale;q[3]=1.0f;
        }
        storeHalfRow(image,y,row.data());
    }
    image.setColorSpace(space);
    return image;
}

QImage halfImage(const QImage& rgba64,const QColorSpace& space) {
    if(rgba64.isNull()||rgba64.format()!=QImage::Format_RGBA64)fail("The display conversion expects an RGBA64 image");
    return halfImage(reinterpret_cast<const std::uint16_t*>(rgba64.constBits()),rgba64.width(),rgba64.height(),
                     rgba64.bytesPerLine()/8,space);
}

QImage frameImage(const FramePtr& frame) {
    if(!frame)fail("No rendered photograph to display");
    const auto& pixels=frame->pixels();
    if(pixels.width>std::uint32_t(std::numeric_limits<int>::max())||pixels.height>std::uint32_t(std::numeric_limits<int>::max()))
        fail("Invalid RGBA16 display dimensions or row pitch");
    // Tag first: an unknown encoding is refused before 33 MP are converted.
    const auto space=colorSpace(frame->encoding);
    return halfImage(pixels.rgba16,int(pixels.width),int(pixels.height),qsizetype(pixels.row_stride_px),space);
}

QImage downscaled(const QImage& image,QSize bound) {
    if(image.isNull()||image.format()!=QImage::Format_RGBX16FPx4)fail("Downscaling expects an RGBX16FPx4 display image");
    if(bound.width()<1||bound.height()<1)fail("Downscaling needs a positive bound");
    const int width=image.width(),height=image.height();
    if(width<=bound.width()&&height<=bound.height())return image;
    const double scale=std::min(double(bound.width())/width,double(bound.height())/height);
    const int outWidth=std::clamp(int(std::lround(width*scale)),1,std::min(width,bound.width()));
    const int outHeight=std::clamp(int(std::lround(height*scale)),1,std::min(height,bound.height()));
    QImage output(outWidth,outHeight,QImage::Format_RGBX16FPx4);
    if(output.isNull())fail("Cannot allocate the reduced display image");
    const Axis columns=areaAxis(width,outWidth),rows=areaAxis(height,outHeight);
    std::vector<float> source(std::size_t(width)*4),cached(std::size_t(outWidth)*3);
    std::vector<float> sum(std::size_t(outWidth)*3),row(std::size_t(outWidth)*4);
    int cachedRow=-1;
    // One source row, reduced horizontally into `out` (RGB per output column).
    auto reduce=[&](int y,std::vector<float>& out) {
        qFloatFromFloat16(source.data(),reinterpret_cast<const qfloat16*>(image.constScanLine(y)),qsizetype(width)*4);
        for(int i=0;i<outWidth;++i) {
            const float* w=columns.weight.data()+columns.offset[i];
            const float* p=source.data()+std::size_t(columns.first[i])*4;
            float r=0,g=0,b=0;
            for(int k=0;k<columns.count[i];++k,p+=4){r+=w[k]*p[0];g+=w[k]*p[1];b+=w[k]*p[2];}
            out[std::size_t(i)*3]=r;out[std::size_t(i)*3+1]=g;out[std::size_t(i)*3+2]=b;
        }
    };
    for(int o=0;o<outHeight;++o) {
        std::fill(sum.begin(),sum.end(),0.0f);
        const float* w=rows.weight.data()+rows.offset[o];
        for(int k=0;k<rows.count[o];++k) {
            const int y=rows.first[o]+k;
            // A row straddling two outputs is reduced once and reused.
            if(y!=cachedRow){reduce(y,cached);cachedRow=y;}
            for(std::size_t i=0;i<sum.size();++i)sum[i]+=w[k]*cached[i];
        }
        for(int i=0;i<outWidth;++i) {
            row[std::size_t(i)*4]=sum[std::size_t(i)*3];row[std::size_t(i)*4+1]=sum[std::size_t(i)*3+1];
            row[std::size_t(i)*4+2]=sum[std::size_t(i)*3+2];row[std::size_t(i)*4+3]=1.0f;
        }
        storeHalfRow(output,o,row.data());
    }
    output.setColorSpace(image.colorSpace());
    return output;
}

}  // namespace spk::desktop::display
