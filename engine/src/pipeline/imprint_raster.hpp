// Portable coverage raster for the physical film-edge/date exposure masks.
// Coordinates are doubles until coverage is quantized to the same 8-bit mask
// consumed by the Apple path. This is not a final-image text overlay.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace spk::imprint {
struct Point { double x, y; };
using Contour = std::vector<Point>;
using Contours = std::vector<Contour>;

// Bundled, immutable Liberation Sans outlines; no system/user font loading.
// The local baseline is y down, matching the physical film coordinate system.
double text_width(const char* face, double em, const std::string& text,
                  double tracking, double horizontal_scale);
Contours text_outlines(const char* face, double em, const std::string& text,
                       double tracking, double horizontal_scale,
                       bool scale_advances, double flatness);

// Nonzero-winding fill, exact horizontal coverage and eight subpixel rows.
// Each drawing operation uses source-over gray, as CoreGraphics does.
void fill(std::vector<uint8_t>& pixels, int width, int height,
          const Contours& contours, double gray);
void gaussian(std::vector<float>& coverage, int width, int height,
              const std::vector<float>& weights);
} // namespace spk::imprint
