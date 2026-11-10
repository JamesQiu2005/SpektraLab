#include "../src/io/raw_camera.hpp"
#include <cmath>
#include <memory>
#include <iostream>
struct Camera : spk::io::detail::CameraLibRaw {
    using CameraLibRaw::adobe_coeff;
    bool uncalibrated() const { return libraw_internal_data.internal_output_params.raw_color; }
};
int main() {
    // LibRaw matches model prefixes, so R6 Mark III must precede R6 Mark II.
    auto canon = std::make_unique<Camera>();
    canon->imgdata.idata.colors = 3;
    if (!canon->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "EOS R6 Mark III") ||
        std::abs(canon->imgdata.color.cam_xyz[0][0] - 0.8309f) > 1e-6f) return 11;
    if (!canon->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "EOS R6 Mark II") ||
        std::abs(canon->imgdata.color.cam_xyz[0][0] - 0.9539f) > 1e-6f) return 12;
    for (const auto* name : {"GFX100RF", "GFX 100RF"}) {
        auto raw = std::make_unique<Camera>();
        raw->imgdata.idata.colors = 3;
        if (!raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, name) || raw->uncalibrated()) return 1;
        if (std::abs(raw->imgdata.color.cam_xyz[0][0] - 1.2806f) > 1e-6f) return 2;
        for (auto& row : raw->imgdata.color.rgb_cam)
            for (float v : row) if (!std::isfinite(v)) return 3;
    }
    auto raw = std::make_unique<Camera>();
    raw->imgdata.idata.colors = 3;
    if (raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, "GFX100RF-unknown")) return 4;
    if (raw->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "GFX100RF")) return 5;
    std::cout << "GFX100RF calibration and exact model boundary passed\n";
}
