// HalfFramePair/PairComposer.swift's decode geometry, in scene-linear RGB.
// No film, paper, tone mapping or display transform belongs in this stage.
#pragma once
#include "image_io.hpp"
#include "json.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace spkhost::pair {
using spk::Json;
struct Size { uint32_t w = 0, h = 0; };
struct Rect { double x = 0, y = 0, w = 1, h = 1; };
struct Geometry { Rect crop; double angle = 0; int turns = 0; bool flip_h = false, flip_v = false; };
struct Placement { double scale = 1, x = 0, y = 0; int turns = 0; };
struct Source {
    Json settings;
    FloatImage pixels;       // source decode, released after its hole is sampled
    Metadata metadata;
    Geometry geometry;
    Placement placement;
    FloatImage hole;         // the exact picture the per-hole meter reads
    std::string error;
    double exposure = 0, metered = 0;
    std::filesystem::path path;
    std::string metered_for;
    bool meter_reused = false;
    std::string cache_source;
    DecodeOptions decode_options;
    bool bitmap_reused = false;
    bool present() const { return pixels.width != 0 || hole.width != 0; }
};
struct Layout {
    Size hole, size;
    uint32_t advance = 0;
    bool turned = false;
    Rect rect(size_t side) const {
        return { double(turned ? 0 : side*advance), double(turned ? side*advance : 0), double(hole.w), double(hole.h) };
    }
};
inline double numeric(const Json& o, const char* key, double fallback) {
    const auto& v = o.at(key);
    if (v.is_null()) return fallback;
    if (!v.is_number() || !std::isfinite(v.as_double())) throw std::runtime_error(std::string("invalid pair field: ")+key);
    return v.as_double();
}
inline int turns(double n) {
    if (std::abs(n) > 1000000) throw std::runtime_error("pair quarter turns out of range");
    const int q = int(std::round(n));
    return ((q % 4)+4)%4;
}
inline Geometry geometry(const Json& value) {
    if(!value.is_null() && !value.is_object()) throw std::runtime_error("invalid pair geometry");
    Geometry g;
    const auto& c = value.at("crop");
    if (c.is_array()) {
        if (c.items().size()!=4) throw std::runtime_error("pair crop needs four numbers");
        std::array<double,4> r;
        for (size_t i=0;i<4;++i) {
            if (!c.items()[i].is_number()) throw std::runtime_error("pair crop needs four numbers");
            r[i]=c.items()[i].as_double();
        }
        g.crop={r[0],r[1],r[2],r[3]};
    } else if (c.is_object()) {
        g.crop={numeric(c,"x",0),numeric(c,"y",0),numeric(c,"width",1),numeric(c,"height",1)};
    } else if (!c.is_null()) throw std::runtime_error("invalid pair crop");
    const auto r=g.crop;
    if (!std::isfinite(r.x+r.y+r.w+r.h) || r.x<0 || r.y<0 || r.w<=0 || r.h<=0 || r.x+r.w>1.000001 || r.y+r.h>1.000001)
        throw std::runtime_error("pair crop is outside the photograph");
    g.angle=numeric(value,"angle",0);
    if (std::abs(g.angle)>45) throw std::runtime_error("pair straighten outside -45..45");
    g.turns=turns(numeric(value,"quarterTurns",0));
    g.flip_h=value.at("flipH").as_bool(); g.flip_v=value.at("flipV").as_bool();
    return g;
}
inline Placement placement(const Json& value) {
    if(!value.is_null() && !value.is_object()) throw std::runtime_error("invalid pair placement");
    return { std::clamp(numeric(value,"scale",1),1.,4.), std::clamp(numeric(value,"x",0),-1.,1.),
        std::clamp(numeric(value,"y",0),-1.,1.), turns(numeric(value,"quarterTurns",0)) };
}
inline Size output_size(const Geometry& g, Size s) {
    Size out{uint32_t(std::max(1l,std::lround(s.w*g.crop.w))),uint32_t(std::max(1l,std::lround(s.h*g.crop.h)))};
    if (g.turns%2) std::swap(out.w,out.h);
    return out;
}
inline Size turned(Size s, int q) { if(q%2) std::swap(s.w,s.h); return s; }
inline std::array<double,2> undo_turn(double u,double v,int q) {
    if(q==1) return {v,1-u};
    if(q==2) return {1-u,1-v};
    if(q==3) return {1-v,u};
    return {u,v};
}
inline std::array<double,2> source_point(const Geometry& g,double u,double v,Size s) {
    if(g.flip_h) u=1-u; if(g.flip_v) v=1-v;
    const auto p=undo_turn(u,v,g.turns);
    const double x=(p[0]-.5)*g.crop.w*s.w, y=(p[1]-.5)*g.crop.h*s.h;
    const double a=g.angle*3.14159265358979323846/180., c=std::cos(a), sn=std::sin(a);
    return {g.crop.x+g.crop.w/2+(x*c-y*sn)/s.w,g.crop.y+g.crop.h/2+(x*sn+y*c)/s.h};
}
inline Rect source_rect(Placement p, Size source, double aspect) {
    double w=source.w,h=source.h;
    if(w/h>aspect) w=h*aspect; else h=w/aspect;
    w/=p.scale; h/=p.scale;
    return {(source.w-w)*(1+p.x)/2,(source.h-h)*(1+p.y)/2,w,h};
}
inline Layout make_layout(uint32_t across,double spacing,bool vertical) {
    const uint32_t a=std::max(8u,across);
    const uint32_t along=uint32_t(std::max(6l,std::lround(a*18./24.)));
    const uint32_t advance=uint32_t(std::lround(along*(18+spacing)/18.));
    Layout l{{along,a},{advance+along,a},advance,vertical};
    if(vertical) { l.hole={a,along}; l.size={a,advance+along}; }
    if(uint64_t(l.size.w)*l.size.h*3>uint64_t(1024)*1024*1024/sizeof(float))
        throw std::runtime_error("pair composition exceeds 1 GiB");
    return l;
}
inline Layout layout(const std::array<Source,2>& sources,double spacing,bool vertical) {
    double across=std::numeric_limits<double>::infinity(), longest=0;
    for(const auto& s:sources) if(s.pixels.width) {
        const Size framed=output_size(s.geometry,{s.pixels.width,s.pixels.height});
        const Size rotated=turned(framed,s.placement.turns);
        Placement fit=s.placement; fit.scale=1;
        const auto cut=source_rect(fit,rotated,vertical?24./18.:18./24.);
        across=std::min(across,vertical?cut.w:cut.h);
        longest=std::max({longest,double(framed.w),double(framed.h)});
    }
    if(!std::isfinite(across)) across=2400;
    if(longest>0) across=std::min(across,longest/(37./24.));
    return make_layout(uint32_t(std::max(8.,std::floor(across))),spacing,vertical);
}
inline void sample_hole(Source& s,const Layout& l) {
    if(!s.pixels.width) return;
    const Size native{s.pixels.width,s.pixels.height}, framed=output_size(s.geometry,native), rotated=turned(framed,s.placement.turns);
    const Rect cut=source_rect(s.placement,rotated,l.turned?24./18.:18./24.);
    s.hole.width=l.hole.w; s.hole.height=l.hole.h;
    s.hole.rgb.resize(size_t(l.hole.w)*l.hole.h*3);
    for(uint32_t y=0;y<l.hole.h;++y) for(uint32_t x=0;x<l.hole.w;++x) {
        auto uv=undo_turn((cut.x+(x+.5)/l.hole.w*cut.w)/rotated.w,(cut.y+(y+.5)/l.hole.h*cut.h)/rotated.h,s.placement.turns);
        uv=source_point(s.geometry,uv[0],uv[1],native);
        const double fx=std::clamp(uv[0]*native.w-.5,0.,double(native.w-1)), fy=std::clamp(uv[1]*native.h-.5,0.,double(native.h-1));
        const uint32_t x0=uint32_t(fx), y0=uint32_t(fy), x1=std::min(x0+1,native.w-1), y1=std::min(y0+1,native.h-1);
        const double tx=fx-x0,ty=fy-y0;
        for(size_t c=0;c<3;++c) {
            auto at=[&](uint32_t a,uint32_t b){return double(s.pixels.rgb[(size_t(b)*native.w+a)*3+c]);};
            s.hole.rgb[(size_t(y)*l.hole.w+x)*3+c]=float((at(x0,y0)*(1-tx)+at(x1,y0)*tx)*(1-ty)+(at(x0,y1)*(1-tx)+at(x1,y1)*tx)*ty);
        }
    }
    s.pixels={};
}
inline FloatImage compose(const std::array<Source,2>& sources,const Layout& l,bool expose=true) {
    const uint64_t count=uint64_t(l.size.w)*l.size.h*3;
    if(count>uint64_t(1024)*1024*1024/sizeof(float)) throw std::runtime_error("pair composition exceeds 1 GiB");
    FloatImage out{l.size.w,l.size.h,std::vector<float>(size_t(count),0.f)};
    for(size_t side=0;side<2;++side) {
        const auto& s=sources[side]; if(!s.hole.width) continue;
        const Rect rect=l.rect(side);
        const double gain=expose?std::exp2(s.exposure+s.metered):1;
        for(uint32_t y=0;y<l.hole.h;++y) for(uint32_t x=0;x<l.hole.w;++x) for(size_t c=0;c<3;++c)
            out.rgb[((size_t(y+uint32_t(rect.y))*out.width)+x+uint32_t(rect.x))*3+c]=float(s.hole.rgb[(size_t(y)*l.hole.w+x)*3+c]*gain);
    }
    return out;
}
} // namespace spkhost::pair
