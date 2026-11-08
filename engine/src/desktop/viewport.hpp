#pragma once
#include <algorithm>
#include <cmath>

namespace spk::desktop {
// Physical pixels, including at 1:1 on a high-DPI monitor.
struct Viewport {
    int x=0, y=0, width=0, height=0;
    double scale=1;
};
inline Viewport viewport(int image_w, int image_h, int canvas_w, int canvas_h,
                         bool fit, double pan_x=0, double pan_y=0) {
    if(image_w<=0 || image_h<=0 || canvas_w<=0 || canvas_h<=0) return {};
    double s=fit?std::min(double(canvas_w)/image_w,double(canvas_h)/image_h):1.0;
    int w=std::max(1,int(std::lround(image_w*s)));
    int h=std::max(1,int(std::lround(image_h*s)));
    auto pos=[](int image,int canvas,double pan) {
        if(image<=canvas) return (canvas-image)/2;
        if(std::isnan(pan))pan=0;
        double value=std::clamp((canvas-image)*0.5+pan,double(canvas-image),0.0);
        return int(std::lround(value));
    };
    return {pos(w,canvas_w,fit?0:pan_x),pos(h,canvas_h,fit?0:pan_y),w,h,s};
}
}
