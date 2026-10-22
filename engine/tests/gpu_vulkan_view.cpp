// Desktop postprocess: exhaustive UNORM16 identity, independent numeric
// oracles, geometry orientation, and the actual session cache contract.
#include "pipeline/view_process.hpp"
#include "core/colour.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <memory>
#include <optional>
#include <stdexcept>
#ifdef _WIN32
#include <process.h>
#endif

using namespace spk;
namespace {
void check(bool ok,const std::string& why){if(!ok)throw std::runtime_error(why);}
Json json(const char* s){Json v;std::string e;check(Json::parse(s,v,e),e);return v;}
uint16_t value(const view::Result& r,size_t i){return uint16_t(r.pixels[2*i])|uint16_t(r.pixels[2*i+1])<<8;}
uint16_t quant(double x){return uint16_t(std::lround(std::clamp(x,0.,1.)*65535));}
void check_rgb(gpu::Gpu* gpu,const Image& packed,view::Request q,const Json& transform,const view::Result& rgba){
 std::string e;q.output_channels=3;
 for(bool sixteen:{true,false}){
  q.rgba16=sixteen;view::Result rgb;check(view::process(gpu,packed,q,transform,nullptr,0,rgb,e),e);
  const size_t n=size_t(rgba.width)*rgba.height;
  check(rgb.width==rgba.width&&rgb.height==rgba.height&&rgb.pixels.size()==n*3*(sixteen?2:1),"RGB packing exposed padding or changed dimensions");
  for(size_t p=0;p<n;++p)for(size_t c=0;c<3;++c){
   const uint16_t expected=value(rgba,p*4+c);
   if(sixteen)check(value(rgb,p*3+c)==expected,"RGB16 differs from RGBA16 with alpha removed");
   else check(rgb.pixels[p*3+c]==uint8_t((uint32_t(expected)*255u+32767u)/65535u),"RGB8 differs from exact RGBA16-to-8 rounding");
  }
 }
}
void cineon_tests(const std::string& resources){
 std::string e;std::unique_ptr<gpu::Gpu> gpu(gpu::Gpu::create_vulkan(resources+"/vulkan",e));check(bool(gpu),e);
 constexpr uint32_t n=1024;std::vector<float> input(n*3),actual(n*3);std::array<float,42> p{};
 for(unsigned c=0;c<3;++c){p[3*c+c]=1;p[12+3*c+c]=1;p[21+3*c+c]=1;}
 p[9]=.1f;p[10]=-.05f;p[11]=.03f;p[31]=-17;p[32]=.78f;p[33]=280;p[34]=55;p[35]=.02f;p[36]=.08f;
 p[37]=685;p[38]=300;p[39]=1023;p[40]=.002f;p[41]=float(std::pow(10.,(95.-685)/300));
 for(unsigned i=0;i<n;++i)for(unsigned c=0;c<3;++c)input[3*i+c]=-4.f+float((i*(37+19*c))%1024)*7.f/1023;
 auto source=gpu->upload(input.data(),input.size()*4,e),out=gpu->alloc(input.size()*4,e);check(source&&out,e);
 size_t changed=0;
 for(bool compensate:{false,true}){
  p[30]=compensate?1.f:0.f;auto uniforms=gpu->upload(p.data(),sizeof(p),e);check(bool(uniforms),e);
  check(gpu->dispatch("spk_di_encode",{gpu::Arg::buf(source),gpu::Arg::buf(uniforms),gpu::Arg::inline_bytes(&n,1),gpu::Arg::buf(out)},n,e)&&gpu->flush(e)&&gpu->read(out.get(),0,actual.data(),actual.size()*4,e),e);
  for(unsigned i=0;i<n;++i){
   std::array<double,3> linear{},lms{};
   for(unsigned c=0;c<3;++c)linear[c]=(std::pow(10.,double(input[3*i+c]))-p[40])*std::pow(10.,p[9+c]);
   if(compensate){
    for(unsigned c=0;c<3;++c)lms[c]=std::cbrt(std::max(0.,linear[c]));
    double L=.2104542553*lms[0]+.793617785*lms[1]-.0040720468*lms[2];
    double a=1.9779984951*lms[0]-2.428592205*lms[1]+.4505937099*lms[2];
    double b=.0259040371*lms[0]+.7827717662*lms[1]-.808675766*lms[2];
    double C=std::hypot(a,b),h=std::atan2(b,a)*180/3.141592653589793,d=std::fmod(h-p[33]+540,360)-180;
    double w=std::abs(d)<p[34]?(1+std::cos(3.141592653589793*d/p[34]))*.5:0;
    double g=std::clamp((C-p[35])/(p[36]-p[35]),0.,1.);w*=g*g*(3-2*g);
    if(w>0){++changed;double h2=(h+w*p[31])*3.141592653589793/180,C2=C*(1+w*(p[32]-1));a=C2*std::cos(h2);b=C2*std::sin(h2);
     linear={L+.3963377774*a+.2158037573*b,L-.1055613458*a-.0638541728*b,L-.0894841775*a-1.291485548*b};
     for(auto& v:linear)v=v*v*v;
    }
   }
   for(unsigned c=0;c<3;++c){double expected=std::clamp((685+300*std::log10(std::max(0.,linear[c])*(1-p[41])+p[41]))/1023,0.,1.);
    check(std::abs(actual[3*i+c]-expected)<2e-5,"Cineon shader differs from double precision scalar reference");}
  }
 }
 check(changed>20,"Cineon test failed to exercise blue-sector compensation");source.reset();out.reset();gpu.reset();
 using Engine=std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)>;using Session=std::unique_ptr<spk_session,decltype(&spk_session_release)>;
 Engine engine(spk_engine_create(resources.c_str(),nullptr),spk_engine_destroy);check(bool(engine),spk_last_error(nullptr));
 std::vector<float> pixels(17*11*3);for(size_t i=0;i<pixels.size();++i)pixels[i]=.015f+float(i%73)/97;
 spk_image image{pixels.data(),17,11,3};Session s(spk_open(engine.get(),&image,"{\"grain_active\":false,\"halation_active\":false,\"glare_active\":false,\"auto_exposure\":false}",nullptr),spk_session_release);check(bool(s),spk_last_error(engine.get()));
 view::Request q;q.target_space="ProPhoto RGB";q.rgba16=true;q.output_channels=3;view::Result before,after,raw;
 check(view::render(s.get(),q,before,e),e);q.cineon=true;q.adjustments=json("{\"exposure\":4,\"saturation\":80}");check(view::render(s.get(),q,raw,e),e);
 spk_result c{};char* meta=nullptr;check(spk_render_digital_intermediate(s.get(),&c,&meta)==SPK_OK,spk_last_error(engine.get()));
 check(c.width==raw.width&&c.height==raw.height&&raw.preview_width&&raw.preview_height,"DI dimensions/preview missing");
 for(unsigned y=0;y<c.height;++y)for(unsigned x=0;x<c.width;++x)for(unsigned k=0;k<3;++k)
  check(c.rgba16[(size_t(y)*c.row_stride_px+x)*4+k]==value(raw,(size_t(y)*c.width+x)*3+k),"direct Cineon export differs from C API or included Post-Dev");
 spk_result_free(&c);spk_string_free(meta);
 q.cineon=false;q.adjustments=Json::object();check(view::render(s.get(),q,after,e)&&after.print_cached&&after.pixels==before.pixels,"DI export changed editor print");
 check(spk_set_params(s.get(),"{\"digital_intermediate\":true}",nullptr)==SPK_OK,spk_last_error(engine.get()));
 check(view::render(s.get(),q,after,e),e);check(after.pixels!=raw.pixels,"DI canvas displayed raw log without shipped view LUT");
 std::ifstream cube(std::filesystem::path(resources)/"DI"/"SpektraLab DI view, Cineon to ProPhoto RGB.cube");std::string line;std::vector<std::array<double,3>> lut;
 while(std::getline(cube,line)){std::istringstream row(line);std::array<double,3> v;if(!(row>>v[0]>>v[1]>>v[2]))continue;
  for(auto& x:v){int exp;std::frexp(x,&exp);double step=std::ldexp(1.,std::max(-24,exp-11));x=std::nearbyint(x/step)*step;}lut.push_back(v);}
 check(lut.size()==65*65*65,"test could not load shipped DI cube");
 for(unsigned i=0;i<raw.width*raw.height;++i){unsigned lower[3];double fraction[3];
  for(unsigned c=0;c<3;++c){double coordinate=double(value(raw,3*i+c))/65535*64;lower[c]=unsigned(std::floor(coordinate));fraction[c]=coordinate-lower[c];}
  for(unsigned c=0;c<3;++c){double expected=0;
   for(unsigned corner=0;corner<8;++corner){unsigned ix[3];double weight=1;
    for(unsigned axis=0;axis<3;++axis){bool high=(corner>>axis)&1;ix[axis]=std::min(64u,lower[axis]+unsigned(high));weight*=high?fraction[axis]:1-fraction[axis];}
    expected+=lut[(ix[2]*65+ix[1])*65+ix[0]][c]*weight;}
   check(std::abs(int(value(after,3*i+c))-int(quant(expected)))<=2,"DI view differs from independently interpolated shipped half-float cube");
  }
 }
 std::puts("Cineon shader: 2048 reference pixels, blue compensation, dedicated raw codes, unmodified editor cache and DI view passed");
}
void process_tests(const std::string& resources){
 std::string e;std::unique_ptr<gpu::Gpu> gpu(gpu::Gpu::create_vulkan(resources+"/vulkan",e));check(bool(gpu),e);
 const uint32_t W=256,H=256;std::vector<uint16_t> px(size_t(W)*H*4);
 for(uint32_t i=0;i<W*H;++i){px[4*i]=uint16_t(i);px[4*i+1]=uint16_t(65535-i);px[4*i+2]=uint16_t((i*7919u)&65535u);px[4*i+3]=65535;}
 Image packed;packed.w=W;packed.h=H;packed.c=2;packed.buf=gpu->upload_persistent(px.data(),px.size()*2,e);check(bool(packed.buf),e);
 Json identity=json("{\"source_color_space\":\"ProPhoto RGB\",\"target_color_space\":\"ProPhoto RGB\"}");
 view::Request q;q.rgba16=true;q.target_space="ProPhoto RGB";view::Result r;
 check(view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),e);
 check(r.pixels.size()==px.size()*2&&std::memcmp(r.pixels.data(),px.data(),r.pixels.size())==0,"all 65536 code values must survive neutral processing exactly");
 check_rgb(gpu.get(),packed,q,identity,r);
 // RGB8/RGB16 end mid-word for odd pixel counts; test every byte-tail class
 // and ensure the last live channel survives while padding remains private.
 for(uint32_t n:{1u,2u,3u,5u,7u,257u}){
  Image tiny; tiny.w=n;tiny.h=1;tiny.c=2;tiny.buf=gpu->upload_persistent(px.data(),size_t(n)*8,e);check(bool(tiny.buf),e);
  view::Result base;check(view::process(gpu.get(),tiny,q,identity,nullptr,0,base,e),e);
  check_rgb(gpu.get(),tiny,q,identity,base);
 }
 q.output_channels=2;check(!view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),"unsupported output channel count accepted");q.output_channels=4;
 q.adjustments=json("{\"exposure\":1}");
 check(view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),e);
 int maxerr=0;
 for(size_t i=0;i<px.size();++i)if(i%4!=3){double x=double(px[i])/65535;auto want=quant(std::pow(std::pow(x,2.2)*2,1/2.2));maxerr=std::max(maxerr,std::abs(int(value(r,i))-want));}
 check(maxerr<=3,"ProPhoto exposure CPU oracle exceeds 3 UNORM16 codes: "+std::to_string(maxerr));
 q.adjustments=json("{\"curves\":{\"rgb\":{\"points\":[[0,0.1],[1,0.9]]}}}");
 check(view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),e);maxerr=0;
 for(size_t i=0;i<px.size();++i)if(i%4!=3)maxerr=std::max(maxerr,std::abs(int(value(r,i))-quant(.1+.8*double(px[i])/65535)));
 check(maxerr<=2,"curve LUT interpolation exceeds 2 UNORM16 codes");
 q.adjustments=Json::object();q.geometry=json("{\"quarterTurns\":1}");
 check(view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),e);
 for(uint32_t y=0;y<H;++y)for(uint32_t x=0;x<W;++x)for(uint32_t c=0;c<4;++c)
   check(value(r,(y*W+x)*4+c)==px[((H-1-x)*W+y)*4+c],"quarter turn must preserve each source code");
 q.geometry=json("{\"crop\":{\"x\":0.25,\"y\":0,\"width\":0.5,\"height\":1}}");q.long_edge=128;
 check(view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),e);check(r.width==64&&r.height==128,"crop dimensions must precede long-edge resize");
 q.geometry=json("{\"crop\":{\"x\":0.9,\"width\":0.5}}");
 check(!view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),"invalid crop accepted");
 q.geometry=Json::object();q.long_edge=0;q.adjustments=json("{\"curves\":{\"red\":{\"points\":[[0.5,0],[0.4,1]]}}}");
 check(!view::process(gpu.get(),packed,q,identity,nullptr,0,r,e),"unordered curve accepted");
 q.adjustments=Json::object();
 Json transfer=json("{\"source_color_space\":\"ProPhoto RGB\",\"target_color_space\":\"sRGB\",\"source_cctf_mode\":1,\"target_cctf_mode\":0,\"matrix\":[1,0,0,0,1,0,0,0,1]}");
 check(view::process(gpu.get(),packed,q,transfer,nullptr,0,r,e),e);maxerr=0;
 for(size_t i=0;i<px.size();++i)if(i%4!=3){double x=double(px[i])/65535;double l=x<.03125?x/16:std::pow(x,1.8);double enc=l<=.0031308?12.92*l:1.055*std::pow(l,1/2.4)-.055;maxerr=std::max(maxerr,std::abs(int(value(r,i))-quant(enc)));}
 check(maxerr<=3,"GPU transfer functions differ from independent CPU oracle");
 transfer.set("matrix",json("[0,1,0,0,0,1,1,0,0]"));
 check(view::process(gpu.get(),packed,q,transfer,nullptr,0,r,e),e);maxerr=0;
 for(size_t i=0;i<px.size();++i)if(i%4!=3){size_t input=i-i%4+(i%4+1)%3;double x=double(px[input])/65535;double l=x<.03125?x/16:std::pow(x,1.8);double enc=l<=.0031308?12.92*l:1.055*std::pow(l,1/2.4)-.055;maxerr=std::max(maxerr,std::abs(int(value(r,i))-quant(enc)));}
 check(maxerr<=3,"asymmetric RGB transform matrix was transposed");
 check_rgb(gpu.get(),packed,q,transfer,r);
 q.adjustments=json("{\"exposure\":0.7,\"contrast\":13,\"saturation\":-27}");
 q.geometry=json("{\"crop\":{\"x\":0.2,\"y\":0.1,\"width\":0.6,\"height\":0.7},\"quarterTurns\":1}");q.long_edge=73;
 check(view::process(gpu.get(),packed,q,transfer,nullptr,0,r,e),e);
 check_rgb(gpu.get(),packed,q,transfer,r);
 std::puts("view pixels: exhaustive identity/RGB8/RGB16 packing, odd tails, grade, curves, geometry, validation, transfer passed");
}
void cache_tests(const std::string& resources){
 using Engine=std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)>;Engine engine(spk_engine_create(resources.c_str(),nullptr),spk_engine_destroy);check(bool(engine),spk_last_error(nullptr));
 std::vector<float> px(32*24*3);for(size_t i=0;i<px.size();++i)px[i]=float(.01+.5*double(i%211)/211);
 spk_image image{px.data(),32,24,3};using Session=std::unique_ptr<spk_session,decltype(&spk_session_release)>;
 Session s(spk_open(engine.get(),&image,"{\"grain_active\":false,\"halation_active\":false,\"glare_active\":false,\"auto_exposure\":false}",nullptr),spk_session_release);check(bool(s),spk_last_error(engine.get()));
 view::Request q;q.rgba16=true;q.target_space="ProPhoto RGB";view::Result first,second;std::string e;
 check(view::render(s.get(),q,first,e),e);check(!first.print_cached,"first view unexpectedly cached");
 check(view::render(s.get(),q,second,e),e);check(second.print_cached&&first.pixels==second.pixels,"repeat did not preserve cached print");
 // Cold display switches must not build the export-only CAM16 tables.
 // Check the actual cache count rather than a hardware-dependent time limit.
 auto cam16_count=[&](){return json(spk_capabilities(engine.get())).at("backend").at("session_cache").at("setup_cam16").as_int();};
 const int tables_before=cam16_count();
 view::Result display[2];const char* spaces[]={"sRGB","Display P3"};
 for(size_t i=0;i<2;++i){q.target_space=spaces[i];check(view::render(s.get(),q,display[i],e),e);check(display[i].print_cached,"display switch redeveloped film");}
 check(cam16_count()==tables_before,"preview created an unused CAM16 setup table");
 // The lightweight metadata must yield exactly the old public off transform.
 // This separate upload is test-only; production keeps the source on its GPU.
 std::unique_ptr<gpu::Gpu> reference_gpu(gpu::Gpu::create_vulkan(resources+"/vulkan",e));check(bool(reference_gpu),e);
 Image packed;packed.w=first.width;packed.h=first.height;packed.c=2;
 packed.buf=reference_gpu->upload_persistent(first.pixels.data(),first.pixels.size(),e);check(bool(packed.buf),e);
 for(size_t i=0;i<2;++i){
  char* text=nullptr;const float* cmax=nullptr;uint32_t count=0;
  check(spk_output_transform(engine.get(),"ProPhoto RGB",spaces[i],"{\"algorithm\":\"off\"}",&text,&cmax,&count)==SPK_OK,spk_last_error(engine.get()));
  Json transform=json(text);spk_string_free(text);check(cmax&&count>0,"public off transform no longer supplies its promised CAM16 table");
  q.target_space=spaces[i];view::Result reference;
  check(view::process(reference_gpu.get(),packed,q,transform,cmax,count,reference,e),e);
  check(reference.pixels==display[i].pixels,"lightweight display transform differs from public off transform");
 }
 q.target_space="ProPhoto RGB";
 q.adjustments=json("{\"exposure\":0.5}");check(view::render(s.get(),q,second,e),e);check(second.print_cached&&first.pixels!=second.pixels,"grade should reuse print but alter pixels");
 q.adjustments=Json::object();spk_result legacy{};check(spk_reprint(s.get(),"full",&legacy)==SPK_OK,spk_last_error(engine.get()));
 check(view::render(s.get(),q,second,e),e);check(!second.print_cached,"legacy rendering did not invalidate view cache");
 check(second.pixels.size()==size_t(legacy.width)*legacy.height*8,"legacy dimensions differ");
 check(std::memcmp(second.pixels.data(),legacy.rgba16,second.pixels.size())==0,"neutral view differs from existing RGBA16 engine result");spk_result_free(&legacy);
 check(spk_set_params(s.get(),"{\"print_exposure\":0.5}",nullptr)==SPK_OK,spk_last_error(engine.get()));
 check(view::render(s.get(),q,second,e),e);check(!second.print_cached,"engine parameter change retained stale print");
 s.reset();engine.reset();check(!first.pixels.empty(),"CPU result lifetime lost");
 std::puts("view cache: reuse, display without CAM16 setup, exact public-transform parity, grade, legacy invalidation, byte parity, parameter invalidation and ownership passed");
}

void proof_tests(const std::string& resources){
 using Engine=std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)>;Engine engine(spk_engine_create(resources.c_str(),nullptr),spk_engine_destroy);check(bool(engine),spk_last_error(nullptr));
 std::vector<float> px(37*29*3);for(size_t i=0;i<px.size();++i)px[i]=float(.001+.9*double((i*71)%251)/251);
 spk_image image{px.data(),37,29,3};using Session=std::unique_ptr<spk_session,decltype(&spk_session_release)>;
 Session s(spk_open(engine.get(),&image,"{\"grain_active\":false,\"halation_active\":false,\"glare_active\":false,\"auto_exposure\":false}",nullptr),spk_session_release);check(bool(s),spk_last_error(engine.get()));
 std::string e;Blob blob;Colour colour;check(blob.open(resources+"/spektrafilm_constants.bin",e)&&colour.init(blob,e),e);
 for(const char* space:{"sRGB","Display P3","ProPhoto RGB","Adobe RGB (1998)","ITU-R BT.2020"})for(bool sixteen:{false,true}){
  view::Request q;q.export_intent=true;q.output_channels=3;q.rgba16=sixteen;q.target_space=space;q.long_edge=23;
  q.adjustments=json("{\"exposure\":0.7,\"saturation\":35}");q.geometry=json("{\"quarterTurns\":1,\"crop\":{\"x\":0.1,\"y\":0.1,\"width\":0.8,\"height\":0.8}}");
  view::Result file,proof,repeat;check(view::render(s.get(),q,file,e),e);
  q.proof_long_edge=11;q.proof_display="sRGB";check(view::render(s.get(),q,proof,e),e);
  check(proof.print_cached&&proof.file_width==file.width&&proof.file_height==file.height,"proof changed full-tier film or recipe dimensions");
  check(std::max(proof.width,proof.height)==11&&proof.pixels.size()==size_t(proof.width)*proof.height*4,"proof exposed full-file pixel payload");
  check(proof.moved_pixels>=proof.outside_pixels&&proof.moved_pixels<=file.width*file.height&&proof.clipped_pixels<=file.width*file.height,"invalid full-file gamut statistics");
  Mat3 matrix;check(colour.matrix_RGB_to_RGB(space,"sRGB","CAT02",matrix,e),e);double m[9];matrix.to_row_major(m);
  auto sample=[&](uint32_t x,uint32_t y,int c){size_t i=(size_t(y)*file.width+x)*3+c;return sixteen?double(value(file,i))/65535:double(file.pixels[i])/255;};
  int worst=0;
  for(uint32_t y=0;y<proof.height;++y)for(uint32_t x=0;x<proof.width;++x){
   double fx=std::clamp((x+.5)*file.width/proof.width-.5,0.,double(file.width-1)),fy=std::clamp((y+.5)*file.height/proof.height-.5,0.,double(file.height-1));
   uint32_t x0=uint32_t(fx),y0=uint32_t(fy),x1=std::min(x0+1,file.width-1),y1=std::min(y0+1,file.height-1);double tx=fx-x0,ty=fy-y0,enc[3],linear[3];
   for(int c=0;c<3;++c){enc[c]=double(quant((sample(x0,y0,c)*(1-tx)+sample(x1,y0,c)*tx)*(1-ty)+(sample(x0,y1,c)*(1-tx)+sample(x1,y1,c)*tx)*ty))/65535;linear[c]=colour.cctf_decode(enc[c],space);}
   for(int c=0;c<3;++c){double out=std::string(space)=="sRGB"?enc[c]:colour.cctf_encode(m[c*3]*linear[0]+m[c*3+1]*linear[1]+m[c*3+2]*linear[2],"sRGB");
    auto expected=uint8_t((uint32_t(quant(out))*255+32767)/65535);worst=std::max(worst,std::abs(int(expected)-int(proof.pixels[(y*proof.width+x)*4+c])));}
  }
  check(worst<=2,std::string("proof differs from actual file pixel CPU oracle in ")+space+": "+std::to_string(worst));
  check(view::render(s.get(),q,repeat,e)&&repeat.pixels==proof.pixels&&repeat.moved_pixels==proof.moved_pixels&&repeat.outside_pixels==proof.outside_pixels,"repeat proof changed cached file or stats");
  q.proof_long_edge=7;check(view::render(s.get(),q,repeat,e),e);
  check(repeat.moved_pixels==proof.moved_pixels&&repeat.outside_pixels==proof.outside_pixels&&repeat.clipped_pixels==proof.clipped_pixels,"stats measured proof pixels instead of file pixels");
 }
 // A direct process oracle locks down export's lightness-disabled contract,
 // including same-space ProPhoto's chroma knee, separately from host proofing.
 view::Request neutral;neutral.rgba16=true;neutral.target_space="ProPhoto RGB";view::Result original;
 check(view::render(s.get(),neutral,original,e),e);
 std::unique_ptr<gpu::Gpu> gpu(gpu::Gpu::create_vulkan(resources+"/vulkan",e));check(bool(gpu),e);
 Image packed;packed.w=original.width;packed.h=original.height;packed.c=2;packed.buf=gpu->upload_persistent(original.pixels.data(),original.pixels.size(),e);check(bool(packed.buf),e);
 for(const char* space:{"sRGB","ProPhoto RGB"}){
  char* text=nullptr;const float* cmax=nullptr;uint32_t n=0;
  check(spk_output_transform(engine.get(),"ProPhoto RGB",space,"{\"lightness_compression_active\":false}",&text,&cmax,&n)==SPK_OK,spk_last_error(engine.get()));Json transform=json(text);spk_string_free(text);
  view::Request q;q.rgba16=true;q.export_intent=true;q.target_space=space;view::Result reference,actual;
  check(view::process(gpu.get(),packed,q,transform,cmax,n,reference,e),e);check(view::render(s.get(),q,actual,e),e);
  check(actual.pixels==reference.pixels,"export applied a second lightness shoulder or skipped same-space chroma mapping");
 }
 std::puts("proof: five spaces, 8/16-bit actual-file CPU oracle, crop/resize order, tiny payload, cache, full-file stats and Mac export transform passed");
}

struct ScopedEnvironment {
 std::string name; std::optional<std::string> previous;
 ScopedEnvironment(const char* key,const std::string& value):name(key){
  if(const char* p=std::getenv(key))previous=p;
  set(value.c_str());
 }
 void set(const char* value){
#ifdef _WIN32
  _putenv_s(name.c_str(),value?value:"");
#else
  if(value)setenv(name.c_str(),value,1);else unsetenv(name.c_str());
#endif
 }
 ~ScopedEnvironment(){set(previous?previous->c_str():nullptr);}
};

size_t residency_files(){
#ifdef _WIN32
 const std::string prefix="spektralab-residency-"+std::to_string(_getpid())+"-";
 size_t n=0;
 for(const auto& entry:std::filesystem::directory_iterator(std::filesystem::temp_directory_path()))
  if(entry.path().filename().string().starts_with(prefix))++n;
 return n;
#else
 // tmpfile() unlinks immediately on POSIX; closure still owns its lifetime.
 return 0;
#endif
}

void residency_tests(const std::string& resources){
 using Engine=std::unique_ptr<spk_engine,decltype(&spk_engine_destroy)>;
 using Session=std::unique_ptr<spk_session,decltype(&spk_session_release)>;
 Engine engine(spk_engine_create(resources.c_str(),nullptr),spk_engine_destroy);check(bool(engine),spk_last_error(nullptr));
 const uint32_t w=960,h=640;std::vector<float> px(size_t(w)*h*3);
 for(size_t i=0;i<px.size();++i)px[i]=float(.02+.7*double((i*313)%997)/997);
 spk_image image{px.data(),w,h,3};
 // Keep the default random effects enabled: regeneration cannot satisfy the
 // byte comparison merely because the material parameters stayed identical.
 const char* params="{\"auto_exposure\":false,\"preview_long_edge\":800}";
 Session s(spk_open(engine.get(),&image,params,nullptr),spk_session_release);check(bool(s),spk_last_error(engine.get()));
 std::string e;view::Request q;q.rgba16=true;q.target_space="ProPhoto RGB";
 view::Result full_before,live_before,after;
 check(view::render(s.get(),q,full_before,e),e);q.tier="live";
 check(view::render(s.get(),q,live_before,e),e);
 auto ledger=[&](){return json(spk_memory_report(engine.get()));};
 const auto resident=ledger();
 const auto gpu_before=resident.at("persistent").at("bytes").as_double();
 const auto files_before=residency_files();
 // A mid-write error must leave all original GPU holdings and cached pixels.
 {
  ScopedEnvironment fail("SPK_TEST_RESIDENCY_FAILURE","write");
  check(!view::suspend(s.get(),e),"injected temporary-file write unexpectedly succeeded");
 }
 check(!view::suspended(s.get()),"failed suspend removed resident session");
 check(ledger().at("persistent").at("bytes").as_double()==gpu_before,"failed suspend leaked or dropped GPU data");
 check(residency_files()==files_before,"failed suspend leaked temporary file");
 check(view::render(s.get(),q,after,e)&&after.print_cached&&after.pixels==live_before.pixels,"failed suspend changed cached print");
#ifdef _WIN32
 {
  const auto missing=std::filesystem::temp_directory_path()/"spektralab-nonexistent-residency-test"/"missing";
  ScopedEnvironment temp("TMP",missing.string());
  check(!view::suspend(s.get(),e),"invalid temporary directory accepted");
 }
 check(!view::suspended(s.get())&&residency_files()==files_before,"temporary-directory failure damaged session");
#endif
 check(view::suspend(s.get(),e),e);check(view::suspend(s.get(),e),"suspend is not idempotent");
 check(view::suspended(s.get()),"suspended state not recorded");
 const auto on_disk=ledger();
 check(on_disk.at("suspended_bytes").as_double()>0,"disk bytes absent from memory ledger");
 check(on_disk.at("persistent").at("source_bytes").as_double()==0&&
       on_disk.at("persistent").at("cached_negative_bytes").as_double()==0&&
       on_disk.at("persistent").at("cached_view_bytes").as_double()==0,"image GPU references survived suspension");
 const auto gpu_suspended=on_disk.at("persistent").at("bytes").as_double();
 check(gpu_before-gpu_suspended==on_disk.at("suspended_bytes").as_double(),"source/full-tier alias duplicated or disk bytes counted as GPU bytes");
#ifdef _WIN32
 check(residency_files()==files_before+1,"suspend did not own exactly one temporary file");
#endif
 // A partial restore allocates/uploads one plane, then fails. It must free
 // those GPU allocations and leave the only exact snapshot available to retry.
 {
  ScopedEnvironment fail("SPK_TEST_RESIDENCY_FAILURE","read");
  check(!view::resume(s.get(),e),"injected restore read unexpectedly succeeded");
 }
 check(view::suspended(s.get()),"failed restore discarded disk snapshot");
 check(ledger().at("persistent").at("bytes").as_double()==gpu_suspended,"partial restore leaked GPU allocation");
 // No RAW source exists: restoration is entirely from the exact disk bytes.
 check(view::render(s.get(),q,after,e)&&after.print_cached&&after.pixels==live_before.pixels,"live random print changed across automatic restore");
 q.tier="full";
 check(view::render(s.get(),q,after,e)&&after.print_cached&&after.pixels==full_before.pixels,"full random print changed across restore");
 check(!view::suspended(s.get())&&view::resume(s.get(),e),"resume is not idempotent");
 check(residency_files()==files_before&&ledger().at("suspended_bytes").as_double()==0,"restored snapshot was not cleaned up");
 check(ledger().at("persistent").at("bytes").as_double()==gpu_before,"restore did not preserve source aliases/allocation sizes");
 // Retaining each pipeline must also preserve the next random realization.
 // A second session took the same full/live route and is the unchanged control.
 Session control(spk_open(engine.get(),&image,params,nullptr),spk_session_release);check(bool(control),spk_last_error(engine.get()));
 view::Result reference;q.tier="full";check(view::render(control.get(),q,reference,e),e);
 q.tier="live";check(view::render(control.get(),q,reference,e),e);
 spk_result next{},next_control{};
 check(spk_reprint(s.get(),"full",&next)==SPK_OK,spk_last_error(engine.get()));
 check(spk_reprint(control.get(),"full",&next_control)==SPK_OK,spk_last_error(engine.get()));
 const bool same=next.width==next_control.width&&next.height==next_control.height&&
  next.row_stride_px==next_control.row_stride_px&&
  std::memcmp(next.rgba16,next_control.rgba16,size_t(next.row_stride_px)*next.height*8)==0;
 spk_result_free(&next);spk_result_free(&next_control);
 check(same,"pipeline state/RNG changed across residency cycle");
 control.reset();check(view::suspend(s.get(),e),e);s.reset();
 check(residency_files()==files_before&&ledger().at("suspended_bytes").as_double()==0,"closing suspended session leaked temporary file");
 std::puts("view residency: exact random pixels, aliases, rollback, automatic restore, RNG continuation and suspended-close cleanup passed");
}
}
int main(int argc,char** argv){try{check(argc==2,"resource directory required");process_tests(argv[1]);cache_tests(argv[1]);proof_tests(argv[1]);cineon_tests(argv[1]);residency_tests(argv[1]);return 0;}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
