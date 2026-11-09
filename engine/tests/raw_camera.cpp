#include "../src/io/raw_camera.hpp"
#include <cmath>
#include <memory>
#include <iostream>
struct Camera : spk::io::detail::CameraLibRaw {
    using CameraLibRaw::adobe_coeff;
    bool uncalibrated() const { return libraw_internal_data.internal_output_params.raw_color; }
};
int main() {
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

    if (!raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, "X-E5") || raw->uncalibrated()) return 6;
    constexpr float xe5_xyz_to_camera[3][3] = {
        {1.1809f, -0.5358f, -0.1141f},
        {-0.4248f, 1.2164f, 0.2343f},
        {-0.0514f, 0.1097f, 0.5848f},
    };
    for (int row = 0; row < 3; ++row)
        for (int col = 0; col < 3; ++col)
            if (std::abs(raw->imgdata.color.cam_xyz[row][col] - xe5_xyz_to_camera[row][col]) > 1e-6f) return 7;
    if (raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, "X-E5-unknown")) return 8;
    if (raw->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "X-E5")) return 9;
    raw->imgdata.idata.dng_version = 0x01040000;
    if (raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, "X-E5")) return 10;
    std::cout << "GFX100RF and X-E5 calibration and exact model boundaries passed\n";
}
