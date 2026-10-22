#pragma once
#include "image_io.hpp"
namespace spkhost {
// Additional flat formats return the same linear ProPhoto frame as RAW/TIFF.
bool probe_extra(const std::filesystem::path&, FileKind, Probe&, std::string&);
bool decode_extra(const std::filesystem::path&, FileKind, FloatImage&, Probe&, std::string&);
// ICC LUT profiles use Little CMS; existing matrix/TRC decoding remains exact.
bool icc_to_linear_prophoto(const std::vector<uint8_t>& profile, std::vector<float>& rgb,
                           uint32_t codes, std::string& error);
}
