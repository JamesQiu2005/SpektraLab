#include "pipeline/imprint_raster.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <numeric>
#include <stdexcept>

namespace {
void check(bool ok,const char* error){if(!ok)throw std::runtime_error(error);}
}
int main(){try{
    using namespace spk::imprint;
    std::vector<uint8_t> pixels(16*16);
    fill(pixels,16,16,{{{1.25,2.125},{9.75,2.125},{9.75,8.875},{1.25,8.875}}},1);
    const double area=std::accumulate(pixels.begin(),pixels.end(),0.0)/255;
    check(std::abs(area-8.5*6.75)<.06,"subpixel coverage area is wrong");
    check(pixels[2*16+1]>0&&pixels[2*16+1]<255,"edge was not antialiased");
    std::fill(pixels.begin(),pixels.end(),0);
    fill(pixels,16,16,{{{0,0},{12,0},{12,12},{0,12}},{{4,4},{4,8},{8,8},{8,4}}},1);
    check(std::accumulate(pixels.begin(),pixels.end(),0)==128*255,"nonzero-winding glyph counter was filled");
    check(pixels[5*16+5]==0&&pixels[2*16+2]==255,"glyph hole is wrong");
    fill(pixels,16,16,{{{1,1},{3,1},{3,3},{1,3}}},.3);
    check(pixels[2*16+2]==77,"gray source-over did not replace the old operation");

    const double width=text_width("HelveticaNeue-Bold",1,"KODAK TRI-X 400",.02,1);
    check(width>6&&width<12,"bundled font has wrong physical advance");
    check(std::abs(text_width("HelveticaNeue-Bold",1,"KODAK TRI-X 400",.02,1.7)-width*1.7)<1e-12,"advance scale mismatch");
    const auto normal=text_outlines("HelveticaNeue",1,"0123456789 ABC",.01,1,false,.001);
    const auto bold=text_outlines("HelveticaNeue-Bold",1,"0123456789 ABC",.01,1,false,.001);
    check(!normal.empty()&&!bold.empty(),"bundled font produced no contours");
    std::vector<uint8_t> a(720*160),b(a.size());
    auto draw=[&](Contours paths,std::vector<uint8_t>& out){for(auto& path:paths)for(auto& p:path){p.x=20+p.x*70;p.y=120+p.y*70;}fill(out,720,160,paths,1);};
    draw(normal,a);draw(bold,b);
    check(std::accumulate(b.begin(),b.end(),uint64_t(0))>std::accumulate(a.begin(),a.end(),uint64_t(0)),"regular/bold face selection failed");

    // A direct 2-D reference verifies edge extension and pass ordering; the
    // larger case also crosses the bounded multi-worker threshold.
    for(int side:{9,513}){
        std::vector<float> src(size_t(side)*side);for(size_t i=0;i<src.size();++i)src[i]=float((i*17)%127)/128;
        auto out=src;const std::vector<float> weights{.25f,.5f,.25f};gaussian(out,side,side,weights);
        for(int y=0;y<side;++y)for(int x=0;x<side;++x){float want=0;
            for(int j=-1;j<=1;++j)for(int i=-1;i<=1;++i)want+=weights[i+1]*weights[j+1]*src[size_t(std::clamp(y+j,0,side-1))*side+std::clamp(x+i,0,side-1)];
            check(out[size_t(y)*side+x]==want,"portable Gaussian differs from exact 2-D fixture");
        }
    }
    std::puts("Imprint raster passed coverage, glyph counters, compositing, bundled fonts and serial/parallel blur");
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
