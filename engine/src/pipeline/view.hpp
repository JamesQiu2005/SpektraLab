// Internal desktop view/export boundary. The public C result keeps its CPU
// ownership contract; this path retains the print on the device until the final
// display/file pixels are read once. Not part of the public engine ABI.
#pragma once
#include <cstddef>
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include "json.hpp"
#include "spektrafilm/spk_engine.h"

namespace spk::view {
struct Request {
    std::string tier = "full";
    Json adjustments = Json::object();
    Json geometry = Json::object();
    Json pair; // optional frozen per-hole print/grade layers and normalized source gates
    uint32_t long_edge = 0;  // after crop; zero retains native output size
    std::string target_space = "sRGB";
    bool export_intent = false; // CAM16 for files; matrix-only for display
    bool rgba16 = false;
    uint32_t output_channels = 4; // 3: encoder RGB; 4: display/public-style RGBA
    // A proof runs the exact file-size chain above before quantising to its
    // chosen depth, then downsamples on the GPU and converts for the display.
    // Zero disables proofing. The proof itself always returns RGBA8.
    uint32_t proof_long_edge = 0;
    std::string proof_display = "sRGB";
    bool cineon = false; // dedicated untagged DI: no Post-Dev or RGB output transform
};
struct Result {
    uint32_t width = 0, height = 0, source_width = 0, source_height = 0;
    // Tightly packed RGB/RGBA, 8-bit or little-endian 16-bit as requested.
    // No row padding or trailing GPU word padding is exposed to the caller.
    std::vector<uint8_t> pixels;
    bool print_cached = false;
    double print_ms = 0, post_ms = 0, readback_ms = 0;
    uint32_t file_width = 0, file_height = 0;
    uint32_t moved_pixels = 0, clipped_pixels = 0, outside_pixels = 0;
    std::vector<uint8_t> preview_rgb; // dedicated DI's reduced sRGB second TIFF page
    uint32_t preview_width = 0, preview_height = 0;
};
bool render(spk_session* session, const Request& request, Result& result, std::string& error);
// Current decoded source, before the film. No embedded camera JPEG and no
// display-space reinterpretation. The source stays resident on the device.
bool render_source(spk_session* session, uint32_t long_edge, const std::string& display,
                   Result& result, std::string& error);
struct SourceSample {
    std::array<double, 3> mean{}, minimum{}, maximum{};
    uint32_t samples = 0;
};
bool sample_source(spk_session* session, double x, double y, SourceSample& result, std::string& error);
// Host-worker safe point: release unused device scratch and transfer staging,
// without invalidating any source, negative or finished print. Returns only
// device-pool bytes (staging has its own Vulkan diagnostic accounting).
size_t trim_idle_memory(spk_engine* engine);

// Desktop batch residency only: preserve exact source/negative/print bytes on
// temporary disk storage while a different image uses the GPU. The session,
// parameters and pipeline RNG remain alive. No public C ABI entry is added.
// A host must resume before calling any source-touching public C operation;
// render() does so itself. A failed resume leaves the disk copy intact.
bool suspended(spk_session* session);
bool suspend(spk_session* session, std::string& error);
bool resume(spk_session* session, std::string& error);
}
