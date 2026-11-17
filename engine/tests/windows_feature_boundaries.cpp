// Exercise Windows feature refusals through the exported DLL boundary.
#include "spektralab/spk_engine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kWidth = 48;
constexpr uint32_t kHeight = 32;

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
                       result.width == kWidth && result.height == kHeight;
    const std::string error = spk_last_error(engine);
    spk_result_free(&result);
    require(valid, "default render failed after a refused request: " + error);
}

std::vector<uint16_t> render_pixels(spk_engine* engine, spk_session* session) {
    spk_result result{};
    const spk_status status = spk_render(session, "full", &result);
    require(status == SPK_OK && result.rgba16 &&
                result.width > 0 && result.height > 0,
            std::string("render failed (") + std::to_string(status) + "): " +
                spk_last_error(engine));
    const std::vector<uint16_t> pixels(
        result.rgba16, result.rgba16 + result.width * result.height * 4);
    spk_result_free(&result);
    return pixels;
}

size_t max_difference(const std::vector<uint16_t>& a,
                      const std::vector<uint16_t>& b) {
    require(a.size() == b.size(), "render shapes differ");
    size_t worst = 0;
    for (size_t i = 0; i < a.size(); ++i)
        worst = std::max(worst, size_t(std::abs(int(a[i]) - int(b[i]))));
    return worst;
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

        std::vector<float> pixels(kWidth * kHeight * 3);
        for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = 0.025f + float(i % 31) * 0.025f;
        const spk_image input{pixels.data(), kWidth, kHeight, 3};
        std::unique_ptr<spk_session, decltype(&spk_session_release)> session(
            spk_open(engine.get(), &input, nullptr, nullptr), spk_session_release);
        require(bool(session), std::string("default open failed: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        const std::string before = params(session.get());

        struct Feature { const char* key; const char* label; };
        const std::array<Feature, 0> features{};
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

        spk_result di{};
        char* di_json = nullptr;
        const spk_status di_status = spk_render_digital_intermediate(session.get(), &di, &di_json);
        const std::string di_error = spk_last_error(engine.get());
        const bool valid = di.texture && di.width == kWidth && di.height == kHeight && di_json &&
            std::string(di_json).find("\"encoding\":\"cineon\"") != std::string::npos;
        spk_result_free(&di);
        spk_string_free(di_json);
        require(di_status == SPK_OK && valid,
                "Digital Intermediate failed: " + di_error);
        require(params(session.get()) == before, "DI render mutated the session");
        render(engine.get(), session.get());

        spk_result neutral_result{};
        require(spk_render(session.get(), "full", &neutral_result) == SPK_OK &&
                neutral_result.rgba16 && neutral_result.width == kWidth && neutral_result.height == kHeight,
                std::string("neutral render for latitude failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> neutral(
            neutral_result.rgba16, neutral_result.rgba16 + neutral_result.width * neutral_result.height * 4);
        spk_result_free(&neutral_result);
        const char mask_delta[] =
            "{\"contrast_mask_active\":true,\"contrast_mask_highlights\":1.5,"
            "\"contrast_mask_shadows\":1.2,\"contrast_mask_core\":0.5,"
            "\"contrast_mask_scale\":0.02,\"contrast_mask_scheme\":\"gaussian\"}";
        require(spk_set_params(session.get(), mask_delta, nullptr) == SPK_OK,
                std::string("contrast mask was refused: ") + spk_last_error(engine.get()));
        const float* mask = nullptr;
        uint32_t mask_width = 0, mask_height = 0;
        require(spk_contrast_mask_field(session.get(), "full", &mask, &mask_width, &mask_height) == SPK_OK &&
                mask && mask_width > 0 && mask_height > 0,
                std::string("contrast mask analysis failed: ") + spk_last_error(engine.get()));
        spk_result mask_result{};
        require(spk_render(session.get(), "full", &mask_result) == SPK_OK &&
                mask_result.rgba16 && mask_result.width == kWidth && mask_result.height == kHeight,
                std::string("contrast mask render failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> masked(
            mask_result.rgba16, mask_result.rgba16 + mask_result.width * mask_result.height * 4);
        spk_result_free(&mask_result);
        require(masked != neutral, "contrast mask was accepted but changed no output");
        require(spk_set_params(session.get(), "{\"contrast_mask_active\":false}", nullptr) == SPK_OK,
                std::string("contrast mask could not be disabled: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        const char latitude_delta[] =
            "{\"scene_latitude_active\":true,\"scene_latitude_norm\":\"y\","
            "\"scene_latitude_highlight_knee\":0.4,\"scene_latitude_highlight_room\":1.5,"
            "\"scene_latitude_shadow_knee\":-0.7,\"scene_latitude_shadow_room\":0.8,"
            "\"scene_latitude_rolloff\":2,\"scene_latitude_max_lift\":1.5}";
        require(spk_set_params(session.get(), latitude_delta, nullptr) == SPK_OK,
                std::string("scene latitude mapping was refused: ") + spk_last_error(engine.get()));
        spk_result latitude_result{};
        require(spk_render(session.get(), "full", &latitude_result) == SPK_OK &&
                latitude_result.rgba16 && latitude_result.width == kWidth && latitude_result.height == kHeight,
                std::string("scene latitude render failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> mapped(
            latitude_result.rgba16, latitude_result.rgba16 + latitude_result.width * latitude_result.height * 4);
        spk_result_free(&latitude_result);
        require(mapped != neutral, "scene latitude mapping was accepted but changed no output");
        require(spk_set_params(session.get(),
                    "{\"scene_latitude_active\":false}", nullptr) == SPK_OK,
                std::string("scene latitude could not be disabled: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        const char curve_delta[] =
            "{\"scene_curve\":\"0,0.55,1,0,0.55,1,0,0.55,1,0,0.55,1,0,0.55,1\"}";
        require(spk_set_params(session.get(), curve_delta, nullptr) == SPK_OK,
                std::string("Decode scene curve was refused: ") + spk_last_error(engine.get()));
        spk_result curve_result{};
        require(spk_render(session.get(), "full", &curve_result) == SPK_OK &&
                curve_result.rgba16 && curve_result.width == kWidth && curve_result.height == kHeight,
                std::string("Decode scene curve render failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> curved(
            curve_result.rgba16, curve_result.rgba16 + curve_result.width * curve_result.height * 4);
        spk_result_free(&curve_result);
        require(curved != neutral, "Decode scene curve was accepted but changed no output");
        require(spk_set_params(session.get(), "{\"scene_curve\":\"\"}", nullptr) == SPK_OK,
                std::string("Decode scene curve could not be disabled: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        const std::string before_latitude_analysis = params(session.get());

        mask = nullptr;
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
        require(params(session.get()) == before_latitude_analysis, "latitude analysis mutated the session");
        render(engine.get(), session.get());

        const char overscan_delta[] =
            "{\"overscan_active\":true,\"overscan_format\":\"135\","
            "\"overscan_fog\":1.0,\"overscan_leaks\":1.0,"
            "\"overscan_edge_text\":\"SPEKTRALAB 400\"}";
        require(spk_set_params(session.get(), overscan_delta, nullptr) == SPK_OK,
                std::string("film edge was refused: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> overscanned = render_pixels(engine.get(), session.get());
        require(overscanned != neutral, "film edge was accepted but changed no output");
        char* geometry_json = nullptr;
        require(spk_overscan_geometry(session.get(), &geometry_json) == SPK_OK && geometry_json &&
                    std::string(geometry_json).find("\"gates\"") != std::string::npos &&
                    std::string(geometry_json).find("\"canvas_w\"") != std::string::npos,
                std::string("film-edge geometry failed: ") + spk_last_error(engine.get()));
        spk_string_free(geometry_json);

        // API-SPEC §24: the five cine gauges are in the format table, laid out with their neighbours, and render
        // a canvas wider than the frame. Each needs a picture of the gate's own shape.
        char* formats_json = nullptr;
        require(spk_overscan_formats(&formats_json) == SPK_OK && formats_json,
                "overscan format table failed");
        const std::string formats = formats_json;
        spk_string_free(formats_json);
        // The table's keys come back sorted, and a cine entry nests its own object: read one entry at a time.
        const auto entry_for = [&](const std::string& key) {
            const size_t array = formats.find('[');
            if (array == std::string::npos) return std::string();
            for (size_t p = formats.find('{', array); p != std::string::npos; p = formats.find('{', p + 1)) {
                int depth = 0;
                size_t q = p;
                for (; q < formats.size(); ++q) {
                    if (formats[q] == '{') ++depth;
                    else if (formats[q] == '}' && --depth == 0) break;
                }
                const std::string entry = formats.substr(p, q - p + 1);
                if (entry.find("\"name\":\"" + key + "\"") != std::string::npos) return entry;
                p = q;
            }
            return std::string();
        };
        for (const char* gauge : {"8_super", "16_super", "35_4perf", "65_5perf", "65_15perf"}) {
            const std::string name = gauge;
            const std::string entry = entry_for(name);
            require(!entry.empty(), name + " missing from the format table");
            const auto field = [&](const std::string& key) {
                const size_t p = entry.find("\"" + key + "\":");
                require(p != std::string::npos, name + " has no " + key);
                return std::atof(entry.c_str() + p + key.size() + 3);
            };
            const double across = field("across_mm"), along = field("along_mm");
            const uint32_t w = 48;
            const uint32_t h = std::max(2.0, std::round(w * std::min(across, along) / std::max(across, along)));
            std::vector<float> picture(size_t(w) * h * 3);
            for (size_t i = 0; i < picture.size(); ++i) picture[i] = 0.025f + float(i % 31) * 0.025f;
            const spk_image cine_input{picture.data(), w, h, 3};
            std::unique_ptr<spk_session, decltype(&spk_session_release)> cine_session(
                spk_open(engine.get(), &cine_input, before.c_str(), nullptr), spk_session_release);
            require(bool(cine_session), name + " open failed: " + spk_last_error(engine.get()));
            const std::string delta = "{\"overscan_active\":true,\"overscan_format\":\"" + name + "\"}";
            require(spk_set_params(cine_session.get(), delta.c_str(), nullptr) == SPK_OK,
                    name + " was refused: " + spk_last_error(engine.get()));
            render_pixels(engine.get(), cine_session.get());
            char* json = nullptr;
            require(spk_overscan_geometry(cine_session.get(), &json) == SPK_OK && json,
                    name + " geometry failed: " + spk_last_error(engine.get()));
            const std::string geometry(json);
            spk_string_free(json);
            require(geometry.find("\"neighbours_mm\"") != std::string::npos &&
                        geometry.find("\"format\":\"" + name + "\"") != std::string::npos,
                    name + " geometry is not a cine gauge's: " + geometry);
            const size_t cw = geometry.find("\"canvas_w\":");
            const size_t ch = geometry.find("\"canvas_h\":");
            require(cw != std::string::npos && ch != std::string::npos &&
                        size_t(std::atoi(geometry.c_str() + cw + 11)) * size_t(std::atoi(geometry.c_str() + ch + 11)) >
                            size_t(w) * h,
                    name + " canvas has no rebate around the frame: " + geometry);
        }
        require(spk_set_params(session.get(), "{\"overscan_format\":\"135\"}", nullptr) == SPK_OK,
                std::string("135 could not be restored: ") + spk_last_error(engine.get()));

        require(spk_set_params(session.get(),
                    "{\"date_imprint_active\":true,\"date_imprint_text\":\"2026 11 15\"}",
                    nullptr) == SPK_OK,
                std::string("date back was refused: ") + spk_last_error(engine.get()));
        require(render_pixels(engine.get(), session.get()) != overscanned,
                "date back was accepted but changed no film-edge output");
        require(spk_set_params(session.get(),
                    "{\"date_imprint_active\":false,\"overscan_active\":false}", nullptr) == SPK_OK,
                std::string("film edge effects could not be disabled: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> restored = render_pixels(engine.get(), session.get());
        std::unique_ptr<spk_session, decltype(&spk_session_release)> fresh(
            spk_open(engine.get(), &input, before.c_str(), nullptr), spk_session_release);
        require(bool(fresh), std::string("fresh neutral session failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> fresh_neutral = render_pixels(engine.get(), fresh.get());
        if (restored != fresh_neutral) {
            size_t differing = 0;
            for (size_t i = 0; i < std::min(restored.size(), fresh_neutral.size()); ++i)
                differing += restored[i] != fresh_neutral[i];
            throw std::runtime_error(
                "disabling film edge and date back did not restore the neutral render (" +
                std::to_string(restored.size()) + " vs " + std::to_string(fresh_neutral.size()) +
                " components, " + std::to_string(differing) + " differing)");
        }

        require(spk_set_params(session.get(),
                    "{\"leak_kind\":\"band\",\"leak_amount\":2.0,\"leak_front\":0.0,"
                    "\"overscan_camera_seed\":5,\"overscan_frame_seed\":3}",
                    nullptr) == SPK_OK,
                std::string("light leak was refused: ") + spk_last_error(engine.get()));
        require(render_pixels(engine.get(), session.get()) != restored,
                "light leak was accepted but changed no output");
        require(spk_set_params(session.get(), "{\"leak_kind\":\"off\"}", nullptr) == SPK_OK,
                std::string("light leak could not be disabled: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());

        require(spk_set_params(session.get(),
                    "{\"diffusion_filter_active\":true,\"diffusion_filter_family\":\"pro_mist\","
                    "\"diffusion_filter_strength\":1.0}", nullptr) == SPK_OK,
                std::string("source diffusion filter failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> diffused = render_pixels(engine.get(), session.get());
        require(diffused != fresh_neutral,
                "source diffusion filter was accepted but changed no output");
        require(spk_set_params(session.get(),
                    "{\"diffusion_filter_active\":false,\"lens_aberrations_active\":true,"
                    "\"lens_lateral_ca_r\":2.0,\"lens_lateral_ca_b\":-1.5,"
                    "\"lens_field_curvature_um\":48.0,\"lens_astigmatism_um\":32.0,"
                    "\"lens_coma_um\":24.0}", nullptr) == SPK_OK,
                std::string("lens aberrations failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> aberrated = render_pixels(engine.get(), session.get());
        require(aberrated != fresh_neutral,
                "lens aberrations were accepted but changed no output");
        require(spk_set_params(session.get(),
                    "{\"lens_aberrations_active\":false}", nullptr) == SPK_OK,
                std::string("lens aberrations could not be disabled: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());

        const std::string slide =
            R"({"film_stock":"fujifilm_provia_100f","scan_film":true,)"
            R"("product_defaults":true,"grain_active":false,"glare_active":false,)"
            R"("auto_exposure":false})";
        std::unique_ptr<spk_session, decltype(&spk_session_release)> slide_sdr(
            spk_open(engine.get(), &input, slide.c_str(), nullptr), spk_session_release);
        require(bool(slide_sdr), std::string("slide open failed: ") + spk_last_error(engine.get()));
        const std::vector<uint16_t> slide_today = render_pixels(engine.get(), slide_sdr.get());
        require(spk_set_params(slide_sdr.get(), "{\"scan_hdr_stretch\":true}", nullptr) == SPK_OK,
                std::string("scan HDR stretch was refused: ") + spk_last_error(engine.get()));
        require(render_pixels(engine.get(), slide_sdr.get()) != slide_today,
                "scan HDR stretch was accepted but changed no output");
        require(spk_set_params(slide_sdr.get(),
                    "{\"scan_hdr_stretch\":false,\"scan_hdr_headroom\":4.0,"
                    "\"scan_hdr_output_scale\":0.25}", nullptr) == SPK_OK,
                std::string("scan HDR headroom was refused: ") + spk_last_error(engine.get()));
        char* hdr_progress = nullptr;
        require(spk_progress(slide_sdr.get(), nullptr, &hdr_progress) == SPK_OK && hdr_progress &&
                    std::string(hdr_progress).find("\"scan_hdr\"") != std::string::npos,
                std::string("scan HDR progress is missing: ") + spk_last_error(engine.get()));
        spk_string_free(hdr_progress);
        render(engine.get(), slide_sdr.get());
        require(spk_set_params(slide_sdr.get(),
                    "{\"scan_hdr_headroom\":0.0,\"scan_hdr_output_scale\":1.0}", nullptr) == SPK_OK,
                std::string("scan HDR could not be disabled: ") + spk_last_error(engine.get()));
        require(render_pixels(engine.get(), slide_sdr.get()) == slide_today,
                "disabling scan HDR did not restore the session's SDR output");

        const std::string exposed =
            R"({"film_stock":"kodak_portra_400","print_stock":"kodak_portra_endura",)"
            R"("product_defaults":true,"grain_active":false,"glare_active":false,)"
            R"("auto_exposure":false,"exposure_compensation_ev":1.0})";
        const std::string layered =
            R"({"film_stock":"kodak_portra_400","print_stock":"kodak_portra_endura",)"
            R"("product_defaults":true,"grain_active":false,"glare_active":false,)"
            R"("auto_exposure":false,"scene_layers":"full"})";
        std::unique_ptr<spk_session, decltype(&spk_session_release)> exposed_session(
            spk_open(engine.get(), &input, exposed.c_str(), nullptr), spk_session_release);
        std::unique_ptr<spk_session, decltype(&spk_session_release)> layered_session(
            spk_open(engine.get(), &input, layered.c_str(), nullptr), spk_session_release);
        require(bool(exposed_session) && bool(layered_session),
                std::string("scene-layer comparison sessions failed: ") + spk_last_error(engine.get()));
        std::vector<uint16_t> layer_mask(4 * 4, 65535);
        spk_scene_layer layer{layer_mask.data(), 4, 4,
                              {float(std::log(2.0)), float(std::log(2.0)),
                               float(std::log(2.0))},
                              1.0f};
        char* layer_json = nullptr;
        require(spk_set_scene_layers(layered_session.get(), &layer, 1, nullptr,
                                     "full", &layer_json) == SPK_OK && layer_json &&
                    std::string(layer_json).find("\"stamp\":\"full\"") != std::string::npos,
                std::string("scene layers failed: ") + spk_last_error(engine.get()));
        spk_string_free(layer_json);
        const std::vector<uint16_t> exposed_pixels =
            render_pixels(engine.get(), exposed_session.get());
        const std::vector<uint16_t> layered_pixels =
            render_pixels(engine.get(), layered_session.get());
        require(max_difference(exposed_pixels, layered_pixels) <= 2,
                "a full scene-layer mask at +1 stop differs from Film Exposure +1");

        std::cout << "Windows feature boundaries passed (latitude, DI, contrast mask, film edge, "
                     "date back, light leak, diffusion, aberrations, scan HDR, scene layers)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
