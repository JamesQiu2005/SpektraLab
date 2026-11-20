// Exercise Windows feature refusals through the exported DLL boundary.
#include "spektralab/spk_engine.h"

#include <array>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

std::string params(spk_session* session) {
    char* json = nullptr;
    require(spk_get_params(session, &json) == SPK_OK && json, "get_params failed");
    std::string result(json);
    spk_string_free(json);
    return result;
}

void render(spk_engine* engine, spk_session* session) {
    spk_result result{};
    const spk_status status = spk_render(session, "full", &result);
    const bool valid = status == SPK_OK && result.rgba16 && result.texture &&
                       result.width == 32 && result.height == 16;
    const std::string error = spk_last_error(engine);
    spk_result_free(&result);
    require(valid, "default render failed after a refused request: " + error);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "usage: spk_windows_feature_boundaries resources_dir\n"; return 2; }
    try {
        std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)> engine(
            spk_engine_create(argv[1], nullptr), spk_engine_destroy);
        require(bool(engine), std::string("engine creation failed: ") + spk_last_error(nullptr));
        const char* capabilities = spk_capabilities(engine.get());
        require(capabilities && std::string(capabilities).find("unsupported_features") != std::string::npos,
                "Windows capabilities must disclose unported effects");

        std::vector<float> pixels(32 * 16 * 3);
        for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = 0.025f + float(i % 31) * 0.025f;
        const spk_image input{pixels.data(), 32, 16, 3};
        std::unique_ptr<spk_session, decltype(&spk_session_release)> session(
            spk_open(engine.get(), &input, nullptr, nullptr), spk_session_release);
        require(bool(session), std::string("default open failed: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        const std::string before = params(session.get());

        // The film edge and the date back render on Vulkan since overscan.metal's kernels were ported and
        // their imprints are drawn without CoreText (edge_raster.cpp); the DI, scene latitude and the
        // contrast mask before them. Each is set, rendered, and set back.
        // A frame of the 135 gate's shape (36.25 x 24.3) for the film edge: it refuses any other.
        std::vector<float> gate(149 * 100 * 3);
        for (size_t i = 0; i < gate.size(); ++i) gate[i] = 0.025f + float(i % 29) * 0.025f;
        const spk_image gate_input{gate.data(), 149, 100, 3};
        std::unique_ptr<spk_session, decltype(&spk_session_release)> edge_session(
            spk_open(engine.get(), &gate_input, nullptr, nullptr), spk_session_release);
        require(bool(edge_session), std::string("135-shaped open failed: ") + spk_last_error(engine.get()));
        for (const char* delta : {"{\"overscan_active\":true,\"overscan_format\":\"135\",\"overscan_edge_text\":\"PORTRA 400\"}",
                                  "{\"date_imprint_active\":true,\"date_imprint_text\":\"'25 11 19\",\"date_imprint_placement\":\"frame\"}"}) {
#ifdef _WIN32
            // Windows has no edge fonts yet (edge_raster.cpp reads the Linux font folders): a clear refusal
            // that leaves the session as it was.
            const spk_status refused = spk_set_params(edge_session.get(), delta, nullptr);
            const std::string refusal = spk_last_error(engine.get());
            require(refused == SPK_ERR_USER && refusal.find("Windows Vulkan backend") != std::string::npos,
                    std::string("unclear refusal: ") + delta + ": " + refusal);
            continue;
#endif
            require(spk_set_params(edge_session.get(), delta, nullptr) == SPK_OK,
                    std::string("refused: ") + delta + ": " + spk_last_error(engine.get()));
            spk_result shown{};
            const spk_status st = spk_render(edge_session.get(), "full", &shown);
            const bool ok = st == SPK_OK && shown.rgba16 && shown.width > 0 && shown.height > 0;
            const std::string why = spk_last_error(engine.get());
            spk_result_free(&shown);
            require(ok, std::string("did not render: ") + delta + ": " + why);
            require(spk_set_params(edge_session.get(), "{\"overscan_active\":false,\"date_imprint_active\":false}", nullptr) == SPK_OK,
                    "could not set the film edge back");
        }
        render(engine.get(), session.get());
        require(params(session.get()) == before, "the film edge and date did not set back");

        spk_result di{};
        char* di_json = nullptr;
        const spk_status di_status = spk_render_digital_intermediate(session.get(), &di, &di_json);
        const std::string di_error = spk_last_error(engine.get());
        const bool rendered = di.rgba16 && di.width == 32 && di.height == 16;
        spk_result_free(&di);
        spk_string_free(di_json);
        require(di_status == SPK_OK && rendered, "DI did not render on Vulkan: " + di_error);
        require(params(session.get()) == before, "a DI render mutated the session");
        render(engine.get(), session.get());

        const float* mask = nullptr;
        uint32_t width = 0, height = 0;
        require(spk_contrast_mask_field(session.get(), "full", &mask, &width, &height) == SPK_OK &&
                !mask && width == 0 && height == 0, "disabled contrast mask must have an empty field");

        // Latitude analysis uses the existing pipeline; only applying its
        // mapping is unported. This also exercises probe_medium's readback.
        char* latitude_json = nullptr;
        const spk_status latitude_status = spk_scene_latitude(session.get(), nullptr, &latitude_json);
        const std::string latitude_error = spk_last_error(engine.get());
        const bool latitude_valid = latitude_json &&
            std::string(latitude_json).find("\"medium\"") != std::string::npos &&
            std::string(latitude_json).find("\"scene\"") != std::string::npos;
        spk_string_free(latitude_json);
        require(latitude_status == SPK_OK && latitude_valid, "latitude analysis failed: " + latitude_error);
        require(params(session.get()) == before, "latitude analysis mutated the session");
        render(engine.get(), session.get());
        std::cout << "Windows feature boundaries passed (film edge and date render, DI renders, mask off, latitude analysis)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
