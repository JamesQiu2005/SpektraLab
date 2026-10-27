// The Mac's shipped DI view, not another implementation of its colour model.
// Same 65^3 red-fastest table and half-float texels as CineonLUT.makeTexture.
// CPU trilinear sampling is presentation in the native host; the spectral
// negative and Cineon encoding still run in the original Vulkan pipeline.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <sstream>
#include "platform.hpp"
#include "pipeline/parallel_lines.hpp"

namespace spkhost {
class CineonView {
public:
    static constexpr const char* names[2] = {
        "SpektraLab DI view, Cineon to ProPhoto RGB.cube",
        "SpektraLab DI view, Cineon to Rec709.cube"
    };

    bool load(const std::filesystem::path& resources, std::string& error) {
        std::vector<uint8_t> bytes;
        if (!read_file(resources / "di" / names[0], bytes, error)) return false;
        std::istringstream input(std::string(bytes.begin(), bytes.end()));
        std::string line;
        std::vector<std::array<float, 3>> texels;
        uint32_t size = 0;
        while (std::getline(input, line)) {
            const auto first = line.find_first_not_of(" \t\r");
            if (first == std::string::npos || line[first] == '#' || line.compare(first, 5, "TITLE") == 0) continue;
            std::istringstream row(line.substr(first));
            if (line.compare(first, 11, "LUT_3D_SIZE") == 0) { std::string key; row >> key >> size; continue; }
            if (line.compare(first, 6, "DOMAIN") == 0) continue;
            std::array<float, 3> v{};
            if (!(row >> v[0] >> v[1] >> v[2])) { error = "invalid Cineon DI view triple"; return false; }
            for (float& c : v) {
                if (!std::isfinite(c) || c < 0 || c > 1) { error = "invalid Cineon DI view texel"; return false; }
                c = half_texel(c);
            }
            texels.push_back(v);
        }
        if (size != 65 || texels.size() != size_t(size) * size * size) {
            error = "Cineon DI view must be the complete shipped 65-cube"; return false;
        }
        // The export contract needs both tables, even though only ProPhoto is
        // sampled in-app. Fail explicitly when a portable bundle is incomplete.
        if (!read_file(resources / "di" / names[1], bytes, error)) return false;
        size_ = size;
        texels_ = std::move(texels);
        return true;
    }

    bool ready() const { return size_ == 65; }

    void apply(const uint16_t* input, uint32_t width, uint32_t height, uint32_t stride,
               std::vector<uint16_t>& output) const {
        output.resize(size_t(width) * height * 4);
        spk::portable_for_each_line(height, [&](uint32_t y) {
            for (uint32_t x = 0; x < width; ++x) {
                const uint16_t* source = input + (size_t(y) * stride + x) * 4;
                uint32_t lo[3], hi[3];
                float t[3];
                for (int c = 0; c < 3; ++c) {
                    const float v = float(source[c]) * (float(size_ - 1) / 65535.0f);
                    lo[c] = uint32_t(v); hi[c] = std::min(lo[c] + 1, size_ - 1); t[c] = v - float(lo[c]);
                }
                auto at = [&](uint32_t r, uint32_t g, uint32_t b, int c) {
                    return texels_[(size_t(b) * size_ + g) * size_ + r][c];
                };
                auto mix = [](float a, float b, float v) { return a + (b - a) * v; };
                uint16_t* dest = output.data() + (size_t(y) * width + x) * 4;
                for (int c = 0; c < 3; ++c) {
                    const float a = mix(at(lo[0], lo[1], lo[2], c), at(hi[0], lo[1], lo[2], c), t[0]);
                    const float b = mix(at(lo[0], hi[1], lo[2], c), at(hi[0], hi[1], lo[2], c), t[0]);
                    const float d = mix(at(lo[0], lo[1], hi[2], c), at(hi[0], lo[1], hi[2], c), t[0]);
                    const float e = mix(at(lo[0], hi[1], hi[2], c), at(hi[0], hi[1], hi[2], c), t[0]);
                    const float value = mix(mix(a, b, t[1]), mix(d, e, t[1]), t[2]);
                    dest[c] = uint16_t(std::lround(std::clamp(value, 0.0f, 1.0f) * 65535.0f));
                }
                dest[3] = 65535;
            }
        });
    }

private:
    static float half_texel(float v) {
        // Table values are finite [0,1]. Round to the IEEE binary16 grid,
        // including subnormals, then widen, as Swift Float16 -> Metal does.
        int exponent = 0;
        std::frexp(v, &exponent);
        const float step = std::ldexp(1.0f, std::max(exponent - 11, -24));
        return std::nearbyint(v / step) * step;
    }
    uint32_t size_ = 0;
    std::vector<std::array<float, 3>> texels_;
};
}  // namespace spkhost
