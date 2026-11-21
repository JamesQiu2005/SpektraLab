// SPDX-License-Identifier: GPL-3.0-or-later
// Develop Camera's RAW path: Camera2 Bayer data and that frame's corrections -> linear ProPhoto RGB for Develop's
// engine. Pure C++ (no JNI), so it can be tested on a desktop against DNGs from the phone.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

struct RawInput {
    const uint8_t* base = nullptr;   // uint16 Bayer samples
    int w = 0, h = 0, rowStride = 0, cfa = 0;
    std::vector<float> black;        // 4, 2x2 position order (row * 2 + column)
    float white = 1023;
    std::vector<float> neutral;      // 3
    std::vector<float> fwd;          // 9, white-balanced camera RGB -> XYZ D50, row-major
    std::vector<float> shading;      // gw x gh x 4 (R, G even, G odd, B), or empty
    int gw = 0, gh = 0;
    std::vector<float> dist;         // k1 k2 k3 p1 p2, or empty
    std::vector<float> intr;         // fx fy cx cy s, or empty
    float cropAspect = 0;
    int maxPixels = 0;
    float targetMedian = 0;          // >0: scale so the median luminance is this (linear)
    // The app's film meter: the viewfinder showed (preview linear) x gain. With previewMedian (the preview's
    // median luminance at the shot) the RAW is scaled by gain x previewMedian / (its own median), so the picture
    // has the brightness the viewfinder showed. Takes precedence over targetMedian.
    float gain = 0;
    float previewMedian = 0;
};

// Returns the frame as linear ProPhoto RGB (ow x oh x 3), or an empty vector with [error] set.
std::vector<float> raw_to_prophoto(const RawInput& in, int& ow, int& oh, std::string& error);

// Linear ProPhoto (D50) -> sRGB (D65, Bradford), encoded, into RGBA8 rows (for the quick version).
void prophoto_to_srgb8(const float* px, int w, int h, uint8_t* rgba, int strideBytes);
