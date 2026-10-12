// Internal desktop view/export boundary. The public C result keeps its CPU
// ownership contract; this path retains the print on the device until the final
// display/file pixels are read once. Not part of the public engine ABI.
#pragma once
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
    uint32_t long_edge = 0;  // after crop; zero retains native output size
    std::string target_space = "sRGB";
    bool export_intent = false; // CAM16 for files; matrix-only for display
    bool rgba16 = false;
    uint32_t output_channels = 4; // 3: encoder RGB; 4: display/public-style RGBA
};
struct Result {
    uint32_t width = 0, height = 0, source_width = 0, source_height = 0;
    // Tightly packed RGB/RGBA, 8-bit or little-endian 16-bit as requested.
    // No row padding or trailing GPU word padding is exposed to the caller.
    std::vector<uint8_t> pixels;
    bool print_cached = false;
    double print_ms = 0, post_ms = 0, readback_ms = 0;
};
bool render(spk_session* session, const Request& request, Result& result, std::string& error);
}
