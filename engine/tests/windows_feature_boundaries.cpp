// Exercise Windows feature refusals through the exported DLL boundary.
#include "spektrafilm/spk_engine.h"
#include "pipeline/parallel_lines.hpp"

#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
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

void check_parallel_lines() {
    for (uint32_t lines : {0u, 1u, 3u, 67u}) {
        std::vector<double> serial(lines), parallel(lines);
        std::vector<uint32_t> visits(lines);
        auto calculate = [](uint32_t line) {
            double sum = 0;
            for (uint32_t i = 0; i < 257; ++i) sum += std::sin(double(line + i)) / double(i + 1);
            return sum;
        };
        spk::portable_for_each_line(lines, [&](uint32_t line) { serial[line] = calculate(line); }, 1);
        spk::portable_for_each_line(lines, [&](uint32_t line) {
            parallel[line] = calculate(line);
            ++visits[line];
        }, 8);
        require(std::equal(visits.begin(), visits.end(), std::vector<uint32_t>(lines, 1).begin()),
                "parallel lines skipped or repeated a line");
        require(!lines || std::memcmp(serial.data(), parallel.data(), lines * sizeof(double)) == 0,
                "parallel lines changed a line's accumulation order");
    }
}

std::vector<uint16_t> pixels_for(spk_engine* engine, spk_session* session) {
    spk_result result{};
    const auto status = spk_render(session, "full", &result);
    require(status == SPK_OK && result.rgba16,
            std::string("mask render failed: ") + spk_last_error(engine));
    std::vector<uint16_t> out(size_t(result.width) * result.height * 4);
    for (uint32_t y = 0; y < result.height; ++y)
        std::copy_n(result.rgba16 + size_t(y) * result.row_stride_px * 4, size_t(result.width) * 4,
                    out.data() + size_t(y) * result.width * 4);
    spk_result_free(&result);
    return out;
}

void check_mask(spk_engine* engine, const spk_image& input) {
    std::unique_ptr<spk_session, decltype(&spk_session_release)> s(
        spk_open(engine, &input, "{\"grain_active\":false,\"glare_active\":false}", nullptr), spk_session_release);
    require(bool(s), "could not open deterministic mask session");
    const auto bare = pixels_for(engine, s.get());
    require(spk_set_params(s.get(), "{\"contrast_mask_active\":true,\"contrast_mask_highlights\":0,\"contrast_mask_shadows\":0}", nullptr) == SPK_OK,
            std::string("mask switch refused: ") + spk_last_error(engine));
    require(pixels_for(engine, s.get()) == bare, "zero-strength mask changed the unmasked print");
    require(spk_set_params(s.get(), "{\"contrast_mask_highlights\":2,\"contrast_mask_shadows\":2,\"contrast_mask_core\":0,\"contrast_mask_scale\":0.03}", nullptr) == SPK_OK,
            "could not configure mask strengths");
    const auto masked = pixels_for(engine, s.get());
    require(masked != bare, "nonzero mask did not affect the actual print");
    const auto before = params(s.get());
    const float* field = nullptr;
    uint32_t width = 0, height = 0;
    require(spk_contrast_mask_field(s.get(), "full", &field, &width, &height) == SPK_OK &&
            field && width == input.width && height == input.height,
            std::string("mask field failed: ") + spk_last_error(engine));
    bool changed = false;
    for (size_t i = 0; i < size_t(width) * height; ++i) {
        require(std::isfinite(field[i]) && std::abs(field[i]) < 6, "mask field exceeded its finite gain bound");
        changed |= std::abs(field[i]) > 1e-6f;
    }
    require(changed, "mask field contains no active gain");
    require(params(s.get()) == before, "asking for the field mutated the session");
    require(pixels_for(engine, s.get()) == masked, "asking for the field altered the next cached print");
    require(spk_set_params(s.get(), "{\"contrast_mask_active\":false}", nullptr) == SPK_OK,
            "could not turn off the mask");
    require(pixels_for(engine, s.get()) == bare, "mask toggle did not recover the unmasked print");
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "usage: spk_windows_feature_boundaries resources_dir\n"; return 2; }
    try {
        check_parallel_lines();
        std::string resources = argv[1];
#ifdef _WIN32
        // Tauri resource_dir returns a verbatim native path. Exercise that
        // exact boundary, including the engine's appended '/' filenames.
        const auto native = std::filesystem::absolute(std::filesystem::path(
            std::u8string(resources.begin(), resources.end()))).make_preferred().u8string();
        resources.assign(reinterpret_cast<const char*>(native.data()), native.size());
        resources = resources.rfind("\\\\", 0) == 0 ? "\\\\?\\UNC\\" + resources.substr(2) : "\\\\?\\" + resources;
#endif
        std::unique_ptr<spk_engine, decltype(&spk_engine_destroy)> engine(
            spk_engine_create(resources.c_str(), nullptr), spk_engine_destroy);
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

        check_mask(engine.get(), input);

        spk_result di{};
        char* di_json = nullptr;
        const spk_status di_status = spk_render_digital_intermediate(session.get(), &di, &di_json);
        const std::string di_error = spk_last_error(engine.get());
        const bool valid_di = di.rgba16 && di.width == 32 && di.height == 16 && di_json &&
            std::string(di_json).find("\"encoding\":\"cineon\"") != std::string::npos;
        spk_result_free(&di);
        spk_string_free(di_json);
        require(di_status == SPK_OK && valid_di, "Cineon DI export failed: " + di_error);
        require(params(session.get()) == before, "DI export mutated the canvas session");
        render(engine.get(), session.get());
        require(spk_set_params(session.get(), "{\"digital_intermediate\":true}", nullptr) == SPK_OK,
                "Cineon DI mode refused");
        render(engine.get(), session.get());
        require(spk_set_params(session.get(), "{\"digital_intermediate\":false}", nullptr) == SPK_OK,
                "could not leave Cineon DI mode");
        require(params(session.get()) == before, "DI round trip changed unrelated parameters");
        std::unique_ptr<spk_session, decltype(&spk_session_release)> positive(
            spk_open(engine.get(), &input, "{\"film_stock\":\"fujifilm_provia_100f\"}", nullptr), spk_session_release);
        require(bool(positive), "could not open a slide film session");
        spk_result slide_di{};
        const spk_status slide_status = spk_render_digital_intermediate(positive.get(), &slide_di, nullptr);
        require(slide_status == SPK_ERR_USER && !slide_di.rgba16 &&
                std::string(spk_last_error(engine.get())).find("slide film") != std::string::npos,
                "a slide film must still reject negative reversal");
        spk_result_free(&slide_di);

        const float* mask = nullptr;
        uint32_t width = 0, height = 0;
        require(spk_contrast_mask_field(session.get(), "full", &mask, &width, &height) == SPK_OK &&
                !mask && width == 0 && height == 0, "disabled contrast mask must have an empty field");

        // Latitude analysis uses the existing pipeline. This also exercises
        // probe_medium's readback; applying the mapping is checked below.
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
        // Positive boundary: the real overscan/date pipeline must render,
        // expose its layout, and survive returning to the bare photograph.
        // These assertions first fail against the old explicit refusal.
        for (const char* delta : {"{\"overscan_active\":true,\"overscan_format\":\"135\",\"geometry_crop_w\":0.75}",
                                  "{\"overscan_active\":true,\"overscan_format\":\"120_6x6\",\"geometry_crop_w\":0.5}",
                                  "{\"overscan_active\":false,\"date_imprint_active\":true,\"date_imprint_text\":\"26 10 26\",\"geometry_crop_w\":1}"}) {
            const spk_status set_status = spk_set_params(session.get(), delta, nullptr);
            require(set_status == SPK_OK,
                    std::string("ported imprint was refused: ") + spk_last_error(engine.get()));
            spk_result result{};
            const spk_status render_status = spk_render(session.get(), "full", &result);
            require(render_status == SPK_OK && result.rgba16,
                    std::string("ported imprint failed: ") + spk_last_error(engine.get()));
            const bool edge = std::string(delta).find("\"overscan_active\":true") != std::string::npos;
            require(edge ? (result.width > 32 || result.height > 16) : (result.width == 32 && result.height == 16),
                    "imprint canvas dimensions disagree with the active effect");
            char* geometry = nullptr;
            require(spk_overscan_geometry(session.get(), &geometry) == SPK_OK && geometry,
                    "overscan geometry unavailable");
            require(std::string(geometry).find(edge ? "\"valid\":true" : "\"valid\":false") != std::string::npos,
                    "overscan layout validity disagrees with canvas");
            spk_string_free(geometry);
            spk_result_free(&result);
        }
        require(spk_set_params(session.get(), "{\"overscan_active\":false,\"date_imprint_active\":false}", nullptr) == SPK_OK,
                "could not disable imprints");
        render(engine.get(), session.get());
        const spk_status latitude_set = spk_set_params(session.get(),
            "{\"scene_latitude_active\":true,\"scene_latitude_highlight_knee\":0,\"scene_latitude_highlight_room\":1,\"scene_latitude_shadow_knee\":-1,\"scene_latitude_shadow_room\":1}", nullptr);
        require(latitude_set == SPK_OK, std::string("latitude mapping refused: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        require(spk_set_params(session.get(), "{\"scene_latitude_active\":false}", nullptr) == SPK_OK,
                "could not disable latitude mapping");
        render(engine.get(), session.get());
        std::cout << "Windows boundaries passed (mask field/print/cache, Cineon DI/slide refusal, latitude, overscan/date)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
