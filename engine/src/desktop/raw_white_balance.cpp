#include "raw_white_balance.hpp"
// The host's Temperature/Tint arithmetic (engine/host is spektralab-host's
// directory; its white_balance.cpp is compiled into spk_desktop_host too).
#include "../../host/white_balance.hpp"
// TIFF/JPEG/PNG at the door (decode_flat), the host's own reader.
#include "../../host/image_io.hpp"

#include <libraw/libraw.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <stdexcept>

namespace spk::desktop {
namespace {

bool invert(const std::array<double, 9>& m, std::array<double, 9>& out) {
    const double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    const double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (!std::isfinite(det) || std::fabs(det) < 1e-12) return false;
    out = {(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
           (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
           (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det};
    return true;
}

}  // namespace

WhiteBalance white_balance(const RenderSettings& settings) {
    return {std::get<std::string>(settings.get("white_balance")),
            std::get<double>(settings.get("white_balance_temperature")),
            std::get<double>(settings.get("white_balance_tint"))};
}

void set_white_balance(RenderSettings& settings, const WhiteBalance& value) {
    const auto* row = find_setting("white_balance");
    if (!row || !check_setting(*row, value.mode).empty())
        throw std::invalid_argument("Unknown white balance: " + value.mode);
    settings.set("white_balance", value.mode);
    settings.set("white_balance_temperature", value.temperature);
    settings.set("white_balance_tint", value.tint);
}

const std::vector<WhiteBalancePreset>& white_balance_presets() {
    static const std::vector<WhiteBalancePreset> presets{
        {"as_shot", "As Shot", 0.0},       {"daylight", "Daylight", 5500.0}, {"cloudy", "Cloudy", 6500.0},
        {"shade", "Shade", 7500.0},        {"tungsten", "Tungsten", 3200.0}, {"fluorescent", "Fluorescent", 4000.0}};
    return presets;
}

bool same_decode(const RenderSettings& a, const RenderSettings& b) {
    const WhiteBalance x = white_balance(a), y = white_balance(b);
    if (x.as_shot() || y.as_shot()) return x.as_shot() == y.as_shot();
    return x.temperature == y.temperature && x.tint == y.tint;
}

bool as_shot_white_balance(const io::RawMetadata& metadata, double& temperature, double& tint) {
    if (metadata.colors != 3) return false;
    const auto& mul = metadata.camera_whitebalance;
    if (!(mul[0] > 0 && mul[1] > 0 && mul[2] > 0)) return false;
    return spkhost::temperature_tint_for(metadata.xyz_to_camera, {1.0 / mul[0], 1.0 / mul[1], 1.0 / mul[2]},
                                         temperature, tint);
}

bool flat_file(const std::filesystem::path& source) {
    const auto kind = spkhost::sniff_kind(source);
    return kind == spkhost::FileKind::Tiff || kind == spkhost::FileKind::Jpeg || kind == spkhost::FileKind::Png;
}

namespace {

// A flat file at the door: its own encoding off, linear ProPhoto out, the
// shooting data its EXIF carries for the date back and the film edge (only
// the fields image_io reads; one it lacks stays absent, never invented).
bool decode_flat(const std::filesystem::path& source, io::DecodedRaw& out, std::string& error) {
    const auto started = std::chrono::steady_clock::now();
    spkhost::FloatImage image;
    spkhost::Probe probe;
    std::string space;
    if (!spkhost::decode_linear_prophoto(source, {}, image, probe, error, &space)) return false;
    if (image.width == 0 || image.height == 0 || image.rgb.size() != std::size_t(image.width) * image.height * 3) {
        error = "the decoded frame has no pixels";
        return false;
    }
    io::DecodedRaw decoded;
    decoded.width = image.width;
    decoded.height = image.height;
    decoded.rgb = std::move(image.rgb);
    const auto& meta = probe.metadata;
    decoded.metadata.make = meta.make;
    decoded.metadata.model = meta.model;
    std::string kind = spkhost::kind_name(probe.kind);
    for (char& c : kind) c = char(std::toupper(static_cast<unsigned char>(c)));
    decoded.metadata.decoder_name = kind + ", " + space;
    auto& shooting = decoded.metadata.shooting;
    int year = 0, month = 0, day = 0;
    if (meta.datetime_original.size() >= 10 &&
        std::sscanf(meta.datetime_original.c_str(), "%d:%d:%d", &year, &month, &day) == 3 && year > 0 && month >= 1 &&
        month <= 12 && day >= 1 && day <= 31) {
        shooting.year = year;
        shooting.month = month;
        shooting.day = day;
    }
    if (meta.shutter_s && *meta.shutter_s > 0) shooting.exposure_time = *meta.shutter_s;
    if (meta.aperture && *meta.aperture > 0) shooting.f_number = *meta.aperture;
    decoded.timings.total_ms = decoded.timings.convert_ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    out = std::move(decoded);
    return true;
}

}  // namespace

bool decode_raw(const std::filesystem::path& source, DecodeMode mode, const RenderSettings& settings,
                io::DecodedRaw& out, std::string& error) {
    // A flat file has no camera to balance and one decode (header above).
    if (flat_file(source)) return decode_flat(source, out, error);
    const WhiteBalance wb = white_balance(settings);
    std::array<float, 4> mul{};
    const std::array<float, 4>* user = nullptr;
    double header_ms = 0.0;
    if (!wb.as_shot()) {
        // The matrix is the file's, so the header is read before the decode:
        // open_file identifies the camera and fills cam_xyz without unpacking.
        const auto started = std::chrono::steady_clock::now();
        auto raw = std::make_unique<LibRaw>(LIBRAW_OPTIONS_NO_DATAERR_CALLBACK);
        const int status = raw->open_file(source.c_str());
        if (status != LIBRAW_SUCCESS) {
            error = std::string("RAW open: ") + LibRaw::strerror(status);
            return false;
        }
        if (!spkhost::multipliers_for(*raw, wb.temperature, wb.tint, mul, error)) {
            error = "White balance: " + error;
            return false;
        }
        user = &mul;
        header_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    }
    const bool ok = mode == DecodeMode::headroom ? io::decode_raw_headroom(source, user, out, error)
                                                 : io::decode_raw_compatible(source, user, out, error);
    // The header read is part of opening the file, and is reported as such.
    if (ok) {
        out.timings.open_ms += header_ms;
        out.timings.total_ms += header_ms;
    }
    return ok;
}

std::array<double, 9> camera_to_output(const io::RawMetadata& metadata) {
    std::array<double, 9> m{};
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) {
            if (metadata.headroom_enabled) {
                m[r * 3 + c] = metadata.camera_to_output[r * 4 + c];
            } else {
                // convert_to_rgb, output_color 4: out_cam = prophoto_rgb . rgb_cam.
                double v = 0.0;
                for (int k = 0; k < 3; ++k) v += LibRaw_constants::prophoto_rgb[r][k] * metadata.rgb_cam[k * 4 + c];
                m[r * 3 + c] = v;
            }
        }
    return m;
}

bool neutral_white_balance(const std::array<double, 9>& xyz_to_camera, const std::array<double, 9>& to_output,
                           const std::array<double, 3>& applied, const std::array<double, 3>& rgb,
                           double& temperature, double& tint, std::string& error) {
    std::array<double, 9> inverse;
    if (!invert(to_output, inverse)) {
        error = "the decode's colour matrix cannot be inverted";
        return false;
    }
    std::array<double, 3> camera{};
    for (int r = 0; r < 3; ++r) {
        const double scaled = inverse[r * 3] * rgb[0] + inverse[r * 3 + 1] * rgb[1] + inverse[r * 3 + 2] * rgb[2];
        if (!(applied[r] > 0.0) || !(scaled > 0.0)) {
            error = "this point holds a colour no white balance can neutralise";
            return false;
        }
        camera[r] = scaled / applied[r];
    }
    if (!spkhost::temperature_tint_for(xyz_to_camera, camera, temperature, tint)) {
        error = "this camera has no three-colour matrix in LibRaw; white balance cannot be set";
        return false;
    }
    return true;
}

bool neutral_white_balance(const io::RawMetadata& metadata, const std::array<double, 3>& rgb, double& temperature,
                           double& tint, std::string& error) {
    if (metadata.colors != 3) {
        error = "this camera has no three-colour matrix in LibRaw; white balance cannot be set";
        return false;
    }
    const auto& pre = metadata.post_scale_pre_mul;
    return neutral_white_balance(metadata.xyz_to_camera, camera_to_output(metadata), {pre[0], pre[1], pre[2]}, rgb,
                                 temperature, tint, error);
}

bool sample_decoded(const io::DecodedRaw& decoded, double x, double y, int radius, std::array<double, 3>& rgb,
                    std::string& error) {
    const auto w = std::int64_t(decoded.width), h = std::int64_t(decoded.height);
    if (w <= 0 || h <= 0 || decoded.rgb.size() != std::size_t(w * h * 3) || !std::isfinite(x) || !std::isfinite(y) ||
        radius < 0) {
        error = "no decoded photograph to sample";
        return false;
    }
    const std::int64_t cx = std::clamp<std::int64_t>(std::int64_t(std::floor(x * double(w))), 0, w - 1);
    const std::int64_t cy = std::clamp<std::int64_t>(std::int64_t(std::floor(y * double(h))), 0, h - 1);
    // Compatible16 is [0, 1] by construction and 1 is its clip; headroom has
    // no ceiling.
    const bool clips = !decoded.metadata.headroom_enabled;
    double sum[3] = {0, 0, 0};
    std::int64_t count = 0;
    for (std::int64_t row = std::max<std::int64_t>(0, cy - radius); row <= std::min(h - 1, cy + radius); ++row)
        for (std::int64_t col = std::max<std::int64_t>(0, cx - radius); col <= std::min(w - 1, cx + radius); ++col) {
            const float* p = decoded.rgb.data() + std::size_t(row * w + col) * 3;
            for (int c = 0; c < 3; ++c) {
                if (clips && p[c] >= 1.0f) {
                    error = "this point is clipped in the RAW; pick a neutral that is not white";
                    return false;
                }
                sum[c] += p[c];
            }
            ++count;
        }
    for (int c = 0; c < 3; ++c) rgb[c] = sum[c] / double(count);
    if (!(rgb[0] > 0.0 && rgb[1] > 0.0 && rgb[2] > 0.0)) {
        error = "this point is black in the RAW; pick a neutral that holds some light";
        return false;
    }
    return true;
}

}  // namespace spk::desktop
