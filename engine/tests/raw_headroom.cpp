// The mathematical contract is independent of LibRaw's demosaicing. Real RAW
// colour/orientation comparisons are run separately against rawpy camera RGB.
#include "io/raw_decoder.hpp"
#include "io/raw_headroom.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Matrix = std::array<float, 12>;
constexpr Matrix identity{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
unsigned checked = 0;

void require(bool condition, const char* message) {
    ++checked;
    if (!condition) throw std::runtime_error(message);
}

void near(float actual, double expected, const char* message) {
    require(std::isfinite(actual) && std::abs(actual - expected) < 2e-7, message);
}

void orientations() {
    // Explicit expected grids avoid using the implementation's coordinate
    // formula as the oracle. R identifies the pixel; G/B distinguish channels.
    constexpr std::array<std::array<int, 6>, 8> expected{{
        {{1, 2, 3, 4, 5, 6}}, {{3, 2, 1, 6, 5, 4}},
        {{4, 5, 6, 1, 2, 3}}, {{6, 5, 4, 3, 2, 1}},
        {{1, 4, 2, 5, 3, 6}}, {{3, 6, 2, 5, 1, 4}},
        {{4, 1, 5, 2, 6, 3}}, {{6, 3, 5, 2, 4, 1}}
    }};
    std::array<std::uint16_t, 24> camera{};
    for (unsigned pixel = 0; pixel < 6; ++pixel) {
        camera[pixel * 4] = static_cast<std::uint16_t>((pixel + 1) * 1000);
        camera[pixel * 4 + 1] = static_cast<std::uint16_t>((pixel + 1) * 1000 + 100);
        camera[pixel * 4 + 2] = static_cast<std::uint16_t>((pixel + 1) * 1000 + 200);
        camera[pixel * 4 + 3] = 65535;
    }
    for (int flip = 0; flip < 8; ++flip) {
        std::vector<float> out;
        std::uint32_t width = 0, height = 0;
        std::string error;
        require(spk::io::detail::convert_camera_rgb_headroom(camera.data(), 6, 3, 2,
            flip, identity, 1.0, out, width, height, error), "orientation conversion failed");
        require(width == (flip < 4 ? 3u : 2u) && height == (flip < 4 ? 2u : 3u),
                "orientation dimensions");
        for (unsigned pixel = 0; pixel < 6; ++pixel)
            for (unsigned channel = 0; channel < 3; ++channel)
                near(out[pixel * 3 + channel],
                     (expected[flip][pixel] * 1000.0 + channel * 100.0) / 65535.0,
                     "orientation or channel order");
    }
}

void colour_and_scale() {
    constexpr Matrix matrix{1.25f, -0.5f, 0.25f, 0,
                            -0.25f, 1.5f, -0.25f, 0,
                            0.125f, -0.375f, 1.25f, 0};
    constexpr std::array<std::uint16_t, 20> camera{
        0, 65535, 0, 1234,
        65535, 65535, 65535, 1,
        0, 0, 0, 65535,
        16384, 16384, 16384, 4000,
        3, 2, 1, 60000};
    std::vector<float> out;
    std::uint32_t width = 0, height = 0;
    std::string error;
    require(spk::io::detail::convert_camera_rgb_headroom(camera.data(), 5, 5, 1, 0,
            matrix, 2.0, out, width, height, error), "colour conversion failed");
    near(out[0], -1, "negative red clipped");
    near(out[1], 3, "headroom clipped");
    near(out[2], -0.75, "negative blue clipped");
    for (unsigned c = 0; c < 3; ++c) {
        near(out[3 + c], 2, "white neutrality or exposure scale");
        near(out[6 + c], 0, "black neutrality");
        near(out[9 + c], 32768.0 / 65535.0, "mid-gray neutrality or scale");
    }
    near(out[12], 6.0 / 65535.0, "fractional matrix result red");
    near(out[13], 4.0 / 65535.0, "fractional matrix result green");
    near(out[14], 1.75 / 65535.0, "fractional matrix result was truncated");

    double restore = 99;
    require(spk::io::detail::headroom_exposure_restore({1, 0.5f, 0.75f, 0.25f}, restore, error)
            && restore == 4, "WB restore ignored the second green minimum");
    require(spk::io::detail::headroom_exposure_restore({0.5f, 0.25f, 0.75f, 1}, restore, error)
            && restore == 4, "WB restore ignored the second green maximum");
    require(spk::io::detail::headroom_exposure_restore({1, 1, 1, 1}, restore, error)
            && restore == 1, "unity WB changes exposure");
    for (const auto invalid : std::array<std::array<float, 4>, 5>{{
             {{0, 1, 1, 1}}, {{-1, 1, 1, 1}}, {{2, 1, 1, 1}},
             {{0.5f, 0.5f, 0.5f, 0.5f}},
             {{1, 1, 1, std::numeric_limits<float>::quiet_NaN()}}}}) {
        restore = 99;
        require(!spk::io::detail::headroom_exposure_restore(invalid, restore, error)
                && !error.empty() && restore == 99, "invalid WB or output mutation");
    }
}

void rejection() {
    const std::uint16_t pixel[4]{1, 2, 3, 4};
    for (unsigned variant = 0; variant < 13; ++variant) {
        const std::uint16_t* camera = pixel;
        std::size_t camera_pixels = 1;
        std::uint32_t width = 1, height = 1;
        int flip = 0;
        double restore = 1;
        Matrix matrix = identity;
        switch (variant) {
        case 0: camera = nullptr; break;
        case 1: width = 0; break;
        case 2: height = 0; break;
        case 3: camera_pixels = 2; break;
        case 4: flip = -1; break;
        case 5: flip = 8; break;
        case 6: restore = 0.5; break;
        case 7: restore = std::numeric_limits<double>::infinity(); break;
        case 8: matrix[0] = std::numeric_limits<float>::quiet_NaN(); break;
        case 9: matrix[7] = 1; break;
        case 10: matrix[1] = std::numeric_limits<float>::max(); restore = 2; break;
        case 11: restore = std::numeric_limits<double>::max(); break;
        case 12: width = height = std::numeric_limits<std::uint32_t>::max(); break;
        }
        std::vector<float> out{9, 8, 7};
        std::uint32_t out_width = 17, out_height = 19;
        std::string error = "stale error";
        require(!spk::io::detail::convert_camera_rgb_headroom(camera, camera_pixels,
            width, height, flip, matrix, restore, out, out_width, out_height, error),
            "invalid transform accepted");
        require(error != "stale error" && !error.empty(), "invalid transform lacks error");
        require(out == std::vector<float>({9, 8, 7}) && out_width == 17 && out_height == 19,
                "failed transform changed prior result");
    }

    spk::io::DecodedRaw previous;
    previous.width = 17;
    previous.height = 19;
    previous.rgb = {9, 8, 7};
    previous.metadata.headroom_enabled = true;
    previous.metadata.white_balance_exposure_restore = 2;
    std::string error;
    require(!spk::io::decode_raw_headroom({}, previous, error) && !error.empty(),
            "empty headroom source accepted");
    require(previous.width == 17 && previous.height == 19 &&
            previous.rgb == std::vector<float>({9, 8, 7}) &&
            previous.metadata.headroom_enabled && previous.metadata.white_balance_exposure_restore == 2,
            "failed decoder changed previous result");
}

}  // namespace

int main() {
    try {
        orientations();
        colour_and_scale();
        rejection();
        std::cout << "RAW headroom mathematical contract: " << checked << " checks passed\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << exception.what() << '\n';
        return 1;
    }
}
