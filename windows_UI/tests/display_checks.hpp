#pragma once
// Pixel comparisons for the canvas images (FrameImage.hpp), shared by the
// RAW workflow tests. Displayed images are compared exactly in their own
// format; an 8-bit file is compared exactly with what the export path makes
// of the same engine frame, and then with the displayed half floats through
// the two real conversions (no copy of either's arithmetic here).
#include "FrameImage.hpp"
#include "FrameOutput.hpp"
#include <QImage>
#include <algorithm>
#include <cstring>
#include <functional>
#include <vector>

namespace display_checks {
namespace output=spk::desktop::output;
namespace display=spk::desktop::display;

// Same size, format and colour space, and every byte of every pixel equal.
inline bool sameImage(const QImage& a,const QImage& b) {
    if(a.isNull()||b.isNull()||a.size()!=b.size()||a.format()!=b.format()||a.colorSpace()!=b.colorSpace())return false;
    const auto row=std::size_t(a.width())*std::size_t(a.depth())/8;
    for(int y=0;y<a.height();++y)if(std::memcmp(a.constScanLine(y),b.constScanLine(y),row)!=0)return false;
    return true;
}

// Exactly equal 8-bit RGB (PNG8/JPEG8 carry no alpha).
inline bool sameRgb8(const QImage& a,const QImage& b) {
    if(a.isNull()||b.isNull()||a.size()!=b.size())return false;
    const auto x=a.convertToFormat(QImage::Format_RGB888),y=b.convertToFormat(QImage::Format_RGB888);
    for(int r=0;r<x.height();++r)if(std::memcmp(x.constScanLine(r),y.constScanLine(r),std::size_t(x.width())*3)!=0)return false;
    return true;
}

// A read-only RGBA64 view of the engine frame; the frame must outlive it.
inline QImage framePixels(const spk::desktop::FramePtr& frame) {
    const auto& p=frame->pixels();
    return QImage(reinterpret_cast<const uchar*>(p.rgba16),int(p.width),int(p.height),
                  qsizetype(p.row_stride_px)*8,QImage::Format_RGBA64);
}

// The frame's own codes after `geometry`, quantised to 8 bits as a PNG8
// export quantises: what the displayed half floats are held to (the display
// shows the frame's own encoding).
inline QImage frame8(const spk::desktop::FramePtr& frame,const output::Geometry& geometry) {
    output::ExportOptions options;options.format=output::Format::PNG8;
    return output::exportImage(framePixels(frame),geometry,options);
}

// The legacy export's conversion of a framed RGBA64 image out of the frame's
// encoding into sRGB (the workflow tests pass exporting::convert on an engine
// of their own; RecipeExport.hpp exportLegacy runs the same).
using ToSrgb=std::function<QImage(const QImage& rgba64,const spk::desktop::OutputEncoding& from)>;

// What a legacy export of `frame` with `geometry` in `format` must hold, by
// the export path itself: an sRGB frame's own codes; any other encoding (the
// ProPhoto working space) framed and sized in its encoding, then converted
// into sRGB by `toSrgb`, then quantised. Without `toSrgb` the frame must be
// sRGB.
inline QImage expectedFile(const spk::desktop::FramePtr& frame,const output::Geometry& geometry,output::Format format,
                           const ToSrgb& toSrgb={},const QImage& graded={}) {
    output::ExportOptions options;options.format=format;
    const QImage source=graded.isNull()?framePixels(frame):graded;
    if(frame->encoding.is_encoded_srgb()||!toSrgb)return output::exportImage(source,geometry,options);
    output::ExportOptions keep;keep.format=output::Format::TIFF16;
    const QImage framed=output::exportImage(source,geometry,keep).copy();
    return output::exportImage(toSrgb(framed,frame->encoding),output::Geometry{},options);
}
inline QImage expected8(const spk::desktop::FramePtr& frame,const output::Geometry& geometry,const ToSrgb& toSrgb={}) {
    return expectedFile(frame,geometry,output::Format::PNG8,toSrgb);
}

// Whether an 8-bit export and a half-float display can be the same 16-bit
// pixels: each 8-bit sample must be what the export quantises some code to
// whose half float is the displayed one. Half floats merge up to 32 codes
// near white, so where a merged run straddles an 8-bit rounding edge both
// neighbours are possible ("ambiguous"); everywhere else this is exact.
class ExportDisplayAgreement {
public:
    struct Result { qint64 samples=0, disagreements=0, ambiguous=0; };
    ExportDisplayAgreement() {
        QImage ramp(65536,1,QImage::Format_RGBA64);
        auto* p=reinterpret_cast<QRgba64*>(ramp.scanLine(0));
        for(int v=0;v<65536;++v)p[v]=QRgba64::fromRgba64(quint16(v),quint16(v),quint16(v),65535);
        const auto half=display::halfImage(ramp,QColorSpace(QColorSpace::SRgb));
        output::ExportOptions options;options.format=output::Format::PNG8;
        const auto eight=output::exportImage(ramp,output::Geometry{},options).convertToFormat(QImage::Format_RGB888);
        const auto* h=reinterpret_cast<const quint16*>(half.constScanLine(0));
        const auto* e=eight.constScanLine(0);
        for(int v=0;v<65536;++v) {
            const quint16 bits=h[std::size_t(v)*4];const uchar q=e[std::size_t(v)*3];
            low_[bits]=std::min(low_[bits],q);high_[bits]=std::max(high_[bits],q);
        }
    }
    Result compare(const QImage& export8,const QImage& displayHalf) const {
        Result r;
        if(export8.size()!=displayHalf.size()||displayHalf.format()!=QImage::Format_RGBX16FPx4){r.disagreements=-1;return r;}
        const auto eight=export8.convertToFormat(QImage::Format_RGB888);
        for(int y=0;y<eight.height();++y) {
            const auto* h=reinterpret_cast<const quint16*>(displayHalf.constScanLine(y));
            const auto* e=eight.constScanLine(y);
            for(int x=0;x<eight.width();++x)for(int c=0;c<3;++c) {
                const quint16 bits=h[std::size_t(x)*4+c];const uchar q=e[std::size_t(x)*3+c];
                ++r.samples;
                if(low_[bits]>high_[bits]||q<low_[bits]||q>high_[bits])++r.disagreements;
                else if(low_[bits]!=high_[bits])++r.ambiguous;
            }
        }
        return r;
    }
private:
    std::vector<uchar> low_=std::vector<uchar>(65536,255),high_=std::vector<uchar>(65536,0);
};

}  // namespace display_checks
