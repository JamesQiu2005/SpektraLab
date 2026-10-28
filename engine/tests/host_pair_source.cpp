// PairComposer source geometry/cache contract, CPU-only with owned fixture
// probes/decodes. GPU/real-format integration is exercised by host_pair.py.
#include "pair_source.hpp"
#include "platform.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <stdexcept>

using spk::Json;
static std::map<std::string,spkhost::FloatImage> sources;
namespace spkhost {
bool probe_file(const std::filesystem::path& path,Probe& out,std::string& error) {
    auto it=sources.find(path_utf8(path));
    if(it==sources.end()){error="owned missing photograph";return false;}
    out.width=it->second.width;out.height=it->second.height;out.kind=FileKind::Png;return true;
}
}
static void require(bool good,const char* message){if(!good)throw std::runtime_error(message);}
static Json parse(const char* text){Json j;std::string error;require(Json::parse(text,j,error),error.c_str());return j;}
static void equal(const spkhost::FloatImage& a,const spkhost::FloatImage& b){
    require(a.width==b.width&&a.height==b.height&&a.rgb.size()==b.rgb.size(),"pair dimensions differ");
    require(!std::memcmp(a.rgb.data(),b.rgb.data(),a.rgb.size()*sizeof(float)),"cached and uncached pair pixels differ");
}
int main(){try{
    const auto dir=std::filesystem::temp_directory_path()/"spektralab-pair-source-test";
    std::filesystem::create_directories(dir);
    const auto a=spkhost::path_utf8(dir/"left.fake"),b=spkhost::path_utf8(dir/"right.fake");
    for(const auto& path:{a,b}){std::ofstream file(spkhost::utf8_path(path));file<<"fixture";}
    spkhost::FloatImage source;source.width=128;source.height=96;source.rgb.resize(128*96*3);
    for(unsigned y=0;y<96;++y)for(unsigned x=0;x<128;++x){source.rgb[(y*128+x)*3]=float(x)/127;source.rgb[(y*128+x)*3+1]=float(y)/95;source.rgb[(y*128+x)*3+2]=.18f;}
    sources[a]=source;std::fill(source.rgb.begin(),source.rgb.end(),.375f);sources[b]=source;
    Json pair=parse(R"({"schemaVersion":1,"spacingMM":1,"turned":false,"left":{"autoExposure":false},"right":{"autoExposure":false}})");
    auto left=pair.at("left"),right=pair.at("right");left.set("path",Json(a));right.set("path",Json(b));pair.set("left",left);pair.set("right",right);
    Json params=parse(R"({"auto_exposure_method":"balanced"})");
    int decodes=0,meters=0;bool fail_decode=false;
    auto decode=[&](const std::filesystem::path& path,const Json&,spkhost::FloatImage& image,spkhost::Probe& p,std::string& error){
        ++decodes;if(fail_decode){error="injected decode failure";return false;}image=sources.at(spkhost::path_utf8(path));return spkhost::probe_file(path,p,error);};
    auto meter=[&](const spkhost::FloatImage& image,const std::string& method){++meters;require(std::max(image.width,image.height)<=1024&&method=="balanced","pair meter contract");return .25;};
    spkhost::PairSource cache;spkhost::FloatImage baseline,warm,cold;spkhost::PairSource::Description description;std::array<std::optional<double>,2> metered;std::string error;
    auto compose=[&](spkhost::PairSource& c,const Json& p,spkhost::FloatImage& image){require(c.compose(p,params,image,description,metered,decode,meter,[]{},error),error.c_str());};
    compose(cache,pair,baseline);require(decodes==2&&meters==0,"initial pair decode count");
    require(baseline.width==127&&baseline.height==83&&description.hole_width==62&&description.advance==65,"Mac pair layout cap");
    compose(cache,pair,warm);require(decodes==2,"pair cache miss on unchanged source");equal(baseline,warm);
    spkhost::PairSource uncached;compose(uncached,pair,cold);equal(baseline,cold);
    require(cache.cached_bytes()==size_t(62)*83*3*2*2,"pair cache is not half-float RGB");
    for(unsigned y=0;y<83;++y)for(unsigned x=62;x<65;++x)for(unsigned c=0;c<3;++c)require(baseline.rgb[(y*127+x)*3+c]==0,"pair gap is not unexposed black");
    const auto key=spkhost::PairSource::signature(pair,params);
    left.set("print",parse(R"({"brightnessStops":2,"yFilterShift":5})"));left.set("adjustments",parse(R"({"exposure":1})"));pair.set("left",left);
    require(spkhost::PairSource::signature(pair,params)==key,"print/grade regenerated pair negative source");
    left.set("exposureEV",Json(1.));pair.set("left",left);compose(cache,pair,warm);
    for(unsigned y=0;y<83;++y)for(unsigned x=0;x<127;++x)for(unsigned c=0;c<3;++c){const size_t i=(y*127+x)*3+c;require(warm.rgb[i]==baseline.rgb[i]*(x<62?2.f:1.f),"hole exposure/gap isolation");}
    left.set("exposureEV",Json(0.));left.set("geometry",parse(R"({"flipH":true})"));pair.set("left",left);compose(cache,pair,warm);
    for(unsigned y=0;y<83;++y)for(unsigned x=0;x<62;++x)for(unsigned c=0;c<3;++c)require(warm.rgb[(y*127+x)*3+c]==baseline.rgb[(y*127+61-x)*3+c],"hole geometry flip does not map source");
    left.set("geometry",Json::object());left.set("autoExposure",Json(true));pair.set("left",left);compose(cache,pair,warm);require(meters==1&&metered[0]==.25,"hole automatic exposure missing");
    left.set("placement",parse(R"({"scale":2,"x":0.4,"y":-0.3,"quarterTurns":1})"));pair.set("left",left);compose(cache,pair,warm);require(meters==1,"placement caused exposure pumping");
    left.set("meteredEV",Json(*metered[0]));left.set("meteredFor",Json(description.meter_keys[0]));pair.set("left",left);
    spkhost::PairSource reopened;compose(reopened,pair,cold);require(meters==1,"cold pair discarded its persisted meter reading");equal(warm,cold);
    const auto settled=spkhost::PairSource::signature(pair,params);
    auto old_request=pair;auto old_left=left;old_left.set("meteredEV",Json());old_left.set("meteredFor",Json());old_request.set("left",old_left);
    require(spkhost::PairSource::signature(old_request,params,pair)==settled,"absorbing meter metadata redevelops the source");
    auto changed_reading=pair;auto changed_left=left;changed_left.set("meteredEV",Json(.5));changed_reading.set("left",changed_left);
    require(spkhost::PairSource::signature(changed_reading,params)!=settled,"different effective reading missing from source signature");
    for(const char* field:{"meteredFor","meteredEV","decode","geometry","meterMethod"}){
        auto invalid_pair=pair;auto invalid_left=left;
        if(std::string(field)=="meteredFor")invalid_left.set(field,Json(std::string("invalid")));
        else if(std::string(field)=="meteredEV")invalid_left.set(field,Json(1e100));
        else if(std::string(field)=="meterMethod")invalid_left.set(field,Json(std::string("center_weighted")));
        else invalid_left.set(field,parse(std::string(field)=="decode"?R"({"whiteBalance":"Daylight"})":R"({"flipH":true})"));
        invalid_pair.set("left",invalid_left);spkhost::PairSource fresh;int readings=0;
        require(fresh.compose(invalid_pair,params,cold,description,metered,decode,[&](const spkhost::FloatImage&,const std::string&){++readings;return .125;},[]{},error),error.c_str());
        require(readings==1&&metered[0]==.125,"stale or out-of-range persisted meter was trusted");
    }
    { std::ofstream changed(spkhost::utf8_path(a),std::ios::app);changed<<"new source stamp"; }
    spkhost::PairSource changed_source;int source_readings=0;
    require(changed_source.compose(pair,params,cold,description,metered,decode,[&](const spkhost::FloatImage&,const std::string&){++source_readings;return .3;},[]{},error),error.c_str());
    require(source_readings==1&&metered[0]==.3,"changed source file reused an old persisted meter");
    pair.set("turned",Json(true));compose(cache,pair,warm);require(warm.height>warm.width&&description.gates.items()[1].at("x").as_double()==0,"turned pair gates/layout");
    right.set("path",Json(b+".missing"));pair.set("right",right);compose(cache,pair,warm);require(!description.available[1]&&!description.errors[1].empty(),"missing pair hole not reported");
    const unsigned start=description.advance;for(unsigned y=start;y<warm.height;++y)for(unsigned x=0;x<warm.width;++x)require(warm.rgb[(size_t(y)*warm.width+x)*3]==0,"missing hole not black");
    fail_decode=true;spkhost::PairSource failed;compose(failed,pair,warm);require(!description.available[0]&&description.errors[0]=="injected decode failure","decode failure silently shown as valid");
    fail_decode=false;bool cancelled=false;try{cache.compose(pair,params,warm,description,metered,decode,meter,[]{throw std::runtime_error("cancel");},error);}catch(const std::runtime_error&){cancelled=true;}require(cancelled,"pair checkpoint ignored");
    left.set("geometry",parse(R"({"crop":{"x":0.8,"width":0.4}})"));pair.set("left",left);bool invalid=false;try{spkhost::PairSource::describe(pair);}catch(const std::invalid_argument&){invalid=true;}require(invalid,"pair accepted out-of-range crop");
    std::puts("Pair source: Mac layout, half-float cache/cold equality, geometry, scoped exposure, meter reuse, turned/missing holes and cancellation passed");return 0;
}catch(const std::exception& e){std::fprintf(stderr,"pair source: %s\n",e.what());return 1;}}
