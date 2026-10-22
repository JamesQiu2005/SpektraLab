#include "white_balance.hpp"
#include "io/raw_decoder.hpp"
#include <cmath>
#include <iostream>
#include <stdexcept>

void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
int main() {
    try {
        spk::io::RawMetadata m;
        m.colour_channels = 3;
        // Non-identity calibration, non-neutral chosen WB. Independently build
        // source codes from a known illuminant; picking must recover that light.
        m.camera_from_xyz = {.72f,.18f,.10f, .15f,.80f,.05f, .05f,.15f,.80f};
        m.camera_to_output = {1.2f,-.1f,-.1f,0, -.08f,1.13f,-.05f,0, -.02f,-.12f,1.14f,0};
        for (bool headroom : {false,true}) for (double temperature : {2500.,4000.,6500.,10000.})
            for (double tint : {-35.,0.,40.}) {
                m.headroom_enabled = headroom;
                m.white_balance_exposure_restore = headroom ? 2.5 : 1.;
                m.post_scale_pre_mul = headroom ? std::array<float,4>{1.f,.4f,.6f,.4f} : std::array<float,4>{2.5f,1.f,1.5f,1.f};
                double x,y; spkhost::temperature_tint_to_xy(temperature,tint,x,y);
                const double xyz[3] = {x/y,1.,(1-x-y)/y};
                double camera[3]{};
                for(int r=0;r<3;++r)for(int c=0;c<3;++c)camera[r]+=.12*m.camera_from_xyz[r*3+c]*xyz[c]*m.post_scale_pre_mul[r];
                std::array<double,3> rgb{};
                for(int r=0;r<3;++r)for(int c=0;c<3;++c)rgb[r]+=m.camera_to_output[r*4+c]*camera[c]*m.white_balance_exposure_restore;
                double got_t=0,got_g=0;std::string error;
                require(spkhost::neutral_temperature_tint(m,rgb,got_t,got_g,error),error.c_str());
                require(std::abs(got_t-temperature)/temperature<.002 && std::abs(got_g-tint)<.15,"neutral illuminant recovery");
            }
        double t=123,g=456;std::string error;
        require(!spkhost::neutral_temperature_tint(m,{0,0,0},t,g,error)&&t==123&&g==456,"black rejected without output mutation");
        require(!spkhost::neutral_temperature_tint(m,{100,100,100},t,g,error),"clipping rejected");
        m.camera_to_output.fill(0);
        require(!spkhost::neutral_temperature_tint(m,{.2,.2,.2},t,g,error),"singular matrix rejected");
        std::cout<<"neutral picker: 48 illuminants, both RAW scales, camera matrix and invalid inputs passed\n";
        return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
