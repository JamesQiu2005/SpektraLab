// spk_overscan_add_mask on Vulkan against overscan.metal's arithmetic in C++
// double: a coverage box added to a canvas as exposure, in place. Boxes
// inside, across every edge and wholly off the canvas; coverage at and below
// zero (skipped); a box past 16.7 M threads, where a device at the spec's
// minimum workgroup count (lavapipe, Intel) has its dispatch folded into rows
// (vulkan_gpu.cpp) -- where the limit is larger the dispatch stays one row and
// the case checks only that threads that far in write; and a guarded tail.
#include "gpu/gpu.hpp"
#include "gpu_vulkan_read.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

namespace {
using spk::gpu::Arg;
using spk::gpu::BufferRef;
using spk::gpu::Gpu;
constexpr float kGuard = -12345.25f;
constexpr size_t kGuardCount = 11;
size_t cases = 0, written = 0, past_fold = 0;
double max_error = 0.0;

struct Box { int x0, y0, mw, mh; };

bool run_case(Gpu* gpu, int cw, int ch, const Box& b, const float e[3], std::string& error) {
    const size_t n = size_t(b.mw) * size_t(b.mh);
    std::vector<float> mask(n);
    for (size_t i = 0; i < n; ++i) {
        // Multiplicative hash: about one in eight at or below zero.
        const uint32_t hsh = uint32_t(i) * 2654435761u + uint32_t(cases) * 40503u;
        mask[i] = float((hsh >> 8) & 0xFFFF) / 65535.0f * 1.15f - 0.15f;
        if (i % 97 == 3) mask[i] = 0.0f;
        if (i % 89 == 5) mask[i] = 1.0f;
    }
    std::vector<float> canvas(size_t(cw) * size_t(ch) * 3 + kGuardCount, kGuard);
    for (size_t i = 0; i < size_t(cw) * size_t(ch) * 3; ++i) canvas[i] = float(int(i % 211)) / 105.5f;
    std::vector<double> expected(canvas.begin(), canvas.end());
    std::vector<bool> touched(canvas.size(), false);
    for (size_t i = 0; i < n; ++i) {
        const int x = b.x0 + int(i % size_t(b.mw)), y = b.y0 + int(i / size_t(b.mw));
        if (x < 0 || y < 0 || x >= cw || y >= ch || !(mask[i] > 0.0f)) continue;
        const size_t o = 3 * (size_t(y) * size_t(cw) + size_t(x));
        for (int c = 0; c < 3; ++c) {
            expected[o + size_t(c)] = double(canvas[o + size_t(c)]) + double(mask[i]) * double(e[c]);
            touched[o + size_t(c)] = true;
        }
        if (i >= size_t(65535) * 256) ++past_fold;   // beyond where a minimum-limit device folds
    }
    BufferRef mb = gpu->upload(mask.data(), mask.size() * sizeof(float), error);
    BufferRef cb = gpu->upload(canvas.data(), canvas.size() * sizeof(float), error);
    if (!mb || !cb) return false;
    const float M[9] = {float(b.x0), float(b.y0), float(b.mw), float(b.mh), float(cw), float(ch), e[0], e[1], e[2]};
    const uint32_t count[1] = {uint32_t(n)};
    if (!gpu->dispatch("spk_overscan_add_mask",
                       {Arg::buf(mb), Arg::inline_bytes(M, 9), Arg::inline_bytes(count, 1), Arg::buf(cb)}, n, error) ||
        !gpu->flush(error))
        return false;
    std::vector<float> got;
    if (!read_test_buffer(gpu, cb, got, error)) return false;
    for (size_t i = 0; i < canvas.size(); ++i) {
        const double g = got[i];
        if (!touched[i]) {
            // Untouched values, the guards among them, must be the same bits.
            if (got[i] != canvas[i]) {
                char buf[200];
                std::snprintf(buf, sizeof buf, "case %zu: value %zu changed, outside the box or at coverage <= 0 (%.9g -> %.9g)", cases, i,
                              double(canvas[i]), g);
                error = buf;
                return false;
            }
            continue;
        }
        // Two float roundings (product, sum) against the double sum.
        const double err = std::fabs(g - expected[i]);
        const double tol = 2.4e-7 * (std::fabs(double(canvas[i])) + std::fabs(expected[i] - double(canvas[i])));
        max_error = std::max(max_error, err);
        if (!(err <= tol)) {
            char buf[200];
            std::snprintf(buf, sizeof buf, "case %zu: value %zu got %.9g expected %.17g (tolerance %.3g)", cases, i, g,
                          expected[i], tol);
            error = buf;
            return false;
        }
        ++written;
    }
    ++cases;
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_vulkan_overscan_add_mask <resources>\n"); return 2; }
    std::string error;
    std::unique_ptr<Gpu> gpu(Gpu::create_vulkan(std::string(argv[1]) + "/vulkan", error));
    if (!gpu) { std::fprintf(stderr, "Vulkan device: %s\n", error.c_str()); return 1; }
    std::printf("Vulkan device: %s\n", gpu->device_name().c_str());
    const float e1[3] = {0.37f, 1.25e-3f, 12.5f}, e2[3] = {2.0f, 0.5f, 0.0f};
    struct Case { int cw, ch; Box b; const float* e; };
    const Case kCases[] = {
        {37, 23, {5, 3, 17, 11}, e1},          // inside
        {37, 23, {-4, -2, 13, 9}, e1},         // across the top-left corner
        {37, 23, {30, 18, 15, 12}, e2},        // across the bottom-right corner
        {37, 23, {-6, 5, 50, 4}, e2},          // wider than the canvas
        {37, 23, {40, 30, 8, 8}, e1},          // wholly off it
        {1, 1, {0, 0, 1, 1}, e1},              // one pixel
        {256, 3, {0, 0, 257, 3}, e2},          // a partial last workgroup
        // 4100 x 4100 = 16.81 M threads, past 65535 x 256 (vulkan_gpu.cpp folds
        // there on a minimum-limit device); the rows that land are the last 64.
        {4100, 64, {0, -(4100 - 64), 4100, 4100}, e1},
    };
    for (const Case& c : kCases) {
        if (!run_case(gpu.get(), c.cw, c.ch, c.b, c.e, error)) {
            std::fprintf(stderr, "overscan_add_mask: %s\n", error.c_str());
            return 1;
        }
    }
    if (past_fold == 0) {
        std::fprintf(stderr, "overscan_add_mask: no thread past 65535 x 256 wrote\n");
        return 1;
    }
    std::printf("overscan_add_mask: %zu cases, %zu values written, %zu pixels from threads past 65535 x 256, max abs error %.3g "
                "against float64, every other value and guard unchanged\n", cases, written, past_fold, max_error);
    return 0;
}
