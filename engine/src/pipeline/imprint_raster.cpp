// Apple retains CoreText/CoreGraphics/vImage in overscan.cpp. The portable
// adapter uses only the three pinned font blobs compiled by CMake; stb must
// never parse externally supplied fonts (see its upstream security notice).
#if !defined(__APPLE__) || defined(SPK_VULKAN_BACKEND)
#include "imprint_raster.hpp"
#include "spk_imprint_fonts.hpp"
#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "../../third_party/stb/stb_truetype.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <thread>
#include <utility>

namespace spk::imprint {
namespace {
struct Fonts {
    stbtt_fontinfo regular{}, bold{}, mono_bold{};
    Fonts() {
        if (!stbtt_InitFont(&regular, font_data::regular, 0) ||
            !stbtt_InitFont(&bold, font_data::bold, 0) ||
            !stbtt_InitFont(&mono_bold, font_data::mono_bold, 0))
            throw std::runtime_error("cannot initialize bundled imprint fonts");
    }
};
// The CoreText face names overscan.cpp asks for, mapped to the pinned blobs:
//   "Menlo-Bold" (CineStill 800T's 135 numbers)  -> DejaVu Sans Mono Bold,
//       the face Menlo was derived from; same 0.602 em advance and cap height;
//   any other "...Bold"                          -> Liberation Sans Bold;
//   everything else (HelveticaNeue, ArialNarrow) -> Liberation Sans Regular.
bool is_mono(const char* face) { return std::strstr(face, "Menlo") || std::strstr(face, "Mono"); }
const stbtt_fontinfo& font(const char* face) {
    static const Fonts fonts;
    if (is_mono(face)) return fonts.mono_bold;
    return std::strstr(face, "Bold") ? fonts.bold : fonts.regular;
}
// Arial Narrow's advances and outlines are Arial's at 0.82 across (measured
// through CoreText on macOS 27: 0.8200 on every string the edge prints), and
// Liberation Sans is metric-compatible with Arial, so the narrow face is the
// regular blob condensed by that factor (CineStill 800T's 120 name).
double face_width(const char* face) { return std::strstr(face, "Narrow") ? 0.82 : 1.0; }
std::vector<int> codepoints(const std::string& text) {
    std::vector<int> result;
    for (size_t i=0;i<text.size();) {
        const unsigned char first=text[i++];
        uint32_t cp=first;size_t tail=0;
        if (first>=0xC2 && first<=0xDF) { cp=first&31;tail=1; }
        else if (first>=0xE0 && first<=0xEF) { cp=first&15;tail=2; }
        else if (first>=0xF0 && first<=0xF4) { cp=first&7;tail=3; }
        else if(first>=0x80) { result.push_back(0xFFFD);continue; }
        bool valid=i+tail<=text.size();
        for(size_t j=0;j<tail && valid;++j) {
            const unsigned char c=text[i+j];
            if((c&0xC0)!=0x80)valid=false;
            else cp=(cp<<6)|(c&63);
        }
        if(!valid) { result.push_back(0xFFFD);continue; }
        i+=tail;
        if(cp>0x10FFFF || (cp>=0xD800&&cp<=0xDFFF) ||
           (tail==1&&cp<0x80)||(tail==2&&cp<0x800)||(tail==3&&cp<0x10000))cp=0xFFFD;
        result.push_back(int(cp));
    }
    return result;
}
Point middle(Point a,Point b) { return {(a.x+b.x)*.5,(a.y+b.y)*.5}; }
double distance_to_line(Point p,Point a,Point b) {
    const double dx=b.x-a.x,dy=b.y-a.y,l2=dx*dx+dy*dy;
    if(l2==0)return std::hypot(p.x-a.x,p.y-a.y);
    return std::abs(dx*(p.y-a.y)-dy*(p.x-a.x))/std::sqrt(l2);
}
void quadratic(Contour& out,Point a,Point b,Point c,double tol,unsigned depth=0) {
    if(depth==16||distance_to_line(b,a,c)<=tol){out.push_back(c);return;}
    const auto ab=middle(a,b),bc=middle(b,c),m=middle(ab,bc);
    quadratic(out,a,ab,m,tol,depth+1);quadratic(out,m,bc,c,tol,depth+1);
}
void cubic(Contour& out,Point a,Point b,Point c,Point d,double tol,unsigned depth=0) {
    if(depth==16||std::max(distance_to_line(b,a,d),distance_to_line(c,a,d))<=tol){out.push_back(d);return;}
    const auto ab=middle(a,b),bc=middle(b,c),cd=middle(c,d),abc=middle(ab,bc),bcd=middle(bc,cd),m=middle(abc,bcd);
    cubic(out,a,ab,abc,m,tol,depth+1);cubic(out,m,bcd,cd,d,tol,depth+1);
}
template<class F> void rows(int height,size_t pixels,F&& fn) {
    // Tiny masks remain serial. Larger full-width bands use bounded workers;
    // each output owns its sum and keeps the scalar tap order reproducible.
    const unsigned available=std::max(1u,std::thread::hardware_concurrency());
    const unsigned count=pixels>=262144?std::min({8u,available,unsigned(height)}):1u;
    std::vector<std::thread> workers;workers.reserve(count-1);
    try {
        for(unsigned k=1;k<count;++k)
            workers.emplace_back([&,k]{for(int y=int(uint64_t(height)*k/count);y<int(uint64_t(height)*(k+1)/count);++y)fn(y);});
        for(int y=0;y<int(uint64_t(height)/count);++y)fn(y);
    }catch(...){for(auto& t:workers)t.join();throw;}
    for(auto& t:workers)t.join();
}
} // namespace

double text_width(const char* face,double em,const std::string& text,double tracking,double horizontal_scale) {
    const auto& f=font(face);const auto cps=codepoints(text);
    const double scale=stbtt_ScaleForMappingEmToPixels(&f,float(em));double advance=0;
    const double across=scale*face_width(face);
    for(size_t i=0;i<cps.size();++i){int a=0,b=0;stbtt_GetCodepointHMetrics(&f,cps[i],&a,&b);
        advance+=a*across+tracking;
        if(i+1<cps.size())advance+=stbtt_GetCodepointKernAdvance(&f,cps[i],cps[i+1])*across;
    }
    return advance*horizontal_scale;
}

Contours text_outlines(const char* face,double em,const std::string& text,double tracking,
                       double horizontal_scale,bool scale_advances,double flatness) {
    const auto& f=font(face);const auto cps=codepoints(text);
    const double scale=stbtt_ScaleForMappingEmToPixels(&f,float(em));double advance=0;
    const double across=scale*face_width(face);
    Contours result;
    for(size_t i=0;i<cps.size();++i){
        stbtt_vertex* shape=nullptr;const int count=stbtt_GetCodepointShape(&f,cps[i],&shape);
        auto free_shape = [&](stbtt_vertex* v) { stbtt_FreeShape(&f, v); };
        std::unique_ptr<stbtt_vertex, decltype(free_shape)> owned(shape, free_shape);
        auto point=[&](short x,short y){return Point{advance*(scale_advances?horizontal_scale:1.0)+x*across*horizontal_scale,-y*scale};};
        Point current{};
        for(int j=0;j<count;++j){const auto& v=shape[j];const Point next=point(v.x,v.y);
            if(v.type==STBTT_vmove){result.emplace_back();result.back().push_back(next);}
            else if(!result.empty()){
                if(v.type==STBTT_vline)result.back().push_back(next);
                else if(v.type==STBTT_vcurve)quadratic(result.back(),current,point(v.cx,v.cy),next,flatness);
                else if(v.type==STBTT_vcubic)cubic(result.back(),current,point(v.cx,v.cy),point(v.cx1,v.cy1),next,flatness);
            }
            current=next;
        }
        int a=0,b=0;stbtt_GetCodepointHMetrics(&f,cps[i],&a,&b);advance+=a*across+tracking;
        if(i+1<cps.size())advance+=stbtt_GetCodepointKernAdvance(&f,cps[i],cps[i+1])*across;
    }
    return result;
}

// Exact-area coverage (the signed-area accumulation of font-rs / stb_truetype's
// v2 rasterizer): each edge deposits the area it sweeps into a per-row
// accumulation buffer, and a prefix sum along the row gives the integral of
// the winding number over each pixel. Coverage is min(1, |that|), which is
// the nonzero rule's exact area wherever the winding is 0 or +-1 -- every
// glyph and every date/edge mark this engine draws. Until 2026-10-29 this was
// eight sample rows per pixel; against CoreGraphics' analytic coverage that
// left the date back's seven-segment edges up to 21 8-bit codes off on the
// printed frame (engine/tests/parity_metal_vulkan.py, pair/135_half_no_edge).
void fill(std::vector<uint8_t>& pixels,int width,int height,const Contours& paths,double gray) {
    if(width<=0||height<=0||paths.empty())return;
    double xmin=1e300,ymin=1e300,xmax=-1e300,ymax=-1e300;
    for(const auto& path:paths)for(const auto& p:path){xmin=std::min(xmin,p.x);xmax=std::max(xmax,p.x);ymin=std::min(ymin,p.y);ymax=std::max(ymax,p.y);}
    if(!(xmin<=xmax)||!(ymin<=ymax))return;
    const int y0=std::clamp(int(std::floor(ymin)),0,height),y1=std::clamp(int(std::ceil(ymax)),0,height);
    if(y0>=y1||xmax<0||xmin>width)return;
    // The buffer spans the paths' own x extent (unclipped) plus two guard
    // cells, so nothing is clipped before the prefix sum; only the visible
    // part [0, width) is composited.
    const int bx0=int(std::floor(xmin)),bw=int(std::ceil(xmax))-bx0+3,bh=y1-y0;
    std::vector<double> acc(size_t(bw)*size_t(bh),0.0);
    auto line=[&](Point p0,Point p1){
        if(p0.y==p1.y)return;
        double dir=1;
        if(p0.y>p1.y){std::swap(p0,p1);dir=-1;}
        const double dxdy=(p1.x-p0.x)/(p1.y-p0.y);
        const int ys=std::max(y0,int(std::floor(p0.y))),ye=std::min(y1,int(std::ceil(p1.y)));
        for(int y=ys;y<ye;++y){
            const double top=std::max(double(y),p0.y),bot=std::min(double(y+1),p1.y);
            if(bot<=top)continue;
            const double xa=p0.x+(top-p0.y)*dxdy-bx0,xb=p0.x+(bot-p0.y)*dxdy-bx0;
            const double d=(bot-top)*dir;
            double* row=&acc[size_t(y-y0)*size_t(bw)];
            const double lo=std::min(xa,xb),hi=std::max(xa,xb);
            const int i0=int(std::floor(lo)),i1=int(std::ceil(hi));
            if(i1<=i0+1){
                // within one pixel column: the part right of the edge's mean x
                const double xm=0.5*(xa+xb)-i0;
                row[i0]+=d*(1-xm);row[i0+1]+=d*xm;
            }else{
                const double sl=1.0/(hi-lo),f0=lo-i0,f1=hi-(i1-1);
                const double a0=0.5*sl*(1-f0)*(1-f0),am=0.5*sl*f1*f1;
                row[i0]+=d*a0;
                if(i1==i0+2)row[i0+1]+=d*(1-a0-am);
                else{
                    const double a1=sl*(1.5-f0);
                    row[i0+1]+=d*(a1-a0);
                    for(int i=i0+2;i<i1-1;++i)row[i]+=d*sl;
                    const double a2=a1+(i1-i0-3)*sl;
                    row[i1-1]+=d*(1-a2-am);
                }
                row[i1]+=d*am;
            }
        }
    };
    for(const auto& path:paths){if(path.size()<3)continue;
        Point a=path.back();for(const auto& b:path){line(a,b);a=b;}}
    const double value=255*std::clamp(gray,0.0,1.0);
    for(int y=y0;y<y1;++y){
        const double* row=&acc[size_t(y-y0)*size_t(bw)];double sum=0;
        for(int i=0;i<bw;++i){
            sum+=row[i];
            const int x=bx0+i;
            if(x<0)continue;
            if(x>=width)break;
            const double a=std::min(1.0,std::abs(sum));
            if(a<=0)continue;
            auto& p=pixels[size_t(y)*width+x];p=uint8_t(std::clamp(std::lround(value*a+p*(1-a)),0l,255l));
        }
    }
}

void gaussian(std::vector<float>& cov,int width,int height,const std::vector<float>& weights) {
    const int radius=int(weights.size()/2);std::vector<float> temp(cov.size());
    rows(height,cov.size(),[&](int y){for(int x=0;x<width;++x){float sum=0;
        for(int k=-radius;k<=radius;++k)sum+=weights[size_t(k+radius)]*cov[size_t(y)*width+std::clamp(x+k,0,width-1)];
        temp[size_t(y)*width+x]=sum;}});
    rows(height,cov.size(),[&](int y){for(int x=0;x<width;++x){float sum=0;
        for(int k=-radius;k<=radius;++k)sum+=weights[size_t(k+radius)]*temp[size_t(std::clamp(y+k,0,height-1))*width+x];
        cov[size_t(y)*width+x]=sum;}});
}
} // namespace spk::imprint
#endif
