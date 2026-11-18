#include "../src/io/raw_camera.hpp"
#include <cmath>
#include <memory>
#include <iostream>
// The colour tables SpektraLab used to supply itself (raw_camera.hpp's history)
// now come from the pinned LibRaw. Hold upstream to the exact coefficients the
// removed override supplied, so a pin that drops or changes them fails here
// rather than silently falling back to an uncalibrated camera.
struct Camera : spk::io::detail::CameraLibRaw {
    using CameraLibRaw::adobe_coeff;
    bool uncalibrated() const { return libraw_internal_data.internal_output_params.raw_color; }
};
namespace {
bool matrix_is(Camera& raw, const float (&want)[3][3]) {
    for (int row = 0; row < 3; ++row)
        for (int col = 0; col < 3; ++col)
            if (std::abs(raw.imgdata.color.cam_xyz[row][col] - want[row][col]) > 1e-6f) return false;
    for (auto& row : raw.imgdata.color.rgb_cam)
        for (float v : row) if (!std::isfinite(v)) return false;
    return true;
}
}  // namespace
int main() {
    // LibRaw matches model prefixes, so R6 Mark III must precede R6 Mark II.
    auto canon = std::make_unique<Camera>();
    canon->imgdata.idata.colors = 3;
    if (!canon->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "EOS R6 Mark III") ||
        std::abs(canon->imgdata.color.cam_xyz[0][0] - 0.8309f) > 1e-6f) return 11;
    if (!canon->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "EOS R6 Mark II") ||
        std::abs(canon->imgdata.color.cam_xyz[0][0] - 0.9539f) > 1e-6f) return 12;

    // GFX 100RF: the GFX 100 II matrix (RawSpeed's cameras.xml gives both the
    // same), which is what the override lent it under 0.22.2.
    constexpr float gfx100_ii[3][3] = {
        {1.2806f, -0.5779f, -0.1110f},
        {-0.3546f, 1.1507f, 0.2318f},
        {-0.0177f, 0.0996f, 0.5715f},
    };
    for (const auto* name : {"GFX 100RF", "GFX 100 II"}) {
        auto raw = std::make_unique<Camera>();
        raw->imgdata.idata.colors = 3;
        if (!raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, name) || raw->uncalibrated()) return 1;
        if (!matrix_is(*raw, gfx100_ii)) return 2;
    }
    // X-E5: the X-H2 matrix.
    constexpr float xh2[3][3] = {
        {1.1809f, -0.5358f, -0.1141f},
        {-0.4248f, 1.2164f, 0.2343f},
        {-0.0514f, 0.1097f, 0.5848f},
    };
    for (const auto* name : {"X-E5", "X-H2"}) {
        auto raw = std::make_unique<Camera>();
        raw->imgdata.idata.colors = 3;
        if (!raw->adobe_coeff(LIBRAW_CAMERAMAKER_Fujifilm, name) || raw->uncalibrated()) return 6;
        if (!matrix_is(*raw, xh2)) return 7;
    }
    // A Fujifilm entry is not found under another maker.
    auto raw = std::make_unique<Camera>();
    raw->imgdata.idata.colors = 3;
    if (raw->adobe_coeff(LIBRAW_CAMERAMAKER_Canon, "GFX 100RF")) return 5;
    std::cout << "EOS R6 Mark III, GFX 100RF and X-E5 calibration come from the pinned LibRaw\n";
}
