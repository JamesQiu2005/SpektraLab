// RFC-052's scene layers on Vulkan: the essential checks of scene_layers_checks.cpp (which hands
// real MTLBuffers and runs on the Mac only) through the public API with host-memory planes.
//   1. a full-mask layer of e stops is Film Exposure + e (the scalar path, the same gain);
//   2. an all-zero mask, and coverage 0, leave the render byte for byte as without layers;
//   3. a mask on the left half brightens the left half only.
#include "spektralab/spk_engine.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void require(bool ok, const std::string& what) { if (!ok) throw std::runtime_error(what); }

std::vector<uint16_t> render(spk_engine* e, spk_session* s, uint32_t& w, uint32_t& h) {
    spk_result r{};
    require(spk_render(s, "full", &r) == SPK_OK && r.rgba16, std::string("render: ") + spk_last_error(e));
    w = r.width; h = r.height;
    std::vector<uint16_t> px(r.rgba16, r.rgba16 + size_t(w) * h * 4);
    spk_result_free(&r);
    return px;
}
double mean(const std::vector<uint16_t>& px, uint32_t w, uint32_t h, uint32_t x0, uint32_t x1) {
    double s = 0; size_t n = 0;
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = x0; x < x1; ++x) { for (int c = 0; c < 3; ++c) s += px[(size_t(y) * w + x) * 4 + c]; n += 3; }
    return s / double(n);
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: spk_scene_layers_vulkan resources\n"); return 2; }
    try {
        std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)> e(spk_engine_create(argv[1], nullptr), spk_engine_destroy);
        require(bool(e), std::string("engine: ") + spk_last_error(nullptr));
        const uint32_t W = 96, H = 64;
        std::vector<float> img(size_t(W) * H * 3);
        for (uint32_t y = 0; y < H; ++y)
            for (uint32_t x = 0; x < W; ++x)
                for (int c = 0; c < 3; ++c) img[(size_t(y) * W + x) * 3 + c] = 0.05f + 0.25f * float(x) / W + 0.1f * float(c);
        const spk_image in{img.data(), W, H, 3};
        const char* base = "{\"auto_exposure\":false,\"grain_active\":false,\"glare_active\":false}";
        std::unique_ptr<spk_session, decltype(&spk_session_release)> s(spk_open(e.get(), &in, base, nullptr), spk_session_release);
        require(bool(s), std::string("open: ") + spk_last_error(e.get()));
        uint32_t w, h;
        const auto plain = render(e.get(), s.get(), w, h);

        auto set = [&](const std::vector<uint16_t>& plane, uint32_t pw, uint32_t ph, double stops, double coverage) {
            spk_scene_layer l{};
            l.plane = const_cast<uint16_t*>(plane.data());
            l.width = pw; l.height = ph; l.coverage = float(coverage);
            for (int c = 0; c < 3; ++c) l.log_gain[c] = float(stops * std::log(2.0));
            require(spk_set_scene_layers(s.get(), &l, 1, nullptr, "t", nullptr) == SPK_OK, std::string("set: ") + spk_last_error(e.get()));
            require(spk_set_params(s.get(), "{\"scene_layers\":\"t\"}", nullptr) == SPK_OK, std::string("stamp: ") + spk_last_error(e.get()));
        };
        auto clear = [&] {
            require(spk_set_params(s.get(), "{\"scene_layers\":\"\",\"exposure_compensation_ev\":0}", nullptr) == SPK_OK, "unstamp");
            require(spk_set_scene_layers(s.get(), nullptr, 0, nullptr, nullptr, nullptr) == SPK_OK, "clear");
        };

        // 1. full mask, +1 stop  ==  Film Exposure +1
        const std::vector<uint16_t> full(4 * 4, 65535);
        set(full, 4, 4, 1.0, 1.0);
        const auto layered = render(e.get(), s.get(), w, h);
        clear();
        require(spk_set_params(s.get(), "{\"exposure_compensation_ev\":1}", nullptr) == SPK_OK, "ev");
        const auto exposed = render(e.get(), s.get(), w, h);
        int worst = 0;
        for (size_t i = 0; i < layered.size(); ++i) worst = std::max(worst, std::abs(int(layered[i]) - int(exposed[i])));
        require(worst <= 2, "a full-mask +1 stop layer is not Film Exposure +1: " + std::to_string(worst) + " codes");
        require(spk_set_params(s.get(), "{\"exposure_compensation_ev\":0}", nullptr) == SPK_OK, "ev0");

        // 2. zero mask and coverage 0: byte for byte the plain render
        const std::vector<uint16_t> none(4 * 4, 0);
        set(none, 4, 4, 2.0, 1.0);
        require(render(e.get(), s.get(), w, h) == plain, "an all-zero mask moved the render");
        set(full, 4, 4, 2.0, 0.0);
        require(render(e.get(), s.get(), w, h) == plain, "coverage 0 moved the render");

        // 3. the left half only
        std::vector<uint16_t> left(64 * 64, 0);
        for (uint32_t y = 0; y < 64; ++y) for (uint32_t x = 0; x < 32; ++x) left[y * 64 + x] = 65535;
        set(left, 64, 64, 1.0, 1.0);
        const auto half = render(e.get(), s.get(), w, h);
        const double dl = mean(half, w, h, 0, w / 2 - 4) - mean(plain, w, h, 0, w / 2 - 4);
        const double dr = mean(half, w, h, w / 2 + 4, w) - mean(plain, w, h, w / 2 + 4, w);
        require(dl > 1000 && std::fabs(dr) < 50, "the left-half mask: left " + std::to_string(dl) + ", right " + std::to_string(dr));
        clear();
        std::printf("scene layers on Vulkan: full mask = Film Exposure (max %d codes), zero = identity, left half +%.0f / right %+.0f\n",
                    worst, dl, dr);
        return 0;
    } catch (const std::exception& x) {
        std::fprintf(stderr, "%s\n", x.what());
        return 1;
    }
}
