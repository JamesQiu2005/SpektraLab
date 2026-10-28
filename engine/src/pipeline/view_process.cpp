#include "view_process.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <stdexcept>

namespace spk::view {
namespace {
using Clock = std::chrono::steady_clock;
using gpu::Arg;
double ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
double number(const Json& o, const char* key, double fallback, double lo, double hi) {
    const auto& v=o.at(key);
    if(v.is_null()) return fallback;
    if(!v.is_number() || !std::isfinite(v.as_double()) || v.as_double()<lo || v.as_double()>hi)
        throw std::runtime_error(std::string("view: invalid ")+key);
    return v.as_double();
}
std::vector<std::array<double,2>> points(const Json& j) {
    if(j.is_null()) return {{0,0},{1,1}};
    const auto& a=j.at("points");
    if(!a.is_array() || a.items().size()<2 || a.items().size()>256) throw std::runtime_error("view: invalid curve points");
    std::vector<std::array<double,2>> p;
    for(const auto& q:a.items()) {
        if(!q.is_array()||q.items().size()!=2)throw std::runtime_error("view: invalid curve point");
        double x=q.items()[0].as_double(-1),y=q.items()[1].as_double(-1);
        if(!std::isfinite(x)||!std::isfinite(y)||x<0||x>1||y<0||y>1||(!p.empty()&&x<=p.back()[0]))
            throw std::runtime_error("view: curve points must increase within 0..1");
        p.push_back({x,y});
    }
    return p;
}
// Fritsch-Carlson, shared behaviour with CurveMath.swift/adjustments.ts.
double curve(const std::vector<std::array<double,2>>& p,double x) {
    size_t n=p.size(); if(x<=p.front()[0])return p.front()[1]; if(x>=p.back()[0])return p.back()[1];
    std::vector<double> d(n-1),m(n);
    for(size_t i=0;i+1<n;++i)d[i]=(p[i+1][1]-p[i][1])/std::max(p[i+1][0]-p[i][0],1e-6);
    m[0]=d[0];m[n-1]=d[n-2];
    for(size_t i=1;i+1<n;++i)m[i]=d[i-1]*d[i]<=0?0:(d[i-1]+d[i])/2;
    for(size_t i=0;i+1<n;++i)if(d[i]!=0){double a=m[i]/d[i],b=m[i+1]/d[i],s=a*a+b*b;if(s>9){double t=3/std::sqrt(s);m[i]=t*a*d[i];m[i+1]=t*b*d[i];}}
    size_t i=0;while(i<n-2&&x>p[i+1][0])++i;
    double h=std::max(p[i+1][0]-p[i][0],1e-6),t=(x-p[i][0])/h,t2=t*t,t3=t2*t;
    return std::clamp((2*t3-3*t2+1)*p[i][1]+(t3-2*t2+t)*h*m[i]+(-2*t3+3*t2)*p[i+1][1]+(t3-t2)*h*m[i+1],0.0,1.0);
}
Image allocate(gpu::Gpu* gpu,uint32_t w,uint32_t h,std::string& error) {
    Image out;out.w=w;out.h=h;out.c=3;out.buf=gpu->alloc(out.bytes(),error);return out;
}
bool resample(gpu::Gpu* gpu,Image& current,uint32_t w,uint32_t h,const float* geo,uint32_t turns,uint32_t flips,std::string& error) {
    Image next=allocate(gpu,w,h,error);if(!next.valid())return false;
    uint32_t meta[]={current.w,current.h,w,h,turns,flips};
    if(!gpu->dispatch("spk_view_geometry",{Arg::buf(current.buf),Arg::inline_bytes(geo,7),Arg::inline_bytes(meta,6),Arg::buf(next.buf)},next.pixels(),error)||!gpu->flush(error))return false;
    current=std::move(next);return true;
}
std::vector<float> floats(const Json& j,size_t n) {
    if(!j.is_array()||j.items().size()!=n)throw std::runtime_error("view: invalid output transform table");
    std::vector<float> v;v.reserve(n);for(const auto& x:j.items())v.push_back(float(x.as_double()));return v;
}
}

bool process(gpu::Gpu* gpu,const Image& print,const Request& req,const Json& transform,
             const float* cmax,uint32_t cmax_count,Result& result,std::string& error,
             const gpu::BufferRef& di_lut,uint32_t di_lut_size,Image* device_output) {
    const auto started=Clock::now();
    try {
        if(!print.valid()||print.c!=2){error="view: expected device RGBA16 print";return false;}
        if(req.output_channels!=3&&req.output_channels!=4){error="view: output_channels must be 3 or 4";return false;}
        if(device_output&&(!req.rgba16||req.output_channels!=4||req.proof_long_edge)){error="view: device output requires RGBA16";return false;}
        if(!req.adjustments.is_object()||!req.geometry.is_object()){error="view: adjustments and geometry must be objects";return false;}
        const Json& a=req.adjustments;std::array<float,32> u{};
        u[0]=a.at("enabled").as_bool(true)?1.f:0.f;
        double t=number(a,"temperature",0,-100,100)/100,g=number(a,"tint",0,-100,100)/100;
        u[1]=float(1+.18*t);u[2]=float(1-.12*g);u[3]=float(1-.18*t);
        u[4]=float(std::pow(2.,number(a,"exposure",0,-20,20)));
        const char* scalars[]={"contrast","brightness","saturation","highlights","shadows","blackPoint","whitePoint"};
        for(size_t i=0;i<7;++i)u[5+i]=float(number(a,scalars[i],0,-100,100)/100);
        u[7]+=1;u[12]=.3857f;
        u[13]=float(number(a.at("vignette"),"amount",0,-100,100)/100);
        u[14]=float(number(a.at("vignette"),"midpoint",50,0,100)/100);
        const char* zones[]={"master","shadows","midtones","highlights"};
        constexpr double pi=3.14159265358979323846;
        for(size_t z=0;z<4;++z){const Json& q=a.at("colorBalance").at(zones[z]);double hue=number(q,"hue",0,-360,360)*pi/180,s=number(q,"saturation",0,-1,1)*.25;
            for(size_t c=0;c<3;++c)u[16+z*3+c]=float(std::cos(hue-2*pi*c/3)*s);
            u[28+z]=float(number(q,"luminance",0,-1,1)*.25);
        }
        std::array<float,1280> table{};const char* channels[]={"rgb","luma","red","green","blue"};
        for(size_t row=0;row<5;++row){auto p=points(a.at("curves").at(channels[row]));
            if(p.size()!=2||p[0]!=std::array<double,2>{0,0}||p[1]!=std::array<double,2>{1,1})u[15]=1;
            for(size_t x=0;x<256;++x)table[row*256+x]=float(curve(p,double(x)/255));
        }
        const Json& geom=req.geometry;const Json& crop=geom.at("crop");
        double x=number(crop,"x",0,0,1),y=number(crop,"y",0,0,1),cw=number(crop,"width",1,1e-9,1),ch=number(crop,"height",1,1e-9,1);
        if(x+cw>1.000001||y+ch>1.000001){error="view: crop extends outside source";return false;}
        double angle=number(geom,"angle",0,-45,45)*pi/180;
        int tr=int(number(geom,"quarterTurns",0,-1000,1000));uint32_t turns=uint32_t((tr%4+4)%4),flips=(geom.at("flipH").as_bool()?1u:0u)|(geom.at("flipV").as_bool()?2u:0u);
        uint32_t w=std::max(1u,uint32_t(std::lround(cw*print.w))),h=std::max(1u,uint32_t(std::lround(ch*print.h)));
        if(turns%2)std::swap(w,h);
        // All request validation precedes any GPU operation.
        Image current=allocate(gpu,print.w,print.h,error);if(!current.valid())return false;
        {
            auto curves=gpu->upload(table.data(),sizeof(table),error);if(!curves)return false;
            uint32_t gm[]={uint32_t(print.pixels()),print.w,print.h,di_lut_size};
            std::vector<Arg> grade_args={Arg::buf(print.buf),Arg::inline_bytes(u.data(),u.size()),Arg::buf(curves),Arg::inline_bytes(gm,di_lut?4:3),Arg::buf(current.buf)};
            if(di_lut)grade_args.push_back(Arg::buf(di_lut));
            if(!gpu->dispatch(di_lut?"spk_view_grade_di":"spk_view_grade",grade_args,print.pixels(),error)||!gpu->flush(error))return false;
            // Args borrow raw pointers; end their scope and release the curve
            // table only after the dispatch that uses them has completed.
        }
        bool geometry=x!=0||y!=0||cw!=1||ch!=1||angle!=0||turns!=0||flips!=0;
        if(geometry){float p[]={float(x+cw/2),float(y+ch/2),float(cw),float(ch),float(std::cos(angle)),float(std::sin(angle)),float(print.h)/print.w};
            if(!resample(gpu,current,w,h,p,turns,flips,error))return false;}
        uint32_t edge=std::max(w,h);
        if(req.long_edge&&req.long_edge<edge){double s=double(req.long_edge)/edge;w=std::max(1u,uint32_t(std::lround(w*s)));h=std::max(1u,uint32_t(std::lround(h*s)));
            const float p[]={.5f,.5f,1,1,1,0,float(current.h)/current.w};
            if(!resample(gpu,current,w,h,p,0,0,error))return false;}
        auto stats=gpu->alloc_zeroed(12,error);if(!stats)return false;
        uint32_t encode_mode=4;
        auto convert=[&](const Json& transform,bool compress)->bool {
        const bool identity=transform.at("source_color_space").as_string()==transform.at("target_color_space").as_string();
        encode_mode=4;
        if(!identity||(compress&&transform.at("gamut_compress").at("algorithm").as_string()=="cam16ucs")){
            Image next=allocate(gpu,w,h,error);if(!next.valid())return false;
            uint32_t dm[]={uint32_t(current.elements()),uint32_t(transform.at("source_cctf_mode").as_int())};
            if(!gpu->dispatch("spk_cctf_decode",{Arg::buf(current.buf),Arg::inline_bytes(dm,2),Arg::buf(next.buf)},current.elements(),error)||!gpu->flush(error))return false;
            current=std::move(next);next=allocate(gpu,w,h,error);if(!next.valid())return false;
            auto row=floats(transform.at("matrix"),9);std::array<float,9> transpose{};
            for(size_t r=0;r<3;++r)for(size_t c=0;c<3;++c)transpose[r*3+c]=row[c*3+r];
            uint32_t count=uint32_t(current.pixels());
            if(!gpu->dispatch("spk_matmul3",{Arg::buf(current.buf),Arg::inline_bytes(transpose.data(),9),Arg::inline_bytes(&count,1),Arg::buf(next.buf)},count,error)||!gpu->flush(error))return false;
            current=std::move(next);
            const Json& gc=transform.at("gamut_compress");
            if(compress&&gc.at("algorithm").as_string()=="cam16ucs"){
                uint32_t rows=uint32_t(gc.at("cmax_rows").as_int()),cols=uint32_t(gc.at("cmax_cols").as_int());
                if(!cmax||uint64_t(rows)*cols!=cmax_count||rows<2||cols<2){error="view: invalid C_max table";return false;}
                auto mx=floats(gc.at("m_to_xyz"),9),mr=floats(gc.at("m_to_rgb"),9),k=floats(gc.at("k"),22);
                auto cb=gpu->upload(cmax,size_t(cmax_count)*4,error);if(!cb)return false;
                uint32_t meta[]={count,rows,cols,gc.at("lightness_compression_active").as_bool()?1u:0u};
                next=allocate(gpu,w,h,error);if(!next.valid())return false;
                std::vector<Arg> args={Arg::buf(current.buf),Arg::inline_bytes(mx.data(),9),Arg::inline_bytes(mr.data(),9),Arg::buf(cb),Arg::inline_bytes(k.data(),22),Arg::inline_bytes(meta,4),Arg::buf(next.buf)};
                if(req.proof_long_edge)args.push_back(Arg::buf(stats));
                if(!gpu->dispatch(req.proof_long_edge?"spk_view_cam16":"spk_cam16ucs_compress",args,count,error)||!gpu->flush(error))return false;
                current=std::move(next);
            }
            encode_mode=uint32_t(transform.at("target_cctf_mode").as_int());
            if(encode_mode>3){error="view: unsupported target transfer function";return false;}
        }
        return true;
        };
        if(!convert(transform,req.export_intent))return false;
        result.file_width=w;result.file_height=h;
        uint32_t output_channels=req.output_channels,bits=req.rgba16?16u:8u;
        if(req.proof_long_edge){
            if(!req.export_intent||!transform.at("proof").is_object()){error="view: missing proof display transform";return false;}
            uint32_t qm[]={w*h,encode_mode,bits,0,1};
            if(!gpu->dispatch("spk_view_pack",{Arg::buf(current.buf),Arg::inline_bytes(qm,5),Arg::buf(current.buf),Arg::buf(stats)},current.pixels(),error)||!gpu->flush(error))return false;
            if(req.proof_long_edge<std::max(w,h)){
                double scale=double(req.proof_long_edge)/std::max(w,h);
                w=std::max(1u,uint32_t(std::lround(w*scale)));h=std::max(1u,uint32_t(std::lround(h*scale)));
                const float p[]={.5f,.5f,1,1,1,0,float(current.h)/current.w};
                if(!resample(gpu,current,w,h,p,0,0,error))return false;
            }
            if(!convert(transform.at("proof"),false))return false;
            uint32_t counts[3]{};
            if(!gpu->read(stats.get(),0,counts,sizeof(counts),error))return false;
            result.moved_pixels=counts[0];result.clipped_pixels=counts[1];result.outside_pixels=counts[2];
            output_channels=4;bits=8;
        }
        const size_t bytes=size_t(w)*h*output_channels*(bits/8);
        // Vulkan storage writes and buffer copies operate on complete words.
        // RGB8/RGB16 can have a partial final word; only its live bytes escape.
        const size_t padded_bytes=(bytes+3)&~size_t(3);
        auto packed=gpu->alloc(padded_bytes,error);if(!packed)return false;
        uint32_t pm[]={w*h,encode_mode,bits,output_channels,0};
        const size_t jobs=output_channels==3?padded_bytes/4:size_t(w)*h;
        if(!gpu->dispatch("spk_view_pack",{Arg::buf(current.buf),Arg::inline_bytes(pm,5),Arg::buf(packed),Arg::buf(stats)},jobs,error)||!gpu->flush(error))return false;
        // Only the packed result is needed from here. Drop the final float
        // plane before allocating its CPU output; the pool may reuse it, while
        // device_output keeps ownership of packed without a readback.
        const size_t finished_float_bytes=current.bytes();
        current={};stats.reset();
        result.post_ms=ms(started);
        result.width=w;result.height=h;result.source_width=print.w;result.source_height=print.h;
        if(device_output){device_output->w=w;device_output->h=h;device_output->c=2;device_output->buf=std::move(packed);return true;}
        // A large CPU readback should not overlap the now-idle float planes.
        // Keep packed (and every other live/cache handle) while returning the
        // unused scratch. Small previews retain their normal warm pool.
        if(!gpu->trim_idle_for_phase(finished_float_bytes,0,error))return false;
        result.post_ms=ms(started);
        auto read=Clock::now();result.pixels.resize(padded_bytes);
        if(!gpu->read(packed.get(),0,result.pixels.data(),padded_bytes,error))return false;
        result.pixels.resize(bytes);
        result.readback_ms=ms(read);result.width=w;result.height=h;result.source_width=print.w;result.source_height=print.h;
        return true;
    }catch(const std::exception& e){error=e.what();return false;}
}
}
