#include "raw_decoder.hpp"
#include "raw_headroom.hpp"

#include <libraw/libraw.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <exception>
#include <limits>
#include <iterator>
#include <memory>
#include <utility>

namespace spk::io {
namespace {

using Clock = std::chrono::steady_clock;

double elapsed_ms(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

bool libraw_ok(int status, const char* stage, std::string& error) {
    if (status == LIBRAW_SUCCESS) return true;
    error = std::string(stage) + ": " + LibRaw::strerror(status) +
            " (" + std::to_string(status) + ")";
    return false;
}

bool supported_compression(LibRaw& raw, std::string& error) {
    const char* decoder = raw.unpack_function_name();
    if (decoder && std::strstr(decoder, "nikon_he_load_raw") != nullptr) {
        const auto& model = raw.imgdata.idata.model;
        error = "RAW unpack (" +
            std::string(std::begin(model), std::find(std::begin(model), std::end(model), '\0')) +
            "): Nikon HE/HE* compression is not supported by bundled LibRaw " +
            LibRaw::version() +
            "; use a lossless-compressed NEF or externally converted RAW DNG";
        return false;
    }
    return true;
}

void configure_compatible(libraw_output_params_t& params) {
    params.user_qual = 3;  // AHD (LibRaw still selects its native X-Trans path).
    params.half_size = 0;
    params.four_color_rgb = 0;
    params.output_color = 4;
    params.output_bps = 16;
    params.gamm[0] = params.gamm[1] = 1.0;
    params.no_auto_bright = 1;
    params.no_auto_scale = 0;
    params.adjust_maximum_thr = 0.0f;
    params.bright = 1.0f;
    params.use_camera_wb = 1;
    params.use_auto_wb = 0;
    params.use_camera_matrix = 1;
    std::fill(std::begin(params.user_mul), std::end(params.user_mul), 0.0f);
    params.user_black = -1;
    std::fill(std::begin(params.user_cblack), std::end(params.user_cblack), -1000001);
    params.user_sat = -1;
    params.user_flip = -1;
    params.highlight = 0;
    params.exp_correc = 0;
    params.exp_shift = 1.0f;
    params.exp_preser = 0.0f;
    params.threshold = 0.0f;
    params.med_passes = 0;
    params.fbdd_noiserd = 0;
    params.dcb_iterations = 0;
    params.dcb_enhance_fl = 0;
    params.no_interpolation = 0;
    params.output_profile = nullptr;
    params.camera_profile = nullptr;
}

bool capture_source_metadata(const LibRaw& raw, RawMetadata& metadata,
                             std::string& error) {
    const auto& data = raw.imgdata;
    // raw2image_start() restores this saved copy before postprocessing; rawpy
    // reads its source WB and white-level metadata from the same structure.
    const auto& color = data.rawdata.color;
    const auto& sizes = data.sizes;
    for (unsigned c = 0; c < 4; ++c) {
        const float wb = color.cam_mul[c];
        // LibRaw falls back to auto WB when red <= 1e-5, even if the value
        // is positive. Do not report that fallback as camera/as-shot WB.
        if (!std::isfinite(wb) || (c < 3 && wb <= 0.00001f)) {
            error = "RAW metadata: valid camera/as-shot RGB white balance is required";
            return false;
        }
        metadata.camera_whitebalance[c] = wb;
        const std::uint64_t black = std::uint64_t(color.black) + color.cblack[c];
        if (black > std::numeric_limits<std::uint32_t>::max()) {
            error = "RAW metadata: black level overflow";
            return false;
        }
        metadata.black_level_per_channel[c] = static_cast<std::uint32_t>(black);
        metadata.camera_white_level_per_channel[c] = color.linear_max[c];
    }
    metadata.libraw_version = LibRaw::version();
    metadata.libraw_capabilities = LibRaw::capabilities();
    metadata.make.assign(data.idata.make,
                         std::find(std::begin(data.idata.make), std::end(data.idata.make), '\0'));
    metadata.model.assign(data.idata.model,
                          std::find(std::begin(data.idata.model), std::end(data.idata.model), '\0'));
    metadata.sizes_before_postprocess = {
        sizes.raw_width, sizes.raw_height, sizes.width, sizes.height,
        sizes.iwidth, sizes.iheight, sizes.top_margin, sizes.left_margin,
        sizes.pixel_aspect};
    metadata.raw_flip = sizes.flip;
    metadata.as_shot_wb_applied = color.as_shot_wb_applied != 0;
    metadata.black = color.black;
    metadata.white_level = color.maximum;
    metadata.black_pattern_rows = color.cblack[4];
    metadata.black_pattern_cols = color.cblack[5];
    const std::uint64_t pattern_size =
        std::uint64_t(color.cblack[4]) * color.cblack[5];
    constexpr std::size_t pattern_capacity = sizeof(color.cblack) / sizeof(color.cblack[0]) - 6;
    if (pattern_size > pattern_capacity) {
        error = "RAW metadata: repeated black-level pattern exceeds storage";
        return false;
    }
    metadata.black_pattern.assign(color.cblack + 6,
                                  color.cblack + 6 + static_cast<std::size_t>(pattern_size));
    return true;
}

bool supported_headroom_source(LibRaw& raw, std::string& error) {
    const auto& data = raw.imgdata;
    if (data.idata.colors != 3 || data.idata.filters <= 1000 ||
        data.idata.is_foveon || raw.is_floating_point() ||
        raw.is_sraw() || raw.is_nikon_sraw() ||
        data.rawdata.color.as_shot_wb_applied ||
        raw.is_fuji_rotated() || data.sizes.pixel_aspect != 1.0 ||
        data.idata.cdesc[0] != 'R' || data.idata.cdesc[1] != 'G' ||
        data.idata.cdesc[2] != 'B') {
        error = "RAW headroom: only conventional three-colour Bayer RAW with unapplied "
                "as-shot WB and square pixels is supported; use compatible16 for this source";
        return false;
    }
    unsigned counts[3] = {};
    for (int row = 0; row < 8; ++row) {
        for (int col = 0; col < 2; ++col) {
            const int c = raw.FC(row, col);
            if (c != raw.FC(row % 2, col)) {
                error = "RAW headroom: a nonstandard Bayer pattern is unsupported";
                return false;
            }
            if (row < 2) ++counts[c == 3 ? 1 : c];
        }
    }
    // Two greens must occupy opposite corners, as in the four Bayer layouts.
    const auto channel = [&raw](int row, int col) {
        const int c = raw.FC(row, col);
        return c == 3 ? 1 : c;
    };
    if (counts[0] != 1 || counts[1] != 2 || counts[2] != 1 ||
        (channel(0, 0) == 1) != (channel(1, 1) == 1)) {
        error = "RAW headroom: a nonstandard Bayer pattern is unsupported";
        return false;
    }
    return true;
}

class HeadroomLibRaw final : public LibRaw {
public:
    HeadroomLibRaw() : LibRaw(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK) {}

    std::vector<float> converted;
    std::uint32_t converted_width = 0, converted_height = 0;
    std::array<float, 12> matrix{};
    double exposure_restore = 1.0;
    double conversion_ms = 0.0;
    bool conversion_finished = false;
    std::string conversion_error;

protected:
    void convert_to_rgb_loop(float out_cam[3][4]) override {
        const auto start = Clock::now();
        if (libraw_internal_data.internal_output_params.raw_color ||
            imgdata.idata.colors != 3 || !imgdata.image) {
            conversion_error = "RAW headroom: no supported three-channel camera-to-ProPhoto transform";
            return;
        }
        std::array<float, 4> applied_wb{};
        std::copy(std::begin(imgdata.color.pre_mul), std::end(imgdata.color.pre_mul),
                  applied_wb.begin());
        if (!detail::headroom_exposure_restore(applied_wb, exposure_restore, conversion_error))
            return;
        for (unsigned row = 0; row < 3; ++row)
            for (unsigned col = 0; col < 4; ++col)
                matrix[row * 4 + col] = out_cam[row][col];
        const auto& sizes = imgdata.sizes;
        conversion_finished = detail::convert_camera_rgb_headroom(
            imgdata.image[0], std::size_t(sizes.width) * sizes.height,
            sizes.width, sizes.height, sizes.flip, matrix, exposure_restore,
            converted, converted_width, converted_height, conversion_error);
        conversion_ms = elapsed_ms(start);
        // dcraw_process may continue its bookkeeping; no clipped uint16 output
        // is subsequently used, and the supported square-pixel Bayer inputs
        // require no post-conversion geometric resampling.
    }
};

}  // namespace

bool decode_raw_compatible(const std::filesystem::path& source,
                           DecodedRaw& out, std::string& error) {
    error.clear();
    const auto total_start = Clock::now();
    try {
        if (source.empty()) {
            error = "RAW open: source path is empty";
            return false;
        }
        // LibRaw carries substantial metadata; keep it off the Windows stack.
        auto raw = std::make_unique<LibRaw>(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK);
        configure_compatible(raw->imgdata.params);
        DecodedRaw decoded;
        auto start = Clock::now();
        // filesystem::path::value_type is wchar_t on Windows, selecting
        // LibRaw's Unicode filename overload without an ANSI conversion.
        const int open_status = raw->open_file(source.c_str());
        decoded.timings.open_ms = elapsed_ms(start);
        if (!libraw_ok(open_status, "RAW open", error)) return false;
        if (!supported_compression(*raw, error)) return false;

        start = Clock::now();
        const int unpack_status = raw->unpack();
        decoded.timings.unpack_ms = elapsed_ms(start);
        if (!libraw_ok(unpack_status, "RAW unpack", error)) return false;
        if (raw->error_count() != 0) {
            error = "RAW unpack: decoder reported corrupt data";
            return false;
        }
        if (!capture_source_metadata(*raw, decoded.metadata, error)) return false;
        if (const char* name = raw->unpack_function_name()) decoded.metadata.decoder_name = name;

        start = Clock::now();
        const int process_status = raw->dcraw_process();
        decoded.timings.process_ms = elapsed_ms(start);
        if (!libraw_ok(process_status, "RAW process", error)) return false;
        if (raw->error_count() != 0) {
            error = "RAW process: decoder reported corrupt data";
            return false;
        }
        const auto& color = raw->imgdata.color;
        decoded.metadata.process_warnings = raw->imgdata.process_warnings;
        if (decoded.metadata.process_warnings & LIBRAW_WARN_BAD_CAMERA_WB) {
            error = "RAW process: LibRaw rejected camera/as-shot white balance";
            return false;
        }
        std::copy(std::begin(color.pre_mul), std::end(color.pre_mul),
                  decoded.metadata.post_scale_pre_mul.begin());
        for (unsigned c = 0; c < 4; ++c) {
            if (!std::isfinite(color.pre_mul[c]) || color.pre_mul[c] <= 0.0f) {
                error = "RAW process: invalid applied white-balance multiplier";
                return false;
            }
        }
        for (unsigned row = 0; row < 3; ++row)
            for (unsigned col = 0; col < 4; ++col)
                decoded.metadata.rgb_cam[row * 4 + col] = color.rgb_cam[row][col];
        decoded.metadata.postprocess_black = color.black;
        decoded.metadata.postprocess_maximum = color.maximum;

        // This also performs LibRaw's final orientation and identity gamma
        // lookup. Reading imgdata.image directly would omit those semantics.
        start = Clock::now();
        int image_status = LIBRAW_SUCCESS;
        using ImagePtr = std::unique_ptr<libraw_processed_image_t,
                                         decltype(&LibRaw::dcraw_clear_mem)>;
        ImagePtr image(raw->dcraw_make_mem_image(&image_status), &LibRaw::dcraw_clear_mem);
        if (!libraw_ok(image_status, "RAW output", error)) return false;
        if (!image || image->type != LIBRAW_IMAGE_BITMAP || image->bits != 16 ||
            image->colors != 3 || image->width == 0 || image->height == 0) {
            error = "RAW output: expected a non-empty 16-bit three-channel bitmap";
            return false;
        }
        const std::uint64_t samples = std::uint64_t(image->width) * image->height * 3;
        if (samples > std::numeric_limits<std::size_t>::max() / sizeof(float) ||
            samples * sizeof(std::uint16_t) != image->data_size) {
            error = "RAW output: inconsistent image byte count or unsupported dimensions";
            return false;
        }
        decoded.width = image->width;
        decoded.height = image->height;
        decoded.rgb.resize(static_cast<std::size_t>(samples));
        for (std::size_t i = 0; i < decoded.rgb.size(); ++i) {
            std::uint16_t value;
            // LibRaw returns native-endian 16-bit samples. memcpy avoids
            // imposing alignment or aliasing assumptions on its byte array.
            std::memcpy(&value, image->data + i * sizeof(value), sizeof(value));
            decoded.rgb[i] = static_cast<float>(static_cast<double>(value) / 65535.0);
        }
        decoded.timings.convert_ms = elapsed_ms(start);
        decoded.timings.total_ms = elapsed_ms(total_start);
        out = std::move(decoded);
        return true;
    } catch (const std::exception& exception) {
        error = std::string("RAW decode: ") + exception.what();
        return false;
    } catch (...) {
        error = "RAW decode: unknown decoder exception";
        return false;
    }
}

bool decode_raw_headroom(const std::filesystem::path& source,
                         DecodedRaw& out, std::string& error) {
    error.clear();
    const auto total_start = Clock::now();
    try {
        if (source.empty()) {
            error = "RAW open: source path is empty";
            return false;
        }
        auto raw = std::make_unique<HeadroomLibRaw>();
        configure_compatible(raw->imgdata.params);
        // LibRaw's Ignore mode prevents WB multipliers above one, but does not
        // reconstruct sensor saturation and still uses uint16 intermediates.
        raw->imgdata.params.highlight = 1;
        DecodedRaw decoded;
        auto start = Clock::now();
        const int open_status = raw->open_file(source.c_str());
        decoded.timings.open_ms = elapsed_ms(start);
        if (!libraw_ok(open_status, "RAW open", error)) return false;
        if (!supported_compression(*raw, error)) return false;

        start = Clock::now();
        const int unpack_status = raw->unpack();
        decoded.timings.unpack_ms = elapsed_ms(start);
        if (!libraw_ok(unpack_status, "RAW unpack", error)) return false;
        if (raw->error_count() != 0) {
            error = "RAW unpack: decoder reported corrupt data";
            return false;
        }
        if (!capture_source_metadata(*raw, decoded.metadata, error) ||
            !supported_headroom_source(*raw, error)) return false;
        if (const char* name = raw->unpack_function_name()) decoded.metadata.decoder_name = name;

        start = Clock::now();
        const int process_status = raw->dcraw_process();
        const double process_and_conversion_ms = elapsed_ms(start);
        decoded.timings.process_ms = std::max(0.0, process_and_conversion_ms - raw->conversion_ms);
        decoded.timings.convert_ms = raw->conversion_ms;
        if (!libraw_ok(process_status, "RAW process", error)) return false;
        if (raw->error_count() != 0) {
            error = "RAW process: decoder reported corrupt data";
            return false;
        }
        decoded.metadata.process_warnings = raw->imgdata.process_warnings;
        if (decoded.metadata.process_warnings & LIBRAW_WARN_BAD_CAMERA_WB) {
            error = "RAW process: LibRaw rejected camera/as-shot white balance";
            return false;
        }
        if (!raw->conversion_finished) {
            error = raw->conversion_error.empty()
                ? "RAW headroom: float colour conversion did not run" : raw->conversion_error;
            return false;
        }
        const auto& color = raw->imgdata.color;
        std::copy(std::begin(color.pre_mul), std::end(color.pre_mul),
                  decoded.metadata.post_scale_pre_mul.begin());
        for (unsigned row = 0; row < 3; ++row)
            for (unsigned col = 0; col < 4; ++col)
                decoded.metadata.rgb_cam[row * 4 + col] = color.rgb_cam[row][col];
        decoded.metadata.postprocess_black = color.black;
        decoded.metadata.postprocess_maximum = color.maximum;
        decoded.metadata.headroom_enabled = true;
        decoded.metadata.white_balance_exposure_restore = raw->exposure_restore;
        decoded.metadata.camera_to_output = raw->matrix;
        decoded.width = raw->converted_width;
        decoded.height = raw->converted_height;
        decoded.rgb = std::move(raw->converted);
        decoded.timings.total_ms = elapsed_ms(total_start);
        out = std::move(decoded);
        return true;
    } catch (const std::exception& exception) {
        error = std::string("RAW headroom decode: ") + exception.what();
        return false;
    } catch (...) {
        error = "RAW headroom decode: unknown decoder exception";
        return false;
    }
}

}  // namespace spk::io
