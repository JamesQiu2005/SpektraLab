// raw_decode_dump <raw> <compatible16|headroom> <out.spkf32>
//
// One RAW through spk::io's decoder, written as the linear frame the host
// hands the engine: a text header, then width*height*3 float32 (native
// endian, top row first). Built twice by raw_pin_compare.sh -- once against
// the previous LibRaw pin and once against the current one -- so the two
// frames can be compared value by value (raw_frame_compare.cpp).
//
// Header (one line each, then a blank line):
//   SPKF32 1
//   width <w>
//   height <h>
//   libraw <LibRaw::version()>
//   make <make> / model <model> / decoder <unpack function>
//   flip <LibRaw sizes.flip>
//   nonfinite <count of NaN/Inf samples>
//   sizes / levels / wb / camera_from_xyz: the calibration LibRaw used
// Exit 0 when the decode succeeded, 3 when it failed (the error on stderr).
#include "io/raw_decoder.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>

int main(int argc, char** argv) {
    if (argc != 4) {
        std::cerr << "usage: raw_decode_dump <raw> <compatible16|headroom> <out>\n";
        return 2;
    }
    const std::string mode = argv[2];
    spk::io::DecodedRaw decoded;
    std::string error;
    bool ok = false;
    if (mode == "compatible16") {
        ok = spk::io::decode_raw_compatible(std::filesystem::u8path(argv[1]), decoded, error);
    } else if (mode == "headroom") {
        ok = spk::io::decode_raw_headroom(std::filesystem::u8path(argv[1]), decoded, error);
    } else {
        std::cerr << "unknown mode " << mode << "\n";
        return 2;
    }
    if (!ok) {
        std::cerr << error << "\n";
        return 3;
    }
    if (decoded.rgb.size() != std::size_t(decoded.width) * decoded.height * 3) {
        std::cerr << "decoded frame size does not match its dimensions\n";
        return 4;
    }
    std::size_t nonfinite = 0;
    for (float v : decoded.rgb)
        if (!std::isfinite(v)) ++nonfinite;
    std::FILE* out = std::fopen(argv[3], "wb");
    if (!out) {
        std::cerr << "cannot write " << argv[3] << "\n";
        return 5;
    }
    const auto& m = decoded.metadata;
    std::fprintf(out, "SPKF32 1\nwidth %u\nheight %u\nlibraw %s\nmake %s\nmodel %s\ndecoder %s\nflip %d\nnonfinite %zu\n",
                 decoded.width, decoded.height, m.libraw_version.c_str(), m.make.c_str(), m.model.c_str(),
                 m.decoder_name.c_str(), m.raw_flip, nonfinite);
    // The calibration LibRaw used, so a changed frame can be traced to its cause.
    const auto& s = m.sizes_before_postprocess;
    std::fprintf(out, "sizes raw %ux%u visible %ux%u margins %u,%u\n", s.raw_width, s.raw_height, s.width, s.height,
                 s.left_margin, s.top_margin);
    std::fprintf(out, "levels black %u white %u per-channel-black %u,%u,%u,%u postprocess %u..%u\n", m.black, m.white_level,
                 m.black_level_per_channel[0], m.black_level_per_channel[1], m.black_level_per_channel[2],
                 m.black_level_per_channel[3], m.postprocess_black, m.postprocess_maximum);
    std::fprintf(out, "wb as-shot %.6g,%.6g,%.6g,%.6g applied %.6g,%.6g,%.6g,%.6g\n", m.camera_whitebalance[0],
                 m.camera_whitebalance[1], m.camera_whitebalance[2], m.camera_whitebalance[3], m.post_scale_pre_mul[0],
                 m.post_scale_pre_mul[1], m.post_scale_pre_mul[2], m.post_scale_pre_mul[3]);
    std::fprintf(out, "camera_from_xyz %.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g\n\n", m.camera_from_xyz[0],
                 m.camera_from_xyz[1], m.camera_from_xyz[2], m.camera_from_xyz[3], m.camera_from_xyz[4],
                 m.camera_from_xyz[5], m.camera_from_xyz[6], m.camera_from_xyz[7], m.camera_from_xyz[8]);
    const std::size_t written = std::fwrite(decoded.rgb.data(), sizeof(float), decoded.rgb.size(), out);
    if (std::fclose(out) != 0 || written != decoded.rgb.size()) {
        std::cerr << "short write to " << argv[3] << "\n";
        return 5;
    }
    std::printf("%s %ux%u %s %s %s flip=%d nonfinite=%zu\n", mode.c_str(), decoded.width, decoded.height,
                m.make.c_str(), m.model.c_str(), m.decoder_name.c_str(), m.raw_flip, nonfinite);
    return 0;
}
