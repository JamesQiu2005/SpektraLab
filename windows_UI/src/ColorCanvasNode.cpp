#include "ColorCanvasNode.hpp"
#include <QFloat16>
#include <QQuickWindow>
#include <QtGui/qrgbafloat.h>
#include <QSGGeometry>
#include <QSGGeometryNode>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <rhi/qrhi.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace {
std::atomic<int> maxTextureSizeForTesting{0};
std::atomic<bool> forceLutAtlasForTesting{false};
std::atomic<int> lastTileCountForTesting{0};
std::atomic<QRhiTexture::Format> curveFormat{QRhiTexture::RGBA16F};

// The shader variant: shaders/colorcanvas.frag built per LUT_MODE and CURVES.
enum Variant {NoLut=0,VolumeLut=1,AtlasLut=2,Copy=3,VolumeCurves=4,AtlasCurves=5};

bool isHalfFloat(QImage::Format format) {
    return format==QImage::Format_RGBX16FPx4 || format==QImage::Format_RGBA16FPx4 ||
        format==QImage::Format_RGBA16FPx4_Premultiplied;
}
// More than 8 bits per channel: kept above 8 bits up to the display LUT.
bool isDeep(const QImage& image) {
    const auto pixel=image.pixelFormat();
    return pixel.typeInterpretation()==QPixelFormat::FloatingPoint || image.depth()>32 ||
        image.format()==QImage::Format_Grayscale16 || pixel.redSize()>8;
}

// ---- The frame -------------------------------------------------------------

// How the frame goes up: the texture format, and the QImage format it must be
// converted to first (Format_Invalid: none). Textures hold premultiplied
// alpha, as Qt's own did; a format with straight alpha (ARGB32 today) is
// premultiplied in the render phase, where QSGPlainTexture converted it too,
// so the GUI thread never waits for it. RGBX16FPx4 from the 16-bit frames
// goes up as it is. QSGPlainTexture turned Format_RGBA64 into RGBA8
// (measured, tests/color_canvas.cpp); here every deep format keeps more than
// 8 bits up to the LUT.
struct Upload {
    QRhiTexture::Format format=QRhiTexture::BGRA8;
    QImage::Format convertTo=QImage::Format_Invalid;
    bool deep=false;      // more than 8 bits per channel reach the shader
};
Upload uploadable(QRhi* rhi,const QImage& image) {
    const bool alpha=image.hasAlphaChannel();
    constexpr auto none=QImage::Format_Invalid;
    Upload upload;
    switch(image.format()) {
    case QImage::Format_RGB32: case QImage::Format_ARGB32_Premultiplied: upload={QRhiTexture::BGRA8,none,false};break;
    case QImage::Format_ARGB32: upload={QRhiTexture::BGRA8,QImage::Format_ARGB32_Premultiplied,false};break;
    case QImage::Format_RGBX8888: case QImage::Format_RGBA8888_Premultiplied: upload={QRhiTexture::RGBA8,none,false};break;
    case QImage::Format_RGBA8888: upload={QRhiTexture::RGBA8,QImage::Format_RGBA8888_Premultiplied,false};break;
    case QImage::Format_RGBX16FPx4: case QImage::Format_RGBA16FPx4_Premultiplied: upload={QRhiTexture::RGBA16F,none,true};break;
    case QImage::Format_RGBA16FPx4: upload={QRhiTexture::RGBA16F,QImage::Format_RGBA16FPx4_Premultiplied,true};break;
    default:
        // Half float holds 11 significant bits, enough for any 16-bit integer
        // or float frame on an 8-bit display. 32-bit float textures need not
        // be filterable, and the canvas filters below 100 %.
        if(isDeep(image))upload={QRhiTexture::RGBA16F,alpha?QImage::Format_RGBA16FPx4_Premultiplied:QImage::Format_RGBX16FPx4,true};
        else upload={QRhiTexture::BGRA8,alpha?QImage::Format_ARGB32_Premultiplied:QImage::Format_RGB32,false};
    }
    if(upload.format==QRhiTexture::RGBA16F && !rhi->isTextureFormatSupported(QRhiTexture::RGBA16F))
        upload={QRhiTexture::BGRA8,alpha?QImage::Format_ARGB32_Premultiplied:QImage::Format_RGB32,false};
    if(upload.format==QRhiTexture::BGRA8 && !rhi->isTextureFormatSupported(QRhiTexture::BGRA8))
        upload={QRhiTexture::RGBA8,alpha?QImage::Format_RGBA8888_Premultiplied:QImage::Format_RGBX8888,false};
    return upload;
}

// One tile of the frame (the whole frame when it fits) as an RHI texture. The
// QRhiTexture is kept across publications of the same size and format, so an
// edit re-uploads into it instead of allocating a new one.
class FrameTexture final : public QSGTexture {
public:
    ~FrameTexture() override {delete texture_;}
    // `source` is the part of `image` this texture holds, apron included.
    void setSource(const QImage& image,const QRect& source,const Upload& upload) {
        image_=image;source_=source;format_=upload.format;convertTo_=upload.convertTo;
        alpha_=image.hasAlphaChannel();pending_=true;
    }
    qint64 comparisonKey() const override {return qint64(quintptr(this));}
    QRhiTexture* rhiTexture() const override {return texture_;}
    QSize textureSize() const override {return source_.size();}
    bool hasAlphaChannel() const override {return alpha_;}
    bool hasMipmaps() const override {return false;}
    void commitTextureOperations(QRhi* rhi,QRhiResourceUpdateBatch* updates) override {
        if(!pending_)return;
        pending_=false;
        if(!texture_ || texture_->format()!=format_ || texture_->pixelSize()!=source_.size()) {
            delete texture_;
            texture_=rhi->newTexture(format_,source_.size());
            if(!texture_->create()) {
                qWarning("FrameCanvas: cannot create a %dx%d frame texture",source_.width(),source_.height());
                delete texture_;texture_=nullptr;image_={};return;
            }
        }
        QImage pixels=image_;
        QRect region=source_;
        if(convertTo_!=QImage::Format_Invalid) {
            pixels=(source_==image_.rect()?image_:image_.copy(source_)).convertToFormat(convertTo_);
            region=pixels.rect();
        }
        QRhiTextureSubresourceUploadDescription description(pixels);
        if(region!=pixels.rect()) {description.setSourceTopLeft(region.topLeft());description.setSourceSize(region.size());}
        updates->uploadTexture(texture_,QRhiTextureUploadEntry(0,0,description));
        // The update batch holds its own reference until the copy executes.
        image_={};
    }
private:
    QImage image_;
    QRect source_;
    QRhiTexture::Format format_=QRhiTexture::BGRA8;
    QImage::Format convertTo_=QImage::Format_Invalid;
    QRhiTexture* texture_=nullptr;
    bool alpha_=false,pending_=false;
};

// ---- The LUT ---------------------------------------------------------------

// One part of the display LUT as a texture: the table, 3D (N x N x N, blue
// the slice) or as the 2D atlas (N*N x N, slice b at x = b*N), or the 1-D
// curves (M x 2: shaper in row 0, output curve in row 1). Half float: it is
// filterable on every D3D11 device (32-bit float need not be), and its 11
// significant bits put a table node within 1/8 of an 8-bit step. For 4096-
// entry curves, read from a float target (tests/color_canvas.cpp): at most
// 0.11 (WARP) and 0.16 (RTX 3070) of an 8-bit step from exact with half-float
// curves, 0.04 with 32-bit ones -- what is left there is the half-float table.
enum class LutPart {Volume,Atlas,Curves};
class LutTexture final : public QSGTexture {
public:
    LutTexture(std::shared_ptr<const ColorLut> lut,LutPart part,QRhiTexture::Format format)
        :lut_(std::move(lut)),size_(part==LutPart::Curves?lut_->curveSize:lut_->size),part_(part),format_(format) {
        setFiltering(Linear);
    }
    ~LutTexture() override {delete texture_;}
    qint64 comparisonKey() const override {return qint64(quintptr(this));}
    QRhiTexture* rhiTexture() const override {return texture_;}
    QSize textureSize() const override {
        return part_==LutPart::Volume?QSize(size_,size_):part_==LutPart::Atlas?QSize(size_*size_,size_):QSize(size_,2);
    }
    bool hasAlphaChannel() const override {return true;}
    bool hasMipmaps() const override {return false;}
    int size() const {return size_;}
    // Uploads once; every canvas of the window shares the result.
    void commitTextureOperations(QRhi* rhi,QRhiResourceUpdateBatch* updates) override {
        if(!lut_)return;
        const auto lut=std::move(lut_);
        const int n=size_;
        texture_=part_==LutPart::Volume?rhi->newTexture(format_,n,n,n,1,QRhiTexture::ThreeDimensional):
            rhi->newTexture(format_,textureSize());
        if(!texture_->create()) {
            qWarning("FrameCanvas: cannot create a display LUT texture (%d entries)",n);
            delete texture_;texture_=nullptr;return;
        }
        const bool half=format_==QRhiTexture::RGBA16F;
        const qsizetype texel=half?8:16;
        auto store=[half](char* destination,const float* source,qsizetype count) {
            if(half)qFloatToFloat16(reinterpret_cast<qfloat16*>(destination),source,count);
            else std::memcpy(destination,source,size_t(count)*sizeof(float));
        };
        if(part_==LutPart::Curves) {
            QByteArray bytes(qsizetype(n)*2*texel,Qt::Uninitialized);
            store(bytes.data(),lut->shaper.data(),qsizetype(n)*4);
            store(bytes.data()+qsizetype(n)*texel,lut->output.data(),qsizetype(n)*4);
            updates->uploadTexture(texture_,QRhiTextureUploadEntry(0,0,QRhiTextureSubresourceUploadDescription(bytes)));
            return;
        }
        // ColorLut keeps node (r, g, b) at ((b*N + g)*N + r)*4: a row is r,
        // a slice is (r, g) at one b.
        if(part_==LutPart::Atlas) {
            QByteArray bytes(qsizetype(n)*n*n*texel,Qt::Uninitialized);
            for(int g=0;g<n;++g)
                for(int b=0;b<n;++b)
                    store(bytes.data()+(qsizetype(g)*n+b)*n*texel,lut->rgba.data()+(size_t(b)*n+g)*n*4,qsizetype(n)*4);
            updates->uploadTexture(texture_,QRhiTextureUploadEntry(0,0,QRhiTextureSubresourceUploadDescription(bytes)));
        } else {
            std::vector<QRhiTextureUploadEntry> slices;
            slices.reserve(size_t(n));
            for(int b=0;b<n;++b) {
                QByteArray bytes(qsizetype(n)*n*texel,Qt::Uninitialized);
                store(bytes.data(),lut->rgba.data()+size_t(b)*n*n*4,qsizetype(n)*n*4);
                slices.emplace_back(b,0,QRhiTextureSubresourceUploadDescription(bytes));
            }
            QRhiTextureUploadDescription description;
            description.setEntries(slices.cbegin(),slices.cend());
            updates->uploadTexture(texture_,description);
        }
    }
    // The QRhi is being destroyed; its resources must go before it does.
    void releaseRhiResources() {delete texture_;texture_=nullptr;lut_.reset();}
private:
    std::shared_ptr<const ColorLut> lut_;  // until uploaded
    int size_;
    LutPart part_;
    QRhiTexture::Format format_;
    QRhiTexture* texture_=nullptr;
};

// One LUT texture per QRhi (per window: Qt Quick gives each its own) and LUT
// key. Materials hold the strong references; the last canvas to drop a LUT
// frees it. A QRhi cleanup callback releases whatever is still alive when the
// QRhi goes (window closed, scene graph invalidated, device lost).
struct LutEntry {quint64 key;LutPart part;std::weak_ptr<LutTexture> texture;};
std::mutex lutCacheMutex;
std::unordered_map<QRhi*,std::vector<LutEntry>> lutCache;
const char lutCacheCleanupKey=0;

std::shared_ptr<LutTexture> sharedLutTexture(QRhi* rhi,const std::shared_ptr<const ColorLut>& lut,LutPart part) {
    const QRhiTexture::Flags flags=part==LutPart::Volume?QRhiTexture::Flags{QRhiTexture::ThreeDimensional}:QRhiTexture::Flags{};
    const auto preferred=part==LutPart::Curves?curveFormat.load():QRhiTexture::RGBA16F;
    QRhiTexture::Format format=preferred;
    if(!rhi->isTextureFormatSupported(format,flags))format=preferred==QRhiTexture::RGBA16F?QRhiTexture::RGBA32F:QRhiTexture::RGBA16F;
    if(!rhi->isTextureFormatSupported(format,flags))return nullptr;
    const QSize extent=part==LutPart::Volume?QSize(lut->size,lut->size):
        part==LutPart::Atlas?QSize(lut->size*lut->size,lut->size):QSize(lut->curveSize,2);
    // QRhi reports no 3D limit; D3D11's is 2048, far above any table here.
    const int limit=rhi->resourceLimit(QRhi::TextureSizeMax);
    if(extent.width()>limit || extent.height()>limit)return nullptr;
    std::lock_guard lock(lutCacheMutex);
    auto [found,inserted]=lutCache.try_emplace(rhi);
    if(inserted) {
        rhi->addCleanupCallback(&lutCacheCleanupKey,[](QRhi* dying) {
            std::lock_guard lock(lutCacheMutex);
            const auto it=lutCache.find(dying);
            if(it==lutCache.end())return;
            for(auto& entry:it->second)if(auto texture=entry.texture.lock())texture->releaseRhiResources();
            lutCache.erase(it);
        });
    }
    auto& entries=found->second;
    std::erase_if(entries,[](const LutEntry& entry){return entry.texture.expired();});
    for(const auto& entry:entries)
        if(entry.key==lut->key && entry.part==part)
            if(auto texture=entry.texture.lock())return texture;
    auto texture=std::make_shared<LutTexture>(lut,part,format);
    entries.push_back({lut->key,part,texture});
    return texture;
}

// ---- Material ----------------------------------------------------------------

// A tile's material. Every variant but Copy blends (premultiplied) and
// multiplies by the inherited opacity. Copy is the node's opaque material
// under the identity LUT without dither (an 8-bit frame; a deep one when
// dither is off), used at full opacity exactly as Qt's opaque texture
// material was, so today's case renders as before to the bit.
class CanvasMaterial final : public QSGMaterial {
public:
    CanvasMaterial(Variant variant,FrameTexture* frame):variant_(variant),frame_(frame) {
        // A Copy blends only a frame with alpha, as QSGOpaqueTextureMaterial.
        setFlag(Blending,variant!=Copy || frame->hasAlphaChannel());
    }
    QSGMaterialType* type() const override {static QSGMaterialType types[6];return &types[variant_];}
    QSGMaterialShader* createShader(QSGRendererInterface::RenderMode) const override;
    int compare(const QSGMaterial* other) const override {
        const auto* that=static_cast<const CanvasMaterial*>(other);
        auto order=[](auto a,auto b){return a<b?-1:(b<a?1:0);};
        auto key=[](const std::shared_ptr<LutTexture>& t){return t?t->comparisonKey():0;};
        if(int c=order(frame_->comparisonKey(),that->frame_->comparisonKey()))return c;
        if(int c=order(key(lut),key(that->lut)))return c;
        if(int c=order(key(curves),key(that->curves)))return c;
        return order(dither,that->dither);
    }
    Variant variant() const {return variant_;}
    FrameTexture* frame() const {return frame_;}
    std::shared_ptr<LutTexture> lut;       // the table; null without a lookup
    std::shared_ptr<LutTexture> curves;    // the 1-D curves; null without them
    float dither=0;
private:
    Variant variant_;
    FrameTexture* frame_;                  // owned by the tile
};

// The uniform block of shaders/colorcanvas.*, std140.
constexpr int kMatrixOffset=0,kOpacityOffset=64,kParametersOffset=68,kUniformBytes=92;

class CanvasShader final : public QSGMaterialShader {
public:
    explicit CanvasShader(Variant variant) {
        static const char* const names[]={"plain","lut3d","lut2d","copy","lut3d_curves","lut2d_curves"};
        setShaderFileName(VertexStage,QStringLiteral(":/shaders/colorcanvas.vert.qsb"));
        setShaderFileName(FragmentStage,QStringLiteral(":/shaders/colorcanvas_%1.frag.qsb").arg(QLatin1StringView(names[variant])));
    }
    bool updateUniformData(RenderState& state,QSGMaterial* newMaterial,QSGMaterial*) override {
        QByteArray* buffer=state.uniformData();
        if(buffer->size()<kUniformBytes)return false;
        if(state.isMatrixDirty()) {
            const QMatrix4x4 matrix=state.combinedMatrix();
            std::memcpy(buffer->data()+kMatrixOffset,matrix.constData(),64);
        }
        if(state.isOpacityDirty()) {
            const float opacity=state.opacity();
            std::memcpy(buffer->data()+kOpacityOffset,&opacity,4);
        }
        const auto* material=static_cast<CanvasMaterial*>(newMaterial);
        const float n=material->lut?float(material->lut->size()):0.0f;
        const float m=material->curves?float(material->curves->size()):0.0f;
        const float parameters[6]={n>0?(n-1)/n:1.0f,n>0?0.5f/n:0.0f,n,material->dither,
                                   m>0?(m-1)/m:1.0f,m>0?0.5f/m:0.0f};
        std::memcpy(buffer->data()+kParametersOffset,parameters,sizeof parameters);
        return true;
    }
    void updateSampledImage(RenderState& state,int binding,QSGTexture** texture,QSGMaterial* newMaterial,QSGMaterial*) override {
        auto* material=static_cast<CanvasMaterial*>(newMaterial);
        QSGTexture* bound=binding==1?static_cast<QSGTexture*>(material->frame()):
            binding==2?material->lut.get():material->curves.get();
        if(bound)bound->commitTextureOperations(state.rhi(),state.resourceUpdateBatch());
        *texture=bound;
    }
};

QSGMaterialShader* CanvasMaterial::createShader(QSGRendererInterface::RenderMode) const {return new CanvasShader(variant_);}

// [begin, end) source spans of at most `limit` texels including a one-texel
// apron on each inner side: tile i draws [a, b) from a texture holding
// [a - 1, b + 1), so Linear filtering at a seam reads the neighbour's texel
// as it would in one texture. A frame within the limit is one span.
std::vector<std::pair<int,int>> spans(int extent,int limit) {
    std::vector<std::pair<int,int>> result;
    const int step=extent<=limit?extent:limit-2;
    for(int a=0;a<extent;a+=step)result.emplace_back(a,std::min(extent,a+step));
    return result;
}

// ---- CPU path ----------------------------------------------------------------

quint32 wang(quint32 h) {
    h=(h^61u)^(h>>16);h*=9u;h^=h>>4;h*=0x27d4eb2du;h^=h>>15;return h;
}
float triangular(quint32 h) {return (float(h&0xffffu)-float(h>>16))/65536.0f;}

// Trilinear interpolation between the eight nodes around the clamped input:
// what the 3D texture's sampler does at the texel centres the shader uses.
void lookup(const ColorLut& lut,const float in[3],float out[3]) {
    const int n=lut.size;
    int index[3];float fraction[3];
    for(int k=0;k<3;++k) {
        const float position=std::clamp(in[k],0.0f,1.0f)*float(n-1);
        index[k]=std::min(int(position),n-2);fraction[k]=position-float(index[k]);
    }
    auto node=[&](int dr,int dg,int db) {
        return lut.rgba.data()+((size_t(index[2]+db)*n+size_t(index[1]+dg))*n+size_t(index[0]+dr))*4;
    };
    const float *p000=node(0,0,0),*p100=node(1,0,0),*p010=node(0,1,0),*p110=node(1,1,0);
    const float *p001=node(0,0,1),*p101=node(1,0,1),*p011=node(0,1,1),*p111=node(1,1,1);
    const float fr=fraction[0],fg=fraction[1],fb=fraction[2];
    for(int c=0;c<3;++c) {
        const float x00=p000[c]+(p100[c]-p000[c])*fr,x10=p010[c]+(p110[c]-p010[c])*fr;
        const float x01=p001[c]+(p101[c]-p001[c])*fr,x11=p011[c]+(p111[c]-p011[c])*fr;
        const float y0=x00+(x10-x00)*fg,y1=x01+(x11-x01)*fg;
        out[c]=y0+(y1-y0)*fb;
    }
}

// Channel `c` of a 1-D curve at x in [0,1]: linear interpolation between its
// entries, what a linear sampler returns at the shader's texel centres.
float curveAt(const std::vector<float>& curve,int m,float x,int c) {
    const float position=std::clamp(x,0.0f,1.0f)*float(m-1);
    const int i=std::min(int(position),m-2);
    const float a=curve[size_t(i)*4+c],b=curve[size_t(i+1)*4+c];
    return a+(b-a)*(position-float(i));
}

// The display transform of one straight colour, clamped: the table alone, or
// shaper -> table -> output(sqrt) when the LUT has curves (the shader's order).
void transform(const ColorLut& lut,float c[3]) {
    float mapped[3];
    if(lut.hasCurves()) {
        for(int k=0;k<3;++k)c[k]=std::clamp(curveAt(lut.shaper,lut.curveSize,c[k],k),0.0f,1.0f);
        lookup(lut,c,mapped);
        for(int k=0;k<3;++k)
            c[k]=std::clamp(curveAt(lut.output,lut.curveSize,std::sqrt(std::clamp(mapped[k],0.0f,1.0f)),k),0.0f,1.0f);
        return;
    }
    lookup(lut,c,mapped);
    for(int k=0;k<3;++k)c[k]=std::clamp(mapped[k],0.0f,1.0f);
}

// Rows split over the machine's cores: a 24 MP frame is ~24M lookups, and the
// software backend converts it on every publication.
template<class Function> void forRows(int height,qsizetype pixels,Function rows) {
    const unsigned cores=std::min(16u,std::max(1u,std::thread::hardware_concurrency()));
    if(cores<2 || pixels<(qsizetype(1)<<18)) {rows(0,height);return;}
    const int chunk=int((unsigned(height)+cores-1)/cores);
    std::vector<std::thread> workers;
    for(int start=chunk;start<height;start+=chunk)workers.emplace_back(rows,start,std::min(height,start+chunk));
    rows(0,std::min(height,chunk));
    for(auto& worker:workers)worker.join();
}
}

bool displayLutActive(const ColorLut& lut) {
    const bool table=lut.size>=2 && lut.rgba.size()==size_t(lut.size)*size_t(lut.size)*size_t(lut.size)*4;
    // Malformed curves void the whole LUT: its table expects the shaper's
    // output, so applying it to encoded values would be wrong, not just coarse.
    const bool curves=lut.curveSize==0 || (lut.curveSize>=2 && lut.shaper.size()==size_t(lut.curveSize)*4 &&
                                           lut.output.size()==size_t(lut.curveSize)*4);
    return table && curves;
}

QImage applyDisplayLutCpu(const QImage& image,const ColorLut& lut,bool dither) {
    if(image.isNull())return image;
    const bool active=displayLutActive(lut);
    const auto format=image.format();
    const bool eightBit=format==QImage::Format_RGB32 || format==QImage::Format_ARGB32 ||
        format==QImage::Format_ARGB32_Premultiplied;
    if(!active && eightBit)return image;
    const bool deep=isDeep(image),alpha=image.hasAlphaChannel();
    const QImage source=eightBit || isHalfFloat(format)?image:image.convertToFormat(
        deep?(alpha?QImage::Format_RGBA16FPx4:QImage::Format_RGBX16FPx4):(alpha?QImage::Format_ARGB32:QImage::Format_RGB32));
    QImage output(image.size(),alpha?QImage::Format_ARGB32_Premultiplied:QImage::Format_RGB32);
    if(source.isNull() || output.isNull())return {};
    const bool half=isHalfFloat(source.format());
    const bool premultiplied=source.format()==QImage::Format_ARGB32_Premultiplied ||
        source.format()==QImage::Format_RGBA16FPx4_Premultiplied;
    // As in the shader: dither only where it can matter, never on an 8-bit
    // frame under the identity LUT (that path is the image itself, above).
    const float amplitude=dither && (active || deep)?1.0f/255.0f:0.0f;
    // qRound of the clamped value is what QImage::pixel() does for a half-
    // float image, so the identity path agrees with it to the bit.
    auto quantize=[](float v){return qRound(std::clamp(v,0.0f,1.0f)*255.0f);};
    const int width=source.width();
    forRows(source.height(),qsizetype(width)*source.height(),[&](int first,int last) {
        for(int y=first;y<last;++y) {
            auto* out=reinterpret_cast<QRgb*>(output.scanLine(y));
            for(int x=0;x<width;++x) {
                float c[4];
                if(half) {
                    const auto p=reinterpret_cast<const QRgbaFloat16*>(source.constScanLine(y))[x];
                    c[0]=p.red();c[1]=p.green();c[2]=p.blue();c[3]=p.alpha();
                } else {
                    const QRgb p=reinterpret_cast<const QRgb*>(source.constScanLine(y))[x];
                    c[0]=qRed(p)/255.0f;c[1]=qGreen(p)/255.0f;c[2]=qBlue(p)/255.0f;c[3]=qAlpha(p)/255.0f;
                }
                if(premultiplied) {
                    if(c[3]>0){c[0]/=c[3];c[1]/=c[3];c[2]/=c[3];}else c[0]=c[1]=c[2]=0;
                }
                for(int k=0;k<3;++k)c[k]=std::clamp(c[k],0.0f,1.0f);
                if(active)transform(lut,c);
                if(amplitude>0) {
                    const quint32 hr=wang(quint32(x)^wang(quint32(y))),hg=wang(hr),hb=wang(hg);
                    c[0]+=triangular(hr)*amplitude;c[1]+=triangular(hg)*amplitude;c[2]+=triangular(hb)*amplitude;
                }
                const QRgb straight=qRgba(quantize(c[0]),quantize(c[1]),quantize(c[2]),quantize(c[3]));
                out[x]=alpha?qPremultiply(straight):(straight|0xff000000u);
            }
        }
    });
    return output;
}

struct ColorCanvasNode::Tile {
    QSGGeometryNode* node=nullptr;   // a child of the canvas node, which deletes it
    std::unique_ptr<FrameTexture> texture=std::make_unique<FrameTexture>();
    QRect interior,source;           // source pixels drawn / held (with apron)
    QRectF rect,textureRect;         // what the geometry holds now
};

ColorCanvasNode::ColorCanvasNode()=default;
ColorCanvasNode::~ColorCanvasNode() {clear();}

void ColorCanvasNode::clear() {
    // Children first: a material refers to its tile's texture.
    for(auto& tile:tiles_)delete tile->node;
    tiles_.clear();
    delete software_;software_=nullptr;
}

bool ColorCanvasNode::update(QQuickWindow* window,const CanvasPaint& paint) {
    return window->rhi()?updateRhi(window,paint):updateSoftware(window,paint);
}

bool ColorCanvasNode::updateRhi(QQuickWindow* window,const CanvasPaint& paint) {
    QRhi* rhi=window->rhi();
    if(software_){delete software_;software_=nullptr;}
    int limit=rhi->resourceLimit(QRhi::TextureSizeMax);
    if(const int cap=maxTextureSizeForTesting.load();cap>0)limit=std::min(limit,cap);
    limit=std::max(limit,3);  // one interior texel and its two apron texels
    if(tiles_.empty() || paint.revision!=revision_ || limit!=tileLimit_) {
        if(paint.image.isNull())return false;
        const Upload upload=uploadable(rhi,paint.image);
        const QSize size=paint.image.size();
        const bool alpha=paint.image.hasAlphaChannel();
        const auto columns=spans(size.width(),limit),rows=spans(size.height(),limit);
        const size_t count=columns.size()*rows.size();
        if(tiles_.size()!=count) {
            for(auto& tile:tiles_)delete tile->node;
            tiles_.clear();
            for(size_t i=0;i<count;++i) {
                auto tile=std::make_unique<Tile>();
                tile->node=new QSGGeometryNode;
                tile->node->setGeometry(new QSGGeometry(QSGGeometry::defaultAttributes_TexturedPoint2D(),4));
                // A geometry node in a live tree must always have a material:
                // the renderer reads its flags on every change notification.
                tile->node->setMaterial(new CanvasMaterial(NoLut,tile->texture.get()));
                tile->node->setFlags(QSGNode::OwnsGeometry|QSGNode::OwnsMaterial|QSGNode::OwnsOpaqueMaterial);
                appendChildNode(tile->node);
                tiles_.push_back(std::move(tile));
            }
        }
        size_t i=0;
        for(const auto& [top,bottom]:rows)
            for(const auto& [left,right]:columns) {
                auto& tile=*tiles_[i++];
                tile.interior=QRect(QPoint(left,top),QPoint(right-1,bottom-1));
                tile.source=QRect(QPoint(std::max(0,left-1),std::max(0,top-1)),
                    QPoint(std::min(size.width(),right+1)-1,std::min(size.height(),bottom+1)-1));
                tile.texture->setSource(paint.image,tile.source,upload);
                tile.textureRect={};  // re-derive the texture coordinates below
                // The Copy material's blending follows the frame's alpha.
                if(alpha!=alpha_)tile.node->setOpaqueMaterial(nullptr);
                tile.node->markDirty(QSGNode::DirtyMaterial);
            }
        revision_=paint.revision;tileLimit_=limit;deep_=upload.deep;alpha_=alpha;imageSize_=size;
    }

    Variant mode=NoLut;
    std::shared_ptr<LutTexture> lut,curves;
    if(displayLutActive(*paint.lut)) {
        const bool atlas=forceLutAtlasForTesting.load() || !rhi->isFeatureSupported(QRhi::ThreeDimensionalTextures);
        lut=sharedLutTexture(rhi,paint.lut,atlas?LutPart::Atlas:LutPart::Volume);
        if(paint.lut->hasCurves())curves=sharedLutTexture(rhi,paint.lut,LutPart::Curves);
        if(lut && (curves || !paint.lut->hasCurves()))
            mode=curves?(atlas?AtlasCurves:VolumeCurves):(atlas?AtlasLut:VolumeLut);
        else {
            lut.reset();curves.reset();
            static std::once_flag warned;
            std::call_once(warned,[]{qWarning("FrameCanvas: the display LUT cannot be a texture here; drawing without display colour management");});
        }
    }
    // One output step of triangular dither before the 8-bit swap chain
    // quantises: wherever the LUT runs, and for a deep frame even under the
    // identity (its extra bits would otherwise band). Never for an 8-bit
    // frame under the identity, which must stay bit-exact.
    const float dither=paint.dither && (mode!=NoLut || deep_)?1.0f/255.0f:0.0f;
    const auto filtering=paint.smooth?QSGTexture::Linear:QSGTexture::Nearest;
    const double scaleX=paint.rect.width()/imageSize_.width(),scaleY=paint.rect.height()/imageSize_.height();
    // At full opacity, the identity without dither is drawn by a bare texture
    // read, the shader Qt's own texture node used. Measured on WARP with the
    // test's frame reduced to 34 %: any arithmetic after the read (even
    // "* qt_Opacity") moved 86 % of its pixels by one count against Qt's node;
    // on an RTX 3070 the arithmetic version matched it exactly.
    const bool copy=mode==NoLut && dither==0;
    for(auto& tile:tiles_) {
        auto* material=static_cast<CanvasMaterial*>(tile->node->material());
        if(material->variant()!=mode) {
            material=new CanvasMaterial(mode,tile->texture.get());
            tile->node->setMaterial(material);  // deletes the previous one (OwnsMaterial)
        }
        if(material->lut!=lut || material->curves!=curves || material->dither!=dither) {
            material->lut=lut;material->curves=curves;material->dither=dither;
            tile->node->markDirty(QSGNode::DirtyMaterial);
        }
        if(copy!=(tile->node->opaqueMaterial()!=nullptr))
            tile->node->setOpaqueMaterial(copy?new CanvasMaterial(Copy,tile->texture.get()):nullptr);
        if(tile->texture->filtering()!=filtering) {
            tile->texture->setFiltering(filtering);
            tile->node->markDirty(QSGNode::DirtyMaterial);
        }
        // Edges from the same expression on both sides of a seam, so the
        // rasteriser's fill rule gives every pixel to exactly one tile.
        const auto& in=tile->interior;
        const QRectF rect(QPointF(paint.rect.x()+in.left()*scaleX,paint.rect.y()+in.top()*scaleY),
                          QPointF(paint.rect.x()+(in.right()+1)*scaleX,paint.rect.y()+(in.bottom()+1)*scaleY));
        const auto& src=tile->source;
        const QRectF textureRect(double(in.left()-src.left())/src.width(),double(in.top()-src.top())/src.height(),
                                 double(in.width())/src.width(),double(in.height())/src.height());
        if(rect!=tile->rect || textureRect!=tile->textureRect) {
            QSGGeometry::updateTexturedRectGeometry(tile->node->geometry(),rect,textureRect);
            tile->node->markDirty(QSGNode::DirtyGeometry);
            tile->rect=rect;tile->textureRect=textureRect;
        }
    }
    lastTileCountForTesting=int(tiles_.size());
    return true;
}

bool ColorCanvasNode::updateSoftware(QQuickWindow* window,const CanvasPaint& paint) {
    if(!tiles_.empty()) {
        for(auto& tile:tiles_)delete tile->node;
        tiles_.clear();
    }
    const bool active=displayLutActive(*paint.lut);
    const quint64 lut=active?paint.lut->key:0;
    if(!software_ || paint.revision!=revision_ || active!=softwareLutActive_ || lut!=softwareLut_ ||
       paint.dither!=softwareDither_) {
        auto* texture=window->createTextureFromImage(applyDisplayLutCpu(paint.image,*paint.lut,paint.dither));
        if(!texture)return false;
        if(!software_){software_=new QSGSimpleTextureNode;appendChildNode(software_);}
        software_->setTexture(texture);software_->setOwnsTexture(true);
        revision_=paint.revision;softwareLutActive_=active;softwareLut_=lut;softwareDither_=paint.dither;
    }
    software_->setFiltering(paint.smooth?QSGTexture::Linear:QSGTexture::Nearest);
    software_->setRect(paint.rect);
    lastTileCountForTesting=0;
    return true;
}

namespace canvas_testing {
void setMaxTextureSize(int pixels) {maxTextureSizeForTesting=pixels;}
void setForceLutAtlas(bool force) {forceLutAtlasForTesting=force;}
void setCurvesFloat32(bool float32) {curveFormat=float32?QRhiTexture::RGBA32F:QRhiTexture::RGBA16F;}
int lastTileCount() {return lastTileCountForTesting.load();}
}
