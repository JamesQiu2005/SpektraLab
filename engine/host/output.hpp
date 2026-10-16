// output.hpp -- leaving the working space, and writing files.
//
// The engine renders encoded ProPhoto RGB (the session's resolved
// `io.output_color_space`). A display or a file wants another space, and the
// conversion is the one the macOS canvas runs (`Canvas/Shaders.metal`
// `outputTransform`, RFC-018 §5.4): the source curve off, the engine's
// CAT02-adapted matrix, CAM16-UCS gamut compression into the target, the
// target curve on. Every number comes from `spk_output_transform`; this file
// only does the per-pixel arithmetic, in float32 as the shader does.
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include "spektrafilm/spk_engine.h"

namespace spkhost {

// "srgb" / "sRGB" -> "sRGB", "display-p3" -> "Display P3",
// "prophoto" -> "ProPhoto RGB". Empty on an unknown name.
std::string engine_space_name(const std::string& wire);

// What OutputTransform runs per pixel, as numbers -- for a caller that runs
// the same arithmetic itself (the Windows canvas soft proof evaluates it in its
// fragment shader, as the macOS canvas shader's `outputTransform` does). The
// table pointer is valid as long as the transform it came from.
struct OutputTransformParameters {
    uint32_t source_mode = 0, target_mode = 0;   // cctf_decode_mode / cctf_encode_mode
    bool identity = false;                        // source is target: decode only
    std::array<float, 9> matrix{};                // row-major, source linear -> target linear
    bool cam16 = false, lightness = false;
    std::array<float, 9> m_to_xyz{}, m_to_rgb{};  // row-major
    std::array<float, 22> k{};
    uint32_t cmax_rows = 0, cmax_cols = 0;        // C_max(J', h'): rows L, columns h
    const float* cmax = nullptr;                  // rows * cols, row-major
};

class OutputTransform {
public:
    // `gamut_compress_json` as spk_output_transform takes it; null is the
    // session default (CAM16-UCS with lightness compression).
    bool fetch(spk_engine* engine, const std::string& src, const std::string& dst, std::string& error,
               const char* gamut_compress_json = nullptr);
    const std::string& target() const { return dst_; }
    bool identity() const { return identity_; }
    // Encoded source RGBA16 (row stride in pixels) -> linear target RGB float.
    void to_linear(const uint16_t* rgba16, uint32_t width, uint32_t height, uint32_t stride_px,
                   std::vector<float>& rgb) const;
    // Linear target RGB -> encoded target, then quantised.
    void encode_rgba8(const std::vector<float>& rgb, std::vector<uint8_t>& rgba) const;
    void encode_rgba16(const std::vector<float>& rgb, std::vector<uint16_t>& rgba) const;
    uint32_t target_mode() const { return dst_mode_; }
    uint32_t source_mode() const { return src_mode_; }
    bool compresses() const { return cam16_; }

    // The same per-pixel arithmetic as to_linear on unquantised input, for a
    // caller that samples the transform on a grid (the Windows soft proof's
    // LUT): `count` interleaved encoded source RGB triples -> linear target
    // RGB, unclamped. `outside`, when not null, receives per pixel whether the
    // destination could not hold its chroma -- d > 1 before the knee, the
    // macOS canvas shader's `outside` (Canvas/Shaders.metal cam16ucsInto,
    // stats[2]), the number its export warning reports. Always 0 without the
    // CAM16 step.
    void transform_encoded(const float* encoded_rgb, size_t count, float* linear_rgb,
                           uint8_t* outside = nullptr) const;
    // Copy the engine's C_max table into this object, so it outlives the
    // engine it was fetched from (a worker thread evaluating it later).
    void own_tables();
    OutputTransformParameters parameters() const;

private:
    std::string src_, dst_;
    bool identity_ = false;
    uint32_t src_mode_ = 0, dst_mode_ = 0;
    std::array<float, 9> matrix_{};
    bool cam16_ = false, lightness_ = false;
    std::array<float, 9> m2x_{}, m2r_{};
    std::array<float, 22> k_{};
    uint32_t nl_ = 0, nh_ = 0;
    const float* cmax_ = nullptr;
    // own_tables()'s copy; when present it is the table (copies stay valid).
    std::vector<float> owned_cmax_;
    const float* table() const { return owned_cmax_.empty() ? cmax_ : owned_cmax_.data(); }
};

float cctf_decode_mode(float v, uint32_t mode);
float cctf_encode_mode(float v, uint32_t mode);

// --- files -----------------------------------------------------------------

// An ICC profile describing `space` ("sRGB" uses the bundled resource).
bool icc_for(const std::string& engine_space, const std::filesystem::path& resources,
             std::vector<uint8_t>& icc, std::string& error);

// The shooting data a written file carries (EXIF): what the frame came from,
// never what it was before the host turned it upright (Orientation is 1).
struct Exif {
    std::string make, model, lens, datetime_original;   // EXIF "YYYY:MM:DD HH:MM:SS"
    double iso = 0, shutter_s = 0, aperture = 0, focal_mm = 0;   // 0 = absent
    // EXIF ColorSpace (0xA001): 1 sRGB, 0xFFFF uncalibrated (any other tag,
    // or none -- macOS marks the Digital Intermediate so); 0 = not written.
    uint16_t color_space = 0;
};

// A second TIFF page (IFD1, NewSubfileType 1): an 8-bit interleaved RGB
// picture of the first, with its own profile -- the macOS export's preview
// page (Exporter.swift `write`, AGENTS.md trap 29: read it by index).
struct TiffPreview {
    const uint8_t* rgb = nullptr;
    uint32_t width = 0, height = 0;
    std::vector<uint8_t> icc;
};

// Interleaved 3-channel encoded samples. `exif` and `preview` may be null.
bool encode_tiff(const void* rgb, uint32_t width, uint32_t height, uint32_t bits,
                 const std::vector<uint8_t>& icc, std::vector<uint8_t>& out, std::string& error,
                 const Exif* exif = nullptr, const TiffPreview* preview = nullptr);
bool encode_png8(const uint8_t* rgb, uint32_t width, uint32_t height, const std::vector<uint8_t>& icc,
                 std::vector<uint8_t>& out, std::string& error, const Exif* exif = nullptr);
bool encode_jpeg(const uint8_t* rgb, uint32_t width, uint32_t height, int quality,
                 const std::vector<uint8_t>& icc, std::vector<uint8_t>& out, std::string& error,
                 const Exif* exif = nullptr);
// A complete little-endian TIFF-structured EXIF block (JPEG APP1 after
// "Exif\0\0", PNG eXIf).
std::vector<uint8_t> exif_block(const Exif& exif, uint32_t width, uint32_t height);
// A .cube from spk_print_lut_table's (S,S,S,3) [r][g][b] table, domain 0..1.
std::string cube_text(const float* table, uint32_t size, const std::string& title);

}  // namespace spkhost
