// FrameCanvas through forced display LUTs, rendered for real and read back:
// by default D3D11 on the WARP software adapter through QQuickRenderControl
// (no window, no swap chain, the same scene graph and material as the app);
// with --software, the software backend and its CPU path. Every case compares
// the pixels with a reference computed here, independently of
// ColorCanvasNode.cpp: double-precision trilinear interpolation at the LUT
// nodes (between the contract's 1-D curves when the LUT has them), clamped,
// rounded to 8 bits.
//
// Exit 77 (CTest: skipped) when no D3D11 device can be created, with a
// message on stderr; anything else that goes wrong is a failure.
#include "ColorCanvasNode.hpp"
#include "ColorLut.hpp"
#include "ColorPipeline.hpp"
#include "FrameCanvas.hpp"
#include <QGuiApplication>
#include <QQuickGraphicsConfiguration>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <QtGui/qrgbafloat.h>
#include <QSGRectangleNode>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <rhi/qrhi.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <functional>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>

namespace {
constexpr int kSkipped=77;
// --hardware (by hand, not in CTest): the machine's own adapter instead.
bool preferWarp=true;
// The letterbox swatch and the window's clear colour: the LUTs below move
// both visibly, so an untouched pixel proves the transform skipped it.
const QColor kLetterbox(0x5f,0x5f,0x5f),kClear(0x20,0x30,0x40);

struct Skip : std::runtime_error {using std::runtime_error::runtime_error;};
void check(bool value,const std::string& message) {if(!value)throw std::runtime_error(message);}

// Stands in for the QML Rectangle behind the canvas: chrome, drawn by the
// scene graph's own rectangle node, never by the canvas material.
class Swatch final : public QQuickItem {
public:
    explicit Swatch(QQuickItem* parent):QQuickItem(parent) {setFlag(ItemHasContents);}
protected:
    QSGNode* updatePaintNode(QSGNode* old,UpdatePaintNodeData*) override {
        auto* node=static_cast<QSGRectangleNode*>(old);
        if(!node)node=window()->createRectangleNode();
        node->setRect(boundingRect());node->setColor(kLetterbox);
        return node;
    }
};

// The canvas as it was before the display LUT: Qt's own texture node with
// the same filtering rule and rectangle. Under the identity LUT FrameCanvas
// must render exactly what this does.
class PlainCanvas final : public QQuickItem {
public:
    explicit PlainCanvas(QQuickItem* parent):QQuickItem(parent) {setFlag(ItemHasContents);setClip(true);}
    void show(const QImage& image,const QRectF& rect,bool smooth) {image_=image;rect_=rect;smooth_=smooth;setVisible(true);update();}
protected:
    QSGNode* updatePaintNode(QSGNode* old,UpdatePaintNodeData*) override {
        delete old;
        auto* node=new QSGSimpleTextureNode;
        node->setTexture(window()->createTextureFromImage(image_));node->setOwnsTexture(true);
        node->setFiltering(smooth_?QSGTexture::Linear:QSGTexture::Nearest);node->setRect(rect_);
        return node;
    }
private:
    QImage image_;QRectF rect_;bool smooth_=false;
};

// A QQuickWindow rendered by QQuickRenderControl into a texture (RHI) or a
// QImage (software), with a full-size swatch, the old canvas (hidden) and a
// FrameCanvas on top.
class Harness {
public:
    // A float target (RHI only) measures the shader's output before any 8-bit
    // rounding.
    Harness(QSize size,bool software,bool floatTarget=false):size_(size),software_(software),floatTarget_(floatTarget) {
        window_=std::make_unique<QQuickWindow>(&control_);
        if(!software) {
            // WARP: the same answer on every machine, and no GPU needed.
            QQuickGraphicsConfiguration config;config.setPreferSoftwareDevice(preferWarp);
            window_->setGraphicsConfiguration(config);
        }
        window_->setColor(kClear);
        window_->resize(size);window_->contentItem()->setSize(size);
        auto* swatch=new Swatch(window_->contentItem());swatch->setSize(size);
        plain_=new PlainCanvas(window_->contentItem());plain_->setSize(size);plain_->setVisible(false);
        canvas_=new FrameCanvas(window_->contentItem());canvas_->setSize(size);
        pipeline_=ColorPipeline::forWindow(window_.get());
        pipeline_->setDither(false);
        pipeline_->setLutOverrideForTesting(std::make_shared<const ColorLut>());
        check(window_->effectiveDevicePixelRatio()==1.0,"device pixel ratio is not 1; the pixel mapping below assumes it");
        if(software) {
            // The software adaptation must not call initialize().
            image_=QImage(size,QImage::Format_ARGB32_Premultiplied);image_.fill(Qt::black);
            window_->setRenderTarget(QQuickRenderTarget::fromPaintDevice(&image_));
            return;
        }
        if(!control_.initialize())throw Skip("QQuickRenderControl could not create a D3D11 device (WARP)");
        QRhi* rhi=control_.rhi();
        check(rhi!=nullptr,"render control has no QRhi");
        texture_.reset(rhi->newTexture(floatTarget?QRhiTexture::RGBA32F:QRhiTexture::RGBA8,size,1,
                                       QRhiTexture::RenderTarget|QRhiTexture::UsedAsTransferSource));
        check(texture_->create(),"cannot create the render target texture");
        depth_.reset(rhi->newRenderBuffer(QRhiRenderBuffer::DepthStencil,size,1));
        check(depth_->create(),"cannot create the depth-stencil buffer");
        QRhiTextureRenderTargetDescription description{QRhiColorAttachment(texture_.get())};
        description.setDepthStencilBuffer(depth_.get());
        target_.reset(rhi->newTextureRenderTarget(description));
        pass_.reset(target_->newCompatibleRenderPassDescriptor());
        target_->setRenderPassDescriptor(pass_.get());
        check(target_->create(),"cannot create the texture render target");
        window_->setRenderTarget(QQuickRenderTarget::fromRhiRenderTarget(target_.get()));
    }
    QQuickWindow& window() {return *window_;}
    FrameCanvas& canvas() {return *canvas_;}
    PlainCanvas& plain() {return *plain_;}
    ColorPipeline& pipeline() {return *pipeline_;}
    QRhi* rhi() const {return control_.rhi();}
    QImage render() {
        control_.polishItems();
        control_.beginFrame();
        control_.sync();
        control_.render();
        if(software_) {
            control_.endFrame();
            return image_.convertToFormat(QImage::Format_ARGB32);
        }
        QRhiReadbackResult result;
        QRhiResourceUpdateBatch* readback=control_.rhi()->nextResourceUpdateBatch();
        readback->readBackTexture(texture_.get(),&result);
        control_.commandBuffer()->resourceUpdate(readback);
        control_.endFrame();  // an offscreen frame: complete when this returns
        const int texel=floatTarget_?16:4;
        check(result.pixelSize==size_ && result.data.size()>=qsizetype(size_.width())*size_.height()*texel,"readback incomplete");
        QImage image(reinterpret_cast<const uchar*>(result.data.constData()),size_.width(),size_.height(),
                     qsizetype(size_.width())*texel,
                     floatTarget_?QImage::Format_RGBA32FPx4_Premultiplied:QImage::Format_RGBA8888_Premultiplied);
        QImage copy=image.convertToFormat(floatTarget_?QImage::Format_RGBA32FPx4:QImage::Format_ARGB32);
        return control_.rhi()->isYUpInFramebuffer()?copy.flipped(Qt::Vertical):copy;
    }
private:
    // Destroyed bottom to top: RHI resources, then the window (its scene
    // graph), then the render control that owns the QRhi.
    QSize size_;
    bool software_,floatTarget_;
    QQuickRenderControl control_;
    std::unique_ptr<QQuickWindow> window_;
    FrameCanvas* canvas_=nullptr;
    PlainCanvas* plain_=nullptr;
    ColorPipeline* pipeline_=nullptr;
    QImage image_;
    std::unique_ptr<QRhiTexture> texture_;
    std::unique_ptr<QRhiRenderBuffer> depth_;
    std::unique_ptr<QRhiTextureRenderTarget> target_;
    std::unique_ptr<QRhiRenderPassDescriptor> pass_;
};

using Rgb=std::array<double,3>;
using Transfer=std::function<Rgb(const Rgb&)>;

std::shared_ptr<const ColorLut> makeLut(int n,quint64 key,const Transfer& f) {
    auto lut=std::make_shared<ColorLut>();
    lut->size=n;lut->key=key;lut->rgba.resize(size_t(n)*n*n*4);
    for(int b=0;b<n;++b)for(int g=0;g<n;++g)for(int r=0;r<n;++r) {
        const Rgb out=f({r/double(n-1),g/double(n-1),b/double(n-1)});
        float* node=lut->rgba.data()+((size_t(b)*n+g)*n+r)*4;
        node[0]=float(out[0]);node[1]=float(out[1]);node[2]=float(out[2]);node[3]=1;
    }
    return lut;
}

// The reference: the contract's grid, trilinear, clamped in and out.
Rgb referenceLookup(const ColorLut& lut,Rgb c) {
    for(auto& v:c)v=std::clamp(v,0.0,1.0);
    if(lut.size==0)return c;
    const int n=lut.size;
    int i[3];double f[3];
    for(int k=0;k<3;++k){const double p=c[k]*(n-1);i[k]=std::min(int(p),n-2);f[k]=p-i[k];}
    Rgb out{};
    for(int corner=0;corner<8;++corner) {
        const int dr=corner&1,dg=(corner>>1)&1,db=(corner>>2)&1;
        const double w=(dr?f[0]:1-f[0])*(dg?f[1]:1-f[1])*(db?f[2]:1-f[2]);
        const float* node=lut.rgba.data()+((size_t(i[2]+db)*n+(i[1]+dg))*n+(i[0]+dr))*4;
        for(int k=0;k<3;++k)out[k]+=w*node[k];
    }
    for(auto& v:out)v=std::clamp(v,0.0,1.0);
    return out;
}

// A LUT with the contract's 1-D curves: the per-channel shaper, the table as
// a 3x3 matrix over the shaper's output (left unclamped, as a profile's would
// be), and the output curve as a function of the table's output u (stored
// against sqrt(u), as the contract indexes it).
std::shared_ptr<const ColorLut> curvesLut(int n,int m,quint64 key,const std::function<double(double)>& shaper,
                                          const std::array<double,9>& matrix,const std::function<double(double)>& output) {
    auto lut=std::make_shared<ColorLut>(*makeLut(n,key,[&](const Rgb& t) {
        Rgb out;
        for(int k=0;k<3;++k)out[k]=matrix[k*3]*t[0]+matrix[k*3+1]*t[1]+matrix[k*3+2]*t[2];
        return out;
    }));
    lut->curveSize=m;lut->shaper.resize(size_t(m)*4);lut->output.resize(size_t(m)*4);
    for(int j=0;j<m;++j) {
        const double x=j/double(m-1);
        for(int k=0;k<3;++k) {
            lut->shaper[size_t(j)*4+k]=float(shaper(x));
            lut->output[size_t(j)*4+k]=float(output(x*x));
        }
        lut->shaper[size_t(j)*4+3]=lut->output[size_t(j)*4+3]=1;
    }
    return lut;
}
double referenceCurve(const std::vector<float>& curve,int m,double x,int c) {
    const double p=std::clamp(x,0.0,1.0)*(m-1);
    const int i=std::min(int(p),m-2);
    return curve[size_t(i)*4+c]+(curve[size_t(i+1)*4+c]-curve[size_t(i)*4+c])*(p-i);
}
// The whole display transform: shaper -> table -> output(sqrt), each step
// clamped as the contract says; the table alone without curves.
Rgb referenceTransform(const ColorLut& lut,Rgb c) {
    for(auto& v:c)v=std::clamp(v,0.0,1.0);
    if(lut.size==0 || !lut.hasCurves())return referenceLookup(lut,c);
    for(int k=0;k<3;++k)c[k]=std::clamp(referenceCurve(lut.shaper,lut.curveSize,c[k],k),0.0,1.0);
    const Rgb u=referenceLookup(lut,c);
    Rgb out;
    for(int k=0;k<3;++k)out[k]=std::clamp(referenceCurve(lut.output,lut.curveSize,std::sqrt(u[k]),k),0.0,1.0);
    return out;
}
int quantize(double v) {return int(std::floor(std::clamp(v,0.0,1.0)*255.0+0.5));}

// The source pixel as the shader reads it: 8-bit or half float, straight,
// with its alpha in [3].
std::array<double,4> sourcePixel(const QImage& image,int x,int y) {
    switch(image.format()) {
    case QImage::Format_RGBX16FPx4: case QImage::Format_RGBA16FPx4: {
        const auto p=reinterpret_cast<const QRgbaFloat16*>(image.constScanLine(y))[x];
        return {double(float(p.red())),double(float(p.green())),double(float(p.blue())),double(float(p.alpha()))};
    }
    case QImage::Format_ARGB32_Premultiplied: {
        const QRgb p=reinterpret_cast<const QRgb*>(image.constScanLine(y))[x];
        const double a=qAlpha(p)/255.0;
        if(a==0)return {0,0,0,0};
        return {qRed(p)/255.0/a,qGreen(p)/255.0/a,qBlue(p)/255.0/a,a};
    }
    default: {
        const QRgb p=image.pixel(x,y);
        return {qRed(p)/255.0,qGreen(p)/255.0,qBlue(p)/255.0,qAlpha(p)/255.0};
    }
    }
}

struct Comparison {
    int maxDiff=0;
    qint64 differing=0,pixels=0;
    QPoint worst;
    std::set<int> redLevels;  // distinct output red values inside the image
};
// Inside the image rectangle every pixel against the reference (the LUT's
// output composited over the letterbox by the frame's alpha times the item
// opacity); outside it every pixel against the letterbox, exactly.
// With `model`, the expected colour is the colour core's own CPU model of the
// canvas (spk::color::sampleLut) instead of this file's reference.
Comparison compare(const QImage& got,const QRect& imageRect,const QImage& source,const ColorLut& lut,
                   QPoint sourceOrigin={},double opacity=1.0,const spk::color::LutSampling* model=nullptr) {
    const Rgb ground{kLetterbox.redF(),kLetterbox.greenF(),kLetterbox.blueF()};
    Comparison result;
    for(int y=0;y<got.height();++y)for(int x=0;x<got.width();++x) {
        const QRgb pixel=got.pixel(x,y);
        if(!imageRect.contains(x,y)) {
            if(pixel!=kLetterbox.rgb())
                throw std::runtime_error("letterbox pixel ("+std::to_string(x)+","+std::to_string(y)+") changed to #"+
                                         QString::number(pixel&0xffffff,16).toStdString());
            continue;
        }
        const int sx=x-imageRect.x()+sourceOrigin.x(),sy=y-imageRect.y()+sourceOrigin.y();
        const auto in=sourcePixel(source,sx,sy);
        Rgb expected=referenceTransform(lut,{in[0],in[1],in[2]});
        if(model) {
            const auto m=spk::color::sampleLut(lut,float(in[0]),float(in[1]),float(in[2]),*model);
            for(int k=0;k<3;++k)expected[k]=std::clamp(double(m[k]),0.0,1.0);
        }
        const double a=in[3]*opacity;
        for(int k=0;k<3;++k)expected[k]=expected[k]*a+ground[k]*(1-a);
        const int e[3]={quantize(expected[0]),quantize(expected[1]),quantize(expected[2])};
        const int g[3]={qRed(pixel),qGreen(pixel),qBlue(pixel)};
        int diff=0;for(int k=0;k<3;++k)diff=std::max(diff,std::abs(e[k]-g[k]));
        if(diff>result.maxDiff){result.maxDiff=diff;result.worst=QPoint(x,y);}
        result.differing+=diff>0;++result.pixels;result.redLevels.insert(g[0]);
    }
    return result;
}
void report(const char* name,const Comparison& c) {
    std::printf("  %-44s max diff %d, %lld of %lld pixels differ\n",name,c.maxDiff,c.differing,c.pixels);
    std::fflush(stdout);
}
void expect(const char* name,const Comparison& c,int tolerance) {
    report(name,c);
    if(c.maxDiff>tolerance)
        throw std::runtime_error(std::string(name)+": max diff "+std::to_string(c.maxDiff)+" > "+std::to_string(tolerance)+
                                 " at ("+std::to_string(c.worst.x())+","+std::to_string(c.worst.y())+")");
}

// The whole frame of the canvas against the old texture node showing the
// same image in the same rectangle: the largest channel difference.
int againstPlain(Harness& h,const QImage& image,qint64* differing=nullptr) {
    auto& canvas=h.canvas();
    canvas.setImage(image);
    const QImage ours=h.render();
    canvas.setVisible(false);
    h.plain().show(image,canvas.imageRect(),canvas.scalePercent()<100);
    const QImage theirs=h.render();
    h.plain().setVisible(false);canvas.setVisible(true);
    int worst=0;qint64 count=0;
    for(int y=0;y<ours.height();++y)for(int x=0;x<ours.width();++x) {
        const QRgb a=ours.pixel(x,y),b=theirs.pixel(x,y);
        const int d=std::max({std::abs(qRed(a)-qRed(b)),std::abs(qGreen(a)-qGreen(b)),std::abs(qBlue(a)-qBlue(b))});
        worst=std::max(worst,d);count+=d>0;
    }
    if(differing)*differing=count;
    return worst;
}

const char* formatName(QRhiTexture::Format format) {
    switch(format) {
    case QRhiTexture::RGBA8: return "RGBA8";
    case QRhiTexture::BGRA8: return "BGRA8";
    case QRhiTexture::RGBA16F: return "RGBA16F";
    case QRhiTexture::RGBA32F: return "RGBA32F";
    default: return "other";
    }
}

// The image rectangle at 100 %, on whole pixels (FrameCanvas aligns it).
QRect wholeRect(FrameCanvas& canvas) {
    const QRectF r=canvas.imageRect();
    const QRect rounded(qRound(r.x()),qRound(r.y()),qRound(r.width()),qRound(r.height()));
    check(std::abs(r.x()-rounded.x())<1e-9 && std::abs(r.y()-rounded.y())<1e-9 && QRectF(rounded).size()==r.size(),
          "image rectangle is not on the pixel grid at 100 %");
    // Only the visible part: the canvas clips to its own bounds.
    return rounded.intersected(QRect(QPoint(),canvas.size().toSize()));
}

QImage pattern8(int width,int height) {
    QImage image(width,height,QImage::Format_ARGB32);
    for(int y=0;y<height;++y)for(int x=0;x<width;++x)
        image.setPixel(x,y,qRgb(x&255,(y*3+x/7)&255,((x^y)*5)&255));
    image.setColorSpace(QColorSpace::SRgb);
    return image;
}

// Triangle waves 64 counts per pixel in x, y and x+y.
QImage triangles(int width,int height) {
    auto wave=[](int t){return std::min(255,std::abs((t*64)%512-256));};
    QImage image(width,height,QImage::Format_ARGB32);
    for(int y=0;y<height;++y)for(int x=0;x<width;++x)image.setPixel(x,y,qRgb(wave(x),wave(y),wave(x+y)));
    image.setColorSpace(QColorSpace::SRgb);
    return image;
}

// A smooth ramp from 0.4 to 0.6 across the width in every channel, at half-
// float precision (or 8 bits in the control), for the contrast LUT below.
QImage ramp(int width,int height,QImage::Format format) {
    QImage image(width,height,format);
    for(int y=0;y<height;++y)for(int x=0;x<width;++x) {
        const float v=0.4f+0.2f*x/(width-1);
        if(format==QImage::Format_ARGB32)image.setPixel(x,y,qRgb(qRound(v*255),qRound(v*255),qRound(v*255)));
        else if(format==QImage::Format_RGBA64)
            reinterpret_cast<QRgba64*>(image.scanLine(y))[x]=QRgba64::fromRgba64(quint16(qRound(v*65535)),quint16(qRound(v*65535)),quint16(qRound(v*65535)),65535);
        else reinterpret_cast<QRgbaFloat16*>(image.scanLine(y))[x]=QRgbaFloat16{qfloat16(v),qfloat16(v),qfloat16(v),qfloat16(1)};
    }
    image.setColorSpace(QColorSpace::SRgb);
    return image;
}

void run(bool software) {
    const char* mode=software?"software backend (CPU path)":"D3D11";
    const auto identity=std::make_shared<const ColorLut>();
    const auto swap=makeLut(17,101,[](const Rgb& c){return Rgb{c[1],c[2],c[0]};});
    const auto gamma=makeLut(33,102,[](const Rgb& c){return Rgb{std::pow(c[0],1/2.2),std::pow(c[1],1/2.2),std::pow(c[2],1/2.2)};});
    const auto nodes=makeLut(33,103,[](const Rgb& c){return c;});
    const auto contrast=makeLut(65,104,[](const Rgb& c){
        Rgb out;for(int k=0;k<3;++k)out[k]=std::clamp((c[k]-0.4)*5,0.0,1.0);return out;});

    Harness h(QSize(1100,240),software);
    if(!software) {
        const auto info=h.rhi()->driverInfo();
        std::printf("%s: %s on \"%s\", texture limit %d, 3D textures %s\n",mode,h.rhi()->backendName(),
                    info.deviceName.constData(),h.rhi()->resourceLimit(QRhi::TextureSizeMax),
                    h.rhi()->isFeatureSupported(QRhi::ThreeDimensionalTextures)?"yes":"no");
    } else std::printf("%s\n",mode);
    auto& canvas=h.canvas();
    canvas.setFit(false);

    // (a) 8-bit sRGB frame, 100 %, through identity, channel swap, gamma and
    // a LUT whose nodes are the identity (the lookup path with nothing to do).
    const QImage frame=pattern8(256,192);
    canvas.setImage(frame);
    QImage got=h.render();
    const QRect rect=wholeRect(canvas);
    expect("identity (no lookup): exact",compare(got,rect,frame,*identity),0);
    // The identity draws what the old canvas drew, bit for bit: at 100 %,
    // magnified (both Nearest) and reduced (Linear).
    {
        struct Case {const char* name;QImage image;bool fit;};
        const Case cases[]={{"100 %",frame,false},{"fit, magnified 125 %",frame,true},{"fit, reduced 34 %",pattern8(2000,700),true}};
        for(const auto& c:cases) {
            canvas.setFit(c.fit);
            qint64 n=0;const int worst=againstPlain(h,c.image,&n);
            std::printf("  %-44s max diff %d, %lld pixels differ\n",(std::string("identity vs Qt's texture node, ")+c.name).c_str(),worst,n);
            check(worst==0,std::string("the identity differs from the old canvas, ")+c.name);
        }
        canvas.setFit(false);
        canvas.setImage(frame);
    }
    h.pipeline().setLutOverrideForTesting(swap);
    expect("channel swap, 17^3",compare(h.render(),rect,frame,*swap),1);
    h.pipeline().setLutOverrideForTesting(gamma);
    const QImage gammaRender=h.render();
    expect("gamma 1/2.2, 33^3 (letterbox exact)",compare(gammaRender,rect,frame,*gamma),1);
    h.pipeline().setLutOverrideForTesting(nodes);
    expect("identity-valued 33^3 through the lookup",compare(h.render(),rect,frame,*nodes),1);

    if(!software) {
        // The 2D atlas an RHI without 3D textures gets.
        canvas_testing::setForceLutAtlas(true);
        h.pipeline().setLutOverrideForTesting(swap);
        expect("atlas: channel swap",compare(h.render(),rect,frame,*swap),1);
        h.pipeline().setLutOverrideForTesting(gamma);
        expect("atlas: gamma",compare(h.render(),rect,frame,*gamma),1);
        canvas_testing::setForceLutAtlas(false);
    }

    // The contract's 1-D curves around the table, 4096 entries as the colour
    // core builds them. A gamma-2.2 shaper, an identity table and the inverse
    // output curve make the identity; sRGB decode -> matrix -> gamma-2.2
    // encode is held to the reference, into Adobe RGB (in gamut) and from it
    // (negative coefficients: the table's output is clamped before the output
    // curve). Then LUTs the colour core itself builds, held to its own CPU
    // model of the recommended canvas sampling (ColorLut.hpp).
    {
        constexpr int kCurve=4096;
        auto srgbDecode=[](double x){return x<=0.04045?x/12.92:std::pow((x+0.055)/1.055,2.4);};
        auto encode22=[](double u){return std::pow(u,256.0/563.0);};
        const std::array<double,9> unit{1,0,0,0,1,0,0,0,1};
        const std::array<double,9> toAdobe{0.7151627,0.2848373,0,0,1,0,0,0.0411705,0.9588295};
        const std::array<double,9> fromAdobe{1.3982832,-0.3982831,0,0,1,0,0,-0.0429383,1.0429383};
        const auto roundTrip=curvesLut(65,kCurve,201,[](double x){return std::pow(x,2.2);},unit,
                                       [](double u){return std::pow(u,1/2.2);});
        h.pipeline().setLutOverrideForTesting(roundTrip);
        expect("curves: gamma 2.2 round trip is the identity",compare(h.render(),rect,frame,*identity),1);
        const auto adobe=curvesLut(65,kCurve,202,srgbDecode,toAdobe,encode22);
        h.pipeline().setLutOverrideForTesting(adobe);
        expect("curves: sRGB -> Adobe RGB",compare(h.render(),rect,frame,*adobe),1);
        const auto clipped=curvesLut(65,kCurve,203,encode22,fromAdobe,srgbDecode);
        h.pipeline().setLutOverrideForTesting(clipped);
        expect("curves: out of gamut, clamped before output",compare(h.render(),rect,frame,*clipped),1);

        const spk::color::LutSampling recommended{8,true,true,false,false};
        const QColorSpace srgb(QColorSpace::SRgb),adobeRgb(QColorSpace::AdobeRgb),proPhoto(QColorSpace::ProPhotoRgb),
            p3(QColorSpace::DisplayP3);
        const std::pair<const char*,std::shared_ptr<const ColorLut>> built[]={
            {"core: curved sRGB -> Adobe RGB, vs its model",spk::color::buildCurvedLut(srgb,adobeRgb)},
            {"core: curved ProPhoto -> sRGB, vs its model",spk::color::buildCurvedLut(proPhoto,srgb)},
            {"core: encoded sRGB -> Display P3, vs its model",spk::color::buildEncodedLut(srgb,p3)}};
        for(const auto& [name,lut]:built) {
            check(lut && displayLutActive(*lut) && lut->hasCurves()==(std::string(name).find("curved")!=std::string::npos),
                  std::string(name)+": the colour core did not build the expected LUT");
            h.pipeline().setLutOverrideForTesting(lut);
            expect(name,compare(h.render(),rect,frame,*lut,{},1.0,&recommended),1);
        }
        if(!software) {
            canvas_testing::setForceLutAtlas(true);
            h.pipeline().setLutOverrideForTesting(built[1].second);
            expect("atlas: core curved ProPhoto -> sRGB",compare(h.render(),rect,frame,*built[1].second,{},1.0,&recommended),1);
            canvas_testing::setForceLutAtlas(false);

            // How far the shader's output lies from exact float filtering
            // before the 8-bit rounding, read from a 32-bit float target.
            Harness precise(QSize(320,240),false,true);
            precise.canvas().setFit(false);
            precise.canvas().setImage(frame);
            double worstAll=0;
            for(const auto& [name,lut]:{std::pair{"gamma 2.2 round trip",roundTrip},std::pair{"sRGB -> Adobe RGB",adobe},
                                        std::pair{"core ProPhoto -> sRGB",built[1].second}}) {
                precise.pipeline().setLutOverrideForTesting(lut);
                const QImage out=precise.render();
                const QRect area=wholeRect(precise.canvas());
                double worst=0;
                for(int y=area.top();y<=area.bottom();++y)for(int x=area.left();x<=area.right();++x) {
                    const auto in=sourcePixel(frame,x-area.x(),y-area.y());
                    const Rgb expected=referenceTransform(*lut,{in[0],in[1],in[2]});
                    const auto p=reinterpret_cast<const QRgbaFloat32*>(out.constScanLine(y))[x];
                    const double got[3]={p.red(),p.green(),p.blue()};
                    for(int k=0;k<3;++k)worst=std::max(worst,std::abs(got[k]-expected[k])*255);
                }
                worstAll=std::max(worstAll,worst);
                std::printf("  %-44s %.4f counts from exact before rounding\n",(std::string("float target: ")+name).c_str(),worst);
            }
            check(worstAll<0.25,"the curved path is more than a quarter count from exact before rounding");
        }
    }

    // Dither: one LSB of triangular noise where the LUT runs; never on an
    // 8-bit frame under the identity.
    h.pipeline().setLutOverrideForTesting(gamma);
    h.pipeline().setDither(true);
    const QImage dithered=h.render();
    qint64 changed=0,inside=0;int worst=0;
    for(int y=rect.top();y<=rect.bottom();++y)for(int x=rect.left();x<=rect.right();++x) {
        const QRgb a=dithered.pixel(x,y),b=gammaRender.pixel(x,y);
        const int d=std::max({std::abs(qRed(a)-qRed(b)),std::abs(qGreen(a)-qGreen(b)),std::abs(qBlue(a)-qBlue(b))});
        worst=std::max(worst,d);changed+=d>0;++inside;
    }
    std::printf("  %-44s max diff %d from undithered, %lld of %lld pixels moved\n","dither on, gamma",worst,changed,inside);
    check(worst<=1 && changed>inside/20,"dither is not a one-step triangular perturbation of most pixels");
    h.pipeline().setLutOverrideForTesting(identity);
    expect("dither on, identity, 8-bit: still exact",compare(h.render(),rect,frame,*identity),0);
    h.pipeline().setDither(false);

    // Translucency: the frame's own alpha (straight ARGB32, premultiplied on
    // upload, unpremultiplied before the lookup) and an item opacity below 1
    // composite the transformed colour over the letterbox. An 8-bit texture
    // holds premultiplied colour, as Qt's did, so the GPU reference starts
    // from that: a steep LUT amplifies its rounding in dark translucent
    // pixels (the straight-alpha reference measured 4 counts off with the
    // gamma LUT). The app's frames are opaque, where premultiplying is exact.
    {
        QImage translucent=frame.copy();
        for(int y=0;y<translucent.height();++y)for(int x=0;x<translucent.width();++x) {
            const QRgb p=translucent.pixel(x,y);
            translucent.setPixel(x,y,qRgba(qRed(p),qGreen(p),qBlue(p),40+(x*3+y)%216));
        }
        qint64 n=0;const int worst=againstPlain(h,translucent,&n);
        std::printf("  %-44s max diff %d, %lld pixels differ\n","translucent, identity vs Qt's texture node",worst,n);
        check(worst==0,"the identity differs from the old canvas on a translucent frame");
        h.pipeline().setLutOverrideForTesting(gamma);
        const QImage stored=software?translucent:translucent.convertToFormat(QImage::Format_ARGB32_Premultiplied);
        expect("translucent frame, gamma",compare(h.render(),rect,stored,*gamma),1);
        h.pipeline().setLutOverrideForTesting(identity);
        canvas.setImage(frame);
        canvas.setOpacity(0.5);
        expect("opacity 0.5, identity",compare(h.render(),rect,frame,*identity,{},0.5),1);
        h.pipeline().setLutOverrideForTesting(gamma);
        expect("opacity 0.5, gamma",compare(h.render(),rect,frame,*gamma,{},0.5),1);
        canvas.setOpacity(1);
        h.pipeline().setLutOverrideForTesting(identity);
    }

    // (b) Deep frames keep their extra bits up to the LUT: a 0.4..0.6 ramp
    // through a 5x contrast LUT spans the whole output range.
    for(const auto format:{QImage::Format_RGBX16FPx4,QImage::Format_RGBA16FPx4,QImage::Format_RGBA64,QImage::Format_ARGB32}) {
        const QImage deep=ramp(1024,64,format);
        canvas.setImage(deep);
        h.pipeline().setLutOverrideForTesting(identity);
        const QImage plain=h.render();
        const QRect deepRect=wholeRect(canvas);
        // The reference reads the source as the shader does; RGBA64 is
        // uploaded as half float, so compare it through that conversion.
        const QImage asRead=format==QImage::Format_RGBA64?deep.convertToFormat(QImage::Format_RGBX16FPx4):deep;
        const std::string tag=format==QImage::Format_RGBX16FPx4?"RGBX16FPx4":format==QImage::Format_RGBA16FPx4?"RGBA16FPx4":
            format==QImage::Format_RGBA64?"RGBA64":"ARGB32 (8-bit control)";
        expect(("identity, "+tag).c_str(),compare(plain,deepRect,asRead,*identity),1);
        h.pipeline().setLutOverrideForTesting(contrast);
        const auto c=compare(h.render(),deepRect,asRead,*contrast);
        expect(("5x contrast, "+tag).c_str(),c,1);
        std::printf("  %-44s %zu distinct output levels\n",("5x contrast, "+tag).c_str(),c.redLevels.size());
        if(format==QImage::Format_ARGB32)check(c.redLevels.size()<=60,"the 8-bit control has more levels than 8 bits allow");
        else check(c.redLevels.size()>200,tag+" lost precision before the LUT");
    }
    if(!software) {
        // For the record, what the old canvas (QSGPlainTexture) did with deep
        // frames: the texture format Qt picks, and its picture beside ours.
        for(const auto format:{QImage::Format_RGBX16FPx4,QImage::Format_RGBA64,QImage::Format_ARGB32}) {
            const QImage deep=ramp(1024,64,format);
            std::unique_ptr<QSGTexture> texture(h.window().createTextureFromImage(deep));
            QRhiResourceUpdateBatch* updates=h.rhi()->nextResourceUpdateBatch();
            texture->commitTextureOperations(h.rhi(),updates);
            const char* uploaded=texture->rhiTexture()?formatName(texture->rhiTexture()->format()):"nothing";
            updates->release();
            h.pipeline().setLutOverrideForTesting(identity);
            qint64 n=0;const int worst=againstPlain(h,deep,&n);
            std::printf("  QSGPlainTexture uploads %s as %s; identity vs it: max diff %d, %lld pixels differ\n",
                        format==QImage::Format_RGBA64?"RGBA64":format==QImage::Format_ARGB32?"ARGB32":"RGBX16FPx4",uploaded,worst,n);
        }
    }

    // (c) Wider than D3D11's 16384: tiles, 100 % across the seam, exact.
    {
        Harness wide(QSize(600,100),software);
        auto& c=wide.canvas();
        c.setFit(false);
        const QImage huge=pattern8(17000,48);
        c.setImage(huge);
        wide.render();
        // Bring source column 16382 (the first tile's last interior column
        // + 1 at a 16384 limit) to the middle of the canvas.
        c.panBy(300-16382-c.imageRect().x(),0);
        const QRectF placed=c.imageRect();
        const QPoint origin(-qRound(placed.x()),0);
        QImage tiled=wide.render();
        const QRect visible=wholeRect(c);
        const int tiles=canvas_testing::lastTileCount();
        std::printf("  17000x48 frame: %d tile(s), source columns %d..%d visible\n",tiles,origin.x(),origin.x()+visible.width()-1);
        if(!software)check(wide.rhi()->resourceLimit(QRhi::TextureSizeMax)>=17000 || tiles==2,"a 17000 px frame was not split into two tiles");
        expect("17000 px wide, identity: exact",compare(tiled,visible,huge,*identity,origin),0);
        wide.pipeline().setLutOverrideForTesting(gamma);
        expect("17000 px wide, gamma",compare(wide.render(),visible,huge,*gamma,origin),1);
    }

    // Linear filtering (fit, below 100 %) is continuous across a seam: tiles
    // forced at 1024 px render what one texture does. Neighbouring texels
    // differ by 64 counts, so a tile clamping at its edge instead of reading
    // the apron is off by up to 32 at the seam, while the two layouts'
    // slightly different sample positions stay within a count. (With 255-
    // count neighbours that noise measured 2: D3D11 filter weights carry 8
    // fractional bits.)
    if(!software) {
        const QImage busy=triangles(3000,200);
        canvas.setImage(busy);
        canvas.setFit(true);
        h.pipeline().setLutOverrideForTesting(identity);
        const QImage whole=h.render();
        const int single=canvas_testing::lastTileCount();
        canvas_testing::setMaxTextureSize(1024);
        canvas.update();
        const QImage split=h.render();
        const int pieces=canvas_testing::lastTileCount();
        canvas_testing::setMaxTextureSize(0);
        check(single==1 && pieces==3,"seam case did not tile as intended");
        int worst=0;qint64 moved=0;
        for(int y=0;y<whole.height();++y)for(int x=0;x<whole.width();++x) {
            const QRgb a=whole.pixel(x,y),b=split.pixel(x,y);
            const int d=std::max({std::abs(qRed(a)-qRed(b)),std::abs(qGreen(a)-qGreen(b)),std::abs(qBlue(a)-qBlue(b))});
            worst=std::max(worst,d);moved+=d>0;
        }
        std::printf("  %-44s max diff %d, %lld pixels differ\n","fit 36.7 %, 3 tiles vs 1 texture",worst,moved);
        check(worst<=1,"a tile seam is visible under Linear filtering");
    }
}
}

int main(int argc,char** argv) {
    const bool software=argc>1 && QByteArray(argv[1])=="--software";
    preferWarp=!(argc>1 && QByteArray(argv[1])=="--hardware");
    // The software run uses the self-test's offscreen platform. The RHI run
    // cannot: Qt Quick picks the software adaptation on a platform plugin
    // without RHI support, which offscreen is on Windows. Its window is never
    // shown, and one item unit is one pixel whatever the monitor's scale.
    if(software && qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))qputenv("QT_QPA_PLATFORM","offscreen");
    if(qEnvironmentVariable("QT_QPA_PLATFORM")=="offscreen" && qEnvironmentVariableIsEmpty("QT_QPA_FONTDIR"))
        qputenv("QT_QPA_FONTDIR",(qEnvironmentVariable("WINDIR")+"/Fonts").toUtf8());
    qputenv("QT_ENABLE_HIGHDPI_SCALING","0");
    QQuickWindow::setGraphicsApi(software?QSGRendererInterface::Software:QSGRendererInterface::Direct3D11);
    QGuiApplication app(argc,argv);
    try {
        run(software);
        std::printf("PASS\n");
        return 0;
    } catch(const Skip& skip) {
        std::fprintf(stderr,"\n*** SKIPPED: %s. The GPU canvas test did not run. ***\n\n",skip.what());
        return kSkipped;
    } catch(const std::exception& error) {
        std::fprintf(stderr,"FAIL: %s\n",error.what());
        return 1;
    }
}
