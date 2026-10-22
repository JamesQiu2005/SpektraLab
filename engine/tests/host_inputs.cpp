#include "image_io.hpp"
#include "input_formats.hpp"
#include "platform.hpp"
#include <OpenEXR/ImfOutputFile.h>
#include <OpenEXR/ImfHeader.h>
#include <OpenEXR/ImfChannelList.h>
#include <OpenEXR/ImfFrameBuffer.h>
#include <OpenEXR/ImfStandardAttributes.h>
#include <lcms2.h>
#include <algorithm>
#include <cmath>
#include <cctype>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace spkhost;
void require(bool ok,const std::string& error){if(!ok)throw std::runtime_error(error);}
void exr_fixture(const std::filesystem::path& path,const std::vector<float>& rgb) {
    Imf::Header h(7,4);h.dataWindow()={{-3,5},{3,8}};h.displayWindow()=h.dataWindow();
    Imf::addChromaticities(h,Imf::Chromaticities());
    Imf::FrameBuffer fb;
    for(int c=0;c<3;++c) {
        const char* name=c==0?"R":c==1?"G":"B";
        h.channels().insert(name,Imf::Channel(Imf::FLOAT));
        fb.insert(name,Imf::Slice::Make(Imf::FLOAT,rgb.data()+c,h.dataWindow(),12,7*12));
    }
    Imf::OutputFile file(path_utf8(path).c_str(),h);file.setFrameBuffer(fb);file.writePixels(4);
}
int lut_sample(const cmsUInt16Number in[],cmsUInt16Number out[],void*) {
    const double m[]={.7976749,.1351917,.0313534,.2880402,.7118741,.0000857,0,0,.8252100};
    for(int r=0;r<3;++r) {
        double xyz=0;for(int c=0;c<3;++c)xyz+=m[r*3+c]*in[c]/65535.;
        out[r]=cmsUInt16Number(std::lround(xyz*32768.));
    }
    return 1;
}
void complex_profile() {
    cmsHPROFILE p=cmsCreateProfilePlaceholder(nullptr);require(p,"profile allocation");
    cmsSetProfileVersion(p,4.3);cmsSetDeviceClass(p,cmsSigInputClass);cmsSetColorSpace(p,cmsSigRgbData);cmsSetPCS(p,cmsSigXYZData);
    cmsCIEXYZ white={.9642,1,.8249};require(cmsWriteTag(p,cmsSigMediaWhitePointTag,&white),"whitepoint");
    cmsPipeline* pipe=cmsPipelineAlloc(nullptr,3,3);
    cmsToneCurve* identity=cmsBuildGamma(nullptr,1);cmsToneCurve* curves[]={identity,identity,identity};
    cmsStage* clut=cmsStageAllocCLut16bit(nullptr,17,3,3,nullptr);
    require(cmsStageSampleCLut16bit(clut,lut_sample,nullptr,0),"CLUT sampling");
    cmsPipelineInsertStage(pipe,cmsAT_END,cmsStageAllocToneCurves(nullptr,3,curves));
    cmsPipelineInsertStage(pipe,cmsAT_END,clut);
    cmsPipelineInsertStage(pipe,cmsAT_END,cmsStageAllocToneCurves(nullptr,3,curves));
    require(cmsWriteTag(p,cmsSigAToB0Tag,pipe),"CLUT profile");
    cmsUInt32Number n=0;require(cmsSaveProfileToMem(p,nullptr,&n),"profile size");
    std::vector<uint8_t> bytes(n);require(cmsSaveProfileToMem(p,bytes.data(),&n),"profile serialization");
    cmsPipelineFree(pipe);cmsFreeToneCurve(identity);cmsCloseProfile(p);
    RgbSpace ignored;std::string error;require(!parse_icc(bytes,ignored,error),"test must exercise LUT path");
    const std::vector<float> original={.1f,.3f,.7f,.5f,.5f,.5f,.8f,.2f,.05f};
    auto result=original;require(icc_to_linear_prophoto(bytes,result,0,error),error);
    for(size_t i=0;i<result.size();++i)require(std::abs(result[i]-original[i])<.002,"CLUT RGB->XYZ->ProPhoto failed independent expected linear codes");
    auto bad=original;require(!icc_to_linear_prophoto({0,1,2},bad,0,error),"malformed ICC silently reinterpreted");
}
int main(int argc,char** argv) {
    try {
        require(argc>=2,"usage: spk_host_inputs output-dir [heic-fixture]");
        const auto dir=std::filesystem::u8path(argv[1]);std::filesystem::create_directories(dir);
        // Recognizing a RAW extension routes it to LibRaw; it is not a claim
        // that every camera/compression variant is supported by that decoder.
        for(const char* ext:{"arw","nef","nrw","cr2","cr3","crw","raf","dng","orf","rw2","pef","srw","3fr","iiq","erf","mos","mrw","x3f","raw","rwl","srf","sr2","kdc","dcr","mef","fff","gpr","ari","bay","k25"}) {
            std::string upper(ext);for(char& c:upper)c=char(std::toupper(static_cast<unsigned char>(c)));
            require(sniff_kind(dir/("unopened."+std::string(ext)))==FileKind::Raw,"RAW suffix not routed to decoder");
            require(sniff_kind(dir/("unopened."+upper))==FileKind::Raw,"Uppercase RAW suffix not routed to decoder");
        }
        require(sniff_kind(dir/"unopened.txt")==FileKind::Unknown,"unknown suffix treated as RAW");
        const auto path=dir/std::filesystem::path(u8"浮点输入.exr");
        std::vector<float> original(7*4*3);
        for(size_t i=0;i<original.size();++i)original[i]=float(int(i%19)-2)/10;
        exr_fixture(path,original);
        FloatImage image;Probe probe;std::string error;
        require(probe_file(path,probe,error)&&probe.kind==FileKind::Exr&&probe.width==7&&probe.height==4,error);
        require(decode_linear_prophoto(path,{},image,probe,error),error);
        auto expected=original;auto space=srgb_space();for(auto& t:space.trc){t.kind=Trc::Kind::Gamma;t.gamma=1;}
        to_linear_prophoto(space,expected);
        require(image.rgb.size()==expected.size(),"EXR extent/data window changed");
        for(size_t i=0;i<expected.size();++i)require(std::abs(image.rgb[i]-expected[i])<.0005,
            "EXR matrix/sample mismatch at "+std::to_string(i)+": "+std::to_string(image.rgb[i])+" vs "+std::to_string(expected[i]));
        require(*std::min_element(image.rgb.begin(),image.rgb.end())<0&&*std::max_element(image.rgb.begin(),image.rgb.end())>1,"EXR float range clipped");
        Rgba8 thumb;std::string from;require(thumbnail(path,5,thumb,from,error)&&thumb.width==5&&thumb.height==3,error);
        complex_profile();
        std::ofstream bad(dir/"broken.heic",std::ios::binary);bad<<"bad";bad.close();
        require(!decode_linear_prophoto(dir/"broken.heic",{},image,probe,error),"bad HEIC accepted");
        if(argc>=3) {
            const auto owned=dir/std::filesystem::path(u8"透明样片.heic");
            // Use the host's Unicode/overwrite path so rerunning this fixture
            // does not depend on MinGW filesystem::copy_file overwrite quirks.
            std::vector<uint8_t> fixture;
            require(read_file(std::filesystem::u8path(argv[2]),fixture,error),error);
            require(write_file_atomic(owned,fixture,true,error),error);
            require(decode_linear_prophoto(owned,{},image,probe,error),error);
            require(image.width==512&&image.height==512&&image.rgb.size()==512*512*3,"HEIC dimensions");
            require(thumbnail(owned,31,thumb,from,error)&&thumb.width==31&&thumb.height==31,error);
            for(float v:image.rgb)require(std::isfinite(v),"HEIC non-finite pixel");
            std::cout<<"HEIC alpha fixture decoded through bundled libde265; ";
        }
        std::cout<<"EXR float32/data-window/negative/highlight/Chinese path, RGB CLUT ICC, thumbnails and invalid input passed\n";return 0;
    }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
