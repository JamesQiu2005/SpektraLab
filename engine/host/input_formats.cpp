#include "input_formats.hpp"
#include "platform.hpp"
#include "tiff_ifd.hpp"
#include <OpenEXR/ImfInputFile.h>
#include <OpenEXR/ImfHeader.h>
#include <OpenEXR/ImfFrameBuffer.h>
#include <OpenEXR/ImfChannelList.h>
#include <OpenEXR/ImfStandardAttributes.h>
#include <OpenEXR/ImfThreading.h>
#include <OpenEXR/ImfPartType.h>
#include <libheif/heif.h>
#include <lcms2.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>

namespace spkhost {
namespace {
using Profile = std::unique_ptr<void, decltype(&cmsCloseProfile)>;
using Context = std::unique_ptr<std::remove_pointer_t<cmsContext>, decltype(&cmsDeleteContext)>;
using Transform = std::unique_ptr<void, decltype(&cmsDeleteTransform)>;
using Curve = std::unique_ptr<cmsToneCurve, decltype(&cmsFreeToneCurve)>;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void check(heif_error e) { if(e.code != heif_error_Ok) throw std::runtime_error(std::string("HEIC: ")+e.message); }
void dimensions(int64_t w,int64_t h) {
    require(w>0 && h>0 && w<=65536 && h<=65536 && uint64_t(w)*h<=200000000,"input dimensions exceed the supported flat-image limit");
}
Profile profile(cmsContext ctx, const cmsCIExyY& white,const cmsCIExyYTRIPLE& primaries) {
    Curve gamma(cmsBuildGamma(ctx,1),cmsFreeToneCurve);
    require(bool(gamma),"cannot allocate colour curve");
    cmsToneCurve* curves[]={gamma.get(),gamma.get(),gamma.get()};
    Profile p(cmsCreateRGBProfileTHR(ctx,&white,&primaries,curves),cmsCloseProfile);
    require(bool(p),"invalid image chromaticities"); return p;
}
Profile prophoto(cmsContext ctx) {
    const cmsCIExyY white={.3457,.3585,1};
    const cmsCIExyYTRIPLE primaries={{.7347,.2653,1},{.1596,.8404,1},{.0366,.0001,1}};
    return profile(ctx,white,primaries);
}
RgbSpace linear_space(const cmsCIExyY& white,const cmsCIExyYTRIPLE& primaries) {
    auto p=profile(nullptr,white,primaries);
    RgbSpace result;
    // LittleCMS ICC PCS uses (0.9642, 1, 0.8249), while the engine's
    // ProPhoto matrix uses (0.96422, 1, 0.82521). Chromaticities are not an
    // embedded ICC profile: adapt to the engine's white explicitly instead
    // of introducing a blue-channel bias by mixing the two D50 conventions.
    const auto working=linear_prophoto_space().to_xyz_d50;
    const cmsCIEXYZ destination_white={working[0]+working[1]+working[2],
        working[3]+working[4]+working[5],working[6]+working[7]+working[8]};
    const cmsTagSignature tags[]={cmsSigRedColorantTag,cmsSigGreenColorantTag,cmsSigBlueColorantTag};
    for(int c=0;c<3;++c) {
        const auto* xyz=static_cast<const cmsCIEXYZ*>(cmsReadTag(p.get(),tags[c]));
        require(xyz,"missing colour matrix");
        cmsCIEXYZ adapted{};
        require(cmsAdaptToIlluminant(&adapted,cmsD50_XYZ(),&destination_white,xyz),"invalid image white point");
        result.to_xyz_d50[c]=adapted.X; result.to_xyz_d50[3+c]=adapted.Y; result.to_xyz_d50[6+c]=adapted.Z;
    }
    result.description="embedded linear chromaticities"; return result;
}

void exr(const std::filesystem::path& path,FloatImage* out,Probe& probe) {
    Imf::setGlobalThreadCount(int(std::min(8u,hardware_threads())));
    Imf::InputFile file(path_utf8(path).c_str());
    const auto& header=file.header();
    require(!header.hasType() || !Imf::isDeepData(header.type()),"deep EXR input is not a flat photograph");
    const auto& window=header.dataWindow();
    const int64_t w=int64_t(window.max.x)-window.min.x+1,h=int64_t(window.max.y)-window.min.y+1;
    dimensions(w,h);
    probe.kind=FileKind::Exr;probe.width=uint32_t(w);probe.height=uint32_t(h);probe.metadata.orientation=1;
    const auto& channels=header.channels();
    const bool rgb=channels.findChannel("R")&&channels.findChannel("G")&&channels.findChannel("B");
    const bool mono=channels.findChannel("Y")&&!channels.findChannel("RY")&&!channels.findChannel("BY");
    require(rgb||mono,"EXR requires RGB or monochrome Y channels");
    if(!out)return;
    FloatImage next;next.width=uint32_t(w);next.height=uint32_t(h);next.rgb.resize(size_t(w)*h*3);
    Imf::FrameBuffer fb;
    for(int c=0;c<(rgb?3:1);++c) {
        const char* name=rgb?(c==0?"R":c==1?"G":"B"):"Y";
        const auto* channel=channels.findChannel(name);
        require(channel->xSampling==1&&channel->ySampling==1,"subsampled EXR channels are unsupported");
        fb.insert(name,Imf::Slice::Make(Imf::FLOAT,next.rgb.data()+c,window,3*sizeof(float),size_t(w)*3*sizeof(float)));
    }
    file.setFrameBuffer(fb);file.readPixels(window.min.y,window.max.y);
    if(!rgb)for(size_t i=0;i<next.rgb.size();i+=3)next.rgb[i+1]=next.rgb[i+2]=next.rgb[i];
    for(float v:next.rgb)require(std::isfinite(v),"EXR contains NaN or infinite image values");
    // OpenEXR's defined default primaries are Rec.709/D65; explicit chromaticities
    // (including ACES) take precedence. Negative and >1 float values stay intact.
    const Imf::Chromaticities c=Imf::hasChromaticities(header)?Imf::chromaticities(header):Imf::Chromaticities();
    const cmsCIExyY white={c.white.x,c.white.y,1};
    const cmsCIExyYTRIPLE primaries={{c.red.x,c.red.y,1},{c.green.x,c.green.y,1},{c.blue.x,c.blue.y,1}};
    to_linear_prophoto(linear_space(white,primaries),next.rgb);*out=std::move(next);
}

struct HeifFile {
    std::FILE* file=nullptr;int64_t size=0;
    explicit HeifFile(const std::filesystem::path& path) {
        file=open_file(path,"rb");require(file,"HEIC cannot open file");
        std::error_code ec;auto bytes=std::filesystem::file_size(path,ec);
        if(ec||bytes>uint64_t(INT64_MAX)){std::fclose(file);file=nullptr;throw std::runtime_error("HEIC invalid file size");}
        size=int64_t(bytes);
    }
    ~HeifFile(){if(file)std::fclose(file);}
    static int64_t tell(void* p) {
#ifdef _WIN32
        return _ftelli64(static_cast<HeifFile*>(p)->file);
#else
        return ftello(static_cast<HeifFile*>(p)->file);
#endif
    }
    static int read(void* dst,size_t n,void* p){return std::fread(dst,1,n,static_cast<HeifFile*>(p)->file)==n?0:1;}
    static int seek(int64_t at,void* p) {
        auto* f=static_cast<HeifFile*>(p);if(at<0||at>f->size)return 1;
#ifdef _WIN32
        return _fseeki64(f->file,at,SEEK_SET);
#else
        return fseeko(f->file,at,SEEK_SET);
#endif
    }
    static heif_reader_grow_status wait(int64_t n,void* p){return n>=0&&n<=static_cast<HeifFile*>(p)->size?heif_reader_grow_status_size_reached:heif_reader_grow_status_size_beyond_eof;}
};

double inverse_transfer(double v,int transfer) {
    switch(transfer) {
        case 2: case 13: return v<=.04045?v/12.92:std::pow((v+.055)/1.055,2.4);
        case 1: case 6: case 14: return v<.081?v/4.5:std::pow((v+.099)/1.099,1/.45);
        case 15: return v<.08145?v/4.5:std::pow((v+.0993)/1.0993,1/.45);
        case 4: return std::pow(v,2.2);
        case 5: return std::pow(v,2.8);
        case 8: return v;
        default: throw std::runtime_error("unsupported HEIC transfer function; HDR PQ/HLG input is not yet calibrated for this SDR workflow");
    }
}
void heic(const std::filesystem::path& path,FloatImage* out,Probe& probe) {
    HeifFile file(path);
    std::unique_ptr<heif_context,decltype(&heif_context_free)> ctx(heif_context_alloc(),heif_context_free);
    require(bool(ctx),"HEIC context allocation failed");
    heif_context_set_max_decoding_threads(ctx.get(),1);
    auto* limits=heif_context_get_security_limits(ctx.get());
    limits->max_image_size_pixels=200000000;limits->max_color_profile_size=16*1024*1024;
    heif_reader reader{};reader.reader_api_version=1;reader.get_position=HeifFile::tell;reader.read=HeifFile::read;reader.seek=HeifFile::seek;reader.wait_for_file_size=HeifFile::wait;
    check(heif_context_read_from_reader(ctx.get(),&reader,&file,nullptr));
    heif_image_handle* raw_handle=nullptr;check(heif_context_get_primary_image_handle(ctx.get(),&raw_handle));
    std::unique_ptr<heif_image_handle,decltype(&heif_image_handle_release)> handle(raw_handle,heif_image_handle_release);
    const int w=heif_image_handle_get_width(handle.get()),h=heif_image_handle_get_height(handle.get());
    dimensions(w,h);probe.kind=FileKind::Heic;probe.width=uint32_t(w);probe.height=uint32_t(h);
    // Container rotation/crop/mirror is applied by libheif, once. EXIF orientation
    // is informational here and must not rotate the decoded result a second time.
    heif_item_id exif_id=0;
    if(heif_image_handle_get_list_of_metadata_block_IDs(handle.get(),"Exif",&exif_id,1)>0) {
        size_t n=heif_image_handle_get_metadata_size(handle.get(),exif_id);
        if(n>=4&&n<=16*1024*1024) {
            std::vector<uint8_t> bytes(n);check(heif_image_handle_get_metadata(handle.get(),exif_id,bytes.data()));
            size_t start=4+(uint32_t(bytes[0])<<24|uint32_t(bytes[1])<<16|uint32_t(bytes[2])<<8|bytes[3]);
            if(start<n){TiffBytes t(bytes.data()+start,n-start);uint32_t ifd=0;if(t.header(ifd))read_exif_metadata(t,ifd,probe.metadata);}
        }
    }
    probe.metadata.orientation=1;
    if(!out)return;
    std::unique_ptr<heif_decoding_options,decltype(&heif_decoding_options_free)> opts(heif_decoding_options_alloc(),heif_decoding_options_free);
    require(bool(opts),"HEIC options allocation failed");
    opts->output_image_nclx_profile_passthrough=1;opts->num_codec_threads=int(std::min(8u,hardware_threads()));
    const int requested=heif_image_handle_get_luma_bits_per_pixel(handle.get());
    require(requested>0&&requested<=16,"HEIC unsupported bit depth");
    const auto chroma=requested>8?heif_chroma_interleaved_RRGGBBAA_LE:heif_chroma_interleaved_RGBA;
    heif_image* raw_image=nullptr;check(heif_decode_image(handle.get(),&raw_image,heif_colorspace_RGB,chroma,opts.get()));
    std::unique_ptr<heif_image,decltype(&heif_image_release)> image(raw_image,heif_image_release);
    const int bits=heif_image_get_bits_per_pixel_range(image.get(),heif_channel_interleaved);
    const int iw=heif_image_get_width(image.get(),heif_channel_interleaved),ih=heif_image_get_height(image.get(),heif_channel_interleaved);
    dimensions(iw,ih);require(bits>0&&bits<=16,"HEIC invalid decoded bit depth");
    int stride=0;const uint8_t* pixels=heif_image_get_plane_readonly(image.get(),heif_channel_interleaved,&stride);
    require(pixels&&stride>=iw*4*(requested>8?2:1),"HEIC invalid RGB plane");
    FloatImage next;next.width=uint32_t(iw);next.height=uint32_t(ih);next.rgb.resize(size_t(iw)*ih*3);
    const bool premult=heif_image_is_premultiplied_alpha(image.get())!=0;
    const double max=double((1u<<bits)-1);
    auto sample=[&](int x,int y,int c){const uint8_t* p=pixels+size_t(y)*stride+size_t(x)*4*(requested>8?2:1)+c*(requested>8?2:1);return (requested>8?double(uint16_t(p[0])|uint16_t(p[1])<<8):double(*p))/max;};
    for(int y=0;y<ih;++y)for(int x=0;x<iw;++x) {
        const double a=sample(x,y,3);
        for(int c=0;c<3;++c)next.rgb[(size_t(y)*iw+x)*3+c]=float(premult?(a>0?sample(x,y,c)/a:0):sample(x,y,c));
    }
    size_t profile_size=heif_image_get_raw_color_profile_size(image.get());
    if(!profile_size)profile_size=heif_image_handle_get_raw_color_profile_size(handle.get());
    if(profile_size) {
        require(profile_size<=16*1024*1024,"HEIC ICC profile too large");
        std::vector<uint8_t> icc(profile_size);
        if(heif_image_get_raw_color_profile_size(image.get()))check(heif_image_get_raw_color_profile(image.get(),icc.data()));
        else check(heif_image_handle_get_raw_color_profile(handle.get(),icc.data()));
        std::string error;if(!icc_to_linear_prophoto(icc,next.rgb,0,error))throw std::runtime_error(error);
    } else {
        heif_color_profile_nclx* raw_nclx=nullptr;
        auto status=heif_image_get_nclx_color_profile(image.get(),&raw_nclx);
        std::unique_ptr<heif_color_profile_nclx,decltype(&heif_nclx_color_profile_free)> nclx(raw_nclx,heif_nclx_color_profile_free);
        if(status.code==heif_error_Color_profile_does_not_exist)to_linear_prophoto(srgb_space(),next.rgb);
        else {
            check(status);require(bool(nclx),"HEIC missing NCLX data");
            const auto& n=*nclx;
            RgbSpace space;
            if(n.color_primaries==heif_color_primaries_unspecified){space=srgb_space();for(auto& t:space.trc){t.kind=Trc::Kind::Gamma;t.gamma=1;}}
            else space=linear_space({n.color_primary_white_x,n.color_primary_white_y,1},{{n.color_primary_red_x,n.color_primary_red_y,1},{n.color_primary_green_x,n.color_primary_green_y,1},{n.color_primary_blue_x,n.color_primary_blue_y,1}});
            for(float& v:next.rgb)v=float(inverse_transfer(v,int(n.transfer_characteristics)));
            to_linear_prophoto(space,next.rgb);
        }
    }
    for(int y=0;y<ih;++y)for(int x=0;x<iw;++x)for(int c=0;c<3;++c)next.rgb[(size_t(y)*iw+x)*3+c]*=float(sample(x,y,3));
    probe.width=next.width;probe.height=next.height;*out=std::move(next);
}
}

bool icc_to_linear_prophoto(const std::vector<uint8_t>& bytes,std::vector<float>& rgb,uint32_t codes,std::string& error) {
    try {
        require(!bytes.empty()&&bytes.size()<=16*1024*1024,"ICC profile is empty or too large");
        Context ctx(cmsCreateContext(nullptr,nullptr),cmsDeleteContext);require(bool(ctx),"ICC context allocation failed");
        Profile input(cmsOpenProfileFromMemTHR(ctx.get(),bytes.data(),cmsUInt32Number(bytes.size())),cmsCloseProfile);
        require(bool(input)&&cmsGetColorSpace(input.get())==cmsSigRgbData,"unsupported or invalid RGB ICC profile");
        auto output=prophoto(ctx.get());
        Transform transform(cmsCreateTransformTHR(ctx.get(),input.get(),TYPE_RGB_FLT,output.get(),TYPE_RGB_FLT,
            INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE),cmsDeleteTransform);
        require(bool(transform),"cannot evaluate embedded RGB ICC profile");
        if(codes)for(float& v:rgb)v/=float(codes-1);
        for(size_t at=0;at<rgb.size()/3;) {
            const auto count=cmsUInt32Number(std::min<size_t>(65536,rgb.size()/3-at));
            cmsDoTransform(transform.get(),rgb.data()+at*3,rgb.data()+at*3,count);at+=count;
        }
        for(float v:rgb)require(std::isfinite(v),"ICC conversion produced non-finite values");
        return true;
    } catch(const std::exception& e){error=std::string("input ICC: ")+e.what();return false;}
}
bool probe_extra(const std::filesystem::path& path,FileKind kind,Probe& out,std::string& error) {
    try {Probe next;if(kind==FileKind::Heic)heic(path,nullptr,next);else exr(path,nullptr,next);out=std::move(next);return true;}
    catch(const std::exception& e){error=e.what();return false;}
}
bool decode_extra(const std::filesystem::path& path,FileKind kind,FloatImage& out,Probe& probe,std::string& error) {
    try {FloatImage next;Probe info;if(kind==FileKind::Heic)heic(path,&next,info);else exr(path,&next,info);out=std::move(next);probe=std::move(info);return true;}
    catch(const std::exception& e){error=e.what();return false;}
}
}
