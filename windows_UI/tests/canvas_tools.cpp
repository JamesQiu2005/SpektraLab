// The canvas tools without a window, a RAW or a GPU (CanvasMath.hpp,
// FrameImage.hpp histogram / originalImage):
//  - the zoom ladder against ViewportState.swift's, zoom about a point, the
//    one clamp, and 100 % on the physical pixel grid even for an item at a
//    fractional physical position (grain must not shift);
//  - the crop grips: hit test, resize with the opposite side pinned, an
//    aspect lock, the per-axis move clamp, drawing, and the straighten line's
//    sign held against FrameOutput's own straighten mapping;
//  - the histogram on synthetic frames, cropped against uncropped (the Mac
//    counts the uncropped print, AGENTS.md trap 33; Windows counts what the
//    canvas shows), and its cost at 33 MP;
//  - the Original: its colour conversion against Qt's, and its geometry
//    against the print's under crop, quarter turn, flip and straighten -- a
//    surface-agreement test in trap 33's sense, with a control that shows the
//    comparison can fail.
#include "CanvasMath.hpp"
#include "FrameImage.hpp"
#include "FrameOutput.hpp"
#include <QColorTransform>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QRgbaFloat>
#include <QtCore/qfloat16.h>
#include <algorithm>
#include <array>
#include <functional>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

namespace canvas=spk::desktop::canvas;
namespace display=spk::desktop::display;
namespace output=spk::desktop::output;
using spk::desktop::OutputEncoding;

namespace {
int checks=0;
void check(bool value,const std::string& message) {++checks;if(!value)throw std::runtime_error(message);}
bool near(double a,double b,double tolerance=1e-9){return std::abs(a-b)<=tolerance;}
bool near(QRectF a,QRectF b,double tolerance=1e-9) {
    return near(a.x(),b.x(),tolerance)&&near(a.y(),b.y(),tolerance)&&near(a.width(),b.width(),tolerance)&&near(a.height(),b.height(),tolerance);
}
std::vector<float> floats(const QImage& image,int y) {
    std::vector<float> row(std::size_t(image.width())*4);
    qFloatFromFloat16(row.data(),reinterpret_cast<const qfloat16*>(image.constScanLine(y)),qsizetype(row.size()));
    return row;
}
QImage halfFilled(int width,int height,const std::function<std::array<float,3>(int,int)>& colour) {
    QImage image(width,height,QImage::Format_RGBX16FPx4);
    std::vector<float> row(std::size_t(width)*4);
    for(int y=0;y<height;++y) {
        for(int x=0;x<width;++x){const auto c=colour(x,y);row[x*4]=c[0];row[x*4+1]=c[1];row[x*4+2]=c[2];row[x*4+3]=1;}
        qFloatToFloat16(reinterpret_cast<qfloat16*>(image.scanLine(y)),row.data(),qsizetype(row.size()));
    }
    image.setColorSpace(QColorSpace(QColorSpace::SRgb));
    return image;
}

void zoomLadder() {
    // ViewportState.zoomSteps, and the stepping rule (0.1 % past the current).
    check(canvas::steppedZoom(1,1)==1.5&&canvas::steppedZoom(1.5,1)==2&&canvas::steppedZoom(2,1)==3,"zoom in follows the Mac ladder");
    check(canvas::steppedZoom(1,-1)==0.66&&canvas::steppedZoom(0.66,-1)==0.5,"zoom out follows the Mac ladder");
    check(canvas::steppedZoom(0.2917,1)==0.33&&canvas::steppedZoom(0.2917,-1)==0.25,"a fitted zoom steps to its neighbours");
    check(canvas::steppedZoom(1.0005,1)==1.5&&canvas::steppedZoom(0.9995,-1)==0.66,"a step within 0.1 % is the same step");
    check(canvas::steppedZoom(8,1)==canvas::kMaxZoom&&canvas::steppedZoom(0.05,-1)==canvas::kMinZoom,"the ladder stops at 5 % and 800 %");
    check(canvas::kMenuZooms==std::array<double,5>{0.25,0.5,1,2,4},"the zoom menu is TopBar.swift's");
    check(canvas::pixelAligned(1)&&canvas::pixelAligned(2)&&canvas::pixelAligned(4)&&!canvas::pixelAligned(1.5)&&
          !canvas::pixelAligned(0.5),"pixel-aligned zooms are whole multiples of 100 %");
}

void viewMaths() {
    canvas::View v;v.canvas={1000,700};v.dpr=1.25;v.image={4000,3000};
    v.sceneOrigin={300.4,50.2};  // a rail width that is not a whole physical pixel
    v=canvas::fitted(v);
    check(near(canvas::fitZoom(v),std::min(1250.0/4000,875.0/3000))&&v.fit,"fit is the smaller axis ratio");
    const auto fit=canvas::imageRect(v);
    check(near(fit.height(),700)&&near(fit.x(),(1000-fit.width())/2),"fitted is centred and meets the canvas");
    // 100 % about the centre: one device pixel per photo pixel, on the
    // window's physical grid, the photo point at the centre kept.
    auto h=canvas::zoomedAbout(v,1,{500,350});
    const auto r=canvas::imageRect(h);
    check(!h.fit&&near(canvas::zoomOf(h),1)&&near(r.width()*h.dpr,4000)&&near(r.height()*h.dpr,3000),"100 % is physical");
    const double px=(h.sceneOrigin.x()+r.x())*h.dpr,py=(h.sceneOrigin.y()+r.y())*h.dpr;
    check(near(px,std::round(px),1e-9)&&near(py,std::round(py),1e-9),"100 % sits on the physical pixel grid");
    check(near((500-r.x())/r.width(),0.5,1e-3)&&near((350-r.y())/r.height(),0.5,1e-3),"zooming about the centre keeps it");
    // About a point off centre, before any clamp can bite.
    auto z=canvas::zoomedAbout(h,2,{300,200});
    const auto r2=canvas::imageRect(z);
    check(near((300-r.x())/r.width(),(300-r2.x())/r2.width(),2e-4)&&near((200-r.y())/r.height(),(200-r2.y())/r2.height(),2e-4),
          "the photo point under the pointer stays under it");
    const double qx=(z.sceneOrigin.x()+r2.x())*z.dpr;
    check(near(qx,std::round(qx),1e-9),"200 % is pixel aligned too");

    // The one clamp: an edge never comes inside the canvas, and a pan has no
    // dead zone at the edge.
    auto p=canvas::panned(h,{1e9,1e9});
    const auto edge=canvas::imageRect(p);
    check(near(edge.x(),0,1)&&near(edge.y(),0,1),"a pan stops with the edge at the canvas edge");
    auto back=canvas::panned(p,{-1,-1});
    check(near(canvas::imageRect(back).x()-edge.x(),-1,1.0/h.dpr+1e-9),"a pan away from the edge moves at once");
    p=canvas::panned(h,{-1e9,-1e9});
    check(near(canvas::imageRect(p).right(),1000,1)&&near(canvas::imageRect(p).bottom(),700,1),"the far edges clamp too");
    // Smaller than the canvas: centred, and the pan does nothing.
    auto small=canvas::zoomedAbout(v,0.1,{100,100});
    check(near(canvas::zoomOf(small),0.1)&&near(canvas::imageRect(small).x(),(1000-400/1.25)/2)&&
          near(canvas::imageRect(canvas::panned(small,{50,50})).x(),canvas::imageRect(small).x()),"a small photo is centred");
    // Limits: down to the smaller of fit and 5 %, up to 800 %.
    check(near(canvas::zoomOf(canvas::zoomedAbout(v,100,{0,0})),8)&&near(canvas::zoomOf(canvas::zoomedAbout(v,0.001,{0,0})),0.05),
          "zoom limits");
    // A new canvas size keeps the centre point; a fitted view refits.
    auto grown=canvas::resized(z,{1200,800},1.25);
    const auto rg=canvas::imageRect(grown);
    check(near((600-rg.x())/rg.width(),(500-r2.x())/r2.width(),1e-3),"a resize keeps the photo point at the centre");
    check(canvas::resized(v,{1200,800},1.25).fit,"a fitted view stays fitted on resize");
    check(canvas::imageRect(canvas::View{}).isNull(),"an empty view has no rectangle");
}

void cropGrips() {
    const QSizeF source(6000,4000);
    const QRectF crop(0.2,0.25,0.5,0.5);
    const double tol=30;  // source px
    using H=canvas::CropHandle;
    check(canvas::cropHandleAt(crop,{0.2,0.25},source,tol)==H::topLeft,"top-left grip");
    check(canvas::cropHandleAt(crop,{0.7+2.0/6000,0.75},source,tol)==H::bottomRight,"bottom-right grip");
    check(canvas::cropHandleAt(crop,{0.45,0.25},source,tol)==H::top,"top grip");
    check(canvas::cropHandleAt(crop,{0.2,0.6},source,tol)==H::left,"an edge away from its grip is still the edge");
    check(canvas::cropHandleAt(crop,{0.45,0.5},source,tol)==H::body,"inside is the body");
    check(canvas::cropHandleAt(crop,{0.9,0.9},source,tol)==H::none,"outside is nothing");
    // Corners win over edges on a small crop.
    check(canvas::cropHandleAt({0.5,0.5,0.004,0.004},{0.5,0.5},source,tol)==H::topLeft,"corners win ties");
    // Free resize: the opposite corner pinned.
    auto r=canvas::resizedCrop(crop,H::bottomRight,{0.6,0.6},source,0);
    check(near(r,QRectF(0.2,0.25,0.4,0.35)),"a corner resizes, the opposite corner pinned");
    r=canvas::resizedCrop(crop,H::left,{0.1,0.9},source,0);
    check(near(r,QRectF(0.1,0.25,0.6,0.5)),"an edge moves only its own side");
    r=canvas::resizedCrop(crop,H::topLeft,{-0.5,-0.5},source,0);
    check(near(r,QRectF(0,0,0.7,0.75)),"a drag past the frame stops at it");
    r=canvas::resizedCrop(crop,H::right,{0.1,0.5},source,0);
    check(near(r,QRectF(0.1,0.25,0.1,0.5)),"past the opposite edge the rectangle flips");
    // Locked 3:2 in source px.
    const double ratio=1.5;
    r=canvas::resizedCrop(crop,H::bottomRight,{0.6,0.7},source,ratio);
    check(near(r.width()*6000/(r.height()*4000),ratio,1e-9)&&near(r.topLeft().x(),0.2)&&near(r.topLeft().y(),0.25),
          "a locked corner keeps the ratio and its anchor");
    r=canvas::resizedCrop(crop,H::bottomRight,{2,2},source,ratio);
    check(near(r.width()*6000/(r.height()*4000),ratio,1e-6)&&r.right()<=1+1e-9&&r.bottom()<=1+1e-9&&
          near(r.left(),0.2)&&near(r.top(),0.25),"a locked shape stops where it still fits");
    r=canvas::resizedCrop(crop,H::top,{0.5,0.05},source,ratio);
    check(near(r.width()*6000/(r.height()*4000),ratio,1e-6)&&near(r.bottom(),0.75,1e-9),"a locked edge derives the other side");
    // Minimum side.
    r=canvas::resizedCrop(crop,H::bottomRight,{0.2,0.25},source,0);
    check(r.width()*6000>=canvas::kMinCropSide-1e-6&&r.height()*4000>=canvas::kMinCropSide-1e-6,"16 px minimum side");
    // Move, per axis.
    check(near(canvas::movedCrop(crop,{0.1,-0.1}),QRectF(0.3,0.15,0.5,0.5)),"a move moves");
    check(near(canvas::movedCrop(crop,{0.9,0.05}),QRectF(0.5,0.3,0.5,0.5)),"against an edge the crop slides along it");
    check(near(canvas::movedCrop({0,0.2,1,0.5},{0.3,0.1}),QRectF(0,0.3,1,0.5)),"a full-width crop still moves vertically");
    // Draw.
    check(near(canvas::drawnCrop({0.7,0.7},{0.2,0.3},source,0),QRectF(0.2,0.3,0.5,0.4)),"a free rectangle from either corner");
    r=canvas::drawnCrop({0.2,0.3},{0.7,0.4},source,1.0);
    check(near(r.width()*6000,r.height()*4000,1e-6)&&near(r.x(),0.2)&&near(r.y(),0.3)&&r.bottom()<=1,"a locked rectangle grows from its start");
    r=canvas::drawnCrop({0.9,0.9},{0.1,0.1},source,1.0);
    check(near(r.width()*6000,r.height()*4000,1e-6)&&near(r.right(),0.9)&&near(r.bottom(),0.9)&&r.left()>=0&&r.top()>=0,
          "a locked rectangle keeps to the frame");
}

void straightenLine() {
    const QSizeF source(6000,4000);
    check(!canvas::straightenFromLine({0.5,0.5},{0.5005,0.5},source).has_value(),"a click is not a line");
    // A line falling to the right by 5 degrees.
    const double fall=5*std::acos(-1.0)/180;
    const QPointF a(0.2,0.4),b(a.x()+std::cos(fall)*0.5,a.y()+std::sin(fall)*0.5*6000/4000);
    const auto degrees=canvas::straightenFromLine(a,b,source);
    check(degrees&&near(*degrees,-5,1e-9),"a line falling 5 degrees straightens by -5");
    // Held against FrameOutput.cpp's straighten: output (dx, 0) samples the
    // source at (c dx, -s dx) for the angle's c, s -- so at the angle given,
    // a step along the output's horizontal is a step along the drawn line.
    const double t=*degrees*std::acos(-1.0)/180;
    const double sx=std::cos(t),sy=-std::sin(t);
    check(near(std::atan2(sy,sx),fall,1e-9),"the angle levels the drawn line in output::Geometry's convention");
    // Reversed, the same line; near vertical, plumb.
    check(near(*canvas::straightenFromLine(b,a,source),-5,1e-9),"either direction");
    const auto plumb=canvas::straightenFromLine({0.5,0.1},{0.5+std::tan(3*std::acos(-1.0)/180)*0.6*4000/6000,0.7},source);
    check(plumb&&near(*plumb,3,1e-9),"a line 3 degrees off vertical makes it plumb");
}

void histograms() {
    // 3 x 1, stride 1: one pixel in each bin it should land in.
    {
        const auto image=halfFilled(3,1,[](int x,int){return x==0?std::array<float,3>{0,0,0}:x==1?std::array<float,3>{0.5f,0.5f,0.5f}:std::array<float,3>{1.2f,-0.1f,0.25f};});
        const auto bins=display::histogram(image);
        check(bins.size()==1024,"4 x 256 bins");
        // round(0.5 * 255) = 128; 1.2 clamps to 255, -0.1 to 0; 0.25 -> 64.
        check(bins[128]==1&&bins[256+128]==1&&bins[512+128]==1&&bins[768+128]==1,"mid grey lands in bin 128 of every row");
        check(bins[255]==1&&bins[256]==1&&bins[512+64]==1,"values clamp before binning");
        const int luma=int((0.2126f+0.0f*0.7152f+0.25f*0.0722f)*255+0.5f);
        check(bins[768+luma]==1,"luma is Rec. 709 of the clamped channels");
    }
    // Left half black, right half grey 0.5: the uncropped histogram has both,
    // the right-half crop only the grey.
    const auto image=halfFilled(800,600,[](int x,int){return x<400?std::array<float,3>{0,0,0}:std::array<float,3>{0.5f,0.5f,0.5f};});
    const auto whole=display::histogram(image);
    const auto cropped=display::histogram(output::displayImage(image,QRectF(0.5,0,0.5,1)));
    check(whole[0]==1&&whole[128]==1,"uncropped counts black and grey");
    check(cropped[0]==0&&cropped[128]==1&&cropped[768]==0,"the crop counts only what it shows");
    // Normalised to the tallest bin away from the ends.
    const auto ramp=halfFilled(256,10,[](int x,int){const float v=x<128?0.5f:x/255.0f;return std::array<float,3>{v,v,v};});
    const auto rampBins=display::histogram(ramp);
    check(rampBins[128]==1&&near(rampBins[200],1.0/(128+1),1e-6),"normalised to the tallest interior bin");
    check(display::histogram(QImage()).size()==1024&&display::histogram(QImage())[0]==0,"a null image is all zeros");
    // 33 MP: ~200 000 samples, whatever the frame size.
    const auto big=halfFilled(7008,4672,[](int x,int y){return std::array<float,3>{x/7008.f,y/4672.f,0.3f};});
    QElapsedTimer clock;clock.start();
    const auto bigBins=display::histogram(big);
    const double ms=double(clock.nsecsElapsed())/1e6;
    std::printf("histogram of a 7008 x 4672 frame: %.2f ms\n",ms);
    check(bigBins[768+0]<=1&&ms<500,"the 33 MP histogram is cheap");
}

spk::io::DecodedRaw decode(int width,int height,const std::function<std::array<float,3>(int,int)>& linear) {
    spk::io::DecodedRaw d;d.width=std::uint32_t(width);d.height=std::uint32_t(height);
    d.rgb.resize(std::size_t(width)*height*3);
    for(int y=0;y<height;++y)for(int x=0;x<width;++x) {
        const auto c=linear(x,y);float* p=d.rgb.data()+(std::size_t(y)*width+x)*3;p[0]=c[0];p[1]=c[1];p[2]=c[2];
    }
    return d;
}

void originalColour() {
    const OutputEncoding srgb{"sRGB",true};
    const QColorSpace prophotoLinear(QColorSpace::Primaries::ProPhotoRgb,QColorSpace::TransferFunction::Linear);
    const QColorSpace srgbLinear(QColorSpace::SRgbLinear);
    // Colours inside sRGB, written in linear ProPhoto through Qt's own
    // conversion, must come out as their sRGB encoding.
    const std::array<std::array<float,3>,5> colours{{{0.2f,0.5f,0.1f},{0.9f,0.05f,0.3f},{0.18f,0.18f,0.18f},{0.0f,0.0f,0.0f},{1.0f,1.0f,1.0f}}};
    const auto toProPhoto=srgbLinear.transformationToColorSpace(prophotoLinear);
    const auto encode=srgbLinear.transformationToColorSpace(QColorSpace(QColorSpace::SRgb));
    const auto d=decode(5,1,[&](int x,int){const auto c=colours[x];const auto p=toProPhoto.map(QRgbaFloat32{c[0],c[1],c[2],1});return std::array<float,3>{p.r,p.g,p.b};});
    const auto original=display::originalImage(d,srgb);
    check(original.format()==QImage::Format_RGBX16FPx4&&original.size()==QSize(5,1)&&original.colorSpace()==QColorSpace(QColorSpace::SRgb),
          "the Original is half floats tagged like an sRGB print");
    const auto row=floats(original,0);
    double worst=0;
    for(int x=0;x<5;++x) {
        const auto e=encode.map(QRgbaFloat32{colours[x][0],colours[x][1],colours[x][2],1});
        worst=std::max({worst,double(std::abs(row[x*4]-e.r)),double(std::abs(row[x*4+1]-e.g)),double(std::abs(row[x*4+2]-e.b))});
        check(row[x*4+3]==1,"opaque");
    }
    std::printf("Original sRGB conversion, worst error: %.6f\n",worst);
    check(worst<2e-3,"the Original's conversion agrees with Qt's to half-float precision");
    // Out of gamut and out of range clip; NaN is black.
    const auto clipped=floats(display::originalImage(decode(3,1,[](int x,int){
        return x==0?std::array<float,3>{1,0,0}:x==1?std::array<float,3>{4,4,4}:std::array<float,3>{std::nanf(""),-1,0.5f};}),srgb),0);
    for(float v:clipped)check(v>=0&&v<=1,"clipped to [0,1]");
    check(clipped[0]==1&&clipped[4]==1&&clipped[5]==1&&clipped[6]==1&&clipped[8]==0,"ProPhoto red clips, white clips, NaN is black");
    // A ProPhoto session: identity primaries, ProPhoto's own curve.
    const auto pp=display::originalImage(decode(1,1,[](int,int){return std::array<float,3>{0.18f,0.18f,0.18f};}),{"ProPhoto RGB",true});
    const auto ppEncode=prophotoLinear.transformationToColorSpace(QColorSpace(QColorSpace::ProPhotoRgb)).map(QRgbaFloat32{0.18f,0.18f,0.18f,1});
    check(pp.colorSpace()==QColorSpace(QColorSpace::ProPhotoRgb)&&near(floats(pp,0)[0],ppEncode.r,1e-3),"a ProPhoto session's Original is ProPhoto");
    // Refusals.
    bool refused=false;
    try{spk::io::DecodedRaw bad;bad.width=2;bad.height=2;bad.rgb.resize(5);display::originalImage(bad,srgb);}catch(const std::exception&){refused=true;}
    check(refused,"an inconsistent decode is refused");
    // 33 MP cost.
    const auto big=decode(7008,4672,[](int x,int y){return std::array<float,3>{x/7008.f,y/4672.f,0.25f};});
    QElapsedTimer clock;clock.start();
    const auto bigOriginal=display::originalImage(big,srgb);
    std::printf("Original of a 7008 x 4672 decode: %.1f ms\n",double(clock.nsecsElapsed())/1e6);
    check(bigOriginal.size()==QSize(7008,4672),"the 33 MP Original has the decode's size");
}

// A camera RAW's Original is rendered for the eye (Apple's default decode on
// the Mac): RAW 0.10 grey is 18 % grey, black and the RAW's white stay put,
// the DNG baseline exposure adds its stops, and a colour keeps its hue.
void originalRawLook() {
    const OutputEncoding srgb{"sRGB",true};
    const QColorSpace prophotoLinear(QColorSpace::Primaries::ProPhotoRgb,QColorSpace::TransferFunction::Linear);
    const auto toSrgb=prophotoLinear.transformationToColorSpace(QColorSpace(QColorSpace::SRgb));
    const auto encodeSrgb=QColorSpace(QColorSpace::SRgbLinear).transformationToColorSpace(QColorSpace(QColorSpace::SRgb));
    const std::array<std::array<float,3>,5> raw{{{0.10f,0.10f,0.10f},{0,0,0},{1,1,1},{0.05f,0.05f,0.05f},{0.12f,0.06f,0.03f}}};
    auto d=decode(5,1,[&](int x,int){return raw[x];});
    const auto neutral=floats(display::originalImage(d,srgb),0);
    d.metadata.camera_raw=true;
    const auto rendered=floats(display::originalImage(d,srgb),0);
    const float grey=encodeSrgb.map(QRgbaFloat32{0.18f,0.18f,0.18f,1}).g;
    std::printf("RAW Original: 0.10 grey %.4f (neutral %.4f), 0.05 grey %.4f (neutral %.4f)\n",
                rendered[1],neutral[1],rendered[13],neutral[13]);
    check(near(rendered[0],grey,2e-3)&&near(rendered[1],grey,2e-3)&&near(rendered[2],grey,2e-3),"RAW 0.10 grey renders as 18 % grey");
    check(rendered[4]==0&&rendered[5]==0&&rendered[6]==0,"black stays black");
    check(near(rendered[8],1,1e-3)&&near(rendered[9],1,1e-3)&&near(rendered[10],1,1e-3),"the RAW's white stays white");
    check(rendered[13]>neutral[13]+0.05&&rendered[13]<rendered[1],"a darker grey is lifted and stays darker");
    // Hue: the middle channel keeps its place between the other two, in
    // linear ProPhoto, which is what the sRGB result is converted from.
    const float* c=raw[4].data();
    const auto expected=[&]{
        const float ratio=(c[1]-c[2])/(c[0]-c[2]);
        const auto t=[](double x){const double a=std::pow(0.10,1.3),k=0.82*a/(0.18-a),xp=std::pow(x,1.3);return float((1+k)*xp/(xp+k));};
        const float top=t(c[0]),bottom=t(c[2]);
        return toSrgb.map(QRgbaFloat32{top,bottom+(top-bottom)*ratio,bottom,1});
    }();
    check(near(rendered[16],expected.r,3e-3)&&near(rendered[17],expected.g,3e-3)&&near(rendered[18],expected.b,3e-3),
          "a colour is toned on its largest and smallest channel, its hue kept");
    // The DNG baseline exposure: one stop up makes RAW 0.05 the 0.10 grey.
    d.metadata.baseline_exposure_ev=1.0;
    const auto lifted=floats(display::originalImage(d,srgb),0);
    check(near(lifted[12],grey,2e-3),"the DNG baseline exposure adds its stops");
}

// The Original against the print, through the two geometry paths the
// controller uses: the print's turned frames come from its RGBA16 through
// exportImage (output::displayFrame), the Original from its half-float image
// through displayImage. Both decodes code each pixel's position, so a
// different crop, turn, flip or straighten shows as a different picture.
void originalGeometry() {
    const int width=240,height=160;
    const OutputEncoding srgb{"sRGB",true};
    // Red and green ramp with position; blue is a sawtooth, so a shift of one
    // pixel anywhere changes the picture by far more than precision does.
    const auto lin=[&](int x,int y){return std::array<float,3>{0.02f+0.9f*float(x)/(width-1),0.02f+0.9f*float(y)/(height-1),
                                                                 0.1f+0.08f*float((x*3+y*5)%11)};};
    const auto d=decode(width,height,lin);
    const auto original=display::originalImage(d,srgb);
    // The "print": the same picture already encoded, as the engine's RGBA16.
    const auto encode=QColorSpace(QColorSpace::SRgbLinear).transformationToColorSpace(QColorSpace(QColorSpace::SRgb));
    QImage print(width,height,QImage::Format_RGBA64);
    for(int y=0;y<height;++y) {
        auto* row=reinterpret_cast<QRgba64*>(print.scanLine(y));
        const auto source=floats(original,y);
        for(int x=0;x<width;++x)
            row[x]=QRgba64::fromRgba64(quint16(std::lround(source[x*4]*65535.0)),quint16(std::lround(source[x*4+1]*65535.0)),
                                       quint16(std::lround(source[x*4+2]*65535.0)),65535);
    }
    (void)encode;
    auto maxDifference=[](const QImage& a,const QImage& b) {
        if(a.size()!=b.size())return 1e9;
        double worst=0;
        for(int y=0;y<a.height();++y){const auto ra=floats(a,y),rb=floats(b,y);
            for(std::size_t i=0;i<ra.size();++i)worst=std::max(worst,double(std::abs(ra[i]-rb[i])));}
        return worst;
    };
    const QColorSpace tag(QColorSpace::SRgb);
    const output::Geometry cases[]={
        {QRectF(0,0,1,1)},
        {QRectF(0.1,0.2,0.7,0.6)},
        {QRectF(0.1,0.2,0.7,0.6),1,true,false,0},
        {QRectF(0.15,0.1,0.6,0.7),3,false,true,0},
        {QRectF(0.1,0.2,0.7,0.6),1,true,false,4.0},
        {QRectF(0.05,0.05,0.9,0.9),2,true,true,-7.5}};
    for(const auto& geometry:cases) {
        const auto shown=display::halfImage(output::exportImage(print,geometry,{}),tag);
        const auto before=output::displayImage(original,geometry);
        const double worst=maxDifference(before,shown);
        check(before.colorSpace()==shown.colorSpace(),"the Original keeps the print's tag through geometry");
        check(worst<4e-3,"the Original lands on the print's pixels under crop " +
              std::to_string(geometry.crop.x())+" turn "+std::to_string(geometry.quarterTurns)+" straighten "+
              std::to_string(geometry.straightenDegrees)+": "+std::to_string(worst));
    }
    // The control: one pixel of crop, or the other flip, is a visible miss.
    const output::Geometry base{QRectF(0.1,0.2,0.7,0.6),1,true,false,4.0};
    auto shifted=base;shifted.crop.translate(1.0/width,0);
    auto flipped=base;flipped.flipHorizontal=false;
    const auto shown=display::halfImage(output::exportImage(print,base,{}),tag);
    check(maxDifference(output::displayImage(original,shifted),shown)>1e-2,"a one-pixel crop shift fails the comparison");
    check(maxDifference(output::displayImage(original,flipped),shown)>1e-1,"a different flip fails the comparison");
}
}

int main(int argc,char** argv) {
    QCoreApplication application(argc,argv);
    try {
        zoomLadder();
        viewMaths();
        cropGrips();
        straightenLine();
        histograms();
        originalColour();
        originalRawLook();
        originalGeometry();
    } catch(const std::exception& e) {
        std::fprintf(stderr,"FAIL after %d checks: %s\n",checks,e.what());
        return 1;
    }
    std::printf("spk_qt_canvas_tools: %d checks passed\n",checks);
    return 0;
}
