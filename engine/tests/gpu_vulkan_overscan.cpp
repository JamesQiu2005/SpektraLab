// Transfer/dispatch and physical stage invariants, independently of fonts or
// grain. The full seeded film/date/DX suite lives in overscan_checks.py.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>
namespace {
void check(bool ok,const std::string& error){if(!ok)throw std::runtime_error(error);}
using P=std::array<float,261>;
std::vector<float> run(spk::gpu::Gpu* gpu,const char* kernel,const std::vector<float>& in,const std::vector<float>& p,
                       std::vector<float> initial,uint32_t count){
    std::string e;initial.insert(initial.end(),51,-12345.f);
    auto source=gpu->upload(in.data(),in.size()*4,e),params=gpu->upload(p.data(),p.size()*4,e),dest=gpu->upload(initial.data(),initial.size()*4,e);
    check(source&&params&&dest,e);
    const bool ok=gpu->dispatch(kernel,{spk::gpu::Arg::buf(source),spk::gpu::Arg::buf(params),spk::gpu::Arg::inline_bytes(&count,1),spk::gpu::Arg::buf(dest)},count+31,e)&&gpu->flush(e);
    check(ok,e);std::vector<float> out;check(read_test_buffer(gpu,dest,out,e),e);
    for(size_t i=initial.size()-51;i<initial.size();++i)check(out[i]==-12345.f,"overscan dispatch wrote past output");
    out.resize(initial.size()-51);return out;
}
std::vector<float> run(spk::gpu::Gpu* gpu,const char* kernel,const std::vector<float>& in,const P& p){return run(gpu,kernel,in,{p.begin(),p.end()},std::vector<float>(in.size()),uint32_t(in.size()/3));}
}
int main(int argc,char** argv){try{
    check(argc==2,"usage: spk_vulkan_overscan resources_dir");std::string e;
    std::unique_ptr<spk::gpu::Gpu> gpu(spk::gpu::Gpu::create_vulkan(std::string(argv[1])+"/vulkan",e));check(bool(gpu),e);
    constexpr int w=17,h=13;std::vector<float> input(w*h*3);for(size_t i=0;i<input.size();++i)input[i]=float(1u<<(i%3))*.2f;
    P p{};p[0]=w;p[1]=h;p[2]=.1f;p[3]=w;p[4]=h;p[5]=p[8]=1;p[16]=w*p[2];p[17]=h*p[2];p[44]=h*p[2];p[199]=2;
    const auto canvas=run(gpu.get(),"spk_overscan_canvas",input,p);
    check(canvas==input,"unmodified gate did not preserve uniform raw exposure");
    check(run(gpu.get(),"spk_overscan_film_present",input,p)==input,"unperforated no-carrier film changed density");
    const auto identity_light=run(gpu.get(),"spk_overscan_light",input,p);
    // GLSL mix lowers to arithmetic; the identity endpoint may round by 1 ulp.
    for(size_t i=0;i<input.size();++i)check(std::abs(identity_light[i]-input[i])<2e-7f,
        "unperforated no-carrier scan changed RGB");
    // Shift film relative to the canvas, exercising full film, half coverage
    // and no film. Density removal precedes print; scan carrier is later.
    p[199]=0;p[10]=-.4f;p[44]=.8f;p[90]=.05f;p[91]=.1f;p[92]=.15f;
    const auto film=run(gpu.get(),"spk_overscan_film_present",input,p),light=run(gpu.get(),"spk_overscan_light",input,p);
    for(int y=0;y<h;++y){const float t=(float(y)+.5f)*p[2]+p[10];const float a=std::clamp(std::min(t,p[44]-t)/p[2]+.5f,0.f,1.f);
        for(int x=0;x<w;++x)for(int c=0;c<3;++c){const size_t i=(size_t(y)*w+x)*3+c;
            check(std::abs(film[i]-(a*input[i]+(1-a)*p[90+c]))<2e-6f,"film coverage changed physical density blend");
            check(std::abs(light[i]-a*input[i])<2e-6f,"scan carrier coverage is wrong");
        }
    }
    // The source mask is clipped using its own offset; negative coordinates
    // must not underflow, and non-positive samples leave the canvas alone.
    std::vector<float> mask(5*7);for(size_t i=0;i<mask.size();++i)mask[i]=float(int(i%9)-2)/8;
    const std::vector<float> m{-2,9,5,7,float(w),float(h),.2f,.4f,.6f};
    const auto added=run(gpu.get(),"spk_overscan_add_mask",mask,m,input,uint32_t(mask.size()));auto want=input;
    for(int y=0;y<7;++y)for(int x=0;x<5;++x){const int xx=x-2,yy=y+9;if(xx<0||yy<0||xx>=w||yy>=h)continue;
        const float a=mask[y*5+x];if(a<=0)continue;for(int c=0;c<3;++c)want[(yy*w+xx)*3+c]+=a*m[6+c];}
    for(size_t i=0;i<want.size();++i)check(std::abs(added[i]-want[i])<2e-7f,"mask exposure/offset clipping differs from CPU reference");
    std::puts("Overscan kernels passed identity exposure, density/scan coverage, mask clipping and dispatch guards");return 0;
}catch(const std::exception& ex){std::fprintf(stderr,"%s\n",ex.what());return 1;}}
