#include "lens_correction.hpp"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace spkhost;
void require(bool b,const char* text){if(!b)throw std::runtime_error(text);}
FloatImage oriented(const FloatImage& src,int o) {
    FloatImage dst=src;dst.width=o>=5?src.height:src.width;dst.height=o>=5?src.width:src.height;
    for(uint32_t y=0;y<src.height;++y)for(uint32_t x=0;x<src.width;++x) {
        uint32_t u=x,v=y;
        switch(o){case 2:u=src.width-1-x;break;case 3:u=src.width-1-x;v=src.height-1-y;break;
        case 4:v=src.height-1-y;break;case 5:u=y;v=x;break;case 6:u=src.height-1-y;v=x;break;
        case 7:u=src.height-1-y;v=src.width-1-x;break;case 8:u=y;v=src.width-1-x;break;}
        for(int c=0;c<3;++c)dst.rgb[(size_t(v)*dst.width+u)*3+c]=src.rgb[(size_t(y)*src.width+x)*3+c];
    }return dst;
}
int main(int argc,char**argv) {
    try {
        require(argc==2,"owned fixture directory required");
        const auto dir=std::filesystem::path(argv[1]);std::filesystem::create_directories(dir);
        std::ofstream(dir/"test.xml")<<R"(<lensdatabase version="2">
        <mount><name>Fixture mount</name></mount>
        <camera><maker>Test</maker><model>Fixture Camera</model><mount>Fixture mount</mount><cropfactor>1</cropfactor></camera>
        <lens><maker>Test</maker><model>Fixture Lens 50mm f/4</model><mount>Fixture mount</mount><cropfactor>1</cropfactor>
        <calibration><distortion model="poly3" focal="50" k1="-0.15"/>
        <tca model="linear" focal="50" kr="1.015" kb="0.985"/>
        <vignetting model="pa" focal="50" aperture="4" distance="1000" k1="-0.25" k2="0.02" k3="0"/>
        </calibration></lens></lensdatabase>)";
        lens_database(dir);
        Probe p;p.kind=FileKind::Raw;p.width=97;p.height=65;
        p.metadata.model="Fixture Camera";p.metadata.lens="Fixture Lens 50mm f/4";
        p.metadata.focal_mm=50;p.metadata.aperture=4;
        auto info=inspect_lens(p);
        require(info.available&&info.distortion&&info.tca&&info.vignetting,"calibration matching/components");
        require(info.focus_distance_assumed,"missing EXIF focus distance must be disclosed");
        p.metadata.extra_exif[0x9206]={5,1,{5,0,0,0,1,0,0,0}};
        info=inspect_lens(p);require(!info.focus_distance_assumed&&info.focus_distance_m==5,"EXIF distance");
        p.metadata.extra_exif.clear();
        FloatImage original;original.width=p.width;original.height=p.height;original.rgb.resize(size_t(p.width)*p.height*3);
        original.raw_metadata.emplace();original.raw_metadata->colour_channels=3;
        // Nonidentity camera transform exposes applying TCA to mixed working primaries.
        original.raw_metadata->camera_to_output={1.2f,-.1f,-.1f,0,-.1f,1.2f,-.1f,0,-.1f,-.1f,1.2f,0};
        for(uint32_t y=0;y<p.height;++y)for(uint32_t x=0;x<p.width;++x) {
            float a=float(x)/float(p.width-1),b=float(y)/float(p.height-1);
            auto* rgb=original.rgb.data()+(size_t(y)*p.width+x)*3;
            rgb[0]=2*a-.3f;rgb[1]=1.5f*b-.2f;rgb[2]=a*b;
        }
        auto base=original;std::string error;require(correct_lens(base,p,error),error.c_str());
        require(p.metadata.lens_correction->applied,"applied status");
        require(base.rgb!=original.rgb,"known distortion must change image");
        require(*std::min_element(base.rgb.begin(),base.rgb.end())<0&&*std::max_element(base.rgb.begin(),base.rgb.end())>1,"headroom was clipped");
        for(int o=1;o<=8;++o) {
            auto input=oriented(original,o),expected=oriented(base,o);auto probe=p;
            probe.width=input.width;probe.height=input.height;probe.metadata.orientation=o;
            require(correct_lens(input,probe,error),error.c_str());
            for(size_t i=0;i<input.rgb.size();++i)require(std::abs(input.rgb[i]-expected.rgb[i])<2e-5f,"EXIF orientation equivariance");
        }
        auto missing=p;missing.metadata.lens="Uncatalogued";
        require(!inspect_lens(missing).available,"unmatched lens must not claim support");
        auto unchanged=original;require(!correct_lens(unchanged,missing,error)&&unchanged.rgb==original.rgb,"unmatched correction must fail unchanged");
        auto bad=original;bad.raw_metadata->camera_to_output.fill(0);
        require(!correct_lens(bad,p,error)&&bad.rgb==original.rgb,"singular camera transform rejected before pixel writes");
        bad=original;bad.rgb.resize(10);require(!correct_lens(bad,p,error),"invalid dimensions rejected");
        std::cout<<"lens matching, EXIF distance, TCA colour transform, float range, 8 orientations and rejection passed\n";
        return 0;
    }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
}
