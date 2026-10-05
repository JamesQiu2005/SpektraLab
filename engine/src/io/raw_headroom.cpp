#include "raw_headroom.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace spk::io::detail {

bool headroom_exposure_restore(const std::array<float, 4>& applied_wb,
                               double& restore, std::string& error) {
    error.clear();
    float minimum = std::numeric_limits<float>::max();
    float maximum = 0.0f;
    for (float value : applied_wb) {
        if (!std::isfinite(value) || value <= 0.0f || value > 1.0f) {
            error = "RAW headroom: invalid max-normalised applied white balance";
            return false;
        }
        minimum = std::min(minimum, value);
        maximum = std::max(maximum, value);
    }
    if (maximum != 1.0f) {
        error = "RAW headroom: applied white balance is not max-normalised";
        return false;
    }
    restore = 1.0 / static_cast<double>(minimum);
    return true;
}

bool convert_camera_rgb_headroom(
    const std::uint16_t* camera, std::size_t camera_pixels,
    std::uint32_t width, std::uint32_t height, int flip,
    const std::array<float, 12>& matrix, double exposure_restore,
    std::vector<float>& rgb, std::uint32_t& output_width,
    std::uint32_t& output_height, std::string& error) {
    error.clear();
    const std::uint64_t pixels = std::uint64_t(width) * height;
    if (!camera || width == 0 || height == 0 || pixels != camera_pixels ||
        pixels > std::numeric_limits<std::size_t>::max() / (3 * sizeof(float)) ||
        pixels > std::numeric_limits<std::size_t>::max() / (4 * sizeof(std::uint16_t)) ||
        flip < 0 || flip > 7) {
        error = "RAW headroom: invalid camera plane bounds or orientation";
        return false;
    }
    if (!std::isfinite(exposure_restore) || exposure_restore < 1.0) {
        error = "RAW headroom: invalid white-balance exposure restoration";
        return false;
    }
    for (float value : matrix) {
        if (!std::isfinite(value)) {
            error = "RAW headroom: non-finite colour matrix";
            return false;
        }
    }
    if (matrix[3] != 0.0f || matrix[7] != 0.0f || matrix[11] != 0.0f) {
        error = "RAW headroom: a fourth colour channel is unsupported";
        return false;
    }

    const std::uint32_t out_width = (flip & 4) ? height : width;
    const std::uint32_t out_height = (flip & 4) ? width : height;
    std::vector<float> converted(static_cast<std::size_t>(pixels) * 3);
    const double output_scale = exposure_restore / 65535.0;
    for (std::uint32_t row = 0; row < out_height; ++row) {
        for (std::uint32_t col = 0; col < out_width; ++col) {
            std::uint32_t source_row = (flip & 4) ? col : row;
            std::uint32_t source_col = (flip & 4) ? row : col;
            if (flip & 2) source_row = height - 1 - source_row;
            if (flip & 1) source_col = width - 1 - source_col;
            const auto* pixel = camera + (std::size_t(source_row) * width + source_col) * 4;
            auto* destination = converted.data() + (std::size_t(row) * out_width + col) * 3;
            for (unsigned channel = 0; channel < 3; ++channel) {
                const auto* coefficients = matrix.data() + channel * 4;
                // Match LibRaw's float expression before its int/CLIP stage.
                // Deliberately omit both that stage and its output curve.
                const float value = coefficients[0] * pixel[0] +
                                    coefficients[1] * pixel[1] +
                                    coefficients[2] * pixel[2];
                destination[channel] = static_cast<float>(static_cast<double>(value) * output_scale);
                if (!std::isfinite(destination[channel])) {
                    error = "RAW headroom: colour conversion produced a non-finite sample";
                    return false;
                }
            }
        }
    }
    rgb = std::move(converted);
    output_width = out_width;
    output_height = out_height;
    return true;
}

}  // namespace spk::io::detail
