// Apple retains CoreText/CoreGraphics/vImage in overscan.cpp. The portable
// adapter uses only the two pinned font blobs compiled by CMake; stb must
// never parse externally supplied fonts (see its upstream security notice).
#ifndef __APPLE__
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
    stbtt_fontinfo regular{}, bold{};
    Fonts() {
        if (!stbtt_InitFont(&regular, font_data::regular, 0) ||
            !stbtt_InitFont(&bold, font_data::bold, 0))
            throw std::runtime_error("cannot initialize bundled imprint fonts");
    }
};
const stbtt_fontinfo& font(const char* face) {
    static const Fonts fonts;
    return std::strstr(face, "Bold") ? fonts.bold : fonts.regular;
}
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
    for(size_t i=0;i<cps.size();++i){int a=0,b=0;stbtt_GetCodepointHMetrics(&f,cps[i],&a,&b);
        advance+=a*scale+tracking;
        if(i+1<cps.size())advance+=stbtt_GetCodepointKernAdvance(&f,cps[i],cps[i+1])*scale;
    }
    return advance*horizontal_scale;
}

Contours text_outlines(const char* face,double em,const std::string& text,double tracking,
                       double horizontal_scale,bool scale_advances,double flatness) {
    const auto& f=font(face);const auto cps=codepoints(text);
    const double scale=stbtt_ScaleForMappingEmToPixels(&f,float(em));double advance=0;
    Contours result;
    for(size_t i=0;i<cps.size();++i){
        stbtt_vertex* shape=nullptr;const int count=stbtt_GetCodepointShape(&f,cps[i],&shape);
        auto free_shape = [&](stbtt_vertex* v) { stbtt_FreeShape(&f, v); };
        std::unique_ptr<stbtt_vertex, decltype(free_shape)> owned(shape, free_shape);
        auto point=[&](short x,short y){return Point{advance*(scale_advances?horizontal_scale:1.0)+x*scale*horizontal_scale,-y*scale};};
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
        int a=0,b=0;stbtt_GetCodepointHMetrics(&f,cps[i],&a,&b);advance+=a*scale+tracking;
        if(i+1<cps.size())advance+=stbtt_GetCodepointKernAdvance(&f,cps[i],cps[i+1])*scale;
    }
    return result;
}

void fill(std::vector<uint8_t>& pixels,int width,int height,const Contours& paths,double gray) {
    if(width<=0||height<=0||paths.empty())return;
    double xmin=width,ymin=height,xmax=0,ymax=0;
    for(const auto& path:paths)for(const auto& p:path){xmin=std::min(xmin,p.x);xmax=std::max(xmax,p.x);ymin=std::min(ymin,p.y);ymax=std::max(ymax,p.y);}
    const int x0=std::clamp(int(std::floor(xmin)),0,width),x1=std::clamp(int(std::ceil(xmax)),0,width);
    const int y0=std::clamp(int(std::floor(ymin)),0,height),y1=std::clamp(int(std::ceil(ymax)),0,height);
    if(x0>=x1||y0>=y1)return;
    constexpr int samples=8;const double value=255*std::clamp(gray,0.0,1.0);
    std::vector<std::pair<double,int>> intersections;std::vector<double> coverage(size_t(x1-x0));
    for(int y=y0;y<y1;++y){
        std::fill(coverage.begin(),coverage.end(),0.0);
        for(int sub=0;sub<samples;++sub){
            const double scan=y+(sub+.5)/samples;intersections.clear();
            for(const auto& path:paths){if(path.size()<3)continue;
                Point a=path.back();for(const auto& b:path){
                    if((a.y<=scan&&b.y>scan)||(b.y<=scan&&a.y>scan))
                        intersections.emplace_back(a.x+(scan-a.y)*(b.x-a.x)/(b.y-a.y),b.y>a.y?1:-1);
                    a=b;
                }
            }
            std::sort(intersections.begin(),intersections.end());int winding=0;double start=0;
            for(const auto& hit:intersections){const int before=winding;winding+=hit.second;
                if(before==0&&winding!=0)start=hit.first;
                else if(before!=0&&winding==0){
                    const double left=std::max(double(x0),start),right=std::min(double(x1),hit.first);
                    for(int x=int(std::floor(left));x<int(std::ceil(right));++x)
                        coverage[size_t(x-x0)]+=std::max(0.0,std::min(right,double(x+1))-std::max(left,double(x)))/samples;
                }
            }
        }
        for(int x=x0;x<x1;++x){const double a=std::clamp(coverage[size_t(x-x0)],0.0,1.0);
            auto& p=pixels[size_t(y)*width+x];p=uint8_t(std::clamp(std::lround(value*a+p*(1-a)),0l,255l));}
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
