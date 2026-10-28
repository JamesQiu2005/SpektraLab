#include "lens_correction.hpp"
#include "platform.hpp"
#include <lensfun/lensfun.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <future>
#include <memory>
#include <mutex>
#include <stdexcept>

namespace spkhost {
namespace {
std::mutex database_mutex;
std::unique_ptr<lfDatabase> database;
std::string database_error="lens database is not configured";
using Matrix=std::array<double,9>;
const Matrix identity={1,0,0,0,1,0,0,0,1};
template<class F> void parallel_rows(uint32_t rows,F&& body) {
    const unsigned count=std::min({8u,hardware_threads(),std::max(1u,rows/16)});
    if(count<=1){body(0,rows);return;}
    std::vector<std::future<void>> tasks;
    const uint32_t step=(rows+count-1)/count;
    for(unsigned t=0;t<count;++t) {
        const auto begin=t*step,end=std::min(rows,begin+step);
        if(begin<end)tasks.push_back(std::async(std::launch::async,[&body,begin,end]{body(begin,end);}));
    }
    std::exception_ptr failure;
    for(auto& task:tasks)try{task.get();}catch(...){if(!failure)failure=std::current_exception();}
    if(failure)std::rethrow_exception(failure);
}
Matrix inverse(const Matrix& m) {
    const double d=m[0]*(m[4]*m[8]-m[5]*m[7])-m[1]*(m[3]*m[8]-m[5]*m[6])+m[2]*(m[3]*m[7]-m[4]*m[6]);
    if(!std::isfinite(d)||std::abs(d)<1e-10)throw std::runtime_error("camera colour matrix is singular; TCA correction is unavailable");
    return {(m[4]*m[8]-m[5]*m[7])/d,(m[2]*m[7]-m[1]*m[8])/d,(m[1]*m[5]-m[2]*m[4])/d,
        (m[5]*m[6]-m[3]*m[8])/d,(m[0]*m[8]-m[2]*m[6])/d,(m[2]*m[3]-m[0]*m[5])/d,
        (m[3]*m[7]-m[4]*m[6])/d,(m[1]*m[6]-m[0]*m[7])/d,(m[0]*m[4]-m[1]*m[3])/d};
}
struct Match {const lfCamera* camera=nullptr;const lfLens* lens=nullptr;std::string reason;};
Match match(const Probe& probe) {
    if(!database)return {nullptr,nullptr,database_error};
    const auto& m=probe.metadata;
    if(m.model.empty()||m.lens.empty()||!m.focal_mm)return {nullptr,nullptr,"camera, lens or focal-length metadata is missing"};
    const lfCamera** cameras=database->FindCameras(nullptr,m.model.c_str());
    const lfCamera* camera=nullptr;
    if(cameras&&cameras[0]&&!cameras[1])camera=cameras[0];
    lf_free(cameras);
    if(!camera)return {nullptr,nullptr,"camera profile was not matched uniquely"};
    const lfLens** lenses=database->FindLenses(camera,nullptr,m.lens.c_str());
    const lfLens* lens=nullptr;
    if(lenses&&lenses[0]&&(!lenses[1]||lenses[0]->Score>lenses[1]->Score))lens=lenses[0];
    lf_free(lenses);
    if(!lens)return {camera,nullptr,"lens profile was not matched uniquely"};
    return {camera,lens,{}};
}
struct Correction {
    LensCorrectionInfo info;
    std::unique_ptr<lfModifier> modifier;
};
Correction prepare(const Probe& probe) {
    Correction out;const auto selected=match(probe);
    if(!selected.lens){out.info.reason=selected.reason;return out;}
    int w=int(probe.width),h=int(probe.height);
    if(probe.metadata.orientation>=5)std::swap(w,h);
    if(w<2||h<2){out.info.reason="image is too small for lens correction";return out;}
    out.modifier=std::make_unique<lfModifier>(selected.lens,float(*probe.metadata.focal_mm),selected.camera->CropFactor,w,h,LF_PF_F32);
    auto& mod=*out.modifier;
    int flags=mod.EnableDistortionCorrection();
    out.info.distortion=(flags&LF_MODIFY_DISTORTION)!=0;
    flags=mod.EnableTCACorrection();out.info.tca=(flags&LF_MODIFY_TCA)!=0;
    if(const auto it=probe.metadata.extra_exif.find(0x9206);it!=probe.metadata.extra_exif.end()) {
        const auto& v=it->second;
        if(v.type==5&&v.count==1&&v.bytes.size()==8) {
            auto u32=[&](size_t at){uint32_t n=0;for(int i=0;i<4;++i)n|=uint32_t(v.bytes[at+i])<<(8*i);return n;};
            const auto n=u32(0),d=u32(4);
            if(n&&d&&n!=UINT32_MAX) {
                const double metres=double(n)/d;
                if(std::isfinite(metres)&&metres>0&&metres<=1000000) {
                    out.info.focus_distance_m=metres;out.info.focus_distance_assumed=false;
                }
            }
        }
    }
    if(probe.metadata.aperture)flags=mod.EnableVignettingCorrection(float(*probe.metadata.aperture),float(out.info.focus_distance_m));
    out.info.vignetting=(flags&LF_MODIFY_VIGNETTING)!=0;
    out.info.available=out.info.distortion||out.info.tca||out.info.vignetting;
    out.info.profile=lf_mlstr_get(selected.lens->Model);
    if(!out.info.available)out.info.reason="profile has no calibration at this focal length and aperture";
    if(out.info.distortion||out.info.tca) {
        const float scale=mod.GetAutoScale(false);
        if(!std::isfinite(scale)||scale<=0||scale>8)throw std::runtime_error("lens profile returned an invalid automatic crop");
        mod.EnableScaling(scale);out.info.scale=scale;
    }
    return out;
}
std::array<float,2> displayed(float x,float y,uint32_t w,uint32_t h,int orientation) {
    switch(orientation) {
        case 2:return {float(w-1)-x,y};case 3:return {float(w-1)-x,float(h-1)-y};
        case 4:return {x,float(h-1)-y};case 5:return {y,x};case 6:return {float(h-1)-y,x};
        case 7:return {float(h-1)-y,float(w-1)-x};case 8:return {y,float(w-1)-x};
        default:return {x,y};
    }
}
float cubic(float x) {
    x=std::abs(x);
    if(x<1)return ((1.5f*x-2.5f)*x)*x+1;
    if(x<2)return ((-.5f*x+2.5f)*x-4)*x+2;
    return 0;
}
float sample(const FloatImage& src,float x,float y,int channel) {
    if(!std::isfinite(x)||!std::isfinite(y))throw std::runtime_error("non-finite lens coordinate");
    x=std::clamp(x,0.f,float(src.width-1));y=std::clamp(y,0.f,float(src.height-1));
    int ix=int(std::floor(x)),iy=int(std::floor(y));float value=0;
    for(int j=-1;j<=2;++j) {
        const float wy=cubic(y-float(iy+j));
        const auto yy=uint32_t(std::clamp(iy+j,0,int(src.height)-1));
        for(int i=-1;i<=2;++i) {
            const auto xx=uint32_t(std::clamp(ix+i,0,int(src.width)-1));
            value+=src.rgb[(size_t(yy)*src.width+xx)*3+channel]*(wy*cubic(x-float(ix+i)));
        }
    }
    return value;
}
}

void lens_database(const std::filesystem::path& directory) {
    std::lock_guard lock(database_mutex);database.reset();
    auto next=std::make_unique<lfDatabase>();
    const auto status=next->Load(path_utf8(directory).c_str());
    if(status!=LF_NO_ERROR){database_error="bundled lens database cannot be loaded";return;}
    database=std::move(next);database_error.clear();
}
LensCorrectionInfo inspect_lens(const Probe& probe) {
    std::lock_guard lock(database_mutex);
    try{return prepare(probe).info;}catch(const std::exception& e){LensCorrectionInfo i;i.reason=e.what();return i;}
}
bool correct_lens(FloatImage& image,Probe& probe,std::string& error) {
    try {
        std::lock_guard lock(database_mutex);
        if(image.width!=probe.width||image.height!=probe.height||image.width<2||image.height<2||
           image.rgb.size()!=size_t(image.width)*image.height*3)
            throw std::runtime_error("invalid lens input dimensions");
        auto correction=prepare(probe);
        if(!correction.info.available)throw std::runtime_error(correction.info.reason);
        if(!image.raw_metadata||image.raw_metadata->colour_channels!=3)throw std::runtime_error("lens correction requires a three-colour RAW decode");
        Matrix to_camera=identity,to_working=identity;
        if(correction.info.tca) {
            for(int r=0;r<3;++r)for(int c=0;c<3;++c)to_working[r*3+c]=image.raw_metadata->camera_to_output[r*4+c];
            to_camera=inverse(to_working);
        }
        const auto orientation=probe.metadata.orientation;
        const uint32_t w=orientation>=5?image.height:image.width,h=orientation>=5?image.width:image.height;
        auto& modifier=*correction.modifier;
        // Vignetting belongs at the distorted sample position, before the
        // geometric resampling. Float RGB retains negative/highlight values.
        // Reconstruct camera channels for TCA: shifting ProPhoto primaries
        // would shift mixtures of sensor channels and create coloured edges.
        parallel_rows(h,[&](uint32_t first,uint32_t last){
            std::vector<float> gains(size_t(w)*3,1.f);
            for(uint32_t y=first;y<last;++y) {
                std::fill(gains.begin(),gains.end(),1.f);
                if(correction.info.vignetting)modifier.ApplyColorModification(gains.data(),0,float(y),int(w),1,LF_CR_3(RED,GREEN,BLUE),int(w*3*sizeof(float)));
                for(uint32_t x=0;x<w;++x) {
                    const auto p=displayed(float(x),float(y),w,h,orientation);
                    float* pixel=image.rgb.data()+(size_t(uint32_t(p[1]))*image.width+uint32_t(p[0]))*3;
                    const std::array<float,3> v={pixel[0],pixel[1],pixel[2]};
                    for(int c=0;c<3;++c)pixel[c]=float(to_camera[c*3]*v[0]+to_camera[c*3+1]*v[1]+to_camera[c*3+2]*v[2])*gains[size_t(x)*3+c];
                }
            }
        });
        std::vector<float> output(image.rgb.size());
        parallel_rows(h,[&](uint32_t first,uint32_t last){
            std::vector<float> coordinates(size_t(w)*6);
            for(uint32_t y=first;y<last;++y) {
                if(!modifier.ApplySubpixelGeometryDistortion(0,float(y),int(w),1,coordinates.data()))
                    for(uint32_t x=0;x<w;++x)for(int c=0;c<3;++c){coordinates[size_t(x)*6+c*2]=float(x);coordinates[size_t(x)*6+c*2+1]=float(y);}
                for(uint32_t x=0;x<w;++x) {
                    std::array<float,3> v{};
                    for(int c=0;c<3;++c) {
                        const auto p=displayed(coordinates[size_t(x)*6+c*2],coordinates[size_t(x)*6+c*2+1],w,h,orientation);
                        v[c]=sample(image,p[0],p[1],c);
                    }
                    const auto p=displayed(float(x),float(y),w,h,orientation);
                    float* pixel=output.data()+(size_t(uint32_t(p[1]))*image.width+uint32_t(p[0]))*3;
                    for(int c=0;c<3;++c)pixel[c]=float(to_working[c*3]*v[0]+to_working[c*3+1]*v[1]+to_working[c*3+2]*v[2]);
                }
            }
        });
        image.rgb=std::move(output);correction.info.applied=true;probe.metadata.lens_correction=correction.info;return true;
    } catch(const std::exception& e){error=std::string(kUnsupportedPrefix)+"lens correction: "+e.what();return false;}
}
}
