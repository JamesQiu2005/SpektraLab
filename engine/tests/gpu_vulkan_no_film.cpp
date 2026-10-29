// Independent scalar decode/grade oracle, headroom, geometry and film isolation.
#include "pipeline/view.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

using namespace spk;
namespace {
void check(bool ok, const std::string& why) { if (!ok) throw std::runtime_error(why); }
Json json(const char* text) { Json out; std::string e; check(Json::parse(text, out, e), e); return out; }
uint16_t code(const view::Result& r, size_t i) { return uint16_t(r.pixels[2*i]) | uint16_t(r.pixels[2*i+1]) << 8; }
uint16_t quant(double v) { return uint16_t(std::lround(std::clamp(v, 0., 1.) * 65535)); }
double encode(double linear) { return linear < 1./512 ? linear*16 : std::pow(linear, 1./1.8); }

void exercise(const std::string& resources) {
    using Engine = std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)>;
    using Session = std::unique_ptr<spk_session, decltype(&spk_session_release)>;
    Engine engine(spk_engine_create(resources.c_str(), nullptr), spk_engine_destroy);
    check(bool(engine), spk_last_error(nullptr));
    constexpr uint32_t W=12, H=8;
    std::vector<float> pixels(W*H*3);
    constexpr std::array<float, 8> light={-.01f, 0, .0002f, .01f, .18f, .8f, 2.f, 4.f};
    for (size_t i=0; i<pixels.size(); ++i) pixels[i]=light[(i*5+i/7)%light.size()];
    spk_image image{pixels.data(), W, H, 3};
    const char* params="{\"input_color_space\":\"ProPhoto RGB\",\"input_cctf_decoding\":false,\"grain_active\":true,\"halation_active\":false,\"glare_active\":false,\"auto_exposure\":false}";
    Session session(spk_open(engine.get(), &image, params, nullptr), spk_session_release);
    check(bool(session), spk_last_error(engine.get()));
    std::string e; view::Request q; q.rgba16=true; q.target_space="ProPhoto RGB";
    view::Result film, neutral, recovered, restored;
    check(view::render(session.get(), q, film, e), e);
    q.no_film=true;
    check(view::render(session.get(), q, neutral, e), e);
    check(neutral.width==W && neutral.height==H && neutral.source_width==W && neutral.source_height==H && !neutral.print_cached,
          "no-film dimensions/cache source are wrong");
    int worst=0;
    for (size_t i=0; i<pixels.size(); ++i)
        worst=std::max(worst, std::abs(int(code(neutral,(i/3)*4+i%3))-int(quant(encode(pixels[i])))));
    check(worst<=3, "no-film neutral disagrees with independent ProPhoto OETF oracle: "+std::to_string(worst));
    q.adjustments=json("{\"exposure\":-4}");
    check(view::render(session.get(), q, recovered, e), e);
    worst=0; bool exercised_headroom=false;
    for (size_t i=0; i<pixels.size(); ++i) {
        const double c=std::max(0.,encode(pixels[i]));
        const auto expected=quant(std::pow(std::pow(c,2.2)/16,1./2.2));
        const auto actual=code(recovered,(i/3)*4+i%3);
        worst=std::max(worst,std::abs(int(actual)-int(expected)));
        if (pixels[i]>1) {
            exercised_headroom=true;
            check(actual>quant(std::pow(1./16,1./2.2))+1000, "decoded highlights were clipped before exposure");
        }
    }
    check(exercised_headroom && worst<=4, "no-film exposure disagrees with scalar oracle: "+std::to_string(worst));
    q.geometry=json("{\"quarterTurns\":1,\"crop\":{\"x\":0.25,\"y\":0.25,\"width\":0.5,\"height\":0.5}}");
    view::Result cropped; check(view::render(session.get(),q,cropped,e),e);
    check(cropped.width==4 && cropped.height==6,"no-film crop/quarter-turn dimensions are wrong");
    for (uint32_t y=0;y<6;++y) for(uint32_t x=0;x<4;++x) for(uint32_t c=0;c<3;++c)
        check(code(cropped,(y*4+x)*4+c)==code(recovered,((5-x)*W+(3+y))*4+c),"no-film geometry does not match original source coordinates");
    q.geometry=Json::object(); q.adjustments=Json::object(); q.no_film=false;
    check(view::render(session.get(),q,restored,e) && restored.print_cached && restored.pixels==film.pixels,
          "source bypass changed random film print cache");

    check(spk_set_params(session.get(),"{\"overscan_active\":true,\"overscan_format\":\"135\",\"date_imprint_active\":true,\"date_imprint_text\":\"26 10 28\",\"geometry_crop_w\":0.5,\"geometry_crop_h\":0.5,\"digital_intermediate\":true}",nullptr)==SPK_OK,spk_last_error(engine.get()));
    q.no_film=true; check(view::render(session.get(),q,restored,e),e);
    check(restored.pixels==neutral.pixels && restored.width==W && restored.height==H,"film edge/date/scan geometry contaminated no-film source");
    q.pair=Json::object(); check(!view::render(session.get(),q,restored,e) && e.find("pair")!=std::string::npos,"native request pair bypass was accepted");
    q.pair=Json();
    check(spk_set_params(session.get(),"{\"overscan_active\":false,\"date_imprint_active\":false,\"overscan_pair\":true,\"overscan_format\":\"135_half\",\"geometry_crop_w\":1,\"geometry_crop_h\":1}",nullptr)==SPK_OK,spk_last_error(engine.get()));
    check(!view::render(session.get(),q,restored,e) && e.find("pair")!=std::string::npos,"native session pair bypass was accepted");
    q.cineon=true; q.no_film=false;
    view::Result di; check(view::render(session.get(),q,di,e),e);
    q.no_film=true; check(!view::render(session.get(),q,restored,e) && e.find("Digital Intermediate")!=std::string::npos,"Cineon accepted no-film");
    std::puts("no-film Vulkan: independent OETF/exposure/headroom oracle, crop+rotation, film cache, edge/date/DI isolation and both native pair guards passed");
}
}
int main(int argc,char** argv) {
    try { check(argc==2,"resource directory required"); exercise(argv[1]); return 0; }
    catch(const std::exception& e) { std::fprintf(stderr,"%s\n",e.what()); return 1; }
}
