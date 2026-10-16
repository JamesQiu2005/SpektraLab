// raw_white_balance.hpp -- the macOS Camera section's white balance for the
// Windows desktop host: Temperature, Tint, As Shot and the presets
// (Controls/WhiteBalanceRows.swift, Model/Sidecar.swift DecodeSettings), and
// the neutral picker (Session.pickNeutral, Session.swift:2816-2831).
//
// It is a decode setting, not a wire field, exactly as on macOS, where it is
// CIRAWFilter's neutralTemperature/neutralTint (ImageDecoder.swift:233-238)
// and changing it re-decodes the file (Session.swift:2694-2725). Here it is
// LibRaw's own user multipliers through the same scale_colors() step
// (io::decode_raw_compatible / decode_raw_headroom), converted from
// Temperature/Tint by the host's DNG-SDK arithmetic (engine/host/
// white_balance.hpp) -- so a value means roughly what it means on macOS, and
// nothing is a second colour model.
//
// The settings live in three product rows of the settings table
// (white_balance, white_balance_temperature, white_balance_tint): stored,
// validated, saved, undone and synced like every row, and never sent.
#pragma once

#include "preview_host.hpp"

#include <array>
#include <filesystem>
#include <string>
#include <vector>

namespace spk::desktop {

// macOS DecodeSettings.WhiteBalance (Sidecar.swift:8-20), by the row's ids.
// "as_shot" follows the camera and ignores the two numbers; a preset is its
// Kelvin at tint 0; "custom" is the two numbers.
struct WhiteBalance {
    std::string mode = "as_shot";
    double temperature = 5500.0, tint = 0.0;
    bool as_shot() const { return mode == "as_shot"; }
};
WhiteBalance white_balance(const RenderSettings& settings);
// Writes the three rows; throws std::invalid_argument for an unknown mode.
void set_white_balance(RenderSettings& settings, const WhiteBalance& value);

// The presets macOS's Camera menu offers (CameraSection.swift:128-137: every
// mode but Custom), in its order: As Shot (kelvin 0), Daylight 5500, Cloudy
// 6500, Shade 7500, Tungsten 3200, Fluorescent 4000.
struct WhiteBalancePreset {
    const char* id;
    const char* label;   // macOS's names, which it leaves in English
    double kelvin;       // 0 for As Shot
};
const std::vector<WhiteBalancePreset>& white_balance_presets();

// Whether two settings decode the same pixels: both As Shot, or both the same
// Temperature and Tint (a preset and Custom at its numbers are one decode).
bool same_decode(const RenderSettings& a, const RenderSettings& b);

// The camera's own illuminant, as Temperature/Tint, from a decode's metadata
// (its cam_mul and LibRaw's XYZ->camera matrix). False for a camera LibRaw
// has no three-colour matrix for: its white balance cannot be moved, and the
// Camera section's rows are disabled for it.
bool as_shot_white_balance(const io::RawMetadata& metadata, double& temperature, double& tint);

// Decodes `source` in `mode` with the settings' white balance: As Shot is the
// decoder's own as-shot path, byte for byte what it was before this file;
// anything else reads LibRaw's matrix from the file's header (open_file, no
// unpack) and hands the decoder the multipliers that neutralise it; that
// header read is counted in `out.timings.open_ms`. On failure `out` is
// unchanged and `error` says why.
//
// A TIFF, JPEG or PNG is decoded here too, at the door (AGENTS.md trap 12):
// engine/host/image_io's decode_linear_prophoto takes the file's embedded
// matrix/TRC profile (or the macOS decoder's assumptions -- an untagged 8-bit
// file is sRGB, an untagged deep TIFF linear ProPhoto; ImageDecoder.swift
// decodeFlat, :266-288) off its transfer function and into linear ProPhoto,
// so the engine's input contract -- scene-linear, `input_cctf_decoding`
// false -- holds for every file it is handed. A flat file is already a
// rendering: it has no camera white balance (`metadata.colors` stays 0, so
// the Camera section's rows are disabled for it, as they are for a flat file
// on macOS) and `mode` changes nothing. `metadata.decoder_name` names the
// file and the space it was read in ("TIFF, sRGB IEC61966-2.1").
bool decode_raw(const std::filesystem::path& source, DecodeMode mode, const RenderSettings& settings,
                io::DecodedRaw& out, std::string& error);

// Whether `source` is a flat (encoded) file the decode above reads through
// image_io rather than LibRaw: by its signature, as image_io sniffs it, for
// anything without a RAW extension.
bool flat_file(const std::filesystem::path& source);

// --- the neutral picker ----------------------------------------------------
//
// macOS asks CIRAWFilter for "the temperature/tint that makes this point
// neutral" (ImageDecoder.neutral, :438-443). LibRaw has no such call, so it is
// done here the way the decode is built: the decoded value p at the point is
// camera_to_output . (applied ⊙ c) for the patch's camera response c, so
// c = (camera_to_output^-1 . p) / applied, and the illuminant whose neutral the
// camera records as c is the answer (white_balance.hpp temperature_tint_for).
// Decoding with that answer gives multipliers proportional to 1 / c: the
// patch comes out with R = G = B, which is what spk_qt_predev checks on a
// synthetic camera.

// The camera-to-output matrix the decode applied (row-major 3 x 3): LibRaw's
// out_cam -- its ProPhoto table times rgb_cam (convert_to_rgb), or under the
// headroom policy the matrix it captured.
std::array<double, 9> camera_to_output(const io::RawMetadata& metadata);

// Temperature/Tint that neutralise `rgb`, a value of the decoded frame. The
// pure form takes LibRaw's XYZ->camera matrix, the camera-to-output matrix and
// the multipliers the decode applied.
bool neutral_white_balance(const std::array<double, 9>& xyz_to_camera, const std::array<double, 9>& camera_to_output,
                           const std::array<double, 3>& applied_multipliers, const std::array<double, 3>& rgb,
                           double& temperature, double& tint, std::string& error);
bool neutral_white_balance(const io::RawMetadata& metadata, const std::array<double, 3>& rgb, double& temperature,
                           double& tint, std::string& error);

// The mean of a decoded frame over the (2r+1)^2 box around a point given in
// [0, 1] of its width and height (top-left origin), clipped to the frame.
// macOS's own linear sampler averages a box of radius 4 (ImageDecoder
// .sampleLinear, :420). False -- with `error` -- when the box holds a value
// the decode clipped (compatible16 stops at 1.0) or a non-positive one: no
// white balance neutralises a channel that recorded nothing or everything.
bool sample_decoded(const io::DecodedRaw& decoded, double x, double y, int radius, std::array<double, 3>& rgb,
                    std::string& error);

}  // namespace spk::desktop
