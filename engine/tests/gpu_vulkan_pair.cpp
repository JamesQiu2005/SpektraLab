#include "spektrafilm/spk_engine.h"
#include "pipeline/view.hpp"
#include <cstdio>
#include <cmath>
#include <memory>
#include <stdexcept>
#include <vector>
namespace {
using spk::Json;using spk::view::Request;using spk::view::Result;
void check(bool ok,const std::string& why){if(!ok)throw std::runtime_error(why);}
Json json(const char* s){Json j;std::string e;check(Json::parse(s,j,e),e);return j;}
Result render(spk_session* s,const Request& q){Result r;std::string e;check(spk::view::render(s,q,r,e),e);return r;}
std::string params(spk_session* s){char* p=nullptr;check(spk_get_params(s,&p)==SPK_OK&&p,"get_params failed");std::string t=p;spk_string_free(p);return t;}
void same_pixel(const Result& a,const Result& b,unsigned x,unsigned y){
 check(a.width==b.width&&a.height==b.height,"layer dimensions differ");
 for(unsigned c=0;c<4;++c)check(a.pixels[(y*a.width+x)*4+c]==b.pixels[(y*b.width+x)*4+c],"pair layer differs from independently graded/reprinted frame");
}
}
int main(int argc,char** argv){try{
 check(argc==2,"usage: spk_vulkan_pair resources");
 std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)> e(spk_engine_create(argv[1],nullptr),spk_engine_destroy);
 check(bool(e),spk_last_error(nullptr));constexpr unsigned w=148,h=96;
 std::vector<float> input(w*h*3);for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x)for(unsigned c=0;c<3;++c)input[(y*w+x)*3+c]=.03f+.4f*x/w+.2f*y/h+.02f*c;
 const spk_image image{input.data(),w,h,3};
 const auto p=json(R"({"output_color_space":"ProPhoto RGB","output_cctf_encoding":true,"input_color_space":"sRGB","input_cctf_decoding":false,"grain_active":false,"halation_active":false,"glare_active":false,"auto_exposure":false})");
 auto open=[&](const Json& values){return std::unique_ptr<spk_session,decltype(&spk_session_release)>(spk_open(e.get(),&image,values.dump().c_str(),nullptr),spk_session_release);};
 auto session=open(p);check(bool(session),spk_last_error(e.get()));Request q;q.adjustments=json(R"({"exposure":0.2,"saturation":10})");
 const auto base=render(session.get(),q);const auto original=params(session.get());
 Request layered=q;layered.pair=json(R"({"gates":[[0,0,0.4864864865,1],[0.5135135135,0,1,1]],"left":{"print":{"brightnessStops":0.7,"yFilterShift":0.1,"mFilterShift":-0.1,"preflashExposure":0.02},"adjustments":{"exposure":-0.3,"saturation":-35}},"right":{"adjustments":{"contrast":20,"brightness":5}}})");
 const auto composite=render(session.get(),layered);check(composite.print_cached,"pair layer discarded base print cache");
 auto left_params=p;left_params.set("print_exposure",Json(std::pow(2.,-.7)));left_params.set("y_filter_shift",Json(.1));left_params.set("m_filter_shift",Json(-.1));left_params.set("preflash_exposure",Json(.02));
 auto left=open(left_params);check(bool(left),spk_last_error(e.get()));Request lq=q;lq.adjustments=layered.pair.at("left").at("adjustments");
 const auto want_left=render(left.get(),lq);Request rq=q;rq.adjustments=layered.pair.at("right").at("adjustments");const auto want_right=render(session.get(),rq);
 for(unsigned y=5;y<h-5;y+=9){same_pixel(composite,want_left,25,y);same_pixel(composite,want_right,120,y);same_pixel(composite,base,74,y);}
 check(params(session.get())==original,"pair layer changed frozen session params");
 check(render(session.get(),q).pixels==base.pixels,"pair layer replaced cached base print");
 const auto repeated=render(session.get(),layered);check(repeated.pixels==composite.pixels,"deterministic pair reprint changed pixels");
 Request bad=layered;auto hole=bad.pair.at("left");hole.set("adjustments",json(R"({"exposure":1000})"));bad.pair.set("left",hole);Result ignored;std::string error;
 check(!spk::view::render(session.get(),bad,ignored,error),"invalid side grade accepted");
 check(params(session.get())==original&&render(session.get(),q).pixels==base.pixels,"failed side grade left a live print delta applied");
 spk_result raw{};check(spk_reprint(session.get(),"full",&raw)==SPK_OK&&raw.negative_was_cached,"pair layers regenerated cached negative");spk_result_free(&raw);
 // Native physical gate rectangles must replace source-composition rectangles
 // once a film border has changed the canvas, in either orientation.
 for(bool turned:{false,true}) {
     spk_image pair_image{input.data(),turned?h:w,turned?w:h,3};
     auto physical=p;physical.set("overscan_active",Json(true));physical.set("overscan_pair",Json(true));
     physical.set("overscan_format",Json(std::string("135_half")));
     auto physical_open=[&](const Json& values){return std::unique_ptr<spk_session,decltype(&spk_session_release)>(spk_open(e.get(),&pair_image,values.dump().c_str(),nullptr),spk_session_release);};
     auto ps=physical_open(physical);check(bool(ps),spk_last_error(e.get()));
     const auto pb=render(ps.get(),q);Request pq=layered;pq.pair.set("turned",Json(turned));
     const auto pc=render(ps.get(),pq);char* layout=nullptr;
     check(spk_overscan_geometry(ps.get(),&layout)==SPK_OK&&layout,"native pair gates unavailable");const auto gates=json(layout).at("gates");spk_string_free(layout);
     auto pp=physical;for(const auto& kv:left_params.fields())if(kv.first=="print_exposure"||kv.first=="y_filter_shift"||kv.first=="m_filter_shift"||kv.first=="preflash_exposure")pp.set(kv.first,kv.second);
     auto pl=physical_open(pp);check(bool(pl),spk_last_error(e.get()));const auto wl=render(pl.get(),lq);const auto wr=render(ps.get(),rq);
     for(size_t side=0;side<2;++side){double x=0,y=0;const auto& quad=gates.items()[side].items();for(size_t k=0;k<8;k+=2){x+=quad[k].as_double()/4;y+=quad[k+1].as_double()/4;}
         same_pixel(pc,side?wr:wl,unsigned(x*pc.width),unsigned(y*pc.height));}
     check(render(ps.get(),q).pixels==pb.pixels,"physical pair layering changed cached base");
 }
 std::puts("Pair layers passed independent side reprint/grade, gap isolation, cache retention, deterministic reuse and failure restoration");return 0;
}catch(const std::exception& ex){std::fprintf(stderr,"%s\n",ex.what());return 1;}}
