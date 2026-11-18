#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace spk::io::detail {

// Compute the exposure convention from the WB actually used by LibRaw,
// including its fourth (second-green) entry. A maximum of one is required:
// these must be post-scale_colors multipliers from highlight=1.
bool headroom_exposure_restore(const std::array<float, 4>& applied_wb,
                               double& restore, std::string& error);

// Transform a bounded, packed uint16 RGBA camera plane into oriented packed
// float RGB. The unused fourth channel must not participate in the matrix.
// LibRaw flip bits: 4 transposes, 2 reverses source rows, 1 source columns.
// This helper does no demosaicing, black subtraction or highlight synthesis.
// Outputs are unchanged on failure; the supplied matrix is not renormalised.
bool convert_camera_rgb_headroom(
    const std::uint16_t* camera, std::size_t camera_pixels,
    std::uint32_t width, std::uint32_t height, int flip,
    const std::array<float, 12>& camera_to_output, double exposure_restore,
    std::vector<float>& rgb, std::uint32_t& output_width,
    std::uint32_t& output_height, std::string& error);

}  // namespace spk::io::detail
