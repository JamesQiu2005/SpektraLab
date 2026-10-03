#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace spk::io {

struct RawDecodeTimings {
    double open_ms = 0.0;
    double unpack_ms = 0.0;
    double process_ms = 0.0;
    double convert_ms = 0.0;
    double total_ms = 0.0;
};

struct RawSourceSizes {
    std::uint32_t raw_width = 0, raw_height = 0;
    std::uint32_t width = 0, height = 0;
    std::uint32_t iwidth = 0, iheight = 0;
    std::uint32_t top_margin = 0, left_margin = 0;
    double pixel_aspect = 1.0;
};

struct RawMetadata {
    std::string libraw_version;
    std::uint32_t libraw_capabilities = 0;
    std::string make, model, decoder_name;
    RawSourceSizes sizes_before_postprocess;
    int raw_flip = 0;
    std::array<float, 4> camera_whitebalance{};
    // scale_colors() replaces daylight pre_mul with the selected WB and
    // normalises it. These are the multipliers after that processing step.
    std::array<float, 4> post_scale_pre_mul{};
    bool as_shot_wb_applied = false;
    std::uint32_t black = 0;
    // Includes common black; a repeated spatial black pattern, if present,
    // remains separate because it cannot be represented by four scalars.
    std::array<std::uint32_t, 4> black_level_per_channel{};
    std::uint32_t black_pattern_rows = 0, black_pattern_cols = 0;
    std::vector<std::uint32_t> black_pattern;
    std::uint32_t white_level = 0;
    // All zero means the camera did not supply per-channel white levels.
    std::array<std::uint32_t, 4> camera_white_level_per_channel{};
    std::uint32_t postprocess_black = 0, postprocess_maximum = 0;
    std::uint32_t process_warnings = 0;
    // Row-major 3 x 4 camera-to-linear-sRGB matrix used by LibRaw.
    std::array<float, 12> rgb_cam{};
    // Opt-in headroom policy only. The matrix is LibRaw's actual camera-to-
    // ProPhoto matrix, captured at its float conversion boundary. The scale
    // restores the min-WB exposure convention after max-WB normalisation.
    bool headroom_enabled = false;
    double white_balance_exposure_restore = 1.0;
    std::array<float, 12> camera_to_output{};
};

struct DecodedRaw {
    std::uint32_t width = 0, height = 0;
    // Packed top-down RGB, with RAW orientation already applied by LibRaw.
    // Linear LibRaw ProPhoto (output_color=4). Compatible16 is in [0,1] and
    // comes from a clipped/quantised uint16 result. Opt-in headroom retains
    // negative RGB from the colour matrix and values above one. Both policies
    // still use LibRaw's integer black subtraction and uint16 demosaicing;
    // neither recovers clipped sensor samples or below-black sensor values.
    std::vector<float> rgb;
    RawMetadata metadata;
    RawDecodeTimings timings;
};

// Fixed compatibility policy matching tools/rawpy_to_f32.py: full-size AHD,
// valid camera/as-shot WB, ProPhoto, gamma=(1,1), output_bps=16, bright=1,
// no automatic brightening or maximum adjustment, highlight clipping, and
// default RAW orientation. scale_colors() remains enabled for WB and scaling.
// No user black/white overrides, exposure adjustment, ICC profile or resize.
// On failure, out is unchanged and error describes the failed stage.
bool decode_raw_compatible(const std::filesystem::path& source,
                           DecodedRaw& out, std::string& error);

// Experimental expanded-output policy for conventional three-colour Bayer
// RAW only. As-shot WB is normalised by its largest multiplier (highlight=1)
// before uint16 AHD demosaicing. LibRaw's actual ProPhoto matrix is evaluated
// without output clipping, then exposure is restored by 1/min(applied WB).
// This is not an all-float RAW decoder. AHD can change with scaling, so even
// non-clipped pixels need not equal the compatibility policy byte for byte.
// Unsupported sensor/layout/WB cases fail explicitly; compatible16 is never
// substituted. On failure, out is unchanged.
bool decode_raw_headroom(const std::filesystem::path& source,
                         DecodedRaw& out, std::string& error);

}  // namespace spk::io
