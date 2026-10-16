// Exercise Windows feature refusals through the exported DLL boundary.
#include "spektrafilm/spk_engine.h"

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

        struct Feature { const char* key; const char* label; };
        const std::array<Feature, 4> features{{
            {"digital_intermediate", "digital intermediate"},
            {"scene_latitude_active", "scene latitude mapping"},
            {"contrast_mask_active", "contrast mask"},
            {"overscan_active", "overscan"},
        }};
        for (const Feature& feature : features) {
            // Include a supported change to catch partial application before
            // the unsupported field is rejected.
            const std::string delta = std::string("{\"") + feature.key +
                                      "\":true,\"print_exposure\":1.25}";
            const spk_status status = spk_set_params(session.get(), delta.c_str(), nullptr);
            const std::string error = spk_last_error(engine.get());
            require(status == SPK_ERR_USER && error.find(feature.label) != std::string::npos &&
                    error.find("Windows Vulkan backend") != std::string::npos,
                    std::string("unclear feature refusal: ") + feature.key + ": " + error);
            require(params(session.get()) == before, std::string("refused delta mutated params: ") + feature.key);
            render(engine.get(), session.get());

            spk_session* rejected = spk_open(engine.get(), &input, delta.c_str(), nullptr);
            const std::string open_error = spk_last_error(engine.get());
            if (rejected) spk_session_release(rejected);
            require(!rejected && open_error.find(feature.label) != std::string::npos,
                    std::string("open accepted an unported effect: ") + feature.key);
        }

        // The latitude's second pair runs the node without `active`
        // (Pipeline::scene_latitude_wanted), so it is a request on its own --
        // whether it arrives in one delta or is completed by a later one.
        {
            const char* second = "{\"scene_latitude_split\":0.5,\"scene_latitude_b_active\":true,"
                                 "\"scene_latitude_b_highlight_room\":1.0}";
            const spk_status status = spk_set_params(session.get(), second, nullptr);
            const std::string error = spk_last_error(engine.get());
            require(status == SPK_ERR_USER && error.find("scene latitude mapping") != std::string::npos,
                    "second latitude pair bypassed the refusal: " + error);
            require(params(session.get()) == before, "refused second-pair delta mutated params");
            require(spk_set_params(session.get(), "{\"scene_latitude_b_active\":true}", nullptr) == SPK_OK,
                    std::string("b_active without a split must stay allowed: ") + spk_last_error(engine.get()));
            const spk_status completed = spk_set_params(session.get(), "{\"scene_latitude_split\":0.5}", nullptr);
            require(completed == SPK_ERR_USER, "a split completing the second pair bypassed the refusal");
            require(spk_set_params(session.get(), "{\"scene_latitude_b_active\":false}", nullptr) == SPK_OK,
                    "could not restore b_active");
            render(engine.get(), session.get());
            spk_session* rejected = spk_open(engine.get(), &input, second, nullptr);
            if (rejected) spk_session_release(rejected);
            require(!rejected, "open accepted the second latitude pair");
        }

        // The date back is ported (overscan.cpp's date-only path on the
        // portable raster, spk_overscan_add_mask): accepted by set_params and
        // open, rendered, and switched off again. Asking for overscan beside
        // it is still refused, by overscan's name, and changes nothing.
        {
            const std::string undated = params(session.get());
            const char* on = "{\"date_imprint_active\":true,\"date_imprint_text\":\"'26 10 16\"}";
            require(spk_set_params(session.get(), on, nullptr) == SPK_OK,
                    std::string("date imprint refused: ") + spk_last_error(engine.get()));
            render(engine.get(), session.get());
            const std::string dated = params(session.get());
            const spk_status status = spk_set_params(session.get(), "{\"overscan_active\":true}", nullptr);
            const std::string error = spk_last_error(engine.get());
            require(status == SPK_ERR_USER && error.find("overscan") != std::string::npos,
                    "overscan beside the date bypassed the refusal: " + error);
            require(params(session.get()) == dated, "refused overscan delta mutated a dated session");
            require(spk_set_params(session.get(), "{\"date_imprint_active\":false,\"date_imprint_text\":\"\"}", nullptr) == SPK_OK,
                    "could not switch the date off");
            require(params(session.get()) == undated, "switching the date off did not restore the params");
            render(engine.get(), session.get());
            spk_session* dated_open = spk_open(engine.get(), &input, on, nullptr);
            const std::string open_error = spk_last_error(engine.get());
            require(dated_open != nullptr, "open refused the date imprint: " + open_error);
            spk_session_release(dated_open);
        }
        const std::string restored = params(session.get());

        spk_result di{};
        char* di_json = nullptr;
        const spk_status di_status = spk_render_digital_intermediate(session.get(), &di, &di_json);
        const std::string di_error = spk_last_error(engine.get());
        const bool empty = !di.texture && !di.rgba16 && !di_json;
        spk_result_free(&di);
        spk_string_free(di_json);
        require(di_status == SPK_ERR_USER && empty &&
                di_error.find("digital intermediate") != std::string::npos,
                "DI API did not return a clear refusal and empty result");
        require(params(session.get()) == restored, "DI refusal mutated the session");
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
        require(params(session.get()) == restored, "latitude analysis mutated the session");
        render(engine.get(), session.get());
        std::cout << "Windows feature boundaries passed (4 refused flags, date imprint accepted, latitude second pair, "
                     "DI refusal, mask off, latitude analysis)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
