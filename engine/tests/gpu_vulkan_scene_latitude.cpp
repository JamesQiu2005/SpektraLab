// RFC-023 shader against the shared independent double stop-axis oracle.
// Covers the numeric node, pathological input, dispatch tail and the global
// coordinates used by half-frame pairs in the striped executor.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"
#include "latitude_fit.hpp"
#include "spektrafilm/spk_engine.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <vector>
namespace {
void check(bool ok,const std::string& why){if(!ok)throw std::runtime_error(why);}
using Params=std::array<float,19>;
std::vector<float> run(spk::gpu::Gpu* gpu,const std::vector<float>& in,const Params& p) {
    std::string e;const uint32_t count=uint32_t(in.size()/3);constexpr size_t guard=51;
    std::vector<float> init(in.size()+guard,-123456.f);
    auto src=gpu->upload(in.data(),in.size()*4,e),dst=gpu->upload(init.data(),init.size()*4,e);
    check(src&&dst,e);
    check(gpu->dispatch("spk_scene_latitude",{spk::gpu::Arg::buf(src),spk::gpu::Arg::inline_bytes(p.data(),p.size()),
        spk::gpu::Arg::inline_bytes(&count,1),spk::gpu::Arg::buf(dst)},count+17,e)&&gpu->flush(e),e);
    std::vector<float> out;check(read_test_buffer(gpu,dst,out,e),e);
    // The pool may lend a larger allocation. Only the initialized guard is
    // part of this request; an older tail beyond it is not a shader write.
    for(size_t i=in.size();i<init.size();++i)check(out[i]==-123456.f,"dispatch wrote past the pixel count");
    out.resize(in.size());return out;
}
double gain(const std::vector<float>& in,size_t i,const Params& p) {
    const double r=std::max(double(in[3*i]),0.),g=std::max(double(in[3*i+1]),0.),b=std::max(double(in[3*i+2]),0.);
    double n=p[6]==1?p[7]*r+p[8]*g+p[9]*b:p[6]==2?std::max({r,g,b}):
        (r*r+g*g+b*b>0?(r*r*r+g*g*g+b*b*b)/(r*r+g*g+b*b):0.);
    if(!(n>0)||!std::isfinite(n))return 1.;
    spk::SceneLatitudeParams s;s.highlight_knee=p[0];s.highlight_room=p[1];s.shadow_knee=p[2];s.shadow_room=p[3];
    s.rolloff=p[4];s.max_lift=p[5];
    if(p[13]>0){const auto w=uint32_t(p[11]),h=uint32_t(p[12]);const double along=w>=h?(double(i%w)+.5)/w:(double(i/w)+p[18]+.5)/h;
        if(along>=p[13]){s.highlight_knee=p[14];s.highlight_room=p[15];s.shadow_knee=p[16];s.shadow_room=p[17];}}
    return std::exp2(std::clamp(spk::slm::delta(std::log2(n/p[10]),s),-30.,30.));
}
void compare(const std::vector<float>& in,const std::vector<float>& out,const Params& p,double& max_rel) {
    for(size_t i=0;i<in.size()/3;++i){const double k=gain(in,i,p);
        for(size_t c=0;c<3;++c){const double want=double(in[3*i+c])*k,got=out[3*i+c];
            if(std::isnan(want)){check(std::isnan(got),"NaN signal was replaced");continue;}
            if(std::isinf(want)){check(got==want,"infinite signal was replaced");continue;}
            const double rel=std::abs(got-want)/std::max(1.,std::abs(want));max_rel=std::max(max_rel,rel);
            check(rel<=3e-5,"latitude differs from double oracle: "+std::to_string(rel));
            if(k==1.)check(out[3*i+c]==in[3*i+c],"identity core or disabled side changed pixels");
        }
    }
}
void api_tests(const char* resources) {
    std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)> engine(spk_engine_create(resources,nullptr),spk_engine_destroy);
    check(bool(engine),std::string("engine: ")+spk_last_error(nullptr));
    const uint32_t w=67,h=131;std::vector<float> input(size_t(w)*h*3);
    for(uint32_t y=0;y<h;++y)for(uint32_t x=0;x<w;++x)for(uint32_t c=0;c<3;++c)
        input[(size_t(y)*w+x)*3+c]=float(.184*std::exp2(-6.+12.*x/(w-1))*(1.-.15*c));
    spk_image image{input.data(),w,h,3};
    const char* quiet=R"({"grain_active":false,"glare_active":false,"halation_active":false,"dir_couplers_active":false,"auto_exposure":false,"input_cctf_decoding":false})";
    std::unique_ptr<spk_session,decltype(&spk_session_release)> session(spk_open(engine.get(),&image,quiet,nullptr),spk_session_release);
    check(bool(session),std::string("open: ")+spk_last_error(engine.get()));
    auto set=[&](const char* delta){const auto status=spk_set_params(session.get(),delta,nullptr);
        check(status==SPK_OK,std::string("set: ")+spk_last_error(engine.get()));};
    auto render=[&](bool* cached=nullptr,bool fresh=false){spk_result r{};
        const auto status=fresh?spk_render(session.get(),"full",&r):spk_reprint(session.get(),"full",&r);
        if(status!=SPK_OK){spk_result_free(&r);throw std::runtime_error(std::string("render: ")+spk_last_error(engine.get()));}
        check(r.rgba16&&r.width==w&&r.height==h,"latitude render changed dimensions");
        std::vector<uint16_t> p(r.rgba16,r.rgba16+size_t(w)*h*4);if(cached)*cached=r.negative_was_cached!=0;spk_result_free(&r);return p;};
    const auto original=render();
    set(R"({"scene_latitude_active":true,"scene_latitude_highlight_room":0,"scene_latitude_shadow_room":0})");
    check(render()==original,"active mapping with both branches off is not an exact bypass");
    set(R"({"scene_latitude_highlight_knee":1,"scene_latitude_highlight_room":2,"scene_latitude_shadow_knee":-1,"scene_latitude_shadow_room":2})");
    bool cached=true;const auto placed=render(&cached);check(!cached&&placed!=original,"scene mapping did not rebuild/change the negative");
    set(R"({"print_exposure":1.05})");render(&cached);check(cached,"reprinting a placed frame did not reuse its negative");
    set(R"({"scene_latitude_active":false,"print_exposure":1})");check(render()==original,"turning off placement did not restore deterministic pixels");
    set(R"({"scene_latitude_split":0.5,"scene_latitude_b_active":true,"scene_latitude_b_highlight_knee":1,"scene_latitude_b_highlight_room":2,"scene_latitude_b_shadow_knee":-1,"scene_latitude_b_shadow_room":2})");
    const auto pair=render();check(pair!=original,"second-frame-only placement was ignored");
    // The final default scanner unsharp (sigma .7) mixes a three-pixel
    // neighborhood across the physical pair boundary. Its halo is expected;
    // the numeric-node test above checks exact isolation all the way to it.
    for(uint32_t y=0;y<h/2-4;++y)for(size_t x=0;x<size_t(w)*4;++x)
        check(pair[size_t(y)*w*4+x]==original[size_t(y)*w*4+x],"second frame's curve changed first frame at row "+std::to_string(y)+" sample "+std::to_string(x)+" from "+std::to_string(original[size_t(y)*w*4+x])+" to "+std::to_string(pair[size_t(y)*w*4+x]));
    // A PRINT-layer execution switch intentionally preserves the negative.
    // Force a fresh render here so this comparison also executes the scene
    // mapping node through the striped film path.
    set(R"({"striped":true,"strip_rows":23})");check(render(nullptr,true)==pair,"striped pair placement differs from whole frame");
    char* before=nullptr;check(spk_get_params(session.get(),&before)==SPK_OK,"cannot capture params");const std::string state=before;spk_string_free(before);
    check(spk_set_params(session.get(),R"({"scene_latitude_norm":"invalid","print_exposure":1.25})",nullptr)==SPK_ERR_USER,"invalid latitude norm accepted");
    char* after=nullptr;check(spk_get_params(session.get(),&after)==SPK_OK,"cannot read params after refusal");const bool same=state==after;spk_string_free(after);check(same,"invalid latitude delta partially mutated params");
    std::puts("Scene latitude C API passed: exact bypass, shoot/print cache, B-only pair, whole/strip and refusal rollback");
}
}
int main(int argc,char** argv){try{
    check(argc==2||argc==3,"usage: spk_vulkan_scene_latitude resources_dir [--api]");
    if(argc==3){check(std::strcmp(argv[2],"--api")==0,"unknown test mode");api_tests(argv[1]);return 0;}
    std::string e;
    std::unique_ptr<spk::gpu::Gpu> gpu(spk::gpu::Gpu::create_vulkan(std::string(argv[1])+"/vulkan",e));check(bool(gpu),e);
    check(gpu->check_math_mode(e),e);double maximum=0;
    for(const auto shape:{std::array<uint32_t,2>{137,79},std::array<uint32_t,2>{79,137}}){
        const auto w=shape[0],h=shape[1];std::vector<float> input(size_t(w)*h*3);
        for(size_t i=0;i<input.size()/3;++i){const float x=float(.184*std::exp2(-26.+52.*double(i%257)/256));
            input[3*i]=x;input[3*i+1]=(i%5==0?-.2f:.7f)*x;input[3*i+2]=.3f*x;}
        // Zero/negative, infinity and all-NaN norms use the identity gain.
        std::fill_n(input.begin(),3,0.f);std::fill_n(input.begin()+3,3,-1.f);
        std::fill_n(input.begin()+6,3,std::numeric_limits<float>::infinity());
        std::fill_n(input.begin()+9,3,std::numeric_limits<float>::quiet_NaN());
        for(float norm:{0.f,1.f,2.f})for(float rolloff:{1.f,2.f,3.25f})for(int mode=0;mode<4;++mode){
            Params p{2,3,-2,2,rolloff,6,norm,.2126f,.7152f,.0722f,.184f,float(w),float(h),.5f,1,2,-1,1,0};
            if(mode==1)p[1]=p[3]=0; // only the second frame is active
            if(mode==2)p[15]=p[17]=0; // only the first frame is active
            if(mode==3)p[1]=p[3]=p[15]=p[17]=0;
            const auto whole=run(gpu.get(),input,p);compare(input,whole,p,maximum);
            const uint32_t first=h/2-3,rows=11;
            std::vector<float> strip(input.begin()+size_t(first)*w*3,input.begin()+size_t(first+rows)*w*3);
            p[18]=float(first);const auto out=run(gpu.get(),strip,p);compare(strip,out,p,maximum);
            for(size_t i=0;i<out.size();++i)check(out[i]==whole[size_t(first)*w*3+i],"pair placement changed across strip boundary");
        }
    }
    std::printf("Scene latitude passed 72 full/strip cases, 3 norms, 3 rolloffs, max relative error %.9g\n",maximum);
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
