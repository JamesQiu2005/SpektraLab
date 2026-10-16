// Exercise Windows feature refusals, and the ported effects' acceptance,
// through the exported DLL boundary.
#include "spektrafilm/spk_engine.h"

#include <array>
#include <cstdint>
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

// A result's RGBA16, packed (the row stride dropped); empty unless it is w x h.
std::vector<uint16_t> packed(const spk_result& result, uint32_t w, uint32_t h) {
    std::vector<uint16_t> out;
    if (!result.rgba16 || result.width != w || result.height != h) return out;
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t i = 0; i < w * 4; ++i) out.push_back(result.rgba16[size_t(y) * result.row_stride_px * 4 + i]);
    return out;
}

std::vector<uint16_t> rendered(spk_engine* engine, spk_session* session, uint32_t w, uint32_t h,
                               const std::string& what) {
    spk_result result{};
    const spk_status status = spk_render(session, "full", &result);
    std::vector<uint16_t> out = status == SPK_OK ? packed(result, w, h) : std::vector<uint16_t>{};
    const std::string error = spk_last_error(engine);
    spk_result_free(&result);
    require(!out.empty(), what + " render failed: " + error);
    return out;
}

// Whether rows [first, last) of two packed w-wide renders differ anywhere.
bool rows_differ(const std::vector<uint16_t>& a, const std::vector<uint16_t>& b, uint32_t w,
                 uint32_t first, uint32_t last) {
    for (size_t i = size_t(first) * w * 4; i < size_t(last) * w * 4; ++i)
        if (a[i] != b[i]) return true;
    return false;
}

void set(spk_engine* engine, spk_session* session, const char* delta) {
    require(spk_set_params(session, delta, nullptr) == SPK_OK,
            std::string("delta refused: ") + delta + ": " + spk_last_error(engine));
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
        {
            const std::string caps(capabilities);
            const size_t at = caps.find("unsupported_features");
            const std::string listed = caps.substr(at, caps.find(']', at) - at);
            require(listed.find("digital_intermediate") == std::string::npos &&
                    listed.find("scene_latitude_mapping") == std::string::npos,
                    "capabilities still list a ported effect: " + listed);
        }

        std::vector<float> pixels(32 * 16 * 3);
        for (size_t i = 0; i < pixels.size(); ++i) pixels[i] = 0.025f + float(i % 31) * 0.025f;
        const spk_image input{pixels.data(), 32, 16, 3};
        std::unique_ptr<spk_session, decltype(&spk_session_release)> session(
            spk_open(engine.get(), &input, nullptr, nullptr), spk_session_release);
        require(bool(session), std::string("default open failed: ") + spk_last_error(engine.get()));
        render(engine.get(), session.get());
        const std::string before = params(session.get());

        struct Feature { const char* key; const char* label; };
        const std::array<Feature, 3> features{{
            {"contrast_mask_active", "contrast mask"},
            {"overscan_active", "overscan"},
            {"date_imprint_active", "date imprint"},
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

        // Ported: the Cineon DI and the scene latitude mapping are accepted by
        // set_params and at open -- the latitude's second pair on its own too,
        // since Pipeline::scene_latitude_wanted runs the node for it without
        // `active` -- and the session renders with each on.
        {
            const char* accepted[] = {
                "{\"digital_intermediate\":true}",
                "{\"scene_latitude_active\":true,\"scene_latitude_highlight_room\":1.0}",
                "{\"scene_latitude_split\":0.5,\"scene_latitude_b_active\":true,"
                "\"scene_latitude_b_highlight_room\":1.0}",
            };
            for (const char* delta : accepted) {
                set(engine.get(), session.get(), delta);
                render(engine.get(), session.get());
                spk_session* opened = spk_open(engine.get(), &input, delta, nullptr);
                const std::string open_error = spk_last_error(engine.get());
                if (opened) { render(engine.get(), opened); spk_session_release(opened); }
                require(opened, std::string("open refused a ported effect: ") + delta + ": " + open_error);
                set(engine.get(), session.get(),
                    "{\"digital_intermediate\":false,\"scene_latitude_active\":false,"
                    "\"scene_latitude_highlight_room\":0.0,\"scene_latitude_split\":0.0,"
                    "\"scene_latitude_b_active\":false,\"scene_latitude_b_highlight_room\":0.0}");
                require(params(session.get()) == before, std::string("could not restore after ") + delta);
            }
        }
        const std::string restored = params(session.get());

        // The DI export: a valid Cineon frame and its description on the
        // session's negative film, and the session left as it was.
        {
            spk_result di{};
            char* di_json = nullptr;
            const spk_status di_status = spk_render_digital_intermediate(session.get(), &di, &di_json);
            const std::string di_error = spk_last_error(engine.get());
            const bool valid = di_status == SPK_OK && !packed(di, 32, 16).empty() && di_json &&
                               std::string(di_json).find("cineon") != std::string::npos;
            spk_result_free(&di);
            spk_string_free(di_json);
            require(valid, "DI export failed on a negative film: " + di_error);
            require(params(session.get()) == restored, "DI export mutated the session");
            render(engine.get(), session.get());
        }
        // ... and still a clear refusal, with an empty result, on a slide.
        {
            std::unique_ptr<spk_session, decltype(&spk_session_release)> slide(
                spk_open(engine.get(), &input, "{\"film_stock\":\"fujifilm_provia_100f\"}", nullptr),
                spk_session_release);
            require(bool(slide), std::string("slide open failed: ") + spk_last_error(engine.get()));
            spk_result di{};
            char* di_json = nullptr;
            const spk_status di_status = spk_render_digital_intermediate(slide.get(), &di, &di_json);
            const std::string di_error = spk_last_error(engine.get());
            const bool empty = !di.texture && !di.rgba16 && !di_json;
            spk_result_free(&di);
            spk_string_free(di_json);
            require(di_status == SPK_ERR_USER && empty && di_error.find("slide film") != std::string::npos,
                    "DI export on a slide did not return a clear refusal and empty result: " + di_error);
        }

        // What the effects do to the picture, on a session with nothing
        // stochastic in it (grain, glare and the meter off, as
        // tools/windows_stripe_regression.py runs its exact comparisons), so
        // equal means equal. The frame is portrait, so a half-frame pair splits
        // along rows -- the axis the strip executor cuts.
        {
            constexpr uint32_t kW = 16, kH = 32;
            std::vector<float> tall(kW * kH * 3);
            for (size_t i = 0; i < tall.size(); ++i) tall[i] = 0.025f + float(i % 31) * 0.025f;
            const spk_image portrait{tall.data(), kW, kH, 3};
            const std::string base = "\"grain_active\":false,\"glare_active\":false,\"auto_exposure\":false";
            std::unique_ptr<spk_session, decltype(&spk_session_release)> still(
                spk_open(engine.get(), &portrait, ("{" + base + "}").c_str(), nullptr), spk_session_release);
            require(bool(still), std::string("deterministic open failed: ") + spk_last_error(engine.get()));
            const auto plain = rendered(engine.get(), still.get(), kW, kH, "deterministic");
            require(rendered(engine.get(), still.get(), kW, kH, "deterministic") == plain,
                    "the deterministic session does not reproduce its own render");

            // The canvas DI and the DI export are the same Cineon frame.
            set(engine.get(), still.get(), "{\"digital_intermediate\":true}");
            const auto di = rendered(engine.get(), still.get(), kW, kH, "DI");
            require(di != plain, "the DI render equals the print");
            spk_result exported{};
            char* json = nullptr;
            const spk_status status = spk_render_digital_intermediate(still.get(), &exported, &json);
            const bool same = status == SPK_OK && packed(exported, kW, kH) == di;
            spk_result_free(&exported);
            spk_string_free(json);
            require(same, std::string("the DI export differs from the canvas DI render: ") +
                          spk_last_error(engine.get()));
            set(engine.get(), still.get(), "{\"digital_intermediate\":false}");

            // One frame: a knee a stop under grey compresses most of the frame.
            set(engine.get(), still.get(), "{\"scene_latitude_active\":true,\"scene_latitude_highlight_knee\":-1.0,"
                                           "\"scene_latitude_highlight_room\":1.0}");
            require(rendered(engine.get(), still.get(), kW, kH, "latitude") != plain,
                    "scene latitude mapping did not change the render");
            set(engine.get(), still.get(), "{\"scene_latitude_active\":false}");

            // The second pair alone: from half way down, the second frame's
            // knee. Rows well above the split are the plain render's; rows
            // below it are not.
            const std::string pair = "\"scene_latitude_split\":0.5,\"scene_latitude_b_active\":true,"
                                     "\"scene_latitude_b_highlight_knee\":-1.0,"
                                     "\"scene_latitude_b_highlight_room\":1.0";
            set(engine.get(), still.get(), ("{" + pair + "}").c_str());
            const auto paired = rendered(engine.get(), still.get(), kW, kH, "second pair");
            require(!rows_differ(paired, plain, kW, 0, kH / 2 - 4),
                    "the second pair changed rows of the first frame");
            require(rows_differ(paired, plain, kW, kH / 2 + 4, kH), "the second pair changed nothing");

            // Striped, the node sees each strip with its first row in the frame
            // (p[18]); 5-row strips put the split inside one, and the result
            // must be the whole-frame render exactly.
            std::unique_ptr<spk_session, decltype(&spk_session_release)> striped(
                spk_open(engine.get(), &portrait,
                         ("{" + base + "," + pair + ",\"striped\":true,\"strip_rows\":5}").c_str(), nullptr),
                spk_session_release);
            require(bool(striped), std::string("striped open failed: ") + spk_last_error(engine.get()));
            require(rendered(engine.get(), striped.get(), kW, kH, "striped second pair") == paired,
                    "the striped second pair differs from the whole-frame render");
        }

        const float* mask = nullptr;
        uint32_t width = 0, height = 0;
        require(spk_contrast_mask_field(session.get(), "full", &mask, &width, &height) == SPK_OK &&
                !mask && width == 0 && height == 0, "disabled contrast mask must have an empty field");

        // Latitude analysis uses the existing pipeline. This also exercises
        // probe_medium's readback.
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
        std::cout << "Windows feature boundaries passed (3 refused flags; DI and scene latitude accepted, "
                     "DI export = canvas DI, slide refused, second pair split and striped; mask off, "
                     "latitude analysis)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
