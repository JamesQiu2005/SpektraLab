// image_io.hpp -- what the host reads: RAW (LibRaw), TIFF, JPEG, PNG.
//
// The engine develops scene-linear radiance in linear ProPhoto RGB, top row
// first (`io.input_color_space` = "ProPhoto RGB", `input_cctf_decoding`
// false -- the convention `spk_open` and the macOS app's `ImageDecoder` share).
// Everything hard about external files is at that boundary (AGENTS.md traps
// 11 and 12), so this file is where a display-encoded file is decoded:
//
//   * RAW -> LibRaw, linear ProPhoto (`spk::io::decode_raw_*`).
//   * TIFF/JPEG/PNG with an embedded matrix/TRC ICC profile -> that profile's
//     curves off, its D50 colorants to XYZ, XYZ to linear ProPhoto. This is
//     what ColorSync/Core Image do for the same file on macOS.
//   * JPEG/PNG/8-bit TIFF without a profile -> sRGB (the web's and every
//     camera's default; Core Image assumes the same).
//   * 16-bit or float TIFF without a profile -> linear ProPhoto, as the macOS
//     decoder treats it (`ImageDecoder.swift`: an untagged deep TIFF is the
//     app's own linear export).
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace spkhost {

struct Metadata {
    std::string make, model, lens, datetime_original;
    std::optional<double> iso, shutter_s, aperture, focal_mm;
    int orientation = 1;   // EXIF 1..8, of the file as stored
    // RAW only: the as-shot illuminant as Temperature/Tint (white_balance.hpp).
    std::optional<double> as_shot_temperature_k, as_shot_tint;
};

enum class FileKind { Raw, Tiff, Jpeg, Png, Unknown };
const char* kind_name(FileKind kind);
FileKind sniff_kind(const std::filesystem::path& path);

struct Probe {
    FileKind kind = FileKind::Unknown;
    uint32_t width = 0, height = 0;   // as displayed (orientation applied)
    Metadata metadata;
};
bool probe_file(const std::filesystem::path& path, Probe& out, std::string& error);

// A 3-channel float image, top row first, tightly packed.
struct FloatImage {
    uint32_t width = 0, height = 0;
    std::vector<float> rgb;
};

struct Rgba8 {
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> rgba;
};

// The frame the engine develops: linear ProPhoto, orientation applied.
struct DecodeOptions {
    std::string raw_mode = "compatible16";   // or "headroom"
    // R2: a custom white balance at decode (RAW, compatible16 only).
    std::optional<double> temperature_k, tint;
};
// Thrown as a plain error string prefixed "unsupported:" when a decode option
// cannot be honoured for this file.
constexpr const char* kUnsupportedPrefix = "unsupported: ";
bool decode_linear_prophoto(const std::filesystem::path& path, const DecodeOptions& options,
                            FloatImage& out, Probe& probe, std::string& error);

// A display thumbnail, sRGB 8-bit, orientation applied, long edge <= long_edge.
// RAW: the embedded preview when there is one, else a half-size decode.
bool thumbnail(const std::filesystem::path& path, uint32_t long_edge, Rgba8& out,
               std::string& source, std::string& error);

// --- helpers shared with the writers ---------------------------------------

// Area-average resize of an interleaved float image.
void resize_area(const float* src, uint32_t sw, uint32_t sh, uint32_t channels,
                 uint32_t dw, uint32_t dh, std::vector<float>& dst);
// Apply an EXIF orientation (1..8) to an interleaved image of `channels`.
template <typename T>
void apply_orientation(std::vector<T>& pixels, uint32_t& width, uint32_t& height,
                       uint32_t channels, int orientation);

// A matrix/TRC RGB colour space read from an ICC profile (or built in).
struct Trc {
    enum class Kind { Gamma, Table, Para } kind = Kind::Gamma;
    double gamma = 1.0;
    std::vector<double> table;   // 0..1
    int para_type = 0;
    std::array<double, 7> p{};   // g a b c d e f
    double decode(double v) const;
};
struct RgbSpace {
    std::array<double, 9> to_xyz_d50{};   // row-major, linear RGB -> PCS XYZ
    std::array<Trc, 3> trc;
    std::string description;
};
bool parse_icc(const std::vector<uint8_t>& icc, RgbSpace& out, std::string& error);
RgbSpace srgb_space();
RgbSpace display_p3_space();
RgbSpace linear_prophoto_space();
// Encoded values (any range) -> linear ProPhoto, in place, 3 channels.
void to_linear_prophoto(const RgbSpace& space, std::vector<float>& rgb);

}  // namespace spkhost
